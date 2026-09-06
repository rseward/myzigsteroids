const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vgame_dep = b.dependency("vgame", .{
        .target = target,
        .optimize = optimize,
    });
    const vgame = vgame_dep.module("vgame");
    const raylib_artifact = vgame_dep.artifact("raylib");

    const exe = b.addExecutable(.{
        .name = "zigsteroids2",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.linkLibrary(raylib_artifact);
    exe.root_module.addImport("vgame", vgame);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run Zigsteroids 2");
    run_step.dependOn(&run_cmd.step);

    b.installArtifact(exe);
}