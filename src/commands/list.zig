const std = @import("std");
const Context = @import("../context.zig").Context;

pub fn run(ctx: *Context) !void {
    for (ctx.manifest.skills) |skill| {
        const text = try line(ctx.allocator, skill);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, text);
        ctx.allocator.free(text);
    }
}

fn line(allocator: std.mem.Allocator, skill: anytype) ![]const u8 {
    var links_buf: std.ArrayList(u8) = .empty;
    defer links_buf.deinit(allocator);
    for (skill.links, 0..) |link, i| {
        if (i != 0) try links_buf.append(allocator, ',');
        try links_buf.appendSlice(allocator, link.agent);
    }

    return std.fmt.allocPrint(allocator, "@{s}/{s} {s} links=[{s}] path={s}\n", .{
        skill.owner,
        skill.project,
        skill.commit,
        links_buf.items,
        skill.path,
    });
}
