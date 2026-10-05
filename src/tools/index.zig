//! The tool set: schemas handed to the model, and dispatch to implementations.
//!
//! A name in the config that has no implementation is not advertised to the
//! model, so a request can never reach a tool that cannot run.

const std = @import("std");
const config = @import("../config.zig");
const json_mod = @import("../json.zig");
const common = @import("common.zig");
const read_tool = @import("read.zig");
const edit_tool = @import("edit.zig");
const bash_tool = @import("bash.zig");

const read_params =
    \\{"type":"object","required":["path"],"properties":{"path":{"type":"string","description":"File path"},"offset":{"type":"integer","description":"First line to return, 1-based"},"range":{"type":"integer","description":"Number of lines to return from offset"}},"additionalProperties":false}
;

const edit_params =
    \\{"type":"object","required":["path","oldText","newText"],"properties":{"path":{"type":"string","description":"File path"},"oldText":{"type":"string","description":"Exact text to replace; empty to create a file"},"newText":{"type":"string","description":"Replacement text"}},"additionalProperties":false}
;

const bash_params =
    \\{"type":"object","required":["command"],"properties":{"command":{"type":"string","description":"Command to run"},"timeout":{"type":"integer","description":"Timeout in seconds; defaults to 120"}},"additionalProperties":false}
;

const read_description = "Read a file. Returns its text. Returns the whole file unless offset and range give a line window. Prefer bash for search or binary files.";
const read_image_description = "Read a file. Returns its text, or the image itself when the file is a png, jpg, or webp. Returns the whole file unless offset and range give a line window. Prefer bash for search or binary files.";
const edit_description = "Edit a file by exact text replacement. oldText must occur exactly once. With empty oldText, create a new file (fails if it exists).";
const bash_description = "Run a bash command in the current working directory.";

pub fn execute(a: std.mem.Allocator, scratch: std.mem.Allocator, name: []const u8, args_json: []const u8, ctx: common.Context) common.Result {
    if (std.mem.eql(u8, name, "read")) return read_tool.run(a, scratch, args_json, ctx);
    if (std.mem.eql(u8, name, "edit")) return edit_tool.run(a, scratch, args_json, ctx);
    if (std.mem.eql(u8, name, "bash")) return bash_tool.run(a, scratch, args_json, ctx);
    return .{
        .text = std.fmt.allocPrint(a, "unknown tool: {s}", .{name}) catch "unknown tool",
        .is_error = true,
    };
}

/// One configured tool as `{"name":…,"description":…,"parameters":…}`, the
/// protocol-neutral form each provider adapter encodes its own wire form from.
/// `with_images` picks the `read` description that mentions image input, so the
/// model is never told about something the model itself cannot use.
fn writeTool(w: *std.Io.Writer, name: config.ToolName, with_images: bool) !void {
    const description = switch (name) {
        .read => if (with_images) read_image_description else read_description,
        .edit => edit_description,
        .bash => bash_description,
    };
    try w.writeAll("{\"name\":");
    try json_mod.writeString(w, @tagName(name));
    try w.writeAll(",\"description\":");
    try json_mod.writeString(w, description);
    try w.writeAll(",\"parameters\":");
    try w.writeAll(switch (name) {
        .read => read_params,
        .edit => edit_params,
        .bash => bash_params,
    });
    try w.writeByte('}');
}

/// The configured tool schemas as the JSON array recorded in the session.
pub fn json(a: std.mem.Allocator, names: []const config.ToolName, with_images: bool) []const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    w.writeByte('[') catch return "[]";
    for (names, 0..) |name, i| {
        if (i > 0) w.writeByte(',') catch return out.written();
        writeTool(w, name, with_images) catch return out.written();
    }
    w.writeByte(']') catch return out.written();
    return out.written();
}
