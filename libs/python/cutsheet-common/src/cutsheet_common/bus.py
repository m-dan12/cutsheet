"""Тонкий адаптер брокера сообщений (ТЗ 3.3).

Бизнес-логика сервиса — это обработчик `Event -> list[Event]`: он не знает про Kafka.
Адаптер читает топики, проверяет контракт, вызывает обработчик, публикует результат
и только после этого фиксирует смещение (at-least-once). Замена Kafka на другую
очередь затрагивает только этот файл.
"""

from __future__ import annotations

import json
import logging
import os
import signal
from typing import Callable, Iterable

from .contracts import ContractError, Contracts
from .envelope import Event, new_event

log = logging.getLogger("cutsheet.bus")

Handler = Callable[[Event], Iterable[Event] | None]


class KafkaBus:
    def __init__(self, service: str, *, bootstrap: str | None = None, group_id: str | None = None,
                 contracts: Contracts | None = None, max_poll_interval_ms: int | None = None):
        from confluent_kafka import Producer  # импорт здесь, чтобы тесты без Kafka не требовали librdkafka

        self.service = service
        self.bootstrap = bootstrap or os.environ.get("KAFKA_BOOTSTRAP", "localhost:9094")
        self.group_id = group_id or os.environ.get("KAFKA_GROUP_ID", service)
        self.contracts = contracts or Contracts()
        # Долгие задачи (детекция, транскрибация) идут десятки минут: поднимаем лимит,
        # иначе брокер решит, что консьюмер умер, и отдаст партицию другому.
        self.max_poll_interval_ms = max_poll_interval_ms or int(
            os.environ.get("KAFKA_MAX_POLL_INTERVAL_MS", str(2 * 60 * 60 * 1000)))
        # Сжатие: сценарий целиком в script.parsed — сотни КБ текста, а лимит сообщения 1 МБ.
        self._producer = Producer({"bootstrap.servers": self.bootstrap, "enable.idempotence": True,
                                   "compression.type": "lz4", "client.id": service})
        self._running = True

    def publish(self, event: Event) -> None:
        if event.producer is None:
            event.producer = self.service
        data = event.to_dict()
        self.contracts.validate(data)
        self._producer.produce(event.event_type, key=event.project_id.encode(),
                               value=json.dumps(data, ensure_ascii=False).encode("utf-8"))
        self._producer.flush(30)
        log.info("published %s", event.event_type,
                 extra={"project_id": event.project_id, "correlation_id": event.correlation_id,
                        "event_id": event.event_id})

    def stop(self, *_: object) -> None:
        self._running = False

    def run(self, topics: list[str], handler: Handler) -> None:
        from confluent_kafka import Consumer, KafkaError

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
        try:
            while self._running:
                msg = consumer.poll(1.0)
                if msg is None:
                    continue
                if msg.error():
                    if msg.error().code() != KafkaError._PARTITION_EOF:
                        log.warning("kafka error: %s", msg.error())
                    continue
                self._handle(msg.value(), handler)
                consumer.commit(message=msg, asynchronous=False)
        finally:
            consumer.close()

    def _handle(self, raw: bytes, handler: Handler) -> None:
        try:
            data = json.loads(raw)
            self.contracts.validate(data)
        except (ValueError, ContractError) as e:
            # Невалидное сообщение не ретраим. На этапе 6 оно пойдёт в <topic>.dlq.
            log.error("invalid message skipped: %s", e)
            return
        event = Event.from_dict(data)
        ctx = {"project_id": event.project_id, "correlation_id": event.correlation_id, "event_id": event.event_id}
        log.info("received %s", event.event_type, extra=ctx)
        try:
            for out in handler(event) or ():
                self.publish(out)
        except Exception as e:  # noqa: BLE001 — любой сбой этапа превращаем в pipeline.failed
            log.exception("handler failed", extra=ctx)
            self.publish(new_event("pipeline.failed", {
                "service": self.service,
                "source_event_id": event.event_id,
                "source_event_type": event.event_type,
                "error": f"{type(e).__name__}: {e}"[:2000],
                "retryable": not isinstance(e, ContractError),
            }, source=event, producer=self.service))
