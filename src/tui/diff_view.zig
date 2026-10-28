const std = @import("std");
const styles = @import("styles.zig");
const tools = @import("../tools.zig");
const highlight = @import("highlight.zig");
const render = @import("render.zig");

const BodyLine = render.BodyLine;

pub const Rendered = struct {
    lines: []const BodyLine = &.{},
    added: usize = 0,
    removed: usize = 0,
};

fn diffHunk() styles.Style {
    return styles.roles.prompt;
}

fn diffNote() styles.Style {
    return styles.roles.comment;
}

pub fn diffLines(a: std.mem.Allocator, lines: []const []const u8, max_diff_lines: usize) Rendered {
    if (lines.len > max_diff_lines) {
        var warn: std.ArrayList(BodyLine) = .empty;
        warn.append(a, .{
            .text = "Diff too large to render efficiently. Full contents in session.jsonl",
            .style = diffNote(),
        }) catch {};
        return .{ .lines = warn.items };
    }
    var out: std.ArrayList(BodyLine) = .empty;
    var added: usize = 0;
    var removed: usize = 0;
    var in_hunk = false;
    for (lines) |line| {
        if (std.mem.startsWith(u8, line, "diff ")) in_hunk = false;
        const kind = highlight.diffKind(line, in_hunk);
        if (kind == .hunk) in_hunk = true;
        const text = render.stripAnsi(a, line);
        switch (kind) {
            .hunk => out.append(a, .{ .text = text, .style = diffHunk() }) catch {},
            .note => out.append(a, .{ .text = text, .style = diffNote() }) catch {},
            .ctx => out.append(a, .{ .text = text, .style = diffNote() }) catch {},
            .add, .del => {
                const is_add = kind == .add;
                if (is_add) added += 1 else removed += 1;
                const style = if (is_add) styles.roles.diff_add else styles.roles.diff_delete;
                out.append(a, .{ .text = text, .style = style }) catch {};
            },
        }
    }
    return .{ .lines = out.items, .added = added, .removed = removed };
}

pub fn diffBody(a: std.mem.Allocator, d: tools.FileDiff, max_diff_lines: usize) Rendered {
    if (d.patch) |patch| {
        const trimmed = std.mem.trimEnd(u8, patch, " \t\r\n");
        var it = std.mem.splitScalar(u8, trimmed, '\n');
        var body: std.ArrayList([]const u8) = .empty;
        while (it.next()) |l| body.append(a, l) catch {};
        return diffLines(a, body.items, max_diff_lines);
    }
    var out: std.ArrayList(BodyLine) = .empty;
    if (d.note) |note| out.append(a, .{ .text = note, .style = styles.roles.comment }) catch {};
    return .{ .lines = out.items };
}
