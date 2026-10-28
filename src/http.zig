const std = @import("std");
const platform = @import("platform.zig");
const time = @import("time.zig");
const build_options = @import("build_options");

const user_agent = "mini-coding-agent/" ++ build_options.version;

const openrouter_headers = [_]std.http.Header{
    .{ .name = "HTTP-Referer", .value = "https://xonecas.io/mini-coding-agent/" },
    .{ .name = "X-OpenRouter-Title", .value = "mini-coding-agent" },
};

fn isOpenRouter(uri: std.Uri) bool {
    const host = switch (uri.host orelse return false) {
        inline else => |h| h,
    };
    return std.mem.eql(u8, host, "openrouter.ai") or std.mem.endsWith(u8, host, ".openrouter.ai");
}

pub const Header = struct { name: []const u8, value: []const u8 };

pub const SseHandler = struct {
    ctx: *anyopaque,
    onEvent: *const fn (ctx: *anyopaque, data: []const u8) void,

    fn call(self: SseHandler, data: []const u8) void {
        self.onEvent(self.ctx, data);
    }
};

const HttpError = error{
    RequestFailed,
    HttpStatus,
    ReadFailed,
    IdleTimeout,
    Aborted,
} || std.mem.Allocator.Error;

pub const Retry = struct {
    attempts: usize = 3,
    base_ms: u64 = 1000,
    idle_ms: u64 = 120_000,
};

const max_backoff_ms: u64 = 30_000;

pub const RetryNotice = struct {
    ctx: *anyopaque,
    on_retry: *const fn (ctx: *anyopaque, attempt: usize, total: usize, delay_ms: u64, reason: []const u8) void,

    fn call(self: RetryNotice, attempt: usize, total: usize, delay_ms: u64, reason: []const u8) void {
        self.on_retry(self.ctx, attempt, total, delay_ms, reason);
    }
};

const Watch = struct {
    cancel: *const std.atomic.Value(bool),
    connection: *std.http.Client.Connection,
    idle_ms: u64,
    last: std.atomic.Value(i64),
    idle: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *Watch) void {
        while (!self.done.load(.acquire)) {
            if (self.cancel.load(.acquire)) {
                self.hangUp();
                return;
            }
            if (self.idle_ms > 0 and time.nowMs() - self.last.load(.acquire) >= self.idle_ms) {
                self.idle.store(true, .release);
                self.hangUp();
                return;
            }
            std.Io.sleep(platform.io, .{ .nanoseconds = 25 * std.time.ns_per_ms }, .boot) catch {};
        }
    }

    fn hangUp(self: *Watch) void {
        self.connection.stream_reader.stream.shutdown(platform.io, .both) catch {};
    }
};

const Exchange = struct {
    a: std.mem.Allocator,
    client: std.http.Client,
    hdrs: std.ArrayList(std.http.Header) = .empty,
    req: std.http.Client.Request,
    response: std.http.Client.Response,
    status: u16 = 0,
    transfer: [16 * 1024]u8 = undefined,
    decompress: std.http.Decompress = undefined,
    decompress_buf: [std.compress.flate.max_window_len]u8 = undefined,
    reader: *std.Io.Reader = undefined,

    fn open(self: *Exchange, a: std.mem.Allocator, method: std.http.Method, url: []const u8, headers: []const Header, body: ?[]const u8) HttpError!void {
        self.a = a;
        self.hdrs = .empty;
        const uri = std.Uri.parse(url) catch return error.RequestFailed;
        self.client = .{ .allocator = a, .io = platform.io };
        errdefer self.client.deinit();
        for (headers) |h| self.hdrs.append(a, .{ .name = h.name, .value = h.value }) catch return error.OutOfMemory;
        if (isOpenRouter(uri)) {
            for (openrouter_headers) |h| self.hdrs.append(a, h) catch return error.OutOfMemory;
        }
        errdefer self.hdrs.deinit(a);
        self.req = self.client.request(method, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = self.hdrs.items,
            .headers = .{ .user_agent = .{ .override = user_agent } },
        }) catch return error.RequestFailed;
        errdefer self.req.deinit();
        if (body) |b| {
            self.req.transfer_encoding = .{ .content_length = b.len };
            var bw = self.req.sendBodyUnflushed(&.{}) catch return error.RequestFailed;
            bw.writer.writeAll(b) catch return error.RequestFailed;
            bw.end() catch return error.RequestFailed;
            self.req.connection.?.flush() catch return error.RequestFailed;
        } else {
            self.req.sendBodiless() catch return error.RequestFailed;
        }
    }

    fn receive(self: *Exchange) HttpError!void {
        self.response = self.req.receiveHead(&.{}) catch return error.RequestFailed;
        self.status = @backingInt(self.response.head.status);
        self.reader = self.response.readerDecompressing(&self.transfer, &self.decompress, &self.decompress_buf);
    }

    fn ok(self: *Exchange) bool {
        return self.status >= 200 and self.status < 300;
    }

    fn close(self: *Exchange) void {
        self.req.deinit();
        self.hdrs.deinit(self.a);
        self.client.deinit();
    }
};

const Attempt = struct {
    status: u16 = 0,
    sent: bool = false,
    err: ?HttpError = null,
};

pub fn get(
    a: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    cancel: *const std.atomic.Value(bool),
    retry: Retry,
) HttpError![]u8 {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        var out = Attempt{};
        if (getOnce(a, url, headers, cancel, &out)) |body| {
            return body;
        } else |e| {
            if (attempt >= retry.attempts or !retryable(e, out.status)) return e;
        }
        try pause(cancel, backoff(retry.base_ms, attempt));
    }
}

fn getOnce(
    a: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    cancel: *const std.atomic.Value(bool),
    out: *Attempt,
) HttpError![]u8 {
    if (cancel.load(.acquire)) return error.Aborted;
    var ex: Exchange = undefined;
    try ex.open(a, .GET, url, headers, null);
    defer ex.close();
    try ex.receive();
    out.status = ex.status;
    if (!ex.ok()) return error.HttpStatus;
    return ex.reader.allocRemaining(a, .limited(1 << 22)) catch return error.ReadFailed;
}

pub fn postSse(
    a: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    handler: SseHandler,
    cancel: *const std.atomic.Value(bool),
    err_body: *?[]const u8,
    retry: Retry,
    notice: ?RetryNotice,
) HttpError!void {
    var attempt: usize = 0;
    while (true) : (attempt += 1) {
        err_body.* = null;
        const out = postOnce(a, url, headers, body, handler, cancel, err_body, retry.idle_ms);
        const e = out.err orelse return;
        if (out.sent or attempt >= retry.attempts or !retryable(e, out.status)) return e;
        const delay_ms = backoff(retry.base_ms, attempt);
        if (notice) |n| {
            var buf: [16]u8 = undefined;
            n.call(attempt + 2, retry.attempts + 1, delay_ms, describe(e, out.status, &buf));
        }
        try pause(cancel, delay_ms);
    }
}

fn postOnce(
    a: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    handler: SseHandler,
    cancel: *const std.atomic.Value(bool),
    err_body: *?[]const u8,
    idle_ms: u64,
) Attempt {
    var out = Attempt{};
    if (cancel.load(.acquire)) {
        out.err = error.Aborted;
        return out;
    }
    var ex: Exchange = undefined;
    ex.open(a, .POST, url, headers, body) catch |e| {
        out.err = e;
        return out;
    };
    defer ex.close();

    var watch = Watch{ .cancel = cancel, .connection = ex.req.connection.?, .idle_ms = idle_ms, .last = std.atomic.Value(i64).init(time.nowMs()) };
    const watcher = std.Thread.spawn(.{}, Watch.run, .{&watch}) catch null;
    defer {
        watch.done.store(true, .release);
        if (watcher) |t| t.join();
    }

    ex.receive() catch {
        out.err = if (watch.idle.load(.acquire)) error.IdleTimeout else error.RequestFailed;
        return out;
    };
    out.status = ex.status;
    if (!ex.ok()) {
        err_body.* = ex.reader.allocRemaining(a, .limited(1 << 20)) catch null;
        out.err = error.HttpStatus;
        return out;
    }

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    var have_data = false;
    var buf: [4096]u8 = undefined;

    while (true) {
        if (cancel.load(.acquire)) {
            out.err = error.Aborted;
            return out;
        }
        const n = ex.reader.readSliceShort(&buf) catch {
            out.err = if (watch.idle.load(.acquire)) error.IdleTimeout else error.ReadFailed;
            return out;
        };
        if (n == 0) break;
        watch.last.store(time.nowMs(), .release);
        var rest: []const u8 = buf[0..n];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            line.appendSlice(a, rest[0..nl]) catch {
                out.err = error.OutOfMemory;
                return out;
            };
            rest = rest[nl + 1 ..];
            const complete = feedLine(a, line.items, &data, &have_data) catch {
                out.err = error.OutOfMemory;
                return out;
            };
            if (complete) {
                out.sent = true;
                handler.call(data.items);
                data.clearRetainingCapacity();
                have_data = false;
            }
            line.clearRetainingCapacity();
        }
        line.appendSlice(a, rest) catch {
            out.err = error.OutOfMemory;
            return out;
        };
    }
    if (watch.idle.load(.acquire)) {
        out.err = error.IdleTimeout;
        return out;
    }
    if (line.items.len > 0) {
        const complete = feedLine(a, line.items, &data, &have_data) catch {
            out.err = error.OutOfMemory;
            return out;
        };
        if (complete) {
            out.sent = true;
            handler.call(data.items);
            data.clearRetainingCapacity();
            have_data = false;
        }
    }
    if (have_data) {
        out.sent = true;
        handler.call(data.items);
    }
    return out;
}

fn retryable(e: HttpError, status: u16) bool {
    return switch (e) {
        error.RequestFailed, error.ReadFailed, error.IdleTimeout => true,
        error.HttpStatus => status == 429 or status >= 500,
        error.Aborted, error.OutOfMemory => false,
    };
}

fn backoff(base_ms: u64, attempt: usize) u64 {
    const shift: u6 = @intCast(@min(attempt, 6));
    return @min(base_ms << shift, max_backoff_ms);
}

fn describe(e: HttpError, status: u16, buf: []u8) []const u8 {
    return switch (e) {
        error.HttpStatus => std.fmt.bufPrint(buf, "http {d}", .{status}) catch "http error",
        error.IdleTimeout => "idle timeout",
        error.ReadFailed => "stream interrupted",
        else => "connection failed",
    };
}

fn pause(cancel: *const std.atomic.Value(bool), delay_ms: u64) HttpError!void {
    var left = delay_ms;
    while (left > 0) {
        if (cancel.load(.acquire)) return error.Aborted;
        const step: u64 = @min(left, 25);
        std.Io.sleep(platform.io, .{ .nanoseconds = step * std.time.ns_per_ms }, .boot) catch {};
        left -= step;
    }
    if (cancel.load(.acquire)) return error.Aborted;
}

fn feedLine(
    a: std.mem.Allocator,
    raw: []const u8,
    data: *std.ArrayList(u8),
    have_data: *bool,
) std.mem.Allocator.Error!bool {
    var line = raw;
    if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

    if (line.len == 0) return have_data.*;
    if (line[0] == ':') return false;
    if (std.mem.startsWith(u8, line, "data:")) {
        var value = line[5..];
        if (value.len > 0 and value[0] == ' ') value = value[1..];
        if (have_data.*) try data.append(a, '\n');
        try data.appendSlice(a, value);
        have_data.* = true;
    }
    return false;
}
