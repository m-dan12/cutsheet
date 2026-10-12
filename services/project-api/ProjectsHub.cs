using System.Security.Claims;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.SignalR;

namespace Cutsheet.ProjectApi;

/// <summary>
/// SignalR-хаб статусов (FR-G1, FR-G8). Клиент вызывает Subscribe(projectId) и получает
/// сообщения "status" по этому проекту.
/// </summary>
[Authorize]
public sealed class ProjectsHub(ProjectStore projects) : Hub
{
    public const string Path = "/hubs/projects";

    public static string Group(Guid projectId) => $"project:{projectId}";

    public async Task<bool> Subscribe(Guid projectId)
    {
        var owner = Context.User!.UserId();
        if (await projects.Get(projectId, owner, Context.ConnectionAborted) is null) return false;
        await Groups.AddToGroupAsync(Context.ConnectionId, Group(projectId));
        return true;
    }

    public Task Unsubscribe(Guid projectId) => Groups.RemoveFromGroupAsync(Context.ConnectionId, Group(projectId));
}

/// <summary>Сообщение "status" в хабе: тот же payload, что у project.status-changed.</summary>
public sealed record StatusMessage(Guid ProjectId, string Stage, string Status, double? Progress, string? Error);

public static class ClaimsExtensions
{
    /// <summary>owner_id из JWT (claim sub, FR-G9).</summary>
    public static Guid UserId(this ClaimsPrincipal user) =>
        Guid.Parse(user.FindFirstValue("sub") ?? throw new InvalidOperationException("no sub claim"));
}
