const std = @import("std");
const Context = @import("../context.zig").Context;
const links = @import("../core/links.zig");
const paths = @import("../core/paths.zig");

pub fn run(ctx: *Context) !void {
    if (ctx.manifest.skills.len == 0) return;

    const delete_downloads = try confirmDeleteDownloads(ctx.io);

    for (ctx.manifest.skills) |*skill| {
        try links.removeRecorded(ctx.io, skill.links);
        clearLinks(ctx.allocator, skill);
    }

    if (delete_downloads) {
        for (ctx.manifest.skills) |skill| {
            if (!paths.isInside(ctx.paths.repos, skill.path)) return error.UnsafeDeletePath;
            try std.Io.Dir.deleteTree(.cwd(), ctx.io, skill.path);
        }
        clearSkills(ctx);
    }

    try ctx.save();
}

fn confirmDeleteDownloads(io: std.Io) !bool {
    try std.Io.File.writeStreamingAll(.stdout(), io, "Delete all downloaded skills? [Y/n] ");

    var buf: [16]u8 = undefined;
    const n = std.Io.File.readStreaming(.stdin(), io, &.{buf[0..]}) catch |err| switch (err) {
        error.EndOfStream => return true,
        else => return err,
    };
    const answer = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (answer.len == 0) return true;

    return switch (std.ascii.toLower(answer[0])) {
        'y' => true,
        'n' => false,
        else => error.InvalidConfirmation,
    };
}

fn clearLinks(allocator: std.mem.Allocator, skill: anytype) void {
    for (skill.links) |link| link.deinit(allocator);
    allocator.free(skill.links);
    skill.links = &.{};
}

fn clearSkills(ctx: *Context) void {
    for (ctx.manifest.skills) |skill| skill.deinit(ctx.allocator);
    ctx.allocator.free(ctx.manifest.skills);
    ctx.manifest.skills = &.{};
}
