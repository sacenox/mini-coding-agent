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

pub fn postSse(
    a: std.mem.Allocator,
    url: []const u8,
    headers: []const Header,
    body: []const u8,
    handler: SseHandler,
    cancel: *const std.atomic.Value(bool),
    err_body: *?[]const u8,
) HttpError!void {
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
    var have_data = false;

    while (true) {
        if (cancel.load(.acquire)) return error.Aborted;
        const maybe_line = reader.takeDelimiter('\n') catch return error.ReadFailed;
        const raw = maybe_line orelse break;
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (line.len == 0) {
            if (have_data) {
                handler.call(data.items);
                data.clearRetainingCapacity();
                have_data = false;
            }
            continue;
        }
        if (line[0] == ':') continue;
        if (std.mem.startsWith(u8, line, "data:")) {
            var value = line[5..];
            if (value.len > 0 and value[0] == ' ') value = value[1..];
            if (have_data) data.append(a, '\n') catch return error.OutOfMemory;
            data.appendSlice(a, value) catch return error.OutOfMemory;
            have_data = true;
        }
    }
    if (have_data) handler.call(data.items);
}
