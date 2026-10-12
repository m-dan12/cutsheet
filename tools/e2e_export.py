"""Сквозная проверка этапа 5 через Kong: экспорт монтажного листа в xlsx / docx / pdf.

Видео → сцены → правка описания → POST /exports по каждому формату → статус "export" по SignalR →
GET /exports/{id} с presigned URL → файл скачивается прямо из MinIO и содержит правку пользователя.
Неизвестный шаблон даёт export.failed с текстом ошибки.

    python tools/e2e_export.py tools/sample.mp4
"""

from __future__ import annotations

import argparse
import io
import sys
import urllib.request
import uuid
import zipfile
from pathlib import Path

from websockets.sync.client import connect

from e2e_api import Hub, call, upload_video, wait_scenes_done

EDIT = "Правка перед экспортом"
MAGIC = {"xlsx": b"PK", "docx": b"PK", "pdf": b"%PDF"}
TEXT_PART = {"xlsx": "xl/sharedStrings.xml", "docx": "word/document.xml"}


def wait_exports(hub: Hub, ids: set[str], timeout: float) -> dict[str, dict]:
    done: dict[str, dict] = {}
    for m in hub.messages(timeout):
        if m.get("type") != 1 or m.get("target") != "export":
            continue
        e = m["arguments"][0]
        print(f"export {e['format']}: {e['status']}")
        if e["export_id"] in ids and e["status"] != "requested":
            done[e["export_id"]] = e
            if done.keys() == ids:
                break
    return done


def download(url: str) -> tuple[bytes, str]:
    with urllib.request.urlopen(url, timeout=60) as resp:
        return resp.read(), resp.headers.get("Content-Disposition", "")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path)
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--timeout", type=float, default=300)
    args = ap.parse_args()
    api = f"{args.base}/api/v1"

    token = call("POST", f"{api}/auth/register",
                 {"email": f"export-{uuid.uuid4().hex[:8]}@example.com", "password": "e2e-password"})["access_token"]
    pid = call("POST", f"{api}/projects", {"name": "Фильм: e2e-экспорт"}, token)["id"]
    call("POST", f"{api}/projects/{pid}/exports", {"format": "pdf"}, token, expect=409)  # лист ещё пуст

    ws_base = args.base.replace("http", "ws", 1)
    with connect(f"{ws_base}/hubs/projects?access_token={token}", open_timeout=30) as ws:
        hub = Hub(ws)
        assert hub.invoke("Subscribe", pid) is True
        upload_video(api, token, pid, args.video)
        if not wait_scenes_done(hub, args.timeout):
            return 1

        scenes = call("GET", f"{api}/projects/{pid}/scenes", token=token)["scenes"]
        s0 = scenes[0]
        call("PATCH", f"{api}/projects/{pid}/scenes/{s0['id']}",
             {"row_version": s0["row_version"], "description": EDIT, "shot_type": "close"}, token)
        call("POST", f"{api}/projects/{pid}/exports", {"format": "odt"}, token, expect=400)

        requested = {}
        for fmt in ("xlsx", "docx", "pdf"):
            e = call("POST", f"{api}/projects/{pid}/exports", {"format": fmt}, token, expect=202)
            assert e["status"] == "requested" and e["download_url"] is None, e
            requested[e["id"]] = fmt
        bad = call("POST", f"{api}/projects/{pid}/exports", {"format": "pdf", "options": {"template": "nope"}},
                   token, expect=202)["id"]
        compact = call("POST", f"{api}/projects/{pid}/exports", {"format": "docx", "options": {"template": "compact"}},
                       token, expect=202)["id"]

        done = wait_exports(hub, {*requested, bad, compact}, args.timeout)
        if done.keys() != {*requested, bad, compact}:
            print(f"timeout: готово {len(done)} из {len(requested) + 2}")
            return 1

    for eid, fmt in requested.items():
        e = call("GET", f"{api}/projects/{pid}/exports/{eid}", token=token)
        assert e["status"] == "completed" and e["download_url"], e
        data, disposition = download(e["download_url"])
        assert data.startswith(MAGIC[fmt]), (fmt, data[:8])
        assert "filename*=UTF-8''" in disposition and e["filename"].endswith(f".{fmt}"), disposition
        if fmt in TEXT_PART:
            text = zipfile.ZipFile(io.BytesIO(data)).read(TEXT_PART[fmt]).decode("utf-8")
            assert EDIT in text and "крупный" in text, f"{fmt}: в файле нет правки пользователя"
        print(f"{fmt}: {len(data)} байт, правка пользователя в файле")

    failed = call("GET", f"{api}/projects/{pid}/exports/{bad}", token=token)
    assert failed["status"] == "failed" and "template not found" in failed["error"], failed
    data, _ = download(call("GET", f"{api}/projects/{pid}/exports/{compact}", token=token)["download_url"])
    text = zipfile.ZipFile(io.BytesIO(data)).read("word/document.xml").decode("utf-8")
    assert "Монтажный лист (диалоги)" in text and EDIT not in text, "шаблон compact не применился"
    print("неизвестный шаблон: export.failed; шаблон compact из каталога шаблонов: OK")

    listed = call("GET", f"{api}/projects/{pid}/exports", token=token)
    assert len(listed) == 5, listed
    print("e2e экспорта: OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
