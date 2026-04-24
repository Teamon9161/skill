const std = @import("std");
const Context = @import("../context.zig").Context;
const links = @import("../core/links.zig");
const manifest = @import("../core/manifest.zig");
const paths = @import("../core/paths.zig");
const source_spec = @import("../core/source_spec.zig");

pub fn run(ctx: *Context, selector: source_spec.Selector) !void {
    const index = manifest.findIndex(ctx.manifest, selector) orelse return error.SkillNotFound;
    const skill = ctx.manifest.skills[index];

    try links.removeRecorded(ctx.io, skill.links);
    if (!paths.isInside(ctx.paths.repos, skill.path)) return error.UnsafeDeletePath;
    try std.Io.Dir.deleteTree(.cwd(), ctx.io, skill.path);

    manifest.removeIndex(ctx.allocator, &ctx.manifest, index);
    try ctx.save();
}
