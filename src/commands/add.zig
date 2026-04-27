const std = @import("std");
const Context = @import("../context.zig").Context;
const cli = @import("../cli.zig");
const agents = @import("../core/agents.zig");
const config = @import("../core/config.zig");
const detect = @import("../core/detect.zig");
const git = @import("../core/git.zig");
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");
const source_spec = @import("../core/source_spec.zig");

pub fn run(ctx: *Context, target: cli.AddTarget) !void {
    const cfg = try config.load(ctx.allocator, ctx.io, ctx.paths.config, ctx.paths.sources);
    defer cfg.deinit(ctx.allocator);

    const cwd = try paths.cwdAlloc(ctx.allocator, ctx.io);
    defer ctx.allocator.free(cwd);

    const candidate_list = try agents.candidates(ctx.allocator, ctx.io, ctx.paths.home, cwd, cfg.agents, target.filter.scope);
    defer agents.deinitCandidates(ctx.allocator, candidate_list);

    const selected = try agents.selectInteractive(ctx.allocator, ctx.io, candidate_list, target.filter);
    defer ctx.allocator.free(selected);

    const agent_list = try agents.fromCandidates(ctx.allocator, candidate_list, selected);
    defer agents.deinitList(ctx.allocator, agent_list);

    for (target.inputs) |raw_input| {
        const input = resolveAlias(ctx.io, raw_input, cfg.aliases);
        const spec = try source_spec.parseAddSpec(ctx.allocator, input, cfg.sources);
        defer spec.deinit(ctx.allocator);
        switch (spec) {
            .remote => |remote| try addRemote(ctx, remote, agent_list),
            .local => |local| try addLocal(ctx, local, agent_list),
        }
    }

    try ctx.save();
}

fn resolveAlias(io: std.Io, input: []const u8, aliases: []const config.Alias) []const u8 {
    if (std.mem.indexOfAny(u8, input, "/\\") != null) return input;
    if (localDirExists(io, input)) return input;
    if (config.findAlias(aliases, input)) |alias| return alias.value;
    return input;
}

fn localDirExists(io: std.Io, name: []const u8) bool {
    var dir = std.Io.Dir.openDir(.cwd(), io, name, .{}) catch return false;
    dir.close(io);
    return true;
}

fn addRemote(ctx: *Context, spec: source_spec.RemoteSpec, agent_list: []const agents.Agent) !void {
    try git.check(ctx.allocator, ctx.io);
    try std.Io.Dir.createDirPath(.cwd(), ctx.io, ctx.paths.repos);

    const repo_path = try paths.repoPath(ctx.allocator, ctx.paths, spec.owner, spec.repo, spec.normalized);
    defer ctx.allocator.free(repo_path);

    const selected_source = if (try repoExists(ctx.io, repo_path))
        try git.remoteUrl(ctx.allocator, ctx.io, repo_path)
    else
        try git.cloneAny(ctx.allocator, ctx.io, spec.urls, repo_path, spec.connect_timeout_seconds);
    defer ctx.allocator.free(selected_source);

    try installRemoteLayouts(ctx, spec, repo_path, selected_source, agent_list);
}

fn installRemoteLayouts(
    ctx: *Context,
    spec: source_spec.RemoteSpec,
    repo_path: []const u8,
    selected_source: []const u8,
    agent_list: []const agents.Agent,
) !void {
    const base_path = try sourceBasePath(ctx.allocator, repo_path, spec.source_path);
    defer ctx.allocator.free(base_path);

    const default_name = defaultSkillName(spec.repo, spec.source_path);
    const layouts = try detect.skillLayouts(ctx.allocator, ctx.io, base_path, default_name);
    defer freeLayouts(ctx.allocator, layouts);

    const branch = try git.currentBranch(ctx.allocator, ctx.io, repo_path);
    defer ctx.allocator.free(branch);
    const commit = try git.currentCommit(ctx.allocator, ctx.io, repo_path);
    defer ctx.allocator.free(commit);

    for (layouts) |layout| {
        try installLayout(ctx, .{
            .name = layout.name,
            .owner = spec.owner,
            .project = spec.repo,
            .source_label = spec.source_label,
            .source_path = spec.source_path,
            .source = selected_source,
            .storage_path = repo_path,
            .branch = branch,
            .commit = commit,
        }, layout.target, agent_list);
    }
}

fn addLocal(ctx: *Context, spec: source_spec.LocalSpec, agent_list: []const agents.Agent) !void {
    const abs_path = try absolutePath(ctx.allocator, ctx.io, spec.path);
    defer ctx.allocator.free(abs_path);

    const project = std.fs.path.basename(abs_path);
    const layouts = try detect.skillLayouts(ctx.allocator, ctx.io, abs_path, project);
    defer freeLayouts(ctx.allocator, layouts);

    for (layouts) |layout| {
        try installLayout(ctx, .{
            .name = layout.name,
            .owner = "local",
            .project = project,
            .source_label = "local",
            .source_path = "",
            .source = abs_path,
            .storage_path = abs_path,
            .branch = "",
            .commit = "",
        }, layout.target, agent_list);
    }
}

const InstallInfo = struct {
    name: []const u8,
    owner: []const u8,
    project: []const u8,
    source_label: []const u8,
    source_path: []const u8,
    source: []const u8,
    storage_path: []const u8,
    branch: []const u8,
    commit: []const u8,
};

fn installLayout(
    ctx: *Context,
    info: InstallInfo,
    target: []const u8,
    agent_list: []const agents.Agent,
) !void {
    const existing = manifest.findIdentity(
        ctx.manifest,
        info.source_label,
        info.owner,
        info.project,
        info.source_path,
        info.name,
    );
    const prev_links: []const manifest.Link = if (existing) |i| ctx.manifest.skills[i].links else &.{};

    const created_links = try links.createForAgents(ctx.allocator, ctx.io, agent_list, info.name, target, .{});
    var created_links_owned = true;
    errdefer {
        if (created_links_owned) {
            for (created_links) |link| link.deinit(ctx.allocator);
            ctx.allocator.free(created_links);
        }
    }

    const index = if (existing) |i| i else blk: {
        const skill = try manifest.newSkill(
            ctx.allocator,
            info.name,
            info.owner,
            info.project,
            info.source_label,
            info.source_path,
            info.source,
            info.storage_path,
        );
        try manifest.appendSkill(ctx.allocator, &ctx.manifest, skill);
        break :blk ctx.manifest.skills.len - 1;
    };

    const skill = &ctx.manifest.skills[index];
    ctx.allocator.free(skill.source);
    skill.source = try ctx.allocator.dupe(u8, info.source);
    try manifest.setGit(ctx.allocator, skill, info.branch, info.commit);
    try printInstalledLinks(ctx.io, info.name, created_links, prev_links);
    try manifest.replaceLinksForAgents(ctx.allocator, skill, agent_list, created_links);
    created_links_owned = false;
    ctx.allocator.free(created_links);

    for (skill.links) |link| {
        try manifest.removeLinkPathFromOthers(ctx.allocator, &ctx.manifest, index, link.agent, link.path);
    }
}

fn printInstalledLinks(io: std.Io, name: []const u8, created_links: []const manifest.Link, prev_links: []const manifest.Link) !void {
    var new_count: usize = 0;
    for (created_links) |link| {
        if (isNewLink(link, prev_links)) new_count += 1;
    }

    if (new_count == 0) {
        try std.Io.File.writeStreamingAll(.stdout(), io, "No links changed for ");
        try std.Io.File.writeStreamingAll(.stdout(), io, name);
        try std.Io.File.writeStreamingAll(.stdout(), io, "\n");
        return;
    }

    try std.Io.File.writeStreamingAll(.stdout(), io, "Installed ");
    try std.Io.File.writeStreamingAll(.stdout(), io, name);
    try std.Io.File.writeStreamingAll(.stdout(), io, " for:\n");
    for (created_links) |link| {
        if (!isNewLink(link, prev_links)) continue;
        try std.Io.File.writeStreamingAll(.stdout(), io, "  - ");
        try std.Io.File.writeStreamingAll(.stdout(), io, link.agent);
        try std.Io.File.writeStreamingAll(.stdout(), io, ": ");
        try std.Io.File.writeStreamingAll(.stdout(), io, link.path);
        try std.Io.File.writeStreamingAll(.stdout(), io, "\n");
    }
}

fn isNewLink(link: manifest.Link, prev_links: []const manifest.Link) bool {
    for (prev_links) |prev| {
        if (std.mem.eql(u8, prev.agent, link.agent) and
            std.mem.eql(u8, prev.path, link.path) and
            std.mem.eql(u8, prev.target, link.target)) return false;
    }
    return true;
}


fn repoExists(io: std.Io, repo_path: []const u8) !bool {
    std.Io.Dir.accessAbsolute(io, repo_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn sourceBasePath(allocator: std.mem.Allocator, repo_path: []const u8, source_path: []const u8) ![]const u8 {
    if (source_path.len == 0) return allocator.dupe(u8, repo_path);
    return std.fs.path.join(allocator, &.{ repo_path, source_path });
}

fn defaultSkillName(repo: []const u8, source_path: []const u8) []const u8 {
    if (source_path.len == 0) return repo;
    return pathTail(source_path);
}

fn pathTail(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfAny(u8, path, "/\\")) |index| return path[index + 1 ..];
    return path;
}

fn absolutePath(allocator: std.mem.Allocator, io: std.Io, input: []const u8) ![]const u8 {
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var dir = if (std.fs.path.isAbsolute(input))
        try std.Io.Dir.openDirAbsolute(io, input, .{})
    else
        try std.Io.Dir.openDir(.cwd(), io, input, .{});
    defer dir.close(io);
    const len = try dir.realPath(io, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn freeLayouts(allocator: std.mem.Allocator, layouts: []detect.Layout) void {
    for (layouts) |layout| layout.deinit(allocator);
    allocator.free(layouts);
}
