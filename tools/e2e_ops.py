"""Сквозная проверка этапа 6: DLQ, повторы, метрики и трейсы на поднятом docker-compose.

1. Невалидное сообщение в video.uploaded → video.uploaded.dlq от Scene Detection и
   Transcription (reason=invalid), в scenes.dlq — от Aggregator (C#).
2. Корректное video.uploaded на несуществующий файл → после всех повторов
   video.uploaded.dlq (reason=failed, attempts=KAFKA_MAX_ATTEMPTS) и pipeline.failed.
3. tools/dlq.py находит эти сообщения.
4. С --observability (make up-obs): все цели Prometheus в up, есть метрики DLQ и lag,
   в Jaeger есть трейсы сервисов.

    python tools/e2e_ops.py --observability
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

from confluent_kafka import Consumer, Producer

from cutsheet_common import new_event
from cutsheet_common.bus import KafkaBus

ROOT = Path(__file__).resolve().parents[1]
PROMETHEUS = os.environ.get("PROMETHEUS_URL", "http://localhost:9090")
JAEGER = os.environ.get("JAEGER_URL", "http://localhost:16686")


def watch(topics: list[str]) -> Consumer:
    c = Consumer({"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"], "group.id": f"e2e-ops-{uuid.uuid4()}",
                  "auto.offset.reset": "latest", "enable.auto.commit": False})
    c.subscribe(topics)
    deadline = time.time() + 30
    while len(c.assignment()) < len(topics) and time.time() < deadline:
        c.poll(0.5)
    return c


def collect(c: Consumer, done, timeout: float) -> list:
    got: list = []
    deadline = time.time() + timeout
    while time.time() < deadline and not done(got):
        msg = c.poll(1.0)
        if msg is not None and not msg.error():
            got.append(msg)
    return got


def headers(msg) -> dict[str, str]:
    return {k: v.decode() for k, v in msg.headers() or []}


def get_json(url: str) -> dict:
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.loads(r.read())


def check(cond: bool, what: str) -> None:
    print(("OK   " if cond else "FAIL ") + what)
    if not cond:
        raise SystemExit(1)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--observability", action="store_true", help="проверить Prometheus и Jaeger")
    ap.add_argument("--timeout", type=float, default=120)
    args = ap.parse_args()
    os.environ.setdefault("KAFKA_BOOTSTRAP", "localhost:9094")
    attempts = os.environ.get("KAFKA_MAX_ATTEMPTS", "3")

    c = watch(["video.uploaded.dlq", "scenes.detected.dlq", "pipeline.failed"])
    producer = Producer({"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"]})
    bad_key = str(uuid.uuid4()).encode()
    producer.produce("video.uploaded", key=bad_key, value=b"{not json")
    producer.produce("scenes.detected", key=bad_key, value=b'{"event_type": 42}')
    producer.flush(10)

    pid = str(uuid.uuid4())
    ev = new_event("video.uploaded", {"video_uri": f"s3://cutsheet/projects/{pid}/video/missing.mp4",
                                      "size_bytes": 1, "filename": "missing.mp4"},
                   project_id=pid, producer="e2e-ops")
    KafkaBus("e2e-ops").publish(ev)

    def invalid(m) -> bool:
        return m.key() == bad_key and headers(m).get("x-dlq-reason") == "invalid"

    def failed(m) -> bool:
        return m.topic() == "video.uploaded.dlq" and headers(m).get("x-dlq-reason") == "failed" \
            and json.loads(m.value())["event_id"] == ev.event_id

    def pipeline_failed(m) -> bool:
        return m.topic() == "pipeline.failed" and json.loads(m.value())["payload"]["source_event_id"] == ev.event_id

    want = {("video.uploaded.dlq", "scene-detection"), ("video.uploaded.dlq", "transcription"),
            ("scenes.detected.dlq", "aggregator")}

    def done(got: list) -> bool:
        inv = {(m.topic(), headers(m)["x-dlq-service"]) for m in got if invalid(m)}
        fail = {headers(m)["x-dlq-service"] for m in got if failed(m)}
        pf = {json.loads(m.value())["payload"]["service"] for m in got if pipeline_failed(m)}
        return want <= inv and {"scene-detection", "transcription"} <= fail and \
            {"scene-detection", "transcription"} <= pf

    got = collect(c, done, args.timeout)
    c.close()
    inv = {(m.topic(), headers(m)["x-dlq-service"]) for m in got if invalid(m)}
    for topic, service in sorted(want):
        check((topic, service) in inv, f"invalid message → {topic} by {service}")
    for m in got:
        if failed(m):
            h = headers(m)
            check(h["x-dlq-attempts"] == attempts,
                  f"{h['x-dlq-service']}: failed after {h['x-dlq-attempts']} attempts → video.uploaded.dlq "
                  f"({h['x-dlq-error'][:80]})")
    pf = {json.loads(m.value())["payload"]["service"] for m in got if pipeline_failed(m)}
    check({"scene-detection", "transcription"} <= pf, f"pipeline.failed published by {sorted(pf)}")

    listing = subprocess.run([sys.executable, str(ROOT / "tools" / "dlq.py"), "list", "video.uploaded", "--json"],
                             check=True, capture_output=True, text=True).stdout
    check(ev.event_id in listing, "tools/dlq.py list shows the failed event")
    replay = subprocess.run([sys.executable, str(ROOT / "tools" / "dlq.py"), "replay", "video.uploaded",
                             "--event-id", ev.event_id, "--dry-run"], capture_output=True, text=True)
    check(replay.returncode == 0 and "would replay" in replay.stdout, "tools/dlq.py replay --dry-run finds it")

    if args.observability:
        observability(args.timeout)
    print("OK")
    return 0


def prom(query: str) -> list:
    return get_json(f"{PROMETHEUS}/api/v1/query?" + urllib.parse.urlencode({"query": query}))["data"]["result"]


def observability(timeout: float) -> None:
    deadline = time.time() + timeout
    targets: list = []
    while time.time() < deadline:
        targets = get_json(f"{PROMETHEUS}/api/v1/targets")["data"]["activeTargets"]
        dlq = prom("sum by (service) (cutsheet_dlq_messages_total)")
        lag = prom("kafka_consumergroup_lag")
        if targets and all(t["health"] == "up" for t in targets) and len(dlq) >= 3 and lag:
            break
        time.sleep(5)
    for t in targets:
        check(t["health"] == "up", f"prometheus target {t['labels'].get('instance')} ({t['labels']['job']}) up")
    services = {r["metric"]["service"] for r in prom("sum by (service) (cutsheet_dlq_messages_total)")}
    check({"scene-detection", "transcription", "aggregator"} <= services, f"DLQ metrics from {sorted(services)}")
    check(bool(prom("kafka_consumergroup_lag")), "consumer lag metric from kafka-exporter")
    check(bool(prom("cutsheet_handler_duration_seconds_count")), "stage duration metric")

    # Трейсы: Project API (HTTP из make e2e), Python-сервисы и Aggregator по цепочке traceparent.
    want = {"project-api", "scene-detection", "transcription", "aggregator"}
    traced: set[str] = set()
    while time.time() < deadline:
        traced = set(get_json(f"{JAEGER}/api/services").get("data") or [])
        if want <= traced:
            break
        time.sleep(5)
    check(want <= traced, f"jaeger has traces from {sorted(traced)}")


if __name__ == "__main__":
    sys.exit(main())
