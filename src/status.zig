const std = @import("std");
const platform = @import("platform.zig");

/// OSC 7501, the Program Status Protocol. The program reports what it is doing
/// so any consumer of the pty can react; well-behaved terminals ignore the
/// unknown sequence. See https://mitchellh.com/writing/program-status-osc7501
const app = "mini-coding-agent";
const max_msg = 256;

pub fn report(state: []const u8, kind: ?[]const u8, msg: ?[]const u8) void {
    var buf: [1024]u8 = undefined;
    const head = "\x1b]7501;";
    @memcpy(buf[0..head.len], head);
    var len: usize = head.len;

    len += (std.fmt.bufPrint(buf[len..], "state={s}:app={s}", .{ state, app }) catch return).len;
    if (kind) |k| len += (std.fmt.bufPrint(buf[len..], ":kind={s}", .{k}) catch return).len;
    if (msg) |m| {
        const clipped = m[0..@min(m.len, max_msg)];
        var encoded: [std.base64.standard.Encoder.calcSize(max_msg)]u8 = undefined;
        const b64 = std.base64.standard.Encoder.encode(&encoded, clipped);
        len += (std.fmt.bufPrint(buf[len..], ":msg={s}", .{b64}) catch return).len;
    }
    buf[len] = 0x1b;
    buf[len + 1] = '\\';
    len += 2;

    platform.writeOut(buf[0..len]);
}
