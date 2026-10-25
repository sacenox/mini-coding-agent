const std = @import("std");

/// The terminal's own palette. Indices 0-7 are its normal colors and 8-15 the bright
/// ones, so the interface inherits whatever scheme the host terminal is set up with.
pub const Color = enum(u8) {
    black = 0,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,
    bright_red,
    bright_green,
    bright_yellow,
    bright_blue,
    bright_magenta,
    bright_cyan,
    bright_white,

    fn fgCode(self: Color) u8 {
        const n: u8 = @backingInt(self);
        return if (n < 8) 30 + n else 90 + n - 8;
    }
};

pub const Style = struct {
    fg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,
};

/// Every role resolves to the terminal's default foreground unless it asks otherwise.
pub const roles = struct {
    pub const comment: Style = .{ .fg = .bright_black, .dim = true };
    pub const prompt = Color.blue;
    pub const accent = Color.cyan;
    pub const err = Color.red;
    pub const warn = Color.yellow;
    pub const code = Color.bright_black;
    pub const diff_add = Color.green;
    pub const diff_delete = Color.red;
    pub const inline_code: Style = .{ .fg = .cyan };
    pub const link: Style = .{ .fg = .blue, .underline = true };
    pub const uri: Style = .{ .underline = true };
    pub const headings = [_]Style{
        .{ .fg = .bright_blue, .bold = true },
        .{ .fg = .bright_cyan, .bold = true },
        .{ .fg = .bright_magenta, .bold = true },
        .{ .fg = .bright_green, .bold = true },
        .{ .fg = .bright_yellow, .bold = true },
        .{ .fg = .bright_red, .bold = true },
    };
};

pub const SGR_PLAIN = "\x1b[0m";
const SGR_NORMAL_FG = "\x1b[39m";

fn sgrFg(a: std.mem.Allocator, color: Color) []const u8 {
    return std.fmt.allocPrint(a, "\x1b[{d}m", .{color.fgCode()}) catch "";
}

fn sgr(a: std.mem.Allocator, style: Style) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "\x1b[0") catch {};
    if (style.bold) out.appendSlice(a, ";1") catch {};
    if (style.italic) out.appendSlice(a, ";3") catch {};
    if (style.underline) out.appendSlice(a, ";4") catch {};
    if (style.dim) out.appendSlice(a, ";2") catch {};
    if (style.fg) |c| out.appendSlice(a, std.fmt.allocPrint(a, ";{d}", .{c.fgCode()}) catch "") catch {};
    out.append(a, 'm') catch {};
    return out.items;
}

/// Renders `style` on top of `base`, so a span keeps the attributes of the line it sits in.
pub fn sgrOn(a: std.mem.Allocator, style: Style, base: Style) []const u8 {
    return sgr(a, .{
        .fg = style.fg orelse base.fg,
        .bold = style.bold or base.bold,
        .italic = style.italic or base.italic,
        .underline = style.underline or base.underline,
        .dim = style.dim or base.dim,
    });
}

pub fn styledWith(a: std.mem.Allocator, style: Style, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ sgr(a, style), text, SGR_PLAIN }) catch text;
}

fn colored(a: std.mem.Allocator, color: Color, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ sgrFg(a, color), text, SGR_NORMAL_FG }) catch text;
}

pub fn comment(a: std.mem.Allocator, text: []const u8) []const u8 {
    return styledWith(a, roles.comment, text);
}

pub fn err(a: std.mem.Allocator, text: []const u8) []const u8 {
    return colored(a, roles.err, text);
}

pub fn warn(a: std.mem.Allocator, text: []const u8) []const u8 {
    return colored(a, roles.warn, text);
}

pub fn accent(a: std.mem.Allocator, text: []const u8) []const u8 {
    return colored(a, roles.accent, text);
}
