"""Нагрузочный тест (этап 6, ТЗ 11.1): N проектов одновременно через весь конвейер.

Как dev_dialogues.py --enrichment, но параллельно: создаёт N проектов, кладёт ролик и
сценарий в MinIO, публикует video.uploaded и script.uploaded для всех сразу и по
project.status-changed замеряет, когда каждый проект прошёл этапы и дошёл до ready_for_review.
В конце — таблица по проектам, медиана и максимум, отношение к длительности ролика
(цель ТЗ 7: обработка ≤ 1,5× длительности фильма) и отказы.

    python tools/load_test.py -n 5 tools/sample.mp4 tools/sample_script.docx
    python tools/load_test.py -n 5 film.mp4 film.docx --timeout 14400 --json load.json

Цель ТЗ — 5 параллельных проектов на фильме 90+ мин; в CI — короткий ролик.
Пока идёт тест, загрузку видно в Grafana (make up-obs): lag, длительность этапов, ошибки.
"""

from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
import uuid
from pathlib import Path

from confluent_kafka import Consumer

sys.path.insert(0, str(Path(__file__).resolve().parent))
from dev_dialogues import create_project  # noqa: E402

from cutsheet_common import new_event  # noqa: E402
from cutsheet_common.bus import KafkaBus  # noqa: E402
from cutsheet_common.storage import Storage  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]


def media_duration_s(path: Path) -> float:
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
                         check=True, capture_output=True, text=True)
    return float(out.stdout.strip())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path, nargs="?", default=ROOT / "tools" / "sample.mp4")
    ap.add_argument("script", type=Path, nargs="?", default=ROOT / "tools" / "sample_script.docx")
    ap.add_argument("-n", "--projects", type=int, default=5)
    ap.add_argument("--timeout", type=float, default=1800)
    ap.add_argument("--json", type=Path, help="сохранить результаты в файл")
    args = ap.parse_args()

    os.environ.setdefault("KAFKA_BOOTSTRAP", "localhost:9094")
    os.environ.setdefault("S3_ENDPOINT", "http://localhost:9000")
    os.environ.setdefault("S3_ACCESS_KEY", "cutsheet")
    os.environ.setdefault("S3_SECRET_KEY", "cutsheet-secret")
    bucket = os.environ.get("S3_BUCKET", "cutsheet")
    if not args.script.exists():
        from make_sample_script import build
        build(args.script)

    storage = Storage()
    storage.ensure_bucket(bucket)
    projects: dict[str, dict] = {}
    for _ in range(args.projects):
        pid = str(uuid.uuid4())
        create_project(pid)
        projects[pid] = {
            "video_uri": storage.upload_file(args.video, bucket, f"projects/{pid}/video/{args.video.name}",
                                             "video/mp4"),
            "script_uri": storage.upload_file(args.script, bucket, f"projects/{pid}/script/{args.script.name}"),
            "stages": {}, "failed": None, "done": None,
        }

    consumer = Consumer({"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"],
                         "group.id": f"load-test-{uuid.uuid4()}", "auto.offset.reset": "latest"})
    consumer.subscribe(["project.status-changed", "pipeline.failed"])
    deadline = time.time() + 30
    while not consumer.assignment() and time.time() < deadline:
        consumer.poll(0.5)

    bus = KafkaBus("load-test")
    started = time.monotonic()
    for pid, p in projects.items():
        cid = str(uuid.uuid4())
        bus.publish(new_event("video.uploaded", {"video_uri": p["video_uri"], "size_bytes": args.video.stat().st_size,
                                                 "filename": args.video.name},
                              project_id=pid, correlation_id=cid, producer="load-test"))
        bus.publish(new_event("script.uploaded", {"script_uri": p["script_uri"], "filename": args.script.name},
                              project_id=pid, correlation_id=cid, producer="load-test"))
    print(f"{len(projects)} projects started")

    def pending() -> list[str]:
        return [pid for pid, p in projects.items() if p["done"] is None and p["failed"] is None]

    deadline = time.time() + args.timeout
    while pending() and time.time() < deadline:
        msg = consumer.poll(1.0)
        if msg is None or msg.error():
            continue
        ev = json.loads(msg.value())
        p = projects.get(ev["project_id"])
        if p is None:
            continue
        t = round(time.monotonic() - started, 1)
        pl = ev["payload"]
        if ev["event_type"] == "pipeline.failed":
            # Сбой обогащения одной сцены проект не валит (FR-A6) — только отмечаем.
            p["stages"].setdefault(f"pipeline.failed:{pl['service']}", t)
            continue
        key = f"{pl['stage']}/{pl['status']}"
        p["stages"].setdefault(key, t)
        if pl["status"] == "ready_for_review":
            p["done"] = t
            print(f"  {ev['project_id'][:8]} ready_for_review at {t}s")
        elif pl["status"] == "failed":
            p["failed"] = pl.get("error") or key
            print(f"  {ev['project_id'][:8]} failed at {t}s: {p['failed']}")
    consumer.close()

    video_s = media_duration_s(args.video)
    times = [p["done"] for p in projects.values() if p["done"] is not None]
    stages = sorted({k for p in projects.values() for k in p["stages"]})
    print(f"\n{'project':<10}" + "".join(f"{s[:24]:>26}" for s in stages))
    for pid, p in projects.items():
        print(f"{pid[:8]:<10}" + "".join(f"{p['stages'].get(s, '-'):>26}" for s in stages))
    summary = {
        "projects": len(projects), "ready": len(times),
        "failed": sum(1 for p in projects.values() if p["failed"]),
        "timed_out": len(pending()),
        "video_s": round(video_s, 1),
        "median_s": round(statistics.median(times), 1) if times else None,
        "max_s": max(times) if times else None,
        "max_ratio_to_video": round(max(times) / video_s, 2) if times and video_s else None,
    }
    print("\n" + json.dumps(summary, ensure_ascii=False))
    if args.json:
        args.json.write_text(json.dumps({"summary": summary, "projects": projects}, ensure_ascii=False, indent=2))
    return 0 if summary["ready"] == len(projects) else 1


if __name__ == "__main__":
    sys.exit(main())
