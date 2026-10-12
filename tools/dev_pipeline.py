"""Сквозная проверка без клиента и Project API (этап 0).

Кладёт видео в MinIO, публикует video.uploaded от имени Project API и ждёт
scenes.detected и project.status-changed по этому проекту.

    python tools/dev_pipeline.py tools/sample.mp4
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import uuid
from pathlib import Path

from confluent_kafka import Consumer

from cutsheet_common import new_event
from cutsheet_common.bus import KafkaBus
from cutsheet_common.storage import Storage


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path)
    ap.add_argument("--timeout", type=float, default=300)
    args = ap.parse_args()

    os.environ.setdefault("KAFKA_BOOTSTRAP", "localhost:9094")
    os.environ.setdefault("S3_ENDPOINT", "http://localhost:9000")
    os.environ.setdefault("S3_ACCESS_KEY", "cutsheet")
    os.environ.setdefault("S3_SECRET_KEY", "cutsheet-secret")
    bucket = os.environ.get("S3_BUCKET", "cutsheet")

    project_id = str(uuid.uuid4())
    storage = Storage()
    storage.ensure_bucket(bucket)
    uri = storage.upload_file(args.video, bucket, f"projects/{project_id}/video/{args.video.name}", "video/mp4")
    print(f"uploaded {uri}")

    # Подписываемся до публикации, чтобы не пропустить ответ.
    consumer = Consumer({"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"],
                         "group.id": f"dev-pipeline-{project_id}", "auto.offset.reset": "latest"})
    consumer.subscribe(["scenes.detected", "project.status-changed", "pipeline.failed"])
    deadline = time.time() + 30
    while not consumer.assignment() and time.time() < deadline:
        consumer.poll(0.5)

    bus = KafkaBus("dev-pipeline")
    bus.publish(new_event("video.uploaded", {"video_uri": uri, "size_bytes": args.video.stat().st_size,
                                             "filename": args.video.name},
                          project_id=project_id, producer="dev-pipeline"))
    print(f"published video.uploaded for project {project_id}")

    seen: set[str] = set()
    deadline = time.time() + args.timeout
    while time.time() < deadline and not {"scenes.detected", "project.status-changed"} <= seen:
        msg = consumer.poll(1.0)
        if msg is None or msg.error():
            continue
        ev = json.loads(msg.value())
        if ev["project_id"] != project_id:
            continue
        seen.add(ev["event_type"])
        if ev["event_type"] == "scenes.detected":
            p = ev["payload"]
            print(f"scenes.detected: fps={p['fps']} duration_ms={p['duration_ms']}")
            for s in p["scenes"]:
                print(f"  #{s['index']}: {s['start_ms']}–{s['end_ms']} ms, {len(s['keyframe_uris'])} keyframes")
        elif ev["event_type"] == "pipeline.failed":
            print(f"pipeline.failed: {ev['payload']['error']}")
            return 1
        else:
            print(f"{ev['event_type']}: {json.dumps(ev['payload'], ensure_ascii=False)}")
    consumer.close()
    if {"scenes.detected", "project.status-changed"} <= seen:
        print("OK")
        return 0
    print(f"timeout, seen: {sorted(seen)}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
