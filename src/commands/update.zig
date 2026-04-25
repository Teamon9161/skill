const std = @import("std");
const Context = @import("../context.zig").Context;
const agents = @import("../core/agents.zig");
const config = @import("../core/config.zig");
const detect = @import("../core/detect.zig");
const git = @import("../core/git.zig");
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");
const source_spec = @import("../core/source_spec.zig");

pub fn run(ctx: *Context, selector: ?source_spec.Selector) !void {
    try git.check(ctx.allocator, ctx.io);
    const cfg = try config.load(ctx.allocator, ctx.io, ctx.paths.config, ctx.paths.sources);
    defer cfg.deinit(ctx.allocator);

    if (selector) |sel| {
        const index = manifest.findIndex(ctx.manifest, sel) orelse return error.SkillNotFound;
        try updateOne(ctx, cfg, index);
        try ctx.save();
        return;
    }

    var failed = false;
    for (ctx.manifest.skills, 0..) |_, i| {
        updateOne(ctx, cfg, i) catch {
            failed = true;
        };
    }
    try ctx.save();
    if (failed) return error.SomeUpdatesFailed;
}

fn updateOne(ctx: *Context, cfg: config.Config, index: usize) !void {
    const skill = &ctx.manifest.skills[index];
    try git.update(ctx.allocator, ctx.io, skill.path, skill.branch);

    const layout = try detect.rootSkill(ctx.allocator, ctx.io, skill.path);
    defer layout.deinit(ctx.allocator);

    const branch = try git.currentBranch(ctx.allocator, ctx.io, skill.path);
    defer ctx.allocator.free(branch);
    const commit = try git.currentCommit(ctx.allocator, ctx.io, skill.path);
    defer ctx.allocator.free(commit);
    try manifest.setGit(ctx.allocator, skill, branch, commit);

    const cwd = try paths.cwdAlloc(ctx.allocator, ctx.io);
    defer ctx.allocator.free(cwd);

    const agent_list = try agents.detect(ctx.allocator, ctx.io, ctx.paths.home, cwd, cfg.agents, .{});
    defer agents.deinitList(ctx.allocator, agent_list);
    const created_links = try links.createForAgents(ctx.allocator, ctx.io, agent_list, skill.name, layout.target, .{ .prompt_conflicts = false });
    manifest.replaceLinks(ctx.allocator, skill, created_links);
}
