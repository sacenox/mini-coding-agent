const std = @import("std");
const common = @import("../tools/common.zig");
const theme = @import("theme.zig");
const highlight = @import("highlight.zig");
const render = @import("render.zig");

const BodyLine = render.BodyLine;

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

pub fn diffLines(a: std.mem.Allocator, path: []const u8, lines: []const []const u8) []const BodyLine {
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

    var out: std.ArrayList(BodyLine) = .empty;
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

pub fn diffBody(a: std.mem.Allocator, d: common.FileDiff) []const BodyLine {
    if (d.patch) |patch| {
        const trimmed = std.mem.trimEnd(u8, patch, " \t\r\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        var body: std.ArrayList([]const u8) = .empty;
        while (it.next()) |l| body.append(a, l) catch {};
        return diffLines(a, d.path, body.items);
    }
    var out: std.ArrayList(BodyLine) = .empty;
    if (d.note) |note| out.append(a, .{ .text = note, .style = .{ .fg = theme.current.comment } }) catch {};
    return out.items;
}
