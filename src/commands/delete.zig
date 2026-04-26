const std = @import("std");
const Context = @import("../context.zig").Context;
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");

pub fn run(ctx: *Context, query: []const u8) !void {
    const matched = try manifest.matchSkills(ctx.allocator, ctx.manifest, query);
    defer ctx.allocator.free(matched);

    if (matched.len == 0) return error.SkillNotFound;

    // collect unique repo paths from matched skills
    var repo_paths: std.ArrayList([]const u8) = .empty;
    defer repo_paths.deinit(ctx.allocator);
    for (matched) |i| {
        const path = ctx.manifest.skills[i].path;
        var dup = false;
        for (repo_paths.items) |p| {
            if (std.mem.eql(u8, p, path)) {
                dup = true;
                break;
            }
        }
        if (!dup) try repo_paths.append(ctx.allocator, path);
    }

    // choose which repos to delete when there are multiple
    const selected = try chooseRepos(ctx, repo_paths.items);
    defer ctx.allocator.free(selected);

    var any_selected = false;
    for (selected) |s| {
        if (s) any_selected = true;
    }
    if (!any_selected) return;

    for (repo_paths.items, 0..) |repo_path, r| {
        if (!selected[r]) continue;
        try deleteRepo(ctx, repo_path);
    }

    try ctx.save();
}

fn deleteRepo(ctx: *Context, repo_path: []const u8) !void {
    // collect all skill indices in this repo (including unmatched siblings)
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(ctx.allocator);
    for (ctx.manifest.skills, 0..) |skill, i| {
        if (std.mem.eql(u8, skill.path, repo_path)) {
            try indices.append(ctx.allocator, i);
        }
    }

    for (indices.items) |i| {
        links.removeRecorded(ctx.io, ctx.manifest.skills[i].links) catch |err| switch (err) {
            error.LinkConflict => {},
            else => return err,
        };
    }
    for (indices.items) |i| {
        try printDeletedLinks(ctx.io, ctx.manifest.skills[i]);
    }

    if (!paths.isInside(ctx.paths.repos, repo_path)) return error.UnsafeDeletePath;
    try std.Io.Dir.deleteTree(.cwd(), ctx.io, repo_path);

    // remove from manifest highest-index first to preserve earlier indices
    var j = indices.items.len;
    while (j > 0) {
        j -= 1;
        manifest.removeIndex(ctx.allocator, &ctx.manifest, indices.items[j]);
    }
}

fn chooseRepos(ctx: *Context, repo_paths: []const []const u8) ![]bool {
    const selected = try ctx.allocator.alloc(bool, repo_paths.len);
    errdefer ctx.allocator.free(selected);
    @memset(selected, false);

    if (repo_paths.len == 1) {
        selected[0] = try confirmSingleRepo(ctx, repo_paths[0]);
        return selected;
    }

    try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "Matching repos:\n");
    for (repo_paths, 0..) |repo_path, r| {
        var num_buf: [32]u8 = undefined;
        const num_text = try std.fmt.bufPrint(&num_buf, "  {d}. ", .{r + 1});
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, num_text);
        try printRepoSkillNames(ctx.io, ctx.manifest, repo_path);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "\n");
    }
    try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "Choose numbers to delete, Enter for all, or n to cancel: ");

    var buf: [256]u8 = undefined;
    const answer = try readPromptLine(ctx.io, &buf);
    if (answer.len == 0) {
        @memset(selected, true);
        return selected;
    }
    if (std.ascii.eqlIgnoreCase(answer, "n")) return selected;
    if (std.ascii.eqlIgnoreCase(answer, "all")) {
        @memset(selected, true);
        return selected;
    }

    var tokens = std.mem.tokenizeAny(u8, answer, ", \t");
    while (tokens.next()) |token| {
        const index = try std.fmt.parseUnsigned(usize, token, 10);
        if (index == 0 or index > repo_paths.len) return error.InvalidSkillSelection;
        selected[index - 1] = true;
    }

    return selected;
}

fn confirmSingleRepo(ctx: *Context, repo_path: []const u8) !bool {
    // collect skill names for display
    var first = true;
    for (ctx.manifest.skills) |skill| {
        if (!std.mem.eql(u8, skill.path, repo_path)) continue;
        if (first) {
            try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "Delete ");
        } else {
            try std.Io.File.writeStreamingAll(.stdout(), ctx.io, ", ");
        }
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, skill.name);
        first = false;
    }
    try std.Io.File.writeStreamingAll(.stdout(), ctx.io, " and remove repo from disk? [y/N] ");

    var buf: [16]u8 = undefined;
    const answer = readPromptLine(ctx.io, &buf) catch |err| switch (err) {
        error.EndOfStream => return false,
        else => return err,
    };
    if (answer.len == 0) return false;
    return switch (std.ascii.toLower(answer[0])) {
        'y' => true,
        'n' => false,
        else => error.InvalidConfirmation,
    };
}

fn printRepoSkillNames(io: std.Io, m: manifest.Manifest, repo_path: []const u8) !void {
    var first = true;
    for (m.skills) |skill| {
        if (!std.mem.eql(u8, skill.path, repo_path)) continue;
        if (!first) try std.Io.File.writeStreamingAll(.stdout(), io, ", ");
        try std.Io.File.writeStreamingAll(.stdout(), io, skill.name);
        first = false;
    }
}

fn printDeletedLinks(io: std.Io, skill: manifest.Skill) !void {
    if (skill.links.len == 0) return;
    try std.Io.File.writeStreamingAll(.stdout(), io, "Deleted ");
    try std.Io.File.writeStreamingAll(.stdout(), io, skill.name);
    try std.Io.File.writeStreamingAll(.stdout(), io, " from:\n");
    for (skill.links) |link| {
        try std.Io.File.writeStreamingAll(.stdout(), io, "  - ");
        try std.Io.File.writeStreamingAll(.stdout(), io, link.agent);
        try std.Io.File.writeStreamingAll(.stdout(), io, ": ");
        try std.Io.File.writeStreamingAll(.stdout(), io, link.path);
        try std.Io.File.writeStreamingAll(.stdout(), io, "\n");
    }
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
