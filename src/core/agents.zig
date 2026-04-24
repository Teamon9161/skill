const std = @import("std");

pub const Agent = struct {
    id: []const u8,
    base: []const u8,
    skills: []const u8,

    pub fn deinit(self: Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        allocator.free(self.skills);
    }
};

pub const AgentFilter = struct {
    claude: bool = false,
    codex: bool = false,

    pub fn addFlag(self: *AgentFilter, flag: []const u8) !void {
        if (std.mem.eql(u8, flag, "--claude")) {
            self.claude = true;
        } else if (std.mem.eql(u8, flag, "--codex")) {
            self.codex = true;
        } else {
            return error.InvalidAgentFlag;
        }
    }

    pub fn matches(self: AgentFilter, id: []const u8) bool {
        if (!self.claude and !self.codex) return true;
        if (self.claude and std.mem.eql(u8, id, "claude")) return true;
        if (self.codex and std.mem.eql(u8, id, "codex")) return true;
        return false;
    }
};

pub fn detect(allocator: std.mem.Allocator, io: std.Io, home: []const u8, filter: AgentFilter) ![]Agent {
    var list: std.ArrayList(Agent) = .empty;
    errdefer {
        for (list.items) |agent| agent.deinit(allocator);
        list.deinit(allocator);
    }

    try maybeAdd(allocator, io, &list, home, "claude", ".claude", filter);
    try maybeAdd(allocator, io, &list, home, "codex", ".codex", filter);

    return list.toOwnedSlice(allocator);
}

pub fn deinitList(allocator: std.mem.Allocator, list: []Agent) void {
    for (list) |agent| agent.deinit(allocator);
    allocator.free(list);
}

fn maybeAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayList(Agent),
    home: []const u8,
    id: []const u8,
    dir_name: []const u8,
    filter: AgentFilter,
) !void {
    if (!filter.matches(id)) return;

    const base = try std.fs.path.join(allocator, &.{ home, dir_name });
    errdefer allocator.free(base);
    std.Io.Dir.accessAbsolute(io, base, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };

    const skills = try std.fs.path.join(allocator, &.{ base, "skills" });
    errdefer allocator.free(skills);
    try list.append(allocator, .{ .id = id, .base = base, .skills = skills });
}
