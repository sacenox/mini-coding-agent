const std = @import("std");
const platform = @import("platform.zig");
const modelsdev = @import("models_dev.zig");
const http = @import("http.zig");
const config = @import("config.zig");

pub const Thinking = enum { off, budget, effort };

pub const Model = struct {
    id: []const u8,
    api: []const u8,
    provider: []const u8,
    base_url: []const u8,
    api_key: ?[]const u8,
    effort: []const u8,
    supports_images: bool,
    context_window: u64,
    max_tokens: u64,
    cost_input: f64,
    cost_output: f64,
    cost_cache_read: f64,
    session_header: ?[]const u8,
    headers: []const [2][]const u8 = &.{},
    thinking: Thinking = .budget,
};

/// A built-in provider is one whose models.dev entry the agent knows how to
/// request: name, environment keys, API root and models all come from the
/// document.
const Builtin = struct {
    id: []const u8,
    session_header: ?[]const u8 = null,
};

const builtins = [_]Builtin{
    .{ .id = "opencode", .session_header = "x-opencode-session" },
    .{ .id = "opencode-go", .session_header = "x-opencode-session" },
    .{ .id = "openrouter" },
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

fn clampEffort(reasoning: bool, effort: []const []const u8, desired: ?[]const u8) []const u8 {
    const want = desired orelse return "";
    if (!reasoning) return "off";
    if (effort.len == 0) return want;
    for (effort) |accepted| {
        if (std.mem.eql(u8, normalizeEffort(accepted), want)) return normalizeEffort(accepted);
    }
    const want_rank = rank(want);
    if (want_rank < 0) return normalizeEffort(effort[0]);

    var up: ?[]const u8 = null;
    var down: ?[]const u8 = null;
    for (effort) |accepted| {
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

fn thinkingStyle(info: modelsdev.Info) Thinking {
    if (!info.reasoning) return .off;
    if (info.budget_tokens) return .budget;
    if (info.effort.len > 0) return .effort;
    return .budget;
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

pub fn resolve(a: std.mem.Allocator, cfg: *const config.Config, err: *?[]const u8) ?Model {
    const provider_id = cfg.provider orelse return null;
    const model_id = cfg.model orelse return null;
    return resolveNamed(a, cfg, provider_id, model_id, err);
}

pub fn resolveNamed(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8, err: *?[]const u8) ?Model {
    if (builtin(provider_id)) |b| {
        var db = modelsdev.Db.open(a) catch {
            err.* = "model metadata unavailable";
            return null;
        };
        const p = db.provider(provider_id) orelse {
            err.* = unknownProvider(a, provider_id);
            return null;
        };
        const info = db.info(provider_id, model_id) orelse {
            err.* = unknownModel(a, model_id, provider_id);
            return null;
        };
        return Model{
            .id = model_id,
            .api = info.api,
            .provider = provider_id,
            .base_url = info.base_url,
            .api_key = firstEnv(p.env),
            .effort = clampEffort(info.reasoning, info.effort, cfg.thinking_effort),
            .supports_images = info.images,
            .context_window = info.context,
            .max_tokens = info.max_output,
            .thinking = thinkingStyle(info),
            .cost_input = info.cost_input,
            .cost_output = info.cost_output,
            .cost_cache_read = info.cost_cache_read,
            .session_header = b.session_header,
        };
    }

    if (custom(cfg, provider_id)) |p| {
        for (p.models) |m| {
            if (!std.mem.eql(u8, m.id, model_id)) continue;
            return Model{
                .id = m.id,
                .api = @tagName(m.api),
                .provider = provider_id,
                .base_url = m.baseUrl,
                .api_key = firstEnv(p.envKeys),
                .effort = clampEffort(m.reasoning, m.effort, cfg.thinking_effort),
                .supports_images = m.images,
                .context_window = m.context,
                .max_tokens = m.maxOutput,
                .cost_input = m.cost[0],
                .cost_output = m.cost[1],
                .cost_cache_read = m.cost[2],
                .session_header = null,
                .headers = headerPairs(a, p.headers),
            };
        }
        err.* = unknownModel(a, model_id, provider_id);
        return null;
    }

    err.* = unknownProvider(a, provider_id);
    return null;
}

fn headerPairs(a: std.mem.Allocator, headers: ?std.json.ArrayHashMap([]const u8)) []const [2][]const u8 {
    const h = headers orelse return &.{};
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = h.map.iterator();
    while (it.next()) |e| out.append(a, .{ e.key_ptr.*, e.value_ptr.* }) catch {};
    return out.toOwnedSlice(a) catch &.{};
}

const ProviderEntry = struct { id: []const u8, name: []const u8, ready: bool };

/// A built-in provider is usable when its first environment key is present.
fn usable(p: modelsdev.Provider) bool {
    return firstEnv(p.env) != null;
}

pub fn providers(a: std.mem.Allocator, cfg: *const config.Config) []ProviderEntry {
    var out: std.ArrayList(ProviderEntry) = .empty;
    var db: ?modelsdev.Db = modelsdev.Db.open(a) catch null;
    for (builtins) |b| {
        // Name, environment keys and every model fact come from the document.
        const p = (if (db) |*d| d.provider(b.id) else null) orelse continue;
        out.append(a, .{
            .id = b.id,
            .name = if (p.name.len > 0) p.name else b.id,
            .ready = usable(p),
        }) catch {};
    }
    for (cfg.custom_providers) |p| {
        out.append(a, .{ .id = p.id, .name = p.name orelse p.id, .ready = p.envKeys.len == 0 or firstEnv(p.envKeys) != null }) catch {};
    }
    return out.toOwnedSlice(a) catch &.{};
}

pub const Entry = struct { id: []const u8, name: []const u8 };

/// The models a provider offers. Built-ins are asked over the wire
/// (authenticated, so the provider decides what is enabled); a model with no
/// models.dev metadata is skipped. Custom providers list what they declare.
pub fn listing(
    a: std.mem.Allocator,
    cfg: *const config.Config,
    provider_id: []const u8,
    cancel: *const std.atomic.Value(bool),
) ![]Entry {
    if (custom(cfg, provider_id)) |p| return customListing(a, p);
    if (builtin(provider_id) == null) return error.UnknownProvider;
    var db = modelsdev.Db.open(a) catch return error.ModelMetadataUnavailable;
    const p = db.provider(provider_id) orelse return error.UnknownProvider;
    const base = db.baseUrl(provider_id) orelse return error.UnknownProvider;
    const key = firstEnv(p.env) orelse return error.MissingApiKey;

    const url = try std.fmt.allocPrint(a, "{s}/models", .{base});
    const authorization = try std.fmt.allocPrint(a, "Bearer {s}", .{key});
    const body = try http.get(a, url, &.{.{ .name = "Authorization", .value = authorization }}, cancel, .{});

    const parsed = try std.json.parseFromSliceLeaky(Listed, a, body, .{ .ignore_unknown_fields = true });
    var out: std.ArrayList(Entry) = .empty;
    for (parsed.data orelse &.{}) |item| {
        const id = item.id orelse continue;
        const info = db.info(provider_id, id) orelse continue;
        try out.append(a, .{ .id = id, .name = info.name });
    }
    const items = try out.toOwnedSlice(a);
    std.mem.sort(Entry, items, {}, entryLess);
    return items;
}

/// The model list shape of an OpenAI-compatible gateway: `data[].id`.
const Listed = struct {
    data: ?[]const Item = null,

    const Item = struct {
        id: ?[]const u8 = null,
    };
};

fn entryLess(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn customListing(a: std.mem.Allocator, p: *const config.CustomProvider) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (p.models) |m| try out.append(a, .{ .id = m.id, .name = m.name orelse m.id });
    const items = try out.toOwnedSlice(a);
    std.mem.sort(Entry, items, {}, entryLess);
    return items;
}

pub fn supportedLevels(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8) []const []const u8 {
    if (builtin(provider_id) == null) {
        if (custom(cfg, provider_id)) |p| {
            for (p.models) |m| {
                if (!std.mem.eql(u8, m.id, model_id)) continue;
                if (!m.reasoning) return &.{"off"};
                if (m.effort.len == 0) return &ladder;
                return m.effort;
            }
        }
        return &ladder;
    }
    var db = modelsdev.Db.open(a) catch return &ladder;
    const info = db.info(provider_id, model_id) orelse return &ladder;
    if (!info.reasoning) return &.{"off"};
    if (info.effort.len == 0) return &ladder;
    return info.effort;
}

pub fn clampNamed(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8, desired: []const u8) []const u8 {
    if (builtin(provider_id) == null) {
        if (custom(cfg, provider_id)) |p| {
            for (p.models) |m| {
                if (std.mem.eql(u8, m.id, model_id)) return clampEffort(m.reasoning, m.effort, desired);
            }
        }
        return desired;
    }
    var db = modelsdev.Db.open(a) catch return desired;
    const info = db.info(provider_id, model_id) orelse return desired;
    return clampEffort(info.reasoning, info.effort, desired);
}

fn unknownModel(a: std.mem.Allocator, model_id: []const u8, provider_id: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "unknown model \"{s}\" for provider \"{s}\"", .{ model_id, provider_id }) catch "unknown model";
}

fn unknownProvider(a: std.mem.Allocator, provider_id: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "unknown provider \"{s}\"", .{provider_id}) catch "unknown provider";
}
