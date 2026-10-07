const std = @import("std");
const platform = @import("../platform.zig");
const complete = @import("complete.zig");
const styles = @import("styles.zig");

pub const Command = enum {
    help,
    new,
    provider,
    model,
    thinking,

    pub fn wire(self: Command) []const u8 {
        return @tagName(self);
    }

    pub fn summary(self: Command) []const u8 {
        return switch (self) {
            .help => "list commands and keybindings",
            .new => "start a new session",
            .provider => "choose the provider and model",
            .model => "choose a model for the current provider",
            .thinking => "set the thinking level",
        };
    }

    pub const all = [_]Command{ .help, .new, .provider, .model, .thinking };
};

pub fn findCommand(text: []const u8) ?Command {
    if (text.len == 0 or text[0] != '/') return null;
    var i: usize = 1;
    while (i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\n') i += 1;
    return std.meta.stringToEnum(Command, text[1..i]);
}

pub fn completeCommand(draft: []const u8) ?[]const u8 {
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

pub fn helpRow(a: std.mem.Allocator, key: []const u8, description: []const u8, width: usize) []const u8 {
    var padded: std.ArrayList(u8) = .empty;
    padded.appendSlice(a, key) catch {};
    var i = key.len;
    while (i < width) : (i += 1) padded.append(a, ' ') catch {};
    return std.fmt.allocPrint(a, "  {s}  {s}", .{ styles.dim(a, padded.items), description }) catch key;
}
