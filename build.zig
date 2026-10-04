const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "mini",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    exe.root_module.addOptions("build_options", options);

    const tree_sitter = b.dependency("tree_sitter", .{ .target = target, .optimize = optimize });
    exe.root_module.addImport("tree-sitter", tree_sitter.module("tree_sitter"));

    const js = b.dependency("tree_sitter_javascript", .{ .target = target, .optimize = optimize });
    const ts = b.dependency("tree_sitter_typescript", .{ .target = target, .optimize = optimize });
    const md = b.dependency("tree_sitter_markdown", .{ .target = target, .optimize = optimize });
    const py = b.dependency("tree_sitter_python", .{ .target = target, .optimize = optimize });
    const go = b.dependency("tree_sitter_go", .{ .target = target, .optimize = optimize });
    const zig = b.dependency("tree_sitter_zig", .{ .target = target, .optimize = optimize });

    exe.root_module.link_libc = true;
    addGrammar(exe, js, "src", &.{ "parser.c", "scanner.c" });
    addGrammar(exe, ts, "typescript/src", &.{ "parser.c", "scanner.c" });
    addGrammar(exe, ts, "tsx/src", &.{ "parser.c", "scanner.c" });
    addGrammar(exe, md, "tree-sitter-markdown/src", &.{ "parser.c", "scanner.c" });
    addGrammar(exe, md, "tree-sitter-markdown-inline/src", &.{ "parser.c", "scanner.c" });
    addGrammar(exe, py, "src", &.{ "parser.c", "scanner.c" });
    addGrammar(exe, go, "src", &.{"parser.c"});
    addGrammar(exe, zig, "src", &.{"parser.c"});

    exe.root_module.addAnonymousImport("js_highlights", .{ .root_source_file = js.path("queries/highlights.scm") });
    exe.root_module.addAnonymousImport("ts_highlights", .{ .root_source_file = ts.path("queries/highlights.scm") });
    exe.root_module.addAnonymousImport("md_highlights", .{ .root_source_file = md.path("tree-sitter-markdown/queries/highlights.scm") });
    exe.root_module.addAnonymousImport("md_inline_highlights", .{ .root_source_file = md.path("tree-sitter-markdown-inline/queries/highlights.scm") });
    exe.root_module.addAnonymousImport("md_tables", .{ .root_source_file = b.path("src/tui/markdown_tables.scm") });
    exe.root_module.addAnonymousImport("py_highlights", .{ .root_source_file = py.path("queries/highlights.scm") });
    exe.root_module.addAnonymousImport("go_highlights", .{ .root_source_file = go.path("queries/highlights.scm") });
    exe.root_module.addAnonymousImport("zig_highlights", .{ .root_source_file = zig.path("queries/highlights.scm") });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run mini");
    run_step.dependOn(&run_cmd.step);
}

fn addGrammar(exe: *std.Build.Step.Compile, dep: *std.Build.Dependency, dir: []const u8, files: []const []const u8) void {
    const root = dep.path(dir);
    exe.root_module.addIncludePath(root);
    exe.root_module.addCSourceFiles(.{
        .root = root,
        .files = files,
        .flags = &.{"-std=c11"},
    });
}
