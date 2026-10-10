const std = @import("std");
const theme = @import("theme.zig");

fn colored(a: std.mem.Allocator, hex: []const u8, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{
        theme.sgrFg(a, hex),
        text,
        theme.SGR_NORMAL_FG,
    }) catch text;
}

pub fn styledWith(a: std.mem.Allocator, style: theme.Style, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ theme.sgr(a, style), text, theme.SGR_PLAIN }) catch text;
}

pub fn comment(a: std.mem.Allocator, text: []const u8) []const u8 {
    return colored(a, theme.current.comment, text);
}
pub fn err(a: std.mem.Allocator, text: []const u8) []const u8 {
    return colored(a, theme.current.err, text);
}
pub fn warn(a: std.mem.Allocator, text: []const u8) []const u8 {
    return colored(a, theme.current.warn, text);
}
pub fn accent(a: std.mem.Allocator, text: []const u8) []const u8 {
    return colored(a, theme.current.accent, text);
}
