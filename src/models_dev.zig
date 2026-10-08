// models.dev metadata, embedded at build time. Refresh with
// `python3 tools/gen_models_dev.py`.

const std = @import("std");

/// The raw models.dev document, filtered to the providers this agent talks to.
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
    cost_input: f64,
    cost_output: f64,
    cost_cache_read: f64,
};

const wires = [_][2][]const u8{
    .{ "@ai-sdk/openai-compatible", "openai-completions" },
    .{ "@ai-sdk/openai", "openai-responses" },
    .{ "@ai-sdk/anthropic", "anthropic-messages" },
    .{ "@ai-sdk/google", "google-generative-ai" },
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
const Package = struct { npm: []const u8 = "" };

const Model = struct {
    name: []const u8 = "",
    attachment: bool = false,
    reasoning: bool = false,
    reasoning_options: []const Effort = &.{},
    limit: Limit = .{},
    cost: Cost = .{},
    provider: ?Package = null,
};

const Provider = struct {
    api: []const u8 = "",
    npm: []const u8 = "",
    models: std.json.ArrayHashMap(Model) = .{},
};

const File = std.json.ArrayHashMap(Provider);

/// A parsed models.dev document. The provider listing and each model's wire,
/// base URL and metadata all come from here.
pub const Db = struct {
    file: File,

    pub fn open(a: std.mem.Allocator) !Db {
        return .{ .file = try std.json.parseFromSliceLeaky(File, a, raw, .{ .ignore_unknown_fields = true }) };
    }

    pub fn baseUrl(self: Db, provider_id: []const u8) ?[]const u8 {
        const p = self.file.map.get(provider_id) orelse return null;
        if (p.api.len == 0) return null;
        return std.mem.trimEnd(u8, p.api, "/");
    }

    pub fn info(self: Db, provider_id: []const u8, model_id: []const u8) ?Info {
        const p = self.file.map.get(provider_id) orelse return null;
        if (p.api.len == 0) return null;
        const m = p.models.map.get(model_id) orelse return null;
        return .{
            .name = if (m.name.len > 0) m.name else model_id,
            .api = wire(if (m.provider) |pkg| pkg.npm else p.npm) orelse return null,
            .base_url = std.mem.trimEnd(u8, p.api, "/"),
            .images = m.attachment,
            .reasoning = m.reasoning,
            .context = m.limit.context,
            .max_output = m.limit.output,
            .effort = effortOf(m),
            .cost_input = m.cost.input,
            .cost_output = m.cost.output,
            .cost_cache_read = m.cost.cache_read,
        };
    }
};

fn effortOf(m: Model) []const []const u8 {
    for (m.reasoning_options) |opt| {
        if (std.mem.eql(u8, opt.type, "effort")) return opt.values;
    }
    return &.{};
}
