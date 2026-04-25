const std = @import("std");
const source_spec = @import("source_spec.zig");

pub const Manifest = struct {
    version: u32 = 1,
    skills: []Skill = &.{},

    pub fn deinit(self: Manifest, allocator: std.mem.Allocator) void {
        for (self.skills) |skill| skill.deinit(allocator);
        allocator.free(self.skills);
    }
};

pub const Skill = struct {
    name: []const u8,
    owner: []const u8,
    project: []const u8,
    source_label: []const u8 = "github",
    source_path: []const u8 = "",
    source: []const u8,
    path: []const u8,
    branch: []const u8 = "",
    commit: []const u8 = "",
    links: []Link = &.{},

    pub fn deinit(self: Skill, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.owner);
        allocator.free(self.project);
        allocator.free(self.source_label);
        allocator.free(self.source_path);
        allocator.free(self.source);
        allocator.free(self.path);
        allocator.free(self.branch);
        allocator.free(self.commit);
        for (self.links) |link| link.deinit(allocator);
        allocator.free(self.links);
    }
};

pub const Link = struct {
    agent: []const u8,
    path: []const u8,
    target: []const u8,

    pub fn deinit(self: Link, allocator: std.mem.Allocator) void {
        allocator.free(self.agent);
        allocator.free(self.path);
        allocator.free(self.target);
    }
};

const DiskManifest = struct {
    version: u32 = 1,
    skills: []DiskSkill = &.{},
};

const DiskSkill = struct {
    name: ?[]const u8 = null,
    owner: []const u8,
    project: []const u8,
    source_label: ?[]const u8 = null,
    source_path: ?[]const u8 = null,
    source: []const u8,
    path: []const u8,
    branch: []const u8 = "",
    commit: []const u8 = "",
    links: []DiskLink = &.{},
};

const DiskLink = struct {
    agent: []const u8,
    path: []const u8,
    target: []const u8,
};

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Manifest {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(10 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(DiskManifest, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    if (parsed.value.version != 1) return error.UnsupportedManifestVersion;

    var skills = try allocator.alloc(Skill, parsed.value.skills.len);
    errdefer allocator.free(skills);
    for (parsed.value.skills, 0..) |disk_skill, i| {
        skills[i] = try cloneSkill(allocator, disk_skill);
    }

    return .{ .version = parsed.value.version, .skills = skills };
}

pub fn save(allocator: std.mem.Allocator, io: std.Io, path: []const u8, value: Manifest) !void {
    const dir_name = std.fs.path.dirname(path) orelse ".";
    try std.Io.Dir.createDirPath(.cwd(), io, dir_name);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &out.writer);
    const json = try out.toOwnedSlice();
    defer allocator.free(json);

    const temp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(temp_path);

    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = temp_path, .data = json });
    try std.Io.Dir.renameAbsolute(temp_path, path, io);
}

pub fn findIndex(value: Manifest, selector: source_spec.Selector) ?usize {
    for (value.skills, 0..) |skill, i| {
        switch (selector) {
            .project => |project| if (std.mem.eql(u8, skill.name, project) or std.mem.eql(u8, skill.project, project)) return i,
            .repo => |repo| if (std.mem.eql(u8, skill.owner, repo.owner) and std.mem.eql(u8, skill.project, repo.project)) return i,
        }
    }
    return null;
}

pub fn findProject(value: Manifest, project: []const u8) ?usize {
    for (value.skills, 0..) |skill, i| {
        if (std.mem.eql(u8, skill.name, project) or std.mem.eql(u8, skill.project, project)) return i;
    }
    return null;
}

pub fn findIdentity(
    value: Manifest,
    source_label: []const u8,
    owner: []const u8,
    project: []const u8,
    source_path: []const u8,
    name: []const u8,
) ?usize {
    for (value.skills, 0..) |skill, i| {
        if (std.mem.eql(u8, skill.source_label, source_label) and
            std.mem.eql(u8, skill.owner, owner) and
            std.mem.eql(u8, skill.project, project) and
            std.mem.eql(u8, skill.source_path, source_path) and
            std.mem.eql(u8, skill.name, name))
        {
            return i;
        }
    }
    return null;
}

pub fn matchSkills(allocator: std.mem.Allocator, value: Manifest, query: []const u8) ![]usize {
    var out: std.ArrayList(usize) = .empty;
    errdefer out.deinit(allocator);

    const exact_project = hasExactProject(value, query);
    for (value.skills, 0..) |skill, i| {
        if (exact_project) {
            if (std.mem.eql(u8, skill.project, query)) try out.append(allocator, i);
            continue;
        }

        if (matches(skill.name, query) or matches(skill.project, query) or matches(skill.source, query)) {
            try out.append(allocator, i);
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn allSameProject(value: Manifest, indices: []const usize, query: []const u8) bool {
    for (indices) |index| {
        if (!std.mem.eql(u8, value.skills[index].project, query)) return false;
    }
    return indices.len != 0;
}

fn hasExactProject(value: Manifest, query: []const u8) bool {
    for (value.skills) |skill| {
        if (std.mem.eql(u8, skill.project, query)) return true;
    }
    return false;
}

fn matches(value: []const u8, query: []const u8) bool {
    return std.mem.indexOf(u8, value, query) != null;
}

pub fn appendSkill(allocator: std.mem.Allocator, value: *Manifest, skill: Skill) !void {
    const new_skills = try allocator.realloc(value.skills, value.skills.len + 1);
    value.skills = new_skills;
    value.skills[value.skills.len - 1] = skill;
}

pub fn removeIndex(allocator: std.mem.Allocator, value: *Manifest, index: usize) void {
    value.skills[index].deinit(allocator);
    std.mem.copyForwards(Skill, value.skills[index..], value.skills[index + 1 ..]);
    value.skills = allocator.realloc(value.skills, value.skills.len - 1) catch value.skills[0 .. value.skills.len - 1];
}

pub fn replaceLinks(allocator: std.mem.Allocator, skill: *Skill, links: []Link) void {
    for (skill.links) |link| link.deinit(allocator);
    allocator.free(skill.links);
    skill.links = links;
}

pub fn replaceLinksForAgents(
    allocator: std.mem.Allocator,
    skill: *Skill,
    agent_list: anytype,
    links: []Link,
) !void {
    var kept: std.ArrayList(Link) = .empty;
    errdefer kept.deinit(allocator);

    for (skill.links) |link| {
        if (agentSelected(agent_list, link.agent)) {
            link.deinit(allocator);
        } else {
            try kept.append(allocator, link);
        }
    }
    try kept.appendSlice(allocator, links);
    const new_links = try kept.toOwnedSlice(allocator);
    allocator.free(skill.links);
    skill.links = new_links;
}

pub fn removeLinkPathFromOthers(
    allocator: std.mem.Allocator,
    value: *Manifest,
    owner_index: usize,
    agent: []const u8,
    path: []const u8,
) !void {
    for (value.skills, 0..) |*skill, i| {
        if (i == owner_index) continue;

        var kept: std.ArrayList(Link) = .empty;
        errdefer kept.deinit(allocator);
        var changed = false;
        for (skill.links) |link| {
            if (std.mem.eql(u8, link.agent, agent) and std.mem.eql(u8, link.path, path)) {
                link.deinit(allocator);
                changed = true;
            } else {
                try kept.append(allocator, link);
            }
        }
        if (!changed) {
            kept.deinit(allocator);
            continue;
        }

        const new_links = try kept.toOwnedSlice(allocator);
        allocator.free(skill.links);
        skill.links = new_links;
    }
}

fn agentSelected(agent_list: anytype, id: []const u8) bool {
    for (agent_list) |agent| {
        if (std.mem.eql(u8, agent.id, id)) return true;
    }
    return false;
}

pub fn setGit(allocator: std.mem.Allocator, skill: *Skill, branch: []const u8, commit: []const u8) !void {
    allocator.free(skill.branch);
    allocator.free(skill.commit);
    skill.branch = try allocator.dupe(u8, branch);
    skill.commit = try allocator.dupe(u8, commit);
}

pub fn newSkill(
    allocator: std.mem.Allocator,
    name: []const u8,
    owner: []const u8,
    project: []const u8,
    source_label: []const u8,
    source_path: []const u8,
    source: []const u8,
    path: []const u8,
) !Skill {
    return .{
        .name = try allocator.dupe(u8, name),
        .owner = try allocator.dupe(u8, owner),
        .project = try allocator.dupe(u8, project),
        .source_label = try allocator.dupe(u8, source_label),
        .source_path = try allocator.dupe(u8, source_path),
        .source = try allocator.dupe(u8, source),
        .path = try allocator.dupe(u8, path),
        .branch = try allocator.dupe(u8, ""),
        .commit = try allocator.dupe(u8, ""),
        .links = &.{},
    };
}

pub fn newLink(allocator: std.mem.Allocator, agent: []const u8, path: []const u8, target: []const u8) !Link {
    return .{
        .agent = try allocator.dupe(u8, agent),
        .path = try allocator.dupe(u8, path),
        .target = try allocator.dupe(u8, target),
    };
}

fn cloneSkill(allocator: std.mem.Allocator, disk: DiskSkill) !Skill {
    var links = try allocator.alloc(Link, disk.links.len);
    errdefer allocator.free(links);
    for (disk.links, 0..) |link, i| {
        links[i] = try newLink(allocator, link.agent, link.path, link.target);
    }

    return .{
        .name = try allocator.dupe(u8, disk.name orelse disk.project),
        .owner = try allocator.dupe(u8, disk.owner),
        .project = try allocator.dupe(u8, disk.project),
        .source_label = try allocator.dupe(u8, disk.source_label orelse "github"),
        .source_path = try allocator.dupe(u8, disk.source_path orelse ""),
        .source = try allocator.dupe(u8, disk.source),
        .path = try allocator.dupe(u8, disk.path),
        .branch = try allocator.dupe(u8, disk.branch),
        .commit = try allocator.dupe(u8, disk.commit),
        .links = links,
    };
}

test "find project" {
    const allocator = std.testing.allocator;
    var m = Manifest{};
    defer m.deinit(allocator);
    try appendSkill(allocator, &m, try newSkill(allocator, "skill", "owner", "project", "github", "", "src", "/tmp/repo"));
    try std.testing.expectEqual(@as(?usize, 0), findProject(m, "project"));
    try std.testing.expectEqual(@as(?usize, 0), findProject(m, "skill"));
    try std.testing.expectEqual(@as(?usize, null), findProject(m, "missing"));
}
