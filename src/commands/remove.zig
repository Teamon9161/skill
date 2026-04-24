const std = @import("std");
const Context = @import("../context.zig").Context;
const cli = @import("../cli.zig");
const agents = @import("../core/agents.zig");
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");

pub fn run(ctx: *Context, target: cli.Target) !void {
    const index = manifest.findIndex(ctx.manifest, target.selector) orelse return error.SkillNotFound;
    var skill = &ctx.manifest.skills[index];

    const agent_list = try agents.detect(ctx.allocator, ctx.io, ctx.paths.home, target.filter);
    defer agents.deinitList(ctx.allocator, agent_list);

    try links.removeForAgents(ctx.allocator, ctx.io, agent_list, skill.project, skill.path);

    var kept: std.ArrayList(manifest.Link) = .empty;
    errdefer kept.deinit(ctx.allocator);
    for (skill.links) |link| {
        if (target.filter.matches(link.agent)) {
            link.deinit(ctx.allocator);
        } else {
            try kept.append(ctx.allocator, link);
        }
    }
    const new_links = try kept.toOwnedSlice(ctx.allocator);
    ctx.allocator.free(skill.links);
    skill.links = new_links;

    try ctx.save();
}
