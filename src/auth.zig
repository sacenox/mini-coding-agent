const std = @import("std");
const platform = @import("platform.zig");
const config = @import("config.zig");
const filesystem = @import("filesystem.zig");
const http = @import("http.zig");
const time = @import("time.zig");

pub const token_url = "https://auth.openai.com/api/accounts/oauth/token";
pub const scope_url = "https://auth.openai.com/api/accounts/authorize";
pub const resource = "https://api.openai.com/v1";
pub const plan_scope = "chatgpt.tokens.use.direct";

/// The credential `mini login` writes. Keys are camelCase to match the other
/// files in the config directory.
pub const Record = struct {
    email: ?[]const u8 = null,
    clientId: []const u8,
    accessToken: []const u8,
    refreshToken: ?[]const u8 = null,
    idToken: ?[]const u8 = null,
    expiresAt: i64 = 0,
    scope: []const u8 = "",
};

pub fn path(a: std.mem.Allocator) []const u8 {
    return filesystem.join(a, &.{ config.configDir(a), "auth.json" }) catch "auth.json";
}

pub fn load(a: std.mem.Allocator) ?Record {
    const text = filesystem.readFileAlloc(a, path(a), 1 << 20) catch return null;
    return std.json.parseFromSliceLeaky(Record, a, text, .{ .ignore_unknown_fields = true }) catch null;
}

/// Written to a temporary file and renamed, so a crash mid-write cannot leave a
/// truncated credential with the refresh token already rotated.
pub fn save(a: std.mem.Allocator, record: Record) !void {
    const json = try std.json.Stringify.valueAlloc(a, record, .{ .whitespace = .indent_2 });
    const out = try std.fmt.allocPrint(a, "{s}\n", .{json});
    const target = path(a);
    const temp = try std.fmt.allocPrint(a, "{s}.tmp", .{target});
    try filesystem.writeFile(temp, out);
    try std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), target, platform.io);
}

pub fn available(a: std.mem.Allocator) bool {
    return filesystem.fileExists(path(a));
}

/// True when the granted `scope` string contains `name`.
pub fn granted(scope: []const u8, name: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, scope, " +");
    while (it.next()) |s| {
        if (std.mem.eql(u8, s, name)) return true;
    }
    return false;
}

pub const TokenResponse = struct {
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
    expires_in: ?u64 = null,
    scope: ?[]const u8 = null,
};

var no_cancel = std.atomic.Value(bool).init(false);

/// POSTs an already encoded grant to the token endpoint. Null on any failure;
/// the reason is printed once and never retried.
pub fn tokenRequest(a: std.mem.Allocator, body: []const u8, cancel: ?*const std.atomic.Value(bool)) ?TokenResponse {
    const response = http.post(a, token_url, &.{
        .{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "Accept", .value = "application/json" },
    }, body, cancel orelse &no_cancel) catch {
        platform.printErr("sign-in: token request failed\n", .{});
        return null;
    };
    if (response.status != 200) {
        platform.printErr("sign-in: token endpoint returned {d} {s}\n", .{ response.status, response.body });
        return null;
    }
    return std.json.parseFromSliceLeaky(TokenResponse, a, response.body, .{ .ignore_unknown_fields = true }) catch null;
}

/// RFC 3986 percent encoding. A space becomes `%20`, which is also valid in an
/// `application/x-www-form-urlencoded` body, so one encoder serves both.
pub fn appendEncoded(a: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => try out.append(a, c),
            else => {
                try out.append(a, '%');
                try out.append(a, hex[c >> 4]);
                try out.append(a, hex[c & 0xf]);
            },
        }
    }
}

pub fn form(a: std.mem.Allocator, pairs: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |pair, i| {
        if (i > 0) try out.append(a, '&');
        try appendEncoded(a, &out, pair[0]);
        try out.append(a, '=');
        try appendEncoded(a, &out, pair[1]);
    }
    return out.toOwnedSlice(a);
}

/// One credential, one lock. Refreshes are serialized so two turns cannot race
/// the rotating refresh token.
pub const Session = struct {
    mutex: std.Io.Mutex = .init,
    record: Record,

    /// The record owns its strings for the life of the process, so a caller's
    /// scratch allocator can be reset between requests without dangling it.
    pub fn access(self: *Session, cancel: *const std.atomic.Value(bool)) ?[]const u8 {
        const a = platform.gpa;
        self.mutex.lockUncancelable(platform.io);
        defer self.mutex.unlock(platform.io);
        if (self.record.expiresAt - time.nowMs() > 60_000) return self.record.accessToken;
        const next = self.renew(a, cancel) orelse return null;
        save(a, next) catch platform.printErr("sign-in: could not persist the refreshed credential\n", .{});
        self.record = next;
        return self.record.accessToken;
    }

    fn renew(self: *Session, a: std.mem.Allocator, cancel: *const std.atomic.Value(bool)) ?Record {
        const refresh = self.record.refreshToken orelse return null;
        const body = form(a, &.{
            .{ "grant_type", "refresh_token" },
            .{ "client_id", self.record.clientId },
            .{ "refresh_token", refresh },
            .{ "resource", resource },
        }) catch return null;
        const response = tokenRequest(a, body, cancel) orelse return null;
        const bearer = response.access_token orelse return null;
        return .{
            .email = self.record.email,
            .clientId = self.record.clientId,
            .accessToken = bearer,
            .refreshToken = response.refresh_token orelse self.record.refreshToken,
            .idToken = response.id_token orelse self.record.idToken,
            .expiresAt = time.nowMs() + @as(i64, @intCast(response.expires_in orelse 3600)) * 1000,
            .scope = response.scope orelse self.record.scope,
        };
    }
};

var session: ?Session = null;
var init_mutex: std.Io.Mutex = .init;

/// The process-wide credential, loaded on first use and then kept in memory for
/// the life of the process. A `mini login` in another process is only visible to
/// a new one.
pub fn token(cancel: *const std.atomic.Value(bool)) ?[]const u8 {
    init_mutex.lockUncancelable(platform.io);
    if (session == null) {
        const record = load(platform.gpa) orelse {
            init_mutex.unlock(platform.io);
            return null;
        };
        session = .{ .record = record };
    }
    init_mutex.unlock(platform.io);
    return session.?.access(cancel);
}
