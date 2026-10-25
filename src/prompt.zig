const std = @import("std");
const platform = @import("platform.zig");
const filesystem = @import("filesystem.zig");
const config = @import("config.zig");
const text = @import("text.zig");

const Skill = struct { name: []const u8, description: []const u8, path: []const u8 };

const Frontmatter = struct { name: ?[]const u8 = null, description: ?[]const u8 = null };

fn frontmatter(raw: []const u8) Frontmatter {
    var out = Frontmatter{};
    if (!std.mem.startsWith(u8, raw, "---")) return out;
    const rest = raw[3..];
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
        for (filesystem.listDir(a, root) catch continue) |entry| {
            const path = filesystem.join(a, &.{ root, entry, "SKILL.md" }) catch continue;
            if (!filesystem.fileExists(path)) continue;
            const content = filesystem.readFileAlloc(a, path, 1 << 20) catch continue;
            const meta = frontmatter(content);
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
        const agents = filesystem.join(a, &.{ h, ".agents" }) catch "";
        if (agents.len > 0) try roots.append(a, agents);
    }
    const cwd = try std.process.currentPathAlloc(platform.io, a);
    try roots.append(a, cwd);
    var found: std.ArrayList([]const u8) = .empty;
    var seen: std.ArrayList([]const u8) = .empty;
    for (roots.items) |root| {
        for ([_][]const u8{ "AGENTS.md", "CLAUDE.md" }) |name| {
            const path = try filesystem.join(a, &.{ root, name });
            if (!filesystem.fileExists(path)) continue;
            const real = filesystem.realPath(a, path) orelse path;
            if (contains(seen.items, real)) continue;
            try seen.append(a, real);
            try found.append(a, path);
        }
    }
    return found.items;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

pub const Loaded = struct { agent_files: usize = 0, skills: usize = 0 };

pub const Built = struct { prompt: []const u8, loaded: Loaded };

pub fn buildSystemPrompt(a: std.mem.Allocator, cfg: *const config.Config) !Built {
    var sections: std.ArrayList([]const u8) = .empty;
    var loaded: Loaded = .{};

    const configured = std.mem.trim(u8, cfg.system_prompt, " \t\r\n");
    if (configured.len > 0) try sections.append(a, configured);

    if (cfg.skills_dirs.len > 0) {
        const skills = try discoverSkills(a, cfg.skills_dirs);
        loaded.skills = skills.len;
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
        const files = try agentFiles(a);
        loaded.agent_files = files.len;
        for (files) |path| {
            const content = try filesystem.readFileAlloc(a, path, 1 << 24);
            try sections.append(a, try std.fmt.allocPrint(a, "## {s}\n\n{s}", .{
                path,
                std.mem.trim(u8, content, " \t\r\n"),
            }));
        }
    }

    return .{ .prompt = try text.join(a, sections.items, "\n\n"), .loaded = loaded };
}
