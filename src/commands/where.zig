const std = @import("std");
const Context = @import("../context.zig").Context;
const manifest = @import("../core/manifest.zig");
const io_util = @import("io.zig");

pub fn run(ctx: *Context, query: []const u8) !void {
    const indices = try manifest.matchSkills(ctx.allocator, ctx.manifest, query);
    defer ctx.allocator.free(indices);

    if (indices.len == 0) {
        try io_util.eprintln(ctx.io, &.{ "warning: no installed skills match ", query });
        return;
    }

    for (indices) |index| {
        const skill = ctx.manifest.skills[index];
        try io_util.println(ctx.io, &.{ skill.name, " ", skill.project, " ", skill.path });
    }
}
