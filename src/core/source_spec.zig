const std = @import("std");

pub const SourceError = error{
    InvalidSpec,
    InvalidSelector,
    InvalidOwner,
    InvalidProject,
};

pub const RepoSpec = struct {
    owner: []const u8,
    project: []const u8,
    normalized: []const u8,

    pub fn deinit(self: RepoSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.owner);
        allocator.free(self.project);
        allocator.free(self.normalized);
    }
};

pub const Selector = union(enum) {
    project: []const u8,
    repo: struct {
        owner: []const u8,
        project: []const u8,
    },

    pub fn deinit(self: Selector, allocator: std.mem.Allocator) void {
        switch (self) {
            .project => |project| allocator.free(project),
            .repo => |repo| {
                allocator.free(repo.owner);
                allocator.free(repo.project);
            },
        }
    }

    pub fn projectName(self: Selector) []const u8 {
        return switch (self) {
            .project => |project| project,
            .repo => |repo| repo.project,
        };
    }
};

pub fn parseRepoSpec(allocator: std.mem.Allocator, input: []const u8) !RepoSpec {
    const at_index = std.mem.indexOfScalar(u8, input, '@') orelse return SourceError.InvalidSpec;
    if (std.mem.indexOfScalarPos(u8, input, at_index + 1, '@') != null) return SourceError.InvalidSpec;

    const owner = input[0..at_index];
    const project = input[at_index + 1 ..];
    try validateOwner(owner);
    try validateProject(project);

    const owner_copy = try allocator.dupe(u8, owner);
    errdefer allocator.free(owner_copy);
    const project_copy = try allocator.dupe(u8, project);
    errdefer allocator.free(project_copy);
    const normalized = try normalizedGithubUrl(allocator, owner, project);

    return .{
        .owner = owner_copy,
        .project = project_copy,
        .normalized = normalized,
    };
}

pub fn parseSelector(allocator: std.mem.Allocator, input: []const u8) !Selector {
    if (std.mem.indexOfScalar(u8, input, '@')) |at_index| {
        if (std.mem.indexOfScalarPos(u8, input, at_index + 1, '@') != null) return SourceError.InvalidSelector;
        const owner = input[0..at_index];
        const project = input[at_index + 1 ..];
        try validateOwner(owner);
        try validateProject(project);

        const owner_copy = try allocator.dupe(u8, owner);
        errdefer allocator.free(owner_copy);
        const project_copy = try allocator.dupe(u8, project);
        return .{ .repo = .{ .owner = owner_copy, .project = project_copy } };
    }

    try validateProject(input);
    return .{ .project = try allocator.dupe(u8, input) };
}

pub fn normalizedGithubUrl(allocator: std.mem.Allocator, owner: []const u8, project: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "https://github.com/{s}/{s}.git", .{ owner, project });
}

pub fn validateOwner(owner: []const u8) !void {
    if (isBadPathPart(owner)) return SourceError.InvalidOwner;
}

pub fn validateProject(project: []const u8) !void {
    if (isBadPathPart(project)) return SourceError.InvalidProject;
}

fn isBadPathPart(value: []const u8) bool {
    if (value.len == 0) return true;
    if (std.mem.eql(u8, value, ".") or std.mem.eql(u8, value, "..")) return true;
    return std.mem.indexOfAny(u8, value, "/\\") != null;
}

pub fn sourceHashHex(input: []const u8) [12]u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    var out: [12]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (digest[0..6], 0..) |byte, i| {
        out[i * 2] = alphabet[byte >> 4];
        out[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return out;
}

test "parse repo spec owner project" {
    const allocator = std.testing.allocator;
    const spec = try parseRepoSpec(allocator, "owner@project");
    defer spec.deinit(allocator);
    try std.testing.expectEqualStrings("owner", spec.owner);
    try std.testing.expectEqualStrings("project", spec.project);
    try std.testing.expectEqualStrings("https://github.com/owner/project.git", spec.normalized);
}

test "parse selector project and repo" {
    const allocator = std.testing.allocator;
    const one = try parseSelector(allocator, "project");
    defer one.deinit(allocator);
    try std.testing.expect(one == .project);
    try std.testing.expectEqualStrings("project", one.project);

    const two = try parseSelector(allocator, "owner@project");
    defer two.deinit(allocator);
    try std.testing.expect(two == .repo);
    try std.testing.expectEqualStrings("owner", two.repo.owner);
    try std.testing.expectEqualStrings("project", two.repo.project);
}

test "reject invalid project path segment" {
    try std.testing.expectError(SourceError.InvalidProject, validateProject(""));
    try std.testing.expectError(SourceError.InvalidProject, validateProject(".."));
    try std.testing.expectError(SourceError.InvalidProject, validateProject("bad/name"));
}
