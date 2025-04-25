const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "smatter",
        .root_module = exe_mod,
    });

    const zig_cli = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zig-cli", zig_cli.module("zig-cli"));

    b.installArtifact(exe);

    const exe_cmd = b.addRunArtifact(exe);
    exe_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| exe_cmd.addArgs(args);

    const exe_step = b.step("run", "Run smatter");
    exe_step.dependOn(&exe_cmd.step);

    const unit_tests = b.addTest(.{ .root_source_file = b.path("src/test.zig") });
    const run_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
