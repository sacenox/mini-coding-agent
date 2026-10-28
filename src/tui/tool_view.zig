const std = @import("std");
const styles = @import("styles.zig");
const render = @import("render.zig");
const diff_view = @import("diff_view.zig");

const BodyLine = render.BodyLine;

pub const PendingCall = struct { name: []const u8, summary: []const u8, rendered: bool = false };

fn callHead(a: std.mem.Allocator, name: []const u8) []const u8 {
    return styles.accent(a, std.fmt.allocPrint(a, "{s}", .{name}) catch "tool");
}

pub fn diffHead(a: std.mem.Allocator, path: []const u8) []const u8 {
    return std.fmt.allocPrint(a, "{s}  {s}", .{ callHead(a, "diff"), path }) catch path;
}

pub fn relativize(cwd: []const u8, path: []const u8) []const u8 {
    if (!std.fs.path.isAbsolute(path) or cwd.len == 0) return path;
    if (!std.mem.startsWith(u8, path, cwd)) return path;
    const rest = path[cwd.len..];
    if (rest.len == 0) return ".";
    if (rest[0] != '/') return path;
    return rest[1..];
}

fn preview(a: std.mem.Allocator, command: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, command, '\n') orelse return command;
    if (std.mem.indexOfNone(u8, command[end..], " \t\r\n") == null) return command[0..end];
    const first = std.mem.trimEnd(u8, command[0..end], " \t\r");
    return std.fmt.allocPrint(a, "{s} …", .{first}) catch first;
}

pub fn callSummary(a: std.mem.Allocator, name: []const u8, args_json: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, args_json, .{}) catch return args_json;
    if (parsed == .object) {
        if (std.mem.eql(u8, name, "bash")) {
            if (parsed.object.get("command")) |c| if (c == .string) return preview(a, c.string);
        }
        if (std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "read")) {
            if (parsed.object.get("path")) |p| if (p == .string) return p.string;
        }
    }
    return args_json;
}

pub fn callLine(a: std.mem.Allocator, name: []const u8, summary: []const u8, width: usize) []const u8 {
    const head = std.fmt.allocPrint(a, "{s}  ", .{callHead(a, name)}) catch return summary;
    const room = width -| render.displayWidth(head);
    const args = styles.styledWith(a, .{ .bold = true }, render.clip(a, render.expandTabs(a, summary, 4), room));
    return std.fmt.allocPrint(a, "{s}{s}", .{ head, args }) catch summary;
}

pub const Result = struct {
    lines: []const BodyLine,
    footer: ?[]const u8 = null,
};

pub fn diffFooter(a: std.mem.Allocator, r: diff_view.Rendered) ?[]const u8 {
    if (r.added == 0 and r.removed == 0) return null;
    const add = std.fmt.allocPrint(a, "+{d}", .{r.added}) catch return null;
    const del = std.fmt.allocPrint(a, "-{d}", .{r.removed}) catch return null;
    return std.fmt.allocPrint(a, "{s}{s} {s}", .{
        styles.comment(a, " └ "),
        styles.styledWith(a, styles.roles.diff_add, add),
        styles.styledWith(a, styles.roles.diff_delete, del),
    }) catch null;
}

pub fn resultLines(a: std.mem.Allocator, name: []const u8, text: []const u8, max_diff_lines: usize) Result {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, trimmed, '\n');
    while (it.next()) |l| lines.append(a, l) catch {};
    if (std.mem.eql(u8, name, "bash")) {
        if (lines.items.len > 0 and std.mem.startsWith(u8, lines.items[lines.items.len - 1], "exit code: ")) {
            _ = lines.pop();
        }
    } else if (std.mem.eql(u8, name, "edit")) {
        const verb = if (std.mem.startsWith(u8, lines.items[0], "edited "))
            "edited "
        else if (std.mem.startsWith(u8, lines.items[0], "created "))
            "created "
        else
            "";
        if (verb.len > 0) {
            _ = lines.orderedRemove(0);
            const r = diff_view.diffLines(a, lines.items, max_diff_lines);
            return .{ .lines = r.lines, .footer = diffFooter(a, r) };
        }
    }
    var out: std.ArrayList(BodyLine) = .empty;
    for (lines.items) |l| out.append(a, .{ .text = l }) catch {};
    return .{ .lines = out.items };
}

pub fn metaLine(a: std.mem.Allocator, meta: []const u8) []const u8 {
    const label = std.fmt.allocPrint(a, " └ {s}", .{meta}) catch return "";
    return styles.comment(a, label);
}

pub fn exitLine(a: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| trimmed[i + 1 ..] else trimmed;
    if (!std.mem.startsWith(u8, last, "exit code: ")) return null;
    const label = std.fmt.allocPrint(a, " └ exit {s}", .{last["exit code: ".len..]}) catch return null;
    return styles.comment(a, label);
}
