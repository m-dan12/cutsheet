"""Метрики, /health и передача traceparent через заголовки Kafka (этап 6)."""

import json
import socket
import urllib.request

from cutsheet_common import observability as obs
from cutsheet_common.bus import KafkaBus

from test_bus_retries import FakeProducer, detected, uploaded


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_metrics_and_health_endpoints():
    health = obs.Health("scene-detection")
    port = free_port()
    server = obs.serve(health, port)
    try:
        bus = KafkaBus("scene-detection", producer=FakeProducer(), sleep=lambda s: None)
        bus.process("video.uploaded", uploaded(), detected)
        metrics = urllib.request.urlopen(f"http://127.0.0.1:{port}/metrics").read().decode()
        assert 'cutsheet_events_consumed_total{outcome="ok",service="scene-detection",topic="video.uploaded"}' \
            in metrics
        assert "cutsheet_handler_duration_seconds_bucket" in metrics

        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/health")
            raise AssertionError("stopped consumer must not be healthy")
        except urllib.error.HTTPError as e:
            assert e.code == 503
        health.running = True
        body = json.loads(urllib.request.urlopen(f"http://127.0.0.1:{port}/health").read())
        assert body["status"] == "ok" and body["service"] == "scene-detection"
    finally:
        server.shutdown()


def test_trace_context_flows_from_consumed_to_published_event(monkeypatch):
    from opentelemetry import trace
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import SimpleSpanProcessor
    from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    monkeypatch.setattr(obs, "_tracer", provider.get_tracer("test"))

    parent = "00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01"
    producer = FakeProducer()
    bus = KafkaBus("scene-detection", producer=producer, sleep=lambda s: None)
    bus.process("video.uploaded", uploaded(), detected, headers=[("traceparent", parent.encode())])

    [out] = producer.sent
    assert out["headers"]["traceparent"].split("-")[1] == "0af7651916cd43dd8448eb211c80319c"
    spans = {s.name: s for s in exporter.get_finished_spans()}
    assert spans["video.uploaded process"].kind == trace.SpanKind.CONSUMER
    assert spans["scenes.detected publish"].parent.span_id == spans["video.uploaded process"].context.span_id
