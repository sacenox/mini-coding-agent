//! mini: a fast, transparent, config-first terminal coding agent.

const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");
const config = @import("config.zig");
const prompt = @import("prompt.zig");
const models = @import("models.zig");
const session = @import("session.zig");
const types = @import("types.zig");
const agent = @import("agent.zig");
const tools = @import("tools/index.zig");
const tui = @import("tui/tui.zig");

var cancel = std.atomic.Value(bool).init(false);

fn onSignal(_: std.posix.SIG) callconv(.c) void {
    cancel.store(true, .release);
}

const ParsedArgs = struct { print: ?[]const u8 = null, config: ?[]const u8 = null };

fn parseArgs(a: std.mem.Allocator) !ParsedArgs {
    var it = std.process.Args.Iterator.init(platform.args);
    _ = it.next();
    var result = ParsedArgs{};
    while (it.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--print=")) {
            result.print = try a.dupe(u8, arg["--print=".len..]);
        } else if (std.mem.startsWith(u8, arg, "-p=")) {
            result.print = try a.dupe(u8, arg["-p=".len..]);
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--print")) {
            const value = it.next() orelse return error.MissingPrompt;
            result.print = try a.dupe(u8, value);
        } else if (std.mem.startsWith(u8, arg, "--config=")) {
            result.config = try a.dupe(u8, arg["--config=".len..]);
        } else if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--config")) {
            const value = it.next() orelse return error.MissingConfig;
            result.config = try a.dupe(u8, value);
        } else {
            platform.printErr("unknown argument: {s}\n", .{arg});
            return error.UnknownArg;
        }
    }
    return result;
}

const PrintCtx = struct {
    failed: bool = false,
    cancelled: bool = false,
    no_model: bool = false,
};

fn printEvent(ctx: *anyopaque, event: agent.Event) void {
    const pc: *PrintCtx = @ptrCast(@alignCast(ctx));
    switch (event) {
        .tool_call => |call| platform.printErr("[tool] {s}\n", .{call.name}),
        .tool_output => |chunk| platform.writeErr(chunk),
        .no_model => {
            pc.no_model = true;
            platform.printErr("[error] no model configured; add \"provider\" and \"model\" to {s}\n", .{config.configPath(platform.gpa)});
        },
        .err => |message| {
            pc.failed = true;
            platform.printErr("[error] {s}\n", .{message});
        },
        .cancelled => {
            pc.cancelled = true;
            platform.printErr("[cancelled]\n", .{});
        },
        else => {},
    }
}

fn runPrint(a: std.mem.Allocator, prompt_text: []const u8, opts: agent.Options) u8 {
    var messages: std.ArrayList(types.Message) = .empty;
    const user = types.Message{ .user = .{ .content = prompt_text, .timestamp = util.nowMs() } };
    messages.append(a, user) catch {
        platform.printErr("[error] out of memory\n", .{});
        return 1;
    };
    opts.session.appendMessage(a, user) catch |e| {
        platform.printErr("[error] {s}\n", .{@errorName(e)});
        return 1;
    };

    const act = std.posix.Sigaction{
        .handler = .{ .handler = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
    std.posix.sigaction(std.posix.SIG.TERM, &act, null);

    var pc = PrintCtx{};
    agent.runTurn(opts, &messages, agent.NO_INTERACTION, .{ .ctx = &pc, .on_event = printEvent });
    opts.session.close();

    var last: ?*types.AssistantMessage = null;
    for (messages.items) |message| {
        if (message == .assistant) last = message.assistant;
    }
    if (!pc.failed and !pc.cancelled and !pc.no_model) {
        if (last) |am| {
            const text = types.assistantText(a, am) catch {
                platform.printErr("[error] out of memory\n", .{});
                return 1;
            };
            if (text.len > 0) {
                platform.writeOut(text);
                if (text[text.len - 1] != '\n') platform.writeOut("\n");
            }
        }
    }
    return if (pc.failed or pc.cancelled or pc.no_model) 1 else 0;
}

pub fn main(init: std.process.Init) void {
    platform.setup(init);
    const code = run() catch |e| {
        platform.printErr("{s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    std.process.exit(code);
}

fn run() !u8 {
    const a = platform.gpa;

    const args = parseArgs(a) catch |e| {
        switch (e) {
            error.MissingPrompt => platform.printErr("a prompt is required\n", .{}),
            error.MissingConfig => platform.printErr("a config path is required\n", .{}),
            else => {},
        }
        return 1;
    };

    const cfg = config.load(a, args.config) catch return 1;

    var resolve_err: ?[]const u8 = null;
    const model = models.resolve(a, &cfg, &resolve_err);
    if (resolve_err) |message| {
        platform.printErr("{s}\n", .{message});
        return 1;
    }

    const cwd = std.process.currentPathAlloc(platform.io, a) catch ".";
    var sess = session.Session.init(a, cfg.sessions_dir, cwd);

    const model_ptr: ?*const types.Model = if (model) |m| blk: {
        const ptr = try a.create(types.Model);
        ptr.* = m;
        break :blk ptr;
    } else null;

    const supports_images = if (model_ptr) |m| tools.acceptsImages(m) else false;
    const tool_list = tools.schemas(a, cfg.tools, supports_images);
    const opts = agent.Options{
        .a = a,
        .model = model_ptr,
        .system_prompt = try prompt.buildSystemPrompt(a, &cfg),
        .tools_json = tools.writeArray(a, tool_list),
        .supports_images = supports_images,
        .session = &sess,
        .cancel = &cancel,
    };

    if (args.print) |print_text| {
        if (model_ptr == null) {
            platform.printErr("[error] no model configured; add \"provider\" and \"model\" to {s}\n", .{config.configPath(a)});
            return 1;
        }
        return runPrint(a, print_text, opts);
    }

    const stdin_tty = std.Io.File.stdin().isTty(platform.io) catch false;
    const stdout_tty = std.Io.File.stdout().isTty(platform.io) catch false;
    if (!stdin_tty or !stdout_tty) {
        platform.printErr("interactive mode requires a TTY; use -p for non-interactive mode\n", .{});
        return 1;
    }
    try tui.run(opts, &cfg, cfg.tools);
    return 0;
}
