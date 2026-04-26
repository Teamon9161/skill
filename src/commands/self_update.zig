const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const cli = @import("../cli.zig");

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, sub: cli.SelfCommand) !void {
    switch (sub) {
        .update => try runUpdate(allocator, io, environ),
    }
}

fn runUpdate(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) !void {
    const tmp_path = try tempPath(allocator, environ);
    defer allocator.free(tmp_path);
    defer std.Io.Dir.deleteFileAbsolute(io, tmp_path) catch {};

    const script = if (builtin.os.tag == .windows) build_options.install_ps1 else build_options.install_sh;
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = tmp_path, .data = script });

    if (builtin.os.tag == .windows) {
        try exec(allocator, io, &.{
            "powershell.exe", "-ExecutionPolicy", "Bypass", "-NonInteractive", "-File", tmp_path,
            "-CurrentVersion", build_options.version,
        });
    } else {
        try exec(allocator, io, &.{ "sh", tmp_path, build_options.version });
    }
}

fn tempPath(allocator: std.mem.Allocator, environ: std.process.Environ) ![]const u8 {
    if (builtin.os.tag == .windows) {
        const tmp_dir = environ.getAlloc(allocator, "TEMP") catch |err| switch (err) {
            error.EnvironmentVariableMissing => return std.fs.path.join(allocator, &.{ "C:\\Windows\\Temp", "skill-self-update.ps1" }),
            else => return err,
        };
        defer allocator.free(tmp_dir);
        return std.fs.path.join(allocator, &.{ tmp_dir, "skill-self-update.ps1" });
    }
    return allocator.dupe(u8, "/tmp/skill-self-update.sh");
}

fn exec(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.stdout.len > 0) try std.Io.File.writeStreamingAll(.stdout(), io, result.stdout);
    if (result.stderr.len > 0) try std.Io.File.writeStreamingAll(.stderr(), io, result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SelfUpdateFailed,
        else => return error.SelfUpdateFailed,
    }
}
