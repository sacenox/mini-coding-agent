const std = @import("std");
const ts = @import("tree-sitter");
const render = @import("render.zig");
const theme = @import("theme.zig");

extern fn tree_sitter_javascript() callconv(.c) *const ts.Language;
extern fn tree_sitter_typescript() callconv(.c) *const ts.Language;
extern fn tree_sitter_tsx() callconv(.c) *const ts.Language;
extern fn tree_sitter_markdown() callconv(.c) *const ts.Language;
extern fn tree_sitter_markdown_inline() callconv(.c) *const ts.Language;
extern fn tree_sitter_python() callconv(.c) *const ts.Language;
extern fn tree_sitter_go() callconv(.c) *const ts.Language;
extern fn tree_sitter_zig() callconv(.c) *const ts.Language;
extern fn tree_sitter_bash() callconv(.c) *const ts.Language;
extern fn tree_sitter_diff() callconv(.c) *const ts.Language;

const JS_QUERIES = @embedFile("js_highlights");
const TS_QUERIES = @embedFile("ts_highlights");
const MD_QUERIES = @embedFile("md_highlights");
const MD_TABLES = @embedFile("md_tables");
const MD_INLINE_QUERIES = @embedFile("md_inline_highlights");
const PY_QUERIES = @embedFile("py_highlights");
const GO_QUERIES = @embedFile("go_highlights");
const ZIG_QUERIES = @embedFile("zig_highlights");
const BASH_QUERIES = @embedFile("bash_highlights");
const DIFF_QUERIES = @embedFile("diff_highlights");

const Syntax = struct {
    parser: *ts.Parser,
    query: *ts.Query,
};

fn syntax(a: std.mem.Allocator, language: *const ts.Language, sources: []const []const u8) ?Syntax {
    const parser = ts.Parser.create();
    parser.setLanguage(language) catch {
        parser.destroy();
        return null;
    };
    var source: std.ArrayList(u8) = .empty;
    for (sources, 0..) |s, i| {
        if (i > 0) source.append(a, '\n') catch {};
        source.appendSlice(a, s) catch {};
    }
    var error_offset: u32 = 0;
    const query = ts.Query.create(language, source.items, &error_offset) catch {
        parser.destroy();
        return null;
    };
    return .{ .parser = parser, .query = query };
}

var grammars: ?Grammars = null;

const Lang = enum { javascript, typescript, tsx, markdown, markdown_inline, python, go, zig, bash, diff };

fn load(a: std.mem.Allocator, lang: Lang) Syntax {
    return switch (lang) {
        .javascript => syntax(a, tree_sitter_javascript(), &.{JS_QUERIES}) orelse unreachable,
        .typescript => syntax(a, tree_sitter_typescript(), &.{ JS_QUERIES, TS_QUERIES }) orelse unreachable,
        .tsx => syntax(a, tree_sitter_tsx(), &.{ JS_QUERIES, TS_QUERIES }) orelse unreachable,
        .markdown => syntax(a, tree_sitter_markdown(), &.{ MD_QUERIES, MD_TABLES }) orelse unreachable,
        .markdown_inline => syntax(a, tree_sitter_markdown_inline(), &.{MD_INLINE_QUERIES}) orelse unreachable,
        .python => syntax(a, tree_sitter_python(), &.{PY_QUERIES}) orelse unreachable,
        .go => syntax(a, tree_sitter_go(), &.{GO_QUERIES}) orelse unreachable,
        .zig => syntax(a, tree_sitter_zig(), &.{ZIG_QUERIES}) orelse unreachable,
        .bash => syntax(a, tree_sitter_bash(), &.{BASH_QUERIES}) orelse unreachable,
        .diff => syntax(a, tree_sitter_diff(), &.{DIFF_QUERIES}) orelse unreachable,
    };
}

const Grammars = struct {
    slots: [@typeInfo(Lang).@"enum".fields.len]?Syntax = @splat(null),

    fn get(self: *Grammars, a: std.mem.Allocator, lang: Lang) *Syntax {
        const slot = &self.slots[@intFromEnum(lang)];
        if (slot.* == null) slot.* = load(a, lang);
        return &slot.*.?;
    }
};

fn getGrammars() *Grammars {
    if (grammars == null) grammars = .{};
    return &grammars.?;
}

pub const Span = struct {
    start: u32,
    end: u32,
    style: theme.Style,
};

fn captureNode(match: ts.Query.Match, index: u32) ?ts.Node {
    for (match.captures) |capture| {
        if (capture.index == index) return capture.node;
    }
    return null;
}

fn nodeText(u: Utf16, text: []const u8, node: ts.Node) []const u8 {
    return text[byteOf(u, node.startByte() / 2)..byteOf(u, node.endByte() / 2)];
}

extern fn regcomp(preg: *anyopaque, regex: [*:0]const u8, cflags: c_int) c_int;
extern fn regexec(preg: *const anyopaque, string: [*:0]const u8, nmatch: usize, pmatch: ?*anyopaque, eflags: c_int) c_int;
extern fn regfree(preg: *anyopaque) void;

const REG_EXTENDED: c_int = 1;
const REG_NOMATCH: c_int = 1;

fn matchesRegex(a: std.mem.Allocator, pattern: []const u8, text: []const u8) bool {
    const pat = a.dupeZ(u8, pattern) catch return false;
    defer a.free(pat);
    const subject = a.dupeZ(u8, text) catch return false;
    defer a.free(subject);
    var regex: [512]u8 align(16) = undefined;
    if (regcomp(&regex, pat.ptr, REG_EXTENDED) != 0) return false;
    defer regfree(&regex);
    return regexec(&regex, subject.ptr, 0, null, 0) != REG_NOMATCH;
}

fn eqText(query: *const ts.Query, match: ts.Query.Match, steps: []const ts.Query.PredicateStep, u: Utf16, text: []const u8) bool {
    if (steps.len < 2) return true;
    const left = predicateArg(query, match, steps[0], u, text) orelse return false;
    const right = predicateArg(query, match, steps[1], u, text) orelse return false;
    return std.mem.eql(u8, left, right);
}

fn predicateArg(query: *const ts.Query, match: ts.Query.Match, step: ts.Query.PredicateStep, u: Utf16, text: []const u8) ?[]const u8 {
    switch (step.type) {
        .capture => {
            const node = captureNode(match, step.value_id) orelse return null;
            return nodeText(u, text, node);
        },
        .string => return query.stringValueForId(step.value_id),
        .done => return null,
    }
}

fn predicatesPass(a: std.mem.Allocator, query: *const ts.Query, match: ts.Query.Match, u: Utf16, text: []const u8) bool {
    const steps = query.predicatesForPattern(match.pattern_index);
    var i: usize = 0;
    while (i < steps.len) {
        if (steps[i].type == .done) {
            i += 1;
            continue;
        }
        const name = if (steps[i].type == .string) query.stringValueForId(steps[i].value_id) else null;
        var j = i + 1;
        while (j < steps.len and steps[j].type != .done) j += 1;
        const args = steps[i + 1 .. j];
        const ok = evalPredicate(a, query, match, name, args, u, text);
        if (!ok) return false;
        i = j + 1;
    }
    return true;
}

fn evalPredicate(a: std.mem.Allocator, query: *const ts.Query, match: ts.Query.Match, name: ?[]const u8, args: []const ts.Query.PredicateStep, u: Utf16, text: []const u8) bool {
    const n = name orelse return true;
    if (std.mem.eql(u8, n, "eq?")) return eqText(query, match, args, u, text);
    if (std.mem.eql(u8, n, "not-eq?")) return !eqText(query, match, args, u, text);
    if (std.mem.eql(u8, n, "match?") or std.mem.eql(u8, n, "not-match?")) {
        if (args.len < 2) return true;
        const cap = predicateArg(query, match, args[0], u, text) orelse return false;
        const pattern = predicateArg(query, match, args[1], u, text) orelse return false;
        const found = matchesRegex(a, pattern, cap);
        return if (std.mem.eql(u8, n, "match?")) found else !found;
    }
    if (std.mem.eql(u8, n, "any-of?") or std.mem.eql(u8, n, "not-any-of?")) {
        if (args.len < 2) return true;
        const cap = predicateArg(query, match, args[0], u, text) orelse return false;
        var found = false;
        for (args[1..]) |arg| {
            const candidate = predicateArg(query, match, arg, u, text) orelse continue;
            if (std.mem.eql(u8, cap, candidate)) found = true;
        }
        return if (std.mem.eql(u8, n, "any-of?")) found else !found;
    }
    return true;
}

fn spansOf(a: std.mem.Allocator, syn: *Syntax, node: ts.Node, u: Utf16, text: []const u8, offset: u32) []Span {
    var spans: std.ArrayList(Span) = .empty;
    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(syn.query, node);
    while (cursor.nextCapture()) |pair| {
        const match = pair[1];
        if (!predicatesPass(a, syn.query, match, u, text)) continue;
        const capture = match.captures[pair[0]];
        const name = syn.query.captureNameForId(capture.index) orelse continue;
        const style = theme.styleFor(name) orelse continue;
        if (capture.node.endByte() <= capture.node.startByte()) continue;
        spans.append(a, .{
            .start = offset + byteOf(u, capture.node.startByte() / 2),
            .end = offset + byteOf(u, capture.node.endByte() / 2),
            .style = style,
        }) catch {};
    }
    return spans.toOwnedSlice(a) catch &.{};
}

fn collectByKind(a: std.mem.Allocator, node: ts.Node, kinds: []const []const u8, out: *std.ArrayList(ts.Node)) void {
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const child = node.child(i) orelse continue;
        for (kinds) |kind| {
            if (std.mem.eql(u8, child.kind(), kind)) {
                out.append(a, child) catch {};
                break;
            }
        }
        collectByKind(a, child, kinds, out);
    }
}

fn recolor(a: std.mem.Allocator, spans: []Span, start: u32, end: u32, style: theme.Style) []Span {
    var kept: std.ArrayList(Span) = .empty;
    for (spans) |span| {
        if (span.start < start or span.end > end) kept.append(a, span) catch {};
    }
    kept.append(a, .{ .start = start, .end = end, .style = style }) catch {};
    return kept.toOwnedSlice(a) catch spans;
}

const Event = struct { at: u32, open: bool, span: usize, order: usize };

fn eventLess(_: void, x: Event, y: Event) bool {
    if (x.at != y.at) return x.at < y.at;
    if (x.open != y.open) return !x.open and y.open;
    return x.order < y.order;
}

pub fn paint(a: std.mem.Allocator, text: []const u8, spans: []const Span, base: theme.Style) []u8 {
    var events: std.ArrayList(Event) = .empty;
    for (spans, 0..) |span, i| {
        if (span.end <= span.start) continue;
        events.append(a, .{ .at = span.start, .open = true, .span = i, .order = events.items.len }) catch {};
        events.append(a, .{ .at = span.end, .open = false, .span = i, .order = events.items.len }) catch {};
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
    if (!plain) out.appendSlice(a, theme.sgrOn(a, .{}, base)) catch {};
    return out.items;
}

fn emit(a: std.mem.Allocator, out: *std.ArrayList(u8), active: *std.ArrayList(usize), spans: []const Span, text: []const u8, end: u32, at: *u32, plain: *bool, base: theme.Style) void {
    if (end <= at.*) return;
    const reset = theme.sgrOn(a, .{}, base);
    const style: ?theme.Style = if (active.items.len == 0) null else spans[active.items[active.items.len - 1]].style;
    if (style) |s| {
        const sgr = theme.sgrOn(a, s, base);
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

fn langFor(lang: []const u8) ?Lang {
    if (std.mem.eql(u8, lang, "js") or std.mem.eql(u8, lang, "javascript") or std.mem.eql(u8, lang, "jsx")) return .javascript;
    if (std.mem.eql(u8, lang, "ts") or std.mem.eql(u8, lang, "typescript")) return .typescript;
    if (std.mem.eql(u8, lang, "tsx")) return .tsx;
    if (std.mem.eql(u8, lang, "py") or std.mem.eql(u8, lang, "python")) return .python;
    if (std.mem.eql(u8, lang, "go") or std.mem.eql(u8, lang, "golang")) return .go;
    if (std.mem.eql(u8, lang, "zig")) return .zig;
    if (std.mem.eql(u8, lang, "bash") or std.mem.eql(u8, lang, "sh") or std.mem.eql(u8, lang, "shell")) return .bash;
    return null;
}

fn syntaxFor(g: *Grammars, a: std.mem.Allocator, lang: []const u8) ?*Syntax {
    return g.get(a, langFor(lang) orelse return null);
}

fn infoLang(info: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, info, " \t\r\n");
    var end: usize = 0;
    while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t') end += 1;
    return trimmed[0..end];
}

pub fn spansFor(a: std.mem.Allocator, info: []const u8, text: []const u8) []const Span {
    const g = getGrammars();
    const lang = std.ascii.allocLowerString(a, infoLang(info)) catch infoLang(info);
    const s = syntaxFor(g, a, lang) orelse return &.{};
    const u = utf16(a, text) orelse return &.{};
    const root = parse(s.parser, u) orelse return &.{};
    defer root.destroy();
    return spansOf(a, s, root.rootNode(), u, text, 0);
}

pub fn highlightOn(a: std.mem.Allocator, info: []const u8, text: []const u8, base: theme.Style) []const u8 {
    return paint(a, text, spansFor(a, info, text), base);
}

pub const NodeSpan = struct { start: u32, end: u32, kind: []const u8 };

const diff_line_kinds = [_][]const u8{
    "file_change", "binary_change", "index",    "similarity", "dissimilarity",
    "old_file",    "new_file",      "location", "addition",   "deletion",
    "change",      "context",       "comment",  "special",    "unrecognized",
};

pub fn isDiffLineKind(kind: []const u8) bool {
    for (diff_line_kinds) |k| {
        if (std.mem.eql(u8, kind, k)) return true;
    }
    return false;
}

fn collectDiffNodes(a: std.mem.Allocator, node: ts.Node, u: Utf16, out: *std.ArrayList(NodeSpan)) void {
    if (isDiffLineKind(node.kind())) {
        out.append(a, .{
            .start = byteOf(u, node.startByte() / 2),
            .end = byteOf(u, node.endByte() / 2),
            .kind = node.kind(),
        }) catch {};
        return;
    }
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const child = node.child(i) orelse continue;
        collectDiffNodes(a, child, u, out);
    }
}

pub fn diffSpans(a: std.mem.Allocator, text: []const u8) []NodeSpan {
    const g = getGrammars();
    const u = utf16(a, text) orelse return &.{};
    const root = parse(g.get(a, .diff).parser, u) orelse return &.{};
    defer root.destroy();
    var out: std.ArrayList(NodeSpan) = .empty;
    collectDiffNodes(a, root.rootNode(), u, &out);
    return out.items;
}

pub fn highlightCode(a: std.mem.Allocator, info: []const u8, text: []const u8) []const u8 {
    return highlightOn(a, info, text, .{});
}

pub fn highlightMarkdown(a: std.mem.Allocator, text: []const u8) []const u8 {
    const g = getGrammars();
    const u = utf16(a, text) orelse return text;
    const root = parse(g.get(a, .markdown).parser, u) orelse return text;
    defer root.destroy();
    var spans: std.ArrayList(Span) = .empty;
    spans.appendSlice(a, spansOf(a, g.get(a, .markdown), root.rootNode(), u, text, 0)) catch {};

    var inline_nodes: std.ArrayList(ts.Node) = .empty;
    collectByKind(a, root.rootNode(), &.{ "inline", "pipe_table_cell" }, &inline_nodes);
    for (inline_nodes.items) |node| {
        const start = byteOf(u, node.startByte() / 2);
        const inline_text = text[start..byteOf(u, node.endByte() / 2)];
        const iu = utf16(a, inline_text) orelse continue;
        const inline_root = parse(g.get(a, .markdown_inline).parser, iu) orelse continue;
        defer inline_root.destroy();
        spans.appendSlice(a, spansOf(a, g.get(a, .markdown_inline), inline_root.rootNode(), iu, inline_text, start)) catch {};
        var code_spans: std.ArrayList(ts.Node) = .empty;
        collectByKind(a, inline_root.rootNode(), &.{"code_span"}, &code_spans);
        for (code_spans.items) |code| spans = std.ArrayList(Span).fromOwnedSlice(recolor(
            a,
            spans.items,
            start + byteOf(iu, code.startByte() / 2),
            start + byteOf(iu, code.endByte() / 2),
            theme.current.inline_code,
        ));
    }

    var headings: std.ArrayList(ts.Node) = .empty;
    collectByKind(a, root.rootNode(), &.{ "atx_heading", "setext_heading" }, &headings);
    for (headings.items) |heading| {
        var level: usize = 1;
        var i: u32 = 0;
        while (i < heading.childCount()) : (i += 1) {
            const child = heading.child(i) orelse continue;
            const kind = child.kind();
            if (std.mem.startsWith(u8, kind, "atx_h") or std.mem.startsWith(u8, kind, "setext_h")) {
                var digits: usize = 0;
                for (kind) |c| {
                    if (c >= '0' and c <= '9') digits = digits * 10 + (c - '0');
                }
                if (digits > 0) level = digits;
                break;
            }
        }
        const idx = @min(level, theme.current.headings.len) - 1;
        spans = std.ArrayList(Span).fromOwnedSlice(recolor(a, spans.items, byteOf(u, heading.startByte() / 2), byteOf(u, heading.endByte() / 2), theme.current.headings[idx]));
    }
    return paint(a, text, spans.items, .{});
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

const Row = struct { cells: []const []const u8, delimiter: bool };

fn formatTable(a: std.mem.Allocator, text: []const u8, u: Utf16, table: ts.Node) ?[]const u8 {
    var rows: std.ArrayList(Row) = .empty;
    var named: usize = 0;
    var i: u32 = 0;
    while (i < table.childCount()) : (i += 1) {
        const child = table.child(i) orelse continue;
        const kind = child.kind();
        const delimiter = std.mem.eql(u8, kind, "pipe_table_delimiter_row");
        const header = std.mem.eql(u8, kind, "pipe_table_header");
        if (!delimiter and !header and !std.mem.eql(u8, kind, "pipe_table_row")) continue;
        var cells: std.ArrayList([]const u8) = .empty;
        var j: u32 = 0;
        while (j < child.childCount()) : (j += 1) {
            const cell = child.child(j) orelse continue;
            const cell_kind = cell.kind();
            if (!std.mem.eql(u8, cell_kind, "pipe_table_cell") and !std.mem.eql(u8, cell_kind, "pipe_table_delimiter_cell")) continue;
            const span = text[byteOf(u, cell.startByte() / 2)..byteOf(u, cell.endByte() / 2)];
            cells.append(a, std.mem.trim(u8, span, " \t")) catch {};
        }
        if (header) named = cells.items.len;
        rows.append(a, .{ .cells = cells.items, .delimiter = delimiter }) catch {};
    }
    if (rows.items.len == 0 or named == 0) return null;

    const aligns = a.alloc(Align, named) catch return null;
    const widths = a.alloc(usize, named) catch return null;
    @memset(aligns, .none);
    @memset(widths, 3);
    for (rows.items) |row| {
        for (row.cells, 0..) |cell, k| {
            if (k >= named) break;
            if (row.delimiter) aligns[k] = alignOf(cell) else widths[k] = @max(widths[k], render.displayWidth(cell));
        }
    }

    const end = byteOf(u, table.endByte() / 2);
    const trailing = end > 0 and end <= text.len and text[end - 1] == '\n';

    var block: std.ArrayList(u8) = .empty;
    for (rows.items, 0..) |row, r| {
        if (r > 0) block.append(a, '\n') catch {};
        block.append(a, '|') catch {};
        for (0..named) |k| {
            const cell = if (k < row.cells.len) row.cells[k] else "";
            const alignment = aligns[k];
            block.append(a, ' ') catch {};
            if (row.delimiter) {
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
    if (trailing) block.append(a, '\n') catch {};
    return block.items;
}

pub fn formatTables(a: std.mem.Allocator, text: []const u8) []const u8 {
    const u = utf16(a, text) orelse return text;
    const root = parse(getGrammars().get(a, .markdown).parser, u) orelse return text;
    defer root.destroy();
    var tables: std.ArrayList(ts.Node) = .empty;
    collectByKind(a, root.rootNode(), &.{"pipe_table"}, &tables);

    var out: std.ArrayList(u8) = .empty;
    var at: u32 = 0;
    var found = false;
    for (tables.items) |table| {
        const parent = table.parent() orelse continue;
        if (!std.mem.eql(u8, parent.kind(), "section")) continue;
        const start = byteOf(u, table.startByte() / 2);
        const end = byteOf(u, table.endByte() / 2);
        const block = formatTable(a, text, u, table) orelse continue;
        out.appendSlice(a, text[at..start]) catch {};
        out.appendSlice(a, block) catch {};
        at = end;
        found = true;
    }
    if (!found) return text;
    out.appendSlice(a, text[at..]) catch {};
    return out.items;
}

const Utf16 = struct {
    units: []u16,
    byte_of: []u32,
};

fn utf16(a: std.mem.Allocator, text: []const u8) ?Utf16 {
    const units = std.unicode.utf8ToUtf16LeAlloc(a, text) catch return null;
    const byte_of = a.alloc(u32, units.len + 1) catch return null;
    var i: usize = 0;
    var u: usize = 0;
    while (u < units.len) {
        byte_of[u] = @intCast(i);
        if (units[u] >= 0xd800 and units[u] <= 0xdbff and u + 1 < units.len and
            units[u + 1] >= 0xdc00 and units[u + 1] <= 0xdfff)
        {
            byte_of[u + 1] = @intCast(i);
            u += 2;
        } else {
            u += 1;
        }
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(@as(usize, n), text.len - i);
    }
    byte_of[units.len] = @intCast(text.len);
    return .{ .units = units, .byte_of = byte_of };
}

fn byteOf(u: Utf16, unit: u32) u32 {
    return if (unit < u.byte_of.len) u.byte_of[unit] else u.byte_of[u.byte_of.len - 1];
}

fn parse(parser: *ts.Parser, u: Utf16) ?*ts.Tree {
    return parser.parseStringEncoding(std.mem.sliceAsBytes(u.units), null, .utf16le);
}
