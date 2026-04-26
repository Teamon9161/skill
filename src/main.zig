const std = @import("std");
const cli = @import("cli.zig");
const Context = @import("context.zig").Context;

const add = @import("commands/add.zig");
const remove = @import("commands/remove.zig");
const delete_cmd = @import("commands/delete.zig");
const update = @import("commands/update.zig");
const list = @import("commands/list.zig");
const where_cmd = @import("commands/where.zig");
const rebuild = @import("commands/rebuild.zig");
const uninstall = @import("commands/uninstall.zig");
const self_update = @import("commands/self_update.zig");

pub fn main(init: std.process.Init) !u8 {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const command = cli.parse(init, alloc) catch |err| {
        try printError(init.io, err);
        try cli.printUsage(init.io);
        return 1;
    };

    switch (command) {
        .help => {
            try cli.printUsage(init.io);
            return 0;
        },
        .version => {
            try cli.printVersion(init.io);
            return 0;
        },
        .self => |sub| {
            self_update.run(alloc, init.io, init.minimal.environ, sub) catch |err| {
                try printError(init.io, err);
                return 1;
            };
            return 0;
        },
        else => {},
    }

    var ctx = Context.init(alloc, init.io, init.minimal.environ) catch |err| {
        try printError(init.io, err);
        return 1;
    };

    (switch (command) {
        .help => unreachable,
        .version => unreachable,
        .self => unreachable,
        .add => |spec| add.run(&ctx, spec),
        .remove => |target| remove.run(&ctx, target),
        .delete => |selector| delete_cmd.run(&ctx, selector),
        .update => |selector| update.run(&ctx, selector),
        .list => list.run(&ctx),
        .where => |query| where_cmd.run(&ctx, query),
        .rebuild => rebuild.run(&ctx),
        .uninstall => uninstall.run(&ctx),
    }) catch |err| {
        try printError(init.io, err);
        return 1;
    };

    return 0;
}

fn printError(io: std.Io, err: anyerror) !void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "error: {s}\n", .{@errorName(err)}) catch "error\n";
    try std.Io.File.writeStreamingAll(.stderr(), io, msg);
}

test {
    _ = @import("core/source_spec.zig");
    _ = @import("core/paths.zig");
    _ = @import("core/manifest.zig");
}
