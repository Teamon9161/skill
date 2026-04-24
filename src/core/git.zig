const std = @import("std");

pub fn check(allocator: std.mem.Allocator, io: std.Io) !void {
    var result = try run(allocator, io, &.{ "git", "--version" }, null);
    result.deinit(allocator);
}

pub fn clone(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8) !void {
    var result = try run(allocator, io, &.{ "git", "clone", "--depth=1", "--single-branch", url, dest }, null);
    result.deinit(allocator);
}

pub fn update(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, branch: []const u8) !void {
    const ref = if (branch.len == 0) "HEAD" else branch;
    var fetch = try run(allocator, io, &.{ "git", "fetch", "--depth=1", "origin", ref }, repo);
    fetch.deinit(allocator);
    var reset = try run(allocator, io, &.{ "git", "reset", "--hard", "FETCH_HEAD" }, repo);
    reset.deinit(allocator);
}

pub fn currentBranch(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) ![]const u8 {
    var result = try run(allocator, io, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, repo);
    defer result.deinit(allocator);
    return trimDup(allocator, result.stdout);
}

pub fn currentCommit(allocator: std.mem.Allocator, io: std.Io, repo: []const u8) ![]const u8 {
    var result = try run(allocator, io, &.{ "git", "rev-parse", "HEAD" }, repo);
    defer result.deinit(allocator);
    return trimDup(allocator, result.stdout);
}

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !RunResult {
    const child_cwd: std.process.Child.Cwd = if (cwd) |path| .{ .path = path } else .inherit;
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = child_cwd,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) return error.GitFailed,
        else => return error.GitFailed,
    }

    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

fn trimDup(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return allocator.dupe(u8, std.mem.trim(u8, bytes, "\r\n \t"));
}
