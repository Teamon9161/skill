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
    const source_options = try updateSourceOptions(ctx.allocator, cfg, skill.*);
    const urls = source_options.urls;
    defer config.freeStringList(ctx.allocator, urls);

    const selected_source = try git.updateAny(ctx.allocator, ctx.io, skill.path, skill.branch, urls, source_options.connect_timeout_seconds);
    defer ctx.allocator.free(selected_source);
    if (selected_source.len != 0) {
        ctx.allocator.free(skill.source);
        skill.source = try ctx.allocator.dupe(u8, selected_source);
    }

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

const UpdateSourceOptions = struct {
    urls: []const []const u8,
    connect_timeout_seconds: u32,
};

fn updateSourceOptions(allocator: std.mem.Allocator, cfg: config.Config, skill: manifest.Skill) !UpdateSourceOptions {
    if (config.findSource(cfg.sources, skill.source_label)) |source| {
        return .{
            .urls = try config.expandUrls(allocator, source, skill.owner, skill.project),
            .connect_timeout_seconds = source.connect_timeout_seconds,
        };
    }

    var urls = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(urls);
    urls[0] = try allocator.dupe(u8, skill.source);
    return .{
        .urls = urls,
        .connect_timeout_seconds = config.default_connect_timeout_seconds,
    };
}
