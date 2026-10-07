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
const highlight = @import("highlight.zig");
const styles = @import("styles.zig");
const term = @import("term.zig");
const editor_mod = @import("editor.zig");
const stream = @import("stream.zig");
const complete = @import("complete.zig");

const SPINNER = "⠀⠁⠂⠃⠄⠅⠆⠇⡀⡁⡂⡃⡄⡅⡆⡇⠈⠉⠊⠋⠌⠍⠎⠏⡈⡉⡊⡋⡌⡍⡎⡏⠐⠑⠒⠓⠔⠕⠖⠗⡐⡑⡒⡓⡔⡕⡖⡗⠘⠙⠚⠛⠜⠝⠞⠟⡘⡙⡚⡛⡜⡝⡞⡟⠠⠡⠢⠣⠤⠥⠦⠧⡠⡡⡢⡣⡤⡥⡦⡧⠨⠩⠪⠫⠬⠭⠮⠯⡨⡩⡪⡫⡬⡭⡮⡯⠰⠱⠲⠳⠴⠵⠶⠷⡰⡱⡲⡳⡴⡵⡶⡷⠸⠹⠺⠻⠼⠽⠾⠿⡸⡹⡺⡻⡼⡽⡾⡿⢀⢁⢂⢃⢄⢅⢆⢇⣀⣁⣂⣃⣄⣅⣆⣇⢈⢉⢊⢋⢌⢍⢎⢏⣈⣉⣊⣋⣌⣍⣎⣏⢐⢑⢒⢓⢔⢕⢖⢗⣐⣑⣒⣓⣔⣕⣖⣗⢘⢙⢚⢛⢜⢝⢞⢟⣘⣙⣚⣛⣜⣝⣞⣟⢠⢡⢢⢣⢤⢥⢦⢧⣠⣡⣢⣣⣤⣥⣦⣧⢨⢩⢪⢫⢬⢭⢮⢯⣨⣩⣪⣫⣬⣭⣮⣯⢰⢱⢲⢳⢴⢵⢶⢷⣰⣱⣲⣳⣴⣵⣶⣷⢸⢹⢺⢻⢼⢽⢾⢿⣸⣹⣺⣻⣼⣽⣾⣿";
const SPINNER_MS = 120;
const BODY_PREFIX = " | ";
const ERROR_PREFIX = " ! ";

const MAX_BODY_ROWS = 12;
const ELIDED_HEAD = 4;
const ELIDED_TAIL = 4;

const physicalRows = render.physicalRows;
const rowsForCells = render.rowsForCells;

const PendingCall = struct { name: []const u8, summary: []const u8 };

const STATE_WIDTH = "running".len;
const STATE_PAD = std.fmt.comptimePrint("{{s: <{d}}}", .{STATE_WIDTH});

fn styleLine(a: std.mem.Allocator, line: stream.BodyLine) []const u8 {
    const safe = render.sanitize(a, line.text);
    const expanded = render.expandTabs(a, safe, 4);
    if (expanded.len == 0) return "";
    const row_bg = if (line.bg) |bg| theme.sgrBg(a, bg) else theme.SGR_NORMAL_BG;
    const styled = if (line.style) |s| styles.styledWith(a, .{
        .fg = s.fg,
        .bg = line.bg orelse theme.current.bg,
        .bold = s.bold,
        .italic = s.italic,
        .underline = s.underline,
    }, expanded) else expanded;
    return std.fmt.allocPrint(a, "{s}{s}{s}", .{ row_bg, styled, row_bg }) catch expanded;
}

fn plainRows(a: std.mem.Allocator, lines: []const stream.BodyLine) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (lines) |line| out.append(a, styleLine(a, line)) catch {};
    return out.items;
}

fn bodyRows(a: std.mem.Allocator, lines: []const stream.BodyLine, width: usize) []const []const u8 {
    const rows = plainRows(a, lines);
    var height: usize = 0;
    for (rows) |r| height += physicalRows(r, width);
    if (height <= MAX_BODY_ROWS or rows.len <= ELIDED_HEAD + ELIDED_TAIL) return rows;
    const tail_at = rows.len - ELIDED_TAIL;
    var shown: usize = 0;
    var head: usize = 0;
    while (head < tail_at) : (head += 1) {
        const h = physicalRows(rows[head], width);
        if (shown + h + ELIDED_TAIL > MAX_BODY_ROWS - 1) break;
        shown += h;
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (rows[0..head]) |r| out.append(a, r) catch {};
    const hidden_rows: usize = blk: {
        var n = height;
        for (rows[0..head]) |r| n -= physicalRows(r, width);
        for (rows[tail_at..]) |r| n -= physicalRows(r, width);
        break :blk n;
    };
    out.append(a, styles.dim(a, std.fmt.allocPrint(a, "... {d} lines not shown ...", .{hidden_rows}) catch "")) catch {};
    for (rows[tail_at..]) |r| out.append(a, r) catch {};
    return out.items;
}

fn callHead(a: std.mem.Allocator, name: []const u8) []const u8 {
    return styles.teal(a, std.fmt.allocPrint(a, "-> {s}", .{name}) catch "->");
}

fn callRows(a: std.mem.Allocator, call: PendingCall, running: bool) []const []const u8 {
    const padded = std.fmt.allocPrint(a, STATE_PAD, .{if (running) "running" else "queued"}) catch "";
    const word = if (running) styles.teal(a, padded) else styles.dim(a, padded);
    const head = callHead(a, call.name);
    const text = render.expandTabs(a, render.sanitize(a, call.summary), 4);
    var out: std.ArrayList([]const u8) = .empty;
    out.append(a, std.fmt.allocPrint(a, "{s} {s} {s}", .{ word, head, text }) catch text) catch {};
    return out.items;
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

fn diffHunk() theme.Style {
    return .{ .fg = theme.current.prompt };
}

const DiffKind = enum { hunk, add, del, ctx, note };

fn diffKindOf(kind: []const u8) ?DiffKind {
    if (std.mem.eql(u8, kind, "location")) return .hunk;
    if (std.mem.eql(u8, kind, "addition")) return .add;
    if (std.mem.eql(u8, kind, "deletion")) return .del;
    if (std.mem.eql(u8, kind, "context")) return .ctx;
    if (highlight.isDiffLineKind(kind)) return .note;
    return null;
}

fn prefixKind(line: []const u8) DiffKind {
    if (std.mem.startsWith(u8, line, "@@")) return .hunk;
    if (std.mem.startsWith(u8, line, "+")) return .add;
    if (std.mem.startsWith(u8, line, "-")) return .del;
    if (std.mem.startsWith(u8, line, " ")) return .ctx;
    return .note;
}

fn langFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    const named = [_]struct { ext: []const u8, lang: []const u8 }{
        .{ .ext = ".js", .lang = "js" },
        .{ .ext = ".jsx", .lang = "jsx" },
        .{ .ext = ".mjs", .lang = "js" },
        .{ .ext = ".cjs", .lang = "js" },
        .{ .ext = ".ts", .lang = "ts" },
        .{ .ext = ".tsx", .lang = "tsx" },
        .{ .ext = ".py", .lang = "py" },
        .{ .ext = ".go", .lang = "go" },
        .{ .ext = ".zig", .lang = "zig" },
    };
    for (named) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry.ext)) return entry.lang;
    }
    return "";
}

fn rebaseSpans(a: std.mem.Allocator, spans: []const highlight.Span, lo: u32, hi: u32) []const highlight.Span {
    var out: std.ArrayList(highlight.Span) = .empty;
    for (spans) |s| {
        const start = @max(s.start, lo);
        const end = @min(s.end, hi);
        if (end <= start) continue;
        out.append(a, .{ .start = start - lo, .end = end - lo, .style = s.style }) catch {};
    }
    return out.items;
}

fn diffLines(a: std.mem.Allocator, path: []const u8, lines: []const []const u8) []const stream.BodyLine {
    var joined: std.ArrayList(u8) = .empty;
    var starts = a.alloc(u32, lines.len) catch return &.{};
    for (lines, 0..) |l, i| {
        if (i > 0) joined.append(a, '\n') catch {};
        starts[i] = @intCast(joined.items.len);
        joined.appendSlice(a, l) catch {};
    }
    const nodes = highlight.diffSpans(a, joined.items);
    std.mem.sort(highlight.NodeSpan, nodes, {}, struct {
        fn lt(_: void, x: highlight.NodeSpan, y: highlight.NodeSpan) bool {
            return x.start < y.start;
        }
    }.lt);

    var code: std.ArrayList(u8) = .empty;
    var kinds = a.alloc(DiffKind, lines.len) catch return &.{};
    var los = a.alloc(u32, lines.len) catch return &.{};
    var his = a.alloc(u32, lines.len) catch return &.{};
    var cursor: usize = 0;
    for (lines, 0..) |l, i| {
        while (cursor < nodes.len and nodes[cursor].end <= starts[i]) cursor += 1;
        const parsed: ?DiffKind = if (cursor < nodes.len and nodes[cursor].start == starts[i])
            diffKindOf(nodes[cursor].kind)
        else
            null;
        const kind = parsed orelse prefixKind(l);
        kinds[i] = kind;
        los[i] = 0;
        his[i] = 0;
        if (kind != .add and kind != .del and kind != .ctx) continue;
        const content = l[1..];
        los[i] = @intCast(code.items.len);
        code.appendSlice(a, content) catch {};
        code.append(a, '\n') catch {};
        his[i] = @intCast(code.items.len - 1);
    }

    const spans = highlight.spansFor(a, langFor(path), code.items);

    var out: std.ArrayList(stream.BodyLine) = .empty;
    for (lines, 0..) |l, i| {
        switch (kinds[i]) {
            .hunk => out.append(a, .{ .text = l, .style = diffHunk() }) catch {},
            .note => out.append(a, .{ .text = l, .style = .{ .fg = theme.current.comment } }) catch {},
            .ctx => out.append(a, .{ .text = l, .style = .{ .fg = theme.current.comment } }) catch {},
            .add, .del => {
                const bg = if (kinds[i] == .add) theme.current.diff_add else theme.current.diff_delete;
                const content = l[1..];
                const painted = highlight.paint(a, content, rebaseSpans(a, spans, los[i], his[i]), .{ .bg = bg });
                out.append(a, .{
                    .text = std.fmt.allocPrint(a, "{c}{s}", .{ l[0], painted }) catch l,
                    .bg = bg,
                }) catch {};
            },
        }
    }
    return out.items;
}

fn diffRows(a: std.mem.Allocator, diffs: []const common.FileDiff) []const stream.BodyLine {
    var out: std.ArrayList(stream.BodyLine) = .empty;
    for (diffs) |d| {
        out.append(a, .{ .text = d.path, .style = .{ .fg = theme.current.prompt } }) catch {};
        if (d.patch) |patch| {
            const trimmed = std.mem.trimEnd(u8, patch, " \t\r\n");
            var it = std.mem.splitScalar(u8, trimmed, '\n');
            var header = true;
            var body: std.ArrayList([]const u8) = .empty;
            while (it.next()) |l| {
                if (header and isEditHeader(l)) continue;
                header = false;
                body.append(a, l) catch {};
            }
            out.appendSlice(a, diffLines(a, d.path, body.items)) catch {};
        } else if (d.note) |note| {
            out.append(a, .{ .text = note, .style = .{ .fg = theme.current.comment } }) catch {};
        }
    }
    return out.items;
}

fn callBody(a: std.mem.Allocator, name: []const u8, summary: []const u8) stream.BodyLine {
    const body = if (std.mem.eql(u8, name, "bash"))
        highlight.highlightOn(a, "bash", summary, .{})
    else
        summary;
    return .{ .text = std.fmt.allocPrint(a, "{s}  {s}", .{ callHead(a, name), body }) catch summary };
}

fn resultLines(a: std.mem.Allocator, name: []const u8, text: []const u8, is_error: bool) []const stream.BodyLine {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |l| lines.append(a, l) catch {};
    if (std.mem.eql(u8, name, "bash")) {
        if (lines.items.len > 0 and std.mem.startsWith(u8, lines.items[lines.items.len - 1], "exit code: ")) {
            const exit = lines.items[lines.items.len - 1]["exit code: ".len..];
            _ = lines.pop();
            if (is_error) lines.append(a, styles.red(a, std.fmt.allocPrint(a, "exit {s}", .{exit}) catch "exit")) catch {};
        }
    } else if (std.mem.eql(u8, name, "edit")) {
        const verb = if (std.mem.startsWith(u8, lines.items[0], "edited "))
            "edited "
        else if (std.mem.startsWith(u8, lines.items[0], "created "))
            "created "
        else
            "";
        if (verb.len > 0) {
            const path = lines.items[0][verb.len..];
            _ = lines.orderedRemove(0);
            while (lines.items.len > 0 and isEditHeader(lines.items[0])) _ = lines.orderedRemove(0);
            return diffLines(a, path, lines.items);
        }
    }
    var out: std.ArrayList(stream.BodyLine) = .empty;
    for (lines.items) |l| out.append(a, .{ .text = l }) catch {};
    return out.items;
}

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

const LiveRegion = struct {
    widths: std.ArrayList(usize) = .empty,
    caret_line: usize = 0,
    caret_cell: usize = 0,
    drawn: bool = false,

    fn remember(self: *LiveRegion, lines: []const []const u8, caret_line: usize, caret_cell: usize) void {
        self.widths.clearRetainingCapacity();
        for (lines) |line| self.widths.append(platform.gpa, render.displayWidth(line)) catch {};
        self.caret_line = caret_line;
        self.caret_cell = caret_cell;
        self.drawn = true;
    }

    fn caretRow(self: *LiveRegion, width: usize) usize {
        var row: usize = 0;
        const lines = @min(self.caret_line, self.widths.items.len);
        for (self.widths.items[0..lines]) |cells| row += rowsForCells(cells, width);
        return row + self.caret_cell / width;
    }

    fn totalRows(self: *LiveRegion, width: usize) usize {
        var row: usize = 0;
        for (self.widths.items) |cells| row += rowsForCells(cells, width);
        return row;
    }

    fn erase(self: *LiveRegion, a: std.mem.Allocator, width: usize) []const u8 {
        if (!self.drawn) return "";
        const up = self.caretRow(width);
        var out: std.ArrayList(u8) = .empty;
        if (up > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}A", .{up}) catch "") catch {};
        out.appendSlice(a, "\r") catch {};
        out.appendSlice(a, theme.SGR_PLAIN) catch {};
        out.appendSlice(a, "\x1b[J") catch {};
        return out.items;
    }

    fn draw(self: *LiveRegion, a: std.mem.Allocator, width: usize, lines: []const []const u8, caret_line: usize, caret_cell: usize, above: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, self.erase(a, width)) catch {};
        out.appendSlice(a, above) catch {};
        for (lines, 0..) |line, i| {
            if (i > 0) out.appendSlice(a, "\r\n") catch {};
            out.appendSlice(a, line) catch {};
        }
        self.remember(lines, caret_line, caret_cell);
        const end_row = self.totalRows(width) - 1;
        const caret_row = self.caretRow(width);
        const up = if (end_row > caret_row) end_row - caret_row else 0;
        if (up > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}A", .{up}) catch "") catch {};
        out.appendSlice(a, "\r") catch {};
        const col = caret_cell % width;
        if (col > 0) out.appendSlice(a, std.fmt.allocPrint(a, "\x1b[{d}C", .{col}) catch "") catch {};
        return out.items;
    }
};

var resize_flag = std.atomic.Value(bool).init(false);
var exit_flag = std.atomic.Value(bool).init(false);

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    resize_flag.store(true, .seq_cst);
}

fn onExitSignal(_: std.posix.SIG) callconv(.c) void {
    term.restore();
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
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    s: std.mem.Allocator,
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
    qarena: std.heap.ArenaAllocator,
    q: std.mem.Allocator,

    phase: agent.Phase = .idle,
    detail: ?[]const u8 = null,
    writing_tool: ?[]const u8 = null,
    active: bool = false,
    paused: bool = false,
    pause_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    aborting: bool = false,
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

    fn push(self: *Tui, line: []const u8) void {
        const clean = render.sanitize(self.sa, line);
        const blank = clean.len == 0 or (self.separator and self.wrote);
        self.separator = false;
        if (blank and self.wrote and !self.last_blank) {
            self.scroll.appendSlice(self.a, theme.SGR_PLAIN) catch {};
            self.scroll.appendSlice(self.a, "\r\n") catch {};
            self.last_blank = true;
        }
        if (clean.len != 0) {
            self.scroll.appendSlice(self.a, clean) catch {};
            self.scroll.appendSlice(self.a, theme.SGR_PLAIN) catch {};
            self.scroll.appendSlice(self.a, "\r\n") catch {};
            self.wrote = true;
            self.last_blank = false;
        }
        self.dirty = true;
    }

    fn commitLines(self: *Tui, lines: []const stream.BodyLine) void {
        for (lines) |line| self.push(styleLine(self.sa, line));
    }

    fn note(self: *Tui, line: []const u8) void {
        self.separator = true;
        self.push(line);
        self.separator = true;
    }

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
        const loaded = self.opts.loaded;
        self.push(std.fmt.allocPrint(self.s, "{d} agent files · {d} skills", .{
            loaded.agent_files, loaded.skills,
        }) catch "resources");
        self.separator = true;
    }

    fn statusLine(self: *Tui) []const u8 {
        const model = self.opts.model orelse return styles.dim(self.s, "no model configured");
        const used = estimateContextTokens(self.messages.items, self.opts.system_prompt, self.opts.tools_json);
        const usage = contextUsageLine(self.s, used, model);
        if (self.paused or self.phase == .pausing) {
            return std.fmt.allocPrint(self.s, "{s} · {s}", .{ styles.dim(self.s, "paused - type steering, Enter to submit"), usage }) catch usage;
        }
        if (self.active and self.pause_requested.load(.seq_cst)) {
            return std.fmt.allocPrint(self.s, "{s} · {s}", .{ styles.dim(self.s, "pausing - waiting for the step boundary"), usage }) catch usage;
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

    fn queueRows(self: *Tui, width: usize, budget: usize) []const []const u8 {
        if (budget == 0) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        var used: usize = 0;
        for (self.pending_calls.items, 0..) |call, i| {
            for (callRows(self.s, call, i == 0 and self.phase == .running_tool)) |row| {
                const h = physicalRows(row, width);
                if (used + h > budget and out.items.len > 0) break;
                used += h;
                out.append(self.s, row) catch {};
            }
        }
        return out.items;
    }

    fn draw(self: *Tui) void {
        if (self.closed) return;
        self.resetScratch();
        const width = @max(self.term.width(), 1);
        const height = @max(self.term.height() - 1, 1);
        const status = self.statusLine();

        var inflight = self.reply.pending();
        if (inflight.len == 0) inflight = self.activity.pending();
        const rows = plainRows(self.s, inflight);

        const status_rows = physicalRows(status, width);
        const room = if (height > status_rows + 1) height - status_rows - 1 else 0;
        const queue = self.queueRows(width, room);
        var queue_height: usize = 0;
        for (queue) |r| queue_height += physicalRows(r, width);
        const body_budget = if (room > queue_height) room - queue_height else 0;
        var body_start = rows.len;
        var body_used: usize = 0;
        while (body_start > 0) {
            const h = physicalRows(rows[body_start - 1], width);
            if (body_used + h > body_budget) break;
            body_used += h;
            body_start -= 1;
        }
        const body = rows[body_start..];
        const editor_budget = height -| (status_rows + queue_height + body_used);
        const ed = self.editor.layout(width, @max(editor_budget, 1));

        var lines: std.ArrayList([]const u8) = .empty;
        for (body) |r| lines.append(self.s, r) catch {};
        for (queue) |r| lines.append(self.s, r) catch {};
        lines.append(self.s, status) catch {};
        const caret_line = lines.items.len + ed.cursor_row;
        for (ed.rows) |r| lines.append(self.s, r) catch {};

        const frame_text = self.live.draw(self.s, width, lines.items, caret_line, ed.cursor_col, self.scroll.items);
        self.term.write(frame_text);
        self.scroll.clearRetainingCapacity();
        _ = self.sarena.reset(.retain_capacity);
        self.sa = self.sarena.allocator();
    }

    fn keepName(self: *Tui, slot: *?[]const u8, value: ?[]const u8) void {
        if (slot.*) |old| self.a.free(old);
        slot.* = if (value) |v| self.a.dupe(u8, v) catch null else null;
    }

    fn handleAgentEvent(self: *Tui, event: agent.Event) void {
        if (self.closed) return;
        if (self.aborting) return;
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
            self.commitLines(&.{callBody(self.s, call.name, call.summary)});
        }
        const width = @max(self.term.width() - BODY_PREFIX.len, 1);
        const lines: []const stream.BodyLine = if (!is_error and body != null)
            &.{.{ .text = body.? }}
        else
            resultLines(self.s, name, text, is_error);
        const rows = if (std.mem.eql(u8, name, "edit")) plainRows(self.s, lines) else bodyRows(self.s, lines, width);
        for (rows, 0..) |row, i| {
            const prefix = if (is_error and i == rows.len - 1) styles.red(self.s, ERROR_PREFIX) else styles.dim(self.s, BODY_PREFIX);
            self.push(std.fmt.allocPrint(self.s, "{s}{s}", .{ prefix, row }) catch row);
        }
        if (diffs.len > 0) {
            for (plainRows(self.s, diffRows(self.s, diffs))) |row| {
                self.push(std.fmt.allocPrint(self.s, "{s}{s}", .{ styles.dim(self.s, BODY_PREFIX), row }) catch row);
            }
        }
        self.separator = true;
    }

    fn flushCalls(self: *Tui) void {
        for (self.pending_calls.items) |call| {
            self.separator = true;
            self.commitLines(&.{callBody(self.s, call.name, call.summary)});
        }
        self.pending_calls.clearRetainingCapacity();
    }

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
                if (!self.aborting) {
                    self.aborting = true;
                    self.endTurn(styles.red(self.s, "! cancelled"));
                }
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
        self.pause_requested.store(false, .seq_cst);
        self.turn_done.store(false, .seq_cst);
        self.phase = .preparing;
        self.keepName(&self.detail, null);
        self.turn_start = util.nowMs();
        self.frame = 0;
        const t = std.Thread.spawn(.{}, turnThread, .{self}) catch return;
        t.detach();
        self.dirty = true;
    }

    fn runCommand(self: *Tui, command: Command) void {
        switch (command) {
            .help => self.showHelp(),
            .new => {
                self.newSession();
                self.push("");
                self.pushBanner();
                self.note(styles.dim(self.s, "new session"));
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

    fn select(self: *Tui, m: *const types.Model) void {
        self.opts.model = m;
        self.opts.supports_images = m.supports_images;
        self.opts.tools_json = tools_index.json(self.a, self.tool_names, self.opts.supports_images);
        self.pushBanner();
        self.dirty = true;
    }

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
        if (self.abort.load(.seq_cst)) return "";
        self.paused = true;
        self.dirty = true;
        while (!self.steering_ready.load(.seq_cst)) {
            if (self.abort.load(.seq_cst)) {
                self.paused = false;
                self.steering_ready.store(false, .seq_cst);
                return "";
            }
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
        const width = @max(self.term.width(), 1);
        self.term.write(self.live.erase(self.a, width));
        self.term.write(self.scroll.items);
        self.term.stop();
        self.opts.session.close();
    }
};

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

    const all = [_]Command{ .help, .new, .provider, .model, .thinking };
};

fn findCommand(text: []const u8) ?Command {
    if (text.len == 0 or text[0] != '/') return null;
    var i: usize = 1;
    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') i += 1;
    return std.meta.stringToEnum(Command, text[1..i]);
}

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

fn copyEvent(a: std.mem.Allocator, e: agent.Event) agent.Event {
    return switch (e) {
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

pub fn run(opts: agent.Options, cfg: *const config.Config, tool_names: []const config.ToolName) !void {
    const gpa = platform.gpa;
    theme.init(gpa, cfg.theme);
    const opts_ptr = try gpa.create(agent.Options);
    opts_ptr.* = opts;
    const self = try gpa.create(Tui);
    self.* = Tui.init(gpa, opts_ptr, cfg, tool_names);
    self.bindAllocators();

    self.term.start();
    defer self.term.stop();
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
    std.posix.sigaction(std.posix.SIG.HUP, &term_act, null);
    std.posix.sigaction(std.posix.SIG.QUIT, &term_act, null);

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
            self.aborting = false;
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
