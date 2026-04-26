const std = @import("std");
const Context = @import("../context.zig").Context;
const agents = @import("../core/agents.zig");
const config = @import("../core/config.zig");
const git = @import("../core/git.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");

pub fn run(ctx: *Context) !void {
    const cfg = try config.load(ctx.allocator, ctx.io, ctx.paths.config, ctx.paths.sources);
    defer cfg.deinit(ctx.allocator);

    const cwd = try paths.cwdAlloc(ctx.allocator, ctx.io);
    defer ctx.allocator.free(cwd);

    const candidate_list = try agents.candidates(ctx.allocator, ctx.io, ctx.paths.home, cwd, cfg.agents, .global);
    defer agents.deinitCandidates(ctx.allocator, candidate_list);

    var new_manifest: manifest.Manifest = .{};
    errdefer new_manifest.deinit(ctx.allocator);

    for (candidate_list) |candidate| {
        if (!candidate.exists) continue;
        try scanAgentLinks(ctx, &cfg, candidate.id, candidate.skills, &new_manifest);
    }

    const old_count = ctx.manifest.skills.len;
    ctx.manifest.deinit(ctx.allocator);
    ctx.manifest = new_manifest;
    try ctx.save();

    try printSummary(ctx.io, old_count, ctx.manifest);
}

fn scanAgentLinks(
    ctx: *Context,
    cfg: *const config.Config,
    agent_id: []const u8,
    skills_dir: []const u8,
    new_manifest: *manifest.Manifest,
) !void {
    var dir = std.Io.Dir.openDirAbsolute(ctx.io, skills_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(ctx.io);

    var it = dir.iterate();
    while (try it.next(ctx.io)) |entry| {
        const link_path = try paths.child(ctx.allocator, skills_dir, entry.name);
        defer ctx.allocator.free(link_path);

        var target_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const target_len = std.Io.Dir.readLinkAbsolute(ctx.io, link_path, &target_buf) catch |err| switch (err) {
            error.FileNotFound, error.NotLink => continue,
            else => return err,
        };
        const target = target_buf[0..target_len];

        if (!paths.isInside(ctx.paths.repos, target)) continue;

        processLink(ctx, cfg, new_manifest, agent_id, link_path, entry.name, target) catch |err| switch (err) {
            error.GitFailed => continue,
            else => return err,
        };
    }
}

fn processLink(
    ctx: *Context,
    cfg: *const config.Config,
    new_manifest: *manifest.Manifest,
    agent_id: []const u8,
    link_path: []const u8,
    skill_name: []const u8,
    target: []const u8,
) !void {
    // strip repos_path + sep prefix to get the relative path within repos
    const after_repos = target[ctx.paths.repos.len + 1 ..];
    const sep_pos = std.mem.indexOfScalar(u8, after_repos, std.fs.path.sep) orelse after_repos.len;
    const repo_dir_name = after_repos[0..sep_pos];
    const rest = if (sep_pos == after_repos.len) "" else after_repos[sep_pos + 1 ..];

    const repo_info = parseRepoDirName(repo_dir_name) orelse return;

    const repo_root = try std.fs.path.join(ctx.allocator, &.{ ctx.paths.repos, repo_dir_name });
    defer ctx.allocator.free(repo_root);

    const source_path = try recoverSourcePath(ctx.allocator, rest);
    defer ctx.allocator.free(source_path);

    const skill_index = try findOrCreateSkill(
        ctx,
        cfg,
        new_manifest,
        repo_root,
        repo_info.owner,
        repo_info.project,
        source_path,
        skill_name,
    );

    const link = try manifest.newLink(ctx.allocator, agent_id, link_path, target);
    errdefer link.deinit(ctx.allocator);
    try appendLink(ctx.allocator, &new_manifest.skills[skill_index], link);
}

fn findOrCreateSkill(
    ctx: *Context,
    cfg: *const config.Config,
    new_manifest: *manifest.Manifest,
    repo_root: []const u8,
    owner: []const u8,
    project: []const u8,
    source_path: []const u8,
    skill_name: []const u8,
) !usize {
    for (new_manifest.skills, 0..) |skill, i| {
        if (std.mem.eql(u8, skill.name, skill_name) and
            std.mem.eql(u8, skill.path, repo_root) and
            std.mem.eql(u8, skill.source_path, source_path))
        {
            return i;
        }
    }

    const remote_url = try git.remoteUrl(ctx.allocator, ctx.io, repo_root);
    defer ctx.allocator.free(remote_url);

    const source_label = try matchSourceLabel(ctx.allocator, cfg, remote_url, owner, project);
    defer ctx.allocator.free(source_label);

    const branch = git.currentBranch(ctx.allocator, ctx.io, repo_root) catch |err| switch (err) {
        error.GitFailed => try ctx.allocator.dupe(u8, ""),
        else => return err,
    };
    defer ctx.allocator.free(branch);

    const commit = git.currentCommit(ctx.allocator, ctx.io, repo_root) catch |err| switch (err) {
        error.GitFailed => try ctx.allocator.dupe(u8, ""),
        else => return err,
    };
    defer ctx.allocator.free(commit);

    var skill = try manifest.newSkill(
        ctx.allocator,
        skill_name,
        owner,
        project,
        source_label,
        source_path,
        remote_url,
        repo_root,
    );
    errdefer skill.deinit(ctx.allocator);
    try manifest.setGit(ctx.allocator, &skill, branch, commit);
    try manifest.appendSkill(ctx.allocator, new_manifest, skill);
    return new_manifest.skills.len - 1;
}

fn appendLink(allocator: std.mem.Allocator, skill: *manifest.Skill, link: manifest.Link) !void {
    const new_links = try allocator.realloc(skill.links, skill.links.len + 1);
    skill.links = new_links;
    skill.links[skill.links.len - 1] = link;
}

const RepoDirInfo = struct {
    owner: []const u8,
    project: []const u8,
};

fn parseRepoDirName(name: []const u8) ?RepoDirInfo {
    // format: {owner}@{project}-{12hexhash}
    const at_index = std.mem.indexOfScalar(u8, name, '@') orelse return null;
    const owner = name[0..at_index];
    if (owner.len == 0) return null;

    const after_at = name[at_index + 1 ..];
    // need at least 1 project char + '-' + 12 hex chars
    if (after_at.len < 14) return null;
    const hash_sep = after_at.len - 13;
    if (after_at[hash_sep] != '-') return null;

    const hash_part = after_at[after_at.len - 12 ..];
    for (hash_part) |c| {
        if (!isHexDigit(c)) return null;
    }

    const project = after_at[0..hash_sep];
    if (project.len == 0) return null;

    return .{ .owner = owner, .project = project };
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn recoverSourcePath(allocator: std.mem.Allocator, rest: []const u8) ![]const u8 {
    if (rest.len == 0) return allocator.dupe(u8, "");

    // check if the parent directory component is named "skills"
    const sep_pos = std.mem.lastIndexOfScalar(u8, rest, std.fs.path.sep) orelse {
        // single component, no "skills" parent → root layout, source_path = this component
        return allocator.dupe(u8, rest);
    };

    const parent = rest[0..sep_pos];
    const parent_tail_start = if (std.mem.lastIndexOfScalar(u8, parent, std.fs.path.sep)) |p| p + 1 else 0;
    const parent_tail = parent[parent_tail_start..];

    if (std.mem.eql(u8, parent_tail, "skills")) {
        // skills/ layout: source_path is everything before "skills" in parent
        if (parent_tail_start == 0) return allocator.dupe(u8, "");
        return allocator.dupe(u8, parent[0 .. parent_tail_start - 1]);
    }

    // root layout with source_path = rest (target is repo_root/source_path)
    return allocator.dupe(u8, rest);
}

fn matchSourceLabel(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
    remote_url: []const u8,
    owner: []const u8,
    project: []const u8,
) ![]const u8 {
    for (cfg.sources) |source| {
        const urls = config.expandUrls(allocator, source, owner, project) catch continue;
        defer config.freeStringList(allocator, urls);
        for (urls) |url| {
            if (std.mem.eql(u8, url, remote_url)) return allocator.dupe(u8, source.label);
        }
    }
    return allocator.dupe(u8, "github");
}

fn printSummary(io: std.Io, old_count: usize, new_manifest: manifest.Manifest) !void {
    var buf: [128]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "Rebuilt manifest: {d} skill(s) found (was {d})\n", .{ new_manifest.skills.len, old_count });
    try std.Io.File.writeStreamingAll(.stdout(), io, msg);
}
