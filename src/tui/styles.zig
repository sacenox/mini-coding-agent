const std = @import("std");
const config = @import("../config.zig");

/// The terminal's own palette. Indices 0-7 are its normal colors and 8-15 the bright
/// ones, so the interface inherits whatever scheme the host terminal is set up with.
pub const Palette = enum(u8) {
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
};

/// A palette entry unless the config overrides the role with a `#rrggbb`.
pub const Color = union(enum) {
    palette: Palette,
    rgb: u24,
};

pub const Style = struct {
    fg: ?Color = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    dim: bool = false,
};

/// Every role resolves to the terminal's default foreground unless it asks otherwise.
pub const Roles = struct {
    comment: Style = .{ .fg = .{ .palette = .bright_black } },
    prompt: Style = .{ .fg = .{ .palette = .blue } },
    accent: Style = .{ .fg = .{ .palette = .cyan } },
    err: Style = .{ .fg = .{ .palette = .red } },
    warn: Style = .{ .fg = .{ .palette = .yellow } },
    code: Style = .{ .fg = .{ .palette = .bright_black } },
    output: Style = .{},
    diff_add: Style = .{ .fg = .{ .palette = .green } },
    diff_delete: Style = .{ .fg = .{ .palette = .red } },
    inline_code: Style = .{ .fg = .{ .palette = .magenta } },
    link: Style = .{ .fg = .{ .palette = .blue }, .underline = true },
    uri: Style = .{ .underline = true },
    heading1: Style = .{ .fg = .{ .palette = .bright_blue }, .bold = true },
    heading2: Style = .{ .fg = .{ .palette = .bright_cyan }, .bold = true },
    heading3: Style = .{ .fg = .{ .palette = .bright_magenta }, .bold = true },
    heading4: Style = .{ .fg = .{ .palette = .bright_green }, .bold = true },
    heading5: Style = .{ .fg = .{ .palette = .bright_yellow }, .bold = true },
    heading6: Style = .{ .fg = .{ .palette = .bright_red }, .bold = true },

    pub fn heading(self: Roles, level: usize) Style {
        return switch (level) {
            1 => self.heading1,
            2 => self.heading2,
            3 => self.heading3,
            4 => self.heading4,
            5 => self.heading5,
            else => self.heading6,
        };
    }
};

pub var roles: Roles = .{};

/// Each role the config names takes its `#rrggbb` as foreground. Field names line up.
pub fn applyScheme(scheme: config.Colorscheme) void {
    inline for (@typeInfo(config.Colorscheme).@"struct".field_names) |name| {
        if (@field(scheme, name)) |hex| @field(roles, name).fg = .{ .rgb = config.parseHex(hex).? };
    }
}

pub const SGR_PLAIN = "\x1b[0m";

fn appendFg(a: std.mem.Allocator, out: *std.ArrayList(u8), color: Color) void {
    const text = switch (color) {
        .palette => |p| blk: {
            const n: u8 = @backingInt(p);
            break :blk std.fmt.allocPrint(a, ";{d}", .{if (n < 8) 30 + n else 90 + n - 8});
        },
        .rgb => |v| std.fmt.allocPrint(a, ";38;2;{d};{d};{d}", .{ v >> 16 & 0xff, v >> 8 & 0xff, v & 0xff }),
    } catch return;
    out.appendSlice(a, text) catch {};
}

/// Renders `style` on top of `base`, so a span keeps the attributes of the line it sits in.
pub fn over(style: Style, base: Style) Style {
    return .{
        .fg = style.fg orelse base.fg,
        .bold = style.bold or base.bold,
        .italic = style.italic or base.italic,
        .underline = style.underline or base.underline,
        .dim = style.dim or base.dim,
    };
}

fn sgr(a: std.mem.Allocator, style: Style) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "\x1b[0") catch {};
    if (style.bold) out.appendSlice(a, ";1") catch {};
    if (style.italic) out.appendSlice(a, ";3") catch {};
    if (style.underline) out.appendSlice(a, ";4") catch {};
    if (style.dim) out.appendSlice(a, ";2") catch {};
    if (style.fg) |c| appendFg(a, &out, c);
    out.append(a, 'm') catch {};
    return out.items;
}

pub fn sgrOn(a: std.mem.Allocator, style: Style, base: Style) []const u8 {
    return sgr(a, over(style, base));
}

pub fn styledWith(a: std.mem.Allocator, style: Style, text: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ sgr(a, style), text, SGR_PLAIN }) catch text;
}

pub fn anySet(style: Style) bool {
    return style.fg != null or style.bold or style.italic or style.underline or style.dim;
}

/// The `·` between sections. Every separator in the interface uses this one
/// role, so a line never mixes separator colors.
pub fn sep(a: std.mem.Allocator) []const u8 {
    return styledWith(a, roles.comment, " · ");
}

/// Joins already-styled parts with separators.
pub fn join(a: std.mem.Allocator, parts: []const []const u8) []const u8 {
    return std.mem.join(a, sep(a), parts) catch "";
}

pub fn comment(a: std.mem.Allocator, text: []const u8) []const u8 {
    return styledWith(a, roles.comment, text);
}

pub fn err(a: std.mem.Allocator, text: []const u8) []const u8 {
    return styledWith(a, roles.err, text);
}

pub fn warn(a: std.mem.Allocator, text: []const u8) []const u8 {
    return styledWith(a, roles.warn, text);
}

pub fn accent(a: std.mem.Allocator, text: []const u8) []const u8 {
    return styledWith(a, roles.accent, text);
}
