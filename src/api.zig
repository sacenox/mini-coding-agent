//! The provider contract: one streaming request in, one assistant message out,
//! with deltas delivered through a sink.

const std = @import("std");
const types = @import("types.zig");
const http = @import("http.zig");
const util = @import("util.zig");

pub const Event = union(enum) {
    /// Assistant text delta.
    text: []const u8,
    /// Reasoning delta.
    reasoning: []const u8,
    /// A tool call block began; the name is known but arguments have not
    /// finished streaming.
    tool_start: []const u8,
    /// A tool call block finished.
    tool_call: types.ToolCall,
};

pub const Sink = struct {
    ctx: *anyopaque,
    on_event: *const fn (ctx: *anyopaque, event: Event) void,

    pub fn emit(self: Sink, event: Event) void {
        self.on_event(self.ctx, event);
    }
};

/// JSON written byte-for-byte as it stands, never re-encoded. The struct field
/// that holds it supplies the key.
pub const Raw = struct {
    bytes: []const u8 = "",

    pub fn jsonStringify(self: Raw, jws: anytype) !void {
        try jws.beginWriteRaw();
        try jws.writer.writeAll(self.bytes);
        jws.endWriteRaw();
    }
};

/// A provider error value: a message string, or an object carrying one under
/// "message". An empty string is no error at all.
pub const ErrField = struct {
    message: ?[]const u8 = null,

    const Body = struct { message: ?[]const u8 = null };

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        if (try source.peekNextTokenType() != .object_begin) {
            const token = try source.nextAlloc(allocator, options.allocate.?);
            return .{ .message = switch (token) {
                .string, .allocated_string => |v| v,
                else => null,
            } };
        }
        const body = try std.json.innerParse(Body, allocator, source, options);
        return .{ .message = if (body.message) |m| if (m.len > 0) m else null else null };
    }
};

/// A token count a provider may send as an integer or a float.
pub const Count = struct {
    value: u64 = 0,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !@This() {
        _ = options;
        const token = try source.nextAlloc(allocator, .alloc_if_needed);
        return switch (token) {
            .number, .allocated_number => |n| .{ .value = @intFromFloat(@max(std.fmt.parseFloat(f64, n) catch 0, 0)) },
            .null => .{},
            else => error.UnexpectedToken,
        };
    }
};

pub const Request = struct {
    /// Long-lived allocator: the returned message's content outlives the step.
    pers: std.mem.Allocator,
    /// Per-step arena: the request body and each parsed event. Reset freely.
    scratch: std.mem.Allocator,
    model: *const types.Model,
    system_prompt: []const u8,
    /// A pre-serialized JSON array of tool schemas, verbatim.
    tools_json: []const u8,
    messages: []const types.Message,
    effort: []const u8,
    session_id: ?[]const u8,
    cancel: *const std.atomic.Value(bool),
};

/// An untrusted stream index is a hint, never a size. Anything past this is
/// treated like a missing index so a hostile chunk cannot force an allocation.
pub const max_stream_index = 10_000;

/// How one wire reaches its provider: the URL, the key header, and the body
/// encoder. Everything else about the request is the same for all four.
pub const Wire = struct {
    /// The header the api key travels in, and the prefix its value carries.
    /// An empty key sends no header at all.
    key_header: []const u8,
    key_prefix: []const u8 = "",
    /// A protocol version header, sent verbatim when its name is not empty.
    version: [2][]const u8 = .{ "", "" },
    /// The path appended to the model's base URL, after any trailing slash.
    /// `build_url` overrides it for a provider whose URL is not base plus path.
    path: []const u8 = "",
    build_url: ?*const fn (std.mem.Allocator, Request) anyerror![]u8 = null,
    build_body: *const fn (Request) anyerror![]u8,
};

/// The request life cycle every wire shares, over a `State` that carries
/// `req`, `sink`, `arena`, `msg`, `stream_error` and `failed`, and handles each
/// payload through `State.handle`. `finalize` moves the accumulated state into
/// `msg`.
///
/// A stream that fails or is cancelled still finalizes first: the text the
/// model did stream belongs in the transcript, and dropping it would lose a
/// turn the user can see and cannot recover. A tool call whose arguments never
/// finished is not emitted, so a partial call is never handed to a tool.
pub fn run(
    comptime State: type,
    comptime Chunk: type,
    comptime wire: Wire,
    req: Request,
    sink: Sink,
    finalize: *const fn (st: *State) std.mem.Allocator.Error!void,
) std.mem.Allocator.Error!types.AssistantMessage {
    var msg = newAssistant(req);

    var arena = std.heap.ArenaAllocator.init(req.scratch);
    defer arena.deinit();

    const url = if (wire.build_url) |build|
        build(req.scratch, req) catch return error.OutOfMemory
    else
        buildUrl(req.scratch, req.model.base_url, wire.path) catch return error.OutOfMemory;
    const hdrs = try wireHeaders(req.scratch, req, wire);
    const body = wire.build_body(req) catch return error.OutOfMemory;

    var st = State{ .req = req, .sink = sink, .arena = &arena, .msg = &msg };

    // A stream that did not run to the end can leave a tool call with a name
    // but truncated arguments. Such a call is not a call the model finished
    // making, so `finalize` drops it rather than emit arguments to run; the
    // transport's own stop reason is the one the message keeps.
    const complete = try post(req, url, hdrs, body, .{ .ctx = &st, .onEvent = onData(State, Chunk) }, &msg);
    st.failed = !complete;
    const reason = msg.stop_reason;
    const message = msg.error_message;
    try finalize(&st);
    if (!complete) {
        msg.stop_reason = reason;
        msg.error_message = message;
    }

    if (st.stream_error) |text| {
        msg.stop_reason = .err;
        msg.error_message = try req.pers.dupe(u8, text);
    }
    return msg;
}

/// The SSE hook every wire shares: parse one payload into the wire's `Chunk`
/// type and hand it to `State.handle`. The arena is reset before the next
/// payload, so nothing may keep a pointer into the chunk.
fn onData(comptime State: type, comptime Chunk: type) *const fn (ctx: *anyopaque, data: []const u8) void {
    return struct {
        fn hook(ctx: *anyopaque, data: []const u8) void {
            const st: *State = @ptrCast(@alignCast(ctx));
            defer _ = st.arena.reset(.retain_capacity);
            // The sentinel OpenAI-compatible streams send in place of a final
            // event. It is not JSON, and it is not a failure.
            if (std.mem.eql(u8, std.mem.trim(u8, data, " \r\n"), "[DONE]")) return;
            const chunk = std.json.parseFromSliceLeaky(Chunk, st.arena.allocator(), data, .{ .ignore_unknown_fields = true }) catch |e| {
                if (e != error.OutOfMemory and st.stream_error == null) st.stream_error = "stream: invalid JSON chunk";
                return;
            };
            State.handle(st, chunk) catch {
                if (st.stream_error == null) st.stream_error = "stream: out of memory";
            };
        }
    }.hook;
}

/// Grows `list` so `index` exists, and returns the element there. An untrusted
/// stream index is a hint, never a size: anything outside the sane range
/// appends instead, so a hostile chunk cannot force an allocation.
pub fn blockAt(comptime T: type, list: *std.ArrayList(T), a: std.mem.Allocator, index: i64) !*T {
    const idx: usize = if (index >= 0 and index <= max_stream_index)
        @intCast(index)
    else
        list.items.len;
    while (list.items.len <= idx) try list.append(a, .{});
    return &list.items[idx];
}

/// Runs one streaming request. Transport and protocol failures are recorded in
/// the returned message's `stop_reason`/`error_message`; only a failure to
/// allocate is an error.
pub fn stream(req: Request, sink: Sink) std.mem.Allocator.Error!types.AssistantMessage {
    if (std.mem.eql(u8, req.model.api, "openai-completions")) {
        return @import("api/openai_completions.zig").stream(req, sink);
    }
    if (std.mem.eql(u8, req.model.api, "anthropic-messages")) {
        return @import("api/anthropic_messages.zig").stream(req, sink);
    }
    if (std.mem.eql(u8, req.model.api, "openai-responses")) {
        return @import("api/openai_responses.zig").stream(req, sink);
    }
    if (std.mem.eql(u8, req.model.api, "google-generative-ai")) {
        return @import("api/google_generative_ai.zig").stream(req, sink);
    }
    var msg = newAssistant(req);
    msg.stop_reason = .err;
    msg.error_message = "provider: unsupported api";
    return msg;
}

fn newAssistant(req: Request) types.AssistantMessage {
    return .{
        .content = .empty,
        .api = req.model.api,
        .provider = req.model.provider,
        .model = req.model.id,
        .timestamp = util.nowMs(),
    };
}

/// The header list every request shares: content negotiation, the wire's own
/// key and version headers, then the caller's custom and session headers. A
/// header with an empty value is left out entirely.
fn wireHeaders(a: std.mem.Allocator, req: Request, wire: Wire) ![]http.Header {
    var list: std.ArrayList(http.Header) = .empty;
    errdefer list.deinit(a);
    try list.append(a, .{ .name = "Content-Type", .value = "application/json" });
    try list.append(a, .{ .name = "Accept", .value = "text/event-stream" });
    if (wire.version[0].len > 0) {
        try list.append(a, .{ .name = wire.version[0], .value = wire.version[1] });
    }
    if (wire.key_header.len > 0) {
        if (req.model.api_key) |key| {
            if (key.len > 0) {
                try list.append(a, .{
                    .name = wire.key_header,
                    .value = try std.fmt.allocPrint(a, "{s}{s}", .{ wire.key_prefix, key }),
                });
            }
        }
    }
    for (req.model.headers) |kv| try list.append(a, .{ .name = kv[0], .value = kv[1] });
    if (req.session_id) |sid| {
        if (req.model.session_header) |name| {
            if (sid.len > 0) try list.append(a, .{ .name = name, .value = sid });
        }
    }
    return list.toOwnedSlice(a);
}

/// Sends the request and maps a transport failure onto `msg`. Returns false
/// once the caller must return `msg` as-is; true when the stream completed and
/// the caller should proceed to finalize.
fn post(req: Request, url: []const u8, hdrs: []const http.Header, body: []const u8, handler: http.SseHandler, msg: *types.AssistantMessage) std.mem.Allocator.Error!bool {
    var err_body: ?[]const u8 = null;
    http.postSse(req.scratch, url, hdrs, body, handler, req.cancel, &err_body) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        if (e == error.Aborted or req.cancel.load(.acquire)) {
            msg.stop_reason = .aborted;
        } else {
            msg.stop_reason = .err;
            const message = switch (e) {
                error.HttpStatus => err_body orelse "provider returned an error status",
                error.ReadFailed => "stream read failed",
                else => "request failed",
            };
            msg.error_message = try req.pers.dupe(u8, message);
        }
        return false;
    };
    if (req.cancel.load(.acquire)) {
        msg.stop_reason = .aborted;
        return false;
    }
    return true;
}

/// One tool call as the provider streams it. The wires differ only in where
/// the pieces arrive; the shape and the accumulation are the same.
pub const Call = struct {
    id: []const u8 = "",
    name: []const u8 = "",
    args: std.ArrayList(u8) = .empty,
    started: bool = false,
    /// Google's continuation data, replayed on the next request.
    thought_signature: ?[]const u8 = null,

    /// Records the name and announces the call the first time one arrives.
    pub fn announce(self: *Call, a: std.mem.Allocator, sink: Sink, name: []const u8) !void {
        if (self.name.len == 0) self.name = try a.dupe(u8, name);
        if (!self.started and self.name.len > 0) {
            self.started = true;
            sink.emit(.{ .tool_start = self.name });
        }
    }
};

/// Appends every call the stream finished with, and says whether there was
/// one. A stream that failed left arguments truncated, so its calls are
/// dropped: a partial call is not a call the model finished making.
pub fn appendCalls(msg: *types.AssistantMessage, sink: Sink, a: std.mem.Allocator, calls: []const Call, failed: bool) !bool {
    if (failed) return false;
    var any = false;
    for (calls) |call| {
        if (call.name.len == 0) continue;
        any = true;
        try msg.content.append(a, .{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = argumentsOrObject(call.args.items),
            .thought_signature = call.thought_signature,
        } });
        sink.emit(.{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = argumentsOrObject(call.args.items),
        } });
    }
    return any;
}

/// A call's arguments, or an empty object when the provider streamed none.
pub fn argumentsOrObject(args: []const u8) []const u8 {
    return if (args.len > 0) args else "{}";
}

/// Records the tokens a response cost and prices them. The total is the
/// provider's own when it reported one, and the sum of the parts otherwise.
pub fn finishUsage(msg: *types.AssistantMessage, model: *const types.Model, usage: types.Usage) void {
    var u = usage;
    if (u.total_tokens == 0) u.total_tokens = u.input + u.output + u.cache_read + u.cache_write;
    const per = struct {
        fn cost(tokens: u64, rate: f64) f64 {
            return @as(f64, @floatFromInt(tokens)) * rate / 1_000_000.0;
        }
    };
    u.cost_input = per.cost(u.input, model.cost_input);
    u.cost_output = per.cost(u.output, model.cost_output);
    u.cost_cache_read = per.cost(u.cache_read, model.cost_cache_read);
    u.cost_total = u.cost_input + u.cost_output + u.cost_cache_read;
    msg.usage = u;
}

/// A non-empty string field, or null.
pub fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

/// How one provider frames its `tools` array value: `open` and `close` bound
/// it, and each element is `entry` wrapped around the call's schema under
/// `params_key`. The key `"tools"` is supplied by the struct field that holds
/// the value. A provider with no tools writes nothing at all, which is also how
/// an unparsable `tools_json` is treated.
pub const ToolsForm = struct {
    open: []const u8,
    entry: []const u8,
    params_key: []const u8,
    entry_close: []const u8 = "",
    close: []const u8,
};

/// A request's `tools` array, rendered verbatim from the flat `tools_json` the
/// session recorded, in the wire form `form` describes. It is written as an
/// array value, so the caller's struct field supplies the key.
pub const Tools = struct {
    a: std.mem.Allocator,
    json: []const u8,
    form: ToolsForm,

    pub fn jsonStringify(self: Tools, jws: anytype) !void {
        try jws.beginWriteRaw();
        try writeTools(jws.writer, self.a, self.json, self.form);
        jws.endWriteRaw();
    }
};

/// Writes the `tools` array in the wire form `form` describes, from the flat
/// `tools_json` array the session recorded. Nothing at all is written when
/// there is no tool, which is also how an unparsable `tools_json` is treated.
pub fn writeTools(w: *std.Io.Writer, a: std.mem.Allocator, tools_json: []const u8, form: ToolsForm) !void {
    if (tools_json.len == 0) return;
    const root = std.json.parseFromSliceLeaky(std.json.Value, a, tools_json, .{}) catch return;
    if (root != .array) return;
    var first = true;
    for (root.array.items) |tool| {
        if (tool != .object) continue;
        if (first) {
            try w.writeAll(form.open);
            first = false;
        } else {
            try w.writeByte(',');
        }
        try w.writeAll(form.entry);
        try writeToolBody(w, tool.object, form.params_key);
        try w.writeAll(form.entry_close);
    }
    if (first) return;
    try w.writeAll(form.close);
}

/// `"name":"…","description":"…","<params_key>":<schema>` — the body every
/// provider's tool encoding shares. A schema that names no parameters is sent
/// as `{}` rather than panicking on a session log written by another version.
fn writeToolBody(w: *std.Io.Writer, obj: std.json.ObjectMap, params_key: []const u8) !void {
    try w.writeAll("\"name\":");
    try std.json.Stringify.encodeJsonString(stringField(obj, "name") orelse "", .{}, w);
    try w.writeAll(",\"description\":");
    try std.json.Stringify.encodeJsonString(stringField(obj, "description") orelse "", .{}, w);
    try w.writeAll(",\"");
    try w.writeAll(params_key);
    try w.writeAll("\":");
    if (obj.get("parameters")) |params| {
        try std.json.Stringify.value(params, .{}, w);
    } else {
        try w.writeAll("{}");
    }
}

/// `base_url` plus one path segment, with a trailing slash on the base ignored.
fn buildUrl(a: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}{s}", .{ std.mem.trimEnd(u8, base, "/"), path });
}
