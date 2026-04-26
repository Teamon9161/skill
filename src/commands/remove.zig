const std = @import("std");
const Context = @import("../context.zig").Context;
const cli = @import("../cli.zig");
const agents = @import("../core/agents.zig");
const config = @import("../core/config.zig");
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");

pub fn run(ctx: *Context, target: cli.Target) !void {
    const cfg = try config.load(ctx.allocator, ctx.io, ctx.paths.config, ctx.paths.sources);
    defer cfg.deinit(ctx.allocator);

    const cwd = try paths.cwdAlloc(ctx.allocator, ctx.io);
    defer ctx.allocator.free(cwd);

    const agent_list = try agents.detect(ctx.allocator, ctx.io, ctx.paths.home, cwd, cfg.agents, target.filter);
    defer agents.deinitList(ctx.allocator, agent_list);

    const indices = try manifest.matchSkills(ctx.allocator, ctx.manifest, target.query);
    defer ctx.allocator.free(indices);

    if (indices.len == 0) {
        try std.Io.File.writeStreamingAll(.stderr(), ctx.io, "warning: no installed skills match ");
        try std.Io.File.writeStreamingAll(.stderr(), ctx.io, target.query);
        try std.Io.File.writeStreamingAll(.stderr(), ctx.io, "\n");
        return;
    }

    const selected = try chooseMatches(ctx, indices, target.query);
    defer ctx.allocator.free(selected);

    var changed = false;
    for (indices, 0..) |index, i| {
        if (!selected[i]) continue;
        const skill = &ctx.manifest.skills[index];
        try links.removeRecordedForAgents(ctx.io, skill.links, agent_list);
        try dropRecordedLinks(ctx.allocator, skill, agent_list);
        changed = true;
    }

    if (changed) try ctx.save();
}

fn chooseMatches(ctx: *Context, indices: []const usize, query: []const u8) ![]bool {
    const selected = try ctx.allocator.alloc(bool, indices.len);
    errdefer ctx.allocator.free(selected);

    if (indices.len == 1 or manifest.allSameProject(ctx.manifest, indices, query)) {
        @memset(selected, true);
        return selected;
    }

    @memset(selected, false);
    try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "Matching skills:\n");
    for (indices, 0..) |index, i| {
        const skill = ctx.manifest.skills[index];
        var number: [32]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number, "  {d}. ", .{i + 1});
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, number_text);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, skill.name);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, " from ");
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, skill.project);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "\n");
    }
    try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "Choose numbers to remove, Enter for all, or n to cancel: ");

    var buf: [256]u8 = undefined;
    const answer = try readPromptLine(ctx.io, &buf);
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

fn readPromptLine(io: std.Io, buf: []u8) ![]const u8 {
    var len: usize = 0;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.Io.File.readStreaming(.stdin(), io, &.{byte[0..]}) catch |err| switch (err) {
            error.EndOfStream => return std.mem.trim(u8, buf[0..len], " \t\r\n"),
            else => return err,
        };
        if (n == 0) return std.mem.trim(u8, buf[0..len], " \t\r\n");
        if (byte[0] == '\n') return std.mem.trim(u8, buf[0..len], " \t\r\n");
        if (len == buf.len) return error.InputTooLong;
        buf[len] = byte[0];
        len += 1;
    }
}

fn dropRecordedLinks(allocator: std.mem.Allocator, skill: *manifest.Skill, agent_list: []const agents.Agent) !void {
    var kept: std.ArrayList(manifest.Link) = .empty;
    errdefer kept.deinit(allocator);

    for (skill.links) |link| {
        if (matchesAgentPath(agent_list, link.agent, link.path)) {
            link.deinit(allocator);
        } else {
            try kept.append(allocator, link);
        }
    }

    const new_links = try kept.toOwnedSlice(allocator);
    allocator.free(skill.links);
    skill.links = new_links;
}

fn matchesAgentPath(agent_list: []const agents.Agent, agent_id: []const u8, path: []const u8) bool {
    for (agent_list) |agent| {
        if (std.mem.eql(u8, agent.id, agent_id) and std.mem.startsWith(u8, path, agent.skills)) return true;
    }
    return false;
}
