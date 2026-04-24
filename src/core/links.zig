const std = @import("std");
const builtin = @import("builtin");
const agents = @import("agents.zig");
const manifest = @import("manifest.zig");
const paths = @import("paths.zig");

pub fn createForAgents(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_list: []const agents.Agent,
    project: []const u8,
    target: []const u8,
) ![]manifest.Link {
    var out: std.ArrayList(manifest.Link) = .empty;
    errdefer {
        for (out.items) |link| link.deinit(allocator);
        out.deinit(allocator);
    }

    for (agent_list) |agent| {
        try std.Io.Dir.createDirPath(.cwd(), io, agent.skills);
        const link_path = try paths.child(allocator, agent.skills, project);
        defer allocator.free(link_path);
        try ensureLink(allocator, io, link_path, target);
        try out.append(allocator, try manifest.newLink(allocator, agent.id, link_path, target));
    }

    return out.toOwnedSlice(allocator);
}

pub fn removeRecorded(io: std.Io, recorded: []const manifest.Link) !void {
    for (recorded) |link| {
        try removeIfMatches(io, link.path, link.target);
    }
}

pub fn removeForAgents(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_list: []const agents.Agent,
    project: []const u8,
    target: []const u8,
) !void {
    for (agent_list) |agent| {
        const link_path = try paths.child(allocator, agent.skills, project);
        defer allocator.free(link_path);
        try removeIfMatches(io, link_path, target);
    }
}

fn ensureLink(allocator: std.mem.Allocator, io: std.Io, link_path: []const u8, target: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buf) catch |err| switch (err) {
        error.FileNotFound => {
            try createDirectoryLink(allocator, io, link_path, target);
            return;
        },
        error.NotLink => {
            try replaceEmptyDirectoryWithLink(allocator, io, link_path, target);
            return;
        },
        else => return err,
    };

    if (!std.mem.eql(u8, buf[0..len], target)) return error.LinkConflict;
}

fn createDirectoryLink(allocator: std.mem.Allocator, io: std.Io, link_path: []const u8, target: []const u8) !void {
    if (builtin.os.tag == .windows) {
        std.Io.Dir.symLinkAbsolute(io, target, link_path, .{ .is_directory = true }) catch |err| switch (err) {
            error.AccessDenied, error.PermissionDenied => {
                cleanupFailedSymlinkDir(io, link_path) catch {};
                return createJunction(allocator, io, link_path, target);
            },
            else => return err,
        };
        return;
    }

    try std.Io.Dir.symLinkAbsolute(io, target, link_path, .{ .is_directory = true });
}

fn replaceEmptyDirectoryWithLink(allocator: std.mem.Allocator, io: std.Io, link_path: []const u8, target: []const u8) !void {
    std.Io.Dir.deleteDirAbsolute(io, link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        error.DirNotEmpty, error.NotDir => return error.LinkConflict,
        else => return err,
    };
    try createDirectoryLink(allocator, io, link_path, target);
}

fn cleanupFailedSymlinkDir(io: std.Io, link_path: []const u8) !void {
    std.Io.Dir.deleteDirAbsolute(io, link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn createJunction(allocator: std.mem.Allocator, io: std.Io, link_path: []const u8, target: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link_path, target },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) return error.LinkCreateFailed,
        else => return error.LinkCreateFailed,
    }
}

fn removeIfMatches(io: std.Io, link_path: []const u8, target: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buf) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotLink => return error.LinkConflict,
        else => return err,
    };

    if (!std.mem.eql(u8, buf[0..len], target)) return error.LinkConflict;
    try deleteLinkPath(io, link_path);
}

fn deleteLinkPath(io: std.Io, link_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, link_path) catch |err| switch (err) {
        error.IsDir => try std.Io.Dir.deleteDirAbsolute(io, link_path),
        else => return err,
    };
}
