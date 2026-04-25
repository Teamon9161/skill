const std = @import("std");
const config = @import("config.zig");

pub const SourceError = error{
    InvalidSpec,
    InvalidSelector,
    InvalidOwner,
    InvalidProject,
    InvalidSourcePath,
    UnknownSource,
};

pub const AddSpec = union(enum) {
    remote: RemoteSpec,
    local: LocalSpec,

    pub fn deinit(self: AddSpec, allocator: std.mem.Allocator) void {
        switch (self) {
            .remote => |remote| remote.deinit(allocator),
            .local => |local| local.deinit(allocator),
        }
    }
};

pub const RemoteSpec = struct {
    source_label: []const u8,
    owner: []const u8,
    repo: []const u8,
    source_path: []const u8,
    normalized: []const u8,

    pub fn deinit(self: RemoteSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.source_label);
        allocator.free(self.owner);
        allocator.free(self.repo);
        allocator.free(self.source_path);
        allocator.free(self.normalized);
    }
};

pub const LocalSpec = struct {
    path: []const u8,

    pub fn deinit(self: LocalSpec, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }
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

pub fn parseAddSpec(allocator: std.mem.Allocator, input: []const u8, source_list: []const config.Source) !AddSpec {
    if (std.mem.indexOfScalar(u8, input, '@') == null) {
        return .{ .local = .{ .path = try allocator.dupe(u8, input) } };
    }

    const remote = try parseRemoteSpec(allocator, input, source_list);
    return .{ .remote = remote };
}

pub fn parseRemoteSpec(
    allocator: std.mem.Allocator,
    input: []const u8,
    source_list: []const config.Source,
) !RemoteSpec {
    const parts = parseRemoteParts(input, source_list) catch return SourceError.InvalidSpec;
    try validateOwner(parts.owner);
    try validateProject(parts.repo);
    try validateSourcePath(parts.source_path);

    const source = config.findSource(source_list, parts.source_label) orelse return SourceError.UnknownSource;

    const label_copy = try allocator.dupe(u8, parts.source_label);
    errdefer allocator.free(label_copy);
    const owner_copy = try allocator.dupe(u8, parts.owner);
    errdefer allocator.free(owner_copy);
    const repo_copy = try allocator.dupe(u8, parts.repo);
    errdefer allocator.free(repo_copy);
    const source_path_copy = try allocator.dupe(u8, parts.source_path);
    errdefer allocator.free(source_path_copy);
    const normalized = try config.expandUrl(allocator, source, parts.owner, parts.repo);

    return .{
        .source_label = label_copy,
        .owner = owner_copy,
        .repo = repo_copy,
        .source_path = source_path_copy,
        .normalized = normalized,
    };
}

pub fn parseRepoSpec(allocator: std.mem.Allocator, input: []const u8) !RepoSpec {
    const parts = parseRepoParts(input) catch return SourceError.InvalidSpec;
    const owner = parts.owner;
    const project = parts.project;
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
    if (std.mem.indexOfScalar(u8, input, '@') != null) {
        const parts = parseRepoParts(input) catch return SourceError.InvalidSelector;
        const owner = parts.owner;
        const project = parts.project;
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

const RepoParts = struct {
    owner: []const u8,
    project: []const u8,
};

const RemoteParts = struct {
    source_label: []const u8,
    owner: []const u8,
    repo: []const u8,
    source_path: []const u8,
};

const SplitPath = struct {
    owner: []const u8,
    repo: []const u8,
    source_path: []const u8,
};

fn parseRemoteParts(input: []const u8, source_list: []const config.Source) !RemoteParts {
    if (std.mem.startsWith(u8, input, "@")) {
        const rest = input[1..];
        const split = try splitOwnerRepoPath(rest);
        return .{ .source_label = "github", .owner = split.owner, .repo = split.repo, .source_path = split.source_path };
    }

    const at_index = std.mem.indexOfScalar(u8, input, '@') orelse return SourceError.InvalidSpec;
    if (std.mem.indexOfScalarPos(u8, input, at_index + 1, '@') != null) return SourceError.InvalidSpec;

    const left = input[0..at_index];
    const right = input[at_index + 1 ..];
    if (config.findSource(source_list, left) != null) {
        const split = try splitOwnerRepoPath(right);
        return .{ .source_label = left, .owner = split.owner, .repo = split.repo, .source_path = split.source_path };
    }

    const slash_index = std.mem.indexOfScalar(u8, right, '/') orelse right.len;
    return .{
        .source_label = "github",
        .owner = left,
        .repo = right[0..slash_index],
        .source_path = if (slash_index == right.len) "" else right[slash_index + 1 ..],
    };
}

fn splitOwnerRepoPath(input: []const u8) !SplitPath {
    const owner_end = std.mem.indexOfScalar(u8, input, '/') orelse return SourceError.InvalidSpec;
    const rest = input[owner_end + 1 ..];
    const repo_end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return .{
        .owner = input[0..owner_end],
        .repo = rest[0..repo_end],
        .source_path = if (repo_end == rest.len) "" else rest[repo_end + 1 ..],
    };
}

fn parseRepoParts(input: []const u8) !RepoParts {
    if (std.mem.startsWith(u8, input, "@")) {
        if (std.mem.indexOfScalarPos(u8, input, 1, '@') != null) return SourceError.InvalidSpec;
        const slash_index = std.mem.indexOfScalar(u8, input, '/') orelse return SourceError.InvalidSpec;
        return .{
            .owner = input[1..slash_index],
            .project = input[slash_index + 1 ..],
        };
    }

    const at_index = std.mem.indexOfScalar(u8, input, '@') orelse return SourceError.InvalidSpec;
    if (std.mem.indexOfScalarPos(u8, input, at_index + 1, '@') != null) return SourceError.InvalidSpec;
    return .{
        .owner = input[0..at_index],
        .project = input[at_index + 1 ..],
    };
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

pub fn validateSourcePath(source_path: []const u8) !void {
    if (source_path.len == 0) return;
    var parts = std.mem.splitAny(u8, source_path, "/\\");
    while (parts.next()) |part| {
        if (isBadPathPart(part)) return SourceError.InvalidSourcePath;
    }
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
    const spec = try parseRepoSpec(allocator, "@owner/project");
    defer spec.deinit(allocator);
    try std.testing.expectEqualStrings("owner", spec.owner);
    try std.testing.expectEqualStrings("project", spec.project);
    try std.testing.expectEqualStrings("https://github.com/owner/project.git", spec.normalized);
}

test "parse add spec local and custom source" {
    const allocator = std.testing.allocator;
    var source_list: std.ArrayList(config.Source) = .empty;
    defer {
        for (source_list.items) |source| source.deinit(allocator);
        source_list.deinit(allocator);
    }
    try source_list.append(allocator, .{
        .label = try allocator.dupe(u8, "github"),
        .url_template = try allocator.dupe(u8, "https://github.com/{owner}/{repo}.git"),
    });
    try source_list.append(allocator, .{
        .label = try allocator.dupe(u8, "gitlab"),
        .url_template = try allocator.dupe(u8, "https://gitlab.com/{owner}/{repo}.git"),
    });

    const local = try parseAddSpec(allocator, "C:/skills/demo", source_list.items);
    defer local.deinit(allocator);
    try std.testing.expect(local == .local);

    const remote = try parseAddSpec(allocator, "gitlab@owner/repo/path/to/skill", source_list.items);
    defer remote.deinit(allocator);
    try std.testing.expect(remote == .remote);
    try std.testing.expectEqualStrings("gitlab", remote.remote.source_label);
    try std.testing.expectEqualStrings("owner", remote.remote.owner);
    try std.testing.expectEqualStrings("repo", remote.remote.repo);
    try std.testing.expectEqualStrings("path/to/skill", remote.remote.source_path);
    try std.testing.expectEqualStrings("https://gitlab.com/owner/repo.git", remote.remote.normalized);
}

test "parse legacy repo spec owner project" {
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

    const two = try parseSelector(allocator, "@owner/project");
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
