const std = @import("std");
const platform = @import("platform.zig");
const registry = @import("providers.zig");
const models_dev = @import("models_dev.zig");
const auth = @import("auth.zig");
const config = @import("config.zig");
const types = @import("types.zig");
const http = @import("http.zig");

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

fn entryNpm(entry: ?*const models_dev.Model) ?[]const u8 {
    const e = entry orelse return null;
    const pr = e.provider orelse return null;
    return pr.npm;
}

fn npmWire(npm: ?[]const u8) ?[]const u8 {
    const value = npm orelse return null;
    if (std.mem.eql(u8, value, "@ai-sdk/openai-compatible")) return "openai-completions";
    if (std.mem.eql(u8, value, "@ai-sdk/openai")) return "openai-responses";
    if (std.mem.eql(u8, value, "@ai-sdk/anthropic")) return "anthropic-messages";
    if (std.mem.eql(u8, value, "@ai-sdk/google")) return "google-generative-ai";
    return null;
}

const BuiltinAuth = struct {
    api_key: ?[]const u8 = null,
    ok: bool = false,
};

fn builtinAuth(a: std.mem.Allocator, p: *const registry.Provider) BuiltinAuth {
    if (p.oauth) |oauth| {
        const access = auth.accessToken(a, &oauth, null) orelse return .{};
        return .{ .api_key = access, .ok = true };
    }
    const key = firstEnv(p.env_keys) orelse return .{};
    return .{ .api_key = key, .ok = true };
}

// Subscription credentials rotate and expire, so the credential for a request
// is resolved when the request is made, not when its model was resolved.
pub fn resolveCredentials(a: std.mem.Allocator, model: *types.Model, cancel: ?auth.Cancel) void {
    const p = registry.find(model.provider) orelse return;
    const oauth = p.oauth orelse return;
    model.api_key = auth.accessToken(a, &oauth, cancel);
}

fn builtinModel(a: std.mem.Allocator, cfg: *const config.Config, p: *const registry.Provider, id: []const u8) types.Model {
    const catalog = models_dev.get();
    const dev_id = p.models_dev_id orelse p.id;
    const entry = if (catalog) |c| c.model(dev_id, id) else null;
    const dev_provider = if (catalog) |c| c.provider(dev_id) else null;
    const model_npm = entryNpm(entry);
    const provider_npm = if (dev_provider) |pr| pr.npm else null;
    const credentials = builtinAuth(a, p);
    const effort = if (entry) |e| models_dev.effort(a, e) else &.{};
    const reasoning = if (entry) |e| e.reasoning else false;
    return .{
        .id = id,
        .name = if (entry) |e| e.name orelse id else id,
        .api = npmWire(model_npm) orelse npmWire(provider_npm) orelse p.api,
        .provider = p.id,
        .base_url = p.base_url,
        .api_key = credentials.api_key,
        .effort = clampEffort(reasoning, effort, cfg.thinking_effort),
        .supports_images = if (entry) |e| e.attachment else false,
        .context_window = if (entry) |e| e.limit.context else 0,
        .max_tokens = if (entry) |e| e.limit.output else 0,
        .sends_max_output = p.sends_max_output,
        .cost_input = if (entry) |e| e.cost.input else 0,
        .cost_output = if (entry) |e| e.cost.output else 0,
        .cost_cache_read = if (entry) |e| e.cost.cache_read else 0,
        .session_header = p.session_header,
    };
}

fn customModel(a: std.mem.Allocator, p: *const config.CustomProvider, m: config.CustomModel, cfg: *const config.Config) types.Model {
    return .{
        .id = m.id,
        .name = m.name orelse m.id,
        .api = @tagName(m.api),
        .provider = p.id,
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

fn headerPairs(a: std.mem.Allocator, headers: ?std.json.ArrayHashMap([]const u8)) []const [2][]const u8 {
    const h = headers orelse return &.{};
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = h.map.iterator();
    while (it.next()) |e| out.append(a, .{ e.key_ptr.*, e.value_ptr.* }) catch {};
    return out.toOwnedSlice(a) catch &.{};
}

pub fn resolve(a: std.mem.Allocator, cfg: *const config.Config, err: *?[]const u8) ?types.Model {
    const provider_id = cfg.provider orelse return null;
    const model_id = cfg.model orelse return null;
    return resolveNamed(a, cfg, provider_id, model_id, err);
}

pub fn resolveNamed(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8, err: *?[]const u8) ?types.Model {
    if (registry.find(provider_id)) |p| return builtinModel(a, cfg, p, model_id);
    if (custom(cfg, provider_id)) |p| {
        for (p.models) |m| {
            if (std.mem.eql(u8, m.id, model_id)) return customModel(a, p, m, cfg);
        }
        err.* = unknownModel(a, model_id, provider_id);
        return null;
    }
    err.* = std.fmt.allocPrint(a, "unknown provider \"{s}\"", .{provider_id}) catch "unknown provider";
    return null;
}

pub const ProviderEntry = struct {
    id: []const u8,
    name: []const u8,
    available: bool,
    oauth: bool,
};

pub fn providers(a: std.mem.Allocator, cfg: *const config.Config) []ProviderEntry {
    var out: std.ArrayList(ProviderEntry) = .empty;
    for (&registry.builtins) |*p| {
        out.append(a, .{
            .id = p.id,
            .name = p.name,
            .available = if (p.oauth != null) auth.available(a) else firstEnv(p.env_keys) != null,
            .oauth = p.oauth != null,
        }) catch {};
    }
    for (cfg.custom_providers) |p| {
        out.append(a, .{
            .id = p.id,
            .name = p.name orelse p.id,
            .available = p.envKeys.len == 0 or firstEnv(p.envKeys) != null,
            .oauth = false,
        }) catch {};
    }
    return out.toOwnedSlice(a) catch &.{};
}

pub const ModelList = struct {
    models: []types.Model = &.{},
    err: ?[]const u8 = null,
};

pub fn listModels(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8) ModelList {
    if (registry.find(provider_id)) |p| {
        const url = p.listing orelse return .{ .err = "provider has no model listing" };
        const credentials = builtinAuth(a, p);
        if (!credentials.ok) return .{ .err = "provider is not authenticated" };
        var err: ?[]const u8 = null;
        const listed = fetchListing(a, credentials, url, p.client_version, &err) catch return .{ .err = err };
        var out: std.ArrayList(types.Model) = .empty;
        for (listed) |entry| {
            var model = builtinModel(a, cfg, p, entry.id);
            if (entry.name) |name| model.name = name;
            out.append(a, model) catch {};
        }
        return .{ .models = out.toOwnedSlice(a) catch &.{} };
    }
    if (custom(cfg, provider_id)) |p| {
        var out: std.ArrayList(types.Model) = .empty;
        for (p.models) |m| out.append(a, customModel(a, p, m, cfg)) catch {};
        return .{ .models = out.toOwnedSlice(a) catch &.{} };
    }
    return .{ .err = std.fmt.allocPrint(a, "unknown provider \"{s}\"", .{provider_id}) catch "unknown provider" };
}

const Entry = struct {
    id: ?[]const u8 = null,
    slug: ?[]const u8 = null,
    display_name: ?[]const u8 = null,
    visibility: ?[]const u8 = null,

    // Only models the account is meant to pick from carry this visibility.
    fn listed(self: Entry) bool {
        const v = self.visibility orelse return false;
        return std.mem.eql(u8, v, "list");
    }
};
const Listing = struct {
    data: ?[]const Entry = null,
    models: ?[]const Entry = null,
};

const Listed = struct { id: []const u8, name: ?[]const u8 = null };

fn fetchListing(a: std.mem.Allocator, credentials: BuiltinAuth, url: []const u8, client_version: ?[]const u8, err: *?[]const u8) ![]const Listed {
    const target = if (client_version) |version|
        try std.fmt.allocPrint(a, "{s}?client_version={s}", .{ url, version })
    else
        url;
    var headers: std.ArrayList(http.Header) = .empty;
    headers.append(a, .{ .name = "accept", .value = "application/json" }) catch return error.OutOfMemory;
    if (credentials.api_key) |key| {
        headers.append(a, .{ .name = "Authorization", .value = try std.fmt.allocPrint(a, "Bearer {s}", .{key}) }) catch return error.OutOfMemory;
    }
    var err_body: ?[]const u8 = null;
    const text = http.fetch(a, .GET, target, headers.items, null, &err_body, null) catch |e| {
        err.* = switch (e) {
            error.HttpStatus => err_body orelse "model listing returned an error status",
            error.OutOfMemory => "out of memory",
            else => "model listing request failed",
        };
        return e;
    };
    const listing = std.json.parseFromSliceLeaky(Listing, a, text, .{ .ignore_unknown_fields = true }) catch {
        err.* = "model listing: invalid JSON";
        return error.InvalidResponse;
    };
    var out: std.ArrayList(Listed) = .empty;
    for (listing.data orelse &.{}) |entry| {
        if (entry.id) |id| out.append(a, .{ .id = id, .name = entry.display_name }) catch {};
    }
    for (listing.models orelse &.{}) |entry| {
        if (!entry.listed()) continue;
        const slug = entry.slug orelse entry.id orelse continue;
        out.append(a, .{ .id = slug, .name = entry.display_name }) catch {};
    }
    return out.toOwnedSlice(a) catch &.{};
}

pub fn supportedLevels(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8) []const []const u8 {
    if (registry.find(provider_id)) |p| {
        const catalog = models_dev.get() orelse return &ladder;
        const entry = catalog.model(p.models_dev_id orelse p.id, model_id) orelse return &ladder;
        if (!entry.reasoning) return &.{"off"};
        const effort = models_dev.effort(a, entry);
        return if (effort.len == 0) &ladder else effort;
    }
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

pub fn clampNamed(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8, desired: []const u8) []const u8 {
    if (registry.find(provider_id)) |p| {
        const catalog = models_dev.get() orelse return desired;
        const entry = catalog.model(p.models_dev_id orelse p.id, model_id) orelse return desired;
        return clampEffort(entry.reasoning, models_dev.effort(a, entry), desired);
    }
    if (custom(cfg, provider_id)) |p| {
        for (p.models) |m| {
            if (std.mem.eql(u8, m.id, model_id)) return clampEffort(m.reasoning, m.effort, desired);
        }
    }
    return desired;
}

fn unknownModel(a: std.mem.Allocator, model_id: []const u8, provider_id: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "unknown model \"{s}\" for provider \"{s}\"", .{ model_id, provider_id }) catch "unknown model";
}
