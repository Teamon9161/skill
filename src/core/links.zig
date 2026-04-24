const std = @import("std");
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
        try ensureLink(io, link_path, target);
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

fn ensureLink(io: std.Io, link_path: []const u8, target: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buf) catch |err| switch (err) {
        error.FileNotFound => {
            try std.Io.Dir.symLinkAbsolute(io, target, link_path, .{ .is_directory = true });
            return;
        },
        error.NotLink => return error.LinkConflict,
        else => return err,
    };

    if (!std.mem.eql(u8, buf[0..len], target)) return error.LinkConflict;
}

fn removeIfMatches(io: std.Io, link_path: []const u8, target: []const u8) !void {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = std.Io.Dir.readLinkAbsolute(io, link_path, &buf) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotLink => return error.LinkConflict,
        else => return err,
    };

    if (!std.mem.eql(u8, buf[0..len], target)) return error.LinkConflict;
    try std.Io.Dir.deleteFileAbsolute(io, link_path);
}
