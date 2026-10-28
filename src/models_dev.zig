const std = @import("std");

pub const raw = @embedFile("models_dev.json");

pub const Info = struct {
    name: []const u8,
    api: []const u8,
    base_url: []const u8,
    images: bool,
    reasoning: bool,
    context: u64,
    max_output: u64,
    effort: []const []const u8,
    budget_tokens: bool,
    cost_input: f64,
    cost_output: f64,
    cost_cache_read: f64,
};

const wires = [_][2][]const u8{
    .{ "@ai-sdk/openai-compatible", "openai-completions" },
    .{ "@ai-sdk/openai", "openai-responses" },
    .{ "@ai-sdk/anthropic", "anthropic-messages" },
    .{ "@ai-sdk/google", "google-generative-ai" },
    .{ "@openrouter/ai-sdk-provider", "openai-completions" },
};

fn wire(npm: []const u8) ?[]const u8 {
    for (wires) |w| {
        if (std.mem.eql(u8, w[0], npm)) return w[1];
    }
    return null;
}

const Effort = struct { type: []const u8 = "", values: []const []const u8 = &.{} };
const Limit = struct { context: u64 = 0, output: u64 = 0 };
const Cost = struct { input: f64 = 0, output: f64 = 0, cache_read: f64 = 0 };
const Package = struct { npm: []const u8 = "", api: []const u8 = "" };

const Model = struct {
    name: []const u8 = "",
    attachment: bool = false,
    reasoning: bool = false,
    reasoning_options: []const Effort = &.{},
    limit: Limit = .{},
    cost: Cost = .{},
    provider: ?Package = null,
};

pub const Provider = struct {
    api: []const u8 = "",
    npm: []const u8 = "",
    name: []const u8 = "",
    env: []const []const u8 = &.{},
    models: std.json.ArrayHashMap(Model) = .{},
};

const File = std.json.ArrayHashMap(Provider);

const wire_dirs = [_][]const u8{ "openai", "anthropic", "google" };

pub const Db = struct {
    a: std.mem.Allocator,
    file: File,

    pub fn open(a: std.mem.Allocator) !Db {
        return .{ .a = a, .file = try std.json.parseFromSliceLeaky(File, a, raw, .{ .ignore_unknown_fields = true }) };
    }

    pub fn provider(self: Db, provider_id: []const u8) ?Provider {
        return self.file.map.get(provider_id);
    }

    pub fn baseUrl(self: Db, provider_id: []const u8) ?[]const u8 {
        const p = self.file.map.get(provider_id) orelse return null;
        const api = std.mem.trimEnd(u8, p.api, "/");
        if (api.len == 0) return null;
        const version_at = std.mem.lastIndexOfScalar(u8, api, '/') orelse return api;
        const root_at = std.mem.lastIndexOfScalar(u8, api[0..version_at], '/') orelse return api;
        if (!isWireDir(api[root_at + 1 .. version_at])) return api;
        return std.fmt.allocPrint(self.a, "{s}{s}", .{ api[0..root_at], api[version_at..] }) catch null;
    }

    pub fn info(self: Db, provider_id: []const u8, model_id: []const u8) ?Info {
        const p = self.file.map.get(provider_id) orelse return null;
        if (p.api.len == 0) return null;
        const m = p.models.map.get(model_id) orelse return null;
        return .{
            .name = if (m.name.len > 0) m.name else model_id,
            .api = wire(modelNpm(m, p)) orelse return null,
            .base_url = std.mem.trimEnd(u8, modelApi(m, p), "/"),
            .images = m.attachment,
            .reasoning = m.reasoning,
            .context = m.limit.context,
            .max_output = m.limit.output,
            .effort = effortOf(m),
            .budget_tokens = hasOption(m, "budget_tokens"),
            .cost_input = m.cost.input,
            .cost_output = m.cost.output,
            .cost_cache_read = m.cost.cache_read,
        };
    }
};

fn isWireDir(seg: []const u8) bool {
    for (wire_dirs) |w| {
        if (std.mem.eql(u8, w, seg)) return true;
    }
    return false;
}

fn modelNpm(m: Model, p: Provider) []const u8 {
    if (m.provider) |pkg| {
        if (pkg.npm.len > 0) return pkg.npm;
    }
    return p.npm;
}

fn modelApi(m: Model, p: Provider) []const u8 {
    if (m.provider) |pkg| {
        if (pkg.api.len > 0) return pkg.api;
    }
    return p.api;
}

fn effortOf(m: Model) []const []const u8 {
    for (m.reasoning_options) |opt| {
        if (std.mem.eql(u8, opt.type, "effort")) return opt.values;
    }
    return &.{};
}

fn hasOption(m: Model, kind: []const u8) bool {
    for (m.reasoning_options) |opt| {
        if (std.mem.eql(u8, opt.type, kind)) return true;
    }
    return false;
}
