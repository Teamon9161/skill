const std = @import("std");
const manifest = @import("manifest.zig");

pub const Kind = manifest.Kind;

pub const PluginInfo = struct {
    kind: Kind,
    name: []const u8,
    scope: []const u8,

    pub fn deinit(self: PluginInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.scope);
    }
};

const PluginJson = struct {
    name: []const u8,
    scope: ?[]const u8 = null,
};

pub fn detect(allocator: std.mem.Allocator, io: std.Io, plugin_dir_name: []const u8, base_path: []const u8) !?PluginInfo {
    const plugin_dir = try std.fs.path.join(allocator, &.{ base_path, plugin_dir_name });
    defer allocator.free(plugin_dir);

    const marketplace_path = try std.fs.path.join(allocator, &.{ plugin_dir, "marketplace.json" });
    defer allocator.free(marketplace_path);

    const is_marketplace = blk: {
        std.Io.Dir.accessAbsolute(io, marketplace_path, .{}) catch break :blk false;
        break :blk true;
    };

    const plugin_path = try std.fs.path.join(allocator, &.{ plugin_dir, "plugin.json" });
    defer allocator.free(plugin_path);

    if (readPluginJson(allocator, io, plugin_path)) |json| {
        return .{
            .kind = if (is_marketplace) .marketplace else .plugin,
            .name = json.name,
            .scope = json.scope orelse "",
        };
    } else |_| {}

    if (is_marketplace) {
        if (readMarketplaceJson(allocator, io, marketplace_path)) |name_opt| {
            if (name_opt) |name| {
                return .{ .kind = .marketplace, .name = name, .scope = "" };
            }
        } else |_| {}
    }

    return null;
}

fn readPluginJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !PluginJson {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(PluginJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const name = try allocator.dupe(u8, parsed.value.name);
    errdefer allocator.free(name);
    const scope = if (parsed.value.scope) |s| try allocator.dupe(u8, s) else null;
    return .{ .name = name, .scope = scope };
}

fn readMarketplaceJson(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !?[]const u8 {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const MpJson = struct {
        plugins: []const struct {
            name: []const u8,
        },
    };

    var parsed = try std.json.parseFromSlice(MpJson, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.plugins.len > 0) {
        return try allocator.dupe(u8, parsed.value.plugins[0].name);
    }
    return null;
}

pub fn install(
    allocator: std.mem.Allocator,
    io: std.Io,
    backend: []const u8,
    info: PluginInfo,
    repo_path: []const u8,
) !void {
    if (info.kind == .marketplace) {
        // const mp_id = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ owner, repo });
        // defer allocator.free(mp_id);

        const result = try runPluginCli(allocator, io, backend, &.{ "plugin", "marketplace", "add", repo_path }, null);
        result.deinit(allocator);
    }

    var args = try std.ArrayList([]const u8).initCapacity(allocator, 6);
    defer args.deinit(allocator);
    try args.appendSlice(allocator, &.{ "plugin", "install", info.name });
    if (info.scope.len > 0) {
        try args.appendSlice(allocator, &.{ "--scope", info.scope });
    }

    const result = try runPluginCli(allocator, io, backend, args.items, null);
    result.deinit(allocator);
}

pub fn remove(allocator: std.mem.Allocator, io: std.Io, backend: []const u8, name: []const u8) !void {
    const result = try runPluginCli(allocator, io, backend, &.{ "plugin", "remove", name }, null);
    result.deinit(allocator);
}

pub fn update(allocator: std.mem.Allocator, io: std.Io, backend: []const u8, info: PluginInfo) !void {
    const result = try runPluginCli(allocator, io, backend, &.{ "plugin", "update", info.name }, null);
    result.deinit(allocator);
}

const RunResult = struct {
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

fn runPluginCli(allocator: std.mem.Allocator, io: std.Io, backend: []const u8, subcommand: []const []const u8, cwd: ?[]const u8) !RunResult {
    var args = try std.ArrayList([]const u8).initCapacity(allocator, subcommand.len + 1);
    defer args.deinit(allocator);
    try args.append(allocator, backend);
    try args.appendSlice(allocator, subcommand);

    const result = try std.process.run(allocator, io, .{
        .argv = args.items,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
        .expand_arg0 = .expand,
    });
    errdefer allocator.free(result.stdout);
    errdefer allocator.free(result.stderr);

    const failed = switch (result.term) {
        .exited => |code| code != 0,
        else => true,
    };
    if (failed) {
        if (result.stderr.len > 0) {
            std.Io.File.writeStreamingAll(.stderr(), io, result.stderr) catch {};
        }
        return error.PluginCommandFailed;
    }

    return .{ .stdout = result.stdout, .stderr = result.stderr };
}
