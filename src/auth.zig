// Sign in with ChatGPT (ChatGPT plan usage) for subscription providers.
//
// The flow is the documented OSS one: a user-defined agent registers itself
// dynamically, the callback returns an issued client id that is stored and
// reused, and inference runs against the public Responses API.

const std = @import("std");
const platform = @import("platform.zig");
const filesystem = @import("filesystem.zig");
const http = @import("http.zig");
const config = @import("config.zig");
const providers = @import("providers.zig");

pub const OAuth = providers.OAuth;
pub const Error = error{ Cancelled, LoginFailed, MissingScope, OutOfMemory };

pub const Cancel = *const std.atomic.Value(bool);

// Refresh tokens rotate, so credential state is serialized.
var mutex: std.Io.Mutex = .init;

pub const Record = struct {
    email: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    ext_agent_host_id: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    expires_in: ?u64 = null,
    scopes: ?[]const []const u8 = null,
    saved_at: ?i64 = null,
};

pub fn load(a: std.mem.Allocator) ?Record {
    const text = filesystem.readFileAlloc(a, config.credentialPath(a), 1 << 20) catch return null;
    return std.json.parseFromSliceLeaky(Record, a, text, .{ .ignore_unknown_fields = true }) catch null;
}

fn write(a: std.mem.Allocator, record: Record) !void {
    var stored = record;
    stored.saved_at = std.Io.Timestamp.now(platform.io, .real).toSeconds();
    const text = try std.json.Stringify.valueAlloc(a, stored, .{});
    try filesystem.writePrivateFile(config.credentialPath(a), text);
}

fn save(a: std.mem.Allocator, record: Record) !void {
    mutex.lockUncancelable(platform.io);
    defer mutex.unlock(platform.io);
    try write(a, record);
}

pub fn available(a: std.mem.Allocator) bool {
    const record = load(a) orelse return false;
    const access = record.access_token orelse return false;
    return access.len > 0;
}

// The access token for requests, refreshed when it is near expiry. A refresh
// token the server has rejected is dropped so the user can sign in again.
pub fn accessToken(a: std.mem.Allocator, oauth: *const OAuth, cancel_token: ?Cancel) ?[]const u8 {
    mutex.lockUncancelable(platform.io);
    defer mutex.unlock(platform.io);
    const record = load(a) orelse return null;
    const access = record.access_token orelse return null;
    if (!expiring(record)) return access;
    const refresh_token = record.refresh_token orelse return access;
    const fresh = refresh(a, oauth, &record, refresh_token, cancel_token) catch |e| {
        if (e != error.InvalidGrant) return access;
        var cleared = record;
        cleared.access_token = null;
        cleared.refresh_token = null;
        cleared.id_token = null;
        cleared.expires_in = null;
        write(a, cleared) catch {};
        return null;
    };
    write(a, fresh) catch {};
    return fresh.access_token;
}

pub const Hooks = struct {
    ctx: *anyopaque,
    on_url: *const fn (ctx: *anyopaque, url: []const u8) void,
    cancel: Cancel,
};

pub fn login(a: std.mem.Allocator, oauth: *const OAuth, hooks: Hooks) !Record {
    var record = load(a) orelse Record{};
    const host_id = record.ext_agent_host_id orelse try generateHostId(a);
    record.ext_agent_host_id = host_id;
    if (record.access_token == null) save(a, record) catch {};

    const registering = record.client_id == null;
    const client_id = record.client_id orelse oauth.client_id;
    const codes = try pkce(a);
    const state = try randomToken(a, 16);
    const nonce = try randomToken(a, 16);

    hooks.on_url(hooks.ctx, try authorizeUrl(a, oauth, client_id, host_id, codes.challenge, state, nonce, registering, record.id_token));
    const result = try awaitCallback(a, oauth, state, hooks.cancel);

    const issued = result.client_id orelse client_id;
    if (registering and result.client_id == null) return error.LoginFailed;
    if (!registering and result.client_id != null and !std.mem.eql(u8, result.client_id.?, record.client_id.?)) return error.LoginFailed;

    const token = try exchange(a, oauth, issued, result.code, codes.verifier, hooks.cancel);
    const claims = idClaims(a, token.id_token) catch null;
    if (claims) |c| try validate(c, issued, nonce);
    const scopes = splitScopes(a, token.scope) orelse result.scope;
    const saved = Record{
        .email = if (claims) |c| c.email else null,
        .subject = if (claims) |c| c.sub else null,
        .client_id = issued,
        .ext_agent_host_id = host_id,
        .id_token = token.id_token,
        .access_token = token.access,
        .refresh_token = token.refresh,
        .expires_in = token.expires_in,
        .scopes = scopes,
    };
    try save(a, saved);
    if (oauth.required_scope) |required| {
        if (!granted(scopes, required)) return error.MissingScope;
    }
    return saved;
}

fn granted(scopes: ?[]const []const u8, name: []const u8) bool {
    for (scopes orelse &.{}) |scope| {
        if (std.mem.eql(u8, scope, name)) return true;
    }
    return false;
}

fn authorizeUrl(a: std.mem.Allocator, oauth: *const OAuth, client_id: []const u8, host_id: []const u8, challenge: []const u8, state: []const u8, nonce: []const u8, registering: bool, id_token: ?[]const u8) ![]const u8 {
    var params: std.ArrayList([2][]const u8) = .empty;
    try params.append(a, .{ "response_type", "code" });
    try params.append(a, .{ "client_id", client_id });
    try params.append(a, .{ "redirect_uri", oauth.redirect_uri });
    try params.append(a, .{ "scope", oauth.scope });
    try params.append(a, .{ "resource", oauth.resource });
    try params.append(a, .{ "state", state });
    try params.append(a, .{ "nonce", nonce });
    try params.append(a, .{ "code_challenge", challenge });
    try params.append(a, .{ "code_challenge_method", "S256" });
    try params.append(a, .{ "ext_agent_host_id", host_id });
    if (registering) try params.append(a, .{ "agent_name_hint", oauth.app_name });
    if (id_token) |token| try params.append(a, .{ "id_token_hint", token });

    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, oauth.authorize_url);
    for (params.items, 0..) |p, i| {
        try out.append(a, if (i == 0) '?' else '&');
        try encode(a, &out, p[0]);
        try out.append(a, '=');
        try encode(a, &out, p[1]);
    }
    return out.toOwnedSlice(a);
}

const Callback = struct {
    code: []const u8,
    client_id: ?[]const u8 = null,
    scope: ?[]const []const u8 = null,
};

fn awaitCallback(a: std.mem.Allocator, oauth: *const OAuth, state: []const u8, cancel_flag: *const std.atomic.Value(bool)) !Callback {
    const uri = std.Uri.parse(oauth.redirect_uri) catch return error.LoginFailed;
    const path = uri.path.percent_encoded;
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", uri.port orelse 80) catch return error.LoginFailed;
    var listener = address.listen(platform.io, .{ .reuse_address = true }) catch return error.LoginFailed;
    defer listener.deinit(platform.io);

    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [4 * 1024]u8 = undefined;
    while (true) {
        if (cancel_flag.load(.acquire)) return error.Cancelled;
        var connection = listener.accept(platform.io) catch return error.LoginFailed;
        defer connection.close(platform.io);
        var reader = connection.reader(platform.io, &in_buf);
        var writer = connection.writer(platform.io, &out_buf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch continue;
        const target = request.head.target;
        const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
        const got_state = param(a, query, "state");
        const code = param(a, query, "code");
        const error_param = param(a, query, "error");
        const valid = std.mem.indexOf(u8, target, path) != null and got_state != null and
            std.mem.eql(u8, got_state.?, state) and error_param == null and code != null;
        request.respond(if (valid) SuccessPage else FailurePage, .{
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        }) catch {};
        if (!valid) {
            if (got_state == null and code == null and error_param == null) continue;
            return error.LoginFailed;
        }
        return .{
            .code = code.?,
            .client_id = param(a, query, "client_id"),
            .scope = splitScopes(a, param(a, query, "scope")),
        };
    }
}

fn splitScopes(a: std.mem.Allocator, scope: ?[]const u8) ?[]const []const u8 {
    const text = scope orelse return null;
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " +");
    while (it.next()) |s| out.append(a, s) catch {};
    return out.toOwnedSlice(a) catch null;
}

fn param(a: std.mem.Allocator, query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        const buf = a.dupe(u8, pair[eq + 1 ..]) catch return null;
        for (buf) |*ch| {
            if (ch.* == '+') ch.* = ' ';
        }
        return std.Uri.percentDecodeInPlace(buf);
    }
    return null;
}

// Waking the listener lets a blocked accept observe a request to cancel.
pub fn cancel(oauth: *const OAuth) void {
    const uri = std.Uri.parse(oauth.redirect_uri) catch return;
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", uri.port orelse 80) catch return;
    const stream = address.connect(platform.io, .{ .mode = .stream }) catch return;
    defer stream.close(platform.io);
}

const SuccessPage =
    "<!doctype html><meta charset=utf-8><title>mini</title>" ++
    "<p>Signed in. You can close this tab and return to mini.</p>";
const FailurePage =
    "<!doctype html><meta charset=utf-8><title>mini</title>" ++
    "<p>Sign-in failed. You can close this tab and return to mini.</p>";

const Token = struct {
    access: []const u8,
    id_token: ?[]const u8 = null,
    refresh: ?[]const u8 = null,
    expires_in: ?u64 = null,
    scope: ?[]const u8 = null,
};

const TokenResponse = struct {
    access_token: ?[]const u8 = null,
    id_token: ?[]const u8 = null,
    refresh_token: ?[]const u8 = null,
    expires_in: ?u64 = null,
    scope: ?[]const u8 = null,
};

fn exchange(a: std.mem.Allocator, oauth: *const OAuth, client_id: []const u8, code: []const u8, verifier: []const u8, cancel_token: Cancel) !Token {
    const body = try formBody(a, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", client_id },
        .{ "code", code },
        .{ "code_verifier", verifier },
        .{ "redirect_uri", oauth.redirect_uri },
        .{ "resource", oauth.resource },
    });
    return postToken(a, oauth, body, cancel_token);
}

fn refresh(a: std.mem.Allocator, oauth: *const OAuth, record: *const Record, refresh_token: []const u8, cancel_token: ?Cancel) !Record {
    const client_id = record.client_id orelse return error.LoginFailed;
    const body = try formBody(a, &.{
        .{ "grant_type", "refresh_token" },
        .{ "client_id", client_id },
        .{ "refresh_token", refresh_token },
        .{ "resource", oauth.resource },
    });
    const token = try postToken(a, oauth, body, cancel_token);
    var fresh = record.*;
    fresh.access_token = token.access;
    fresh.id_token = token.id_token orelse record.id_token;
    fresh.refresh_token = token.refresh orelse refresh_token;
    fresh.expires_in = token.expires_in;
    fresh.scopes = splitScopes(a, token.scope) orelse record.scopes;
    return fresh;
}

// The refresh token is unusable and the user has to authorize again.
fn unusable(code: []const u8) bool {
    const rejected = [_][]const u8{
        "invalid_grant",
        "invalid_refresh_token",
        "token_expired",
        "refresh_token_expired",
        "refresh_token_invalidated",
        "refresh_token_reused",
    };
    for (rejected) |name| {
        if (std.mem.eql(u8, name, code)) return true;
    }
    return false;
}

const Failure = struct { @"error": ?[]const u8 = null };

fn postToken(a: std.mem.Allocator, oauth: *const OAuth, body: []const u8, cancel_token: ?Cancel) !Token {
    var err_body: ?[]const u8 = null;
    const text = http.fetch(a, .POST, oauth.token_url, &.{
        .{ .name = "content-type", .value = "application/x-www-form-urlencoded" },
        .{ .name = "accept", .value = "application/json" },
    }, body, &err_body, cancel_token) catch |e| {
        if (e == error.HttpStatus) {
            if (err_body) |body_text| {
                const failure = std.json.parseFromSliceLeaky(Failure, a, body_text, .{ .ignore_unknown_fields = true }) catch Failure{};
                if (failure.@"error") |code| {
                    if (unusable(code)) return error.InvalidGrant;
                }
            }
        }
        return error.LoginFailed;
    };
    const response = std.json.parseFromSliceLeaky(TokenResponse, a, text, .{ .ignore_unknown_fields = true }) catch
        return error.LoginFailed;
    const access = response.access_token orelse return error.LoginFailed;
    return .{
        .access = access,
        .id_token = response.id_token,
        .refresh = response.refresh_token,
        .expires_in = response.expires_in,
        .scope = response.scope,
    };
}

const IdClaims = struct {
    iss: ?[]const u8 = null,
    aud: ?std.json.Value = null,
    nonce: ?[]const u8 = null,
    exp: ?i64 = null,
    sub: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

fn validate(claims: IdClaims, client_id: []const u8, nonce: []const u8) !void {
    if (claims.iss) |iss| {
        if (!std.mem.eql(u8, iss, "https://auth.openai.com")) return error.LoginFailed;
    }
    if (claims.nonce) |value| {
        if (!std.mem.eql(u8, value, nonce)) return error.LoginFailed;
    }
    if (claims.exp) |exp| {
        if (exp <= std.Io.Timestamp.now(platform.io, .real).toSeconds()) return error.LoginFailed;
    }
    if (claims.aud) |aud| {
        if (!audMatches(aud, client_id)) return error.LoginFailed;
    }
}

fn audMatches(aud: std.json.Value, client_id: []const u8) bool {
    return switch (aud) {
        .string => |s| std.mem.eql(u8, s, client_id),
        .array => |items| for (items.items) |item| {
            if (item == .string and std.mem.eql(u8, item.string, client_id)) break true;
        } else false,
        else => true,
    };
}

fn idClaims(a: std.mem.Allocator, jwt: ?[]const u8) !IdClaims {
    const text = jwt orelse return error.LoginFailed;
    const buf = try a.alloc(u8, text.len);
    const payload = jwtPayload(text, buf) orelse return error.LoginFailed;
    return std.json.parseFromSliceLeaky(IdClaims, a, payload, .{ .ignore_unknown_fields = true }) catch return error.LoginFailed;
}

// The decoded JWT payload, written into `buf`.
fn jwtPayload(jwt: []const u8, buf: []u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, jwt, '.');
    _ = it.next() orelse return null;
    const part = it.next() orelse return null;
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(part) catch return null;
    if (size > buf.len) return null;
    std.base64.url_safe_no_pad.Decoder.decode(buf[0..size], part) catch return null;
    return buf[0..size];
}

// Whether the stored access token is at or near the end of its life. The token
// response's `expires_in` is authoritative; decoding the access token is the
// fallback for a record written before it was kept.
fn expiring(record: Record) bool {
    const now = std.Io.Timestamp.now(platform.io, .real).toSeconds();
    if (record.expires_in) |seconds| {
        if (record.saved_at) |saved| return now >= saved + @as(i64, @intCast(seconds)) - 60;
    }
    const access = record.access_token orelse return false;
    return expiresSoon(access, now);
}

fn expiresSoon(jwt: []const u8, now: i64) bool {
    var buf: [4096]u8 = undefined;
    const payload = jwtPayload(jwt, &buf) orelse return false;
    const claims = std.json.parseFromSlice(IdClaims, std.heap.page_allocator, payload, .{ .ignore_unknown_fields = true }) catch return false;
    defer claims.deinit();
    const exp = claims.value.exp orelse return false;
    return exp - now < 60;
}

const Pkce = struct { verifier: []const u8, challenge: []const u8 };

fn pkce(a: std.mem.Allocator) !Pkce {
    const verifier = try randomToken(a, 32);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(digest.len));
    return .{ .verifier = verifier, .challenge = std.base64.url_safe_no_pad.Encoder.encode(encoded, &digest) };
}

fn randomToken(a: std.mem.Allocator, n: usize) ![]const u8 {
    const bytes = try a.alloc(u8, n);
    std.Io.random(platform.io, bytes);
    const encoded = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(n));
    return std.base64.url_safe_no_pad.Encoder.encode(encoded, bytes);
}

fn generateHostId(a: std.mem.Allocator) ![]const u8 {
    var b: [16]u8 = undefined;
    std.Io.random(platform.io, &b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    return std.fmt.allocPrint(a, "urn:uuid:{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        b[0], b[1], b[2],  b[3],  b[4],  b[5],  b[6],  b[7],
        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
    });
}

fn encode(a: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            try out.append(a, c);
        } else {
            try out.appendSlice(a, &.{ '%', hex(c >> 4), hex(c & 0xf) });
        }
    }
}

fn hex(v: u8) u8 {
    return if (v < 10) '0' + v else 'a' + (v - 10);
}

fn formBody(a: std.mem.Allocator, pairs: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (pairs, 0..) |p, i| {
        if (i > 0) try out.append(a, '&');
        try encode(a, &out, p[0]);
        try out.append(a, '=');
        try encode(a, &out, p[1]);
    }
    return out.toOwnedSlice(a);
}
