const std = @import("std");
const Context = @import("../context.zig").Context;
const agents = @import("../core/agents.zig");
const config = @import("../core/config.zig");
const detect = @import("../core/detect.zig");
const git = @import("../core/git.zig");
const io_util = @import("io.zig");
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");
const plugins = @import("../core/plugins.zig");
const source_spec = @import("../core/source_spec.zig");

pub fn run(ctx: *Context, selectors: []const source_spec.Selector) !void {
    try git.check(ctx.allocator, ctx.io);
    const cfg = try config.load(ctx.allocator, ctx.io, ctx.paths.config, ctx.paths.sources);
    defer cfg.deinit(ctx.allocator);

    if (selectors.len == 0) {
        var failed = false;
        for (ctx.manifest.skills, 0..) |_, i| {
            updateOne(ctx, cfg, i) catch {
                failed = true;
            };
        }
        try ctx.save();
        if (failed) return error.SomeUpdatesFailed;
        return;
    }

    for (selectors) |sel| {
        const index = manifest.findIndex(ctx.manifest, sel) orelse return error.SkillNotFound;
        try updateOne(ctx, cfg, index);
        try syncSiblings(ctx, index);
    }
    try ctx.save();
}

fn updateOne(ctx: *Context, cfg: config.Config, index: usize) !void {
    const skill = &ctx.manifest.skills[index];

    var has_git = false;
    for (skill.links) |link| {
        if (link.kind == .git) has_git = true;
    }

    if (!has_git) {
        // Plugin-only skill. Find the backing git repo (stored path may be ""
        // for entries created before the path-storage fix; fall back to computing
        // the expected path from source metadata).
        const repo_path = try resolvePluginRepoPath(ctx, cfg, skill.*);
        defer if (repo_path) |p| ctx.allocator.free(p);

        if (repo_path) |p| {
            try updatePluginOnly(ctx, cfg, index, p);
        } else {
            // No local repo at all — try the plugin update CLI as a last resort.
            for (skill.links) |link| {
                switch (link.kind) {
                    .git => {},
                    .marketplace, .plugin => {
                        const backend = agentBackend(cfg, link.agent);
                        const info = try makePluginInfo(ctx.allocator, link);
                        defer info.deinit(ctx.allocator);
                        plugins.update(ctx.allocator, ctx.io, backend, info) catch |err| {
                            try io_util.eprintln(ctx.io, &.{
                                "warning: failed to update plugin ", link.package,
                                " for ",                             link.agent,
                                ": ",                                @errorName(err),
                            });
                        };
                    },
                }
            }
            try std.Io.File.writeStreamingAll(.stdout(), ctx.io, skill.name);
            try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "  plugin (no git repo)\n");
        }
        return;
    }

    // Git-linked skill: pull, rediscover layouts, recreate symlinks.
    const source_options = try updateSourceOptions(ctx.allocator, cfg, skill.*);
    const urls = source_options.urls;
    defer config.freeStringList(ctx.allocator, urls);

    const old_commit = try ctx.allocator.dupe(u8, skill.commit);
    defer ctx.allocator.free(old_commit);

    const selected_source = try git.updateAny(ctx.allocator, ctx.io, skill.path, skill.branch, urls, source_options.connect_timeout_seconds);
    defer ctx.allocator.free(selected_source);
    if (selected_source.len != 0) {
        ctx.allocator.free(skill.source);
        skill.source = try ctx.allocator.dupe(u8, selected_source);
    }

    const base_path = if (skill.source_path.len == 0)
        try ctx.allocator.dupe(u8, skill.path)
    else
        try std.fs.path.join(ctx.allocator, &.{ skill.path, skill.source_path });
    defer ctx.allocator.free(base_path);

    const layouts = try detect.skillLayouts(ctx.allocator, ctx.io, base_path, skill.name);
    defer {
        for (layouts) |l| l.deinit(ctx.allocator);
        ctx.allocator.free(layouts);
    }
    const layout = findLayout(layouts, skill.name) orelse return error.UnsupportedSkillLayout;

    const branch = try git.currentBranch(ctx.allocator, ctx.io, skill.path);
    defer ctx.allocator.free(branch);
    const commit = try git.currentCommit(ctx.allocator, ctx.io, skill.path);
    defer ctx.allocator.free(commit);
    try manifest.setGit(ctx.allocator, skill, branch, commit);

    const cwd = try paths.cwdAlloc(ctx.allocator, ctx.io);
    defer ctx.allocator.free(cwd);

    const all_agents = try agents.detect(ctx.allocator, ctx.io, ctx.paths.home, cwd, cfg.agents, .{});
    defer agents.deinitList(ctx.allocator, all_agents);

    // Only rebuild links for agents that have git-kind links in this skill.
    var git_agent_ids: std.ArrayList([]const u8) = .empty;
    defer git_agent_ids.deinit(ctx.allocator);
    for (skill.links) |link| {
        if (link.kind == .git) try git_agent_ids.append(ctx.allocator, link.agent);
    }

    var git_agents: std.ArrayList(agents.Agent) = .empty;
    defer git_agents.deinit(ctx.allocator);
    for (all_agents) |agent| {
        for (git_agent_ids.items) |id| {
            if (std.mem.eql(u8, agent.id, id)) {
                try git_agents.append(ctx.allocator, agent);
                break;
            }
        }
    }

    if (git_agents.items.len > 0) {
        const created_links = try links.createForAgents(ctx.allocator, ctx.io, git_agents.items, skill.name, layout.target, .{ .prompt_conflicts = false });
        try manifest.replaceLinksForAgents(ctx.allocator, skill, git_agents.items, created_links);
        ctx.allocator.free(created_links);
    }

    try printUpdateResult(ctx.io, skill.name, old_commit, commit);
}

// Update a plugin-only skill that has a backing git repo on disk:
// pull the repo, reinstall all plugin links, self-heal the manifest path.
fn updatePluginOnly(ctx: *Context, cfg: config.Config, index: usize, repo_path: []const u8) !void {
    const skill = &ctx.manifest.skills[index];

    const source_options = try updateSourceOptions(ctx.allocator, cfg, skill.*);
    const urls = source_options.urls;
    defer config.freeStringList(ctx.allocator, urls);

    const old_commit = try ctx.allocator.dupe(u8, skill.commit);
    defer ctx.allocator.free(old_commit);

    const selected_source = try git.updateAny(ctx.allocator, ctx.io, repo_path, skill.branch, urls, source_options.connect_timeout_seconds);
    defer ctx.allocator.free(selected_source);
    if (selected_source.len != 0) {
        ctx.allocator.free(skill.source);
        skill.source = try ctx.allocator.dupe(u8, selected_source);
    }

    const branch = try git.currentBranch(ctx.allocator, ctx.io, repo_path);
    defer ctx.allocator.free(branch);
    const commit = try git.currentCommit(ctx.allocator, ctx.io, repo_path);
    defer ctx.allocator.free(commit);
    try manifest.setGit(ctx.allocator, skill, branch, commit);

    // Self-heal: store the real path for old manifest entries that had "".
    if (skill.path.len == 0) {
        ctx.allocator.free(skill.path);
        skill.path = try ctx.allocator.dupe(u8, repo_path);
    }

    // Update plugins using the refreshed repo catalog.
    for (skill.links) |link| {
        switch (link.kind) {
            .git => {},
            .marketplace, .plugin => {
                const backend = agentBackend(cfg, link.agent);
                const info = try makePluginInfo(ctx.allocator, link);
                defer info.deinit(ctx.allocator);
                plugins.update(ctx.allocator, ctx.io, backend, info) catch |err| {
                    try io_util.eprintln(ctx.io, &.{
                        "warning: failed to update plugin ", link.package,
                        " for ",                            link.agent,
                        ": ",                               @errorName(err),
                    });
                };
            },
        }
    }

    try printUpdateResult(ctx.io, skill.name, old_commit, commit);
}

// Resolve the local git repo path for a plugin-only skill.
// Returns null when the repo is not present on disk.
fn resolvePluginRepoPath(ctx: *Context, cfg: config.Config, skill: manifest.Skill) !?[]const u8 {
    if (skill.path.len > 0) {
        std.Io.Dir.accessAbsolute(ctx.io, skill.path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return try ctx.allocator.dupe(u8, skill.path);
    }

    // Old manifest entry with empty path: compute from source metadata.
    const source_options = try updateSourceOptions(ctx.allocator, cfg, skill);
    const urls = source_options.urls;
    defer config.freeStringList(ctx.allocator, urls);
    if (urls.len == 0) return null;

    const computed = try paths.repoPath(ctx.allocator, ctx.paths, skill.owner, skill.project, urls[0]);
    errdefer ctx.allocator.free(computed);

    std.Io.Dir.accessAbsolute(ctx.io, computed, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            ctx.allocator.free(computed);
            return null;
        },
        else => return err,
    };
    return computed;
}

fn makePluginInfo(allocator: std.mem.Allocator, link: manifest.Link) !plugins.PluginInfo {
    return .{
        .kind = link.kind,
        .name = try allocator.dupe(u8, link.package),
        .scope = try allocator.dupe(u8, link.scope),
    };
}

fn agentBackend(cfg: config.Config, agent_id: []const u8) []const u8 {
    if (config.findAgent(cfg, agent_id)) |def| return def.plugin orelse agent_id;
    return agent_id;
}

fn printUpdateResult(io: std.Io, name: []const u8, old_commit: []const u8, new_commit: []const u8) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, name);
    if (std.mem.eql(u8, old_commit, new_commit)) {
        try io_util.println(io, &.{ "  up to date (", new_commit[0..@min(7, new_commit.len)], ")" });
    } else {
        try io_util.println(io, &.{ "  ", old_commit[0..@min(7, old_commit.len)], " -> ", new_commit[0..@min(7, new_commit.len)] });
    }
}

fn syncSiblings(ctx: *Context, updated_index: usize) !void {
    const updated = ctx.manifest.skills[updated_index];
    for (ctx.manifest.skills, 0..) |*skill, i| {
        if (i == updated_index) continue;
        if (!std.mem.eql(u8, skill.path, updated.path)) continue;
        try manifest.setGit(ctx.allocator, skill, updated.branch, updated.commit);
    }
}

fn findLayout(layouts: []const detect.Layout, name: []const u8) ?detect.Layout {
    for (layouts) |layout| {
        if (std.mem.eql(u8, layout.name, name)) return layout;
    }
    return if (layouts.len == 1) layouts[0] else null;
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
