const std = @import("std");
const theme = @import("theme.zig");

fn fg(a: std.mem.Allocator, hex: []const u8, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{
        theme.sgrFg(a, hex),
        text,
        theme.SGR_NORMAL_FG,
    }) catch text;
}

pub fn styledWith(a: std.mem.Allocator, style: theme.Style, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ theme.sgr(a, style), text, theme.SGR_PLAIN }) catch text;
}

pub fn dim(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.current.comment, text);
}
pub fn red(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.current.error_, text);
}
pub fn yellow(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.current.warn, text);
}
pub fn teal(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.current.accent, text);
}
