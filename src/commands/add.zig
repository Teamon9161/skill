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

    const input = resolveAlias(target.input, cfg.aliases);
    const spec = try source_spec.parseAddSpec(ctx.allocator, input, cfg.sources);
    defer spec.deinit(ctx.allocator);

    const cwd = try paths.cwdAlloc(ctx.allocator, ctx.io);
    defer ctx.allocator.free(cwd);

    const candidate_list = try agents.candidates(ctx.allocator, ctx.io, ctx.paths.home, cwd, cfg.agents, target.filter.scope);
    defer agents.deinitCandidates(ctx.allocator, candidate_list);

    const selected = try selectAgents(ctx, candidate_list, target.filter);
    defer ctx.allocator.free(selected);

    const agent_list = try agents.fromCandidates(ctx.allocator, candidate_list, selected);
    defer agents.deinitList(ctx.allocator, agent_list);

    switch (spec) {
        .remote => |remote| try addRemote(ctx, remote, agent_list),
        .local => |local| try addLocal(ctx, local, agent_list),
    }

    try ctx.save();
}

fn resolveAlias(input: []const u8, aliases: []const config.Alias) []const u8 {
    if (std.mem.indexOfAny(u8, input, "/\\") != null) return input;
    if (config.findAlias(aliases, input)) |alias| return alias.value;
    return input;
}

fn addRemote(ctx: *Context, spec: source_spec.RemoteSpec, agent_list: []const agents.Agent) !void {
    try git.check(ctx.allocator, ctx.io);
    try std.Io.Dir.createDirPath(.cwd(), ctx.io, ctx.paths.repos);

    const repo_path = try paths.repoPath(ctx.allocator, ctx.paths, spec.owner, spec.repo, spec.normalized);
    defer ctx.allocator.free(repo_path);

    if (try repoExists(ctx.io, repo_path)) {
        const selected_source = try git.updateAny(ctx.allocator, ctx.io, repo_path, "", spec.urls, spec.connect_timeout_seconds);
        defer ctx.allocator.free(selected_source);
        try installRemoteLayouts(ctx, spec, repo_path, selected_source, agent_list);
    } else {
        const selected_source = try git.cloneAny(ctx.allocator, ctx.io, spec.urls, repo_path, spec.connect_timeout_seconds);
        defer ctx.allocator.free(selected_source);
        try installRemoteLayouts(ctx, spec, repo_path, selected_source, agent_list);
    }
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
    const created_links = try links.createForAgents(ctx.allocator, ctx.io, agent_list, info.name, target, .{});
    var created_links_owned = true;
    errdefer {
        if (created_links_owned) {
            for (created_links) |link| link.deinit(ctx.allocator);
            ctx.allocator.free(created_links);
        }
    }

    const existing = manifest.findIdentity(
        ctx.manifest,
        info.source_label,
        info.owner,
        info.project,
        info.source_path,
        info.name,
    );

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
    try manifest.replaceLinksForAgents(ctx.allocator, skill, agent_list, created_links);
    created_links_owned = false;
    ctx.allocator.free(created_links);

    for (skill.links) |link| {
        try manifest.removeLinkPathFromOthers(ctx.allocator, &ctx.manifest, index, link.agent, link.path);
    }
}

fn selectAgents(
    ctx: *Context,
    candidate_list: []const agents.Candidate,
    filter: agents.AgentFilter,
) ![]bool {
    const selected = try ctx.allocator.alloc(bool, candidate_list.len);
    errdefer ctx.allocator.free(selected);

    if (filter.hasAny()) {
        var count: usize = 0;
        for (candidate_list, 0..) |candidate, i| {
            selected[i] = filter.matches(candidate.id);
            if (selected[i]) count += 1;
        }
        if (count == 0) return error.UnknownAgent;
        return selected;
    }

    for (candidate_list, 0..) |candidate, i| {
        selected[i] = candidate.exists;
    }

    try printAgentPrompt(ctx.io, candidate_list, selected);

    var buf: [256]u8 = undefined;
    const n = std.Io.File.readStreaming(.stdin(), ctx.io, &.{buf[0..]}) catch |err| switch (err) {
        error.EndOfStream => return selected,
        else => return err,
    };
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (answer.len == 0) return selected;

    @memset(selected, false);
    var tokens = std.mem.tokenizeAny(u8, answer, ", \t");
    while (tokens.next()) |token| {
        if (std.fmt.parseUnsigned(usize, token, 10)) |index| {
            if (index == 0 or index > candidate_list.len) return error.InvalidAgentSelection;
            selected[index - 1] = true;
            continue;
        } else |_| {}

        var matched = false;
        for (candidate_list, 0..) |candidate, i| {
            if (std.ascii.eqlIgnoreCase(token, candidate.id) or std.ascii.eqlIgnoreCase(token, candidate.label)) {
                selected[i] = true;
                matched = true;
            }
        }
        if (!matched) return error.InvalidAgentSelection;
    }

    return selected;
}

fn printAgentPrompt(io: std.Io, candidate_list: []const agents.Candidate, selected: []const bool) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, "Available agents:\n");
    for (candidate_list, 0..) |candidate, i| {
        try std.Io.File.writeStreamingAll(.stdout(), io, if (selected[i]) "  [+] " else "  [ ] ");
        var number: [32]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number, "{d}. ", .{i + 1});
        try std.Io.File.writeStreamingAll(.stdout(), io, number_text);
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.label);
        try std.Io.File.writeStreamingAll(.stdout(), io, " (");
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.base);
        try std.Io.File.writeStreamingAll(.stdout(), io, ")");
        if (selected[i]) {
            try std.Io.File.writeStreamingAll(.stdout(), io, " default");
        } else if (!candidate.exists) {
            try std.Io.File.writeStreamingAll(.stdout(), io, " not detected");
        }
        try std.Io.File.writeStreamingAll(.stdout(), io, "\n");
    }
    try std.Io.File.writeStreamingAll(.stdout(), io, "Enter numbers or ids to override. ");
    try printDefaultSelection(io, candidate_list, selected);
    try std.Io.File.writeStreamingAll(.stdout(), io, ": ");
}

fn printDefaultSelection(io: std.Io, candidate_list: []const agents.Candidate, selected: []const bool) !void {
    var any = false;
    try std.Io.File.writeStreamingAll(.stdout(), io, "Press Enter for default");
    for (candidate_list, 0..) |candidate, i| {
        if (!selected[i]) continue;
        try std.Io.File.writeStreamingAll(.stdout(), io, if (any) ", " else " ");
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.id);
        any = true;
    }
    if (!any) try std.Io.File.writeStreamingAll(.stdout(), io, " none");
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
    if (std.fs.path.isAbsolute(input)) {
        const resolved = try std.Io.Dir.realPathFileAbsoluteAlloc(io, input, allocator);
        defer allocator.free(resolved);
        return allocator.dupe(u8, resolved);
    }
    const resolved = try std.Io.Dir.realPathFileAlloc(.cwd(), io, input, allocator);
    defer allocator.free(resolved);
    return allocator.dupe(u8, resolved);
}

fn freeLayouts(allocator: std.mem.Allocator, layouts: []detect.Layout) void {
    for (layouts) |layout| layout.deinit(allocator);
    allocator.free(layouts);
}
