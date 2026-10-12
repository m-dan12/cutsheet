"""Тонкий адаптер брокера сообщений (ТЗ 3.3, 4.3).

Бизнес-логика сервиса — это обработчик `Event -> list[Event]`: он не знает про Kafka.
Адаптер читает топики, проверяет контракт, вызывает обработчик, публикует результат
и только после этого фиксирует смещение (at-least-once). Замена Kafka на другую
очередь затрагивает только этот файл.

Ошибки (этап 6):
- невалидное сообщение (не JSON, не проходит контракт) не ретраится и сразу уходит в `<topic>.dlq`;
- сбой обработчика повторяется с экспоненциальной задержкой до KAFKA_MAX_ATTEMPTS раз;
  ошибки данных (ValueError, ContractError, PermanentError) не повторяются;
- после последней попытки исходное сообщение уходит в `<topic>.dlq` (с причиной в заголовках),
  а в `pipeline.failed` — сообщение для Aggregator, который переводит проект в failed.
Повторно отправить сообщения из DLQ: tools/dlq.py replay.

Идемпотентность: id результатов детерминированы (derive_event_id), поэтому повторная
обработка даёт те же события и потребители их отбрасывают. Кроме того, адаптер помнит
последние обработанные event_id и не запускает долгий этап повторно на дубль.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import threading
import time
import uuid
from collections import OrderedDict
from datetime import datetime, timezone
from typing import Any, Callable, Iterable

from . import observability as obs
from .contracts import ContractError, Contracts
from .envelope import Event, new_event

log = logging.getLogger("cutsheet.bus")

Handler = Callable[[Event], Iterable[Event] | None]
Headers = list[tuple[str, bytes]]


class PermanentError(Exception):
    """Ошибка, которую повтор не исправит (битые входные данные): сразу в DLQ, без повторов."""


NON_RETRYABLE: tuple[type[BaseException], ...] = (PermanentError, ContractError, ValueError)


def dlq_topic(topic: str) -> str:
    return f"{topic}.dlq"


class KafkaBus:
    def __init__(self, service: str, *, bootstrap: str | None = None, group_id: str | None = None,
                 contracts: Contracts | None = None, max_poll_interval_ms: int | None = None,
                 max_attempts: int | None = None, backoff_s: float | None = None,
                 producer: Any = None, sleep: Callable[[float], None] | None = None):
        self.service = service
        self.bootstrap = bootstrap or os.environ.get("KAFKA_BOOTSTRAP", "localhost:9094")
        self.group_id = group_id or os.environ.get("KAFKA_GROUP_ID", service)
        self.contracts = contracts or Contracts()
        # Долгие задачи (детекция, транскрибация) идут десятки минут: поднимаем лимит,
        # иначе брокер решит, что консьюмер умер, и отдаст партицию другому.
        self.max_poll_interval_ms = max_poll_interval_ms or int(
            os.environ.get("KAFKA_MAX_POLL_INTERVAL_MS", str(2 * 60 * 60 * 1000)))
        self.max_attempts = max(1, max_attempts or int(os.environ.get("KAFKA_MAX_ATTEMPTS", "3")))
        self.backoff_s = float(os.environ.get("KAFKA_RETRY_BACKOFF_S", "2")) if backoff_s is None else backoff_s
        if producer is None:
            from confluent_kafka import Producer  # импорт здесь, чтобы тесты без Kafka не требовали librdkafka

            # Сжатие: сценарий целиком в script.parsed — сотни КБ текста, а лимит сообщения 1 МБ.
            producer = Producer({"bootstrap.servers": self.bootstrap, "enable.idempotence": True,
                                 "compression.type": "lz4", "client.id": service})
        self._producer = producer
        self._stop = threading.Event()
        self._sleep = sleep or (lambda s: self._stop.wait(s))
        self._seen: OrderedDict[str, None] = OrderedDict()
        self.health = obs.Health(service)

    # ---------- публикация ----------

    def publish(self, event: Event) -> None:
        if event.producer is None:
            event.producer = self.service
        data = event.to_dict()
        self.contracts.validate(data)
        with obs.span(f"{event.event_type} publish", kind="producer",
                      attributes={"messaging.destination.name": event.event_type, "cutsheet.event_id": event.event_id,
                                  "cutsheet.project_id": event.project_id}):
            self._producer.produce(event.event_type, key=event.project_id.encode(),
                                   value=json.dumps(data, ensure_ascii=False).encode("utf-8"),
                                   headers=obs.trace_headers())
            self._producer.flush(30)
        obs.EVENTS_PUBLISHED.labels(self.service, event.event_type).inc()
        log.info("published %s", event.event_type,
                 extra={"project_id": event.project_id, "correlation_id": event.correlation_id,
                        "event_id": event.event_id})

    def _to_dlq(self, topic: str, key: bytes | None, raw: bytes, *, reason: str, error: str, attempts: int,
                partition: int | None, offset: int | None, ctx: dict[str, str] | None = None) -> None:
        headers = [
            ("x-dlq-source-topic", topic), ("x-dlq-service", self.service), ("x-dlq-reason", reason),
            ("x-dlq-error", error[:2000]), ("x-dlq-attempts", str(attempts)),
            ("x-dlq-partition", str(partition)), ("x-dlq-offset", str(offset)),
            ("x-dlq-failed-at", datetime.now(timezone.utc).isoformat(timespec="seconds")),
        ]
        self._producer.produce(dlq_topic(topic), key=key, value=raw,
                               headers=[(k, v.encode("utf-8")) for k, v in headers])
        self._producer.flush(30)
        obs.DLQ_MESSAGES.labels(self.service, topic, reason).inc()
        log.error("sent to %s (%s after %d attempt(s)): %s", dlq_topic(topic), reason, attempts, error[:500],
                  extra=ctx or {})

    # ---------- чтение ----------

    def stop(self, *_: object) -> None:
        self._stop.set()

    def run(self, topics: list[str], handler: Handler) -> None:
        from confluent_kafka import Consumer, KafkaError

        obs.init_tracing(self.service)
        obs.serve(self.health)
        consumer = Consumer({
            "bootstrap.servers": self.bootstrap,
            "group.id": self.group_id,
            "enable.auto.commit": False,
            "auto.offset.reset": "earliest",
            "max.poll.interval.ms": self.max_poll_interval_ms,
            "client.id": self.service,
        })
        signal.signal(signal.SIGTERM, self.stop)
        signal.signal(signal.SIGINT, self.stop)
        consumer.subscribe(topics)
        log.info("consuming %s as group %s", topics, self.group_id)
        self.health.running = True
        try:
            while not self._stop.is_set():
                msg = consumer.poll(1.0)
                self.health.last_poll = time.time()
                if msg is None:
                    continue
                if msg.error():
                    if msg.error().code() != KafkaError._PARTITION_EOF:
                        log.warning("kafka error: %s", msg.error())
                    continue
                done = self.process(msg.topic(), msg.value(), handler, key=msg.key(), headers=msg.headers(),
                                    partition=msg.partition(), offset=msg.offset())
                if not done:  # остановка посреди повторов: смещение не фиксируем, сообщение прочитают снова
                    break
                consumer.commit(message=msg, asynchronous=False)
        finally:
            self.health.running = False
            consumer.close()

    def process(self, topic: str, raw: bytes, handler: Handler, *, key: bytes | None = None,
                headers: Headers | None = None, partition: int | None = None, offset: int | None = None) -> bool:
        """Обрабатывает одно сообщение. False — сервис останавливается, смещение фиксировать нельзя."""
        try:
            data = json.loads(raw)
            self.contracts.validate(data)
        except (ValueError, ContractError) as e:
            obs.EVENTS_CONSUMED.labels(self.service, topic, "invalid").inc()
            self._to_dlq(topic, key, raw, reason="invalid", error=f"{type(e).__name__}: {e}", attempts=0,
                         partition=partition, offset=offset)
            return True
        event = Event.from_dict(data)
        ctx = {"project_id": event.project_id, "correlation_id": event.correlation_id, "event_id": event.event_id}
        if event.event_id in self._seen:
            obs.EVENTS_CONSUMED.labels(self.service, topic, "duplicate").inc()
            log.info("duplicate %s skipped", event.event_type, extra=ctx)
            return True
        log.info("received %s", event.event_type, extra=ctx)

        self.health.busy_with, self.health.busy_since = f"{event.event_type} {event.event_id}", time.time()
        try:
            with obs.span(f"{topic} process", kind="consumer", headers=headers,
                          attributes={"messaging.destination.name": topic, "cutsheet.event_id": event.event_id,
                                      "cutsheet.project_id": event.project_id,
                                      "cutsheet.correlation_id": event.correlation_id}):
                return self._attempts(topic, raw, key, event, handler, ctx, partition, offset)
        finally:
            self.health.busy_with = self.health.busy_since = None

    def _attempts(self, topic: str, raw: bytes, key: bytes | None, event: Event, handler: Handler,
                  ctx: dict[str, str], partition: int | None, offset: int | None) -> bool:
        attempt = 0
        while True:
            attempt += 1
            done = obs.timed(self.service, event.event_type)
            try:
                for out in handler(event) or ():
                    self.publish(out)
                done()
                self._remember(event.event_id)
                obs.EVENTS_CONSUMED.labels(self.service, topic, "ok").inc()
                return True
            except Exception as e:  # noqa: BLE001 — любой сбой этапа: повтор или DLQ + pipeline.failed
                error = f"{type(e).__name__}: {e}"
                retryable = not isinstance(e, NON_RETRYABLE)
                if retryable and attempt < self.max_attempts:
                    delay = min(self.backoff_s * 2 ** (attempt - 1), 300.0)
                    obs.HANDLER_RETRIES.labels(self.service, topic).inc()
                    log.warning("handler failed (attempt %d/%d), retry in %.1fs: %s",
                                attempt, self.max_attempts, delay, error[:500], extra=ctx)
                    self._sleep(delay)
                    if self._stop.is_set():
                        return False
                    continue
                log.exception("handler failed after %d attempt(s)", attempt, extra=ctx)
                break

        obs.EVENTS_CONSUMED.labels(self.service, topic, "failed").inc()
        self._to_dlq(topic, key, raw, reason="failed", error=error, attempts=attempt,
                     partition=partition, offset=offset, ctx=ctx)
        # Случайный id: если сообщение повторно отправят из DLQ и оно снова упадёт,
        # Aggregator должен увидеть новую неудачу, а не отбросить её как дубль.
        self.publish(new_event("pipeline.failed", {
            "service": self.service,
            "source_event_id": event.event_id,
            "source_event_type": event.event_type,
            "error": error[:2000],
            "retryable": retryable,
        }, source=event, producer=self.service, event_id=str(uuid.uuid4())))
        # Неудачу не запоминаем: повторная отправка из DLQ (tools/dlq.py replay) должна дойти до обработчика.
        return True

    def _remember(self, event_id: str, size: int = 1000) -> None:
        self._seen[event_id] = None
        while len(self._seen) > size:
            self._seen.popitem(last=False)
