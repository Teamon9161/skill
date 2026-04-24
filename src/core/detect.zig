const std = @import("std");

pub const Layout = struct {
    skill_file: []const u8,
    target: []const u8,

    pub fn deinit(self: Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_file);
        allocator.free(self.target);
    }
};

pub fn rootSkill(allocator: std.mem.Allocator, io: std.Io, repo_path: []const u8) !Layout {
    const skill_file = try std.fs.path.join(allocator, &.{ repo_path, "SKILL.md" });
    errdefer allocator.free(skill_file);
    std.Io.Dir.accessAbsolute(io, skill_file, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.UnsupportedSkillLayout,
        else => return err,
    };

    return .{
        .skill_file = skill_file,
        .target = try allocator.dupe(u8, repo_path),
    };
}
