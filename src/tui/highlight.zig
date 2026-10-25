const std = @import("std");
const styles = @import("styles.zig");
const render = @import("render.zig");

const Span = struct {
    start: u32,
    end: u32,
    style: styles.Style,
};

const Event = struct { at: u32, open: bool, span: usize, order: usize };

fn eventLess(_: void, x: Event, y: Event) bool {
    if (x.at != y.at) return x.at < y.at;
    if (x.open != y.open) return !x.open and y.open;
    return x.order < y.order;
}

fn paint(a: std.mem.Allocator, text: []const u8, spans: []const Span, base: styles.Style) []u8 {
    var events: std.ArrayList(Event) = .empty;
    for (spans, 0..) |span, i| {
        if (span.end <= span.start or span.start >= text.len) continue;
        events.append(a, .{ .at = span.start, .open = true, .span = i, .order = events.items.len }) catch {};
        events.append(a, .{ .at = @min(span.end, @as(u32, @intCast(text.len))), .open = false, .span = i, .order = events.items.len }) catch {};
    }
    std.mem.sort(Event, events.items, {}, eventLess);

    var out: std.ArrayList(u8) = .empty;
    var active: std.ArrayList(usize) = .empty;
    var plain = true;
    var at: u32 = 0;

    for (events.items) |event| {
        emit(a, &out, &active, spans, text, event.at, &at, &plain, base);
        if (event.open) {
            active.append(a, event.span) catch {};
        } else {
            for (active.items, 0..) |idx, k| {
                if (idx == event.span) {
                    _ = active.orderedRemove(k);
                    break;
                }
            }
        }
    }
    emit(a, &out, &active, spans, text, @intCast(text.len), &at, &plain, base);
    if (!plain) out.appendSlice(a, styles.sgrOn(a, .{}, base)) catch {};
    return out.items;
}

fn emit(a: std.mem.Allocator, out: *std.ArrayList(u8), active: *std.ArrayList(usize), spans: []const Span, text: []const u8, end: u32, at: *u32, plain: *bool, base: styles.Style) void {
    if (end <= at.*) return;
    const reset = styles.sgrOn(a, .{}, base);
    const style: ?styles.Style = if (active.items.len == 0) null else spans[active.items[active.items.len - 1]].style;
    if (style) |s| {
        const sgr = styles.sgrOn(a, s, base);
        out.appendSlice(a, sgr) catch {};
        plain.* = false;
        const chunk = text[at.*..end];
        for (chunk) |c| {
            out.append(a, c) catch {};
            if (c == '\n') out.appendSlice(a, sgr) catch {};
        }
    } else {
        if (!plain.*) out.appendSlice(a, reset) catch {};
        plain.* = true;
        out.appendSlice(a, text[at.*..end]) catch {};
    }
    at.* = end;
}

fn muted() styles.Style {
    return styles.roles.comment;
}

fn isAlnum(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn runLength(line: []const u8, at: usize, c: u8) usize {
    var n: usize = 0;
    while (at + n < line.len and line[at + n] == c) n += 1;
    return n;
}

/// Closing run for `marker` repeated `count` times, ignoring empty or space-padded content.
fn closeRun(line: []const u8, open_at: usize, marker: u8, count: usize, limit: usize) ?usize {
    var i = open_at + count;
    while (i + count <= limit) : (i += 1) {
        if (line[i] != marker) continue;
        if (line[i - 1] == ' ' or line[i - 1] == '\t') continue;
        if (runLength(line, i, marker) < count) continue;
        return i;
    }
    return null;
}

fn addSpan(a: std.mem.Allocator, spans: *std.ArrayList(Span), base: u32, start: usize, end: usize, style: styles.Style) void {
    if (end <= start) return;
    spans.append(a, .{ .start = base + @as(u32, @intCast(start)), .end = base + @as(u32, @intCast(end)), .style = style }) catch {};
}

/// Inline markup inside one prose line. `limit` is the byte index the scan stops at.
fn scanInline(a: std.mem.Allocator, line: []const u8, base: u32, start: usize, limit: usize, spans: *std.ArrayList(Span)) void {
    var i = start;
    while (i < limit) {
        const c = line[i];
        if (c == '`') {
            const n = runLength(line, i, '`');
            var j = i + n;
            while (j + n <= limit) : (j += 1) {
                if (line[j] != '`') continue;
                if (runLength(line, j, '`') < n) continue;
                addSpan(a, spans, base, i, j + n, styles.roles.inline_code);
                i = j + n;
                break;
            } else {
                i += n;
            }
            continue;
        }
        if (c == '*' or c == '_') {
            const n = runLength(line, i, c);
            const count: usize = @min(n, 2);
            const content = i + count;
            // An opener needs content and, for `_`, must not sit inside a word.
            if (content >= limit or line[content] == ' ' or line[content] == '\t' or
                (c == '_' and i > start and isAlnum(line[i - 1])))
            {
                i += n;
                continue;
            }
            if (closeRun(line, i, c, count, limit)) |close| {
                const style: styles.Style = if (count == 2) .{ .bold = true } else .{ .italic = true };
                addSpan(a, spans, base, i, close + count, style);
                i = close + count;
            } else {
                i += n;
            }
            continue;
        }
        if (c == '[') {
            if (std.mem.indexOfScalarPos(u8, line[0..limit], i, ']')) |close| {
                if (close + 1 < limit and line[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, line[0..limit], close + 1, ')')) |end| {
                        addSpan(a, spans, base, i, close + 1, styles.roles.link);
                        addSpan(a, spans, base, close + 1, end + 1, styles.roles.uri);
                        i = end + 1;
                        continue;
                    }
                }
            }
            i += 1;
            continue;
        }
        i += 1;
    }
}

fn leadingSpaces(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    return i;
}

fn headingLevel(line: []const u8) ?usize {
    const at = leadingSpaces(line);
    var n: usize = 0;
    while (at + n < line.len and line[at + n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (at + n < line.len and line[at + n] != ' ' and line[at + n] != '\t') return null;
    return n;
}

fn isFenceMarker(line: []const u8) bool {
    const at = leadingSpaces(line);
    if (at >= line.len) return false;
    const c = line[at];
    if (c != '`' and c != '~') return false;
    return runLength(line, at, c) >= 3;
}

fn isRule(line: []const u8) bool {
    const at = leadingSpaces(line);
    if (at >= line.len) return false;
    const c = line[at];
    if (c != '-' and c != '*' and c != '_') return false;
    var marks: usize = 0;
    for (line[at..]) |ch| {
        if (ch == c) {
            marks += 1;
        } else if (ch != ' ' and ch != '\t' and ch != '\r') {
            return false;
        }
    }
    return marks >= 3;
}

/// Byte offset just past a list or quote marker, or null when the line has none.
fn blockMarker(line: []const u8) ?usize {
    const at = leadingSpaces(line);
    if (at >= line.len) return null;
    const c = line[at];
    if (c == '>' or c == '-' or c == '*' or c == '+') {
        if (at + 1 < line.len and (line[at + 1] == ' ' or line[at + 1] == '\t')) return at + 1;
        return null;
    }
    var n = at;
    while (n < line.len and std.ascii.isDigit(line[n])) n += 1;
    if (n == at or n >= line.len) return null;
    if ((line[n] == '.' or line[n] == ')') and n + 1 < line.len and (line[n + 1] == ' ' or line[n + 1] == '\t')) return n + 1;
    return null;
}

fn markdownLine(a: std.mem.Allocator, line: []const u8, base: u32, spans: *std.ArrayList(Span)) void {
    const limit = line.len;
    if (isFenceMarker(line) or isRule(line)) {
        addSpan(a, spans, base, 0, limit, muted());
        return;
    }
    if (headingLevel(line)) |level| {
        const idx = @min(level, styles.roles.headings.len) - 1;
        addSpan(a, spans, base, 0, limit, styles.roles.headings[idx]);
        return;
    }
    var start: usize = 0;
    if (blockMarker(line)) |after| {
        addSpan(a, spans, base, 0, after, muted());
        start = after;
    }
    scanInline(a, line, base, start, limit, spans);
}

pub fn highlightMarkdown(a: std.mem.Allocator, text: []const u8) []const u8 {
    var spans: std.ArrayList(Span) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    var base: u32 = 0;
    while (it.next()) |line| {
        markdownLine(a, line, base, &spans);
        base += @intCast(line.len + 1);
    }
    return paint(a, text, spans.items, .{});
}

/// Fenced code is styled as one muted block: token-level coloring needs a grammar, and a
/// hand-written approximation costs more than it shows.
pub fn highlightCode(a: std.mem.Allocator, text: []const u8) []const u8 {
    // Stop before the block's trailing newline so the style does not leak a dangling SGR.
    const end = if (text.len > 0 and text[text.len - 1] == '\n') text.len - 1 else text.len;
    const spans = [_]Span{.{ .start = 0, .end = @intCast(end), .style = .{ .fg = styles.roles.code } }};
    return paint(a, text, &spans, .{});
}

pub const DiffKind = enum { hunk, add, del, ctx, note };

fn isFileHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ");
}

/// Classify one diff line by its first byte. `in_hunk` disambiguates `---`/`+++` file
/// headers from removed/added content once a hunk header has been seen.
pub fn diffKind(line: []const u8, in_hunk: bool) DiffKind {
    if (std.mem.startsWith(u8, line, "@@")) return .hunk;
    if (std.mem.startsWith(u8, line, "\\")) return .note;
    if (in_hunk) {
        if (line.len > 0 and line[0] == '+') return .add;
        if (line.len > 0 and line[0] == '-') return .del;
        return .ctx;
    }
    if (isFileHeader(line)) return .note;
    if (line.len > 0 and line[0] == '+') return .add;
    if (line.len > 0 and line[0] == '-') return .del;
    return .note;
}

const Align = enum { none, left, center, right };

fn alignOf(cell: []const u8) Align {
    const left = cell.len > 0 and cell[0] == ':';
    const right = cell.len > 1 and cell[cell.len - 1] == ':';
    if (left and right) return .center;
    if (left) return .left;
    if (right) return .right;
    return .none;
}

fn splitCells(a: std.mem.Allocator, line: []const u8) []const []const u8 {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    var cells: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i < trimmed.len) : (i += 1) {
        if (trimmed[i] == '\\' and i + 1 < trimmed.len) {
            i += 1;
            continue;
        }
        if (trimmed[i] == '|') {
            cells.append(a, std.mem.trim(u8, trimmed[start..i], " \t")) catch {};
            start = i + 1;
        }
    }
    cells.append(a, std.mem.trim(u8, trimmed[start..], " \t")) catch {};
    if (trimmed.len > 0 and trimmed[0] == '|' and cells.items.len > 0) _ = cells.orderedRemove(0);
    if (trimmed.len > 1 and trimmed[trimmed.len - 1] == '|' and cells.items.len > 0) _ = cells.pop();
    return cells.items;
}

/// Delimiter row (`|---|:--:|`) as per-column alignments, or null when the line is not one.
fn delimiterRow(a: std.mem.Allocator, line: []const u8) ?[]const Align {
    if (std.mem.indexOfScalar(u8, line, '-') == null) return null;
    const cells = splitCells(a, line);
    if (cells.len == 0) return null;
    const aligns = a.alloc(Align, cells.len) catch return null;
    for (cells, 0..) |cell, k| {
        var body = cell;
        if (body.len > 0 and body[0] == ':') body = body[1..];
        if (body.len > 0 and body[body.len - 1] == ':') body = body[0 .. body.len - 1];
        if (body.len == 0) return null;
        for (body) |c| {
            if (c != '-') return null;
        }
        aligns[k] = alignOf(cell);
    }
    return aligns;
}

fn tableCandidate(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return false;
    // Tables nested in quotes or lists keep their marker; reflowing them would drop it.
    if (trimmed[0] == '>' or trimmed[0] == '-' or trimmed[0] == '*' or trimmed[0] == '+') return false;
    return std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

fn rowCells(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    return trimmed.len > 0 and std.mem.indexOfScalar(u8, trimmed, '|') != null;
}

fn emitRow(a: std.mem.Allocator, block: *std.ArrayList(u8), cells: []const []const u8, named: usize, widths: []const usize, aligns: []const Align, delimiter: bool) void {
    block.append(a, '|') catch {};
    for (0..named) |k| {
        const cell = if (k < cells.len) cells[k] else "";
        const alignment = aligns[k];
        block.append(a, ' ') catch {};
        if (delimiter) {
            block.append(a, if (alignment == .left or alignment == .center) ':' else '-') catch {};
            block.appendNTimes(a, '-', widths[k] - 2) catch {};
            block.append(a, if (alignment == .right or alignment == .center) ':' else '-') catch {};
        } else {
            const pad = widths[k] - render.displayWidth(cell);
            const before: usize = switch (alignment) {
                .right => pad,
                .center => pad / 2,
                else => 0,
            };
            block.appendNTimes(a, ' ', before) catch {};
            block.appendSlice(a, cell) catch {};
            block.appendNTimes(a, ' ', pad - before) catch {};
        }
        block.appendSlice(a, " |") catch {};
    }
}

fn formatTable(a: std.mem.Allocator, header: []const u8, aligns: []const Align, body: []const []const u8, trailing: bool) ?[]const u8 {
    const named = aligns.len;
    const rows = a.alloc([]const []const u8, body.len + 1) catch return null;
    rows[0] = splitCells(a, header);
    if (rows[0].len != named) return null;
    for (body, 0..) |line, i| {
        const cells = splitCells(a, line);
        if (cells.len > named) return null;
        rows[i + 1] = cells;
    }

    const widths = a.alloc(usize, named) catch return null;
    @memset(widths, 3);
    for (rows) |cells| {
        for (cells, 0..) |cell, k| widths[k] = @max(widths[k], render.displayWidth(cell));
    }

    var block: std.ArrayList(u8) = .empty;
    for (rows, 0..) |cells, r| {
        if (r > 0) block.append(a, '\n') catch {};
        emitRow(a, &block, cells, named, widths, aligns, false);
        if (r == 0) {
            block.append(a, '\n') catch {};
            emitRow(a, &block, &.{}, named, widths, aligns, true);
        }
    }
    if (trailing) block.append(a, '\n') catch {};
    return block.items;
}

pub fn formatTables(a: std.mem.Allocator, text: []const u8) []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| lines.append(a, line) catch {};

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        if (i + 1 < lines.items.len and tableCandidate(line)) {
            if (delimiterRow(a, lines.items[i + 1])) |aligns| {
                var end = i + 2;
                while (end < lines.items.len and rowCells(lines.items[end])) end += 1;
                const block = formatTable(a, line, aligns, lines.items[i + 2 .. end], end < lines.items.len);
                if (block) |b| {
                    out.appendSlice(a, b) catch {};
                    i = end;
                    continue;
                }
            }
        }
        out.appendSlice(a, line) catch {};
        out.append(a, '\n') catch {};
        i += 1;
    }
    // A single trailing split always leaves one empty entry; drop its newline.
    if (out.items.len > 0 and text.len > 0 and text[text.len - 1] != '\n' and out.items[out.items.len - 1] == '\n')
        out.items.len -= 1;
    return out.items;
}
