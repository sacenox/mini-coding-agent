const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(std.builtin.OptimizeMode, "optimize", "Optimization mode") orelse .small;

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
    exe.root_module.link_libc = true;

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run mini");
    run_step.dependOn(&run_cmd.step);
}
