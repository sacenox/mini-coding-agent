//! Config: `$XDG_CONFIG_HOME/mini-coding-agent/config.json` (or the equivalent
//! under `$HOME`). Every user-facing behavior that can vary comes from here,
//! with a sane default. There is no project-local config. A `-c`/`--config`
//! file is read after the global one and overrides its keys.

const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");

pub const ToolName = enum { edit, read, bash };

pub const CustomProvider = struct {
    id: []const u8,
    name: ?[]const u8,
    base_url: []const u8,
    api: []const u8,
    models: []const []const u8,
    env_keys: []const []const u8,
    headers: []const [2][]const u8,
};

pub const Config = struct {
    /// The file `save` writes back to: the global config, or the override when
    /// one was given on the command line.
    path: []const u8,
    sessions_dir: []const u8,
    system_prompt: []const u8,
    discover_agent_files: bool,
    skills_dirs: []const []const u8,
    tools: []const ToolName,
    provider: ?[]const u8,
    model: ?[]const u8,
    /// Null when unset: no reasoning parameter is sent, so the provider picks.
    thinking_effort: ?[]const u8,
    custom_providers: []const CustomProvider,
};

const valid_efforts = [_][]const u8{ "off", "minimal", "low", "medium", "high", "xhigh", "max" };
const valid_apis = [_][]const u8{ "openai-completions", "openai-responses", "anthropic-messages", "google-generative-ai" };
const known_keys = [_][]const u8{
    "sessionsDir", "systemPrompt",   "discoverAgentFiles",
    "skillsDirs",  "tools",          "provider",
    "model",       "thinkingEffort", "customProviders",
};

fn configDir(a: std.mem.Allocator) []const u8 {
    const base = platform.getEnv("XDG_CONFIG_HOME") orelse
        util.join(a, &.{ platform.home() orelse "", ".config" }) catch "";
    return util.join(a, &.{ base, "mini-coding-agent" }) catch "mini-coding-agent";
}

pub fn configPath(a: std.mem.Allocator) []const u8 {
    return util.join(a, &.{ configDir(a), "config.json" }) catch "config.json";
}

/// `$XDG_STATE_HOME/mini-coding-agent/sessions`, else
/// `$HOME/.local/state/mini-coding-agent/sessions`, else the relative
/// `sessions`. Paths are not mini-coder's cwd-relative default.
fn sessionsDir(a: std.mem.Allocator) []const u8 {
    const state = platform.getEnv("XDG_STATE_HOME") orelse blk: {
        const home = platform.home() orelse return "sessions";
        break :blk util.join(a, &.{ home, ".local/state" }) catch return "sessions";
    };
    return util.join(a, &.{ state, "mini-coding-agent/sessions" }) catch "sessions";
}

fn fail(a: std.mem.Allocator, path: []const u8, comptime fmt: []const u8, args: anytype) error{InvalidConfig} {
    const detail = std.fmt.allocPrint(a, fmt, args) catch "invalid";
    platform.printErr("config {s}: {s}\n", .{ path, detail });
    return error.InvalidConfig;
}

fn strField(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, path: []const u8) !?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => fail(a, path, "\"{s}\" must be a string", .{key}),
    };
}

fn boolField(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn stringArray(a: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8, path: []const u8) !?[][]const u8 {
    const v = obj.get(key) orelse return null;
    if (v != .array) return fail(a, path, "\"{s}\" must be an array", .{key});
    var out: std.ArrayList([]const u8) = .empty;
    for (v.array.items, 0..) |item, i| {
        switch (item) {
            .string => |s| out.append(a, s) catch return error.OutOfMemory,
            else => return fail(a, path, "\"{s}[{d}]\" must be a string", .{ key, i }),
        }
    }
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

fn parseTools(a: std.mem.Allocator, obj: std.json.ObjectMap, path: []const u8) !?[]ToolName {
    const names = (try stringArray(a, obj, "tools", path)) orelse return null;
    var out: std.ArrayList(ToolName) = .empty;
    for (names) |name| {
        const tool = std.meta.stringToEnum(ToolName, name) orelse
            return fail(a, path, "unknown tool \"{s}\"", .{name});
        out.append(a, tool) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

fn parseHeaderPairs(a: std.mem.Allocator, obj: std.json.ObjectMap, path: []const u8) ![]const [2][]const u8 {
    const v = obj.get("headers") orelse return &.{};
    if (v != .object) return fail(a, path, "\"headers\" must be an object", .{});
    var out: std.ArrayList([2][]const u8) = .empty;
    var it = v.object.iterator();
    while (it.next()) |entry| {
        const value = switch (entry.value_ptr.*) {
            .string => |s| s,
            else => return fail(a, path, "\"headers.{s}\" must be a string", .{entry.key_ptr.*}),
        };
        out.append(a, .{ entry.key_ptr.*, value }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

fn parseCustomProviders(a: std.mem.Allocator, obj: std.json.ObjectMap, path: []const u8) !?[]CustomProvider {
    const v = obj.get("customProviders") orelse return null;
    if (v != .array) return fail(a, path, "\"customProviders\" must be an array", .{});
    var out: std.ArrayList(CustomProvider) = .empty;
    for (v.array.items, 0..) |item, i| {
        if (item != .object) return fail(a, path, "\"customProviders[{d}]\" must be an object", .{i});
        const p = item.object;
        const id = (try strField(a, p, "id", path)) orelse
            return fail(a, path, "\"customProviders[{d}].id\" is required", .{i});
        if (id.len == 0) return fail(a, path, "\"customProviders[{d}].id\" must not be empty", .{i});
        const base_url = (try strField(a, p, "baseUrl", path)) orelse
            return fail(a, path, "\"customProviders[{d}].baseUrl\" is required", .{i});
        if (base_url.len == 0) return fail(a, path, "\"customProviders[{d}].baseUrl\" must not be empty", .{i});
        const api = (try strField(a, p, "api", path)) orelse
            return fail(a, path, "\"customProviders[{d}].api\" is required", .{i});
        var api_ok = false;
        for (valid_apis) |known| {
            if (std.mem.eql(u8, known, api)) api_ok = true;
        }
        if (!api_ok) return fail(a, path, "\"customProviders[{d}].api\" is unknown", .{i});
        const models = (try stringArray(a, p, "models", path)) orelse
            return fail(a, path, "\"customProviders[{d}].models\" is required", .{i});
        if (models.len == 0) return fail(a, path, "\"customProviders[{d}].models\" must not be empty", .{i});
        const env_keys = (try stringArray(a, p, "envKeys", path)) orelse &[_][]const u8{};
        const headers = try parseHeaderPairs(a, p, path);
        out.append(a, .{
            .id = id,
            .name = try strField(a, p, "name", path),
            .base_url = base_url,
            .api = api,
            .models = models,
            .env_keys = env_keys,
            .headers = headers,
        }) catch return error.OutOfMemory;
    }
    return out.toOwnedSlice(a) catch error.OutOfMemory;
}

/// Loads the config. The global file is always read; when `override` is given
/// it is read after and its keys win. A missing global file means every
/// default, but a missing override is an error. Any read, parse, or validation
/// failure is reported on stderr and returned. The result is allocated from
/// `a` and lives for the process.
pub fn load(a: std.mem.Allocator, override: ?[]const u8) !Config {
    var cfg = try defaults(a);
    try readInto(a, configPath(a), false, &cfg);

    if (override) |path| {
        cfg.path = path;
        try readInto(a, path, true, &cfg);
    }
    return cfg;
}

fn readInto(a: std.mem.Allocator, path: []const u8, required: bool, cfg: *Config) !void {
    const text = util.readFileAlloc(a, path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => {
            if (!required) return;
            platform.printErr("config {s}: no such file\n", .{path});
            return error.InvalidConfig;
        },
        else => {
            platform.printErr("config {s}: {s}\n", .{ path, @errorName(e) });
            return error.InvalidConfig;
        },
    };
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, text, .{}) catch {
        platform.printErr("config {s}: invalid JSON\n", .{path});
        return error.InvalidConfig;
    };
    if (root != .object) return fail(a, path, "root must be an object", .{});
    const obj = root.object;

    var it = obj.iterator();
    while (it.next()) |entry| {
        var known = false;
        for (known_keys) |key| {
            if (std.mem.eql(u8, key, entry.key_ptr.*)) known = true;
        }
        if (!known) return fail(a, path, "unknown key \"{s}\"", .{entry.key_ptr.*});
    }

    if (try strField(a, obj, "sessionsDir", path)) |v| cfg.sessions_dir = v;
    if (try strField(a, obj, "systemPrompt", path)) |v| cfg.system_prompt = v;
    if (try strField(a, obj, "provider", path)) |v| cfg.provider = v;
    if (try strField(a, obj, "model", path)) |v| cfg.model = v;
    if (boolField(obj, "discoverAgentFiles")) |v| cfg.discover_agent_files = v;
    if (try stringArray(a, obj, "skillsDirs", path)) |v| cfg.skills_dirs = v;
    if (try parseTools(a, obj, path)) |v| cfg.tools = v;
    if (try parseCustomProviders(a, obj, path)) |v| cfg.custom_providers = v;
    if (try strField(a, obj, "thinkingEffort", path)) |v| {
        var ok = false;
        for (valid_efforts) |known| {
            if (std.mem.eql(u8, known, v)) ok = true;
        }
        if (!ok) return fail(a, path, "unknown thinkingEffort \"{s}\"", .{v});
        cfg.thinking_effort = v;
    }
}

/// The subset of config a TUI command persists. `null` leaves a key alone.
pub const Update = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking_effort: ?[]const u8 = null,
};

/// Merges `update` into the on-disk config, preserving every other key. The
/// merge is textual: the file at `cfg.path` is parsed, the changed keys
/// replaced, and the whole object written back.
pub fn save(a: std.mem.Allocator, cfg: *const Config, update: Update) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const tmp = arena.allocator();

    const path = cfg.path;
    var root: std.json.Value = .{ .object = std.json.ObjectMap.empty };
    if (util.readFileAlloc(tmp, path, 1 << 20)) |text| {
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, tmp, text, .{}) catch
            return error.InvalidConfig;
        if (parsed != .object) return error.InvalidConfig;
        root = parsed;
    } else |_| {}

    if (update.provider) |v| root.object.put(tmp, "provider", .{ .string = v }) catch return error.OutOfMemory;
    if (update.model) |v| root.object.put(tmp, "model", .{ .string = v }) catch return error.OutOfMemory;
    if (update.thinking_effort) |v| root.object.put(tmp, "thinkingEffort", .{ .string = v }) catch return error.OutOfMemory;

    const json_text = std.json.Stringify.valueAlloc(tmp, root, .{ .whitespace = .indent_2 }) catch
        return error.OutOfMemory;
    const out = try std.fmt.allocPrint(tmp, "{s}\n", .{json_text});
    // Written atomically: a temp file, then a rename over the target, so an
    // interrupted write can never leave a truncated config behind.
    const temp = try std.fmt.allocPrint(tmp, "{s}.tmp", .{path});
    try util.writeFile(temp, out);
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), path, platform.io);
}

fn defaults(a: std.mem.Allocator) !Config {
    return .{
        .path = configPath(a),
        .sessions_dir = sessionsDir(a),
        .system_prompt = "",
        .discover_agent_files = true,
        .skills_dirs = &.{},
        .tools = &.{ .edit, .read, .bash },
        .provider = null,
        .model = null,
        .thinking_effort = null,
        .custom_providers = &.{},
    };
}
