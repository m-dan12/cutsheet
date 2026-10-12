"""Разбор DLQ (этап 6, ТЗ 4.3): что упало и почему, повторная отправка после исправления.

В `<topic>.dlq` лежит исходное сообщение как есть, а причина — в заголовках x-dlq-*
(сервис, reason invalid|failed, ошибка, число попыток, исходные партиция и смещение).

    python tools/dlq.py list                          # все DLQ-топики
    python tools/dlq.py list video.uploaded           # один топик
    python tools/dlq.py replay video.uploaded         # вернуть всё в video.uploaded (один раз)
    python tools/dlq.py replay video.uploaded --event-id <uuid>   # одно событие

replay без --event-id читает DLQ группой dlq-replay и фиксирует смещение, поэтому каждое
сообщение возвращается один раз; с --event-id DLQ читается целиком без фиксации.
Возвращённое событие получат все группы топика: они идемпотентны (дедупликация по event_id),
а сервис, у которого оно упало, обработает его заново. Невалидные сообщения (reason=invalid)
не возвращаются: они упадут снова.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from typing import Iterator

from confluent_kafka import Consumer, Producer
from confluent_kafka.admin import AdminClient

SUFFIX = ".dlq"


def bootstrap() -> str:
    return os.environ.get("KAFKA_BOOTSTRAP", "localhost:9094")


def dlq_topics(only: str | None) -> list[str]:
    if only:
        return [only if only.endswith(SUFFIX) else only + SUFFIX]
    names = AdminClient({"bootstrap.servers": bootstrap()}).list_topics(timeout=10).topics
    return sorted(t for t in names if t.endswith(SUFFIX))


def read(topics: list[str], group: str | None, idle_s: float = 30.0) -> Iterator[tuple[Consumer, object]]:
    """Сообщения DLQ с начала (или с зафиксированного смещения группы) до конца на момент запуска.

    Конец фиксируется при первом назначении партиций: при replay то же событие может снова
    упасть и вернуться в DLQ, и без этой границы оно повторялось бы бесконечно.
    """
    consumer = Consumer({"bootstrap.servers": bootstrap(), "group.id": group or f"dlq-inspect-{uuid.uuid4()}",
                         "enable.auto.commit": False, "auto.offset.reset": "earliest"})
    ends: dict[tuple[str, int], int] = {}
    pending: set[tuple[str, int]] = set()
    state = {"assigned": False, "last": time.monotonic()}

    def on_assign(c: Consumer, partitions) -> None:
        # Повторное назначение (ребалансировка группы) границу не сдвигает.
        fresh = [tp for tp in partitions if (tp.topic, tp.partition) not in ends]
        committed = {(tp.topic, tp.partition): tp.offset for tp in c.committed(fresh, timeout=10)} if fresh else {}
        for tp in fresh:
            low, high = c.get_watermark_offsets(tp, timeout=10)
            key = (tp.topic, tp.partition)
            ends[key] = high
            if max(low, committed.get(key, -1)) < high:
                pending.add(key)
        state.update(assigned=True, last=time.monotonic())

    consumer.subscribe(topics, on_assign=on_assign)
    started = time.monotonic()
    try:
        while not (state["assigned"] and not pending):
            msg = consumer.poll(0.5)
            if not state["assigned"]:
                if time.monotonic() - started > 60:
                    raise SystemExit(f"no partitions assigned for {topics}")
                continue
            if msg is None:
                if time.monotonic() - state["last"] > idle_s:
                    break  # страховка: граница так и не достигнута
                continue
            if msg.error():
                continue
            state["last"] = time.monotonic()
            key = (msg.topic(), msg.partition())
            if msg.offset() + 1 >= ends.get(key, 0):
                pending.discard(key)
            if msg.offset() >= ends.get(key, 0):
                continue
            yield consumer, msg
    finally:
        consumer.close()


def headers(msg) -> dict[str, str]:
    return {k: v.decode("utf-8", "replace") for k, v in msg.headers() or [] if isinstance(v, bytes)}


def envelope(msg) -> dict:
    try:
        data = json.loads(msg.value())
        return data if isinstance(data, dict) else {}
    except ValueError:
        return {}


def cmd_list(args: argparse.Namespace) -> int:
    rows = 0
    for _, msg in read(dlq_topics(args.topic), None):
        h, e = headers(msg), envelope(msg)
        rows += 1
        if args.json:
            print(json.dumps({"dlq_topic": msg.topic(), "offset": msg.offset(), "headers": h,
                              "event_id": e.get("event_id"), "project_id": e.get("project_id")}, ensure_ascii=False))
            continue
        print(f"{msg.topic()}@{msg.offset()}  {h.get('x-dlq-failed-at', '?')}  service={h.get('x-dlq-service')} "
              f"reason={h.get('x-dlq-reason')} attempts={h.get('x-dlq-attempts')}\n"
              f"    event={e.get('event_type', '?')} {e.get('event_id', '?')} project={e.get('project_id', '?')}\n"
              f"    error: {h.get('x-dlq-error', '')[:300]}")
    if not args.json:
        print(f"{rows} message(s)")
    return 0


def cmd_replay(args: argparse.Namespace) -> int:
    [topic] = dlq_topics(args.topic)
    source = topic[: -len(SUFFIX)]
    producer = Producer({"bootstrap.servers": bootstrap(), "enable.idempotence": True, "client.id": "dlq-replay"})
    group = None if args.event_id else f"dlq-replay-{source}"
    replayed = skipped = 0
    for consumer, msg in read([topic], group):
        h, e = headers(msg), envelope(msg)
        wanted = args.event_id is None or e.get("event_id") == args.event_id
        if wanted and h.get("x-dlq-reason") == "invalid":
            print(f"skip invalid message at offset {msg.offset()}: {h.get('x-dlq-error', '')[:200]}")
            wanted = False
        if wanted:
            if not args.dry_run:
                producer.produce(source, key=msg.key(), value=msg.value(),
                                 headers=[("x-dlq-replayed-from", f"{topic}@{msg.offset()}".encode())])
            replayed += 1
            print(f"{'would replay' if args.dry_run else 'replayed'} {e.get('event_type')} {e.get('event_id')} "
                  f"-> {source}")
        else:
            skipped += 1
        if group and not args.dry_run:
            consumer.commit(message=msg, asynchronous=False)
    producer.flush(30)
    print(f"{replayed} replayed, {skipped} skipped")
    return 0 if replayed or not args.event_id else 1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list", help="показать сообщения DLQ")
    ls.add_argument("topic", nargs="?", help="исходный топик или <topic>.dlq; по умолчанию все")
    ls.add_argument("--json", action="store_true", help="по строке JSON на сообщение")
    rp = sub.add_parser("replay", help="вернуть сообщения в исходный топик")
    rp.add_argument("topic")
    rp.add_argument("--event-id")
    rp.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()
    return cmd_list(args) if args.cmd == "list" else cmd_replay(args)


if __name__ == "__main__":
    sys.exit(main())
