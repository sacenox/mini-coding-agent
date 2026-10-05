//! The TUI: append-only scrollback above a bounded live region. It is one
//! projection of the agent event stream; it owns no agent or provider
//! semantics. The turn runs on a thread and reports through a queue; the event
//! loop renders and reads keys.

const std = @import("std");
const platform = @import("../platform.zig");
const util = @import("../util.zig");
const config = @import("../config.zig");
const session_mod = @import("../session.zig");
const types = @import("../types.zig");
const agent = @import("../agent.zig");
const models_mod = @import("../models.zig");
const tools_index = @import("../tools/index.zig");
const common = @import("../tools/common.zig");
const render = @import("render.zig");
const theme = @import("theme.zig");
const styles = @import("styles.zig");
const term = @import("term.zig");
const editor_mod = @import("editor.zig");
const stream = @import("stream.zig");
const complete = @import("complete.zig");

/// Status-row spinner frames; the only animation in the TUI.
const SPINNER = "⠀⠁⠂⠃⠄⠅⠆⠇⡀⡁⡂⡃⡄⡅⡆⡇⠈⠉⠊⠋⠌⠍⠎⠏⡈⡉⡊⡋⡌⡍⡎⡏⠐⠑⠒⠓⠔⠕⠖⠗⡐⡑⡒⡓⡔⡕⡖⡗⠘⠙⠚⠛⠜⠝⠞⠟⡘⡙⡚⡛⡜⡝⡞⡟⠠⠡⠢⠣⠤⠥⠦⠧⡠⡡⡢⡣⡤⡥⡦⡧⠨⠩⠪⠫⠬⠭⠮⠯⡨⡩⡪⡫⡬⡭⡮⡯⠰⠱⠲⠳⠴⠵⠶⠷⡰⡱⡲⡳⡴⡵⡶⡷⠸⠹⠺⠻⠼⠽⠾⠿⡸⡹⡺⡻⡼⡽⡾⡿⢀⢁⢂⢃⢄⢅⢆⢇⣀⣁⣂⣃⣄⣅⣆⣇⢈⢉⢊⢋⢌⢍⢎⢏⣈⣉⣊⣋⣌⣍⣎⣏⢐⢑⢒⢓⢔⢕⢖⢗⣐⣑⣒⣓⣔⣕⣖⣗⢘⢙⢚⢛⢜⢝⢞⢟⣘⣙⣚⣛⣜⣝⣞⣟⢠⢡⢢⢣⢤⢥⢦⢧⣠⣡⣢⣣⣤⣥⣦⣧⢨⢩⢪⢫⢬⢭⢮⢯⣨⣩⣪⣫⣬⣭⣮⣯⢰⢱⢲⢳⢴⢵⢶⢷⣰⣱⣲⣳⣴⣵⣶⣷⢸⢹⢺⢻⢼⢽⢾⢿⣸⣹⣺⣻⣼⣽⣾⣿";
const SPINNER_MS = 120;
const BODY_PREFIX = " | ";
const ERROR_PREFIX = " ! ";

/// Display-only elision for tool bodies; `edit` diffs are always shown in full.
const MAX_BODY_ROWS = 12;
const ELIDED_HEAD = 4;
const ELIDED_TAIL = 4;

/// One announced call, held until its result commits the line to scrollback.
const PendingCall = struct { name: []const u8, summary: []const u8 };

/// Width every state word is padded to, so the tool heads align.
const STATE_WIDTH = "running".len;
const STATE_PAD = std.fmt.comptimePrint("{{s: <{d}}}", .{STATE_WIDTH});

fn paintRow(a: std.mem.Allocator, line: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}{s}\x1b[K", .{ theme.SGR_PLAIN, line }) catch line;
}

/// Wraps plain text, then styles each row: styling after the break is what lets
/// a continuation row inherit its source line's style.
fn styleRow(a: std.mem.Allocator, line: stream.BodyLine, width: usize) []const []const u8 {
    const safe = render.sanitize(a, line.text);
    const expanded = render.expandTabs(a, safe, 4);
    const wrapped = render.wrapLine(a, expanded, width);
    var out: std.ArrayList([]const u8) = .empty;
    for (wrapped) |row| {
        if (row.len == 0) {
            out.append(a, "") catch {};
            continue;
        }
        const row_bg = if (line.bg) |bg| theme.sgrBg(a, bg) else theme.SGR_NORMAL_BG;
        // The span's foreground must not hand the row's own background back to
        // `Normal`: a diff row's tint has to cover its text, not just the cells
        // `ESC[K` erases after it.
        const styled = if (line.style) |s| styles.styledWith(a, .{
            .fg = s.fg,
            .bg = line.bg orelse theme.current.bg,
            .bold = s.bold,
            .italic = s.italic,
            .underline = s.underline,
        }, row) else row;
        out.append(a, std.fmt.allocPrint(a, "{s}{s}{s}", .{ row_bg, styled, row_bg }) catch row) catch {};
    }
    return out.items;
}

fn renderRows(a: std.mem.Allocator, lines: []const stream.BodyLine, width: usize) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |line| {
        for (styleRow(a, line, width)) |row| out.append(a, row) catch {};
    }
    return out.items;
}

/// `renderRows` plus the display-only elision applied to long tool bodies.
fn bodyRows(a: std.mem.Allocator, lines: []const stream.BodyLine, width: usize) []const []const u8 {
    const rows = renderRows(a, lines, width);
    if (rows.len <= MAX_BODY_ROWS) return rows;
    var out: std.ArrayList([]const u8) = .empty;
    for (rows[0..ELIDED_HEAD]) |r| out.append(a, r) catch {};
    out.append(a, styles.dim(a, std.fmt.allocPrint(a, "... {d} lines not shown ...", .{rows.len - ELIDED_HEAD - ELIDED_TAIL}) catch "")) catch {};
    for (rows[rows.len - ELIDED_TAIL ..]) |r| out.append(a, r) catch {};
    return out.items;
}

fn callHead(a: std.mem.Allocator, name: []const u8) []const u8 {
    return styles.teal(a, std.fmt.allocPrint(a, "-> {s}", .{name}) catch "->");
}

/// The rows of one announced call: the state word and the tool head, then the
/// arguments, wrapped at `width`.
fn callRows(a: std.mem.Allocator, width: usize, call: PendingCall, running: bool) []const []const u8 {
    const padded = std.fmt.allocPrint(a, STATE_PAD, .{if (running) "running" else "queued"}) catch "";
    const word = if (running) styles.teal(a, padded) else styles.dim(a, padded);
    const head = callHead(a, call.name);
    const text = render.expandTabs(a, render.sanitize(a, call.summary), 4);
    return render.wrapLine(a, std.fmt.allocPrint(a, "{s} {s} {s}", .{ word, head, text }) catch text, width);
}

fn collapseWs(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '\n' or s[i] == '\r') {
            if (out.items.len > 0 and out.items[out.items.len - 1] != ' ') out.append(a, ' ') catch {};
            i += 1;
            while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r')) i += 1;
            continue;
        }
        out.append(a, s[i]) catch {};
        i += 1;
    }
    return out.items;
}

/// The call line's summary, from the raw arguments JSON the provider streamed.
fn callSummary(a: std.mem.Allocator, name: []const u8, args_json: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, args_json, .{}) catch return args_json;
    if (parsed == .object) {
        if (std.mem.eql(u8, name, "bash")) {
            if (parsed.object.get("command")) |c| if (c == .string) return collapseWs(a, c.string);
        }
        if (std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "read")) {
            if (parsed.object.get("path")) |p| if (p == .string) return p.string;
        }
    }
    return args_json;
}

fn isEditHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "Index: ") or std.mem.startsWith(u8, line, "--- ") or
        std.mem.startsWith(u8, line, "+++ ") or (line.len >= 3 and line[0] == '=' and line[1] == '=' and line[2] == '=');
}

fn diffLine(line: []const u8) stream.BodyLine {
    if (std.mem.startsWith(u8, line, "@@")) return .{ .text = line, .style = .{ .fg = theme.current.prompt } };
    if (std.mem.startsWith(u8, line, "+")) return .{ .text = line, .style = .{ .fg = theme.current.add }, .bg = theme.current.diff_add };
    if (std.mem.startsWith(u8, line, "-")) return .{ .text = line, .style = .{ .fg = theme.current.error_ }, .bg = theme.current.diff_delete };
    if (std.mem.startsWith(u8, line, "\\ No newline")) return .{ .text = line, .style = .{ .fg = theme.current.comment } };
    if (std.mem.startsWith(u8, line, " ")) return .{ .text = line, .style = .{ .fg = theme.current.comment } };
    return .{ .text = line };
}

/// Styled lines for a tool call's changed files, shown in full. The patch's own
/// `Index:`/`---`/`+++` header is dropped: the path above it carries the name.
/// Only the opening run is dropped, so a removed line that happens to start
/// with `---` is still shown.
fn diffRows(a: std.mem.Allocator, diffs: []const common.FileDiff) []const stream.BodyLine {
    var out: std.ArrayList(stream.BodyLine) = .empty;
    for (diffs) |d| {
        out.append(a, .{ .text = d.path, .style = .{ .fg = theme.current.prompt } }) catch {};
        if (d.patch) |patch| {
            const trimmed = std.mem.trimEnd(u8, patch, " \t\r\n");
            var it = std.mem.splitScalar(u8, trimmed, '\n');
            var header = true;
            while (it.next()) |l| {
                if (header and isEditHeader(l)) continue;
                header = false;
                out.append(a, diffLine(l)) catch {};
            }
        } else if (d.note) |note| {
            out.append(a, .{ .text = note, .style = .{ .fg = theme.current.comment } }) catch {};
        }
    }
    return out.items;
}

/// Display rewrite of a tool result, by tool name.
fn resultLines(a: std.mem.Allocator, name: []const u8, text: []const u8, is_error: bool) []const stream.BodyLine {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |l| lines.append(a, l) catch {};
    var diff = false;
    if (std.mem.eql(u8, name, "bash")) {
        if (lines.items.len > 0 and std.mem.startsWith(u8, lines.items[lines.items.len - 1], "exit code: ")) {
            const exit = lines.items[lines.items.len - 1]["exit code: ".len..];
            _ = lines.pop();
            if (is_error) lines.append(a, styles.red(a, std.fmt.allocPrint(a, "exit {s}", .{exit}) catch "exit")) catch {};
        }
    } else if (std.mem.eql(u8, name, "edit")) {
        if (lines.items.len > 0 and (std.mem.startsWith(u8, lines.items[0], "edited ") or std.mem.startsWith(u8, lines.items[0], "created "))) {
            _ = lines.orderedRemove(0);
            while (lines.items.len > 0 and isEditHeader(lines.items[0])) _ = lines.orderedRemove(0);
            diff = true;
        }
    }
    var out: std.ArrayList(stream.BodyLine) = .empty;
    for (lines.items) |l| {
        if (diff) out.append(a, diffLine(l)) catch {} else out.append(a, .{ .text = l }) catch {};
    }
    return out.items;
}

// ---- token estimate (display only) --------------------------------------

/// Roughly four characters per token, the usual rule of thumb.
fn estimateTextTokens(text: []const u8) u64 {
    return (text.len + 3) / 4;
}

fn estimateMessageTokens(m: types.Message) u64 {
    return switch (m) {
        .user => |u| estimateTextTokens(u.content),
        .tool_result => |t| estimateTextTokens(t.text),
        .assistant => |am| blk: {
            var chars: usize = 0;
            for (am.content.items) |b| switch (b) {
                .text => |t| chars += t.len,
                .thinking => |t| chars += t.text.len,
                .tool_call => |tc| chars += tc.name.len + tc.arguments.len,
            };
            break :blk (chars + 3) / 4;
        },
    };
}

/// The last assistant turn's reported usage plus an estimate of everything
/// after it; the whole transcript plus the prompt when there is no usage yet.
fn estimateContextTokens(messages: []const types.Message, system_prompt: []const u8, tools_json: []const u8) u64 {
    var last_idx: ?usize = null;
    var usage: u64 = 0;
    for (messages, 0..) |m, i| {
        if (m != .assistant) continue;
        const am = m.assistant;
        if (am.stop_reason == .aborted or am.stop_reason == .err) continue;
        if (am.usage.total_tokens == 0) continue;
        usage = am.usage.total_tokens;
        last_idx = i;
    }
    if (last_idx) |idx| {
        var trailing: u64 = 0;
        for (messages[idx + 1 ..]) |m| trailing += estimateMessageTokens(m);
        return usage + trailing;
    }
    var total: u64 = 0;
    for (messages) |m| total += estimateMessageTokens(m);
    return total + estimateTextTokens(system_prompt) + estimateTextTokens(tools_json);
}

/// `12k`, `1.2M`, or the plain count below a thousand. The trailing zeros the
/// one- or two-decimal rounding leaves are trimmed back off.
fn formatTokens(a: std.mem.Allocator, n: u64) []const u8 {
    if (n < 1000) return std.fmt.allocPrint(a, "{d}", .{n}) catch "";
    const millions = n >= 1_000_000;
    const div: f64 = if (millions) 1_000_000.0 else 1000.0;
    const unit: []const u8 = if (millions) "M" else "k";
    var buf: [64]u8 = undefined;
    var num = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ @as(f64, @floatFromInt(n)) / div, if (millions) @as(usize, 2) else 1 }) catch return unit;
    while (num.len > 0 and num[num.len - 1] == '0') num = num[0 .. num.len - 1];
    if (num.len > 0 and num[num.len - 1] == '.') num = num[0 .. num.len - 1];
    return std.fmt.allocPrint(a, "{s}{s}", .{ num, unit }) catch unit;
}

fn contextUsageLine(a: std.mem.Allocator, used: u64, model: *const types.Model) []const u8 {
    const cw = @max(model.context_window, 1);
    const percent = @as(f64, @floatFromInt(used)) / @as(f64, @floatFromInt(cw)) * 100.0;
    const sizes = std.fmt.allocPrint(a, "{s}/{s}", .{ formatTokens(a, used), formatTokens(a, cw) }) catch "";
    if (used + model.max_tokens > cw) return styles.red(a, std.fmt.allocPrint(a, "ctx full · {s}", .{sizes}) catch "ctx full");
    const text = std.fmt.allocPrint(a, "ctx {s} · {d}%", .{ sizes, @as(u64, @intFromFloat(percent + 0.5)) }) catch "ctx";
    return if (percent >= 85) styles.yellow(a, text) else styles.dim(a, text);
}

// ---- live region ---------------------------------------------------------

const LiveRegion = struct {
    rows: usize = 0,
    cursor_up: usize = 0,

    /// Rows the region currently occupies on screen.
    fn clear(self: *LiveRegion, a: std.mem.Allocator) []const u8 {
        if (self.rows == 0) return "";
        var out: std.ArrayList(u8) = .empty;
        if (self.cursor_up > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}B", .{self.cursor_up}) catch "") catch {};
        if (self.rows > 1) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}A", .{self.rows - 1}) catch "") catch {};
        out.appendSlice(a, "\r") catch {};
        out.appendSlice(a, theme.SGR_PLAIN) catch {};
        out.appendSlice(a, "\x1b[J") catch {};
        self.rows = 0;
        self.cursor_up = 0;
        return out.items;
    }

    fn draw(self: *LiveRegion, a: std.mem.Allocator, lines: []const []const u8, cursor_row: usize, cursor_col: usize, above: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, self.clear(a)) catch {};
        out.appendSlice(a, above) catch {};
        for (lines, 0..) |line, i| {
            if (i > 0) out.appendSlice(a, "\r\n") catch {};
            out.appendSlice(a, line) catch {};
        }
        const up = if (lines.len > 0 and lines.len - 1 > cursor_row) lines.len - 1 - cursor_row else 0;
        if (up > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}A", .{up}) catch "") catch {};
        out.appendSlice(a, "\r") catch {};
        if (cursor_col > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}G", .{cursor_col + 1}) catch "") catch {};
        self.rows = lines.len;
        self.cursor_up = up;
        return out.items;
    }
};

// ---- the Tui -------------------------------------------------------------

var resize_flag = std.atomic.Value(bool).init(false);
var exit_flag = std.atomic.Value(bool).init(false);

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    resize_flag.store(true, .seq_cst);
}

/// A signal that must restore the terminal before the process ends.
fn onExitSignal(_: std.posix.SIG) callconv(.c) void {
    exit_flag.store(true, .seq_cst);
}

const Tui = struct {
    opts: *agent.Options,
    cfg: *const config.Config,
    tool_names: []const config.ToolName,
    term: term.Terminal = .{},
    editor: editor_mod.Editor,
    live: LiveRegion = .{},
    messages: std.ArrayList(types.Message) = .empty,
    /// Session-lifetime display buffers: scroll, pending calls, prompts.
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    /// Per-frame scratch: rendering only, reset each draw and key.
    scratch: std.heap.ArenaAllocator,
    s: std.mem.Allocator,
    /// Scrollback line buffers, freed once the frame is written.
    sarena: std.heap.ArenaAllocator,
    sa: std.mem.Allocator,

    input_bytes: std.ArrayList(u8) = .empty,
    input_batch: std.ArrayList(u8) = .empty,
    keys: std.ArrayList(term.Key) = .empty,
    parser: term.Parser = .{},
    stdin_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    eof_sent: bool = false,
    key_mutex: std.Io.Mutex = .init,
    events: std.ArrayList(agent.Event) = .empty,
    batch: std.ArrayList(agent.Event) = .empty,
    event_mutex: std.Io.Mutex = .init,
    /// Event payloads copied off the agent thread. Written and reset only while
    /// `event_mutex` is held, so it is never touched concurrently.
    qarena: std.heap.ArenaAllocator,
    q: std.mem.Allocator,

    phase: agent.Phase = .idle,
    detail: ?[]const u8 = null,
    writing_tool: ?[]const u8 = null,
    active: bool = false,
    paused: bool = false,
    pause_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    turn_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    steering_text: []const u8 = "",
    steering_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    scroll: std.ArrayList(u8) = .empty,
    wrote: bool = false,
    last_blank: bool = false,
    separator: bool = false,

    reply: stream.MarkdownStream,
    activity: stream.TailStream,
    pending_calls: std.ArrayList(PendingCall) = .empty,
    streamed: std.ArrayList(u8) = .empty,
    turn_start: i64 = 0,
    frame: usize = 0,
    dirty: bool = true,
    closed: bool = false,
    last_frame_ms: i64 = 0,
    last_input_ms: i64 = 0,
    command_active: bool = false,

    // interactive prompt state: an open list prompt, and its answer slot
    prompt_open: bool = false,
    prompt_options: []const []const u8 = &.{},
    prompt_ids: []const []const u8 = &.{},
    prompt_answer: []const u8 = "",
    prompt_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    pending_command: enum { none, provider, model, thinking } = .none,
    pending_provider: ?[]const u8 = null,

    fn init(a: std.mem.Allocator, opts: *agent.Options, cfg: *const config.Config, tool_names: []const config.ToolName) Tui {
        return .{
            .opts = opts,
            .cfg = cfg,
            .tool_names = tool_names,
            .editor = undefined,
            .arena = std.heap.ArenaAllocator.init(a),
            .a = undefined,
            .scratch = std.heap.ArenaAllocator.init(a),
            .s = undefined,
            .sarena = std.heap.ArenaAllocator.init(a),
            .sa = undefined,
            .qarena = std.heap.ArenaAllocator.init(a),
            .q = undefined,
            .reply = undefined,
            .activity = undefined,
        };
    }

    /// Binds the arena allocators and the objects that allocate from them. Must
    /// run on the final heap location: an `Allocator` captures a pointer to its
    /// arena, so it cannot be created on a stack copy that is later moved.
    fn bindAllocators(self: *Tui) void {
        self.a = self.arena.allocator();
        self.s = self.scratch.allocator();
        self.sa = self.sarena.allocator();
        self.q = self.qarena.allocator();
        self.editor = editor_mod.Editor.init(self.a);
        self.editor.s = self.s;
        self.reply = stream.MarkdownStream.init(self.a);
        self.activity = stream.TailStream.init(self.a);
    }

    fn resetScratch(self: *Tui) void {
        _ = self.scratch.reset(.retain_capacity);
        self.s = self.scratch.allocator();
        self.editor.s = self.s;
    }

    // ---- scrollback ------------------------------------------------------
    fn push(self: *Tui, line: []const u8) void {
        const clean = render.sanitize(self.sa, line);
        const blank = clean.len == 0 or (self.separator and self.wrote);
        self.separator = false;
        if (blank and self.wrote and !self.last_blank) {
            self.scroll.appendSlice(self.a, paintRow(self.sa, "")) catch {};
            self.scroll.appendSlice(self.a, "\r\n") catch {};
            self.last_blank = true;
        }
        if (clean.len != 0) {
            self.scroll.appendSlice(self.a, paintRow(self.sa, clean)) catch {};
            self.scroll.appendSlice(self.a, "\r\n") catch {};
            self.wrote = true;
            self.last_blank = false;
        }
        self.dirty = true;
    }

    fn commitLines(self: *Tui, lines: []const stream.BodyLine) void {
        const width = @max(self.term.width(), 1);
        for (renderRows(self.s, lines, width)) |row| self.push(row);
    }

    /// One standalone line between blank separators, away from the live
    /// region: banners, errors, command output.
    fn note(self: *Tui, line: []const u8) void {
        self.separator = true;
        self.push(line);
        self.separator = true;
    }

    /// A standalone error line, in red.
    fn fail(self: *Tui, comptime fmt: []const u8, args: anytype) void {
        self.note(styles.red(self.s, std.fmt.allocPrint(self.s, fmt, args) catch "! error"));
    }

    fn commitUser(self: *Tui, text: []const u8) void {
        self.separator = true;
        var it = std.mem.splitScalar(u8, text, '\n');
        var lines: std.ArrayList(stream.BodyLine) = .empty;
        while (it.next()) |l| lines.append(self.s, .{ .text = l, .style = .{ .fg = theme.current.prompt } }) catch {};
        self.commitLines(lines.items);
        self.separator = true;
    }

    fn pushBanner(self: *Tui) void {
        self.separator = true;
        const model = self.opts.model;
        self.push(if (model) |m|
            if (m.effort.len == 0)
                std.fmt.allocPrint(self.s, "mini · {s}/{s}", .{ m.provider, m.id }) catch "mini"
            else
                std.fmt.allocPrint(self.s, "mini · {s}/{s} · {s}", .{ m.provider, m.id, m.effort }) catch "mini"
        else
            "mini · no model configured");
        self.separator = true;
    }

    // ---- status ----------------------------------------------------------
    fn statusLine(self: *Tui) []const u8 {
        const model = self.opts.model orelse return styles.dim(self.s, "no model configured");
        const used = estimateContextTokens(self.messages.items, self.opts.system_prompt, self.opts.tools_json);
        const usage = contextUsageLine(self.s, used, model);
        if (self.paused or self.phase == .pausing) {
            return std.fmt.allocPrint(self.s, "{s} · {s}", .{ styles.dim(self.s, "paused - type steering, Enter to submit"), usage }) catch usage;
        }
        if (!self.active or self.phase == .idle) return usage;
        const label = switch (self.phase) {
            .preparing => "preparing",
            .waiting_model => "waiting for provider",
            .streaming => if (self.writing_tool) |w| std.fmt.allocPrint(self.s, "writing {s}", .{w}) catch "streaming" else "streaming",
            .running_tool => std.fmt.allocPrint(self.s, "running {s}", .{self.detail orelse "tool"}) catch "running tool",
            else => "idle",
        };
        const elapsed = @max(0, @divFloor(util.nowMs() - self.turn_start, 1000));
        const ch = spinnerChar(self.frame);
        return std.fmt.allocPrint(self.s, "{s} · {s}", .{ styles.dim(self.s, std.fmt.allocPrint(self.s, "{s} {s} · {d}s", .{ ch, label, elapsed }) catch label), usage }) catch usage;
    }

    fn spinnerChar(frame: usize) []const u8 {
        var idx = frame % 256;
        var i: usize = 0;
        while (i < SPINNER.len) {
            const n = std.unicode.utf8ByteSequenceLength(SPINNER[i]) catch 1;
            if (idx == 0) return SPINNER[i .. i + n];
            idx -= 1;
            i += n;
        }
        return " ";
    }

    /// Styled rows for the announced calls, wrapped to `width` and capped at
    /// `budget` rows. The running call is drawn first, so its arguments are what
    /// survives a full region; the tail the cap cuts is counted in one dim row.
    /// The block never exceeds its budget, which keeps the live region's row
    /// count exact.
    fn queueRows(self: *Tui, width: usize, budget: usize) []const []const u8 {
        if (budget == 0) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        for (self.pending_calls.items, 0..) |call, i| {
            for (callRows(self.s, width, call, i == 0 and self.phase == .running_tool)) |row| out.append(self.s, row) catch {};
        }
        if (out.items.len <= budget) return out.items;
        // The last budgeted row carries the count of the rows that do not fit.
        const keep = budget - 1;
        const hidden = out.items.len - keep;
        out.shrinkRetainingCapacity(keep);
        out.append(self.s, styles.dim(self.s, std.fmt.allocPrint(self.s, "... {d} more lines ...", .{hidden}) catch "...")) catch {};
        return out.items;
    }

    // ---- drawing ---------------------------------------------------------
    fn draw(self: *Tui) void {
        if (self.closed) return;
        self.resetScratch();
        const width = @max(self.term.width(), 1);
        const height = @max(self.term.height() - 1, 1);
        const status = render.wrapLine(self.s, self.statusLine(), width);

        var inflight = self.reply.pending();
        if (inflight.len == 0) inflight = self.activity.pending();
        const rows = renderRows(self.s, inflight, width);

        const room = if (height > status.len + 1) height - status.len - 1 else 0;
        // Announced calls wrap, so their row count is not known until they are
        // built; the cap keeps the block inside the room the body shares.
        const queue = self.queueRows(width, room);
        const keep = @min(rows.len, room - queue.len);
        const body = rows[rows.len - keep ..];
        const ed = self.editor.render2(width, @max(height - status.len - queue.len - body.len, 1));

        var lines: std.ArrayList([]const u8) = .empty;
        for (body) |r| lines.append(self.s, paintRow(self.s, r)) catch {};
        for (queue) |r| lines.append(self.s, paintRow(self.s, r)) catch {};
        for (status) |r| lines.append(self.s, paintRow(self.s, r)) catch {};
        for (ed.rows) |r| lines.append(self.s, paintRow(self.s, r)) catch {};
        var cursor_row = body.len + queue.len + status.len + ed.cursor_row;
        if (cursor_row >= lines.items.len and lines.items.len > 0) cursor_row = lines.items.len - 1;

        const scroll = self.scroll.items;
        const reanchor = scroll.len > 0 and self.live.rows >= self.term.height() - 1;
        const above = if (reanchor)
            std.fmt.allocPrint(self.s, "{s}\r\n", .{scroll}) catch scroll
        else
            scroll;
        const frame_text = self.live.draw(self.s, lines.items, cursor_row, ed.cursor_col, above);
        self.term.write(frame_text);
        // The scrollback was written; its buffer and line allocations are
        // reused next frame.
        self.scroll.clearRetainingCapacity();
        _ = self.sarena.reset(.retain_capacity);
        self.sa = self.sarena.allocator();
    }

    /// Tool names arrive in event payloads that point into the agent's
    /// per-step scratch, which is reset as soon as the callback returns. The
    /// status line outlives that reset, so it keeps its own copy.
    fn keepName(self: *Tui, slot: *?[]const u8, value: ?[]const u8) void {
        if (slot.*) |old| self.a.free(old);
        slot.* = if (value) |v| self.a.dupe(u8, v) catch null else null;
    }

    // ---- events ----------------------------------------------------------
    fn handleAgentEvent(self: *Tui, event: agent.Event) void {
        if (self.closed) return;
        self.resetScratch();
        switch (event) {
            .phase => |p| {
                self.phase = p.phase;
                self.keepName(&self.detail, p.detail);
                if (p.phase == .pausing) self.paused = true;
            },
            .text => |delta| {
                self.activity.reset();
                self.streamed.appendSlice(self.a, delta) catch {};
                self.commitLines(self.reply.feed(delta));
            },
            .reasoning => |delta| {
                if (self.reply.pending().len == 0) self.activity.feed(delta);
            },
            .tool_call => |tc| {
                self.keepName(&self.writing_tool, null);
                self.commitLines(self.reply.flush());
                self.activity.reset();
                self.pending_calls.append(self.a, .{
                    .name = self.a.dupe(u8, tc.name) catch "",
                    .summary = callSummary(self.a, tc.name, tc.arguments),
                }) catch {};
            },
            .tool_call_start => |name| self.keepName(&self.writing_tool, name),
            .tool_output => |chunk| self.activity.feed(chunk),
            .message => |am| self.commitMessage(am),
            .tool_result => |tr| {
                self.activity.reset();
                self.commitToolResult(tr.name, tr.text, tr.is_error, tr.diffs, tr.body);
            },
            .err => |m| self.endTurn(styles.red(self.s, std.fmt.allocPrint(self.s, "! {s}", .{m}) catch "! error")),
            .no_model => self.endTurn(styles.red(self.s, "! no model configured")),
            .cancelled => self.endTurn(styles.red(self.s, "! cancelled")),
            .complete => self.endTurn(styles.dim(self.s, std.fmt.allocPrint(self.s, "[complete · {d}s]", .{@max(0, @divFloor(util.nowMs() - self.turn_start, 1000))}) catch "[complete]")),
        }
        self.dirty = true;
    }

    fn endTurn(self: *Tui, line: []const u8) void {
        self.phase = .idle;
        self.keepName(&self.detail, null);
        self.keepName(&self.writing_tool, null);
        self.paused = false;
        self.activity.reset();
        self.commitLines(self.reply.flush());
        self.flushCalls();
        self.note(line);
    }

    fn commitMessage(self: *Tui, am: *types.AssistantMessage) void {
        self.activity.reset();
        self.commitLines(self.reply.flush());
        defer self.streamed.clearRetainingCapacity();
        // The text already streamed; this re-feed only recovers what the
        // streaming renderer held back. An allocation failure drops that
        // recovery, never the streamed text.
        const text = types.assistantText(self.s, am) catch return;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0 and std.mem.indexOf(u8, self.streamed.items, trimmed) == null) {
            self.commitLines(self.reply.feed(trimmed));
            self.commitLines(self.reply.flush());
        }
    }

    fn commitToolResult(self: *Tui, name: []const u8, text: []const u8, is_error: bool, diffs: []const common.FileDiff, body: ?[]const u8) void {
        self.separator = true;
        if (self.pending_calls.items.len > 0) {
            const call = self.pending_calls.orderedRemove(0);
            self.commitLines(&.{.{ .text = std.fmt.allocPrint(self.s, "{s}  {s}", .{ callHead(self.s, call.name), call.summary }) catch call.summary }});
        }
        const width = @max(self.term.width() - BODY_PREFIX.len, 1);
        // A tool that supplies a body wants one line instead of its text: the
        // header already carries the path, so the body carries what is not
        // visible anywhere else.
        const lines: []const stream.BodyLine = if (!is_error and body != null)
            &.{.{ .text = body.? }}
        else
            resultLines(self.s, name, text, is_error);
        const rows = if (std.mem.eql(u8, name, "edit")) renderRows(self.s, lines, width) else bodyRows(self.s, lines, width);
        for (rows, 0..) |row, i| {
            const prefix = if (is_error and i == rows.len - 1) styles.red(self.s, ERROR_PREFIX) else styles.dim(self.s, BODY_PREFIX);
            self.push(std.fmt.allocPrint(self.s, "{s}{s}", .{ prefix, row }) catch row);
        }
        if (diffs.len > 0) {
            for (renderRows(self.s, diffRows(self.s, diffs), width)) |row| {
                self.push(std.fmt.allocPrint(self.s, "{s}{s}", .{ styles.dim(self.s, BODY_PREFIX), row }) catch row);
            }
        }
        self.separator = true;
    }

    fn flushCalls(self: *Tui) void {
        for (self.pending_calls.items) |call| {
            self.separator = true;
            self.commitLines(&.{.{ .text = std.fmt.allocPrint(self.s, "{s}  {s}", .{ callHead(self.s, call.name), call.summary }) catch call.summary }});
        }
        self.pending_calls.clearRetainingCapacity();
    }

    // ---- input -----------------------------------------------------------
    fn handleKey(self: *Tui, key: term.Key) void {
        self.resetScratch();
        if (key == .eof) {
            if (!self.active and !self.command_active and self.editor.contents().len == 0) self.exit();
            return;
        }
        if (key == .interrupt) {
            if (self.active) {
                self.abort.store(true, .seq_cst);
                self.steering_ready.store(true, .seq_cst);
                self.steering_text = "";
                self.dirty = true;
            } else if (self.command_active) {
                self.command_active = false;
                self.prompt_open = false;
                self.dirty = true;
            } else if (self.editor.contents().len != 0) {
                self.editor.clear();
                self.dirty = true;
            }
            return;
        }
        if (key == .escape) {
            if (self.active and !self.paused) {
                self.pause_requested.store(true, .seq_cst);
                self.dirty = true;
            }
            return;
        }
        if (key == .tab) {
            if (completeCommand(self.editor.contents())) |text| {
                self.editor.setText(text);
            } else {
                _ = self.editor.completeWord(completePathStep);
            }
            self.dirty = true;
            return;
        }
        const result = self.editor.handle(key);
        if (result == .submit) self.submit() else if (result == .changed) self.dirty = true;
    }

    fn submit(self: *Tui) void {
        const text = self.editor.contents();
        if (self.active) {
            if (self.paused) {
                self.editor.clear();
                if (text.len > 0) self.commitUser(text);
                self.steering_text = text;
                self.steering_ready.store(true, .seq_cst);
                self.dirty = true;
            }
            return;
        }
        if (self.prompt_open) {
            self.editor.clear();
            self.prompt_answer = self.a.dupe(u8, text) catch text;
            self.prompt_ready.store(true, .seq_cst);
            self.dirty = true;
            return;
        }
        if (self.command_active) return;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        if (findCommand(text)) |found| {
            self.editor.clear();
            self.runCommand(found);
            self.dirty = true;
            return;
        }
        self.editor.clear();
        const message = types.Message{ .user = .{ .content = self.a.dupe(u8, text) catch text, .timestamp = util.nowMs() } };
        self.messages.append(platform.gpa, message) catch {
            self.fail("! out of memory", .{});
            return;
        };
        self.opts.session.appendMessage(platform.gpa, message) catch |e| {
            self.fail("! {s}", .{@errorName(e)});
            return;
        };
        self.commitUser(text);
        self.startTurn();
    }

    fn startTurn(self: *Tui) void {
        self.active = true;
        self.abort.store(false, .seq_cst);
        self.turn_done.store(false, .seq_cst);
        self.phase = .preparing;
        self.keepName(&self.detail, null);
        self.turn_start = util.nowMs();
        self.frame = 0;
        const t = std.Thread.spawn(.{}, turnThread, .{self}) catch return;
        t.detach();
        self.dirty = true;
    }

    // ---- commands --------------------------------------------------------
    fn runCommand(self: *Tui, command: Command) void {
        switch (command) {
            .help => self.showHelp(),
            .new => {
                self.newSession();
                self.note("new session");
            },
            .provider => self.startProviderSelect(),
            .model => {
                const m = self.opts.model orelse return self.fail("! no model configured", .{});
                self.startModelSelect(m.provider);
            },
            .thinking => {
                const m = self.opts.model orelse return self.fail("! no model configured", .{});
                const levels = models_mod.supportedLevels(m.provider, m.id);
                self.beginPrompt("Select a thinking level", levels, levels);
                self.pending_command = .thinking;
            },
        }
    }

    fn showHelp(self: *Tui) void {
        const keys = [_][2][]const u8{
            .{ "Enter", "submit" },
            .{ "Shift+Enter", "newline (Ctrl+J also works)" },
            .{ "Esc", "pause the turn at the next step boundary" },
            .{ "Ctrl+C", "cancel the turn" },
            .{ "Ctrl+D", "exit on an empty draft" },
            .{ "Tab", "complete command or path" },
        };
        var width: usize = 0;
        for (Command.all) |c| width = @max(width, c.wire().len + 1);
        for (keys) |row| width = @max(width, row[0].len);
        self.note("commands");
        for (Command.all) |c| {
            self.push(helpRow(self.s, std.fmt.allocPrint(self.s, "/{s}", .{c.wire()}) catch c.wire(), c.summary(), width));
        }
        self.push("");
        self.push("keybindings");
        for (keys) |row| self.push(helpRow(self.s, row[0], row[1], width));
    }

    /// Starts a fresh session: the current log is closed, a new one is opened
    /// in the same directory, and the transcript is dropped.
    fn newSession(self: *Tui) void {
        self.opts.session.close();
        const cwd = std.process.currentPathAlloc(platform.io, self.a) catch ".";
        self.opts.session.* = session_mod.Session.init(self.a, self.cfg.sessions_dir, cwd);
        self.messages.clearRetainingCapacity();
        self.dirty = true;
    }

    fn startProviderSelect(self: *Tui) void {
        const entries = models_mod.providers(self.a, self.cfg);
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (entries) |p| {
            if (!p.key_present) continue;
            ids.append(self.a, p.id) catch {};
            names.append(self.a, p.name) catch {};
        }
        if (ids.items.len == 0) {
            self.fail("! no authenticated providers", .{});
            return;
        }
        self.beginPrompt("Select a provider", names.items, ids.items);
        self.pending_command = .provider;
    }

    fn startModelSelect(self: *Tui, provider_id: []const u8) void {
        const list = models_mod.catalogModels(self.a, self.cfg, provider_id) catch {
            self.fail("! out of memory", .{});
            self.command_active = false;
            return;
        };
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (list) |m| {
            ids.append(self.a, m.id) catch {};
            names.append(self.a, m.name) catch {};
        }
        if (ids.items.len == 0) {
            self.fail("! no models for provider", .{});
            self.command_active = false;
            return;
        }
        self.beginPrompt(std.fmt.allocPrint(self.a, "Select a model for {s}", .{provider_id}) catch "Select a model", names.items, ids.items);
        self.pending_command = .model;
        self.pending_provider = provider_id;
    }

    /// Opens a numbered list prompt and prints it. `ids` are the values the
    /// answer maps back to, one per option.
    fn beginPrompt(self: *Tui, message: []const u8, options: []const []const u8, ids: []const []const u8) void {
        self.prompt_open = true;
        self.prompt_options = options;
        self.prompt_ids = ids;
        self.prompt_answer = "";
        self.prompt_ready.store(false, .seq_cst);
        self.command_active = true;
        self.separator = true;
        self.push(message);
        for (options, 0..) |o, i| {
            self.push(std.fmt.allocPrint(self.s, "  {d}. {s}", .{ i + 1, o }) catch o);
        }
        self.separator = true;
    }

    /// Applies the answer to the open prompt. The command is left inactive
    /// unless the step it starts opens another prompt.
    fn answerPrompt(self: *Tui) void {
        const answer = std.mem.trim(u8, self.prompt_answer, " \t\r\n");
        const command = self.pending_command;
        self.prompt_open = false;
        self.prompt_answer = "";
        self.command_active = false;
        const id = matchOption(answer, self.prompt_options, self.prompt_ids) orelse return;
        switch (command) {
            .provider => self.startModelSelect(id),
            .model => {
                const provider_id = self.pending_provider orelse return;
                var err: ?[]const u8 = null;
                const m = models_mod.resolveNamed(self.a, self.cfg, provider_id, id, &err) orelse return;
                const ptr = self.a.create(types.Model) catch return;
                ptr.* = m;
                self.select(ptr);
                config.save(self.a, self.cfg, .{ .provider = provider_id, .model = id }) catch {};
            },
            .thinking => {
                const m = self.opts.model orelse return;
                const updated = self.a.create(types.Model) catch return;
                updated.* = m.*;
                updated.effort = models_mod.clampNamed(m.provider, m.id, id);
                self.select(updated);
                config.save(self.a, self.cfg, .{ .thinking_effort = id }) catch {};
            },
            .none => {},
        }
    }

    /// Switches the running session to `model`; the tools and their image
    /// behaviour follow the new model.
    fn select(self: *Tui, m: *const types.Model) void {
        self.opts.model = m;
        self.opts.supports_images = m.supports_images;
        self.opts.tools_json = tools_index.json(self.a, self.tool_names, self.opts.supports_images);
        self.pushBanner();
        self.dirty = true;
    }

    // ---- steering interaction (called on the agent thread) ---------------
    fn isPauseRequested(ctx: *anyopaque) bool {
        const self: *Tui = @ptrCast(@alignCast(ctx));
        return self.pause_requested.load(.seq_cst);
    }
    fn clearPause(ctx: *anyopaque) void {
        const self: *Tui = @ptrCast(@alignCast(ctx));
        self.pause_requested.store(false, .seq_cst);
    }
    fn requestSteering(ctx: *anyopaque) []const u8 {
        const self: *Tui = @ptrCast(@alignCast(ctx));
        self.paused = true;
        self.dirty = true;
        while (!self.steering_ready.load(.seq_cst)) {
            if (self.abort.load(.seq_cst)) return "";
            std.Io.sleep(platform.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .boot) catch {};
        }
        self.steering_ready.store(false, .seq_cst);
        self.paused = false;
        self.dirty = true;
        return self.steering_text;
    }

    fn exit(self: *Tui) void {
        if (self.closed) return;
        self.closed = true;
        self.abort.store(true, .seq_cst);
        self.steering_ready.store(true, .seq_cst);
        self.term.write(self.live.clear(self.a));
        self.term.write(self.scroll.items);
        self.term.stop();
        self.opts.session.close();
    }
};

/// One aligned `key  description` help row; the key column is dimmed.
fn helpRow(a: std.mem.Allocator, key: []const u8, description: []const u8, width: usize) []const u8 {
    var padded: std.ArrayList(u8) = .empty;
    padded.appendSlice(a, key) catch {};
    var i = key.len;
    while (i < width) : (i += 1) padded.append(a, ' ') catch {};
    return std.fmt.allocPrint(a, "  {s}  {s}", .{ styles.dim(a, padded.items), description }) catch key;
}

fn matchOption(answer: []const u8, options: []const []const u8, ids: []const []const u8) ?[]const u8 {
    const n = std.fmt.parseInt(usize, answer, 10) catch {
        for (options, 0..) |o, i| {
            if (std.mem.eql(u8, o, answer)) return ids[i];
        }
        for (ids) |id| {
            if (std.mem.eql(u8, id, answer)) return id;
        }
        return null;
    };
    if (n >= 1 and n <= ids.len) return ids[n - 1];
    return null;
}

fn completePathStep(word: []const u8) ?[]const u8 {
    return complete.completePath(word);
}

/// A command the prompt accepts. `wire` is the word typed after the slash and
/// `help` is what `/help` lists it as.
const Command = enum {
    help,
    new,
    provider,
    model,
    thinking,

    fn wire(self: Command) []const u8 {
        return @tagName(self);
    }

    fn summary(self: Command) []const u8 {
        return switch (self) {
            .help => "list commands and keybindings",
            .new => "start a new session",
            .provider => "choose the provider and model",
            .model => "choose a model for the current provider",
            .thinking => "set the thinking level",
        };
    }

    /// The whole table, in the order `/help` lists it.
    const all = [_]Command{ .help, .new, .provider, .model, .thinking };
};

/// The command `text` names, or null when it names none. Only the first word
/// is read, so `/model extra` still resolves to `/model`.
fn findCommand(text: []const u8) ?Command {
    if (text.len == 0 or text[0] != '/') return null;
    var i: usize = 1;
    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') i += 1;
    return std.meta.stringToEnum(Command, text[1..i]);
}

/// Completes a `/command` draft to the one command it names, or to the prefix
/// every match shares. Null when nothing more can be filled in.
fn completeCommand(draft: []const u8) ?[]const u8 {
    if (draft.len == 0 or draft[0] != '/') return null;
    if (std.mem.indexOfAny(u8, draft, " \t\n") != null) return null;
    const typed = draft[1..];
    var matched: ?[]const u8 = null;
    for (Command.all) |c| {
        if (!std.mem.startsWith(u8, c.wire(), typed)) continue;
        matched = if (matched) |have| complete.commonPrefix(have, c.wire()) else c.wire();
    }
    const name = matched orelse return null;
    // Nothing to add when the draft is already what the matches share.
    if (name.len <= typed.len) return null;
    return std.fmt.allocPrint(platform.gpa, "/{s}", .{name}) catch null;
}

fn inputThread(self: *Tui) void {
    var buf: [4096]u8 = undefined;
    const stdin = std.Io.File.stdin();
    while (!self.closed) {
        const n = stdin.readStreaming(platform.io, &.{buf[0..]}) catch break;
        if (n == 0) break;
        self.key_mutex.lockUncancelable(platform.io);
        self.input_bytes.appendSlice(platform.gpa, buf[0..n]) catch {};
        self.key_mutex.unlock(platform.io);
    }
    self.stdin_closed.store(true, .seq_cst);
}

fn turnThread(self: *Tui) void {
    var o = self.opts.*;
    o.cancel = &self.abort;
    agent.runTurn(o, &self.messages, .{
        .ctx = self,
        .is_pause_requested = Tui.isPauseRequested,
        .clear_pause = Tui.clearPause,
        .request_steering = Tui.requestSteering,
    }, .{ .ctx = self, .on_event = eventTrampoline });
    self.turn_done.store(true, .seq_cst);
}

/// Deep-copies an event's variable-length payload into the TUI arena. The
/// agent thread resets its per-step scratch as soon as the callback returns, so
/// a queued event must not keep pointing into it.
fn copyEvent(a: std.mem.Allocator, e: agent.Event) agent.Event {
    return switch (e) {
        // An allocation failure here would otherwise leave a slice pointing
        // into scratch the agent is about to reset; an empty payload keeps the
        // event safe, at the cost of a display-only line.
        .phase => |p| .{ .phase = .{ .phase = p.phase, .detail = if (p.detail) |d| a.dupe(u8, d) catch "" else null } },
        .text => |s| .{ .text = a.dupe(u8, s) catch "" },
        .reasoning => |s| .{ .reasoning = a.dupe(u8, s) catch "" },
        .tool_call_start => |s| .{ .tool_call_start = a.dupe(u8, s) catch "" },
        .tool_output => |s| .{ .tool_output = a.dupe(u8, s) catch "" },
        .err => |s| .{ .err = a.dupe(u8, s) catch "" },
        .tool_call => |tc| .{ .tool_call = .{
            .name = a.dupe(u8, tc.name) catch "",
            .arguments = a.dupe(u8, tc.arguments) catch "",
        } },
        .tool_result => |tr| blk: {
            var diffs: []const common.FileDiff = &.{};
            if (a.alloc(common.FileDiff, tr.diffs.len)) |buf| {
                for (tr.diffs, 0..) |d, i| buf[i] = .{
                    .path = a.dupe(u8, d.path) catch "",
                    .patch = if (d.patch) |p| a.dupe(u8, p) catch "" else null,
                    .note = if (d.note) |n| a.dupe(u8, n) catch "" else null,
                };
                diffs = buf;
            } else |_| {}
            break :blk .{ .tool_result = .{
                .name = a.dupe(u8, tr.name) catch "",
                .text = a.dupe(u8, tr.text) catch "",
                .is_error = tr.is_error,
                .diffs = diffs,
                .body = if (tr.body) |b| a.dupe(u8, b) catch "" else null,
            } };
        },
        else => e,
    };
}

fn eventTrampoline(ctx: *anyopaque, event: agent.Event) void {
    const self: *Tui = @ptrCast(@alignCast(ctx));
    self.event_mutex.lockUncancelable(platform.io);
    self.events.append(platform.gpa, copyEvent(self.q, event)) catch {};
    self.event_mutex.unlock(platform.io);
}

/// Runs the TUI until the user exits. `opts` and `cfg` outlive the call.
pub fn run(opts: agent.Options, cfg: *const config.Config, tool_names: []const config.ToolName) !void {
    const gpa = platform.gpa;
    // The theme is chosen once, before anything is painted: the sequences the
    // rows are wrapped in are baked from it.
    theme.init(gpa, cfg.theme);
    const opts_ptr = try gpa.create(agent.Options);
    opts_ptr.* = opts;
    const self = try gpa.create(Tui);
    self.* = Tui.init(gpa, opts_ptr, cfg, tool_names);
    self.bindAllocators();

    self.term.start();
    const act = std.posix.Sigaction{
        .handler = .{ .handler = onWinch },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
    const term_act = std.posix.Sigaction{
        .handler = .{ .handler = onExitSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.TERM, &term_act, null);
    std.posix.sigaction(std.posix.SIG.INT, &term_act, null);

    self.pushBanner();
    self.draw();

    const input = std.Thread.spawn(.{}, inputThread, .{self}) catch return;
    input.detach();

    while (!self.closed) {
        self.key_mutex.lockUncancelable(platform.io);
        std.mem.swap(std.ArrayList(u8), &self.input_bytes, &self.input_batch);
        self.key_mutex.unlock(platform.io);
        self.keys.clearRetainingCapacity();
        const keys = &self.keys;
        if (self.input_batch.items.len > 0) {
            self.parser.feed(platform.gpa, self.input_batch.items, keys);
            self.last_input_ms = util.nowMs();
        }
        self.input_batch.clearRetainingCapacity();
        const now_early = util.nowMs();
        switch (self.parser.pending()) {
            .escape => if (now_early - self.last_input_ms > 30) self.parser.flushEscape(platform.gpa, keys),
            .sequence => if (now_early - self.last_input_ms > 150) self.parser.flushSequence(),
            .none => {},
        }
        if (self.stdin_closed.load(.seq_cst) and !self.eof_sent) {
            keys.append(platform.gpa, .eof) catch {};
            self.eof_sent = true;
        }
        for (keys.items) |k| self.handleKey(k);

        // Double-buffer the queue: the agent appends to `events` while the loop
        // drains `batch`, and the payload arena is reset once the queue is
        // empty, so a copied event outlives its own handling but not longer.
        self.event_mutex.lockUncancelable(platform.io);
        std.mem.swap(std.ArrayList(agent.Event), &self.events, &self.batch);
        self.event_mutex.unlock(platform.io);
        for (self.batch.items) |e| self.handleAgentEvent(e);
        self.event_mutex.lockUncancelable(platform.io);
        self.batch.clearRetainingCapacity();
        if (self.events.items.len == 0) {
            _ = self.qarena.reset(.retain_capacity);
            self.q = self.qarena.allocator();
        }
        self.event_mutex.unlock(platform.io);

        if (self.prompt_open and self.prompt_ready.load(.seq_cst)) self.answerPrompt();

        if (self.turn_done.load(.seq_cst) and self.active) {
            self.active = false;
            self.paused = false;
            self.phase = .idle;
            self.dirty = true;
        }

        if (resize_flag.swap(false, .seq_cst)) {
            self.term.refreshSize();
            self.dirty = true;
        }
        if (exit_flag.swap(false, .seq_cst)) self.exit();

        const now = util.nowMs();
        if (self.active and now - self.last_frame_ms >= SPINNER_MS) {
            self.frame += 1;
            self.last_frame_ms = now;
            self.dirty = true;
        }

        if (self.dirty) {
            self.draw();
            self.dirty = false;
        }
        std.Io.sleep(platform.io, .{ .nanoseconds = 8 * std.time.ns_per_ms }, .boot) catch {};
    }
}
