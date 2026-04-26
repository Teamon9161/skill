const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{});
    const clap_module = clap.module("clap");
    const toml_dep = b.dependency("toml", .{ .target = target, .optimize = optimize });
    const toml_module = toml_dep.module("toml");
    const version = b.option([]const u8, "version", "Version string embedded in the binary") orelse "0.1.0";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "default_config", @embedFile("config/defaults.toml"));
    options.addOption([]const u8, "install_sh", @embedFile("install.sh"));
    options.addOption([]const u8, "install_ps1", @embedFile("install.ps1"));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("clap", clap_module);
    exe_module.addImport("toml", toml_module);
    exe_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "skill",
        .root_module = exe_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the skill CLI");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("clap", clap_module);
    test_module.addImport("toml", toml_module);
    test_module.addOptions("build_options", options);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
