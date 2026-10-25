const std = @import("std");
const platform = @import("../platform.zig");

const EXIT_SEQUENCE = "\x1b[<u\x1b[?2004l";
const ENTER_SEQUENCE = "\x1b[?2004h\x1b[>1u\x1b[?u";

/// Cell size in pixels assumed when the terminal does not report window pixels.
const fallback_cell = [2]usize{ 10, 20 };

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
    pixels: [2]usize = .{ 0, 0 },

    pub fn width(self: *Terminal) usize {
        return self.winsize[0];
    }

    pub fn height(self: *Terminal) usize {
        return self.winsize[1];
    }

    /// Cell size in pixels, with a typical fallback for terminals that do not
    /// report the pixel dimensions of the window.
    pub fn cell(self: *Terminal) [2]usize {
        const w = if (self.winsize[0] > 0 and self.pixels[0] > 0) self.pixels[0] / self.winsize[0] else fallback_cell[0];
        const h = if (self.winsize[1] > 0 and self.pixels[1] > 0) self.pixels[1] / self.winsize[1] else fallback_cell[1];
        return .{ @max(w, 1), @max(h, 1) };
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
            if (wsz.xpixel > 0) self.pixels[0] = wsz.xpixel;
            if (wsz.ypixel > 0) self.pixels[1] = wsz.ypixel;
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
            raw.cc[@backingInt(std.posix.V.MIN)] = 1;
            raw.cc[@backingInt(std.posix.V.TIME)] = 0;
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
