const std = @import("std");
const styles = @import("styles.zig");
const format = @import("format.zig");

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

fn codeSpanEnd(line: []const u8, at: usize, limit: usize) ?usize {
    const n = runLength(line, at, '`');
    var i = at + n;
    while (i < limit) : (i += 1) {
        if (line[i] == '`' and runLength(line, i, '`') >= n) return i + n;
    }
    return null;
}

fn closeRun(line: []const u8, open_at: usize, marker: u8, count: usize, limit: usize) ?usize {
    var i = open_at + count;
    while (i + count <= limit) : (i += 1) {
        if (line[i] == '\\') {
            i += 1;
            continue;
        }
        if (line[i] == '`') {
            i = (codeSpanEnd(line, i, limit) orelse i + runLength(line, i, '`')) - 1;
            continue;
        }
        if (line[i] != marker) continue;
        if (line[i - 1] == ' ' or line[i - 1] == '\t') continue;
        const run = runLength(line, i, marker);
        if (run < count) continue;
        if (marker == '_' and i + run < limit and isAlnum(line[i + run])) continue;
        return i;
    }
    return null;
}

fn emphasis(count: usize) styles.Style {
    return switch (count) {
        1 => .{ .italic = true },
        2 => .{ .bold = true },
        else => .{ .bold = true, .italic = true },
    };
}

fn addSpan(a: std.mem.Allocator, spans: *std.ArrayList(Span), base: u32, start: usize, end: usize, style: styles.Style) void {
    if (end <= start) return;
    spans.append(a, .{ .start = base + @as(u32, @intCast(start)), .end = base + @as(u32, @intCast(end)), .style = style }) catch {};
}

fn scanInline(a: std.mem.Allocator, line: []const u8, base: u32, start: usize, limit: usize, spans: *std.ArrayList(Span)) void {
    var i = start;
    while (i < limit) {
        const c = line[i];
        if (c == '\\' and i + 1 < limit) {
            i += 2;
            continue;
        }
        if (c == '`') {
            const n = runLength(line, i, '`');
            const end = codeSpanEnd(line, i, limit) orelse {
                i += n;
                continue;
            };
            addSpan(a, spans, base, i, end, styles.roles.inline_code);
            i = end;
            continue;
        }
        if (c == '*' or c == '_') {
            const n = runLength(line, i, c);
            const count: usize = @min(n, 3);
            const content = i + count;
            if (content >= limit or line[content] == ' ' or line[content] == '\t' or
                (c == '_' and i > start and isAlnum(line[i - 1])))
            {
                i += n;
                continue;
            }
            if (closeRun(line, i, c, count, limit)) |close| {
                addSpan(a, spans, base, i, close + count, emphasis(count));
                scanInline(a, line, base, content, close, spans);
                i = close + count;
            } else {
                i += n;
            }
            continue;
        }
        if (c == '[') {
            if (format.closeBracket(line[0..limit], i)) |close| {
                if (close + 1 < limit and line[close + 1] == '(') {
                    if (format.linkEnd(line[0..limit], close + 1)) |end| {
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

fn blockMarker(line: []const u8) ?usize {
    var at: usize = 0;
    while (at < line.len and (line[at] == ' ' or line[at] == '\t')) at += 1;
    if (at >= line.len) return null;
    const c = line[at];
    if (c == '>' or c == '-' or c == '*' or c == '+') {
        if (at + 1 >= line.len or line[at + 1] == ' ' or line[at + 1] == '\t') return at + 1;
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
    if (format.fenceRun(line) != null or format.isRule(line[leadingSpaces(line)..])) {
        addSpan(a, spans, base, 0, limit, muted());
        return;
    }
    var start: usize = 0;
    while (blockMarker(line[start..])) |after| {
        addSpan(a, spans, base, start, start + after, muted());
        start += after;
    }
    const rest = line[start..];
    if (format.heading(rest[leadingSpaces(rest)..])) |h| {
        addSpan(a, spans, base, start, limit, styles.roles.heading(h.level));
        return;
    }
    if (format.fenceRun(rest) != null or format.isRule(rest)) {
        addSpan(a, spans, base, start, limit, muted());
        return;
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

pub fn highlightCode(a: std.mem.Allocator, text: []const u8) []const u8 {
    const end = if (text.len > 0 and text[text.len - 1] == '\n') text.len - 1 else text.len;
    const spans = [_]Span{.{ .start = 0, .end = @intCast(end), .style = styles.roles.code }};
    return paint(a, text, &spans, .{});
}

pub const DiffKind = enum { hunk, add, del, ctx, note };

fn isFileHeader(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "--- ") or std.mem.startsWith(u8, line, "+++ ");
}

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
