const std = @import("std");
const paths_mod = @import("core/paths.zig");
const manifest_mod = @import("core/manifest.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: paths_mod.Paths,
    manifest: manifest_mod.Manifest,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env: std.process.Environ) !Context {
        const paths = try paths_mod.init(allocator, env);
        errdefer paths.deinit(allocator);
        const manifest = try manifest_mod.load(allocator, io, paths.manifest);
        return .{
            .allocator = allocator,
            .io = io,
            .paths = paths,
            .manifest = manifest,
        };
    }

    pub fn deinit(self: *Context) void {
        self.manifest.deinit(self.allocator);
        self.paths.deinit(self.allocator);
    }

    pub fn save(self: *Context) !void {
        try manifest_mod.save(self.allocator, self.io, self.paths.manifest, self.manifest);
    }
};
