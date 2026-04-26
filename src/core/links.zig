const std = @import("std");
const builtin = @import("builtin");
const agents = @import("agents.zig");
const manifest = @import("manifest.zig");
const paths = @import("paths.zig");

pub const CreateOptions = struct {
    prompt_conflicts: bool = true,
};

pub fn createForAgents(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_list: []const agents.Agent,
    name: []const u8,
    target: []const u8,
    options: CreateOptions,
) ![]manifest.Link {
    var out: std.ArrayList(manifest.Link) = .empty;
    errdefer {
        for (out.items) |link| link.deinit(allocator);
        out.deinit(allocator);
    }

    for (agent_list) |agent| {
        try std.Io.Dir.createDirPath(.cwd(), io, agent.skills);
        const link_path = try paths.child(allocator, agent.skills, name);
        defer allocator.free(link_path);
        const created = try ensureLink(allocator, io, agent.id, link_path, target, options);
        if (!created) continue;
        try out.append(allocator, try manifest.newLink(allocator, agent.id, link_path, target));
    }

    return out.toOwnedSlice(allocator);
}

pub fn removeRecorded(io: std.Io, recorded: []const manifest.Link) !void {
    for (recorded) |link| {
        try removeIfMatches(io, link.path, link.target);
    }
}

pub fn removeRecordedForFilter(
    io: std.Io,
    recorded: []const manifest.Link,
    filter: agents.AgentFilter,
) !void {
    for (recorded) |link| {
        if (!filter.matches(link.agent)) continue;
        try removeIfMatches(io, link.path, link.target);
    }
}

pub fn removeForAgents(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_list: []const agents.Agent,
    name: []const u8,
    target: []const u8,
) !void {
    for (agent_list) |agent| {
        const link_path = try paths.child(allocator, agent.skills, name);
        defer allocator.free(link_path);
        try removeIfMatches(io, link_path, target);
    }
}

fn ensureLink(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent_id: []const u8,
    link_path: []const u8,
    target: []const u8,
    options: CreateOptions,
) !bool {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buf) catch |err| switch (err) {
        error.FileNotFound => {
            try createDirectoryLink(allocator, io, link_path, target);
            return true;
        },
        error.NotLink => {
            if (!options.prompt_conflicts) return error.LinkConflict;
            if (!try confirmReplace(io, agent_id, link_path)) return false;
            try deleteExisting(io, link_path);
            try createDirectoryLink(allocator, io, link_path, target);
            return true;
        },
        else => return err,
    };

    if (std.mem.eql(u8, buf[0..len], target)) return true;
    if (!options.prompt_conflicts) return error.LinkConflict;
    if (!try confirmReplace(io, agent_id, link_path)) return false;
    try deleteLinkPath(io, link_path);
    try createDirectoryLink(allocator, io, link_path, target);
    return true;
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

fn cleanupFailedSymlinkDir(io: std.Io, link_path: []const u8) !void {
    std.Io.Dir.deleteDirAbsolute(io, link_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn confirmReplace(io: std.Io, agent_id: []const u8, link_path: []const u8) !bool {
    try std.Io.File.writeStreamingAll(.stdout(), io, agent_id);
    try std.Io.File.writeStreamingAll(.stdout(), io, " already has ");
    try std.Io.File.writeStreamingAll(.stdout(), io, link_path);
    try std.Io.File.writeStreamingAll(.stdout(), io, ". Replace it? [y/N] ");

    var buf: [16]u8 = undefined;
    const n = std.Io.File.readStreaming(.stdin(), io, &.{buf[0..]}) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (answer.len == 0) return false;
    return switch (std.ascii.toLower(answer[0])) {
        'y' => true,
        'n' => false,
        else => error.InvalidConfirmation,
    };
}

fn deleteExisting(io: std.Io, link_path: []const u8) !void {
    std.Io.Dir.deleteTree(.cwd(), io, link_path) catch |err| switch (err) {
        error.NotDir => try std.Io.Dir.deleteFileAbsolute(io, link_path),
        else => return err,
    };
}

fn createJunction(allocator: std.mem.Allocator, io: std.Io, link_path: []const u8, target: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "& { param($p, $t) New-Item -ItemType Junction -Path $p -Target $t | Out-Null }",
            link_path,
            target,
        },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    });
    defer {
        allocator.free(result.stdout);
        allocator.free(result.stderr);
    }

    switch (result.term) {
        .exited => |code| if (code != 0) {
            try std.Io.File.writeStreamingAll(.stderr(), io, result.stdout);
            try std.Io.File.writeStreamingAll(.stderr(), io, result.stderr);
            return error.LinkCreateFailed;
        },
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
