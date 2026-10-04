//! JSON writing helpers.
//!
//! Values that must be reproduced byte-for-byte from a provider stream — tool
//! call arguments, raw JSON schemas — are written verbatim, never re-encoded.

const std = @import("std");

pub fn writeString(w: *std.Io.Writer, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x08 => try w.writeAll("\\b"),
        0x0c => try w.writeAll("\\f"),
        else => {
            if (c < 0x20) {
                try w.print("\\u{x:0>4}", .{c});
            } else {
                try w.writeByte(c);
            }
        },
    };
    try w.writeByte('"');
}

pub fn writeNum(w: *std.Io.Writer, n: anytype) !void {
    try w.print("{d}", .{n});
}

pub fn writeFloat(w: *std.Io.Writer, f: f64) !void {
    if (!std.math.isFinite(f)) return w.writeAll("null");
    try w.print("{d}", .{f});
}

pub fn writeBool(w: *std.Io.Writer, b: bool) !void {
    try w.writeAll(if (b) "true" else "false");
}
