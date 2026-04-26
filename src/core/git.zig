const std = @import("std");

pub fn check(allocator: std.mem.Allocator, io: std.Io) !void {
    var result = try run(allocator, io, &.{ "git", "--version" }, null);
    result.deinit(allocator);
}

pub fn clone(allocator: std.mem.Allocator, io: std.Io, url: []const u8, dest: []const u8) !void {
    var result = try run(allocator, io, &.{ "git", "clone", "--depth=1", "--single-branch", url, dest }, null);
    result.deinit(allocator);
}

pub fn cloneAny(
    allocator: std.mem.Allocator,
    io: std.Io,
    urls: []const []const u8,
    dest: []const u8,
    timeout_seconds: u32,
) ![]const u8 {
    if (urls.len == 0) return error.GitFailed;

    for (urls) |url| {
        if (!try canAccess(allocator, io, url, timeout_seconds)) continue;

        cloneWithTimeout(allocator, io, url, urls, dest, timeout_seconds) catch |err| switch (err) {
            error.GitFailed => {
                cleanupFailedClone(io, dest);
                continue;
            },
            else => return err,
        };
        return allocator.dupe(u8, url);
    }

    return error.GitFailed;
}

pub fn update(allocator: std.mem.Allocator, io: std.Io, repo: []const u8, branch: []const u8) !void {
    const ref = if (branch.len == 0) "HEAD" else branch;
    var fetch = try run(allocator, io, &.{ "git", "fetch", "--depth=1", "origin", ref }, repo);
    fetch.deinit(allocator);
    var reset = try run(allocator, io, &.{ "git", "reset", "--hard", "FETCH_HEAD" }, repo);
    reset.deinit(allocator);
    try updateSubmodules(allocator, io, repo, 0, "", &.{});
}

pub fn updateAny(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    branch: []const u8,
    urls: []const []const u8,
    timeout_seconds: u32,
) ![]const u8 {
    if (urls.len == 0) {
        try update(allocator, io, repo, branch);
        return allocator.dupe(u8, "");
    }

    const ref = if (branch.len == 0) "HEAD" else branch;
    for (urls) |url| {
        if (!try canAccess(allocator, io, url, timeout_seconds)) continue;

        var fetch = fetchUrl(allocator, io, repo, url, ref, timeout_seconds) catch |err| switch (err) {
            error.GitFailed => continue,
            else => return err,
        };
        fetch.deinit(allocator);

        var reset = try run(allocator, io, &.{ "git", "reset", "--hard", "FETCH_HEAD" }, repo);
        reset.deinit(allocator);
        var set_url = try run(allocator, io, &.{ "git", "remote", "set-url", "origin", url }, repo);
        set_url.deinit(allocator);
        try updateSubmodules(allocator, io, repo, timeout_seconds, url, urls);
        return allocator.dupe(u8, url);
    }

    return error.GitFailed;
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

fn canAccess(allocator: std.mem.Allocator, io: std.Io, url: []const u8, timeout_seconds: u32) !bool {
    var timeout_buf: [32]u8 = undefined;
    const timeout = try timeoutArg(&timeout_buf, timeout_seconds);

    var result = runQuiet(allocator, io, &.{
        "git",
        "-c",
        "http.lowSpeedLimit=1",
        "-c",
        timeout,
        "ls-remote",
        "--exit-code",
        url,
        "HEAD",
    }, null) catch |err| switch (err) {
        error.GitFailed => return false,
        else => return err,
    };
    result.deinit(allocator);
    return true;
}

fn cloneWithTimeout(
    allocator: std.mem.Allocator,
    io: std.Io,
    url: []const u8,
    candidate_urls: []const []const u8,
    dest: []const u8,
    timeout_seconds: u32,
) !void {
    var timeout_buf: [32]u8 = undefined;
    const timeout = try timeoutArg(&timeout_buf, timeout_seconds);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var owned_args: std.ArrayList([]const u8) = .empty;
    defer {
        freeStringList(allocator, owned_args.items);
        owned_args.deinit(allocator);
    }

    try appendGitCommonArgs(&args, allocator, timeout);
    try appendUrlRewriteArgs(allocator, &args, &owned_args, url, candidate_urls);
    try args.appendSlice(allocator, &.{
        "clone",
        "--depth=1",
        "--single-branch",
        "--recurse-submodules",
        "--shallow-submodules",
        url,
        dest,
    });

    var result = try run(allocator, io, args.items, null);
    result.deinit(allocator);
}

fn fetchUrl(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    url: []const u8,
    ref: []const u8,
    timeout_seconds: u32,
) !RunResult {
    var timeout_buf: [32]u8 = undefined;
    const timeout = try timeoutArg(&timeout_buf, timeout_seconds);

    return run(allocator, io, &.{
        "git",
        "-c",
        "http.lowSpeedLimit=1",
        "-c",
        timeout,
        "fetch",
        "--depth=1",
        url,
        ref,
    }, repo);
}

fn timeoutArg(buf: []u8, timeout_seconds: u32) ![]const u8 {
    const seconds = if (timeout_seconds == 0) 1 else timeout_seconds;
    return std.fmt.bufPrint(buf, "http.lowSpeedTime={d}", .{seconds});
}

fn updateSubmodules(
    allocator: std.mem.Allocator,
    io: std.Io,
    repo: []const u8,
    timeout_seconds: u32,
    selected_url: []const u8,
    candidate_urls: []const []const u8,
) !void {
    if (!try hasGitmodules(io, repo)) return;

    var timeout_buf: [32]u8 = undefined;
    const timeout = try timeoutArg(&timeout_buf, timeout_seconds);

    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(allocator);
    var owned_args: std.ArrayList([]const u8) = .empty;
    defer {
        freeStringList(allocator, owned_args.items);
        owned_args.deinit(allocator);
    }

    try appendGitCommonArgs(&args, allocator, timeout);
    try appendUrlRewriteArgs(allocator, &args, &owned_args, selected_url, candidate_urls);
    try args.appendSlice(allocator, &.{
        "submodule",
        "update",
        "--init",
        "--recursive",
        "--depth=1",
    });

    var update_result = try run(allocator, io, args.items, repo);
    update_result.deinit(allocator);
}

fn appendGitCommonArgs(args: *std.ArrayList([]const u8), allocator: std.mem.Allocator, timeout: []const u8) !void {
    try args.appendSlice(allocator, &.{ "git", "-c", "http.lowSpeedLimit=1", "-c", timeout });
}

fn appendUrlRewriteArgs(
    allocator: std.mem.Allocator,
    args: *std.ArrayList([]const u8),
    owned_args: *std.ArrayList([]const u8),
    selected_url: []const u8,
    candidate_urls: []const []const u8,
) !void {
    const selected_base = urlParentPrefix(selected_url) orelse return;
    for (candidate_urls) |candidate_url| {
        const candidate_base = urlParentPrefix(candidate_url) orelse continue;
        if (std.mem.eql(u8, candidate_base, selected_base)) continue;

        const rewrite = try std.fmt.allocPrint(allocator, "url.{s}.insteadOf={s}", .{ selected_base, candidate_base });
        try owned_args.append(allocator, rewrite);
        try args.appendSlice(allocator, &.{ "-c", rewrite });
    }
}

fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    for (list) |item| allocator.free(item);
}

fn urlParentPrefix(url: []const u8) ?[]const u8 {
    const end = std.mem.lastIndexOfScalar(u8, url, '/') orelse return null;
    return url[0 .. end + 1];
}

fn hasGitmodules(io: std.Io, repo: []const u8) !bool {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}{c}.gitmodules", .{ repo, std.fs.path.sep });
    std.Io.Dir.accessAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn run(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !RunResult {
    return runImpl(allocator, io, argv, cwd, false);
}

fn runQuiet(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8) !RunResult {
    return runImpl(allocator, io, argv, cwd, true);
}

fn runImpl(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: ?[]const u8, quiet: bool) !RunResult {
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

    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        if (!quiet and result.stderr.len > 0) {
            std.Io.File.writeStreamingAll(.stderr(), io, result.stderr) catch {};
        }
        return error.GitFailed;
    }

    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

fn trimDup(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    return allocator.dupe(u8, std.mem.trim(u8, bytes, "\r\n \t"));
}

fn cleanupFailedClone(io: std.Io, dest: []const u8) void {
    std.Io.Dir.deleteTree(.cwd(), io, dest) catch {};
}
