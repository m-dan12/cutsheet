"""Сквозная проверка этапа 1 через Kong, как это делает клиент.

Регистрация → JWT → проект → multipart-загрузка видео по presigned URL прямо в MinIO →
complete → статус по SignalR (WebSocket через Kong) → список сцен с ключевыми кадрами.

    python tools/e2e_api.py tools/sample.mp4
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
import uuid
from pathlib import Path

from websockets.sync.client import connect

RS = "\x1e"  # разделитель сообщений протокола SignalR


def call(method: str, url: str, body: dict | None = None, token: str | None = None,
         expect: int | tuple[int, ...] = (200, 201)) -> dict | list | None:
    req = urllib.request.Request(url, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            status, raw = resp.status, resp.read()
    except urllib.error.HTTPError as e:
        status, raw = e.code, e.read()
    expected = (expect,) if isinstance(expect, int) else expect
    if status not in expected:
        raise SystemExit(f"{method} {url}: HTTP {status}, ждали {expected}: {raw[:500]!r}")
    return json.loads(raw) if raw else None


def put_part(url: str, data: bytes) -> str:
    req = urllib.request.Request(url, method="PUT", data=data)
    with urllib.request.urlopen(req, timeout=120) as resp:
        return resp.headers["ETag"]


class Hub:
    """Минимальный клиент SignalR (JSON-протокол) поверх WebSocket без negotiate."""

    def __init__(self, ws):
        self.ws = ws
        self.ws.send(json.dumps({"protocol": "json", "version": 1}) + RS)
        handshake = self._frames(self.ws.recv(timeout=30))[0]
        if handshake.get("error"):
            raise SystemExit(f"SignalR handshake: {handshake['error']}")
        self._buffer: list[dict] = []
        self._invocation = 0

    @staticmethod
    def _frames(raw: str | bytes) -> list[dict]:
        text = raw.decode() if isinstance(raw, bytes) else raw
        return [json.loads(f) for f in text.split(RS) if f]

    def invoke(self, target: str, *args) -> object:
        self._invocation += 1
        inv = str(self._invocation)
        self.ws.send(json.dumps({"type": 1, "invocationId": inv, "target": target, "arguments": list(args)}) + RS)
        while True:
            for m in self._frames(self.ws.recv(timeout=30)):
                if m.get("type") == 3 and m.get("invocationId") == inv:
                    if m.get("error"):
                        raise SystemExit(f"{target}: {m['error']}")
                    return m.get("result")
                self._buffer.append(m)

    def messages(self, timeout: float):
        deadline = time.time() + timeout
        while time.time() < deadline:
            while self._buffer:
                yield self._buffer.pop(0)
            try:
                raw = self.ws.recv(timeout=max(0.1, deadline - time.time()))
            except TimeoutError:
                return
            self._buffer.extend(self._frames(raw))



def wait_scenes_done(hub: Hub, timeout: float) -> bool:
    for m in hub.messages(timeout):
        if m.get("type") != 1 or m.get("target") != "status":
            continue
        status = m["arguments"][0]
        print(f"status: {status['stage']}/{status['status']}")
        if status["status"] == "failed":
            print(f"ошибка пайплайна: {status.get('error')}")
            return False
        if status["stage"] == "scenes" and status["status"] == "done":
            return True
    print("timeout: нет статуса scenes/done")
    return False


def upload_video(api: str, token: str, pid: str, video: Path) -> None:
    size = video.stat().st_size
    upload = call("POST", f"{api}/projects/{pid}/uploads",
                  {"kind": "video", "filename": video.name, "size_bytes": size, "content_type": "video/mp4"},
                  token)
    with video.open("rb") as f:
        for part in upload["parts"]:
            f.seek((part["part_number"] - 1) * upload["part_size"])
            put_part(part["url"], f.read(upload["part_size"]))
    state = call("GET", f"{api}/projects/{pid}/uploads/{upload['upload_id']}", token=token)
    assert len(state["uploaded_parts"]) == upload["part_count"] and not state["parts"], state
    call("POST", f"{api}/projects/{pid}/uploads/{upload['upload_id']}/complete", token=token)
    print(f"видео {size} байт загружено в {upload['part_count']} ч., video.uploaded опубликован")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("video", type=Path)
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--timeout", type=float, default=300)
    args = ap.parse_args()
    api = f"{args.base}/api/v1"

    # Kong стартует после Auth; ждём, пока маршруты отвечают.
    deadline = time.time() + 120
    while True:
        try:
            call("GET", f"{api}/health")
            break
        except (urllib.error.URLError, ConnectionError, SystemExit):
            if time.time() > deadline:
                raise
            time.sleep(2)

    call("GET", f"{api}/projects", expect=401)
    print("без токена: 401")

    email = f"e2e-{uuid.uuid4().hex[:8]}@example.com"
    tokens = call("POST", f"{api}/auth/register", {"email": email, "password": "e2e-password"})
    call("POST", f"{api}/auth/register", {"email": email, "password": "e2e-password"}, expect=409)
    call("POST", f"{api}/auth/login", {"email": email, "password": "wrong-password"}, expect=401)
    tokens = call("POST", f"{api}/auth/refresh", {"refresh_token": tokens["refresh_token"]})
    call("POST", f"{api}/auth/refresh", {"refresh_token": "nope"}, expect=401)
    jwks = call("GET", f"{api}/auth/.well-known/jwks.json")
    assert jwks["keys"] and jwks["keys"][0]["kty"] == "RSA", jwks
    token = tokens["access_token"]
    print(f"пользователь {email}: register, refresh, jwks OK")

    project = call("POST", f"{api}/projects", {"name": "e2e"}, token)
    pid = project["id"]
    assert any(p["id"] == pid for p in call("GET", f"{api}/projects", token=token))
    print(f"проект {pid}")

    ws_base = args.base.replace("http", "ws", 1)
    with connect(f"{ws_base}/hubs/projects?access_token={token}", open_timeout=30) as ws:
        hub = Hub(ws)
        assert hub.invoke("Subscribe", pid) is True
        assert hub.invoke("Subscribe", str(uuid.uuid4())) is False  # чужой/несуществующий проект
        print("SignalR через Kong: подписка OK")
        upload_video(api, token, pid, args.video)
        if not wait_scenes_done(hub, args.timeout):
            return 1

    sheet = call("GET", f"{api}/projects/{pid}/scenes", token=token)
    scenes = sheet["scenes"]
    assert scenes, sheet
    print(f"сцены: fps={sheet['fps']} duration_ms={sheet['duration_ms']}")
    for s in scenes:
        print(f"  #{s['index']}: {s['start_ms']}–{s['end_ms']} ms, {len(s['keyframe_urls'])} кадров")
    with urllib.request.urlopen(scenes[0]["keyframe_urls"][0], timeout=30) as resp:
        assert resp.status == 200 and resp.read(3) == b"\xff\xd8\xff", "ключевой кадр не JPEG"
    assert call("GET", f"{api}/projects/{pid}", token=token)["status"] == "done"

    other = call("POST", f"{api}/auth/register", {"email": f"x-{email}", "password": "e2e-password"})
    call("GET", f"{api}/projects/{pid}/scenes", token=other["access_token"], expect=404)
    print("чужой проект: 404")
    print("OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
