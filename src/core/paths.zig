const std = @import("std");
const source_spec = @import("source_spec.zig");

pub const Paths = struct {
    home: []const u8,
    root: []const u8,
    manifest: []const u8,
    repos: []const u8,
    config: []const u8,
    sources: []const u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.home);
        allocator.free(self.root);
        allocator.free(self.manifest);
        allocator.free(self.repos);
        allocator.free(self.config);
        allocator.free(self.sources);
    }
};

pub fn init(allocator: std.mem.Allocator, env: std.process.Environ) !Paths {
    const home = try homePath(allocator, env);
    errdefer allocator.free(home);

    const root = env.getAlloc(allocator, "SKILL_HOME") catch |err| switch (err) {
        error.EnvironmentVariableMissing => blk: {
            const xdg = env.getAlloc(allocator, "XDG_DATA_HOME") catch |xdg_err| switch (xdg_err) {
                error.EnvironmentVariableMissing => break :blk try std.fs.path.join(allocator, &.{ home, ".local", "share", "skill" }),
                else => return xdg_err,
            };
            defer allocator.free(xdg);
            break :blk try std.fs.path.join(allocator, &.{ xdg, "skill" });
        },
        else => return err,
    };
    errdefer allocator.free(root);

    const manifest = try std.fs.path.join(allocator, &.{ root, "manifest.json" });
    errdefer allocator.free(manifest);
    const repos = try std.fs.path.join(allocator, &.{ root, "repos" });
    errdefer allocator.free(repos);
    const config = try std.fs.path.join(allocator, &.{ root, "config.toml" });
    errdefer allocator.free(config);
    const sources = try std.fs.path.join(allocator, &.{ root, "sources.toml" });
    errdefer allocator.free(sources);

    return .{
        .home = home,
        .root = root,
        .manifest = manifest,
        .repos = repos,
        .config = config,
        .sources = sources,
    };
}

fn homePath(allocator: std.mem.Allocator, env: std.process.Environ) ![]const u8 {
    if (try envGetAllocOrNull(allocator, env, "HOME")) |home| return home;
    if (try envGetAllocOrNull(allocator, env, "USERPROFILE")) |profile| return profile;

    const drive = try envGetAllocOrNull(allocator, env, "HOMEDRIVE");
    defer if (drive) |value| allocator.free(value);

    const path = try envGetAllocOrNull(allocator, env, "HOMEPATH");
    defer if (path) |value| allocator.free(value);

    if (drive) |drive_value| {
        if (path) |path_value| {
            return std.fmt.allocPrint(allocator, "{s}{s}", .{ drive_value, path_value });
        }
    }

    return error.EnvironmentVariableMissing;
}

fn envGetAllocOrNull(allocator: std.mem.Allocator, env: std.process.Environ, name: []const u8) !?[]const u8 {
    return env.getAlloc(allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
}

pub fn repoPath(allocator: std.mem.Allocator, paths: Paths, owner: []const u8, project: []const u8, normalized: []const u8) ![]const u8 {
    const hash = source_spec.sourceHashHex(normalized);
    const dir_name = try std.fmt.allocPrint(allocator, "{s}@{s}-{s}", .{ owner, project, hash });
    defer allocator.free(dir_name);
    return std.fs.path.join(allocator, &.{ paths.repos, dir_name });
}

pub fn child(allocator: std.mem.Allocator, parent: []const u8, name: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ parent, name });
}

pub fn cwdAlloc(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dir = try std.Io.Dir.openDir(.cwd(), io, ".", .{});
    defer dir.close(io);
    const len = try dir.realPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

pub fn isInside(parent: []const u8, child_path: []const u8) bool {
    if (!std.mem.startsWith(u8, child_path, parent)) return false;
    if (child_path.len == parent.len) return false;
    return child_path[parent.len] == std.fs.path.sep;
}

test "storage path includes project and hash" {
    const allocator = std.testing.allocator;
    const p = Paths{
        .home = "/tmp/home",
        .root = "/tmp/skill",
        .manifest = "/tmp/skill/manifest.json",
        .repos = "/tmp/skill/repos",
        .config = "/tmp/skill/config.toml",
        .sources = "/tmp/skill/sources.toml",
    };
    const repo = try repoPath(allocator, p, "owner", "project", "https://github.com/owner/project.git");
    defer allocator.free(repo);
    const dir_name = std.fs.path.basename(repo);
    try std.testing.expect(std.mem.startsWith(u8, dir_name, "owner@project-"));
}
