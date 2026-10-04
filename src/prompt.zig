//! The system prompt: the configured prompt, any discovered skills, and the
//! opted-in agent files. Nothing else is injected.

const std = @import("std");
const platform = @import("platform.zig");
const util = @import("util.zig");
const config = @import("config.zig");

const Skill = struct { name: []const u8, description: []const u8, path: []const u8 };

const Frontmatter = struct { name: ?[]const u8 = null, description: ?[]const u8 = null };

fn frontmatter(text: []const u8) Frontmatter {
    var out = Frontmatter{};
    if (!std.mem.startsWith(u8, text, "---")) return out;
    const rest = text[3..];
    const end = std.mem.indexOf(u8, rest, "\n---") orelse return out;
    var lines = std.mem.splitScalar(u8, rest[0..end], '\n');
    while (lines.next()) |line| {
        const sep = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const key = std.mem.trim(u8, line[0..sep], " \t\r");
        var value = std.mem.trim(u8, line[sep + 1 ..], " \t\r");
        value = std.mem.trim(u8, value, "\"'");
        if (std.mem.eql(u8, key, "name")) out.name = value;
        if (std.mem.eql(u8, key, "description")) out.description = value;
    }
    return out;
}

fn discoverSkills(a: std.mem.Allocator, dirs: []const []const u8) ![]Skill {
    var skills: std.ArrayList(Skill) = .empty;
    for (dirs) |root| {
        for (util.listDir(a, root)) |entry| {
            const path = util.join(a, &.{ root, entry, "SKILL.md" }) catch continue;
            if (!util.fileExists(path)) continue;
            // An unreadable skill file is skipped, not fatal.
            const text = util.readFileAlloc(a, path, 1 << 20) catch continue;
            const meta = frontmatter(text);
            const name = meta.name orelse continue;
            try skills.append(a, .{
                .name = name,
                .description = meta.description orelse "",
                .path = path,
            });
        }
    }
    return skills.items;
}

fn agentFiles(a: std.mem.Allocator) ![]const []const u8 {
    var roots: std.ArrayList([]const u8) = .empty;
    if (platform.home()) |h| {
        const agents = util.join(a, &.{ h, ".agents" }) catch "";
        if (agents.len > 0) try roots.append(a, agents);
    }
    const cwd = try std.process.currentPathAlloc(platform.io, a);
    try roots.append(a, cwd);
    var found: std.ArrayList([]const u8) = .empty;
    for (roots.items) |root| {
        for ([_][]const u8{ "AGENTS.md", "CLAUDE.md" }) |name| {
            const path = try util.join(a, &.{ root, name });
            if (util.fileExists(path)) try found.append(a, path);
        }
    }
    return found.items;
}

/// Builds the system prompt from the config. The result lives for the process.
pub fn buildSystemPrompt(a: std.mem.Allocator, cfg: *const config.Config) ![]const u8 {
    var sections: std.ArrayList([]const u8) = .empty;

    const configured = std.mem.trim(u8, cfg.system_prompt, " \t\r\n");
    if (configured.len > 0) try sections.append(a, configured);

    if (cfg.skills_dirs.len > 0) {
        const skills = try discoverSkills(a, cfg.skills_dirs);
        if (skills.len > 0) {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(a, "## Skills\n");
            for (skills) |s| {
                try out.print(a, "\n- {s}: {s} ({s})", .{ s.name, s.description, s.path });
            }
            try sections.append(a, out.items);
        }
    }

    if (cfg.discover_agent_files) {
        for (try agentFiles(a)) |path| {
            const text = try util.readFileAlloc(a, path, 1 << 24);
            try sections.append(a, try std.fmt.allocPrint(a, "## {s}\n\n{s}", .{
                path,
                std.mem.trim(u8, text, " \t\r\n"),
            }));
        }
    }

    var joined: std.ArrayList(u8) = .empty;
    for (sections.items, 0..) |section, i| {
        if (i > 0) try joined.appendSlice(a, "\n\n");
        try joined.appendSlice(a, section);
    }
    return joined.items;
}
