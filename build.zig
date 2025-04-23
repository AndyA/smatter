const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const smatter_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const smatter = b.addExecutable(.{
        .name = "smatter",
        .root_module = smatter_mod,
    });

    const zig_cli = b.dependency("cli", .{
        .target = target,
        .optimize = optimize,
    });

    smatter.root_module.addImport("zig-cli", zig_cli.module("zig-cli"));

    b.installArtifact(smatter);

    const smatter_cmd = b.addRunArtifact(smatter);
    smatter_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| smatter_cmd.addArgs(args);

    const smatter_step = b.step("run", "Run smatter");
    smatter_step.dependOn(&smatter_cmd.step);

    const smatter_unit_tests = b.addTest(.{
        .root_module = smatter_mod,
    });

    const run_smatter_unit_tests = b.addRunArtifact(smatter_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_smatter_unit_tests.step);
}
