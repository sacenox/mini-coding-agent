const std = @import("std");

/// A single compiled gitignore pattern.
const Pattern = struct {
    /// Pattern text with leading `!`, leading `/` and trailing `/` stripped.
    text: []const u8,
    /// Re-include rather than ignore.
    negated: bool,
    /// Match directories only (trailing `/`).
    dir_only: bool,
    /// Match the full path relative to the source dir, not the basename.
    anchored: bool,
};

/// One `.gitignore` file's rules and the directory they were read from.
const Source = struct {
    base: []const u8,
    patterns: []const Pattern,
};

/// Compile a single line. Returns null for blanks and comments.
fn compilePattern(a: std.mem.Allocator, raw: []const u8) ?Pattern {
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) {
        if (end >= 2 and line[end - 2] == '\\') break;
        end -= 1;
    }
    line = line[0..end];
    if (line.len == 0 or line[0] == '#') return null;

    var negated = false;
    if (line[0] == '!') {
        negated = true;
        line = line[1..];
    }

    var anchored = false;
    if (line.len > 0 and line[0] == '/') {
        anchored = true;
        line = line[1..];
    }
    var dir_only = false;
    if (line.len > 0 and line[line.len - 1] == '/') {
        dir_only = true;
        line = line[0 .. line.len - 1];
    }
    if (line.len == 0) return null;
    if (std.mem.indexOfScalar(u8, line, '/') != null) anchored = true;

    return .{
        .text = a.dupe(u8, line) catch return null,
        .negated = negated,
        .dir_only = dir_only,
        .anchored = anchored,
    };
}

fn classMatch(pat: []const u8, p: *usize, c: u8) bool {
    var i = p.* + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pat.len and (pat[i] != ']' or first)) {
        first = false;
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            if (c >= pat[i] and c <= pat[i + 2]) matched = true;
            i += 3;
        } else {
            if (c == pat[i]) matched = true;
            i += 1;
        }
    }
    if (i >= pat.len) {
        p.* += 1;
        return c == '[';
    }
    p.* = i + 1;
    return matched != negate;
}

fn matchChar(pat: []const u8, p: *usize, c: u8) bool {
    switch (pat[p.*]) {
        '?' => {
            p.* += 1;
            return true;
        },
        '[' => return classMatch(pat, p, c),
        '\\' => {
            if (p.* + 1 < pat.len) p.* += 1;
            const lit = pat[p.*];
            p.* += 1;
            return lit == c;
        },
        else => |ch| {
            p.* += 1;
            return ch == c;
        },
    }
}

/// Glob match within one path segment (`*` and `?` never cross `/`).
fn segmentMatch(pat: []const u8, s: []const u8) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var star_i: usize = 0;
    while (i < s.len) {
        if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            star_i = i;
        } else if (p < pat.len and matchChar(pat, &p, s[i])) {
            i += 1;
        } else if (star) |sp| {
            star_i += 1;
            i = star_i;
            p = sp + 1;
        } else return false;
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

/// End index (exclusive) of the pattern segment starting at `start`.
fn segmentEnd(pat: []const u8, start: usize) usize {
    var i = start;
    while (i < pat.len) : (i += 1) {
        if (pat[i] == '\\') {
            i += 1;
            continue;
        }
        if (pat[i] == '/') return i;
    }
    return pat.len;
}

/// Match a full relative path against a pattern; `**` spans path separators.
fn pathMatchFrom(pat: []const u8, pi: usize, path: []const u8) bool {
    if (pi >= pat.len) return path.len == 0;
    const pend = segmentEnd(pat, pi);
    const next = if (pend < pat.len) pend + 1 else pat.len;
    if (std.mem.eql(u8, pat[pi..pend], "**")) {
        if (next >= pat.len) return path.len > 0;
        if (pathMatchFrom(pat, next, path)) return true;
        var rest = path;
        while (rest.len > 0) {
            const s = std.mem.indexOfScalar(u8, rest, '/');
            rest = if (s) |i| rest[i + 1 ..] else "";
            if (pathMatchFrom(pat, next, rest)) return true;
        }
        return false;
    }
    const s = std.mem.indexOfScalar(u8, path, '/');
    const seg = if (s) |i| path[0..i] else path;
    if (!segmentMatch(pat[pi..pend], seg)) return false;
    return pathMatchFrom(pat, next, if (s) |i| path[i + 1 ..] else "");
}

fn patternMatches(pat: Pattern, rel: []const u8, is_dir: bool) bool {
    if (pat.dir_only and !is_dir) return false;
    if (pat.anchored) return pathMatchFrom(pat.text, 0, rel);
    return segmentMatch(pat.text, std.fs.path.basename(rel));
}

/// Strip an ancestor `base` prefix from `rel`; null when not under `base`.
fn stripBase(rel: []const u8, base: []const u8) ?[]const u8 {
    if (base.len == 0) return rel;
    if (rel.len > base.len and rel[base.len] == '/' and std.mem.startsWith(u8, rel, base))
        return rel[base.len + 1 ..];
    return null;
}

/// Ordered set of gitignore rules, shallow sources first.
pub const Matcher = struct {
    a: std.mem.Allocator,
    sources: std.ArrayList(Source) = .empty,

    pub fn init(a: std.mem.Allocator) Matcher {
        return .{ .a = a };
    }

    pub fn deinit(self: *Matcher) void {
        self.sources.deinit(self.a);
    }

    fn appendSource(self: *Matcher, base: []const u8, pats: []const Pattern) !void {
        if (pats.len == 0) return;
        try self.sources.append(self.a, .{ .base = base, .patterns = pats });
    }

    /// Add the rules from one `.gitignore` file located in `base`.
    pub fn pushFile(self: *Matcher, base: []const u8, content: []const u8) !void {
        var pats: std.ArrayList(Pattern) = .empty;
        var it = std.mem.tokenizeScalar(u8, content, '\n');
        while (it.next()) |line| {
            if (compilePattern(self.a, line)) |p| try pats.append(self.a, p);
        }
        try self.appendSource(base, try pats.toOwnedSlice(self.a));
    }

    /// Add caller-supplied patterns (e.g. config dirs) as a source at `base`.
    pub fn pushPatterns(self: *Matcher, base: []const u8, lines: []const []const u8) !void {
        var pats: std.ArrayList(Pattern) = .empty;
        for (lines) |line| {
            if (compilePattern(self.a, line)) |p| try pats.append(self.a, p);
        }
        try self.appendSource(base, try pats.toOwnedSlice(self.a));
    }

    /// Decide whether `rel` (relative to the search root) is ignored.
    /// null means no rule matched.
    pub fn check(self: *const Matcher, rel: []const u8, is_dir: bool) ?bool {
        var decision: ?bool = null;
        for (self.sources.items) |src| {
            const sub = stripBase(rel, src.base) orelse continue;
            if (sub.len == 0) continue;
            for (src.patterns) |p| {
                if (patternMatches(p, sub, is_dir)) decision = !p.negated;
            }
        }
        return decision;
    }
};
