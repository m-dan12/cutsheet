namespace Cutsheet.Aggregator.Enrichment;

/// <summary>Периодически помечает зависшее обогащение неудачным (FR-A6).</summary>
public sealed class EnrichmentTimeouts(EnrichmentCollector collector, IConfiguration config,
    ILogger<EnrichmentTimeouts> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var timeout = TimeSpan.FromMinutes(config.GetValue("Enrichment:TimeoutMinutes", 30.0));
        var period = TimeSpan.FromSeconds(config.GetValue("Enrichment:CheckSeconds", 30.0));
        log.LogInformation("enrichment timeout {Timeout} without results, check every {Period}", timeout, period);
        using var timer = new PeriodicTimer(period);
        while (await timer.WaitForNextTickAsync(ct))
        {
            try { await collector.ExpireAsync(timeout, ct); }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex) { log.LogError(ex, "enrichment timeout check failed"); }
        }
    }
}
