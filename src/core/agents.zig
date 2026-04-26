const std = @import("std");
const config = @import("config.zig");

pub const Agent = struct {
    id: []const u8,
    base: []const u8,
    skills: []const u8,

    pub fn deinit(self: Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        allocator.free(self.skills);
    }
};

pub const Candidate = struct {
    id: []const u8,
    label: []const u8,
    base: []const u8,
    skills: []const u8,
    exists: bool,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        allocator.free(self.skills);
    }
};

pub const AgentFilter = struct {
    ids: []const []const u8 = &.{},
    scope: Scope = .global,

    pub fn deinit(self: AgentFilter, allocator: std.mem.Allocator) void {
        for (self.ids) |id| allocator.free(id);
        allocator.free(self.ids);
    }

    pub fn matches(self: AgentFilter, id: []const u8) bool {
        if (self.ids.len == 0) return true;
        for (self.ids) |selected| {
            if (std.mem.eql(u8, selected, id)) return true;
        }
        return false;
    }

    pub fn hasAny(self: AgentFilter) bool {
        return self.ids.len != 0;
    }
};

pub const Scope = enum { global, local };

pub fn detect(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    cwd: []const u8,
    defs: []const config.AgentDef,
    filter: AgentFilter,
) ![]Agent {
    var list: std.ArrayList(Agent) = .empty;
    errdefer {
        for (list.items) |agent| agent.deinit(allocator);
        list.deinit(allocator);
    }

    for (defs) |def| {
        try maybeAdd(allocator, io, &list, home, cwd, def, filter);
    }

    return list.toOwnedSlice(allocator);
}

pub fn candidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    cwd: []const u8,
    defs: []const config.AgentDef,
    scope: Scope,
) ![]Candidate {
    var list: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (list.items) |candidate| candidate.deinit(allocator);
        list.deinit(allocator);
    }

    for (defs) |def| {
        try addCandidate(allocator, io, &list, home, cwd, def, scope);
    }
    return list.toOwnedSlice(allocator);
}

pub fn deinitCandidates(allocator: std.mem.Allocator, list: []Candidate) void {
    for (list) |candidate| candidate.deinit(allocator);
    allocator.free(list);
}

pub fn fromCandidates(
    allocator: std.mem.Allocator,
    candidate_list: []const Candidate,
    selected: []const bool,
) ![]Agent {
    var list: std.ArrayList(Agent) = .empty;
    errdefer {
        for (list.items) |agent| agent.deinit(allocator);
        list.deinit(allocator);
    }

    for (candidate_list, 0..) |candidate, i| {
        if (!selected[i]) continue;
        try list.append(allocator, .{
            .id = candidate.id,
            .base = try allocator.dupe(u8, candidate.base),
            .skills = try allocator.dupe(u8, candidate.skills),
        });
    }

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
    cwd: []const u8,
    def: config.AgentDef,
    filter: AgentFilter,
) !void {
    if (!filter.matches(def.id)) return;

    const base = try agentBase(allocator, scopeRoot(home, cwd, filter.scope), def.dir);
    errdefer allocator.free(base);
    std.Io.Dir.accessAbsolute(io, base, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(base);
            return;
        },
        else => return err,
    };

    const skills = try agentSkills(allocator, base, def.skills);
    errdefer allocator.free(skills);
    try list.append(allocator, .{ .id = def.id, .base = base, .skills = skills });
}

fn addCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayList(Candidate),
    home: []const u8,
    cwd: []const u8,
    def: config.AgentDef,
    scope: Scope,
) !void {
    const base = try agentBase(allocator, scopeRoot(home, cwd, scope), def.dir);
    errdefer allocator.free(base);
    const exists = blk: {
        std.Io.Dir.accessAbsolute(io, base, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    const skills = try agentSkills(allocator, base, def.skills);
    errdefer allocator.free(skills);
    try list.append(allocator, .{ .id = def.id, .label = def.label, .base = base, .skills = skills, .exists = exists });
}

fn scopeRoot(home: []const u8, cwd: []const u8, scope: Scope) []const u8 {
    return switch (scope) {
        .global => home,
        .local => cwd,
    };
}

fn agentBase(allocator: std.mem.Allocator, home: []const u8, dir: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(dir)) return allocator.dupe(u8, dir);
    return std.fs.path.join(allocator, &.{ home, dir });
}

fn agentSkills(allocator: std.mem.Allocator, base: []const u8, skills: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(skills)) return allocator.dupe(u8, skills);
    return std.fs.path.join(allocator, &.{ base, skills });
}
