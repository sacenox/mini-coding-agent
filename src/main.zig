const std = @import("std");
const platform = @import("platform.zig");
const config = @import("config.zig");
const prompt = @import("prompt.zig");
const models = @import("models.zig");
const session = @import("session.zig");
const types = @import("types.zig");
const agent = @import("agent.zig");
const tools = @import("tools/index.zig");
const tui = @import("tui/tui.zig");
const term = @import("tui/term.zig");
const headless = @import("headless.zig");

pub const panic = std.debug.FullPanic(panicRestore);

fn panicRestore(msg: []const u8, ra: ?usize) noreturn {
    term.restore();
    std.debug.defaultPanic(msg, ra);
}

pub const debug = struct {
    pub fn handleSegfault(addr: ?usize, name: []const u8, ctx: ?std.debug.CpuContextPtr) noreturn {
        term.restore();
        std.debug.defaultHandleSegfault(addr, name, ctx);
    }
};

var cancel = std.atomic.Value(bool).init(false);

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

    const supports_images = if (model_ptr) |m| m.supports_images else false;
    const built = try prompt.buildSystemPrompt(a, &cfg);
    const opts = agent.Options{
        .a = a,
        .model = model_ptr,
        .system_prompt = built.prompt,
        .loaded = .{ .agent_files = built.loaded.agent_files, .skills = built.loaded.skills },
        .tools_json = tools.json(a, cfg.tools, supports_images),
        .supports_images = supports_images,
        .session = &sess,
        .cancel = &cancel,
        .config = &cfg,
    };

    if (args.print) |print_text| {
        if (model_ptr == null) {
            platform.printErr("[error] no model configured; add \"provider\" and \"model\" to {s}\n", .{config.configPath(a)});
            return 1;
        }
        return headless.run(a, print_text, opts);
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
