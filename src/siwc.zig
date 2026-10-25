const std = @import("std");
const platform = @import("platform.zig");
const config = @import("config.zig");
const filesystem = @import("filesystem.zig");
const http = @import("http.zig");
const auth = @import("auth.zig");
const time = @import("time.zig");

const redirect_uri = "http://127.0.0.1:1455/auth/callback";
const discovery_url = "https://auth.openai.com/.well-known/openid-configuration";
const issuer = "https://auth.openai.com";
const identity_scope = "openid profile email offline_access resource.invoke";
const default_brand = "Mini-coding-agent";
const max_brand = 24;

pub const Error = error{ LoginFailed, OutOfMemory };

/// Runs the Sign in with ChatGPT (SIWC) flow and writes the credential record.
/// Called by `mini login`; never from the TUI, where the loopback listener and
/// a browser hand-off would block the render loop.
pub fn login(a: std.mem.Allocator, cfg: *const config.Config) Error!void {
    const previous = auth.load(a);
    const host = hostId(a) catch return error.OutOfMemory;
    const verifier = random(a, 32) catch return error.OutOfMemory;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const challenge = encode64(a, &digest) catch return error.OutOfMemory;
    const state = random(a, 16) catch return error.OutOfMemory;
    const nonce = random(a, 16) catch return error.OutOfMemory;

    // A returning account reauthorizes its issued client; a new one registers.
    const saved_id: ?[]const u8 = if (previous) |r| r.clientId else null;
    const saved_token: ?[]const u8 = if (previous) |r| r.idToken else null;
    const url = authorizeUrl(a, .{
        .client_id = saved_id orelse "dynamic_agent_client",
        .host_id = host,
        .state = state,
        .nonce = nonce,
        .challenge = challenge,
        .agent_name = if (saved_id == null) "mini" else null,
        .id_token_hint = saved_token,
    }) catch return error.OutOfMemory;

    // Bind before the browser opens: a fast redirect must not find a closed port.
    var listener = listen() catch return error.LoginFailed;
    defer listener.deinit(platform.io);

    platform.printErr("sign-in: opening the browser\n{s}\n\n", .{redact(a, url)});
    openBrowser(url);

    const callback = serve(a, &listener, state, brand(cfg)) catch return error.LoginFailed;

    const body = auth.form(a, &.{
        .{ "grant_type", "authorization_code" },
        .{ "client_id", callback.client_id orelse saved_id orelse return error.LoginFailed },
        .{ "code", callback.code },
        .{ "code_verifier", verifier },
        .{ "redirect_uri", redirect_uri },
        .{ "resource", auth.resource },
    }) catch return error.OutOfMemory;
    const response = auth.tokenRequest(a, body, null) orelse return error.LoginFailed;
    const access = response.access_token orelse return error.LoginFailed;
    const scope = response.scope orelse callback.scope orelse "";
    if (!auth.granted(scope, auth.plan_scope)) {
        platform.printErr("sign-in: the ChatGPT plan permission was not granted\n", .{});
        return error.LoginFailed;
    }
    const identity = verifyIdToken(a, response.id_token orelse return error.LoginFailed, .{
        .client_id = callback.client_id orelse saved_id orelse return error.LoginFailed,
        .nonce = nonce,
    }) orelse return error.LoginFailed;

    auth.save(a, .{
        .email = identity,
        .clientId = callback.client_id orelse saved_id orelse return error.LoginFailed,
        .accessToken = access,
        .refreshToken = response.refresh_token,
        .idToken = response.id_token,
        .expiresAt = time.nowMs() + @as(i64, @intCast(response.expires_in orelse 3600)) * 1000,
        .scope = scope,
    }) catch {
        platform.printErr("sign-in: could not write {s}\n", .{auth.path(a)});
        return error.LoginFailed;
    };

    platform.printErr("sign-in: done, {s}; credentials in {s}\n", .{ identity, auth.path(a) });
}

const Authorize = struct {
    client_id: []const u8,
    host_id: []const u8,
    state: []const u8,
    nonce: []const u8,
    challenge: []const u8,
    agent_name: ?[]const u8 = null,
    id_token_hint: ?[]const u8 = null,
};

fn authorizeUrl(a: std.mem.Allocator, p: Authorize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(a, auth.scope_url);
    try out.append(a, '?');
    const pairs = [_][2]?[]const u8{
        .{ "client_id", p.client_id },
        .{ "agent_name_hint", p.agent_name },
        .{ "ext_agent_host_id", p.host_id },
        .{ "id_token_hint", p.id_token_hint },
        .{ "response_type", "code" },
        .{ "redirect_uri", redirect_uri },
        .{ "scope", identity_scope ++ " " ++ auth.plan_scope },
        .{ "resource", auth.resource },
        .{ "state", p.state },
        .{ "nonce", p.nonce },
        .{ "code_challenge", p.challenge },
        .{ "code_challenge_method", "S256" },
    };
    var first = true;
    for (pairs) |pair| {
        const value = pair[1] orelse continue;
        if (!first) try out.append(a, '&');
        first = false;
        try auth.appendEncoded(a, &out, pair[0].?);
        try out.append(a, '=');
        try auth.appendEncoded(a, &out, value);
    }
    return out.toOwnedSlice(a);
}

const Callback = struct {
    code: []const u8,
    client_id: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

fn listen() Error!std.Io.net.Server {
    const uri = std.Uri.parse(redirect_uri) catch return error.LoginFailed;
    const port = uri.port orelse 1455;
    const address = std.Io.net.IpAddress.parseIp4("127.0.0.1", port) catch return error.LoginFailed;
    return address.listen(platform.io, .{ .reuse_address = true }) catch {
        platform.printErr("sign-in: cannot listen on 127.0.0.1:{d}\n", .{port});
        return error.LoginFailed;
    };
}

/// Serves the loopback callback until the redirect arrives. Unrelated requests
/// (favicon, browser preconnect) are answered and ignored; only a callback
/// carrying our state, or an explicit failure, ends the wait.
fn serve(a: std.mem.Allocator, listener: *std.Io.net.Server, state: []const u8, name: []const u8) Error!Callback {
    var in_buf: [16 * 1024]u8 = undefined;
    var out_buf: [8 * 1024]u8 = undefined;
    var conn_arena = std.heap.ArenaAllocator.init(a);
    defer conn_arena.deinit();
    while (true) {
        var connection = listener.accept(platform.io) catch return error.LoginFailed;
        defer connection.close(platform.io);

        // A browser preconnect completes the handshake and then sends nothing;
        // never block the accept loop on it.
        var ready = [_]std.posix.pollfd{.{
            .fd = connection.socket.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if ((std.posix.poll(&ready, 2000) catch 0) == 0) continue;

        _ = conn_arena.reset(.retain_capacity);
        const ca = conn_arena.allocator();

        var reader = connection.reader(platform.io, &in_buf);
        var writer = connection.writer(platform.io, &out_buf);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        var request = server.receiveHead() catch continue;

        const target = request.head.target;
        const query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[i + 1 ..] else "";
        const got_state = param(ca, query, "state");
        const code = param(ca, query, "code");
        const failure = param(ca, query, "error");
        const ok = got_state != null and std.mem.eql(u8, got_state.?, state) and
            failure == null and code != null;

        request.respond(page(ca, name, ok), .{
            .status = if (ok) .ok else .bad_request,
            .extra_headers = &.{.{ .name = "content-type", .value = "text/html; charset=utf-8" }},
        }) catch {};
        if (ok) return .{
            .code = a.dupe(u8, code.?) catch return error.OutOfMemory,
            .client_id = duped(a, param(ca, query, "client_id")),
            .scope = duped(a, param(ca, query, "scope")),
        };
        if (failure != null or code != null or got_state != null) return error.LoginFailed;
    }
}

fn duped(a: std.mem.Allocator, value: ?[]const u8) ?[]const u8 {
    return a.dupe(u8, value orelse return null) catch null;
}

/// Drops the id_token_hint value: the docs require authorization URLs carrying
/// it to be redacted from logs and diagnostics.
fn redact(a: std.mem.Allocator, url: []const u8) []const u8 {
    const key = "id_token_hint=";
    const start = std.mem.indexOf(u8, url, key) orelse return url;
    const value_start = start + key.len;
    const value_end = std.mem.indexOfScalarPos(u8, url, value_start, '&') orelse url.len;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, url[0..value_start]) catch return url;
    out.appendSlice(a, "redacted") catch return url;
    out.appendSlice(a, url[value_end..]) catch return url;
    return out.toOwnedSlice(a) catch url;
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

fn hostId(a: std.mem.Allocator) ![]const u8 {
    const file = try filesystem.join(a, &.{ config.configDir(a), "host-id" });
    if (filesystem.readFileAlloc(a, file, 256)) |text| {
        const trimmed = std.mem.trim(u8, text, " \r\n\t");
        if (trimmed.len > 0) return trimmed;
    } else |_| {}
    var b: [16]u8 = undefined;
    std.Io.random(platform.io, &b);
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    const id = try std.fmt.allocPrint(a, "urn:uuid:{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        b[0], b[1], b[2],  b[3],  b[4],  b[5],  b[6],  b[7],
        b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15],
    });
    try filesystem.writeFile(file, id);
    return id;
}

fn random(a: std.mem.Allocator, n: usize) ![]const u8 {
    const bytes = try a.alloc(u8, n);
    std.Io.random(platform.io, bytes);
    return encode64(a, bytes);
}

fn encode64(a: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const out = try a.alloc(u8, std.base64.url_safe_no_pad.Encoder.calcSize(bytes.len));
    return std.base64.url_safe_no_pad.Encoder.encode(out, bytes);
}

fn decode64(a: std.mem.Allocator, text: []const u8) ?[]u8 {
    const trimmed = std.mem.trimEnd(u8, text, "=");
    const size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(trimmed) catch return null;
    const out = a.alloc(u8, size) catch return null;
    std.base64.url_safe_no_pad.Decoder.decode(out, trimmed) catch return null;
    return out;
}

fn openBrowser(url: []const u8) void {
    var child = std.process.spawn(platform.io, .{
        .argv = &.{ "xdg-open", url },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    _ = child.wait(platform.io) catch {};
}

const Expect = struct { client_id: []const u8, nonce: []const u8 };

var never = std.atomic.Value(bool).init(false);

/// Validates the ID token: RS256 signature against the published JWKS, then
/// the claims this flow depends on. Returns the email when one is present.
fn verifyIdToken(a: std.mem.Allocator, token: []const u8, expect: Expect) ?[]const u8 {
    const split = std.mem.lastIndexOfScalar(u8, token, '.') orelse return null;
    const header_end = std.mem.indexOfScalar(u8, token, '.') orelse return null;
    const signing_input = token[0..split];
    const header = std.json.parseFromSliceLeaky(Header, a, decode64(a, token[0..header_end]) orelse return null, .{
        .ignore_unknown_fields = true,
    }) catch return null;

    if (header.alg == null or !std.mem.eql(u8, header.alg.?, "RS256")) {
        platform.printErr("sign-in: unexpected id token algorithm\n", .{});
        return null;
    }
    if (!verifySignature(a, signing_input, decode64(a, token[split + 1 ..]) orelse return null, header.kid)) {
        platform.printErr("sign-in: id token signature did not verify\n", .{});
        return null;
    }

    const claims = std.json.parseFromSliceLeaky(Claims, a, decode64(a, token[header_end + 1 .. split]) orelse return null, .{
        .ignore_unknown_fields = true,
    }) catch return null;

    if (claims.iss == null or !std.mem.eql(u8, claims.iss.?, issuer)) return null;
    if (!audMatches(claims.aud, expect.client_id)) return null;
    if (claims.nonce == null or !std.mem.eql(u8, claims.nonce.?, expect.nonce)) return null;
    const exp = seconds(claims.exp) orelse return null;
    if (exp <= @divTrunc(time.nowMs(), 1000)) return null;
    return claims.email;
}

const Header = struct { alg: ?[]const u8 = null, kid: ?[]const u8 = null };

const Claims = struct {
    iss: ?[]const u8 = null,
    aud: ?std.json.Value = null,
    exp: ?std.json.Value = null,
    nonce: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

const Key = struct {
    kty: ?[]const u8 = null,
    kid: ?[]const u8 = null,
    n: ?[]const u8 = null,
    e: ?[]const u8 = null,
};

fn verifySignature(a: std.mem.Allocator, msg: []const u8, sig: []const u8, kid: ?[]const u8) bool {
    const rsa = std.crypto.Certificate.rsa;
    const meta = http.get(a, discovery_url, &.{}, &never) catch return false;
    const discovery = std.json.parseFromSliceLeaky(struct {
        jwks_uri: ?[]const u8 = null,
    }, a, meta, .{ .ignore_unknown_fields = true }) catch return false;
    const jwks_uri = discovery.jwks_uri orelse return false;

    const body = http.get(a, jwks_uri, &.{}, &never) catch return false;
    const keys = std.json.parseFromSliceLeaky(struct { keys: []const Key }, a, body, .{
        .ignore_unknown_fields = true,
    }) catch return false;

    for (keys.keys) |key| {
        if (key.kty == null or !std.mem.eql(u8, key.kty.?, "RSA")) continue;
        if (kid) |want| {
            if (key.kid == null or !std.mem.eql(u8, key.kid.?, want)) continue;
        }
        const modulus_bytes = decode64(a, key.n orelse continue) orelse continue;
        const exponent_bytes = decode64(a, key.e orelse continue) orelse continue;
        if (sig.len != modulus_bytes.len) continue;
        const public_key = rsa.PublicKey.fromBytes(exponent_bytes, modulus_bytes) catch continue;
        return switch (sig.len) {
            256 => checkRs256(256, sig, msg, public_key),
            384 => checkRs256(384, sig, msg, public_key),
            512 => checkRs256(512, sig, msg, public_key),
            else => false,
        };
    }
    return false;
}

fn checkRs256(comptime len: usize, sig: []const u8, msg: []const u8, key: std.crypto.Certificate.rsa.PublicKey) bool {
    std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(
        len,
        sig[0..len],
        msg,
        key,
        std.crypto.hash.sha2.Sha256,
    ) catch return false;
    return true;
}

fn audMatches(aud: ?std.json.Value, client_id: []const u8) bool {
    const value = aud orelse return false;
    return switch (value) {
        .string => |s| std.mem.eql(u8, s, client_id),
        .array => |items| blk: {
            for (items.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, client_id)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn seconds(value: ?std.json.Value) ?i64 {
    const v = value orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .number_string => |s| std.fmt.parseInt(i64, s, 10) catch null,
        else => null,
    };
}

/// The configured brand, or the default when it is missing or carries anything
/// outside a conservative printable set. This is the boundary that keeps the
/// value safe to interpolate into the page.
fn brand(cfg: *const config.Config) []const u8 {
    const raw = cfg.oauth_redirect_brand orelse return default_brand;
    if (raw.len == 0 or raw.len > max_brand) return default_brand;
    for (raw) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', ' ', '.', '-', '_' => {},
        else => return default_brand,
    };
    return raw;
}

const style =
    ":root{color-scheme:dark}" ++
    "*{box-sizing:border-box}" ++
    "body{margin:0;min-height:100vh;display:grid;place-items:center;" ++
    "background:#0b0d10;color:#e6e8eb;" ++
    "font:400 15px/1.6 ui-sans-serif,system-ui,-apple-system,'Segoe UI',sans-serif}" ++
    "main{text-align:center;padding:2.5rem 2rem}" ++
    ".mark{width:52px;height:52px;margin:0 auto 22px;border-radius:14px;" ++
    "display:grid;place-items:center;font-size:20px;font-weight:600;" ++
    "text-transform:uppercase;background:#12161b;border:1px solid #232a33}" ++
    ".ok{color:#8fd6a4}" ++
    ".err{color:#e08f8f}" ++
    "h1{margin:0 0 6px;font-size:16px;font-weight:600;letter-spacing:-.01em}" ++
    "p{margin:0;color:#7d868f;font-size:13px}";

const template =
    "<!doctype html><html lang=en style=\"background:#0b0d10\">" ++
    "<meta charset=utf-8>" ++
    "<meta name=viewport content=\"width=device-width,initial-scale=1\">" ++
    "<title>{s}</title><style>{s}</style>" ++
    "<main><div class=\"mark {s}\">{s}</div><h1>{s}</h1><p>{s}</p></main>";

/// Dark by default, in `color-scheme` and in the inline html background, so the
/// browser never paints a white frame before the stylesheet applies.
fn page(a: std.mem.Allocator, name: []const u8, ok: bool) []const u8 {
    const initial = if (name.len > 0) name[0..1] else "m";
    const message = if (ok)
        "You're signed in. You can close this tab."
    else
        "Sign-in didn't complete. Check the terminal and try again.";
    return std.fmt.allocPrint(a, template, .{
        name,
        style,
        if (ok) "ok" else "err",
        initial,
        name,
        message,
    }) catch "<!doctype html><html style=\"background:#0b0d10\"><title>mini</title>";
}
