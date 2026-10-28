const std = @import("std");
const platform = @import("platform.zig");
const filesystem = @import("filesystem.zig");

pub const ToolName = enum { edit, read, bash };

pub const Notifications = enum { off, osc9, bell, both };

pub const Api = enum {
    @"openai-completions",
    @"openai-responses",
    @"anthropic-messages",
    @"google-generative-ai",
};

pub const CustomModel = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    api: Api,
    baseUrl: []const u8,
    context: u64,
    maxOutput: u64,
    images: bool,
    reasoning: bool,
    effort: []const []const u8 = &.{},
    cost: [3]f64,
};

pub const CustomProvider = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    models: []const CustomModel,
    envKeys: []const []const u8 = &.{},
    headers: ?std.json.ArrayHashMap([]const u8) = null,
};

pub const Colorscheme = struct {
    comment: ?[]const u8 = null,
    prompt: ?[]const u8 = null,
    accent: ?[]const u8 = null,
    err: ?[]const u8 = null,
    warn: ?[]const u8 = null,
    code: ?[]const u8 = null,
    output: ?[]const u8 = null,
    diff_add: ?[]const u8 = null,
    diff_delete: ?[]const u8 = null,
    inline_code: ?[]const u8 = null,
    link: ?[]const u8 = null,
    uri: ?[]const u8 = null,
    heading1: ?[]const u8 = null,
    heading2: ?[]const u8 = null,
    heading3: ?[]const u8 = null,
    heading4: ?[]const u8 = null,
    heading5: ?[]const u8 = null,
    heading6: ?[]const u8 = null,
};

pub fn parseHex(text: []const u8) ?u24 {
    const body = if (text.len > 0 and text[0] == '#') text[1..] else text;
    if (body.len != 6) return null;
    return std.fmt.parseInt(u24, body, 16) catch null;
}

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
    program_status: bool,
    herdr: bool,
    notifications: Notifications,
    retries: usize,
    retry_base_ms: u64,
    stream_idle_timeout_ms: u64,
    show_images: bool,
    custom_providers: []const CustomProvider,
    snapshot_ignore_dirs: []const []const u8,
    snapshot_uses_gitignore: bool,
    snapshot_diffs_in_context: bool,
    history_size: usize,
    max_diff_lines: usize,
    colorscheme: Colorscheme,
};

const File = struct {
    historySize: ?usize = null,
    maxDiffLines: ?usize = null,
    sessionsDir: ?[]const u8 = null,
    systemPrompt: ?[]const u8 = null,
    discoverAgentFiles: ?bool = null,
    skillsDirs: ?[]const []const u8 = null,
    tools: ?[]const ToolName = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    thinkingEffort: ?[]const u8 = null,
    customProviders: ?[]const CustomProvider = null,
    programStatus: ?bool = null,
    herdr: ?bool = null,
    notifications: ?Notifications = null,
    retries: ?usize = null,
    retryBaseMs: ?u64 = null,
    streamIdleTimeoutMs: ?u64 = null,
    showImages: ?bool = null,
    snapshotIgnoreDirs: ?[]const []const u8 = null,
    snapshotUsesGitignore: ?bool = null,
    snapshotDiffsInContext: ?bool = null,
    colorscheme: ?Colorscheme = null,
};

fn xdg(key: []const u8) ?[]const u8 {
    const value = platform.getEnv(key) orelse return null;
    return if (value.len == 0) null else value;
}

pub fn configDir(a: std.mem.Allocator) []const u8 {
    const base = xdg("XDG_CONFIG_HOME") orelse
        filesystem.join(a, &.{ platform.home() orelse "", ".config" }) catch "";
    return filesystem.join(a, &.{ base, "mini-coding-agent" }) catch "mini-coding-agent";
}

pub fn configPath(a: std.mem.Allocator) []const u8 {
    return filesystem.join(a, &.{ configDir(a), "config.json" }) catch "config.json";
}

fn stateDir(a: std.mem.Allocator) []const u8 {
    return xdg("XDG_STATE_HOME") orelse blk: {
        const home = platform.home() orelse return "";
        break :blk filesystem.join(a, &.{ home, ".local/state" }) catch "";
    };
}

fn stateFile(a: std.mem.Allocator, name: []const u8) []const u8 {
    const state = stateDir(a);
    if (state.len == 0) return name;
    return filesystem.join(a, &.{ state, "mini-coding-agent", name }) catch name;
}

pub fn historyPath(a: std.mem.Allocator) []const u8 {
    return stateFile(a, "history");
}

fn sessionsDir(a: std.mem.Allocator) []const u8 {
    return stateFile(a, "sessions");
}
pub fn load(a: std.mem.Allocator, override: ?[]const u8, no_config: bool) !Config {
    var cfg = try defaults(a);
    if (no_config) return cfg;

    try readInto(a, configPath(a), false, &cfg);
    if (override) |path| {
        cfg.path = path;
        try readInto(a, path, true, &cfg);
    }
    return cfg;
}

fn readInto(a: std.mem.Allocator, path: []const u8, required: bool, cfg: *Config) !void {
    const text = filesystem.readFileAlloc(a, path, 1 << 20) catch |e| switch (e) {
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
    if (file.programStatus) |v| cfg.program_status = v;
    if (file.herdr) |v| cfg.herdr = v;
    if (file.notifications) |v| cfg.notifications = v;
    if (file.retries) |v| cfg.retries = v;
    if (file.retryBaseMs) |v| cfg.retry_base_ms = v;
    if (file.streamIdleTimeoutMs) |v| cfg.stream_idle_timeout_ms = v;
    if (file.showImages) |v| cfg.show_images = v;
    if (file.snapshotIgnoreDirs) |v| cfg.snapshot_ignore_dirs = v;
    if (file.snapshotUsesGitignore) |v| cfg.snapshot_uses_gitignore = v;
    if (file.snapshotDiffsInContext) |v| cfg.snapshot_diffs_in_context = v;
    if (file.historySize) |v| cfg.history_size = v;
    if (file.maxDiffLines) |v| cfg.max_diff_lines = v;
    if (file.colorscheme) |scheme| {
        inline for (@typeInfo(Colorscheme).@"struct".field_names) |name| {
            if (@field(scheme, name)) |hex| {
                if (parseHex(hex) == null) {
                    platform.printErr("config {s}: colorscheme.{s}: expected \"#rrggbb\"\n", .{ path, name });
                    return error.InvalidConfig;
                }
                @field(cfg.colorscheme, name) = hex;
            }
        }
    }
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
    if (filesystem.readFileAlloc(tmp, path, 1 << 20)) |text| {
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
    try filesystem.writeFile(temp, out);
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
        .program_status = false,
        .herdr = false,
        .notifications = .off,
        .retries = 3,
        .retry_base_ms = 1000,
        .stream_idle_timeout_ms = 120_000,
        .show_images = false,
        .custom_providers = &.{},
        .snapshot_ignore_dirs = &.{},
        .snapshot_uses_gitignore = true,
        .snapshot_diffs_in_context = false,
        .history_size = 100,
        .max_diff_lines = 2000,
        .colorscheme = .{},
    };
}
