"""Подмена LLM в тестах: OpenAI-совместимый сервер в памяти, без сети и модели."""

from __future__ import annotations

import json
from typing import Any, Callable

import httpx

from .client import LLMClient
from .config import LLMConfig

Reply = str | int | Callable[[dict[str, Any]], str]


class FakeLLMServer:
    """Отвечает по очереди из `replies`: строка — content ответа, int — HTTP-код ошибки,
    функция — получает тело запроса и возвращает content. Запросы сохраняются в `requests`."""

    def __init__(self, replies: list[Reply] | Callable[[dict[str, Any]], str]):
        self.replies = replies
        self.requests: list[dict[str, Any]] = []

    def _handle(self, request: httpx.Request) -> httpx.Response:
        body = json.loads(request.content)
        self.requests.append(body)
        reply = self.replies(body) if callable(self.replies) else self.replies.pop(0)
        if callable(reply):
            reply = reply(body)
        if isinstance(reply, int):
            return httpx.Response(reply, json={"error": {"message": "fake error"}})
        return httpx.Response(200, json={
            "choices": [{"index": 0, "message": {"role": "assistant", "content": reply}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15},
        })

    def client(self, **config: Any) -> LLMClient:
        cfg = LLMConfig(**{"base_url": "http://fake-llm/v1", "model": "fake", "backoff_s": 0, **config})
        return LLMClient(cfg, transport=httpx.MockTransport(self._handle), sleep=lambda _: None)
