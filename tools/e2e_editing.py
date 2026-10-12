"""Сквозная проверка этапа 4 через Kong: правки монтажного листа переживают повторную обработку.

Видео → сцены → правка описания и плана → устаревший row_version даёт 409 с актуальной строкой →
перезапуск обработки: id строк и правка на месте → split (структура теперь пользователя) →
ещё один перезапуск: структура не тронута → merge обратно.

    python tools/e2e_editing.py tools/sample.mp4
"""

from __future__ import annotations

import argparse
import sys
import uuid
from pathlib import Path

from websockets.sync.client import connect

from e2e_api import Hub, call, upload_video, wait_scenes_done


def reprocess(api: str, token: str, pid: str, hub: Hub, timeout: float) -> dict:
    call("POST", f"{api}/projects/{pid}/reprocess", {"from": "scenes"}, token, expect=202)
    if not wait_scenes_done(hub, timeout):
        raise SystemExit("перезапуск не дошёл до scenes/done")
    return call("GET", f"{api}/projects/{pid}/scenes", token=token)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path)
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--timeout", type=float, default=300)
    args = ap.parse_args()
    api = f"{args.base}/api/v1"

    token = call("POST", f"{api}/auth/register",
                 {"email": f"edit-{uuid.uuid4().hex[:8]}@example.com", "password": "e2e-password"})["access_token"]
    pid = call("POST", f"{api}/projects", {"name": "e2e-editing"}, token)["id"]

    ws_base = args.base.replace("http", "ws", 1)
    with connect(f"{ws_base}/hubs/projects?access_token={token}", open_timeout=30) as ws:
        hub = Hub(ws)
        assert hub.invoke("Subscribe", pid) is True
        upload_video(api, token, pid, args.video)
        if not wait_scenes_done(hub, args.timeout):
            return 1

        sheet = call("GET", f"{api}/projects/{pid}/scenes", token=token)
        scenes = sheet["scenes"]
        assert len(scenes) >= 2, sheet
        assert sheet["video_url"] and sheet["review_required"] and not sheet["structure_edited"], sheet
        ids = [s["id"] for s in scenes]
        s1 = scenes[1]
        print(f"лист: {len(scenes)} строк")

        url = f"{api}/projects/{pid}/scenes/{s1['id']}"
        changed = call("PATCH", url, {"row_version": s1["row_version"], "description": "Правка e2e",
                                      "shot_type": "close"}, token)["scenes"][0]
        assert changed["row_version"] == s1["row_version"] + 1, changed
        assert sorted(changed["edited"]) == ["description", "shot_type"], changed
        conflict = call("PATCH", url, {"row_version": s1["row_version"], "description": "чужая"}, token, expect=409)
        assert conflict["scene"]["description"] == "Правка e2e", conflict
        call("PATCH", url, {"row_version": changed["row_version"], "shot_type": "nope"}, token, expect=400)
        print("правка строки, 409 на устаревшей версии, 400 на неверном плане: OK")

        project = call("PATCH", f"{api}/projects/{pid}", {"review_required": False}, token)
        assert project["review_required"] is False, project

        sheet = reprocess(api, token, pid, hub, args.timeout)
        assert [s["id"] for s in sheet["scenes"]] == ids, "id строк изменились после перезапуска"
        s1 = sheet["scenes"][1]
        assert (s1["description"], s1["shot_type"]) == ("Правка e2e", "close"), s1
        print("перезапуск: строки и правки на месте")

        s0 = sheet["scenes"][0]
        mid = (s0["start_ms"] + s0["end_ms"]) // 2
        sheet = call("POST", f"{api}/projects/{pid}/scenes/{s0['id']}/split",
                     {"row_version": s0["row_version"], "at_ms": mid}, token)
        assert len(sheet["scenes"]) == len(ids) + 1 and sheet["structure_edited"], sheet
        assert sheet["scenes"][1]["origin"] == "user" and sheet["scenes"][1]["start_ms"] == mid, sheet

        sheet = reprocess(api, token, pid, hub, args.timeout)
        assert len(sheet["scenes"]) == len(ids) + 1, "повторная детекция затёрла split"
        assert sheet["scenes"][2]["description"] == "Правка e2e", sheet["scenes"][2]
        print("split и перезапуск: структура пользователя сохранена")

        a, b = sheet["scenes"][0], sheet["scenes"][1]
        sheet = call("POST", f"{api}/projects/{pid}/scenes/{a['id']}/merge",
                     {"row_version": a["row_version"], "next_row_version": b["row_version"]}, token)
        assert len(sheet["scenes"]) == len(ids) and sheet["scenes"][0]["end_ms"] == b["end_ms"], sheet
        print("merge: OK")
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
