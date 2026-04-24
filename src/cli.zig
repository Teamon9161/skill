const std = @import("std");
const clap = @import("clap");
const source_spec = @import("core/source_spec.zig");
const agents = @import("core/agents.zig");

pub const CommandName = enum { help, add, remove, delete, update, list };

pub const Command = union(enum) {
    help,
    add: source_spec.RepoSpec,
    remove: Target,
    delete: source_spec.Selector,
    update: ?source_spec.Selector,
    list,

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        switch (self) {
            .add => |spec| spec.deinit(allocator),
            .remove => |target| target.selector.deinit(allocator),
            .delete => |selector| selector.deinit(allocator),
            .update => |maybe| if (maybe) |selector| selector.deinit(allocator),
            else => {},
        }
    }
};

pub const Target = struct {
    selector: source_spec.Selector,
    filter: agents.AgentFilter,
};

const main_params = clap.parseParamsComptime(
    \\-h, --help  Display help and exit.
    \\<command>
    \\
);

const main_parsers = .{
    .command = clap.parsers.enumeration(CommandName),
};

pub fn parse(init: std.process.Init) !Command {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next();

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = init.gpa,
        .terminating_positional = 0,
    }) catch |err| {
        try diag.reportToFile(init.io, .stderr(), err);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0) return .help;
    const command = res.positionals[0] orelse return .help;

    return switch (command) {
        .help => .help,
        .add => try parseAdd(init.gpa, init.io, &iter),
        .remove => try parseRemove(init.gpa, init.io, &iter),
        .delete => try parseDelete(init.gpa, init.io, &iter),
        .update => try parseUpdate(init.gpa, init.io, &iter),
        .list => try parseList(init.gpa, init.io, &iter),
    };
}

fn parseAdd(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();
    if (res.args.help != 0) return .help;
    const spec = res.positionals[0] orelse return error.MissingSpec;
    return .{ .add = try source_spec.parseRepoSpec(allocator, spec) };
}

fn parseRemove(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display help and exit.
        \\    --claude  Only remove Claude symlink.
        \\    --codex   Only remove Codex symlink.
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();
    if (res.args.help != 0) return .help;
    const selector_text = res.positionals[0] orelse return error.MissingSelector;
    return .{ .remove = .{
        .selector = try source_spec.parseSelector(allocator, selector_text),
        .filter = .{ .claude = res.args.claude != 0, .codex = res.args.codex != 0 },
    } };
}

fn parseDelete(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();
    if (res.args.help != 0) return .help;
    const selector_text = res.positionals[0] orelse return error.MissingSelector;
    return .{ .delete = try source_spec.parseSelector(allocator, selector_text) };
}

fn parseUpdate(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\<str>...
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();
    if (res.args.help != 0) return .help;
    if (res.positionals[0].len > 1) return error.TooManyArguments;
    if (res.positionals[0].len == 0) return .{ .update = null };
    return .{ .update = try source_spec.parseSelector(allocator, res.positionals[0][0]) };
}

fn parseList(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display help and exit.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{ .diagnostic = &diag, .allocator = allocator }) catch |err| {
        try diag.reportToFile(io, .stderr(), err);
        return err;
    };
    defer res.deinit();
    if (res.args.help != 0) return .help;
    return .list;
}

pub fn printUsage(io: std.Io) !void {
    try std.Io.File.writeStreamingAll(.stderr(), io,
        \\Usage:
        \\  skill add <owner>@<project>
        \\  skill remove <project|owner@project> [--claude|--codex]
        \\  skill delete <project|owner@project>
        \\  skill update [project|owner@project]
        \\  skill list
        \\
        \\Examples:
        \\  skill add anthropics@my-skill
        \\  skill remove my-skill --claude
        \\  skill delete anthropics@my-skill
        \\
    );
}
