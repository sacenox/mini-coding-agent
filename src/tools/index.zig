//! The tool set: schemas handed to the model, and dispatch to implementations.
//!
//! A name in the config that has no implementation is not advertised to the
//! model, so a request can never reach a tool the harness cannot run.

const std = @import("std");
const config = @import("../config.zig");
const types = @import("../types.zig");
const common = @import("common.zig");
const read_tool = @import("read.zig");
const edit_tool = @import("edit.zig");
const bash_tool = @import("bash.zig");

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    /// A JSON Schema object, verbatim.
    parameters: []const u8,
};

pub const read_params =
    \\{"type":"object","required":["path"],"properties":{"path":{"type":"string","description":"File path"}},"additionalProperties":false}
;

pub const edit_params =
    \\{"type":"object","required":["path","oldText","newText"],"properties":{"path":{"type":"string","description":"File path"},"oldText":{"type":"string","description":"Exact text to replace; empty to create a file"},"newText":{"type":"string","description":"Replacement text"}},"additionalProperties":false}
;

pub const bash_params =
    \\{"type":"object","required":["command"],"properties":{"command":{"type":"string","description":"Command to run"}},"additionalProperties":false}
;

const read_description = "Read a file. Returns its text. Prefer bash for search, ranges, or binary files.";
const read_image_description = "Read a file. Returns its text, or the image itself when the file is a png, jpg, or webp. Prefer bash for search, ranges, or binary files.";
const edit_description = "Edit a file by exact text replacement. oldText must occur exactly once. With empty oldText, create a new file (fails if it exists).";
const bash_description = "Run a bash command in the current working directory.";

pub fn acceptsImages(model: *const types.Model) bool {
    return model.supports_images;
}

pub fn schemas(a: std.mem.Allocator, names: []const config.ToolName, with_images: bool) []Tool {
    var out: std.ArrayList(Tool) = .empty;
    for (names) |name| {
        const tool: Tool = switch (name) {
            .read => .{
                .name = "read",
                .description = if (with_images) read_image_description else read_description,
                .parameters = read_params,
            },
            .edit => .{ .name = "edit", .description = edit_description, .parameters = edit_params },
            .bash => .{ .name = "bash", .description = bash_description, .parameters = bash_params },
        };
        out.append(a, tool) catch {};
    }
    return out.toOwnedSlice(a) catch &.{};
}

pub fn execute(a: std.mem.Allocator, scratch: std.mem.Allocator, name: []const u8, args_json: []const u8, ctx: common.Context) common.Result {
    if (std.mem.eql(u8, name, "read")) return read_tool.run(a, scratch, args_json, ctx);
    if (std.mem.eql(u8, name, "edit")) return edit_tool.run(a, scratch, args_json, ctx);
    if (std.mem.eql(u8, name, "bash")) return bash_tool.run(a, scratch, args_json, ctx);
    return .{
        .text = std.fmt.allocPrint(a, "unknown tool: {s}", .{name}) catch "unknown tool",
        .is_error = true,
    };
}

/// Serializes the tool schemas to the protocol-neutral JSON array recorded in
/// the session; each provider adapter encodes its own wire form from it.
pub fn writeArray(a: std.mem.Allocator, list: []const Tool) []const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.writeByte('[') catch return "[]";
    for (list, 0..) |tool, i| {
        if (i > 0) w.writeByte(',') catch return out.written();
        w.writeAll("{\"name\":") catch return out.written();
        @import("../json.zig").writeString(w, tool.name) catch return out.written();
        w.writeAll(",\"description\":") catch return out.written();
        @import("../json.zig").writeString(w, tool.description) catch return out.written();
        w.writeAll(",\"parameters\":") catch return out.written();
        w.writeAll(tool.parameters) catch return out.written();
        w.writeByte('}') catch return out.written();
    }
    w.writeByte(']') catch return out.written();
    return out.written();
}
