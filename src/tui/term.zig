const std = @import("std");
const platform = @import("../platform.zig");

const EXIT_SEQUENCE = "\x1b[<u\x1b[?2004l";
const ENTER_SEQUENCE = "\x1b[?2004h\x1b[>1u\x1b[?u";

var saved: std.posix.termios = undefined;
var raw_mode = std.atomic.Value(bool).init(false);
var entered = std.atomic.Value(bool).init(false);

fn writeRaw(bytes: []const u8) void {
    _ = std.posix.system.write(std.posix.STDOUT_FILENO, bytes.ptr, bytes.len);
}

pub fn restore() void {
    if (raw_mode.swap(false, .seq_cst)) std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, saved) catch {};
    if (entered.swap(false, .seq_cst)) writeRaw(EXIT_SEQUENCE);
}

pub const Terminal = struct {
    started: bool = false,
    winsize: [2]usize = .{ 80, 24 },

    pub fn width(self: *Terminal) usize {
        return self.winsize[0];
    }

    pub fn height(self: *Terminal) usize {
        return self.winsize[1];
    }

    pub fn refreshSize(self: *Terminal) void {
        var wsz: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
        const r = platform.io.operate(.{ .device_io_control = .{
            .file = std.Io.File.stdout(),
            .code = std.posix.T.IOCGWINSZ,
            .arg = &wsz,
        } }) catch return;
        if (r.device_io_control >= 0) {
            if (wsz.col > 0) self.winsize[0] = wsz.col;
            if (wsz.row > 0) self.winsize[1] = wsz.row;
        }
    }

    pub fn start(self: *Terminal) void {
        if (self.started) return;
        self.started = true;
        self.refreshSize();
        if (std.Io.File.stdin().isTty(platform.io) catch false) {
            const original = std.posix.tcgetattr(std.posix.STDIN_FILENO) catch return;
            var raw = original;
            raw.lflag.ICANON = false;
            raw.lflag.ECHO = false;
            raw.lflag.ISIG = false;
            raw.lflag.IEXTEN = false;
            raw.iflag.ICRNL = false;
            raw.iflag.IXON = false;
            raw.oflag.OPOST = false;
            raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
            raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
            saved = original;
            raw_mode.store(true, .seq_cst);
            std.posix.tcsetattr(std.posix.STDIN_FILENO, .NOW, raw) catch {
                raw_mode.store(false, .seq_cst);
                return;
            };
        }
        entered.store(true, .seq_cst);
        platform.writeOut(ENTER_SEQUENCE);
    }

    pub fn stop(self: *Terminal) void {
        if (!self.started) return;
        self.started = false;
        restore();
    }

    pub fn write(self: *Terminal, text: []const u8) void {
        _ = self;
        platform.writeOut(text);
    }
};
