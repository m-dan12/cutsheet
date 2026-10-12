"""Наблюдаемость Python-сервисов (ТЗ 7, этап 6): метрики Prometheus, /health, трейсинг.

- Метрики и /health отдаёт маленький HTTP-сервер на METRICS_PORT (по умолчанию 9100),
  его опрашивает Prometheus (deploy/observability/prometheus.yml).
- Трейсинг OpenTelemetry включается, только если задан OTEL_EXPORTER_OTLP_ENDPOINT
  (в compose — Jaeger из профиля observability). Контекст трейса идёт между сервисами
  в заголовке Kafka `traceparent` (W3C), поэтому один ролик виден в Jaeger одной цепочкой
  от Project API до Aggregator.
"""

from __future__ import annotations

import json
import logging
import os
import threading
import time
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable, Iterator

from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

log = logging.getLogger("cutsheet.observability")

# ---------- метрики (одинаковые имена у Python и C#-сервисов) ----------

EVENTS_CONSUMED = Counter(
    "cutsheet_events_consumed_total", "Прочитанные события по исходу обработки",
    ["service", "topic", "outcome"])  # outcome: ok | duplicate | failed | invalid
EVENTS_PUBLISHED = Counter("cutsheet_events_published_total", "Опубликованные события", ["service", "topic"])
HANDLER_RETRIES = Counter("cutsheet_handler_retries_total", "Повторы обработки события", ["service", "topic"])
DLQ_MESSAGES = Counter("cutsheet_dlq_messages_total", "Сообщения, отправленные в <topic>.dlq",
                       ["service", "topic", "reason"])
# Детекция и транскрибация длинного фильма идут десятки минут: корзины до двух часов.
HANDLER_DURATION = Histogram(
    "cutsheet_handler_duration_seconds", "Длительность обработки события (этапа) сервисом",
    ["service", "event_type"],
    buckets=(0.05, 0.25, 1, 5, 15, 30, 60, 120, 300, 600, 1200, 2400, 3600, 7200))


# ---------- /health и /metrics ----------

class Health:
    """Состояние цикла чтения: жив ли он и чем занят (долгий обработчик — это норма, не зависание)."""

    def __init__(self, service: str):
        self.service = service
        self.started = time.time()
        self.running = False
        self.busy_with: str | None = None
        self.busy_since: float | None = None
        self.last_poll: float | None = None

    def snapshot(self) -> dict[str, Any]:
        now = time.time()
        return {
            "service": self.service,
            "status": "ok" if self.running else "stopped",
            "uptime_s": round(now - self.started),
            "busy_with": self.busy_with,
            "busy_s": round(now - self.busy_since) if self.busy_since else None,
            "last_poll_s_ago": round(now - self.last_poll) if self.last_poll else None,
        }


def serve(health: Health, port: int | None = None) -> ThreadingHTTPServer | None:
    """Запускает HTTP-сервер /metrics и /health в фоновом потоке. METRICS_PORT=0 — выключен."""
    port = int(os.environ.get("METRICS_PORT", "9100")) if port is None else port
    if port == 0:
        return None

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802 — имя задаёт http.server
            if self.path == "/metrics":
                body, ctype, code = generate_latest(), CONTENT_TYPE_LATEST, 200
            elif self.path == "/health":
                snap = health.snapshot()
                body = json.dumps(snap).encode()
                ctype, code = "application/json", 200 if snap["status"] == "ok" else 503
            else:
                body, ctype, code = b"not found", "text/plain", 404
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_: Any) -> None:  # опрос Prometheus не засоряет лог
            pass

    server = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    threading.Thread(target=server.serve_forever, name="metrics", daemon=True).start()
    log.info("metrics and health on :%d", port)
    return server


# ---------- трейсинг ----------

_tracer: Any = None


def init_tracing(service: str) -> bool:
    """Включает OpenTelemetry, если задан OTEL_EXPORTER_OTLP_ENDPOINT. Возвращает, включён ли он."""
    global _tracer
    endpoint = os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not endpoint:
        return False
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    provider = TracerProvider(resource=Resource.create({"service.name": service}))
    provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))  # endpoint берёт из окружения
    trace.set_tracer_provider(provider)
    _tracer = trace.get_tracer("cutsheet")
    log.info("tracing to %s", endpoint)
    return True


Headers = list[tuple[str, bytes]]


@contextmanager
def span(name: str, *, kind: str, headers: Headers | None = None,
         attributes: dict[str, Any] | None = None) -> Iterator[None]:
    """Спан обработки (kind=consumer, родитель — traceparent из заголовков) или публикации (producer)."""
    if _tracer is None:
        yield
        return
    from opentelemetry import propagate
    from opentelemetry.trace import SpanKind, Status, StatusCode

    ctx = None
    if headers:
        carrier = {k: v.decode("latin-1") for k, v in headers if isinstance(v, bytes)}
        ctx = propagate.extract(carrier)
    with _tracer.start_as_current_span(name, context=ctx, kind=getattr(SpanKind, kind.upper()),
                                       attributes={k: v for k, v in (attributes or {}).items() if v is not None},
                                       record_exception=True, set_status_on_exception=True) as s:
        try:
            yield
        except Exception as e:
            s.set_status(Status(StatusCode.ERROR, str(e)[:200]))
            raise


def trace_headers() -> Headers:
    """Заголовки Kafka с контекстом текущего спана (traceparent)."""
    if _tracer is None:
        return []
    from opentelemetry import propagate

    carrier: dict[str, str] = {}
    propagate.inject(carrier)
    return [(k, v.encode("latin-1")) for k, v in carrier.items()]


def timed(service: str, event_type: str) -> Callable[[], None]:
    """Начинает замер длительности этапа; вызов результата записывает его в гистограмму."""
    started = time.monotonic()
    return lambda: HANDLER_DURATION.labels(service, event_type).observe(time.monotonic() - started)
