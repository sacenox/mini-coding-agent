const std = @import("std");
const config = @import("../config.zig");
const common = @import("common.zig");

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
    run: *const fn (std.mem.Allocator, std.mem.Allocator, []const u8, common.Context) common.Result,
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
