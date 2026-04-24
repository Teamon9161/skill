const std = @import("std");
const Context = @import("../context.zig").Context;
const agents = @import("../core/agents.zig");
const detect = @import("../core/detect.zig");
const git = @import("../core/git.zig");
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");
const source_spec = @import("../core/source_spec.zig");

pub fn run(ctx: *Context, spec: source_spec.RepoSpec) !void {
    if (manifest.findProject(ctx.manifest, spec.project)) |index| {
        const existing = ctx.manifest.skills[index];
        if (!std.mem.eql(u8, existing.owner, spec.owner)) return error.ProjectAlreadyInstalled;
        try updateExisting(ctx, index);
        return;
    }

    try git.check(ctx.allocator, ctx.io);
    try std.Io.Dir.createDirPath(.cwd(), ctx.io, ctx.paths.repos);

    const repo_path = try paths.repoPath(ctx.allocator, ctx.paths, spec.owner, spec.project, spec.normalized);
    defer ctx.allocator.free(repo_path);

    try git.clone(ctx.allocator, ctx.io, spec.normalized, repo_path);
    const layout = try detect.rootSkill(ctx.allocator, ctx.io, repo_path);
    defer layout.deinit(ctx.allocator);

    const branch = try git.currentBranch(ctx.allocator, ctx.io, repo_path);
    defer ctx.allocator.free(branch);
    const commit = try git.currentCommit(ctx.allocator, ctx.io, repo_path);
    defer ctx.allocator.free(commit);

    const agent_list = try agents.detect(ctx.allocator, ctx.io, ctx.paths.home, .{});
    defer agents.deinitList(ctx.allocator, agent_list);
    const created_links = try links.createForAgents(ctx.allocator, ctx.io, agent_list, spec.project, layout.target);

    var skill = try manifest.newSkill(ctx.allocator, spec.owner, spec.project, spec.normalized, repo_path);
    errdefer skill.deinit(ctx.allocator);
    try manifest.setGit(ctx.allocator, &skill, branch, commit);
    skill.links = created_links;

    try manifest.appendSkill(ctx.allocator, &ctx.manifest, skill);
    try ctx.save();
}

fn updateExisting(ctx: *Context, index: usize) !void {
    const skill = &ctx.manifest.skills[index];
    try git.update(ctx.allocator, ctx.io, skill.path, skill.branch);

    const layout = try detect.rootSkill(ctx.allocator, ctx.io, skill.path);
    defer layout.deinit(ctx.allocator);
    const branch = try git.currentBranch(ctx.allocator, ctx.io, skill.path);
    defer ctx.allocator.free(branch);
    const commit = try git.currentCommit(ctx.allocator, ctx.io, skill.path);
    defer ctx.allocator.free(commit);
    try manifest.setGit(ctx.allocator, skill, branch, commit);

    const agent_list = try agents.detect(ctx.allocator, ctx.io, ctx.paths.home, .{});
    defer agents.deinitList(ctx.allocator, agent_list);
    const created_links = try links.createForAgents(ctx.allocator, ctx.io, agent_list, skill.project, layout.target);
    manifest.replaceLinks(ctx.allocator, skill, created_links);

    try ctx.save();
}
