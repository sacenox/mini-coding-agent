const std = @import("std");
const platform = @import("platform.zig");
const build_options = @import("build_options");

const user_agent = "mini-coding-agent/" ++ build_options.version;

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
    Aborted,
} || std.mem.Allocator.Error;

// Blocking socket reads cannot observe the cancel token, so a watcher thread
// shuts the connection down when a cancel is requested, unblocking the read.
const CancelWatch = struct {
    cancel: *const std.atomic.Value(bool),
    connection: *std.http.Client.Connection,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *CancelWatch) void {
        while (!self.done.load(.acquire)) {
            if (self.cancel.load(.acquire)) {
                self.connection.stream_reader.stream.shutdown(platform.io, .both) catch {};
                return;
            }
            std.Io.sleep(platform.io, .{ .nanoseconds = 25 * std.time.ns_per_ms }, .boot) catch {};
        }
    }
};

pub fn get(
    a: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    cancel: *const std.atomic.Value(bool),
) HttpError![]u8 {
    if (cancel.load(.acquire)) return error.Aborted;
    const uri = std.Uri.parse(url) catch return error.RequestFailed;
    var client: std.http.Client = .{ .allocator = a, .io = platform.io };
    defer client.deinit();

    var hdrs: std.ArrayList(std.http.Header) = .empty;
    defer hdrs.deinit(a);
    for (headers) |h| hdrs.append(a, .{ .name = h.name, .value = h.value }) catch return error.OutOfMemory;

    var req = client.request(.GET, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = hdrs.items,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch return error.RequestFailed;
    defer req.deinit();

    req.sendBodiless() catch return error.RequestFailed;
    var response = req.receiveHead(&.{}) catch return error.RequestFailed;
    const status = @intFromEnum(response.head.status);

    var transfer: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, &decompress_buf);

    if (status < 200 or status >= 300) return error.HttpStatus;
    return reader.allocRemaining(a, .limited(1 << 22)) catch return error.ReadFailed;
}

pub fn postSse(
    a: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    handler: SseHandler,
    cancel: *const std.atomic.Value(bool),
    err_body: *?[]const u8,
) HttpError!void {
    if (cancel.load(.acquire)) return error.Aborted;
    const uri = std.Uri.parse(url) catch return error.RequestFailed;
    var client: std.http.Client = .{ .allocator = a, .io = platform.io };
    defer client.deinit();

    var hdrs: std.ArrayList(std.http.Header) = .empty;
    defer hdrs.deinit(a);
    for (headers) |h| hdrs.append(a, .{ .name = h.name, .value = h.value }) catch return error.OutOfMemory;

    var req = client.request(.POST, uri, .{
        .redirect_behavior = .unhandled,
        .extra_headers = hdrs.items,
        .headers = .{ .user_agent = .{ .override = user_agent } },
    }) catch return error.RequestFailed;
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var bw = req.sendBodyUnflushed(&.{}) catch return error.RequestFailed;
    bw.writer.writeAll(body) catch return error.RequestFailed;
    bw.end() catch return error.RequestFailed;
    req.connection.?.flush() catch return error.RequestFailed;

    var watch = CancelWatch{ .cancel = cancel, .connection = req.connection.? };
    const watcher = std.Thread.spawn(.{}, CancelWatch.run, .{&watch}) catch null;
    defer {
        watch.done.store(true, .release);
        if (watcher) |t| t.join();
    }

    var response = req.receiveHead(&.{}) catch return error.RequestFailed;
    const status = @intFromEnum(response.head.status);

    var transfer: [16 * 1024]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer, &decompress, &decompress_buf);

    if (status < 200 or status >= 300) {
        err_body.* = reader.allocRemaining(a, .limited(1 << 20)) catch null;
        return error.HttpStatus;
    }

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(a);
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(a);
    var have_data = false;
    var buf: [4096]u8 = undefined;

    // Lines are assembled here instead of with `takeDelimiter`: some providers
    // stream whole documents in one event, and a line that does not fit the
    // reader's buffer sends the delimiter search down a failure path that
    // desynchronizes chunked transfer decoding.
    while (true) {
        if (cancel.load(.acquire)) return error.Aborted;
        const n = reader.readSliceShort(&buf) catch return error.ReadFailed;
        if (n == 0) break;
        var rest: []const u8 = buf[0..n];
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try line.appendSlice(a, rest[0..nl]);
            rest = rest[nl + 1 ..];
            if (try feedLine(a, line.items, &data, &have_data)) {
                handler.call(data.items);
                data.clearRetainingCapacity();
                have_data = false;
            }
            line.clearRetainingCapacity();
        }
        try line.appendSlice(a, rest);
    }
    if (line.items.len > 0 and try feedLine(a, line.items, &data, &have_data)) {
        handler.call(data.items);
        data.clearRetainingCapacity();
        have_data = false;
    }
    if (have_data) handler.call(data.items);
}

/// Applies one SSE line to the pending event payload, returning whether the
/// payload is complete and should be dispatched.
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
