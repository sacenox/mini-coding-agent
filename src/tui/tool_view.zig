const std = @import("std");
const styles = @import("styles.zig");
const highlight = @import("highlight.zig");
const render = @import("render.zig");
const diff_view = @import("diff_view.zig");

const BodyLine = render.BodyLine;

pub const PendingCall = struct { name: []const u8, summary: []const u8 };

const state_width = "running".len;
const state_pad = std.fmt.comptimePrint("{{s: <{d}}}", .{state_width});

fn callHead(a: std.mem.Allocator, name: []const u8) []const u8 {
    return styles.teal(a, std.fmt.allocPrint(a, "-> {s}", .{name}) catch "->");
}

pub fn callRows(a: std.mem.Allocator, call: PendingCall, running: bool) []const []const u8 {
    const padded = std.fmt.allocPrint(a, state_pad, .{if (running) "running" else "queued"}) catch "";
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

pub fn callSummary(a: std.mem.Allocator, name: []const u8, args_json: []const u8) []const u8 {
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

pub fn callBody(a: std.mem.Allocator, name: []const u8, summary: []const u8) BodyLine {
    const body = if (std.mem.eql(u8, name, "bash"))
        highlight.highlightOn(a, "bash", summary, .{})
    else
        summary;
    return .{ .text = std.fmt.allocPrint(a, "{s}  {s}", .{ callHead(a, name), body }) catch summary };
}

pub fn resultLines(a: std.mem.Allocator, name: []const u8, text: []const u8, is_error: bool) []const BodyLine {
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
            return diff_view.diffLines(a, path, lines.items);
        }
    }
    var out: std.ArrayList(BodyLine) = .empty;
    for (lines.items) |l| out.append(a, .{ .text = l }) catch {};
    return out.items;
}
