const std = @import("std");
const source_spec = @import("source_spec.zig");

pub const Paths = struct {
    home: []const u8,
    root: []const u8,
    manifest: []const u8,
    repos: []const u8,

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.home);
        allocator.free(self.root);
        allocator.free(self.manifest);
        allocator.free(self.repos);
    }
};

pub fn init(allocator: std.mem.Allocator, env: std.process.Environ) !Paths {
    const home = try env.getAlloc(allocator, "HOME");
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

    return .{
        .home = home,
        .root = root,
        .manifest = manifest,
        .repos = repos,
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
    };
    const repo = try repoPath(allocator, p, "owner", "project", "https://github.com/owner/project.git");
    defer allocator.free(repo);
    try std.testing.expect(std.mem.startsWith(u8, repo, "/tmp/skill/repos/owner@project-"));
}
