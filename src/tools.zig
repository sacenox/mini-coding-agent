const std = @import("std");
const config = @import("config.zig");
const message_mod = @import("message.zig");
const read_tool = @import("tools/read.zig");
const edit_tool = @import("tools/edit.zig");
const bash_tool = @import("tools/bash.zig");

pub const OutputFn = struct {
    ctx: *anyopaque,
    on_chunk: *const fn (ctx: *anyopaque, chunk: []const u8) void,

    pub fn call(self: OutputFn, chunk: []const u8) void {
        self.on_chunk(self.ctx, chunk);
    }
};

pub const ToolPhase = enum { snapshotting, running };

pub const PhaseFn = struct {
    ctx: *anyopaque,
    on_phase: *const fn (ctx: *anyopaque, phase: ToolPhase) void,

    pub fn call(self: PhaseFn, phase: ToolPhase) void {
        self.on_phase(self.ctx, phase);
    }
};

pub const Context = struct {
    cancel: *const std.atomic.Value(bool),
    supports_images: bool,
    tools: []const config.ToolName = &.{},
    on_output: ?OutputFn = null,
    on_phase: ?PhaseFn = null,
    snapshot_ignore_dirs: []const []const u8 = &.{},
    snapshot_uses_gitignore: bool = true,
};

pub const FileDiff = struct {
    path: []const u8,
    patch: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

pub const Result = struct {
    text: []const u8,
    is_error: bool,
    images: []const message_mod.ImageContent = &.{},
    diffs: []const FileDiff = &.{},
    body: ?[]const u8 = null,
};

pub fn fail(a: std.mem.Allocator, fallback: []const u8, comptime fmt: []const u8, args: anytype) Result {
    return .{
        .text = std.fmt.allocPrint(a, fmt, args) catch fallback,
        .is_error = true,
    };
}

pub const Kind = enum { string, integer };

pub const Param = struct {
    name: []const u8,
    kind: Kind,
    description: []const u8,
    required: bool = true,
};

pub const Describe = struct {
    with_images: bool = false,
    cwd: []const u8 = "",
};

pub const Descriptor = struct {
    name: config.ToolName,
    description: *const fn (std.mem.Allocator, Describe) []const u8,
    params: []const Param,
    run: *const fn (std.mem.Allocator, std.mem.Allocator, []const u8, Context) Result,
};

pub fn write(w: *std.Io.Writer, a: std.mem.Allocator, d: Descriptor, ctx: Describe) std.Io.Writer.Error!void {
    try w.writeAll("{\"name\":");
    try std.json.Stringify.encodeJsonString(@tagName(d.name), .{}, w);
    try w.writeAll(",\"description\":");
    try std.json.Stringify.encodeJsonString(d.description(a, ctx), .{}, w);
    try w.writeAll(",\"parameters\":{\"type\":\"object\",\"required\":[");
    var first = true;
    for (d.params) |p| {
        if (!p.required) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try std.json.Stringify.encodeJsonString(p.name, .{}, w);
    }
    try w.writeAll("],\"properties\":{");
    for (d.params, 0..) |p, i| {
        if (i > 0) try w.writeByte(',');
        try std.json.Stringify.encodeJsonString(p.name, .{}, w);
        try w.writeAll(":{\"type\":");
        try std.json.Stringify.encodeJsonString(@tagName(p.kind), .{}, w);
        try w.writeAll(",\"description\":");
        try std.json.Stringify.encodeJsonString(p.description, .{}, w);
        try w.writeByte('}');
    }
    try w.writeAll("},\"additionalProperties\":false}}");
}

const all = [_]Descriptor{ read_tool.tool, edit_tool.tool, bash_tool.tool };

fn byName(name: config.ToolName) ?Descriptor {
    for (all) |tool| if (tool.name == name) return tool;
    return null;
}

pub fn execute(a: std.mem.Allocator, scratch: std.mem.Allocator, name: []const u8, args_json: []const u8, ctx: Context) Result {
    for (all) |tool| {
        if (!std.mem.eql(u8, name, @tagName(tool.name))) continue;
        for (ctx.tools) |enabled| if (enabled == tool.name) return tool.run(a, scratch, args_json, ctx);
        break;
    }
    return .{
        .text = std.fmt.allocPrint(a, "unknown tool: {s}", .{name}) catch "unknown tool",
        .is_error = true,
    };
}

pub fn json(a: std.mem.Allocator, names: []const config.ToolName, with_images: bool, cwd: []const u8) []const u8 {
    const ctx = Describe{ .with_images = with_images, .cwd = cwd };
    var out: std.Io.Writer.Allocating = .init(a);
    writeJson(&out.writer, a, names, ctx) catch return "[]";
    return out.written();
}

fn writeJson(w: *std.Io.Writer, a: std.mem.Allocator, names: []const config.ToolName, ctx: Describe) !void {
    try w.writeByte('[');
    var first = true;
    for (names) |name| {
        const tool = byName(name) orelse continue;
        if (!first) try w.writeByte(',');
        first = false;
        try write(w, a, tool, ctx);
    }
    try w.writeByte(']');
}
