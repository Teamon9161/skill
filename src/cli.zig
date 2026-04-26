const std = @import("std");
const clap = @import("clap");
const build_options = @import("build_options");
const source_spec = @import("core/source_spec.zig");
const agents = @import("core/agents.zig");

pub const version = build_options.version;

pub const CommandName = enum { help, add, remove, delete, update, list, where, rebuild, uninstall, version, self };

pub const SelfCommand = enum { update };

pub const Command = union(enum) {
    help,
    add: AddTarget,
    remove: Target,
    delete: []const u8,
    update: ?source_spec.Selector,
    list,
    where: []const u8,
    rebuild,
    uninstall,
    version,
    self: SelfCommand,

    pub fn deinit(self: Command, allocator: std.mem.Allocator) void {
        switch (self) {
            .add => |target| {
                allocator.free(target.input);
                target.filter.deinit(allocator);
            },
            .remove => |target| {
                allocator.free(target.query);
                target.filter.deinit(allocator);
            },
            .where => |query| allocator.free(query),
            .delete => |query| allocator.free(query),
            .update => |maybe| if (maybe) |selector| selector.deinit(allocator),
            else => {},
        }
    }
};

pub const AddTarget = struct {
    input: []const u8,
    filter: agents.AgentFilter,
};

pub const Target = struct {
    query: []const u8,
    filter: agents.AgentFilter,
};

pub fn parse(init: std.process.Init) !Command {
    var iter = try init.minimal.args.iterateAllocator(init.gpa);
    defer iter.deinit();
    _ = iter.next();

    const command = parseCommandName(iter.next() orelse return .help) orelse return error.InvalidCommand;

    return switch (command) {
        .help => .help,
        .add => try parseAdd(init.gpa, init.io, &iter),
        .remove => try parseRemove(init.gpa, init.io, &iter),
        .delete => try parseDelete(init.gpa, init.io, &iter),
        .update => try parseUpdate(init.gpa, init.io, &iter),
        .list => try parseList(init.gpa, init.io, &iter),
        .where => try parseWhere(init.gpa, init.io, &iter),
        .rebuild => try parseRebuild(init.gpa, init.io, &iter),
        .uninstall => try parseUninstall(init.gpa, init.io, &iter),
        .version => .version,
        .self => try parseSelf(init.io, &iter),
    };
}

fn parseCommandName(text: []const u8) ?CommandName {
    if (std.mem.eql(u8, text, "-h") or std.mem.eql(u8, text, "--help") or
        std.mem.eql(u8, text, "-H") or std.mem.eql(u8, text, "help"))
    {
        return .help;
    }
    if (std.mem.eql(u8, text, "-A") or std.mem.eql(u8, text, "add")) return .add;
    if (std.mem.eql(u8, text, "-R") or std.mem.eql(u8, text, "remove")) return .remove;
    if (std.mem.eql(u8, text, "-D") or std.mem.eql(u8, text, "delete")) return .delete;
    if (std.mem.eql(u8, text, "-U") or std.mem.eql(u8, text, "update")) return .update;
    if (std.mem.eql(u8, text, "list")) return .list;
    if (std.mem.eql(u8, text, "where")) return .where;
    if (std.mem.eql(u8, text, "rebuild")) return .rebuild;
    if (std.mem.eql(u8, text, "-V") or std.mem.eql(u8, text, "--version") or
        std.mem.eql(u8, text, "version"))
    {
        return .version;
    }
    if (std.mem.eql(u8, text, "self")) return .self;
    return std.meta.stringToEnum(CommandName, text);
}

fn parseAdd(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
    _ = io;
    const parsed = try parseDynamicAgentArgs(allocator, iter);
    errdefer parsed.deinit(allocator);
    if (parsed.help) {
        parsed.deinit(allocator);
        return .help;
    }
    const input = parsed.value orelse return error.MissingSpec;
    return .{ .add = .{
        .input = try allocator.dupe(u8, input),
        .filter = .{ .ids = parsed.agent_ids, .scope = parsed.scope },
    } };
}

fn parseRemove(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
    _ = io;
    const parsed = try parseDynamicAgentArgs(allocator, iter);
    errdefer parsed.deinit(allocator);
    if (parsed.help) {
        parsed.deinit(allocator);
        return .help;
    }
    const query = parsed.value orelse return error.MissingSelector;
    return .{ .remove = .{
        .query = try allocator.dupe(u8, query),
        .filter = .{ .ids = parsed.agent_ids, .scope = parsed.scope },
    } };
}

const DynamicAgentArgs = struct {
    value: ?[]const u8 = null,
    agent_ids: []const []const u8 = &.{},
    scope: agents.Scope = .global,
    help: bool = false,

    fn deinit(self: DynamicAgentArgs, allocator: std.mem.Allocator) void {
        for (self.agent_ids) |id| allocator.free(id);
        allocator.free(self.agent_ids);
    }
};

fn parseDynamicAgentArgs(
    allocator: std.mem.Allocator,
    iter: *std.process.Args.Iterator,
) !DynamicAgentArgs {
    var ids: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (ids.items) |id| allocator.free(id);
        ids.deinit(allocator);
    }

    var value: ?[]const u8 = null;
    var scope: agents.Scope = .global;
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .{ .help = true, .agent_ids = try ids.toOwnedSlice(allocator) };
        }
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--local")) {
            scope = .local;
            continue;
        }
        if (std.mem.eql(u8, arg, "--agent")) {
            const id = iter.next() orelse return error.MissingAgent;
            try appendUniqueAgent(allocator, &ids, id);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            const id = arg[2..];
            if (id.len == 0) return error.InvalidAgentFlag;
            try appendUniqueAgent(allocator, &ids, id);
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.InvalidAgentFlag;
        if (value != null) return error.TooManyArguments;
        value = arg;
    }

    return .{ .value = value, .agent_ids = try ids.toOwnedSlice(allocator), .scope = scope };
}

fn appendUniqueAgent(allocator: std.mem.Allocator, ids: *std.ArrayList([]const u8), id: []const u8) !void {
    for (ids.items) |existing| {
        if (std.mem.eql(u8, existing, id)) return;
    }
    try ids.append(allocator, try allocator.dupe(u8, id));
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
    const query = res.positionals[0] orelse return error.MissingSelector;
    return .{ .delete = try allocator.dupe(u8, query) };
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

fn parseWhere(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
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
    const query = res.positionals[0] orelse return error.MissingSelector;
    return .{ .where = try allocator.dupe(u8, query) };
}

fn parseSelf(io: std.Io, iter: *std.process.Args.Iterator) !Command {
    const sub = iter.next() orelse {
        try printSelfUsage(io);
        return error.MissingSubcommand;
    };
    if (std.mem.eql(u8, sub, "update")) return .{ .self = .update };
    return error.InvalidCommand;
}

fn printSelfUsage(io: std.Io) !void {
    try std.Io.File.writeStreamingAll(.stderr(), io,
        \\Usage:
        \\  skill self update
        \\
    );
}

fn parseRebuild(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
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
    return .rebuild;
}

fn parseUninstall(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !Command {
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
    return .uninstall;
}

pub fn printUsage(io: std.Io) !void {
    try std.Io.File.writeStreamingAll(.stderr(), io,
        \\Usage:
        \\  skill add|-A [-l|--local] [--<agent>|--agent <id>] <source|path>
        \\  skill remove|-R [-l|--local] <query> [--<agent>|--agent <id>]
        \\  skill delete|-D <query>
        \\  skill update|-U [project|@owner/project]
        \\  skill list
        \\  skill where <query>
        \\  skill rebuild
        \\  skill uninstall
        \\  skill self update
        \\  skill version|-V
        \\  skill help|-H
        \\
        \\Examples:
        \\  skill -A @anthropics/my-skill
        \\  skill -A @anthropics/my-skill -l
        \\  skill -A gitlab@owner/repo/path/to/skill --codex
        \\  skill -A @owner/repo --cursor
        \\  skill -A @owner/repo --agent cursor
        \\  skill -A C:\path\to\skill --claude
        \\  skill -R my-skill --claude
        \\  skill -D @anthropics/my-skill
        \\  skill -U my-skill
        \\  skill list
        \\  skill where lark
        \\  skill -V
        \\  skill uninstall
        \\
    );
}

pub fn printVersion(io: std.Io) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, "skill " ++ version ++ "\n");
}

test "parse command aliases" {
    try std.testing.expectEqual(CommandName.add, parseCommandName("-A").?);
    try std.testing.expectEqual(CommandName.remove, parseCommandName("-R").?);
    try std.testing.expectEqual(CommandName.delete, parseCommandName("-D").?);
    try std.testing.expectEqual(CommandName.update, parseCommandName("-U").?);
    try std.testing.expectEqual(@as(?CommandName, null), parseCommandName("-L"));
    try std.testing.expectEqual(CommandName.where, parseCommandName("where").?);
    try std.testing.expectEqual(CommandName.help, parseCommandName("-H").?);
    try std.testing.expectEqual(CommandName.version, parseCommandName("-V").?);
    try std.testing.expectEqual(CommandName.delete, parseCommandName("delete").?);
    try std.testing.expectEqual(@as(?CommandName, null), parseCommandName("-X"));
}
