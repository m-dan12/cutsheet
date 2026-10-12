"""Сквозная проверка этапа 2 без клиента: видео + сценарий → сцены с репликами.

Создаёт проект в PostgreSQL (как Project API), кладёт видео и сценарий в MinIO, публикует
video.uploaded и script.uploaded и ждёт script.parsed, dialogue.aligned и по одному
scene.ready-for-enrichment на каждую сцену.

    python tools/dev_dialogues.py tools/sample.mp4 tools/sample_script.docx
    python tools/dev_dialogues.py --speech      # ролик с озвучкой реплик (нужен espeak-ng)
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from confluent_kafka import Consumer

from cutsheet_common import new_event
from cutsheet_common.bus import KafkaBus
from cutsheet_common.storage import Storage

ROOT = Path(__file__).resolve().parents[1]
COMPOSE = ["docker", "compose", "-f", str(ROOT / "deploy" / "docker-compose.yml")]
SPEECH = ["Ты опять не спал всю ночь?", "Я думал о том, что ты сказала вчера. Ты была права.",
          "Тогда собирайся, мы опаздываем на поезд."]


def create_project(project_id: str) -> None:
    sql = (f"INSERT INTO projects (id, owner_id, name) VALUES ('{project_id}', '{uuid.uuid4()}', 'dev-dialogues')")
    user, db = os.environ.get("POSTGRES_USER", "cutsheet"), os.environ.get("POSTGRES_DB", "cutsheet")
    subprocess.run([*COMPOSE, "exec", "-T", "postgres", "psql", "-v", "ON_ERROR_STOP=1", "-U", user, "-d", db,
                    "-c", sql], check=True, capture_output=True)


def speech_video(out: Path) -> Path:
    """Цветные «планы» как в make_sample_video.sh + озвучка реплик сценария через espeak-ng."""
    tmp = Path(tempfile.mkdtemp())
    wav = tmp / "speech.wav"
    subprocess.run(["espeak-ng", "-v", "ru", "-s", "140", "-g", "40", "-w", str(wav), " ".join(SPEECH)], check=True)
    subprocess.run(["sh", str(ROOT / "tools" / "make_sample_video.sh"), str(tmp / "video.mp4")], check=True,
                   capture_output=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(tmp / "video.mp4"), "-i", str(wav),
                    "-c:v", "copy", "-c:a", "aac", str(out)], check=True)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path, nargs="?", default=ROOT / "tools" / "sample.mp4")
    ap.add_argument("script", type=Path, nargs="?", default=ROOT / "tools" / "sample_script.docx")
    ap.add_argument("--speech", action="store_true", help="сгенерировать ролик с речью (espeak-ng)")
    ap.add_argument("--timeout", type=float, default=600)
    args = ap.parse_args()

    os.environ.setdefault("KAFKA_BOOTSTRAP", "localhost:9094")
    os.environ.setdefault("S3_ENDPOINT", "http://localhost:9000")
    os.environ.setdefault("S3_ACCESS_KEY", "cutsheet")
    os.environ.setdefault("S3_SECRET_KEY", "cutsheet-secret")
    bucket = os.environ.get("S3_BUCKET", "cutsheet")

    if args.speech:
        args.video = speech_video(ROOT / "tools" / "sample_speech.mp4")
    if not args.script.exists():
        sys.path.insert(0, str(ROOT / "tools"))
        from make_sample_script import build
        build(args.script)

    project_id = str(uuid.uuid4())
    create_project(project_id)
    storage = Storage()
    storage.ensure_bucket(bucket)
    video_uri = storage.upload_file(args.video, bucket, f"projects/{project_id}/video/{args.video.name}", "video/mp4")
    script_uri = storage.upload_file(args.script, bucket, f"projects/{project_id}/script/{args.script.name}")
    print(f"project {project_id}\n  {video_uri}\n  {script_uri}")

    consumer = Consumer({"bootstrap.servers": os.environ["KAFKA_BOOTSTRAP"],
                         "group.id": f"dev-dialogues-{project_id}", "auto.offset.reset": "latest"})
    consumer.subscribe(["scenes.detected", "script.parsed", "dialogue.aligned", "scene.ready-for-enrichment",
                        "project.status-changed", "pipeline.failed"])
    deadline = time.time() + 30
    while not consumer.assignment() and time.time() < deadline:
        consumer.poll(0.5)

    bus = KafkaBus("dev-dialogues")
    cid = str(uuid.uuid4())
    bus.publish(new_event("video.uploaded", {"video_uri": video_uri, "size_bytes": args.video.stat().st_size,
                                             "filename": args.video.name},
                          project_id=project_id, correlation_id=cid, producer="dev-dialogues"))
    bus.publish(new_event("script.uploaded", {"script_uri": script_uri, "filename": args.script.name},
                          project_id=project_id, correlation_id=cid, producer="dev-dialogues"))

    scenes_total: int | None = None
    ready: list[dict] = []
    seen: set[str] = set()
    deadline = time.time() + args.timeout
    while time.time() < deadline and (scenes_total is None or len(ready) < scenes_total):
        msg = consumer.poll(1.0)
        if msg is None or msg.error():
            continue
        ev = json.loads(msg.value())
        if ev["project_id"] != project_id:
            continue
        t, p = ev["event_type"], ev["payload"]
        seen.add(t)
        if t == "pipeline.failed":
            print(f"pipeline.failed from {p['service']}: {p['error']}")
            return 1
        if t == "scenes.detected":
            scenes_total = len(p["scenes"])
            print(f"scenes.detected: {scenes_total} scenes")
        elif t == "script.parsed":
            lines = sum(1 for s in p["script_scenes"] for ln in s["lines"] if ln["kind"] == "dialogue")
            print(f"script.parsed: {len(p['script_scenes'])} scenes, roles {p['roles']}, {lines} dialogue lines")
        elif t == "dialogue.aligned":
            print(f"dialogue.aligned: {json.dumps(p.get('stats'), ensure_ascii=False)}")
        elif t == "scene.ready-for-enrichment":
            ready.append(p)
        else:
            print(f"{t}: {json.dumps(p, ensure_ascii=False)}")
    consumer.close()

    for p in sorted(ready, key=lambda s: s["index"]):
        print(f"  #{p['index']} {p['start_ms']}–{p['end_ms']} ms")
        for r in p.get("replicas", []):
            print(f"      {r['start_ms']:>6} {r['role'] or '?'}: {r['text']}")
    if scenes_total is not None and len(ready) == scenes_total and {"script.parsed", "dialogue.aligned"} <= seen:
        print("OK")
        return 0
    print(f"timeout, seen: {sorted(seen)}, ready {len(ready)}/{scenes_total}")
    return 1


if __name__ == "__main__":
    sys.exit(main())
