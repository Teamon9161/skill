const std = @import("std");

pub const Layout = struct {
    name: []const u8,
    skill_file: []const u8,
    target: []const u8,

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.skill_file);
        allocator.free(self.target);
    }
};

pub fn rootSkill(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !Layout {
    const layouts = try skillLayouts(allocator, io, repo_path, std.fs.path.basename(repo_path));
    defer allocator.free(layouts);
    if (layouts.len != 1) return error.UnsupportedSkillLayout;
    return layouts[0];
}

pub fn skillLayouts(
    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    default_name: []const u8,
) ![]Layout {
    if (try hasSkillFile(io, base_path)) {
        const one = try allocator.alloc(Layout, 1);
        one[0] = try singleLayout(allocator, base_path, default_name);
        return one;
    }

    const skills_dir = try std.fs.path.join(allocator, &.{ base_path, "skills" });
    defer allocator.free(skills_dir);
    std.Io.Dir.accessAbsolute(io, skills_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.UnsupportedSkillLayout,
        else => return err,
    };

    var dir = try std.Io.Dir.openDirAbsolute(io, skills_dir, .{ .iterate = true });
    defer dir.close(io);

    var out: std.ArrayList(Layout) = .empty;
    errdefer {
        for (out.items) |layout| layout.deinit(allocator);
        out.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const target = try std.fs.path.join(allocator, &.{ skills_dir, entry.name });
        defer allocator.free(target);
        if (!try hasSkillFile(io, target)) continue;
        try out.append(allocator, try singleLayout(allocator, target, entry.name));
    }

    if (out.items.len == 0) return error.UnsupportedSkillLayout;
    return out.toOwnedSlice(allocator);
}

fn singleLayout(allocator: std.mem.Allocator, target: []const u8, name: []const u8) !Layout {
    const skill_file = try std.fs.path.join(allocator, &.{ target, "SKILL.md" });
    errdefer allocator.free(skill_file);

    return .{
        .name = try allocator.dupe(u8, name),
        .skill_file = skill_file,
        .target = try allocator.dupe(u8, target),
    };
}

fn hasSkillFile(io: std.Io, target: []const u8) !bool {
    var skill_file_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const skill_file = try std.fmt.bufPrint(&skill_file_buf, "{s}{c}SKILL.md", .{ target, std.fs.path.sep });
    std.Io.Dir.accessAbsolute(io, skill_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}
