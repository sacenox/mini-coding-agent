//! The palettes: one per theme id. Every colour the TUI writes comes from the
//! active theme, foreground and background alike, so no row can fall back to
//! the terminal's own colours. Truecolor only.
//!
//! A theme is one `Theme` value: the slots the TUI itself paints with, then its
//! own capture table and its own heading ramp. The capture tables are not
//! shared, so a theme maps a capture the way its own upstream theme does.
//!
//! The theme is chosen once at startup and never changes: `init` runs before the
//! first row is painted, and nothing writes `current` again.

const std = @import("std");

pub const Style = struct {
    fg: ?[]const u8 = null,
    bg: ?[]const u8 = null,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
};

/// One capture table entry. A dotted name falls back to its parent.
const Capture = struct { name: []const u8, style: Style };

pub const Theme = struct {
    /// `Normal`: the pair every row is painted with, and restored to.
    fg: []const u8,
    bg: []const u8,
    /// `Comment`: diff context, the status row, the elision notes.
    comment: []const u8,
    /// The user's own text, a diff path and hunk header, command output.
    prompt: []const u8,
    /// The tool accent: call-line heads.
    accent: []const u8,
    /// Diff `+` lines.
    add: []const u8,
    /// Diff `-` lines, and every error.
    error_: []const u8,
    /// A near-full context window.
    warn: []const u8,
    /// Diff row backgrounds.
    diff_add: []const u8,
    diff_delete: []const u8,
    /// Inline code, `@markup.raw.markdown_inline`.
    inline_code: Style,
    /// One style per Markdown heading level; the last covers every deeper level.
    headings: []const Style,
    captures: []const Capture,
};

// ---- TokyoNight `night` ---------------------------------------------------

const TOKYONIGHT = Theme{
    .fg = "#c0caf5",
    .bg = "#1a1b26",
    .comment = "#565f89",
    .prompt = "#7aa2f7",
    .accent = "#1abc9c",
    .add = "#9ece6a",
    .error_ = "#f7768e",
    .warn = "#e0af68",
    .diff_add = "#243e4a",
    .diff_delete = "#4a272f",
    .inline_code = .{ .fg = "#7aa2f7", .bg = "#414868" },
    .headings = &TOKYONIGHT_HEADINGS,
    .captures = &TOKYONIGHT_CAPTURES,
};

/// Headings take their level's colour from TokyoNight's rainbow over a tint.
const TOKYONIGHT_HEADINGS = [_]Style{
    .{ .fg = "#7aa2f7", .bg = "#24293b", .bold = true },
    .{ .fg = "#e0af68", .bg = "#2e2a2d", .bold = true },
    .{ .fg = "#9ece6a", .bg = "#272d2d", .bold = true },
    .{ .fg = "#1abc9c", .bg = "#1a2b32", .bold = true },
    .{ .fg = "#bb9af7", .bg = "#2a283b", .bold = true },
    .{ .fg = "#9d7cd8", .bg = "#272538", .bold = true },
    .{ .fg = "#ff9e64", .bg = "#31282c", .bold = true },
    .{ .fg = "#f7768e", .bg = "#302430", .bold = true },
};

const TOKYONIGHT_CAPTURES = [_]Capture{
    .{ .name = "boolean", .style = .{ .fg = "#ff9e64" } },
    .{ .name = "character", .style = .{ .fg = "#9ece6a" } },
    .{ .name = "comment", .style = .{ .fg = "#565f89" } },
    .{ .name = "constant", .style = .{ .fg = "#ff9e64" } },
    .{ .name = "constant.builtin", .style = .{ .fg = "#2ac3de" } },
    .{ .name = "constructor", .style = .{ .fg = "#bb9af7" } },
    .{ .name = "escape", .style = .{ .fg = "#bb9af7" } },
    .{ .name = "function", .style = .{ .fg = "#7aa2f7" } },
    .{ .name = "function.builtin", .style = .{ .fg = "#2ac3de" } },
    .{ .name = "keyword", .style = .{ .fg = "#9d7cd8" } },
    .{ .name = "label", .style = .{ .fg = "#7aa2f7" } },
    // `@module` is TokyoNight's `Include`, which is undefined there and falls
    // through to `PreProc`, a cyan the palette does not carry.
    .{ .name = "module", .style = .{ .fg = "#2ac3de" } },
    .{ .name = "number", .style = .{ .fg = "#ff9e64" } },
    .{ .name = "operator", .style = .{ .fg = "#89ddff" } },
    .{ .name = "property", .style = .{ .fg = "#73daca" } },
    .{ .name = "punctuation.bracket", .style = .{ .fg = "#a9b1d6" } },
    .{ .name = "punctuation.delimiter", .style = .{ .fg = "#89ddff" } },
    .{ .name = "punctuation.special", .style = .{ .fg = "#89ddff" } },
    .{ .name = "string", .style = .{ .fg = "#9ece6a" } },
    .{ .name = "string.special", .style = .{ .fg = "#2ac3de" } },
    .{ .name = "type", .style = .{ .fg = "#2ac3de" } },
    .{ .name = "type.builtin", .style = .{ .fg = "#27a1b9" } },
    .{ .name = "variable", .style = .{ .fg = "#c0caf5" } },
    .{ .name = "variable.builtin", .style = .{ .fg = "#f7768e" } },
    .{ .name = "variable.parameter", .style = .{ .fg = "#e0af68" } },
    // Markdown's queries predate the `@markup` rename; these are the old names.
    .{ .name = "text.emphasis", .style = .{ .italic = true } },
    .{ .name = "text.strong", .style = .{ .bold = true } },
    .{ .name = "text.literal", .style = .{ .fg = "#9ece6a" } },
    .{ .name = "text.title", .style = .{ .fg = "#7aa2f7", .bold = true } },
    .{ .name = "text.uri", .style = .{ .underline = true } },
    .{ .name = "text.reference", .style = .{ .fg = "#2ac3de" } },
};

// ---- Oxocarbon ------------------------------------------------------------

/// The greys are the upstream `blend_hex(base00, base06, n)` ramp resolved to
/// hex. The two diff tints are the upstream `DiffAdd` and `DiffDelete`.
const OXOCARBON = Theme{
    .fg = "#d0d0d0",
    .bg = "#161616",
    .comment = "#525252",
    .prompt = "#78a9ff",
    .accent = "#3ddbd9",
    .add = "#08bdba",
    .error_ = "#ee5396",
    .warn = "#be95ff",
    .diff_add = "#122f2f",
    .diff_delete = "#361c28",
    .inline_code = .{ .fg = "#be95ff", .bg = "#262626" },
    .headings = &OXOCARBON_HEADINGS,
    .captures = &OXOCARBON_CAPTURES,
};

/// Oxocarbon paints every heading level with one colour, `markdownH1` = base10,
/// so the ramp is a single entry and the clamp sends every level to it.
const OXOCARBON_HEADINGS = [_]Style{
    .{ .fg = "#ee5396", .bg = "#2c1c23", .bold = true },
};

const OXOCARBON_CAPTURES = [_]Capture{
    .{ .name = "boolean", .style = .{ .fg = "#78a9ff" } },
    .{ .name = "character", .style = .{ .fg = "#be95ff" } },
    .{ .name = "comment", .style = .{ .fg = "#525252", .italic = true } },
    .{ .name = "constant", .style = .{ .fg = "#be95ff" } },
    .{ .name = "constant.builtin", .style = .{ .fg = "#08bdba" } },
    .{ .name = "constructor", .style = .{ .fg = "#78a9ff" } },
    .{ .name = "function", .style = .{ .fg = "#ff7eb6", .bold = true } },
    .{ .name = "function.builtin", .style = .{ .fg = "#ff7eb6" } },
    .{ .name = "keyword", .style = .{ .fg = "#78a9ff" } },
    .{ .name = "label", .style = .{ .fg = "#82cfff" } },
    // `@module` is `Include` upstream, base09.
    .{ .name = "module", .style = .{ .fg = "#78a9ff" } },
    .{ .name = "number", .style = .{ .fg = "#82cfff" } },
    .{ .name = "operator", .style = .{ .fg = "#78a9ff" } },
    .{ .name = "property", .style = .{ .fg = "#ee5396" } },
    .{ .name = "punctuation.bracket", .style = .{ .fg = "#3ddbd9" } },
    .{ .name = "punctuation.delimiter", .style = .{ .fg = "#3ddbd9" } },
    .{ .name = "punctuation.special", .style = .{ .fg = "#3ddbd9" } },
    .{ .name = "string", .style = .{ .fg = "#be95ff" } },
    .{ .name = "string.special", .style = .{ .fg = "#be95ff" } },
    .{ .name = "type", .style = .{ .fg = "#78a9ff" } },
    .{ .name = "type.builtin", .style = .{ .fg = "#78a9ff" } },
    .{ .name = "variable", .style = .{ .fg = "#d0d0d0" } },
    .{ .name = "variable.builtin", .style = .{ .fg = "#d0d0d0" } },
    .{ .name = "variable.parameter", .style = .{ .fg = "#d0d0d0" } },
    .{ .name = "text.emphasis", .style = .{ .fg = "#ee5396", .bold = true } },
    .{ .name = "text.strong", .style = .{ .bold = true } },
    .{ .name = "text.literal", .style = .{ .fg = "#d0d0d0" } },
    .{ .name = "text.title", .style = .{ .fg = "#ee5396" } },
    .{ .name = "text.uri", .style = .{ .fg = "#be95ff", .underline = true } },
    .{ .name = "text.reference", .style = .{ .fg = "#d0d0d0" } },
};

// ---- the active theme -----------------------------------------------------

/// The id a config with no `theme` key gets.
pub const default_id = "tokyonight";

/// The theme `id` names, or null when no theme does.
pub fn find(id: []const u8) ?*const Theme {
    if (std.mem.eql(u8, id, "tokyonight")) return &TOKYONIGHT;
    if (std.mem.eql(u8, id, "oxocarbon")) return &OXOCARBON;
    return null;
}

/// The active theme. Set once by `init`; every call site reads it.
pub var current: *const Theme = &TOKYONIGHT;

/// The three sequences a row starts and ends in, built from the active theme.
/// Comptime while the palette was fixed; runtime now, because the palette is
/// not known until the config is read.
pub var SGR_PLAIN: []const u8 = "";
pub var SGR_NORMAL_FG: []const u8 = "";
pub var SGR_NORMAL_BG: []const u8 = "";

/// Selects the theme and bakes its sequences. Runs once, before the first row
/// is painted. An unknown id falls back to the default.
pub fn init(a: std.mem.Allocator, id: []const u8) void {
    current = find(id) orelse &TOKYONIGHT;
    const f = rgb(current.fg);
    const b = rgb(current.bg);
    SGR_PLAIN = std.fmt.allocPrint(a, "\x1b[22;23;24;38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{
        f[0], f[1], f[2], b[0], b[1], b[2],
    }) catch "";
    SGR_NORMAL_FG = sgrFg(a, current.fg);
    SGR_NORMAL_BG = sgrBg(a, current.bg);
}

/// A capture's style, falling back to its dotted parent; null when unmapped.
pub fn styleFor(capture: []const u8) ?Style {
    var name = capture;
    while (true) {
        for (current.captures) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry.style;
        }
        const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
        name = name[0..dot];
    }
}

// ---- colour helpers -------------------------------------------------------

/// The three channels of one `#rrggbb`.
fn rgb(hex: []const u8) [3]u8 {
    return .{
        std.fmt.parseInt(u8, hex[1..3], 16) catch 0,
        std.fmt.parseInt(u8, hex[3..5], 16) catch 0,
        std.fmt.parseInt(u8, hex[5..7], 16) catch 0,
    };
}

/// Explicit colour, never a reset: a `39`/`49` or a `0` would hand the rest of
/// the row back to the host terminal, which is the leak this palette closes.
pub fn sgrFg(a: std.mem.Allocator, hex: []const u8) []const u8 {
    const c = rgb(hex);
    return std.fmt.allocPrint(a, "\x1b[38;2;{d};{d};{d}m", .{ c[0], c[1], c[2] }) catch "";
}

pub fn sgrBg(a: std.mem.Allocator, hex: []const u8) []const u8 {
    const c = rgb(hex);
    return std.fmt.allocPrint(a, "\x1b[48;2;{d};{d};{d}m", .{ c[0], c[1], c[2] }) catch "";
}

/// A style's own attributes, with the defaults spelled out: a span that names
/// no colour must not inherit the colour of the span or token before it, and
/// the fallback is the palette's `Normal`, never the terminal's own pair.
pub fn sgr(a: std.mem.Allocator, style: Style) []const u8 {
    const f = rgb(style.fg orelse current.fg);
    const b = rgb(style.bg orelse current.bg);
    return std.fmt.allocPrint(a, "\x1b[{s}{s}{s}38;2;{d};{d};{d};48;2;{d};{d};{d}m", .{
        if (style.bold) "1;" else "",
        if (style.italic) "3;" else "",
        if (style.underline) "4;" else "",
        f[0],
        f[1],
        f[2],
        b[0],
        b[1],
        b[2],
    }) catch "";
}
