const std = @import("std");
const config = @import("config.zig");
const common = @import("tools/common.zig");
const spec = @import("tools/spec.zig");
const read_tool = @import("tools/read.zig");
const edit_tool = @import("tools/edit.zig");
const bash_tool = @import("tools/bash.zig");

const all = [_]spec.Descriptor{ read_tool.tool, edit_tool.tool, bash_tool.tool };

fn byName(name: config.ToolName) ?spec.Descriptor {
    for (all) |tool| if (tool.name == name) return tool;
    return null;
}

pub fn execute(a: std.mem.Allocator, scratch: std.mem.Allocator, name: []const u8, args_json: []const u8, ctx: common.Context) common.Result {
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
    const ctx = spec.Describe{ .with_images = with_images, .cwd = cwd };
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.writeByte('[') catch return "[]";
    var first = true;
    for (names) |name| {
        const tool = byName(name) orelse continue;
        if (!first) w.writeByte(',') catch return out.written();
        first = false;
        spec.write(w, a, tool, ctx) catch return out.written();
    }
    w.writeByte(']') catch return out.written();
    return out.written();
}
