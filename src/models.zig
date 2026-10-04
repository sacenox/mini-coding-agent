//! Built-in provider table and model resolution.

const std = @import("std");
const platform = @import("platform.zig");
const catalog = @import("catalog.zig");
const config = @import("config.zig");
const types = @import("types.zig");

/// A provider whose wire details are compiled in. The catalog carries the
/// per-model metadata; this carries where and how the provider is reached.
const Builtin = struct {
    id: []const u8,
    base_url: []const u8,
    api: []const u8,
    env_keys: []const []const u8,
    session_header: ?[]const u8,
};

const builtins = [_]Builtin{
    .{
        .id = "opencode-go",
        .base_url = "https://opencode.ai/zen/go/v1",
        .api = "openai-completions",
        .env_keys = &.{"OPENCODE_API_KEY"},
        .session_header = "x-opencode-session",
    },
    .{
        .id = "opencode",
        .base_url = "https://opencode.ai/zen/v1",
        .api = "openai-completions",
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

/// Clamps a desired effort to what the model accepts, preferring the next
/// higher level, then the next lower. An unset desire means no reasoning
/// parameter is sent, so the provider decides. A non-reasoning model runs
/// "off".
fn clampEffort(info: *const catalog.ModelInfo, desired: ?[]const u8) []const u8 {
    const want = desired orelse return "";
    if (!info.reasoning) return "off";
    if (info.effort.len == 0) return want;
    for (info.effort) |accepted| {
        if (std.mem.eql(u8, normalizeEffort(accepted), want)) return normalizeEffort(accepted);
    }
    const r0 = rank(want);
    if (r0 < 0) return normalizeEffort(info.effort[0]);
    var r: i32 = r0;
    while (r <= 6) : (r += 1) {
        for (info.effort) |accepted| {
            if (rank(normalizeEffort(accepted)) == r) return normalizeEffort(accepted);
        }
    }
    r = r0 - 1;
    while (r >= 0) : (r -= 1) {
        for (info.effort) |accepted| {
            if (rank(normalizeEffort(accepted)) == r) return normalizeEffort(accepted);
        }
    }
    return "off";
}

fn firstEnv(keys: []const []const u8) ?[]const u8 {
    for (keys) |key| {
        if (platform.getEnv(key)) |value| {
            if (value.len > 0) return value;
        }
    }
    return null;
}

/// Resolves the configured provider and model. Returns null when either is
/// unset; otherwise `err` carries a message the caller surfaces as-is.
pub fn resolve(a: std.mem.Allocator, cfg: *const config.Config, err: *?[]const u8) ?types.Model {
    const provider_id = cfg.provider orelse return null;
    const model_id = cfg.model orelse return null;
    return resolveNamed(a, cfg, provider_id, model_id, err);
}

/// Resolves one named provider and model, clamped to what the catalog says the
/// model accepts. `err` carries a message when the pair is unknown.
pub fn resolveNamed(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8, model_id: []const u8, err: *?[]const u8) ?types.Model {
    for (builtins) |b| {
        if (!std.mem.eql(u8, b.id, provider_id)) continue;
        const info = catalog.lookup(b.id, model_id);
        return types.Model{
            .id = model_id,
            .name = if (info) |i| i.name else model_id,
            .api = b.api,
            .provider = provider_id,
            .base_url = b.base_url,
            .api_key = firstEnv(b.env_keys),
            .effort = if (info) |i| clampEffort(i, cfg.thinking_effort) else cfg.thinking_effort orelse "",
            .supports_images = if (info) |i| i.images else true,
            .context_window = if (info) |i| i.context else 0,
            .max_tokens = if (info) |i| i.max_output else 0,
            .cost_input = if (info) |i| i.cost_input else 0,
            .cost_output = if (info) |i| i.cost_output else 0,
            .cost_cache_read = if (info) |i| i.cost_cache_read else 0,
            .session_header = b.session_header,
        };
    }

    for (cfg.custom_providers) |p| {
        if (!std.mem.eql(u8, p.id, provider_id)) continue;
        var listed = false;
        for (p.models) |id| {
            if (std.mem.eql(u8, id, model_id)) listed = true;
        }
        if (!listed) {
            err.* = std.fmt.allocPrint(a, "unknown model \"{s}\" for provider \"{s}\"", .{ model_id, provider_id }) catch "unknown model";
            return null;
        }
        return types.Model{
            .id = model_id,
            .name = model_id,
            .api = p.api,
            .provider = provider_id,
            .base_url = p.base_url,
            .api_key = firstEnv(p.env_keys),
            .effort = cfg.thinking_effort orelse "",
            // Custom providers are uncatalogued; assume image input. A model
            // that rejects images surfaces the provider error as-is.
            .supports_images = true,
            .context_window = 200_000,
            .max_tokens = 32_768,
            .cost_input = 0,
            .cost_output = 0,
            .cost_cache_read = 0,
            .session_header = null,
            .headers = p.headers,
        };
    }

    err.* = std.fmt.allocPrint(a, "unknown provider \"{s}\"", .{provider_id}) catch "unknown provider";
    return null;
}

/// A provider the TUI can offer in `/provider`. `key_present` is only a hint;
/// a provider without a key is listed but will fail at request time as-is.
pub const ProviderEntry = struct { id: []const u8, name: []const u8, key_present: bool };

/// The built-in providers plus any custom provider in the config.
pub fn providers(a: std.mem.Allocator, cfg: *const config.Config) []ProviderEntry {
    var out: std.ArrayList(ProviderEntry) = .empty;
    for (builtins) |b| {
        out.append(a, .{ .id = b.id, .name = b.id, .key_present = firstEnv(b.env_keys) != null }) catch {};
    }
    for (cfg.custom_providers) |p| {
        out.append(a, .{ .id = p.id, .name = p.name orelse p.id, .key_present = p.env_keys.len == 0 or firstEnv(p.env_keys) != null }) catch {};
    }
    return out.toOwnedSlice(a) catch &.{};
}

/// Every model a provider offers: the catalog entries for a built-in, the
/// declared ids for a custom provider.
pub fn catalogModels(a: std.mem.Allocator, cfg: *const config.Config, provider_id: []const u8) []types.Model {
    var out: std.ArrayList(types.Model) = .empty;
    for (builtins) |b| {
        if (!std.mem.eql(u8, b.id, provider_id)) continue;
        for (&catalog.entries) |*entry| {
            if (!std.mem.eql(u8, entry.provider, b.id)) continue;
            var err: ?[]const u8 = null;
            if (resolveNamed(a, cfg, provider_id, entry.id, &err)) |m| out.append(a, m) catch {};
        }
        return out.toOwnedSlice(a) catch &.{};
    }
    for (cfg.custom_providers) |p| {
        if (!std.mem.eql(u8, p.id, provider_id)) continue;
        for (p.models) |id| {
            var err: ?[]const u8 = null;
            if (resolveNamed(a, cfg, provider_id, id, &err)) |m| out.append(a, m) catch {};
        }
        return out.toOwnedSlice(a) catch &.{};
    }
    return out.toOwnedSlice(a) catch &.{};
}

/// The thinking levels a model accepts, in ladder order.
pub fn supportedLevels(provider_id: []const u8, model_id: []const u8) []const []const u8 {
    for (builtins) |b| {
        if (!std.mem.eql(u8, b.id, provider_id)) continue;
        const info = catalog.lookup(b.id, model_id) orelse return &ladder;
        // A model that does not reason runs "off" and offers nothing else,
        // matching what `clampEffort` will send.
        if (!info.reasoning) return &.{"off"};
        if (info.effort.len == 0) return &ladder;
        return info.effort;
    }
    return &ladder;
}

/// Clamps a requested thinking level to what the named model accepts.
pub fn clampNamed(provider_id: []const u8, model_id: []const u8, desired: []const u8) []const u8 {
    for (builtins) |b| {
        if (!std.mem.eql(u8, b.id, provider_id)) continue;
        const info = catalog.lookup(b.id, model_id) orelse return desired;
        return clampEffort(info, desired);
    }
    return desired;
}
