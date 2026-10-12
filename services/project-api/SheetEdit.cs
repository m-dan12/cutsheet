using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using static Cutsheet.ProjectApi.SheetFields;

namespace Cutsheet.ProjectApi;

/// <summary>
/// Одна правка листа внутри транзакции <see cref="SheetStore.Edit"/>. Любое изменённое поле
/// помечается в user_edits (ТЗ 6.2); если новое значение совпало с авто-значением, метка снимается.
/// Каждая изменённая строка получает row_version + 1.
/// </summary>
public sealed class SheetEdit
{
    private readonly NpgsqlConnection _conn;
    private readonly NpgsqlTransaction _tx;
    private readonly Guid _project;
    private readonly Guid _user;
    private readonly long? _duration;
    private readonly SheetData _sheet;
    private readonly CancellationToken _ct;

    internal SheetEdit(NpgsqlConnection conn, NpgsqlTransaction tx, Guid project, Guid user, long? duration,
        SheetData sheet, CancellationToken ct)
    {
        (_conn, _tx, _project, _user, _duration, _sheet, _ct) = (conn, tx, project, user, duration, sheet, ct);
    }

    private List<SheetScene> Scenes => _sheet.Scenes;

    private SheetScene? Find(Guid id) => Scenes.FirstOrDefault(s => s.Id == id);

    private SheetScene? Neighbor(SheetScene s, int delta) => Scenes.FirstOrDefault(x => x.Index == s.Index + delta);

    // ---------- PATCH /scenes/{id} ----------

    /// <summary>
    /// Правка ячеек строки: start_ms, end_ms, shot_type, description; reset — вернуть поля к
    /// авто-значению (FR-C9). Сдвиг общей границы двигает и соседнюю сцену, чтобы лист шёл без дыр.
    /// </summary>
    public async Task<EditOutcome> PatchSceneAsync(Guid sceneId, JsonElement body)
    {
        if (Find(sceneId) is not { } s) return new EditOutcome.NotFound();
        if (CheckVersion(body, "row_version", s) is { } bad) return bad;

        var errors = new Dictionary<string, string[]>();
        var values = new Dictionary<string, object?>();
        var reset = new List<string>();
        if (body.TryGetProperty("reset", out var resetJson))
        {
            if (resetJson.ValueKind != JsonValueKind.Array
                || resetJson.EnumerateArray().Any(f => f.ValueKind != JsonValueKind.String
                    || f.GetString() is not (StartMs or EndMs or ShotType or Description)))
                errors["reset"] = ["список из start_ms, end_ms, shot_type, description"];
            else
                foreach (var f in resetJson.EnumerateArray())
                {
                    var field = f.GetString()!;
                    reset.Add(field);
                    if (AutoOf(s.Id, field, s.Auto) is { } auto) values[field] = Scalar(auto);
                }
        }

        if (body.TryGetProperty(ShotType, out var shot))
        {
            if (shot.ValueKind == JsonValueKind.Null) values[ShotType] = null;
            else if (shot.ValueKind == JsonValueKind.String && ShotTypes.Contains(shot.GetString()))
                values[ShotType] = shot.GetString();
            else errors[ShotType] = [$"одно из: {string.Join(", ", ShotTypes)}"];
        }
        if (body.TryGetProperty(Description, out var desc))
        {
            if (desc.ValueKind == JsonValueKind.Null) values[Description] = null;
            else if (desc.ValueKind != JsonValueKind.String) errors[Description] = ["строка или null"];
            else
            {
                var text = desc.GetString()!.Trim();
                if (text.Length > MaxDescription) errors[Description] = [$"не длиннее {MaxDescription} символов"];
                else values[Description] = text.Length == 0 ? null : text;
            }
        }
        foreach (var field in new[] { StartMs, EndMs })
        {
            if (!body.TryGetProperty(field, out var ms)) continue;
            if (ms.ValueKind == JsonValueKind.Number && ms.TryGetInt64(out var v) && v >= 0) values[field] = v;
            else errors[field] = ["целое число миллисекунд ≥ 0"];
        }
        if (errors.Count > 0) return new EditOutcome.Invalid(errors);

        var start = values.TryGetValue(StartMs, out var st) ? (long)st! : s.StartMs;
        var end = values.TryGetValue(EndMs, out var en) ? (long)en! : s.EndMs;
        if (start >= end) return new EditOutcome.Invalid(EndMs, "конец сцены должен быть позже начала");
        if (_duration is { } d && end > d) return new EditOutcome.Invalid(EndMs, "конец сцены за пределами видео");

        // Соседи с общей границей сдвигаются вместе с ней; через соседа перескочить нельзя.
        var changed = new List<Guid> { s.Id };
        var prev = Neighbor(s, -1);
        var next = Neighbor(s, +1);
        var prevEnd = (long?)null;
        var nextStart = (long?)null;
        if (start != s.StartMs && prev is not null)
        {
            if (prev.EndMs == s.StartMs)
            {
                if (start <= prev.StartMs) return new EditOutcome.Invalid(StartMs, "начало заходит за начало предыдущей сцены");
                prevEnd = start;
            }
            else if (start < prev.EndMs) return new EditOutcome.Invalid(StartMs, "начало заходит на предыдущую сцену");
        }
        if (end != s.EndMs && next is not null)
        {
            if (next.StartMs == s.EndMs)
            {
                if (end >= next.EndMs) return new EditOutcome.Invalid(EndMs, "конец заходит за конец следующей сцены");
                nextStart = end;
            }
            else if (end > next.StartMs) return new EditOutcome.Invalid(EndMs, "конец заходит на следующую сцену");
        }

        var bounds = start != s.StartMs || end != s.EndMs;
        await UpdateSceneAsync(s, values, bounds);
        if (prevEnd is { } pe)
        {
            await UpdateSceneAsync(prev!, new() { [EndMs] = pe }, true);
            changed.Add(prev!.Id);
        }
        if (nextStart is { } ns)
        {
            await UpdateSceneAsync(next!, new() { [StartMs] = ns }, true);
            changed.Add(next!.Id);
        }
        // Сброс снимает метку, даже если авто-значения нет (поле очищено).
        foreach (var field in reset)
            await ExecAsync("DELETE FROM user_edits WHERE scene_id = @id AND field = @f", ("id", s.Id), ("f", field));
        return new EditOutcome.Changed(changed, bounds);
    }

    // ---------- PUT /scenes/{id}/replicas ----------

    /// <summary>
    /// Реплики строки целиком (FR-C5): порядок списка — порядок в сцене; элемент без id — новая
    /// реплика; id реплики из другой сцены — перенос; отсутствующие — удаление. Удалённая авто-реплика
    /// остаётся меткой, чтобы повторный join её не вернул.
    /// </summary>
    public async Task<EditOutcome> PutReplicasAsync(Guid sceneId, JsonElement body)
    {
        if (Find(sceneId) is not { } s) return new EditOutcome.NotFound();
        if (CheckVersion(body, "row_version", s) is { } bad) return bad;
        if (!body.TryGetProperty("replicas", out var items) || items.ValueKind != JsonValueKind.Array)
            return new EditOutcome.Invalid("replicas", "обязательный список реплик");

        var all = Scenes.SelectMany(x => x.Replicas).ToDictionary(r => r.Id);
        var errors = new Dictionary<string, string[]>();
        var parsed = new List<(ReplicaRow? Existing, string Text, string? Role, long? Start, long? End)>();
        var seen = new HashSet<Guid>();
        var i = 0;
        foreach (var item in items.EnumerateArray())
        {
            var key = $"replicas[{i++}]";
            if (item.ValueKind != JsonValueKind.Object) { errors[key] = ["объект"]; continue; }
            ReplicaRow? existing = null;
            if (item.TryGetProperty("id", out var idJson) && idJson.ValueKind != JsonValueKind.Null)
            {
                if (!idJson.TryGetGuid(out var id) || !all.TryGetValue(id, out existing) || !seen.Add(id))
                {
                    errors[$"{key}.id"] = ["реплика не найдена в проекте или повторяется"];
                    continue;
                }
            }

            var resetFields = item.TryGetProperty("reset", out var rj) && rj.ValueKind == JsonValueKind.Array
                ? rj.EnumerateArray().Select(f => f.GetString()).ToHashSet()
                : [];
            string? text = null;
            if (existing is not null && resetFields.Contains(Text) && AutoOf(existing.Id, Text) is { } autoText)
                text = autoText.GetString();
            else if (item.TryGetProperty(Text, out var tj) && tj.ValueKind == JsonValueKind.String)
                text = tj.GetString()!.Trim();
            else if (existing is not null && !item.TryGetProperty(Text, out _))
                text = existing.Text;
            if (string.IsNullOrEmpty(text) || text.Length > MaxReplicaText)
            {
                errors[$"{key}.text"] = [$"от 1 до {MaxReplicaText} символов"];
                continue;
            }

            string? role;
            if (existing is not null && resetFields.Contains(Role) && AutoOf(existing.Id, Role) is { } autoRole)
                role = autoRole.ValueKind == JsonValueKind.String ? autoRole.GetString() : null;
            else if (item.TryGetProperty(Role, out var roleJson))
            {
                role = roleJson.ValueKind == JsonValueKind.String ? roleJson.GetString()!.Trim() : null;
                if (roleJson.ValueKind is not (JsonValueKind.String or JsonValueKind.Null) || role?.Length > MaxRoleName)
                {
                    errors[$"{key}.role"] = [$"строка до {MaxRoleName} символов или null"];
                    continue;
                }
                if (role?.Length == 0) role = null;
            }
            else role = existing?.Role;

            long? Ms(string name) => item.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number
                && v.TryGetInt64(out var ms) && ms >= 0 ? ms : null;
            parsed.Add((existing, text, role, Ms(StartMs), Ms(EndMs)));
        }
        if (errors.Count > 0) return new EditOutcome.Invalid(errors);

        var changed = new List<Guid> { s.Id };
        foreach (var gone in s.Replicas.Where(r => !seen.Contains(r.Id)))
        {
            if (gone.Origin == "user")
                await ExecAsync("DELETE FROM replicas WHERE id = @id", ("id", gone.Id));
            else
            {
                await ExecAsync("UPDATE replicas SET deleted = true WHERE id = @id", ("id", gone.Id));
                await MarkAsync(replica: true, gone.Id, Deleted, false, true);
            }
        }

        var prevEnd = s.StartMs;
        for (var idx = 0; idx < parsed.Count; idx++)
        {
            var (existing, text, role, startMs, endMs) = parsed[idx];
            var roleId = role is null ? (object)DBNull.Value : await RoleIdAsync(role);
            if (existing is null)
            {
                var start = startMs ?? prevEnd;
                var end = Math.Max(start, endMs ?? Math.Min(start + 2000, Math.Max(s.EndMs, start)));
                await ExecAsync("""
                    INSERT INTO replicas (id, scene_id, idx, start_ms, end_ms, role_id, text, matched, origin)
                    VALUES (@id, @s, @idx, @start, @end, @role, @text, false, 'user')
                    """, ("id", Guid.NewGuid()), ("s", s.Id), ("idx", idx), ("start", start), ("end", end),
                    ("role", roleId), ("text", text));
                prevEnd = end;
                continue;
            }

            if (existing.SceneId != s.Id)
            {
                await MarkAsync(replica: true, existing.Id, SheetFields.SceneId, existing.SceneId, s.Id);
                if (!changed.Contains(existing.SceneId)) changed.Add(existing.SceneId);
            }
            if (text != existing.Text) await MarkAsync(replica: true, existing.Id, Text, existing.Text, text);
            if (role != existing.Role) await MarkAsync(replica: true, existing.Id, Role, existing.Role, role);
            await ExecAsync("UPDATE replicas SET scene_id = @s, idx = @idx, text = @text, role_id = @role WHERE id = @id",
                ("s", s.Id), ("idx", idx), ("text", text), ("role", roleId), ("id", existing.Id));
            prevEnd = existing.EndMs;
        }

        await ExecAsync("UPDATE scenes SET row_version = row_version + 1 WHERE id = ANY(@ids)", ("ids", changed.ToArray()));
        return new EditOutcome.Changed(changed, false);
    }

    // ---------- split / merge / delete / add (FR-C6) ----------

    /// <summary>Делит сцену по таймкоду at_ms: первая часть сохраняет id, вторая — новая строка.</summary>
    public async Task<EditOutcome> SplitAsync(Guid sceneId, JsonElement body)
    {
        if (Find(sceneId) is not { } s) return new EditOutcome.NotFound();
        if (CheckVersion(body, "row_version", s) is { } bad) return bad;
        if (!body.TryGetProperty("at_ms", out var atJson) || !atJson.TryGetInt64(out var at)
            || at <= s.StartMs || at >= s.EndMs)
            return new EditOutcome.Invalid("at_ms", "таймкод внутри сцены");

        var newId = Guid.NewGuid();
        await ExecAsync("""
            INSERT INTO scenes (id, project_id, idx, start_ms, end_ms, shot_type, description, status, origin,
                                needs_enrichment)
            VALUES (@id, @p, (SELECT max(idx) + 1 FROM scenes WHERE project_id = @p), @start, @end, @shot, @desc,
                    @status, 'user', true)
            """, ("id", newId), ("p", _project), ("start", at), ("end", s.EndMs), ("shot", Db(s.ShotType)),
            ("desc", Db(s.Description)), ("status", s.Status));
        await UpdateSceneAsync(s, new() { [EndMs] = at }, true);
        // Правки плана и описания переходят на обе половины.
        await ExecAsync("""
            INSERT INTO user_edits (id, scene_id, field, value, auto_value, user_id)
            SELECT gen_random_uuid(), @new, field, value, auto_value, user_id FROM user_edits
            WHERE scene_id = @s AND field IN ('shot_type', 'description')
            """, ("new", newId), ("s", s.Id));
        await ExecAsync("UPDATE replicas SET scene_id = @new WHERE scene_id = @s AND (start_ms + end_ms) / 2 >= @at",
            ("new", newId), ("s", s.Id), ("at", at));
        return new EditOutcome.Changed([s.Id, newId], true);
    }

    /// <summary>Объединяет сцену со следующей: реплики и кадры переходят в первую, описания склеиваются.</summary>
    public async Task<EditOutcome> MergeAsync(Guid sceneId, JsonElement body)
    {
        if (Find(sceneId) is not { } s) return new EditOutcome.NotFound();
        if (CheckVersion(body, "row_version", s) is { } bad) return bad;
        if (Neighbor(s, +1) is not { } next) return new EditOutcome.Invalid("scene_id", "это последняя сцена");
        if (CheckVersion(body, "next_row_version", next) is { } badNext) return badNext;

        var description = string.Join(" ", new[] { s.Description, next.Description }.Where(t => !string.IsNullOrEmpty(t)));
        await UpdateSceneAsync(s, new()
        {
            [EndMs] = next.EndMs,
            [ShotType] = s.ShotType ?? next.ShotType,
            [Description] = description.Length == 0 ? null : description,
        }, true);
        await ExecAsync("""
            UPDATE replicas SET scene_id = @s, idx = idx + (SELECT COALESCE(max(idx) + 1, 0) FROM replicas WHERE scene_id = @s)
            WHERE scene_id = @next
            """, ("s", s.Id), ("next", next.Id));
        await ExecAsync("""
            UPDATE scene_keyframes
               SET scene_id = @s, position = position + (SELECT COALESCE(max(position) + 1, 0) FROM scene_keyframes WHERE scene_id = @s)
            WHERE scene_id = @next
            """, ("s", s.Id), ("next", next.Id));
        await ExecAsync("DELETE FROM scenes WHERE id = @id", ("id", next.Id));
        return new EditOutcome.Changed([s.Id], true);
    }

    public async Task<EditOutcome> DeleteAsync(Guid sceneId, int? rowVersion)
    {
        if (Find(sceneId) is not { } s) return new EditOutcome.NotFound();
        if (rowVersion is null) return new EditOutcome.Invalid("row_version", "обязательно");
        if (rowVersion != s.RowVersion) return new EditOutcome.Conflict(s);
        await ExecAsync("DELETE FROM scenes WHERE id = @id", ("id", s.Id));
        return new EditOutcome.Changed([], true);
    }

    /// <summary>Добавляет сцену вручную в свободный промежуток (например, после удаления).</summary>
    public async Task<EditOutcome> AddAsync(JsonElement body)
    {
        if (!body.TryGetProperty(StartMs, out var sj) || !sj.TryGetInt64(out var start) || start < 0
            || !body.TryGetProperty(EndMs, out var ej) || !ej.TryGetInt64(out var end) || end <= start)
            return new EditOutcome.Invalid(EndMs, "нужны start_ms ≥ 0 и end_ms > start_ms");
        if (_duration is { } d && end > d) return new EditOutcome.Invalid(EndMs, "конец сцены за пределами видео");
        if (Scenes.Any(x => x.StartMs < end && start < x.EndMs))
            return new EditOutcome.Invalid(StartMs, "промежуток пересекается с другой сценой");

        var id = Guid.NewGuid();
        await ExecAsync("""
            INSERT INTO scenes (id, project_id, idx, start_ms, end_ms, origin, needs_enrichment)
            VALUES (@id, @p, (SELECT COALESCE(max(idx) + 1, 0) FROM scenes WHERE project_id = @p), @start, @end, 'user', true)
            """, ("id", id), ("p", _project), ("start", start), ("end", end));
        return new EditOutcome.Changed([id], true);
    }

    /// <summary>
    /// Структура листа теперь принадлежит человеку: повторная детекция её не трогает. Номера строк
    /// пересчитываются по времени (через отрицательные значения: UNIQUE (project_id, idx) проверяется построчно).
    /// </summary>
    internal async Task MarkStructureEditedAsync()
    {
        await ExecAsync("UPDATE scenes SET idx = -idx - 1 WHERE project_id = @p", ("p", _project));
        await ExecAsync("""
            UPDATE scenes s SET idx = o.rn - 1
            FROM (SELECT id, row_number() OVER (ORDER BY start_ms, id) AS rn FROM scenes WHERE project_id = @p) o
            WHERE s.id = o.id
            """, ("p", _project));
        await ExecAsync("UPDATE projects SET structure_edited = true, updated_at = now() WHERE id = @p", ("p", _project));
    }

    // ---------- общее ----------

    private static EditOutcome? CheckVersion(JsonElement body, string name, SheetScene s)
    {
        if (!body.TryGetProperty(name, out var v) || !v.TryGetInt32(out var version))
            return new EditOutcome.Invalid(name, "обязательно: версия строки из последнего чтения");
        return version == s.RowVersion ? null : new EditOutcome.Conflict(s);
    }

    /// <summary>Авто-значение поля: свежий результат обогащения, иначе значение до первой правки.</summary>
    private JsonElement? AutoOf(Guid id, string field, Dictionary<string, AutoValue>? sceneAuto = null)
    {
        if (sceneAuto is not null && sceneAuto.TryGetValue(field, out var auto)) return auto.Value;
        return _sheet.EditAuto.TryGetValue((id, field), out var before) ? before : null;
    }

    private static object? Scalar(JsonElement v) => v.ValueKind switch
    {
        JsonValueKind.String => v.GetString(),
        JsonValueKind.Number => v.GetInt64(),
        _ => null,
    };

    private async Task UpdateSceneAsync(SheetScene s, Dictionary<string, object?> values, bool boundsChanged)
    {
        var current = new Dictionary<string, object?>
        {
            [StartMs] = s.StartMs, [EndMs] = s.EndMs, [ShotType] = s.ShotType, [Description] = s.Description,
        };
        var sets = new List<string> { "row_version = row_version + 1" };
        if (boundsChanged) sets.Add("needs_enrichment = true");
        var args = new List<(string, object)> { ("id", s.Id) };
        foreach (var (field, value) in values)
        {
            if (Equals(current[field], value)) continue;
            sets.Add($"{field} = @{field}");
            args.Add((field, Db(value)));
            await MarkAsync(replica: false, s.Id, field, current[field], value);
        }
        await ExecAsync($"UPDATE scenes SET {string.Join(", ", sets)} WHERE id = @id", [.. args]);
    }

    /// <summary>
    /// Отмечает поле как изменённое человеком. auto_value — значение до первой правки — сохраняется
    /// только при первой правке. Если новое значение совпало с авто-значением, метка снимается.
    /// </summary>
    private async Task MarkAsync(bool replica, Guid id, string field, object? before, object? after)
    {
        var column = replica ? "replica_id" : "scene_id";
        await ExecAsync($"""
            INSERT INTO user_edits (id, {column}, field, value, auto_value, user_id)
            VALUES (gen_random_uuid(), @id, @f, @v, @auto, @u)
            ON CONFLICT ({column}, field) WHERE {column} IS NOT NULL
            DO UPDATE SET value = excluded.value, user_id = excluded.user_id, updated_at = now()
            """, ("id", id), ("f", field), ("v", Jsonb(after)), ("auto", Jsonb(before)), ("u", _user));
        var auto = replica
            ? "u.auto_value"
            : "COALESCE((SELECT a.value FROM scene_auto_values a WHERE a.scene_id = u.scene_id AND a.field = u.field), u.auto_value)";
        await ExecAsync($"DELETE FROM user_edits u WHERE u.{column} = @id AND u.field = @f AND u.value = {auto}",
            ("id", id), ("f", field));
    }

    private async Task<Guid> RoleIdAsync(string name)
    {
        await ExecAsync("INSERT INTO roles (id, project_id, name) VALUES (@id, @p, @n) ON CONFLICT (project_id, name) DO NOTHING",
            ("id", Guid.NewGuid()), ("p", _project), ("n", name));
        await using var cmd = Command("SELECT id FROM roles WHERE project_id = @p AND name = @n", ("p", _project), ("n", name));
        return (Guid)(await cmd.ExecuteScalarAsync(_ct))!;
    }

    private static object Db(object? v) => v ?? DBNull.Value;

    private static NpgsqlParameter Jsonb(object? v) =>
        new() { NpgsqlDbType = NpgsqlDbType.Jsonb, Value = JsonSerializer.Serialize(v) };

    private NpgsqlCommand Command(string sql, params (string Name, object Value)[] args)
    {
        var cmd = new NpgsqlCommand(sql, _conn, _tx);
        foreach (var (name, value) in args)
        {
            if (value is NpgsqlParameter prm) { prm.ParameterName = name; cmd.Parameters.Add(prm); }
            else cmd.Parameters.AddWithValue(name, value);
        }
        return cmd;
    }

    private async Task ExecAsync(string sql, params (string, object)[] args)
    {
        await using var cmd = Command(sql, args);
        await cmd.ExecuteNonQueryAsync(_ct);
    }
}
