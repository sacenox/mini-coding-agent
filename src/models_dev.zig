// Lazy models.dev metadata: fetched once, cached on disk for a day.

const std = @import("std");
const platform = @import("platform.zig");
const filesystem = @import("filesystem.zig");
const http = @import("http.zig");
const time = @import("time.zig");

pub const URL = "https://models.dev/api.json";
const CACHE_TTL_MS: i64 = 24 * 60 * 60 * 1000;

const ReasoningOption = struct {
    type: ?[]const u8 = null,
    values: ?[]const ?[]const u8 = null,
};

const Limit = struct { context: u64 = 0, output: u64 = 0 };
const Cost = struct { input: f64 = 0, output: f64 = 0, cache_read: f64 = 0 };
const Npm = struct { npm: ?[]const u8 = null };

pub const Model = struct {
    name: ?[]const u8 = null,
    attachment: bool = false,
    reasoning: bool = false,
    reasoning_options: ?[]const ReasoningOption = null,
    limit: Limit = .{},
    cost: Cost = .{},
    provider: ?Npm = null,
};

pub const Provider = struct {
    npm: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    models: std.json.ArrayHashMap(Model) = .{},
};

pub const Catalog = struct {
    providers: std.json.ArrayHashMap(Provider) = .{},

    pub fn provider(self: *const Catalog, id: []const u8) ?*const Provider {
        return self.providers.map.getPtr(id);
    }

    pub fn model(self: *const Catalog, provider_id: []const u8, model_id: []const u8) ?*const Model {
        const p = self.provider(provider_id) orelse return null;
        return p.models.map.getPtr(model_id);
    }
};

pub fn effort(a: std.mem.Allocator, model: *const Model) []const []const u8 {
    const options = model.reasoning_options orelse return &.{};
    for (options) |opt| {
        const kind = opt.type orelse continue;
        if (!std.mem.eql(u8, kind, "effort")) continue;
        const values = opt.values orelse return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        for (values) |value| {
            if (value) |v| out.append(a, v) catch {};
        }
        return out.toOwnedSlice(a) catch &.{};
    }
    return &.{};
}

var mutex: std.Io.Mutex = .init;
var loaded: bool = false;
var catalog: ?*Catalog = null;

pub fn get() ?*const Catalog {
    mutex.lockUncancelable(platform.io);
    defer mutex.unlock(platform.io);
    if (loaded) return catalog;
    loaded = true;
    const text = cachedText(platform.gpa) orelse return null;
    const providers_map = std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Provider), platform.gpa, text, .{
        .ignore_unknown_fields = true,
    }) catch return null;
    const ptr = platform.gpa.create(Catalog) catch return null;
    ptr.* = .{ .providers = providers_map };
    catalog = ptr;
    return catalog;
}

fn cachePath(a: std.mem.Allocator) []const u8 {
    const base = platform.getEnv("XDG_CACHE_HOME") orelse
        (if (platform.home()) |h| filesystem.join(a, &.{ h, ".cache" }) catch return "models.dev.json" else return "models.dev.json");
    return filesystem.join(a, &.{ base, "mini-coding-agent/models.dev.json" }) catch "models.dev.json";
}

fn cachedText(a: std.mem.Allocator) ?[]const u8 {
    const path = cachePath(a);
    const text = filesystem.readFileAlloc(a, path, 64 << 20) catch null;
    if (fresh(path)) return text;
    const fetched = fetch(a) catch return text;
    filesystem.writeFile(path, fetched) catch {};
    return fetched;
}

fn fresh(path: []const u8) bool {
    const stat = std.Io.Dir.cwd().statFile(platform.io, path, .{}) catch return false;
    const modified = stat.mtime.toMilliseconds();
    return time.nowMs() - modified < CACHE_TTL_MS;
}

fn fetch(a: std.mem.Allocator) ![]const u8 {
    return http.fetch(a, .GET, URL, &.{}, null, null, null);
}
