//! Inline foreground styling from the palette. The foreground is restored by
//! re-asserting `Normal`'s, never by resetting: the row's background must
//! survive, and no cell may fall back to the terminal's colours.

const std = @import("std");
const theme = @import("theme.zig");

fn fg(a: std.mem.Allocator, hex: []const u8, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{
        theme.sgrFg(a, hex),
        text,
        theme.SGR_NORMAL_FG,
    }) catch text;
}

/// Applies a full style, restoring `Normal` after: bold and italic must not
/// bleed past the span, and no cell may fall back to the terminal's colours.
pub fn styledWith(a: std.mem.Allocator, style: theme.Style, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ theme.sgr(a, style), text, theme.SGR_PLAIN }) catch text;
}

/// `Comment`, the colour diff context lines share.
pub fn dim(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.PALETTE.comment, text);
}
pub fn red(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.PALETTE.red, text);
}
pub fn yellow(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.PALETTE.yellow, text);
}
/// The tool accent: call-line heads.
pub fn teal(a: std.mem.Allocator, text: []const u8) []const u8 {
    return fg(a, theme.PALETTE.teal, text);
}
