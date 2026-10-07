const std = @import("std");
const platform = @import("platform.zig");
const catalog = @import("catalog.zig");
const config = @import("config.zig");
const types = @import("types.zig");

const Builtin = struct {
    id: []const u8,
    env_keys: []const []const u8,
    session_header: ?[]const u8,
};

const builtins = [_]Builtin{
    .{
        .id = "opencode-go",
        .env_keys = &.{"OPENCODE_API_KEY"},
        .session_header = "x-opencode-session",
    },
    .{
        .id = "opencode",
        .env_keys = &.{"OPENCODE_API_KEY"},
        .session_header = "x-opencode-session",
    },
};

const ladder = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max" };

fn rank(value: []const u8) i32 {
    for (ladder, 0..) |level, i| {
        if (std.mem.eql(u8, level, value)) return @intCast(i);
    }
    return -1;
}

fn normalizeEffort(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "none")) "off" else value;
}

fn clampEffort(info: *const catalog.ModelInfo, desired: ?[]const u8) []const u8 {
    const want = desired orelse return "";
    if (!info.reasoning) return "off";
    if (info.effort.len == 0) return want;
    for (info.effort) |accepted| {
        if (std.mem.eql(u8, normalizeEffort(accepted), want)) return normalizeEffort(accepted);
    }
    const want_rank = rank(want);
    if (want_rank < 0) return normalizeEffort(info.effort[0]);

    var up: ?[]const u8 = null;
    var down: ?[]const u8 = null;
    for (info.effort) |accepted| {
        const r = rank(normalizeEffort(accepted));
        if (r < 0) continue;
        if (r >= want_rank) {
            if (up == null or r < rank(up.?)) up = accepted;
        } else if (down == null or r > rank(down.?)) {
            down = accepted;
        }
    }
    const pick = up orelse down orelse return "off";
    return normalizeEffort(pick);
}

fn builtin(id: []const u8) ?*const Builtin {
    for (&builtins) |*b| {
        if (std.mem.eql(u8, b.id, id)) return b;
    }
    return null;
}

fn custom(cfg: *const config.Config, id: []const u8) ?*const config.CustomProvider {
    for (cfg.custom_providers) |*p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

fn firstEnv(keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (platform.getEnv(key)) |value| {
            if (value.len > 0) return value;
        }
    }
    return null;
}

pub fn resolve(a: std.mem.Allocator, cfg: *const config.Config, err: *?[]const u8) ?types.Model {
    const provider_id = cfg.provider orelse return null;
    const model_id = cfg.model orelse return null;
    return resolveNamed(a, cfg, provider_id, model_id, err);
}

pub fn resolveNamed(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8, err: *?[]const u8) ?types.Model {
    if (builtin(provider_id)) |b| {
        const info = catalog.lookup(provider_id, model_id) orelse {
            err.* = unknownModel(a, model_id, provider_id);
            return null;
        };
        return types.Model{
            .id = model_id,
            .name = info.name,
            .api = info.api,
            .provider = provider_id,
            .base_url = info.base_url,
            .api_key = firstEnv(b.env_keys),
            .effort = clampEffort(info, cfg.thinking_effort),
            .supports_images = info.images,
            .context_window = info.context,
            .max_tokens = info.max_output,
            .cost_input = info.cost_input,
            .cost_output = info.cost_output,
            .cost_cache_read = info.cost_cache_read,
            .session_header = b.session_header,
        };
    }

    if (custom(cfg, provider_id)) |p| {
        var listed = false;
        for (p.models) |id| {
            if (std.mem.eql(u8, id, model_id)) listed = true;
        }
        if (!listed) {
            err.* = unknownModel(a, model_id, provider_id);
            return null;
        }
        return types.Model{
            .id = model_id,
            .name = model_id,
            .api = @tagName(p.api),
            .provider = provider_id,
            .base_url = p.baseUrl,
            .api_key = firstEnv(p.envKeys),
            .effort = cfg.thinking_effort orelse "",
            .supports_images = true,
            .context_window = 200_000,
            .max_tokens = 32_768,
            .cost_input = 0,
            .cost_output = 0,
            .cost_cache_read = 0,
            .session_header = null,
            .headers = headerPairs(a, p.headers),
        };
    }

    err.* = std.fmt.allocPrint(a, "unknown provider \"{s}\"", .{provider_id}) catch "unknown provider";
    return null;
}

fn headerPairs(a: std.mem.Allocator, headers: ?std.json.ArrayHashMap([]const u8)) []const [2][]const u8 {
    const h = headers orelse return &.{};
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = h.map.iterator();
    while (it.next()) |e| out.append(a, .{ e.key_ptr.*, e.value_ptr.* }) catch {};
    return out.toOwnedSlice(a) catch &.{};
}

const ProviderEntry = struct { id: []const u8, name: []const u8, key_present: bool };

pub fn providers(a: std.mem.Allocator, cfg: *const config.Config) []ProviderEntry {
    var out: std.ArrayList(ProviderEntry) = .empty;
    for (builtins) |b| {
        out.append(a, .{ .id = b.id, .name = b.id, .key_present = firstEnv(b.env_keys) != null }) catch {};
    }
    for (cfg.custom_providers) |p| {
        out.append(a, .{ .id = p.id, .name = p.name orelse p.id, .key_present = p.envKeys.len == 0 or firstEnv(p.envKeys) != null }) catch {};
    }
    return out.toOwnedSlice(a) catch &.{};
}

pub fn catalogModels(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8) ![]types.Model {
    var out: std.ArrayList(types.Model) = .empty;
    for (&catalog.entries) |*entry| {
        if (!std.mem.eql(u8, entry.provider, provider_id)) continue;
        var err: ?[]const u8 = null;
        if (resolveNamed(a, cfg, provider_id, entry.id, &err)) |m| try out.append(a, m);
    }
    if (custom(cfg, provider_id)) |p| {
        for (p.models) |id| {
            var err: ?[]const u8 = null;
            if (resolveNamed(a, cfg, provider_id, id, &err)) |m| try out.append(a, m);
        }
    }
    return out.toOwnedSlice(a);
}

pub fn supportedLevels(provider_id: []const u8, model_id: []const u8) []const []const u8 {
    if (builtin(provider_id) == null) return &ladder;
    const info = catalog.lookup(provider_id, model_id) orelse return &ladder;
    if (!info.reasoning) return &.{"off"};
    if (info.effort.len == 0) return &ladder;
    return info.effort;
}

pub fn clampNamed(provider_id: []const u8, model_id: []const u8, desired: []const u8) []const u8 {
    if (builtin(provider_id) == null) return desired;
    const info = catalog.lookup(provider_id, model_id) orelse return desired;
    return clampEffort(info, desired);
}

fn unknownModel(a: std.mem.Allocator, model_id: []const u8, provider_id: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "unknown model \"{s}\" for provider \"{s}\"", .{ model_id, provider_id }) catch "unknown model";
}
