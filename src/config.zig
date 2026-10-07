const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");
const theme = @import("tui/theme.zig");

pub const ToolName = enum { edit, read, bash };

pub const Api = enum {
    @"openai-completions",
    @"openai-responses",
    @"anthropic-messages",
    @"google-generative-ai",
};

pub const CustomProvider = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    baseUrl: []const u8,
    api: Api,
    models: []const []const u8,
    envKeys: []const []const u8 = &.{},
    headers: ?std.json.ArrayHashMap([]const u8) = null,
};

pub const Config = struct {
    path: []const u8,
    sessions_dir: []const u8,
    system_prompt: []const u8,
    discover_agent_files: bool,
    skills_dirs: []const []const u8,
    tools: []const ToolName,
    provider: ?[]const u8,
    model: ?[]const u8,
    thinking_effort: ?[]const u8,
    theme: []const u8,
    custom_providers: []const CustomProvider,
    snapshot_ignore_dirs: []const []const u8,
    snapshot_uses_gitignore: bool,
};

const File = struct {
    sessionsDir: ?[]const u8 = null,
    systemPrompt: ?[]const u8 = null,
    discoverAgentFiles: ?bool = null,
    skillsDirs: ?[]const []const u8 = null,
    tools: ?[]const ToolName = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinkingEffort: ?[]const u8 = null,
    customProviders: ?[]const CustomProvider = null,
    theme: ?[]const u8 = null,
    snapshotIgnoreDirs: ?[]const []const u8 = null,
    snapshotUsesGitignore: ?bool = null,
};

fn configDir(a: std.mem.Allocator) []const u8 {
    const base = platform.getEnv("XDG_CONFIG_HOME") orelse
        util.join(a, &.{ platform.home() orelse "", ".config" }) catch "";
    return util.join(a, &.{ base, "mini-coding-agent" }) catch "mini-coding-agent";
}

pub fn configPath(a: std.mem.Allocator) []const u8 {
    return util.join(a, &.{ configDir(a), "config.json" }) catch "config.json";
}

fn sessionsDir(a: std.mem.Allocator) []const u8 {
    const state = platform.getEnv("XDG_STATE_HOME") orelse blk: {
        const home = platform.home() orelse return "sessions";
        break :blk util.join(a, &.{ home, ".local/state" }) catch return "sessions";
    };
    return util.join(a, &.{ state, "mini-coding-agent/sessions" }) catch "sessions";
}

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
    const file = std.json.parseFromSliceLeaky(File, a, text, .{}) catch |e| {
        platform.printErr("config {s}: {s}\n", .{ path, @errorName(e) });
        return error.InvalidConfig;
    };

    if (file.sessionsDir) |v| cfg.sessions_dir = v;
    if (file.systemPrompt) |v| cfg.system_prompt = v;
    if (file.provider) |v| cfg.provider = v;
    if (file.model) |v| cfg.model = v;
    if (file.discoverAgentFiles) |v| cfg.discover_agent_files = v;
    if (file.skillsDirs) |v| cfg.skills_dirs = v;
    if (file.tools) |v| cfg.tools = v;
    if (file.customProviders) |v| cfg.custom_providers = v;
    if (file.thinkingEffort) |v| cfg.thinking_effort = v;
    if (file.theme) |v| cfg.theme = v;
    if (file.snapshotIgnoreDirs) |v| cfg.snapshot_ignore_dirs = v;
    if (file.snapshotUsesGitignore) |v| cfg.snapshot_uses_gitignore = v;
}

pub const Update = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinking_effort: ?[]const u8 = null,
};

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
        .theme = theme.default_id,
        .custom_providers = &.{},
        .snapshot_ignore_dirs = &.{},
        .snapshot_uses_gitignore = true,
    };
}
