//! The one palette: the TokyoNight `night` slots the TUI uses. Every colour the
//! TUI writes comes from here, foreground and background alike, so no row can
//! fall back to the terminal's own colours. Truecolor only.

const std = @import("std");

pub const PALETTE = struct {
    pub const bg = "#1a1b26";
    pub const fg = "#c0caf5";
    pub const fg_dark = "#a9b1d6";
    pub const comment = "#565f89";
    pub const terminal_black = "#414868";
    pub const blue = "#7aa2f7";
    pub const blue1 = "#2ac3de";
    pub const blue5 = "#89ddff";
    pub const green = "#9ece6a";
    pub const green1 = "#73daca";
    pub const magenta = "#bb9af7";
    pub const orange = "#ff9e64";
    pub const purple = "#9d7cd8";
    pub const red = "#f7768e";
    pub const teal = "#1abc9c";
    pub const yellow = "#e0af68";
};

/// `Normal`: the pair every row is painted with, and restored to.
pub const NORMAL_FG = PALETTE.fg;
pub const NORMAL_BG = PALETTE.bg;

/// Diff row backgrounds, from the `DiffAdd`/`DiffDelete` groups.
pub const DIFF_ADD = "#243e4a";
pub const DIFF_DELETE = "#4a272f";

/// `r;g;b` for one `#rrggbb`.
fn channels(a: std.mem.Allocator, hex: []const u8) []const u8 {
    const r = std.fmt.parseInt(u8, hex[1..3], 16) catch 0;
    const g = std.fmt.parseInt(u8, hex[3..5], 16) catch 0;
    const b = std.fmt.parseInt(u8, hex[5..7], 16) catch 0;
    return std.fmt.allocPrint(a, "{d};{d};{d}", .{ r, g, b }) catch "0;0;0";
}

/// Explicit colour, never a reset: a `39`/`49` or a `0` would hand the rest of
/// the row back to the host terminal, which is the leak this palette closes.
pub fn sgrFg(a: std.mem.Allocator, hex: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "\x1b[38;2;{s}m", .{channels(a, hex)}) catch "";
}

pub fn sgrBg(a: std.mem.Allocator, hex: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "\x1b[48;2;{s}m", .{channels(a, hex)}) catch "";
}

/// Attributes off, then `Normal`. The state a row starts and ends in.
pub fn sgrPlain(a: std.mem.Allocator) []const u8 {
    return std.fmt.allocPrint(a, "\x1b[22;23;24;38;2;{s};48;2;{s}m", .{ channels(a, NORMAL_FG), channels(a, NORMAL_BG) }) catch "";
}

pub const Style = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

/// A style's own attributes, with the defaults spelled out: a span that names
/// no colour must not inherit the colour of the span or token before it, and
/// the fallback is the palette's `Normal`, never the terminal's own pair.
pub fn sgr(a: std.mem.Allocator, style: Style) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, "\x1b[") catch {};
    if (style.bold) out.appendSlice(a, "1;") catch {};
    if (style.italic) out.appendSlice(a, "3;") catch {};
    if (style.underline) out.appendSlice(a, "4;") catch {};
    out.appendSlice(a, std.fmt.allocPrint(a, "38;2;{s};48;2;{s}m", .{
        channels(a, style.fg orelse NORMAL_FG),
        channels(a, style.bg orelse NORMAL_BG),
    }) catch "") catch {};
    return out.items;
}

/// Capture name to colour, mapped the way `folke/tokyonight.nvim` maps capture
/// names to highlight groups. A dotted name falls back to its parent.
const STYLES = [_]struct { name: []const u8, style: Style }{
    .{ .name = "comment", .style = .{ .fg = PALETTE.comment } },
    .{ .name = "constant", .style = .{ .fg = PALETTE.orange } },
    .{ .name = "constant.builtin", .style = .{ .fg = PALETTE.blue1 } },
    .{ .name = "constructor", .style = .{ .fg = PALETTE.magenta } },
    .{ .name = "escape", .style = .{ .fg = PALETTE.magenta } },
    .{ .name = "function", .style = .{ .fg = PALETTE.blue } },
    .{ .name = "function.builtin", .style = .{ .fg = PALETTE.blue1 } },
    .{ .name = "keyword", .style = .{ .fg = PALETTE.purple } },
    .{ .name = "number", .style = .{ .fg = PALETTE.orange } },
    .{ .name = "operator", .style = .{ .fg = PALETTE.blue5 } },
    .{ .name = "property", .style = .{ .fg = PALETTE.green1 } },
    .{ .name = "punctuation.bracket", .style = .{ .fg = PALETTE.fg_dark } },
    .{ .name = "punctuation.delimiter", .style = .{ .fg = PALETTE.blue5 } },
    .{ .name = "punctuation.special", .style = .{ .fg = PALETTE.blue5 } },
    .{ .name = "string", .style = .{ .fg = PALETTE.green } },
    .{ .name = "string.special", .style = .{ .fg = PALETTE.blue1 } },
    .{ .name = "type", .style = .{ .fg = PALETTE.blue1 } },
    .{ .name = "type.builtin", .style = .{ .fg = "#27a1b9" } },
    .{ .name = "variable", .style = .{ .fg = PALETTE.fg } },
    .{ .name = "variable.builtin", .style = .{ .fg = PALETTE.red } },
    .{ .name = "variable.parameter", .style = .{ .fg = PALETTE.yellow } },
    // Markdown's queries predate the `@markup` rename; these are the old names.
    .{ .name = "text.emphasis", .style = .{ .italic = true } },
    .{ .name = "text.strong", .style = .{ .bold = true } },
    .{ .name = "text.literal", .style = .{ .fg = PALETTE.green } },
    .{ .name = "text.uri", .style = .{ .underline = true } },
    .{ .name = "text.reference", .style = .{ .fg = PALETTE.blue1 } },
};

/// A capture's style, falling back to its dotted parent; null when unmapped.
pub fn styleFor(capture: []const u8) ?Style {
    var name = capture;
    while (true) {
        for (STYLES) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.style;
        }
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        name = name[0..dot];
    }
}

/// Headings take their level's colour from TokyoNight's rainbow over a tint.
pub const HEADINGS = [_]Style{
    .{ .fg = PALETTE.blue, .bg = "#24293b", .bold = true },
    .{ .fg = PALETTE.yellow, .bg = "#2e2a2d", .bold = true },
    .{ .fg = PALETTE.green, .bg = "#272d2d", .bold = true },
    .{ .fg = PALETTE.teal, .bg = "#1a2b32", .bold = true },
    .{ .fg = PALETTE.magenta, .bg = "#2a283b", .bold = true },
    .{ .fg = PALETTE.purple, .bg = "#272538", .bold = true },
    .{ .fg = PALETTE.orange, .bg = "#31282c", .bold = true },
    .{ .fg = PALETTE.red, .bg = "#302430", .bold = true },
};

/// Inline code, `@markup.raw.markdown_inline`.
pub const INLINE_CODE = Style{ .fg = PALETTE.blue, .bg = PALETTE.terminal_black };
