const std = @import("std");
const Context = @import("../context.zig").Context;
const manifest = @import("../core/manifest.zig");

pub fn run(ctx: *Context, query: []const u8) !void {
    const indices = try manifest.matchSkills(ctx.allocator, ctx.manifest, query);
    defer ctx.allocator.free(indices);

    if (indices.len == 0) {
        try std.Io.File.writeStreamingAll(.stderr(), ctx.io, "warning: no installed skills match ");
        try std.Io.File.writeStreamingAll(.stderr(), ctx.io, query);
        try std.Io.File.writeStreamingAll(.stderr(), ctx.io, "\n");
        return;
    }

    for (indices) |index| {
        const skill = ctx.manifest.skills[index];
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, skill.name);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, " ");
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, skill.project);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, " ");
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, skill.path);
        try std.Io.File.writeStreamingAll(.stdout(), ctx.io, "\n");
    }
}
