const std = @import("std");
const Context = @import("../context.zig").Context;
const cli = @import("../cli.zig");
const agents = @import("../core/agents.zig");
const config = @import("../core/config.zig");
const io_util = @import("io.zig");
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");
const plugins = @import("../core/plugins.zig");

pub fn run(ctx: *Context, target: cli.Target) !void {
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

    var changed = false;
    for (target.queries) |query| {
        if (try removeOne(ctx, agent_list, query)) changed = true;
    }

    if (changed) try ctx.save();
}

fn removeOne(ctx: *Context, agent_list: []const agents.Agent, query: []const u8) !bool {
    const indices = try manifest.matchSkills(ctx.allocator, ctx.manifest, query);
    defer ctx.allocator.free(indices);

    const linked_indices = try filterLinkedMatches(ctx.allocator, ctx.manifest, indices, agent_list);
    defer ctx.allocator.free(linked_indices);

    if (linked_indices.len == 0) {
        try io_util.eprintln(ctx.io, &.{ "warning: no linked skills match ", query });
        return false;
    }

    const selected = try chooseMatches(ctx, linked_indices, query);
    defer ctx.allocator.free(selected);

    // Deduplicate plugin CLI removes across all selected skills before per-skill cleanup.
    try removePluginLinksDedup(ctx, linked_indices, selected, agent_list);

    var changed = false;
    for (linked_indices, 0..) |index, i| {
        if (!selected[i]) continue;
        const skill = &ctx.manifest.skills[index];
        try links.removeRecordedForAgents(ctx.io, skill.links, agent_list);
        try printRemovedLinks(ctx.io, skill.name, skill.links, agent_list);
        try dropRecordedLinks(ctx.allocator, skill, agent_list);
        changed = true;
    }
    return changed;
}

fn filterLinkedMatches(
    allocator: std.mem.Allocator,
    value: manifest.Manifest,
    indices: []const usize,
    agent_list: []const agents.Agent,
) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);

    for (indices) |index| {
        const skill = value.skills[index];
        for (skill.links) |link| {
            if (!matchesAgentLink(agent_list, link)) continue;
            try out.append(allocator, index);
            break;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn matchesAgentLink(agent_list: []const agents.Agent, link: manifest.Link) bool {
    for (agent_list) |agent| {
        if (!std.mem.eql(u8, agent.id, link.agent)) continue;
        return switch (link.kind) {
            .git => paths.isInside(agent.skills, link.path),
            .marketplace, .plugin => true,
        };
    }
    return false;
}

fn chooseMatches(ctx: *Context, indices: []const usize, query: []const u8) ![]bool {
    const selected = try ctx.allocator.alloc(bool, indices.len);
    errdefer ctx.allocator.free(selected);
    @memset(selected, false);

    if (indices.len == 1) {
        selected[0] = true;
        return selected;
    }

    if (manifest.allSameProject(ctx.manifest, indices, query)) {
        @memset(selected, true);
        return selected;
    }

    try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "Matching skills:\n");
    for (indices, 0..) |index, i| {
        const skill = ctx.manifest.skills[index];
        var number: [32]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number, "  {d}. ", .{i + 1});
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, number_text);
        try io_util.println(ctx.io, &.{ skill.name, " from ", skill.project });
    }
    try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "Choose numbers to remove, Enter for all, or n to cancel: ");

    var buf: [256]u8 = undefined;
    const answer = try io_util.readPromptLine(ctx.io, &buf);
    if (answer.len == 0) {
        @memset(selected, true);
        return selected;
    }
    if (std.ascii.eqlIgnoreCase(answer, "all")) {
        @memset(selected, true);
        return selected;
    }
    if (std.ascii.eqlIgnoreCase(answer, "n")) return selected;

    var tokens = std.mem.tokenizeAny(u8, answer, ", \t");
    while (tokens.next()) |token| {
        const index = try std.fmt.parseUnsigned(usize, token, 10);
        if (index == 0 or index > indices.len) return error.InvalidSkillSelection;
        selected[index - 1] = true;
    }

    return selected;
}

fn printRemovedLinks(
    io: std.Io,
    name: []const u8,
    recorded_links: []const manifest.Link,
    agent_list: []const agents.Agent,
) !void {
    var count: usize = 0;
    for (recorded_links) |link| {
        if (matchesAgentLink(agent_list, link)) count += 1;
    }

    if (count == 0) {
        try io_util.println(io, &.{ "No links changed for ", name });
        return;
    }

    try io_util.println(io, &.{ "Removed ", name, " from:" });
    for (recorded_links) |link| {
        if (!matchesAgentLink(agent_list, link)) continue;
        const display = switch (link.kind) {
            .git => link.path,
            .marketplace, .plugin => link.package,
        };
        try io_util.println(io, &.{ "  - ", link.agent, ": ", display });
    }
}

fn dropRecordedLinks(allocator: std.mem.Allocator, skill: *manifest.Skill, agent_list: []const agents.Agent) !void {
    var kept: std.ArrayList(manifest.Link) = .empty;
    errdefer kept.deinit(allocator);

    for (skill.links) |link| {
        if (matchesAgentLink(agent_list, link)) {
            link.deinit(allocator);
        } else {
            try kept.append(allocator, link);
        }
    }

    const new_links = try kept.toOwnedSlice(allocator);
    allocator.free(skill.links);
    skill.links = new_links;
}

fn removePluginLinksDedup(
    ctx: *Context,
    indices: []const usize,
    selected: []const bool,
    agent_list: []const agents.Agent,
) !void {
    var seen: std.StringHashMap(void) = .init(ctx.allocator);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |k_ptr| {
            ctx.allocator.free(k_ptr.*);
        }
        seen.deinit();
    }

    for (indices, 0..) |index, i| {
        if (!selected[i]) continue;
        for (ctx.manifest.skills[index].links) |link| {
            if (link.kind == .git) continue;
            if (!agents.containsId(agent_list, link.agent)) continue;
            const backend = agents.pluginBackend(agent_list, link.agent) orelse continue;
            const key = try std.fmt.allocPrint(ctx.allocator, "{s}\x00{s}", .{ link.agent, link.package });

            const entry = try seen.getOrPut(key);
            if (entry.found_existing)
                ctx.allocator.free(key)
            else
                plugins.remove(ctx.allocator, ctx.io, backend, link.package) catch |err| {
                    try io_util.eprintln(ctx.io, &.{
                        "warning: failed to remove plugin ", link.package,
                        " for ",                             link.agent,
                        ": ",                                @errorName(err),
                    });
                };
        }
    }
}
