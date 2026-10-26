const std = @import("std");
const platform = @import("../platform.zig");
const time = @import("../time.zig");
const config = @import("../config.zig");
const session_mod = @import("../session.zig");
const message_mod = @import("../message.zig");
const agent = @import("../agent.zig");
const models_mod = @import("../models.zig");
const tools_index = @import("../tools.zig");
const render = @import("render.zig");
const styles = @import("styles.zig");
const term = @import("term.zig");
const input = @import("input.zig");
const editor_mod = @import("editor.zig");
const stream = @import("stream.zig");
const complete = @import("complete.zig");
const commands = @import("commands.zig");
const usage_mod = @import("usage.zig");
const diff_view = @import("diff_view.zig");
const tool_view = @import("tool_view.zig");
const image_view = @import("image.zig");
const picker_mod = @import("picker.zig");
const screen = @import("screen.zig");
const history = @import("../history.zig");
const status = @import("../status.zig");

const SPINNER = "⠀⠁⠂⠃⠄⠅⠆⠇⡀⡁⡂⡃⡄⡅⡆⡇⠈⠉⠊⠋⠌⠍⠎⠏⡈⡉⡊⡋⡌⡍⡎⡏⠐⠑⠒⠓⠔⠕⠖⠗⡐⡑⡒⡓⡔⡕⡖⡗⠘⠙⠚⠛⠜⠝⠞⠟⡘⡙⡚⡛⡜⡝⡞⡟⠠⠡⠢⠣⠤⠥⠦⠧⡠⡡⡢⡣⡤⡥⡦⡧⠨⠩⠪⠫⠬⠭⠮⠯⡨⡩⡪⡫⡬⡭⡮⡯⠰⠱⠲⠳⠴⠵⠶⠷⡰⡱⡲⡳⡴⡵⡶⡷⠸⠹⠺⠻⠼⠽⠾⠿⡸⡹⡺⡻⡼⡽⡾⡿⢀⢁⢂⢃⢄⢅⢆⢇⣀⣁⣂⣃⣄⣅⣆⣇⢈⢉⢊⢋⢌⢍⢎⢏⣈⣉⣊⣋⣌⣍⣎⣏⢐⢑⢒⢓⢔⢕⢖⢗⣐⣑⣒⣓⣔⣕⣖⣗⢘⢙⢚⢛⢜⢝⢞⢟⣘⣙⣚⣛⣜⣝⣞⣟⢠⢡⢢⢣⢤⢥⢦⢧⣠⣡⣢⣣⣤⣥⣦⣧⢨⢩⢪⢫⢬⢭⢮⢯⣨⣩⣪⣫⣬⣭⣮⣯⢰⢱⢲⢳⢴⢵⢶⢷⣰⣱⣲⣳⣴⣵⣶⣷⢸⢹⢺⢻⢼⢽⢾⢿⣸⣹⣺⣻⣼⣽⣾⣿";
const SPINNER_MS = 120;
const BODY_PREFIX = " │ ";
const ERROR_PREFIX = " ! ";

const PendingCall = tool_view.PendingCall;
const Picker = picker_mod.Picker;

const Command = commands.Command;

var resize_flag = std.atomic.Value(bool).init(false);
var exit_flag = std.atomic.Value(bool).init(false);
var exit_signal = std.atomic.Value(u32).init(0);

fn onWinch(_: std.posix.SIG) callconv(.c) void {
    resize_flag.store(true, .seq_cst);
}

fn onExitSignal(sig: std.posix.SIG) callconv(.c) void {
    term.restore();
    exit_signal.store(@backingInt(sig), .seq_cst);
    exit_flag.store(true, .seq_cst);
}

const Tui = struct {
    opts: *agent.Options,
    cfg: *const config.Config,
    history: history.Store = undefined,
    tool_names: []const config.ToolName,
    term: term.Terminal = .{},
    editor: editor_mod.Editor,
    live: screen.LiveRegion = .{},
    messages: std.ArrayList(message_mod.Message) = .empty,
    backing: std.mem.Allocator = undefined,
    arena: std.heap.ArenaAllocator,
    a: std.mem.Allocator,
    scratch: std.heap.ArenaAllocator,
    s: std.mem.Allocator,
    sarena: std.heap.ArenaAllocator,
    sa: std.mem.Allocator,
    calls: std.heap.ArenaAllocator,
    ca: std.mem.Allocator = undefined,
    image_seq: u32 = 0,

    input_bytes: std.ArrayList(u8) = .empty,
    input_batch: std.ArrayList(u8) = .empty,
    keys: std.ArrayList(input.Key) = .empty,
    parser: input.Parser = .{},
    stdin_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    eof_sent: bool = false,
    key_mutex: std.Io.Mutex = .init,
    messages_mutex: std.Io.Mutex = .init,
    events: std.ArrayList(agent.Event) = .empty,
    batch: std.ArrayList(agent.Event) = .empty,
    event_mutex: std.Io.Mutex = .init,
    qarena: std.heap.ArenaAllocator,
    q: std.mem.Allocator,

    phase: agent.Phase = .idle,
    detail: ?[]const u8 = null,
    retrying: ?[]const u8 = null,
    writing_tool: ?[]const u8 = null,
    writing_bytes: usize = 0,
    stream_kind: enum { none, reasoning, text, tool } = .none,
    text_bytes: usize = 0,
    reasoning_bytes: usize = 0,
    active: bool = false,
    paused: bool = false,
    retry: bool = false,
    pause_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    aborting: bool = false,
    turn_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    steering_text: []const u8 = "",
    steering_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    scrollback: screen.Scrollback = .{},

    reply: stream.MarkdownStream,
    pending_calls: std.ArrayList(PendingCall) = .empty,
    streamed: std.ArrayList(u8) = .empty,
    turn_start: i64 = 0,
    ctx_msgs: usize = std.math.maxInt(usize),
    ctx_used: u64 = 0,
    ctx_cache: message_mod.Usage = .{},
    frame: usize = 0,
    dirty: bool = true,
    closed: bool = false,
    last_frame_ms: i64 = 0,
    last_input_ms: i64 = 0,
    command_active: bool = false,

    picker_arena: std.heap.ArenaAllocator,
    picker_m: std.mem.Allocator = undefined,

    hist_index: ?usize = null,
    hist_saved: []const u8 = "",

    picker: ?Picker = null,

    model_thread: ?std.Thread = null,
    model_abort: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    model_ready: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    model_ok: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    model_entries: []const models_mod.Entry = &.{},
    model_provider: []const u8 = "",
    model_arena: std.heap.ArenaAllocator,
    model_m: std.mem.Allocator = undefined,

    fn init(a: std.mem.Allocator, opts: *agent.Options, cfg: *const config.Config, tool_names: []const config.ToolName) Tui {
        return .{
            .opts = opts,
            .cfg = cfg,
            .tool_names = tool_names,
            .editor = undefined,
            .backing = a,
            .arena = std.heap.ArenaAllocator.init(a),
            .a = undefined,
            .scratch = std.heap.ArenaAllocator.init(a),
            .s = undefined,
            .sarena = std.heap.ArenaAllocator.init(a),
            .sa = undefined,
            .calls = std.heap.ArenaAllocator.init(a),
            .qarena = std.heap.ArenaAllocator.init(a),
            .q = undefined,
            .model_arena = std.heap.ArenaAllocator.init(a),
            .picker_arena = std.heap.ArenaAllocator.init(a),
            .reply = undefined,
        };
    }

    fn bindAllocators(self: *Tui) void {
        self.a = self.arena.allocator();
        self.s = self.scratch.allocator();
        self.sa = self.sarena.allocator();
        self.ca = self.calls.allocator();
        self.q = self.qarena.allocator();
        self.model_m = self.model_arena.allocator();
        self.picker_m = self.picker_arena.allocator();
        self.editor = editor_mod.Editor.init(self.backing);
        self.editor.bind();
        self.editor.s = self.s;
        self.reply = stream.MarkdownStream.init(self.backing);
        self.reply.bind();
        self.scrollback.a = self.a;
        self.scrollback.scratch = self.sa;
    }

    fn resetScratch(self: *Tui) void {
        _ = self.scratch.reset(.retain_capacity);
        self.s = self.scratch.allocator();
        self.editor.s = self.s;
    }

    fn push(self: *Tui, line: []const u8) void {
        self.scrollback.push(line);
        self.dirty = true;
    }

    fn commitLines(self: *Tui, lines: []const render.BodyLine) void {
        self.scrollback.commitLines(lines);
        self.dirty = true;
    }

    fn note(self: *Tui, line: []const u8) void {
        self.scrollback.note(line);
        self.dirty = true;
    }

    fn fail(self: *Tui, comptime fmt: []const u8, args: anytype) void {
        self.note(styles.err(self.s, std.fmt.allocPrint(self.s, fmt, args) catch "! error"));
    }

    fn commitUser(self: *Tui, text: []const u8) void {
        self.scrollback.commitUser(text);
        self.dirty = true;
    }

    fn pushBanner(self: *Tui) void {
        self.scrollback.separator = true;
        const a = self.s;
        var parts: std.ArrayList([]const u8) = .empty;
        parts.append(a, styles.accent(a, "mini-coding-agent")) catch {};
        if (self.opts.model) |m| {
            parts.append(a, std.fmt.allocPrint(a, "{s}/{s}", .{ m.provider, m.id }) catch m.id) catch {};
            if (m.effort.len > 0) parts.append(a, m.effort) catch {};
        } else {
            parts.append(a, "no model configured") catch {};
        }
        self.push(styles.join(a, parts.items));
        const loaded = self.opts.loaded;
        var resources: std.ArrayList([]const u8) = .empty;
        if (loaded.agent_files > 0)
            resources.append(a, styles.comment(a, plural(a, loaded.agent_files, "agent file", "agent files"))) catch {};
        if (loaded.skills > 0)
            resources.append(a, styles.comment(a, plural(a, loaded.skills, "skill", "skills"))) catch {};
        if (resources.items.len > 0) self.push(styles.join(a, resources.items));
        self.scrollback.separator = true;
    }

    fn statusLine(self: *Tui) []const u8 {
        const model = self.opts.model orelse return styles.comment(self.s, "no model configured");
        self.messages_mutex.lockUncancelable(platform.io);
        const count = self.messages.items.len;
        if (count != self.ctx_msgs) {
            self.ctx_used = usage_mod.estimateContextTokens(self.messages.items, self.opts.system_prompt, self.opts.tools_json);
            self.ctx_cache = usage_mod.lastUsage(self.messages.items);
            self.ctx_msgs = count;
        }
        const used = self.ctx_used;
        const cache = self.ctx_cache;
        self.messages_mutex.unlock(platform.io);
        const info = std.fmt.allocPrint(self.s, "{s}{s}{s}", .{
            usage_mod.contextUsageLine(self.s, used, model),
            styles.sep(self.s),
            usage_mod.cacheLine(self.s, cache),
        }) catch "ctx";
        const sep = styles.sep(self.s);
        if (self.paused or self.phase == .pausing) {
            return std.fmt.allocPrint(self.s, "{s}{s}{s}", .{ styles.comment(self.s, "paused - type steering, Enter to submit"), sep, info }) catch info;
        }
        if (self.active and self.pause_requested.load(.seq_cst)) {
            return std.fmt.allocPrint(self.s, "{s}{s}{s}", .{ styles.comment(self.s, "pausing - waiting for the step boundary"), sep, info }) catch info;
        }
        if (self.retry) {
            return std.fmt.allocPrint(self.s, "{s}{s}{s}", .{ styles.err(self.s, "failed - Enter to retry"), sep, info }) catch info;
        }
        if (!self.active or self.phase == .idle) return info;
        const elapsed = @max(0, @divFloor(time.nowMs() - self.turn_start, 1000));
        return std.fmt.allocPrint(self.s, "{s} {s}{s}{s}{s}{s}", .{
            styles.accent(self.s, spinnerChar(self.frame)),
            self.stateLabel(),
            sep,
            styles.comment(self.s, std.fmt.allocPrint(self.s, "{d}s", .{elapsed}) catch ""),
            sep,
            info,
        }) catch info;
    }

    fn stateLabel(self: *Tui) []const u8 {
        const a = self.s;
        if (self.retrying) |text| return styles.styledWith(a, styles.roles.warn, text);
        var text: []const u8 = "idle";
        var role: ?styles.Style = null;
        var bytes: usize = 0;
        switch (self.phase) {
            .preparing => text = "preparing",
            .waiting_model => text = "waiting for provider",
            .snapshotting => {
                text = "snapshotting";
                role = styles.roles.warn;
            },
            .running_tool => {
                text = std.fmt.allocPrint(a, "running tool call {s}", .{self.detail orelse "tool"}) catch "running tool call";
                role = styles.roles.prompt;
            },
            .streaming => switch (self.stream_kind) {
                .tool => {
                    text = std.fmt.allocPrint(a, "writing tool call {s}", .{self.writing_tool orelse "tool"}) catch "writing tool call";
                    role = styles.roles.prompt;
                    bytes = self.writing_bytes;
                },
                .reasoning => {
                    text = "reasoning";
                    role = styles.roles.prompt;
                    bytes = self.reasoning_bytes;
                },
                .text => {
                    text = "writing response";
                    role = styles.roles.prompt;
                    bytes = self.text_bytes;
                },
                .none => text = "streaming",
            },
            else => {},
        }
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, if (role) |r| styles.styledWith(a, r, text) else styles.comment(a, text)) catch {};
        if (bytes > 0) {
            const n = usage_mod.formatTokens(a, (bytes + 3) / 4);
            out.appendSlice(a, styles.sep(a)) catch {};
            out.appendSlice(a, styles.comment(a, std.fmt.allocPrint(a, "~{s} tok", .{n}) catch "")) catch {};
        }
        const queued = self.pending_calls.items.len -| @intFromBool(self.phase == .running_tool);
        if (queued > 0) {
            out.appendSlice(a, styles.sep(a)) catch {};
            out.appendSlice(a, styles.comment(a, std.fmt.allocPrint(a, "{d} queued", .{queued}) catch "")) catch {};
        }
        return out.items;
    }

    fn plural(a: std.mem.Allocator, n: usize, one: []const u8, many: []const u8) []const u8 {
        return std.fmt.allocPrint(a, "{d} {s}", .{ n, if (n == 1) one else many }) catch many;
    }

    fn spinnerChar(frame: usize) []const u8 {
        var idx = frame % 256;
        var i: usize = 0;
        while (i < SPINNER.len) {
            const n = std.unicode.utf8ByteSequenceLength(SPINNER[i]) catch 1;
            if (idx == 0) return SPINNER[i .. i + n];
            idx -= 1;
            i += n;
        }
        return " ";
    }

    fn draw(self: *Tui) void {
        if (self.closed) return;
        self.resetScratch();
        const width = @max(self.term.width(), 1);
        const height = @max(self.term.height() - 1, 1);
        const status_line = self.statusLine();
        const status_rows = render.physicalRows(status_line, width);
        const editor_budget = height -| status_rows;
        const ed = self.editor.layout(width, @max(editor_budget, 1));

        var lines: std.ArrayList([]const u8) = .empty;
        lines.append(self.s, status_line) catch {};
        var caret_line: usize = 0;
        var caret_col: usize = 0;
        if (self.picker) |*p| {
            const prefix = std.fmt.allocPrint(self.s, "{s} › ", .{p.title}) catch "";
            lines.append(self.s, std.fmt.allocPrint(self.s, "{s}{s}", .{
                styles.styledWith(self.s, styles.over(.{ .bold = true }, styles.roles.prompt), prefix),
                render.sanitize(self.s, p.query.items),
            }) catch "> ") catch {};
            caret_line = 1;
            caret_col = render.displayWidth(prefix) + render.displayWidth(p.query.items);
            if (p.matches.items.len == 0) {
                lines.append(self.s, styles.comment(self.s, "  no matches")) catch {};
            } else {
                const budget = @max(height -| 2, 1);
                const first = if (p.sel >= budget) p.sel + 1 - budget else 0;
                const last = @min(p.matches.items.len, first + budget);
                for (p.matches.items[first..last], first..) |idx, i| {
                    const row = std.fmt.allocPrint(self.s, "{s}{s}", .{
                        if (i == p.sel) "❯ " else "  ",
                        render.sanitize(self.s, p.labels[idx]),
                    }) catch p.labels[idx];
                    lines.append(self.s, if (i == p.sel)
                        styles.styledWith(self.s, styles.over(.{ .bold = true }, styles.roles.prompt), row)
                    else
                        styles.comment(self.s, row)) catch {};
                }
            }
        } else {
            for (ed.rows) |r| lines.append(self.s, r) catch {};
            caret_line = 1 + ed.cursor_row;
            caret_col = ed.cursor_col;
        }

        const frame_text = self.live.draw(self.s, width, lines.items, caret_line, caret_col, self.scrollback.buf.items);
        self.term.write(frame_text);
        self.scrollback.clear();
        _ = self.sarena.reset(.retain_capacity);
        self.sa = self.sarena.allocator();
    }

    fn keepName(self: *Tui, slot: *?[]const u8, value: ?[]const u8) void {
        if (slot.*) |old| self.backing.free(old);
        slot.* = if (value) |v| self.backing.dupe(u8, v) catch null else null;
    }

    fn handleAgentEvent(self: *Tui, event: agent.Event) void {
        if (self.closed) return;
        if (self.aborting) return;
        self.resetScratch();
        if (std.meta.activeTag(event) != .retry) self.keepName(&self.retrying, null);
        switch (event) {
            .retry => |r| {
                const text = std.fmt.allocPrint(self.s, "retrying {d}/{d} in {d}s · {s}", .{
                    r.attempt, r.total, @divFloor(r.delay_ms + 999, 1000), r.reason,
                }) catch "";
                self.keepName(&self.retrying, text);
                status.report("working", null, r.reason);
            },
            .phase => |p| {
                self.phase = p.phase;
                self.keepName(&self.detail, p.detail);
                if (p.phase == .pausing) self.paused = true;
                if (p.phase == .running_tool) self.renderPendingCall();
                if (p.phase == .waiting_model) {
                    self.stream_kind = .none;
                    self.text_bytes = 0;
                    self.reasoning_bytes = 0;
                }
                status.report(switch (p.phase) {
                    .preparing, .waiting_model, .streaming, .snapshotting, .running_tool => "working",
                    .pausing => "blocked",
                    .idle => "idle",
                }, if (p.phase == .pausing) "question" else null, if (p.phase == .pausing) "paused - type steering to continue" else null);
                if (p.phase == .pausing) status.notify("mini: paused, waiting for steering");
            },
            .text => |delta| {
                self.stream_kind = .text;
                self.text_bytes += delta.len;
                self.streamed.appendSlice(self.a, delta) catch {};
                self.commitLines(self.reply.feed(self.s, delta));
            },
            .reasoning => |delta| {
                self.stream_kind = .reasoning;
                self.reasoning_bytes += delta.len;
            },
            .tool_call => |tc| {
                self.stream_kind = .none;
                self.keepName(&self.writing_tool, null);
                self.commitLines(self.reply.flush(self.s));
                const summary = tool_view.callSummary(self.ca, tc.name, tc.arguments);
                const display = if (std.mem.eql(u8, tc.name, "read") or std.mem.eql(u8, tc.name, "edit"))
                    tool_view.relativize(self.opts.session.cwd, summary)
                else
                    summary;
                self.pending_calls.append(self.a, .{
                    .name = self.ca.dupe(u8, tc.name) catch "",
                    .summary = display,
                }) catch {};
            },
            .tool_call_start => |name| {
                self.stream_kind = .tool;
                self.keepName(&self.writing_tool, name);
                self.writing_bytes = 0;
            },
            .tool_args => |n| self.writing_bytes = n,
            .tool_output => {},
            .message => |am| self.commitMessage(am),
            .tool_result => |tr| self.commitToolResult(tr.name, tr.text, tr.is_error, tr.diffs, tr.body, tr.images),
            .err => |m| {
                status.report("error", null, m);
                status.notify("mini: turn failed");
                self.retry = true;
                self.endTurn(styles.err(self.s, std.fmt.allocPrint(self.s, "! {s}", .{m}) catch "! error"));
            },
            .no_model => {
                status.report("error", null, "no model configured");
                self.endTurn(styles.err(self.s, "! no model configured"));
            },
            .cancelled => {
                status.report("idle", null, null);
                self.endTurn(styles.err(self.s, "! cancelled"));
            },
            .complete => {
                status.report("done", null, null);
                status.notify("mini: turn complete");
                self.endTurn(styles.comment(self.s, std.fmt.allocPrint(self.s, "[complete · {d}s]", .{@max(0, @divFloor(time.nowMs() - self.turn_start, 1000))}) catch "[complete]"));
            },
        }
        self.dirty = true;
    }

    fn endTurn(self: *Tui, line: []const u8) void {
        self.phase = .idle;
        self.keepName(&self.detail, null);
        self.keepName(&self.writing_tool, null);
        self.paused = false;
        self.stream_kind = .none;
        self.commitLines(self.reply.flush(self.s));
        self.flushCalls();
        self.note(line);
    }

    fn commitMessage(self: *Tui, am: *message_mod.AssistantMessage) void {
        self.commitLines(self.reply.flush(self.s));
        defer self.streamed.clearRetainingCapacity();
        const text = am.text(self.s) catch return;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0 and std.mem.indexOf(u8, self.streamed.items, trimmed) == null) {
            self.commitLines(self.reply.feed(self.s, trimmed));
            self.commitLines(self.reply.flush(self.s));
        }
    }

    fn renderCall(self: *Tui, call: *PendingCall) void {
        if (call.rendered) return;
        self.scrollback.separator = true;
        for (tool_view.callBody(self.s, call.name, call.summary, @max(self.term.width(), 1))) |row| self.push(row);
        call.rendered = true;
    }

    fn renderPendingCall(self: *Tui) void {
        if (self.pending_calls.items.len == 0) return;
        self.renderCall(&self.pending_calls.items[0]);
    }

    fn commitToolResult(self: *Tui, name: []const u8, text: []const u8, is_error: bool, diffs: []const tools_index.FileDiff, body: ?[]const u8, images: []const message_mod.ImageContent) void {
        const shown = render.stripAnsi(self.s, text);
        const meta: ?[]const u8 = if (!is_error) body else null;
        var head_committed = false;
        if (self.pending_calls.items.len > 0) {
            var call = self.pending_calls.orderedRemove(0);
            head_committed = true;
            self.renderCall(&call);
        }
        if (!head_committed) self.scrollback.separator = true;
        if (self.cfg.show_images) self.commitImages(images);
        if (meta) |m| {
            self.push(tool_view.metaLine(self.s, m));
        } else {
            const width = @max(self.term.width() - BODY_PREFIX.len, 1);
            const is_bash = std.mem.eql(u8, name, "bash");
            const bash_exit: ?[]const u8 = if (is_bash) tool_view.exitLine(self.s, shown) else null;
            const result = tool_view.resultLines(self.s, name, shown, self.cfg.max_diff_lines);
            const rows = if (std.mem.eql(u8, name, "edit")) render.plainRows(self.s, result.lines, styles.roles.output) else render.bodyRows(self.s, result.lines, width, styles.roles.output);
            const mark_error = is_error and bash_exit == null;
            for (rows, 0..) |row, i| {
                const prefix = if (mark_error and i == rows.len - 1) styles.err(self.s, ERROR_PREFIX) else styles.comment(self.s, BODY_PREFIX);
                self.push(std.fmt.allocPrint(self.s, "{s}{s}", .{ prefix, row }) catch row);
            }
            if (bash_exit) |status_line| self.push(status_line);
            if (result.footer) |footer| self.push(footer);
        }
        for (diffs) |d| {
            self.push(tool_view.diffHead(self.s, name, d.path));
            const r = diff_view.diffBody(self.s, d, self.cfg.max_diff_lines);
            for (render.plainRows(self.s, r.lines, styles.roles.output)) |row| {
                self.push(std.fmt.allocPrint(self.s, "{s}{s}", .{ styles.comment(self.s, BODY_PREFIX), row }) catch row);
            }
            if (tool_view.diffFooter(self.s, r)) |footer| self.push(footer);
        }
        self.scrollback.separator = true;
    }

    fn commitImages(self: *Tui, images: []const message_mod.ImageContent) void {
        if (images.len == 0) return;
        const width = @max(self.term.width(), 1);
        const max_rows = @max(self.term.height() -| 2, 1);
        const cell = self.term.cell();
        const salt: u8 = @truncate(@as(u64, @bitCast(time.nowMs())));
        for (images) |image| {
            self.image_seq +%= 1;
            const id = image_view.imageId(salt, self.image_seq);
            if (image_view.block(self.s, id, image, width, max_rows, cell[0], cell[1])) |bytes| {
                self.scrollback.pushRaw(bytes);
            }
        }
    }

    fn flushCalls(self: *Tui) void {
        for (self.pending_calls.items) |*call| self.renderCall(call);
        self.pending_calls.clearRetainingCapacity();
        self.resetCalls();
    }

    fn resetCalls(self: *Tui) void {
        _ = self.calls.reset(.retain_capacity);
        self.ca = self.calls.allocator();
    }

    fn resetHistory(self: *Tui) void {
        if (self.hist_index == null) return;
        self.backing.free(self.hist_saved);
        self.hist_saved = "";
        self.hist_index = null;
    }

    fn historyWalk(self: *Tui, delta: isize) void {
        const n = self.history.entries.items.len;
        if (n == 0) return;
        if (self.hist_index == null) {
            self.hist_saved = self.backing.dupe(u8, self.editor.contents()) catch return;
            self.hist_index = n;
        }
        const idx = @as(isize, @intCast(self.hist_index.?)) + delta;
        if (idx < 0) return;
        if (idx >= @as(isize, @intCast(n))) {
            self.editor.setText(self.hist_saved);
            self.resetHistory();
            self.dirty = true;
            return;
        }
        self.hist_index = @intCast(idx);
        self.editor.setText(self.history.entries.items[@intCast(idx)]);
        self.dirty = true;
    }

    fn openHistorySearch(self: *Tui) void {
        self.resetHistory();
        self.startPicker(.history, "history");
        const p = &(self.picker orelse return);
        const entries = self.history.entries.items;
        const ids = self.picker_m.alloc([]const u8, entries.len) catch return;
        const labels = self.picker_m.alloc([]const u8, entries.len) catch return;
        for (entries, 0..) |e, i| {
            ids[i] = e;
            labels[i] = e[0 .. std.mem.indexOfScalar(u8, e, '\n') orelse e.len];
        }
        p.ids = ids;
        p.labels = labels;
        p.draft = self.picker_m.dupe(u8, self.editor.contents()) catch "";
        self.editor.clear();
        p.refresh(self.picker_m);
        self.dirty = true;
    }

    fn handleKey(self: *Tui, key: input.Key) void {
        self.resetScratch();
        if (self.picker != null) {
            self.pickerKey(key);
            return;
        }
        if (key == .reverse_search) {
            self.openHistorySearch();
            return;
        }
        if (key == .history_prev) {
            self.historyWalk(-1);
            return;
        }
        if (key == .history_next) {
            self.historyWalk(1);
            return;
        }
        if (key == .eof) {
            if (!self.active and !self.command_active and self.editor.contents().len == 0) self.exit();
            return;
        }
        if (key == .interrupt) {
            if (self.active) {
                self.abort.store(true, .seq_cst);
                self.steering_ready.store(true, .seq_cst);
                self.steering_text = "";
                if (!self.aborting) {
                    self.aborting = true;
                    status.report("idle", null, null);
                    self.endTurn(styles.err(self.s, "! cancelled"));
                }
                self.dirty = true;
            } else if (self.command_active) {
                self.command_active = false;
                self.closePicker();
                self.model_abort.store(true, .seq_cst);
                self.dirty = true;
            } else if (self.editor.contents().len != 0) {
                self.editor.clear();
                self.dirty = true;
            }
            return;
        }
        if (key == .escape) {
            if (self.active and !self.paused) {
                self.pause_requested.store(true, .seq_cst);
                self.dirty = true;
            }
            return;
        }
        if (key == .tab) {
            if (commands.completeCommand(self.editor.contents())) |text| {
                self.editor.setText(text);
            } else {
                _ = self.editor.completeWord(completePathStep);
            }
            self.dirty = true;
            return;
        }
        const result = self.editor.handle(key);
        if (result == .submit) {
            self.submit();
        } else if (result == .changed) {
            self.resetHistory();
            self.dirty = true;
        }
    }

    fn submit(self: *Tui) void {
        self.resetHistory();
        const text = self.a.dupe(u8, self.editor.contents()) catch return;
        if (self.active) {
            if (self.paused) {
                self.editor.clear();
                if (text.len > 0) self.commitUser(text);
                self.steering_text = text;
                self.steering_ready.store(true, .seq_cst);
                self.dirty = true;
            }
            return;
        }
        if (self.command_active) return;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            self.retryTurn();
            return;
        }
        if (commands.findCommand(text)) |found| {
            self.editor.clear();
            self.runCommand(found);
            self.dirty = true;
            return;
        }
        self.editor.clear();
        const message = message_mod.Message{ .user = .{ .content = self.a.dupe(u8, text) catch text, .timestamp = time.nowMs() } };
        self.messages_mutex.lockUncancelable(platform.io);
        self.messages.append(platform.gpa, message) catch {
            self.messages_mutex.unlock(platform.io);
            self.fail("! out of memory", .{});
            return;
        };
        self.messages_mutex.unlock(platform.io);
        self.opts.session.appendMessage(platform.gpa, message) catch |e| {
            self.fail("! {s}", .{@errorName(e)});
            return;
        };
        self.commitUser(text);
        self.history.add(text);
        self.startTurn();
    }

    fn retryTurn(self: *Tui) void {
        if (!self.retry or self.active) return;
        self.note(styles.comment(self.s, "retrying"));
        self.startTurn();
    }

    fn startTurn(self: *Tui) void {
        self.active = true;
        self.retry = false;
        self.abort.store(false, .seq_cst);
        self.pause_requested.store(false, .seq_cst);
        self.turn_done.store(false, .seq_cst);
        self.phase = .preparing;
        self.keepName(&self.detail, null);
        self.keepName(&self.retrying, null);
        self.turn_start = time.nowMs();
        self.frame = 0;
        self.event_mutex.lockUncancelable(platform.io);
        self.events.clearRetainingCapacity();
        _ = self.qarena.reset(.retain_capacity);
        self.q = self.qarena.allocator();
        self.event_mutex.unlock(platform.io);
        const t = std.Thread.spawn(.{}, turnThread, .{self}) catch return;
        t.detach();
        self.dirty = true;
    }

    fn runCommand(self: *Tui, command: Command) void {
        switch (command) {
            .help => self.showHelp(),
            .new => {
                self.newSession();
                self.push("");
                self.pushBanner();
                self.note(styles.comment(self.s, "new session"));
            },
            .provider => self.startProviderSelect(),
            .model => {
                const m = self.opts.model orelse return self.fail("! no model configured", .{});
                self.startModelFetch(m.provider);
            },
            .thinking => self.startThinkingSelect(),
        }
    }

    fn startThinkingSelect(self: *Tui) void {
        const m = self.opts.model orelse return self.fail("! no model configured", .{});
        const levels = models_mod.supportedLevels(self.a, self.cfg, m.provider, m.id);
        self.openPicker(.thinking, "thinking", levels, levels);
    }

    fn showHelp(self: *Tui) void {
        const keys = [_][2][]const u8{
            .{ "Enter", "submit; on an empty draft after a failure, retry it" },
            .{ "Shift+Enter", "newline (Ctrl+J also works)" },
            .{ "Shift+Up/Down", "walk input history (Ctrl+R to search)" },
            .{ "Esc", "pause the turn at the next step boundary" },
            .{ "Ctrl+C", "cancel the turn" },
            .{ "Ctrl+D", "exit on an empty draft" },
            .{ "Tab", "complete command or path" },
        };
        var width: usize = 0;
        for (Command.all) |c| width = @max(width, c.wire().len + 1);
        for (keys) |row| width = @max(width, row[0].len);
        self.note("commands");
        for (Command.all) |c| {
            self.push(commands.helpRow(self.s, std.fmt.allocPrint(self.s, "/{s}", .{c.wire()}) catch c.wire(), c.summary(), width));
        }
        self.push("");
        self.push("keybindings");
        for (keys) |row| self.push(commands.helpRow(self.s, row[0], row[1], width));
    }

    fn newSession(self: *Tui) void {
        self.opts.session.close();
        const cwd = std.process.currentPathAlloc(platform.io, self.backing) catch ".";
        self.opts.session.* = session_mod.Session.init(self.backing, self.cfg.sessions_dir, cwd);
        self.messages_mutex.lockUncancelable(platform.io);
        self.messages.clearRetainingCapacity();
        self.messages_mutex.unlock(platform.io);
        self.pending_calls.clearRetainingCapacity();
        self.streamed.clearRetainingCapacity();
        self.reply.reset();
        self.keepName(&self.detail, null);
        self.keepName(&self.writing_tool, null);
        self.steering_text = "";
        self.retry = false;
        self.phase = .idle;
        self.stream_kind = .none;
        self.resetCalls();
        self.dirty = true;
    }

    fn startProviderSelect(self: *Tui) void {
        const entries = models_mod.providers(self.a, self.cfg);
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (entries) |p| {
            if (!p.ready) continue;
            ids.append(self.a, p.id) catch {};
            names.append(self.a, p.name) catch {};
        }
        if (ids.items.len == 0) {
            self.fail("! no authenticated providers", .{});
            return;
        }
        self.openPicker(.provider, "provider", ids.items, names.items);
    }

    fn startModelFetch(self: *Tui, provider_id: []const u8) void {
        if (self.model_thread) |t| {
            self.model_abort.store(true, .seq_cst);
            t.join();
            self.model_thread = null;
        }
        _ = self.model_arena.reset(.retain_capacity);
        self.model_m = self.model_arena.allocator();
        self.model_provider = provider_id;
        self.model_entries = &.{};
        self.model_abort.store(false, .seq_cst);
        self.model_ok.store(false, .seq_cst);
        self.model_ready.store(false, .seq_cst);
        self.model_thread = std.Thread.spawn(.{}, modelFetchThread, .{self}) catch {
            self.fail("! cannot query models", .{});
            return;
        };
        self.command_active = true;
        self.note(styles.comment(self.s, "querying models..."));
        self.dirty = true;
    }

    fn modelFetchThread(self: *Tui) void {
        if (models_mod.listing(self.model_m, self.cfg, self.model_provider, &self.model_abort)) |entries| {
            self.model_entries = entries;
            self.model_ok.store(true, .seq_cst);
        } else |_| {
            self.model_ok.store(false, .seq_cst);
        }
        self.model_ready.store(true, .release);
    }

    fn openModelsPrompt(self: *Tui) void {
        if (self.model_entries.len == 0) {
            self.command_active = false;
            self.fail("! no models for provider", .{});
            return;
        }
        var ids: std.ArrayList([]const u8) = .empty;
        var names: std.ArrayList([]const u8) = .empty;
        for (self.model_entries) |e| {
            ids.append(self.a, e.id) catch {};
            names.append(self.a, e.name) catch {};
        }
        self.openPicker(.model, "model", ids.items, names.items);
        if (self.picker) |*p| p.provider = self.model_provider;
    }

    fn openPicker(self: *Tui, kind: picker_mod.Kind, title: []const u8, ids: []const []const u8, labels: []const []const u8) void {
        self.startPicker(kind, title);
        if (self.picker) |*p| {
            p.ids = ids;
            p.labels = labels;
            p.refresh(self.picker_m);
        }
        self.dirty = true;
    }

    fn startPicker(self: *Tui, kind: picker_mod.Kind, title: []const u8) void {
        _ = self.picker_arena.reset(.retain_capacity);
        self.picker_m = self.picker_arena.allocator();
        self.picker = .{ .kind = kind, .title = title };
        self.command_active = true;
    }

    fn closePicker(self: *Tui) void {
        self.picker = null;
    }

    fn pickerKey(self: *Tui, key: input.Key) void {
        const p = &(self.picker orelse return);
        switch (p.key(self.picker_m, key)) {
            .ignore => return,
            .update => {},
            .accept => self.pickerAccept(),
            .cancel => {
                const draft = p.draft;
                const restore = p.kind == .history;
                self.closePicker();
                self.command_active = false;
                if (restore) self.editor.setText(draft);
            },
        }
        self.dirty = true;
    }

    fn pickerAccept(self: *Tui) void {
        const p = self.picker orelse return;
        const id = p.current() orelse return;
        const kind = p.kind;
        const provider_id = p.provider;
        self.closePicker();
        self.command_active = false;
        switch (kind) {
            .provider => self.startModelFetch(id),
            .model => {
                var err: ?[]const u8 = null;
                const m = models_mod.resolveNamed(self.a, self.cfg, provider_id, id, &err) orelse return;
                const ptr = self.a.create(models_mod.Model) catch return;
                ptr.* = m;
                self.select(ptr);
                config.save(self.a, self.cfg, .{ .provider = provider_id, .model = id }) catch {};
                self.startThinkingSelect();
            },
            .thinking => {
                const m = self.opts.model orelse return;
                const updated = self.a.create(models_mod.Model) catch return;
                updated.* = m.*;
                updated.effort = models_mod.clampNamed(self.a, self.cfg, m.provider, m.id, id);
                self.select(updated);
                config.save(self.a, self.cfg, .{ .thinking_effort = id }) catch {};
            },
            .history => self.editor.setText(id),
        }
    }

    fn select(self: *Tui, m: *const models_mod.Model) void {
        self.opts.model = m;
        self.opts.supports_images = m.supports_images;
        self.opts.tools_json = tools_index.json(self.a, self.tool_names, self.opts.supports_images, self.opts.session.cwd);
        self.pushBanner();
        self.dirty = true;
    }

    fn isPauseRequested(ctx: *anyopaque) bool {
        const self: *Tui = @ptrCast(@alignCast(ctx));
        return self.pause_requested.load(.seq_cst);
    }
    fn clearPause(ctx: *anyopaque) void {
        const self: *Tui = @ptrCast(@alignCast(ctx));
        self.pause_requested.store(false, .seq_cst);
    }
    fn requestSteering(ctx: *anyopaque) []const u8 {
        const self: *Tui = @ptrCast(@alignCast(ctx));
        if (self.abort.load(.seq_cst)) return "";
        self.paused = true;
        self.dirty = true;
        while (!self.steering_ready.load(.seq_cst)) {
            if (self.abort.load(.seq_cst)) {
                self.paused = false;
                self.steering_ready.store(false, .seq_cst);
                return "";
            }
            std.Io.sleep(platform.io, .{ .nanoseconds = 10 * std.time.ns_per_ms }, .boot) catch {};
        }
        self.steering_ready.store(false, .seq_cst);
        self.paused = false;
        self.dirty = true;
        return self.steering_text;
    }

    fn exit(self: *Tui) void {
        if (self.closed) return;
        self.closed = true;
        self.abort.store(true, .seq_cst);
        self.steering_ready.store(true, .seq_cst);
        self.model_abort.store(true, .seq_cst);
        if (self.model_thread) |t| {
            t.join();
            self.model_thread = null;
        }
        const width = @max(self.term.width(), 1);
        self.term.write(self.live.erase(self.a, width));
        self.term.write(self.scrollback.buf.items);
        self.term.stop();
        if (self.opts.session.file != null) {
            if (self.opts.session.id) |id|
                platform.writeOut(styles.comment(self.a, std.fmt.allocPrint(self.a, "resume with: mini --resume {s}\n", .{id}) catch ""));
        }
        self.opts.session.close();
        status.release();
    }
};

fn completePathStep(word: []const u8) ?[]const u8 {
    return complete.completePath(word);
}

fn inputThread(self: *Tui) void {
    var buf: [4096]u8 = undefined;
    const stdin = std.Io.File.stdin();
    while (!self.closed) {
        const n = stdin.readStreaming(platform.io, &.{buf[0..]}) catch break;
        if (n == 0) break;
        self.key_mutex.lockUncancelable(platform.io);
        self.input_bytes.appendSlice(platform.gpa, buf[0..n]) catch {};
        self.key_mutex.unlock(platform.io);
    }
    self.stdin_closed.store(true, .seq_cst);
}

fn turnThread(self: *Tui) void {
    var o = self.opts.*;
    o.cancel = &self.abort;
    o.messages_mutex = &self.messages_mutex;
    agent.runTurn(o, &self.messages, .{
        .ctx = self,
        .is_pause_requested = Tui.isPauseRequested,
        .clear_pause = Tui.clearPause,
        .request_steering = Tui.requestSteering,
    }, .{ .ctx = self, .on_event = eventTrampoline });
    self.turn_done.store(true, .seq_cst);
}

fn copyEvent(a: std.mem.Allocator, e: agent.Event, with_images: bool) agent.Event {
    return switch (e) {
        .phase => |p| .{ .phase = .{ .phase = p.phase, .detail = if (p.detail) |d| a.dupe(u8, d) catch "" else null } },
        .retry => |r| .{ .retry = .{
            .attempt = r.attempt,
            .total = r.total,
            .delay_ms = r.delay_ms,
            .reason = a.dupe(u8, r.reason) catch "",
        } },
        .text => |s| .{ .text = a.dupe(u8, s) catch "" },
        .reasoning => |s| .{ .reasoning = a.dupe(u8, s) catch "" },
        .tool_call_start => |s| .{ .tool_call_start = a.dupe(u8, s) catch "" },
        .tool_output => |s| .{ .tool_output = a.dupe(u8, s) catch "" },
        .err => |s| .{ .err = a.dupe(u8, s) catch "" },
        .tool_call => |tc| .{ .tool_call = .{
            .name = a.dupe(u8, tc.name) catch "",
            .arguments = a.dupe(u8, tc.arguments) catch "",
        } },
        .tool_result => |tr| blk: {
            var diffs: []const tools_index.FileDiff = &.{};
            if (a.alloc(tools_index.FileDiff, tr.diffs.len)) |buf| {
                for (tr.diffs, 0..) |d, i| buf[i] = .{
                    .path = a.dupe(u8, d.path) catch "",
                    .patch = if (d.patch) |p| a.dupe(u8, p) catch "" else null,
                    .note = if (d.note) |n| a.dupe(u8, n) catch "" else null,
                };
                diffs = buf;
            } else |_| {}
            var images: []const message_mod.ImageContent = &.{};
            if (with_images) {
                if (a.alloc(message_mod.ImageContent, tr.images.len)) |buf| {
                    for (tr.images, 0..) |img, i| buf[i] = .{
                        .data = a.dupe(u8, img.data) catch "",
                        .mime_type = a.dupe(u8, img.mime_type) catch "",
                    };
                    images = buf;
                } else |_| {}
            }
            break :blk .{ .tool_result = .{
                .name = a.dupe(u8, tr.name) catch "",
                .text = a.dupe(u8, tr.text) catch "",
                .is_error = tr.is_error,
                .diffs = diffs,
                .body = if (tr.body) |b| a.dupe(u8, b) catch "" else null,
                .images = images,
            } };
        },
        else => e,
    };
}

fn eventTrampoline(ctx: *anyopaque, event: agent.Event) void {
    const self: *Tui = @ptrCast(@alignCast(ctx));
    switch (event) {
        .tool_output => return,
        else => {},
    }
    self.event_mutex.lockUncancelable(platform.io);
    self.events.append(platform.gpa, copyEvent(self.q, event, self.cfg.show_images)) catch {};
    self.event_mutex.unlock(platform.io);
}

pub fn run(opts: agent.Options, cfg: *const config.Config, tool_names: []const config.ToolName, resumed: []const message_mod.Message) !void {
    const gpa = platform.gpa;
    const opts_ptr = try gpa.create(agent.Options);
    opts_ptr.* = opts;
    const self = try gpa.create(Tui);
    self.* = Tui.init(gpa, opts_ptr, cfg, tool_names);
    self.bindAllocators();
    self.history = history.Store.init(gpa, config.historyPath(gpa), cfg.history_size);
    status.init(cfg);
    styles.applyScheme(cfg.colorscheme);

    self.term.start();
    defer self.term.stop();
    platform.onSignal(.WINCH, onWinch);
    for ([_]std.posix.SIG{ .TERM, .INT, .HUP, .QUIT }) |sig| platform.onSignal(sig, onExitSignal);

    status.report("idle", null, null);
    self.pushBanner();
    if (resumed.len > 0) {
        self.messages.appendSlice(gpa, resumed) catch {};
        self.note(styles.comment(self.s, std.fmt.allocPrint(self.s, "resumed {s} · {d} messages", .{
            opts_ptr.session.id orelse "",
            resumed.len,
        }) catch "resumed"));
    }
    self.draw();

    const stdin_thread = std.Thread.spawn(.{}, inputThread, .{self}) catch return;
    stdin_thread.detach();

    while (!self.closed) {
        self.key_mutex.lockUncancelable(platform.io);
        std.mem.swap(std.ArrayList(u8), &self.input_bytes, &self.input_batch);
        self.key_mutex.unlock(platform.io);
        self.keys.clearRetainingCapacity();
        const keys = &self.keys;
        if (self.input_batch.items.len > 0) {
            self.parser.feed(platform.gpa, self.input_batch.items, keys);
            self.last_input_ms = time.nowMs();
        }
        self.input_batch.clearRetainingCapacity();
        const now_early = time.nowMs();
        switch (self.parser.pending()) {
            .escape => if (now_early - self.last_input_ms > 30) self.parser.flushEscape(platform.gpa, keys),
            .sequence => if (now_early - self.last_input_ms > 150) self.parser.flushSequence(),
            .none => {},
        }
        if (self.stdin_closed.load(.seq_cst) and !self.eof_sent) {
            keys.append(platform.gpa, .eof) catch {};
            self.eof_sent = true;
        }
        for (keys.items) |k| self.handleKey(k);

        self.event_mutex.lockUncancelable(platform.io);
        std.mem.swap(std.ArrayList(agent.Event), &self.events, &self.batch);
        self.event_mutex.unlock(platform.io);
        for (self.batch.items) |e| self.handleAgentEvent(e);
        self.event_mutex.lockUncancelable(platform.io);
        self.batch.clearRetainingCapacity();
        if (self.events.items.len == 0) {
            _ = self.qarena.reset(.retain_capacity);
            self.q = self.qarena.allocator();
        }
        self.event_mutex.unlock(platform.io);

        if (self.model_thread) |t| {
            if (self.model_ready.load(.acquire)) {
                t.join();
                self.model_thread = null;
                if (self.command_active) {
                    if (self.model_ok.load(.seq_cst)) {
                        self.openModelsPrompt();
                    } else {
                        self.command_active = false;
                        self.fail("! cannot load models", .{});
                    }
                }
                self.dirty = true;
            }
        }

        if (self.turn_done.load(.seq_cst) and self.active) {
            self.active = false;
            self.paused = false;
            self.aborting = false;
            self.phase = .idle;
            self.dirty = true;
        }

        if (resize_flag.swap(false, .seq_cst)) {
            self.term.refreshSize();
            self.dirty = true;
        }
        if (exit_flag.swap(false, .seq_cst)) self.exit();

        const now = time.nowMs();
        if (self.active and now - self.last_frame_ms >= SPINNER_MS) {
            self.frame += 1;
            self.last_frame_ms = now;
            self.dirty = true;
        }

        if (self.dirty) {
            self.draw();
            self.dirty = false;
        }
        std.Io.sleep(platform.io, .{ .nanoseconds = 8 * std.time.ns_per_ms }, .boot) catch {};
    }
    const sig = exit_signal.load(.seq_cst);
    if (sig != 0) platform.reRaise(@fromBackingInt(@intCast(sig)));
}
