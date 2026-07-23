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
    base_path: []const u8,
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
        if (created) {
            try out.append(allocator, try manifest.newLink(allocator, agent.id, link_path, target));
        }

        try createSubagentLink(allocator, io, agent, name, base_path, target, options, &out);
    }

    return out.toOwnedSlice(allocator);
}

// Install a skill's sub-agents for one harness by symlinking a per-skill dir
// into <base>/<agents>/<name> (Claude scans that dir recursively). The source
// is resolved with priority: the repo's harness-specific dir (e.g. .claude/agents)
// first, then the skill's own bundled agents/ subdir.
fn createSubagentLink(
    allocator: std.mem.Allocator,
    io: std.Io,
    agent: agents.Agent,
    name: []const u8,
    base_path: []const u8,
    target: []const u8,
    options: CreateOptions,
    out: *std.ArrayList(manifest.Link),
) !void {
    const sub = agent.agents orelse return;
    const src = (try resolveSubagentSrc(allocator, io, base_path, agent.dir, target, sub)) orelse return;
    defer allocator.free(src);

    const dest_dir = try paths.child(allocator, agent.base, sub);
    defer allocator.free(dest_dir);
    try std.Io.Dir.createDirPath(.cwd(), io, dest_dir);

    const link_path = try paths.child(allocator, dest_dir, name);
    defer allocator.free(link_path);
    const created = try ensureLink(allocator, io, agent.id, link_path, src, options);
    if (!created) return;
    try out.append(allocator, try manifest.newLink(allocator, agent.id, link_path, src));
}

fn resolveSubagentSrc(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    dir: []const u8,
    target: []const u8,
    sub: []const u8,
) !?[]const u8 {
    // 1. Harness-specific dir at the repo root, e.g. <repo>/.claude/agents.
    if (dir.len > 0 and !std.fs.path.isAbsolute(dir)) {
        const specific = try std.fs.path.join(allocator, &.{ base_path, dir, sub });
        if (dirExists(io, specific)) return specific;
        allocator.free(specific);
    }
    // 2. The skill's own bundled agents/ subdir.
    const bundled = try std.fs.path.join(allocator, &.{ target, sub });
    if (dirExists(io, bundled)) return bundled;
    allocator.free(bundled);
    return null;
}

fn dirExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

// A git link belongs to an agent when its path is under that agent's skills
// dir or its sub-agents dir.
pub fn agentOwnsPath(agent: agents.Agent, path: []const u8) bool {
    if (paths.isInside(agent.skills, path)) return true;
    if (agent.agents) |sub| {
        var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const dest = std.fmt.bufPrint(&buf, "{s}{c}{s}", .{ agent.base, std.fs.path.sep, sub }) catch return false;
        if (paths.isInside(dest, path)) return true;
    }
    return false;
}

pub fn removeRecorded(io: std.Io, recorded: []const manifest.Link) !void {
    for (recorded) |link| {
        try removeIfMatches(io, link.path, link.target);
    }
}

pub fn removeRecordedForAgents(
    io: std.Io,
    recorded: []const manifest.Link,
    agent_list: []const agents.Agent,
) !void {
    for (recorded) |link| {
        if (!linkBelongsToAnyAgent(link, agent_list)) continue;
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
            if (!options.prompt_conflicts) return false;
            if (!try confirmReplace(io, agent_id, link_path)) return false;
            try deleteExisting(io, link_path);
            try createDirectoryLink(allocator, io, link_path, target);
            return true;
        },
        else => return err,
    };

    if (std.mem.eql(u8, buf[0..len], target)) return true;
    if (!options.prompt_conflicts) return false;
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
        error.NotLink => {
            try printConflict(io, "exists but is not a link", link_path, target, null);
            return error.LinkConflict;
        },
        else => return err,
    };

    if (!std.mem.eql(u8, buf[0..len], target)) {
        try printConflict(io, "points to a different target", link_path, target, buf[0..len]);
        return error.LinkConflict;
    }
    try deleteLinkPath(io, link_path);
}

fn linkBelongsToAnyAgent(link: manifest.Link, agent_list: []const agents.Agent) bool {
    for (agent_list) |agent| {
        if (!std.mem.eql(u8, link.agent, agent.id)) continue;
        if (agentOwnsPath(agent, link.path)) return true;
    }
    return false;
}

fn printConflict(
    io: std.Io,
    reason: []const u8,
    link_path: []const u8,
    expected: []const u8,
    actual: ?[]const u8,
) !void {
    try std.Io.File.writeStreamingAll(.stderr(), io, "link conflict: ");
    try std.Io.File.writeStreamingAll(.stderr(), io, link_path);
    try std.Io.File.writeStreamingAll(.stderr(), io, " ");
    try std.Io.File.writeStreamingAll(.stderr(), io, reason);
    try std.Io.File.writeStreamingAll(.stderr(), io, "\n  expected: ");
    try std.Io.File.writeStreamingAll(.stderr(), io, expected);
    if (actual) |value| {
        try std.Io.File.writeStreamingAll(.stderr(), io, "\n  actual: ");
        try std.Io.File.writeStreamingAll(.stderr(), io, value);
    }
    try std.Io.File.writeStreamingAll(.stderr(), io, "\n");
}

fn deleteLinkPath(io: std.Io, link_path: []const u8) !void {
    std.Io.Dir.deleteFileAbsolute(io, link_path) catch |err| switch (err) {
        error.IsDir => try std.Io.Dir.deleteDirAbsolute(io, link_path),
        else => return err,
    };
}

test "recorded link matching is scoped to selected agent directories" {
    const sep = std.fs.path.sep_str;
    const skills = "C:" ++ sep ++ "repo" ++ sep ++ ".codex" ++ sep ++ "skills";
    const link = manifest.Link{
        .agent = "codex",
        .path = skills ++ sep ++ "lark-doc",
        .target = "C:" ++ sep ++ "store" ++ sep ++ "lark-doc",
    };
    const wrong_agent = manifest.Link{
        .agent = "claude",
        .path = skills ++ sep ++ "lark-doc",
        .target = "C:" ++ sep ++ "store" ++ sep ++ "lark-doc",
    };
    const sibling = manifest.Link{
        .agent = "codex",
        .path = skills ++ "-old" ++ sep ++ "lark-doc",
        .target = "C:" ++ sep ++ "store" ++ sep ++ "lark-doc",
    };
    const agent_list = [_]agents.Agent{.{
        .id = "codex",
        .base = "C:" ++ sep ++ "repo" ++ sep ++ ".codex",
        .skills = skills,
    }};

    try std.testing.expect(linkBelongsToAnyAgent(link, &agent_list));
    try std.testing.expect(!linkBelongsToAnyAgent(wrong_agent, &agent_list));
    try std.testing.expect(!linkBelongsToAnyAgent(sibling, &agent_list));
}
