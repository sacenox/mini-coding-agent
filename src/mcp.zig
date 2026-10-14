const std = @import("std");
const platform = @import("platform.zig");
const config = @import("config.zig");
const http = @import("http.zig");
const json = @import("json.zig");

// Only the stateless MCP revision is supported: no handshake, no session,
// protocol metadata in `_meta` on every request. A server rejects whatever
// revision it does not speak and names the ones it does, so the first request
// probes with the newest revision and `negotiatedVersion` retries with the
// server's newest. No single revision is pinned.
const preferred_version = "2026-07-28";
const client_name = "mini-coding-agent";
const client_version = "0.1.0";

/// The subcommand runs one request with no interactive cancellation.
var no_cancel = std.atomic.Value(bool).init(false);

const Tool = struct {
    name: []const u8,
    path: []const u8,
    description: []const u8,
    schema: ?std.json.Value,
};

pub fn usage() void {
    platform.printErr(
        \\usage: mini mcp <command>
        \\  search <query>          discover tools across configured servers
        \\  describe <path>         show the docs for one tool
        \\  invoke <path> <json>    call a tool with JSON arguments
        \\
    , .{});
}

pub fn run(a: std.mem.Allocator, cfg: *const config.Config, args: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const al = arena_state.allocator();

    if (cfg.mcp_servers.map.count() == 0) {
        platform.printErr("no MCP servers configured; add \"mcpServers\" to {s}\n", .{cfg.path});
        return 1;
    }
    if (args.len == 0) {
        usage();
        return 1;
    }

    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "search")) {
        return search(al, cfg, if (args.len > 1) args[1] else "");
    }
    if (std.mem.eql(u8, cmd, "describe")) {
        if (args.len < 2) {
            platform.printErr("usage: mini mcp describe <path>\n", .{});
            return 1;
        }
        return describe(al, cfg, args[1]);
    }
    if (std.mem.eql(u8, cmd, "invoke")) {
        if (args.len < 2) {
            platform.printErr("usage: mini mcp invoke <path> <json>\n", .{});
            return 1;
        }
        return invoke(al, cfg, args[1], if (args.len > 2) args[2] else "{}");
    }

    platform.printErr("unknown mcp command: {s}\n", .{cmd});
    usage();
    return 1;
}

fn search(al: std.mem.Allocator, cfg: *const config.Config, query: []const u8) u8 {
    var tools: std.ArrayList(Tool) = .empty;
    fetchTools(al, cfg, &tools) catch return 1;

    const Ranked = struct { score: i32, tool: Tool };
    var ranked: std.ArrayList(Ranked) = .empty;
    for (tools.items) |t| {
        const s = score(t, query) orelse continue;
        ranked.append(al, .{ .score = s, .tool = t }) catch return 1;
    }
    std.mem.sort(Ranked, ranked.items, {}, struct {
        fn lessThan(_: void, x: Ranked, y: Ranked) bool {
            return x.score > y.score;
        }
    }.lessThan);

    const Match = struct { path: []const u8, description: []const u8 };
    var matches: std.ArrayList(Match) = .empty;
    for (ranked.items) |r| matches.append(al, .{
        .path = r.tool.path,
        .description = r.tool.description,
    }) catch return 1;

    const body = std.json.Stringify.valueAlloc(al, struct { results: []const Match }{
        .results = matches.items,
    }, .{}) catch return 1;
    platform.writeOut(body);
    platform.writeOut("\n");
    return 0;
}

fn score(t: Tool, query: []const u8) ?i32 {
    if (query.len == 0) return 0;
    if (std.ascii.eqlIgnoreCase(t.name, query)) return 1000;
    if (std.ascii.eqlIgnoreCase(t.path, query)) return 900;
    if (std.ascii.startsWithIgnoreCase(t.path, query)) return 600;
    if (std.ascii.findIgnoreCase(t.path, query) != null) return 300;
    if (std.ascii.findIgnoreCase(t.description, query) != null) return 100;
    return null;
}

fn describe(al: std.mem.Allocator, cfg: *const config.Config, path: []const u8) u8 {
    var tools: std.ArrayList(Tool) = .empty;
    fetchTools(al, cfg, &tools) catch return 1;

    for (tools.items) |t| {
        if (!std.mem.eql(u8, t.path, path)) continue;
        var out: std.Io.Writer.Allocating = .init(al);
        out.writer.writeAll(t.path) catch return 1;
        if (t.description.len > 0) {
            out.writer.writeAll("\n") catch return 1;
            out.writer.writeAll(t.description) catch return 1;
        }
        out.writer.writeAll("\n\n") catch return 1;
        writeSignature(&out.writer, t.path, t.schema) catch return 1;
        out.writer.writeAll("\n") catch return 1;
        platform.writeOut(out.written());
        return 0;
    }

    platform.printErr("mcp: no tool at path {s}\n", .{path});
    return 1;
}

fn invoke(al: std.mem.Allocator, cfg: *const config.Config, path: []const u8, json_args: []const u8) u8 {
    const dot = std.mem.indexOfScalar(u8, path, '.') orelse {
        platform.printErr("mcp: tool path must be <server>.<tool>\n", .{});
        return 1;
    };
    const server = path[0..dot];
    const tool_name = path[dot + 1 ..];
    const sc = cfg.mcp_servers.map.get(server) orelse {
        platform.printErr("mcp: no server named {s}\n", .{server});
        return 1;
    };
    _ = std.json.parseFromSliceLeaky(std.json.Value, al, json_args, .{}) catch {
        platform.printErr("mcp: arguments must be valid JSON\n", .{});
        return 1;
    };

    const result = callRpc(al, server, sc, "tools/call", tool_name, json_args) catch return 1;
    const rendered = renderResult(al, result) catch return 1;
    if (isError(result)) {
        platform.writeErr(rendered);
        return 1;
    }
    platform.writeOut(rendered);
    return 0;
}

fn isError(result: std.json.Value) bool {
    const v = objField(result, "isError") orelse return false;
    return v == .bool and v.bool;
}

fn renderResult(al: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(al);
    if (structuredContent(result)) |structured| {
        try std.json.Stringify.value(structured, .{ .whitespace = .indent_2 }, &out.writer);
    } else if (try textContent(al, result)) |text| {
        try out.writer.writeAll(text);
    } else {
        try std.json.Stringify.value(result, .{ .whitespace = .indent_2 }, &out.writer);
    }
    const written = out.written();
    if (written.len == 0 or written[written.len - 1] != '\n') try out.writer.writeByte('\n');
    return out.written();
}

/// The tool's `structuredContent`, or null when absent. Rendering prefers it so
/// a result that carries both it and text is not printed twice.
fn structuredContent(result: std.json.Value) ?std.json.Value {
    const v = objField(result, "structuredContent") orelse return null;
    return if (v == .null) null else v;
}

/// Concatenates the `content[].text` entries, or null when the result carries
/// none. A tool that returns neither text nor structured content gets its whole
/// result printed.
fn textContent(al: std.mem.Allocator, result: std.json.Value) !?[]const u8 {
    const content = objField(result, "content") orelse return null;
    if (content != .array) return null;

    var out: std.Io.Writer.Allocating = .init(al);
    var wrote = false;
    for (content.array.items) |item| {
        const kind = objField(item, "type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "text")) continue;
        const text = objField(item, "text") orelse continue;
        if (text != .string) continue;
        try out.writer.writeAll(text.string);
        wrote = true;
    }
    if (!wrote) return null;
    return out.written();
}

fn fetchTools(al: std.mem.Allocator, cfg: *const config.Config, out: *std.ArrayList(Tool)) !void {
    var it = cfg.mcp_servers.map.iterator();
    while (it.next()) |entry| {
        const server = entry.key_ptr.*;
        const sc = entry.value_ptr.*;
        const result = callRpc(al, server, sc, "tools/list", null, null) catch continue;
        const tools = objField(result, "tools") orelse continue;
        if (tools != .array) continue;
        for (tools.array.items) |t| {
            const name = objField(t, "name") orelse continue;
            if (name != .string) continue;
            const description = objField(t, "description") orelse std.json.Value{ .string = "" };
            try out.append(al, .{
                .name = name.string,
                .path = try std.fmt.allocPrint(al, "{s}.{s}", .{ server, name.string }),
                .description = if (description == .string) description.string else "",
                .schema = objField(t, "inputSchema"),
            });
        }
    }
}

/// One JSON-RPC request, retried once at the revision the server advertises
/// when it rejects ours. Prints any transport or protocol error with the server
/// name and returns an error, so callers only decide whether to stop.
fn callRpc(
    al: std.mem.Allocator,
    server: []const u8,
    sc: config.McpServer,
    method: []const u8,
    name: ?[]const u8,
    arguments_json: ?[]const u8,
) !std.json.Value {
    var version: []const u8 = preferred_version;
    var retried = false;
    while (true) {
        const response = request(al, server, sc, version, method, name, arguments_json) catch return error.McpRequest;
        const root = parseResponse(al, response.body) catch {
            platform.printErr("mcp {s}: malformed response\n", .{server});
            return error.McpRequest;
        };
        if (root != .object) {
            platform.printErr("mcp {s}: malformed response\n", .{server});
            return error.McpRequest;
        }
        if (root.object.get("error")) |err| {
            if (!retried) {
                if (negotiatedVersion(err)) |v| {
                    retried = true;
                    version = v;
                    continue;
                }
            }
            platform.printErr("mcp {s}: {s}\n", .{ server, errorText(err) });
            return error.McpRequest;
        }
        return root.object.get("result") orelse {
            platform.printErr("mcp {s}: unexpected response (HTTP {d})\n", .{ server, response.status });
            return error.McpRequest;
        };
    }
}

/// The server's answer to a revision it does not speak: `data.supported` when
/// structured, or the list named in the message text otherwise. Returns the
/// newest revision the server accepts, or null when the error is unrelated.
fn negotiatedVersion(err: std.json.Value) ?[]const u8 {
    if (objField(err, "data")) |data| {
        if (objField(data, "supported")) |supported| {
            if (supported == .array) for (supported.array.items) |item| {
                if (item == .string) return item.string;
            };
        }
    }
    const message = errorText(err);
    const marker = "supported versions:";
    const at = std.mem.indexOf(u8, message, marker) orelse return null;
    const rest = std.mem.trim(u8, message[at + marker.len ..], " \t");
    var end = rest.len;
    if (std.mem.indexOfScalar(u8, rest, ',')) |c| end = c else if (std.mem.indexOfScalar(u8, rest, ')')) |p| end = p;
    const first = std.mem.trim(u8, rest[0..end], " \t");
    return if (first.len > 0) first else null;
}

fn request(
    al: std.mem.Allocator,
    server: []const u8,
    sc: config.McpServer,
    version: []const u8,
    method: []const u8,
    name: ?[]const u8,
    arguments_json: ?[]const u8,
) !http.Response {
    const body = try buildBody(al, version, method, name, arguments_json);

    var headers: std.ArrayList(http.Header) = .empty;
    try headers.append(al, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(al, .{ .name = "Accept", .value = "application/json, text/event-stream" });
    try headers.append(al, .{ .name = "MCP-Protocol-Version", .value = version });
    try headers.append(al, .{ .name = "Mcp-Method", .value = method });
    if (name) |n| try headers.append(al, .{ .name = "Mcp-Name", .value = n });
    if (sc.headers) |hs| {
        var hit = hs.map.iterator();
        while (hit.next()) |h| try headers.append(al, .{ .name = h.key_ptr.*, .value = h.value_ptr.* });
    }

    return http.post(al, sc.url, headers.items, body, &no_cancel) catch |e| {
        platform.printErr("mcp {s}: {s}\n", .{ server, @errorName(e) });
        return error.McpRequest;
    };
}

fn buildBody(al: std.mem.Allocator, version: []const u8, method: []const u8, name: ?[]const u8, arguments_json: ?[]const u8) ![]const u8 {
    return std.json.Stringify.valueAlloc(al, Request{
        .method = method,
        .params = .{
            .name = name,
            .arguments = if (arguments_json) |args| .{ .bytes = args } else null,
            ._meta = .{ .version = version },
        },
    }, .{ .emit_null_optional_fields = false });
}

const meta_prefix = "io.modelcontextprotocol/";

/// `_meta` keys carry a reverse-DNS prefix that Zig identifiers cannot hold, so
/// the object is written field by field.
const Meta = struct {
    version: []const u8,

    pub fn jsonStringify(self: Meta, jws: anytype) !void {
        try jws.beginObject();
        try jws.objectField(meta_prefix ++ "protocolVersion");
        try jws.write(self.version);
        try jws.objectField(meta_prefix ++ "clientInfo");
        try jws.write(ClientInfo{});
        try jws.objectField(meta_prefix ++ "clientCapabilities");
        try jws.write(Capabilities{});
        try jws.endObject();
    }
};

const ClientInfo = struct {
    name: []const u8 = client_name,
    version: []const u8 = client_version,
};

const Capabilities = struct {};

const Request = struct {
    jsonrpc: []const u8 = "2.0",
    id: u32 = 1,
    method: []const u8,
    params: Params,
};

const Params = struct {
    name: ?[]const u8 = null,
    arguments: ?json.Raw = null,
    _meta: Meta,
};

/// Responses are either a JSON object or a request-scoped SSE stream whose
/// last `data:` payload carries the reply.
fn parseResponse(al: std.mem.Allocator, body: []const u8) !std.json.Value {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '{') {
        return std.json.parseFromSliceLeaky(std.json.Value, al, trimmed, .{});
    }
    var last: ?std.json.Value = null;
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, "data:")) continue;
        const payload = std.mem.trim(u8, line["data:".len..], " \t");
        if (payload.len == 0) continue;
        last = std.json.parseFromSliceLeaky(std.json.Value, al, payload, .{}) catch continue;
    }
    return last orelse error.MalformedResponse;
}

fn objField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn errorText(err: std.json.Value) []const u8 {
    const message = objField(err, "message") orelse return "request failed";
    return if (message == .string) message.string else "request failed";
}

fn writeSignature(w: *std.Io.Writer, path: []const u8, schema: ?std.json.Value) !void {
    try w.print("{s}(args: ", .{path});
    if (schema) |s| {
        if (s == .object) try writeObjectType(w, s.object) else try w.writeAll("unknown");
    } else {
        try w.writeAll("unknown");
    }
    try w.writeAll("): Promise<unknown>");
}

fn writeObjectType(w: *std.Io.Writer, obj: std.json.ObjectMap) std.Io.Writer.Error!void {
    const props = obj.get("properties") orelse return w.writeAll("Record<string, unknown>");
    if (props != .object or props.object.count() == 0) return w.writeAll("Record<string, unknown>");

    const required = obj.get("required");
    try w.writeAll("{ ");
    var it = props.object.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) try w.writeAll("; ");
        first = false;
        try w.writeAll(entry.key_ptr.*);
        if (!isRequired(required, entry.key_ptr.*)) try w.writeByte('?');
        try w.writeAll(": ");
        try writeType(w, entry.value_ptr.*);
    }
    try w.writeAll(" }");
}

fn writeType(w: *std.Io.Writer, v: std.json.Value) std.Io.Writer.Error!void {
    if (v != .object) return w.writeAll("unknown");
    const obj = v.object;
    const kind = obj.get("type") orelse return w.writeAll("unknown");
    if (kind != .string) return w.writeAll("unknown");
    if (std.mem.eql(u8, kind.string, "string")) return w.writeAll("string");
    if (std.mem.eql(u8, kind.string, "integer")) return w.writeAll("number");
    if (std.mem.eql(u8, kind.string, "number")) return w.writeAll("number");
    if (std.mem.eql(u8, kind.string, "boolean")) return w.writeAll("boolean");
    if (std.mem.eql(u8, kind.string, "array")) return w.writeAll("unknown[]");
    if (std.mem.eql(u8, kind.string, "object")) return writeObjectType(w, obj);
    return w.writeAll("unknown");
}

fn isRequired(v: ?std.json.Value, key: []const u8) bool {
    const required = v orelse return false;
    if (required != .array) return false;
    for (required.array.items) |item| {
        if (item != .string) continue;
        if (std.mem.eql(u8, item.string, key)) return true;
    }
    return false;
}
