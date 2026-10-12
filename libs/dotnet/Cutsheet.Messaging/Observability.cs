using System.Diagnostics;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;
using Prometheus;

namespace Cutsheet.Messaging;

/// <summary>
/// Наблюдаемость C#-сервисов (ТЗ 7, этап 6): JSON-логи со scope project_id/correlation_id,
/// метрики Prometheus на /metrics (имена общие с Python-сервисами), трейсинг OpenTelemetry.
/// Трейсинг включается, только если задан OTEL_EXPORTER_OTLP_ENDPOINT (Jaeger в профиле observability).
/// </summary>
public static class Observability
{
    public const string ActivitySourceName = "Cutsheet.Messaging";
    internal static readonly ActivitySource Source = new(ActivitySourceName);

    public static readonly Counter EventsConsumed = Metrics.CreateCounter(
        "cutsheet_events_consumed_total", "Прочитанные события по исходу обработки",
        "service", "topic", "outcome");
    public static readonly Counter EventsPublished = Metrics.CreateCounter(
        "cutsheet_events_published_total", "Опубликованные события", "service", "topic");
    public static readonly Counter HandlerRetries = Metrics.CreateCounter(
        "cutsheet_handler_retries_total", "Повторы обработки события", "service", "topic");
    public static readonly Counter DlqMessages = Metrics.CreateCounter(
        "cutsheet_dlq_messages_total", "Сообщения, отправленные в <topic>.dlq", "service", "topic", "reason");
    public static readonly Histogram HandlerDuration = Metrics.CreateHistogram(
        "cutsheet_handler_duration_seconds", "Длительность обработки события (этапа) сервисом",
        new HistogramConfiguration
        {
            LabelNames = ["service", "event_type"],
            Buckets = [0.005, 0.025, 0.1, 0.5, 1, 5, 15, 60, 300],
        });

    public static WebApplicationBuilder AddCutsheetObservability(this WebApplicationBuilder builder, string service)
    {
        builder.Logging.ClearProviders();
        builder.Logging.AddJsonConsole(o =>
        {
            o.IncludeScopes = true;
            o.UseUtcTimestamp = true;
            o.TimestampFormat = "yyyy-MM-ddTHH:mm:ss.fffZ";
        });

        if (!string.IsNullOrEmpty(builder.Configuration["OTEL_EXPORTER_OTLP_ENDPOINT"]))
        {
            builder.Services.AddOpenTelemetry()
                .ConfigureResource(r => r.AddService(service))
                .WithTracing(t => t
                    .AddSource(ActivitySourceName)
                    .AddAspNetCoreInstrumentation(o => o.Filter = ctx => !IsProbe(ctx.Request.Path))
                    .AddHttpClientInstrumentation()
                    .AddOtlpExporter()); // адрес и протокол — из OTEL_EXPORTER_OTLP_*
        }
        return builder;
    }

    /// <summary>Метрики HTTP и /metrics. Вызывать сразу после Build(), до аутентификации.</summary>
    public static WebApplication UseCutsheetObservability(this WebApplication app)
    {
        app.UseRouting();
        app.UseHttpMetrics();
        app.MapMetrics();
        return app;
    }

    private static bool IsProbe(PathString path) =>
        path.StartsWithSegments("/metrics") || path.StartsWithSegments("/health");
}
