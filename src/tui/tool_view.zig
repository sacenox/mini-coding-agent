const std = @import("std");
const styles = @import("styles.zig");
const highlight = @import("highlight.zig");
const render = @import("render.zig");
const diff_view = @import("diff_view.zig");

const BodyLine = render.BodyLine;

pub const PendingCall = struct { name: []const u8, summary: []const u8 };

fn callHead(a: std.mem.Allocator, name: []const u8) []const u8 {
    return styles.teal(a, std.fmt.allocPrint(a, "-> {s}", .{name}) catch "->");
}

pub fn diffHead(a: std.mem.Allocator, name: []const u8, path: []const u8) []const u8 {
    const head = callHead(a, std.fmt.allocPrint(a, "{s} diff", .{name}) catch name);
    return std.fmt.allocPrint(a, "{s}  {s}", .{ head, path }) catch path;
}

pub fn relativize(cwd: []const u8, path: []const u8) []const u8 {
    if (!std.fs.path.isAbsolute(path) or cwd.len == 0) return path;
    if (!std.mem.startsWith(u8, path, cwd)) return path;
    const rest = path[cwd.len..];
    if (rest.len == 0) return ".";
    if (rest[0] != '/') return path;
    return rest[1..];
}

pub fn callSummary(a: std.mem.Allocator, name: []const u8, args_json: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, args_json, .{}) catch return args_json;
    if (parsed == .object) {
        if (std.mem.eql(u8, name, "bash")) {
            if (parsed.object.get("command")) |c| if (c == .string) return c.string;
        }
        if (std.mem.eql(u8, name, "edit") or std.mem.eql(u8, name, "read")) {
            if (parsed.object.get("path")) |p| if (p == .string) return p.string;
        }
    }
    return args_json;
}

pub fn callBody(a: std.mem.Allocator, name: []const u8, summary: []const u8, meta: ?[]const u8) []const BodyLine {
    const head = callHead(a, name);
    const body = if (std.mem.eql(u8, name, "bash"))
        highlight.highlightOn(a, "bash", summary, .{})
    else
        summary;
    var out: std.ArrayList(BodyLine) = .empty;
    var it = std.mem.splitScalar(u8, body, '\n');
    var i: usize = 0;
    while (it.next()) |line| : (i += 1) {
        const text = if (i == 0)
            std.fmt.allocPrint(a, "{s}  {s}{s}", .{
                head,
                line,
                if (meta) |m| styles.dim(a, std.fmt.allocPrint(a, " [{s}]", .{m}) catch "") else "",
            }) catch line
        else
            line;
        out.append(a, .{ .text = text }) catch {};
    }
    return out.items;
}

pub fn resultLines(a: std.mem.Allocator, name: []const u8, text: []const u8) []const BodyLine {
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
            const path = lines.items[0][verb.len..];
            _ = lines.orderedRemove(0);
            return diff_view.diffLines(a, path, lines.items);
        }
    }
    var out: std.ArrayList(BodyLine) = .empty;
    for (lines.items) |l| out.append(a, .{ .text = l }) catch {};
    return out.items;
}

pub fn exitLine(a: std.mem.Allocator, text: []const u8, is_error: bool) ?[]const u8 {
    const trimmed = std.mem.trimEnd(u8, text, " \t\r\n");
    const last = if (std.mem.lastIndexOfScalar(u8, trimmed, '\n')) |i| trimmed[i + 1 ..] else trimmed;
    if (!std.mem.startsWith(u8, last, "exit code: ")) return null;
    const label = std.fmt.allocPrint(a, " └ exit {s}", .{last["exit code: ".len..]}) catch return null;
    return if (is_error) styles.red(a, label) else styles.dim(a, label);
}
