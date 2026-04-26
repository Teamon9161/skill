const std = @import("std");
const build_options = @import("build_options");
const toml = @import("toml");

pub const default_connect_timeout_seconds: u32 = 8;

pub const Source = struct {
    label: []const u8,
    url_templates: []const []const u8,
    connect_timeout_seconds: u32 = default_connect_timeout_seconds,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        freeStringList(allocator, self.url_templates);
    }
};

pub const AgentDef = struct {
    id: []const u8,
    label: []const u8,
    dir: []const u8,
    skills: []const u8,

    pub fn deinit(self: AgentDef, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.label);
        allocator.free(self.dir);
        allocator.free(self.skills);
    }
};

pub const Alias = struct {
    name: []const u8,
    value: []const u8,

    pub fn deinit(self: Alias, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.value);
    }
};

pub const Config = struct {
    sources: []Source = &.{},
    agents: []AgentDef = &.{},
    aliases: []Alias = &.{},

    pub fn deinit(self: Config, allocator: std.mem.Allocator) void {
        for (self.sources) |source| source.deinit(allocator);
        allocator.free(self.sources);
        for (self.agents) |agent| agent.deinit(allocator);
        allocator.free(self.agents);
        for (self.aliases) |alias| alias.deinit(allocator);
        allocator.free(self.aliases);
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    config_path: []const u8,
    legacy_sources_path: []const u8,
) !Config {
    var source_list: std.ArrayList(Source) = .empty;
    var agent_list: std.ArrayList(AgentDef) = .empty;
    var alias_list: std.ArrayList(Alias) = .empty;
    errdefer {
        for (source_list.items) |source| source.deinit(allocator);
        source_list.deinit(allocator);
        for (agent_list.items) |agent| agent.deinit(allocator);
        agent_list.deinit(allocator);
        for (alias_list.items) |alias| alias.deinit(allocator);
        alias_list.deinit(allocator);
    }

    try parseTomlSubset(allocator, build_options.default_config, &source_list, &agent_list, &alias_list);
    try parseFileIfExists(allocator, io, config_path, &source_list, &agent_list, &alias_list);
    try parseFileIfExists(allocator, io, legacy_sources_path, &source_list, &agent_list, &alias_list);

    return .{
        .sources = try source_list.toOwnedSlice(allocator),
        .agents = try agent_list.toOwnedSlice(allocator),
        .aliases = try alias_list.toOwnedSlice(allocator),
    };
}

pub fn findSource(list: []const Source, label: []const u8) ?Source {
    for (list) |source| {
        if (std.mem.eql(u8, source.label, label)) return source;
    }
    return null;
}

pub fn findAlias(list: []const Alias, name: []const u8) ?Alias {
    for (list) |alias| {
        if (std.mem.eql(u8, alias.name, name)) return alias;
    }
    return null;
}

pub fn expandUrl(
    allocator: std.mem.Allocator,
    source: Source,
    owner: []const u8,
    repo: []const u8,
) ![]const u8 {
    if (source.url_templates.len == 0) return error.InvalidConfig;
    return expandUrlTemplate(allocator, source.url_templates[0], owner, repo);
}

pub fn expandUrls(
    allocator: std.mem.Allocator,
    source: Source,
    owner: []const u8,
    repo: []const u8,
) ![]const []const u8 {
    if (source.url_templates.len == 0) return error.InvalidConfig;

    var out: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (out.items) |url| allocator.free(url);
        out.deinit(allocator);
    }

    for (source.url_templates) |template| {
        try out.append(allocator, try expandUrlTemplate(allocator, template, owner, repo));
    }

    return out.toOwnedSlice(allocator);
}

pub fn freeStringList(allocator: std.mem.Allocator, list: []const []const u8) void {
    if (list.len == 0) return;
    for (list) |value| allocator.free(value);
    allocator.free(list);
}

fn expandUrlTemplate(
    allocator: std.mem.Allocator,
    url_template: []const u8,
    owner: []const u8,
    repo: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rest = url_template;
    while (rest.len != 0) {
        if (std.mem.startsWith(u8, rest, "{owner}")) {
            try out.appendSlice(allocator, owner);
            rest = rest["{owner}".len..];
        } else if (std.mem.startsWith(u8, rest, "{repo}")) {
            try out.appendSlice(allocator, repo);
            rest = rest["{repo}".len..];
        } else {
            try out.append(allocator, rest[0]);
            rest = rest[1..];
        }
    }

    return out.toOwnedSlice(allocator);
}

fn parseFileIfExists(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    source_list: *std.ArrayList(Source),
    agent_list: *std.ArrayList(AgentDef),
    alias_list: *std.ArrayList(Alias),
) !void {
    const bytes = std.Io.Dir.readFileAlloc(.cwd(), io, path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer allocator.free(bytes);
    try parseTomlSubset(allocator, bytes, source_list, agent_list, alias_list);
}

fn parseTomlSubset(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    source_list: *std.ArrayList(Source),
    agent_list: *std.ArrayList(AgentDef),
    alias_list: *std.ArrayList(Alias),
) !void {
    var parser = toml.Parser(toml.Table).init(allocator);
    defer parser.deinit();

    const parsed = parser.parseString(bytes) catch return error.InvalidConfig;
    defer parsed.deinit();

    try mergeTomlRoot(allocator, parsed.value, source_list, agent_list, alias_list);
}

fn mergeTomlRoot(
    allocator: std.mem.Allocator,
    root: toml.Table,
    source_list: *std.ArrayList(Source),
    agent_list: *std.ArrayList(AgentDef),
    alias_list: *std.ArrayList(Alias),
) !void {
    if (root.get("sources")) |value| switch (value) {
        .table => |table| try mergeSources(allocator, table, source_list),
        else => return error.InvalidConfig,
    };
    if (root.get("agents")) |value| switch (value) {
        .table => |table| try mergeAgents(allocator, table, agent_list),
        else => return error.InvalidConfig,
    };
    if (root.get("aliases")) |value| switch (value) {
        .table => |table| try mergeAliases(allocator, table, alias_list),
        else => return error.InvalidConfig,
    };
}

fn mergeSources(
    allocator: std.mem.Allocator,
    table: *toml.Table,
    source_list: *std.ArrayList(Source),
) !void {
    var it = table.iterator();
    while (it.next()) |entry| {
        const label = entry.key_ptr.*;
        try validateId(label);
        const source_table = switch (entry.value_ptr.*) {
            .table => |value| value,
            else => return error.InvalidConfig,
        };

        if (source_table.get("url")) |value| {
            const url = try expectString(value);
            const urls = [_][]const u8{url};
            try putSourceUrls(allocator, source_list, label, urls[0..]);
        }

        if (source_table.get("urls")) |value| {
            var urls: std.ArrayList([]const u8) = .empty;
            defer urls.deinit(allocator);
            try appendStringArray(allocator, &urls, value);
            try putSourceUrls(allocator, source_list, label, urls.items);
        }

        if (source_table.get("timeout")) |value| {
            try putSourceTimeout(allocator, source_list, label, try expectU32(value));
        }
    }
}

fn mergeAgents(
    allocator: std.mem.Allocator,
    table: *toml.Table,
    agent_list: *std.ArrayList(AgentDef),
) !void {
    var it = table.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        try validateId(id);
        const agent_table = switch (entry.value_ptr.*) {
            .table => |value| value,
            else => return error.InvalidConfig,
        };

        const index = try ensureAgent(allocator, agent_list, id);
        const agent = &agent_list.items[index];

        if (agent_table.get("label")) |value| {
            allocator.free(agent.label);
            agent.label = try allocator.dupe(u8, try expectString(value));
        }
        if (agent_table.get("dir")) |value| {
            allocator.free(agent.dir);
            agent.dir = try allocator.dupe(u8, try expectString(value));
        }
        if (agent_table.get("skills")) |value| {
            allocator.free(agent.skills);
            agent.skills = try allocator.dupe(u8, try expectString(value));
        }
    }
}

fn mergeAliases(
    allocator: std.mem.Allocator,
    table: *toml.Table,
    alias_list: *std.ArrayList(Alias),
) !void {
    var it = table.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        try validateId(name);
        switch (entry.value_ptr.*) {
            .string => |value| try putAlias(allocator, alias_list, name, value),
            .table => |alias_table| {
                const value = alias_table.get("value") orelse return error.InvalidConfig;
                try putAlias(allocator, alias_list, name, try expectString(value));
            },
            else => return error.InvalidConfig,
        }
    }
}

fn expectString(value: toml.Value) ![]const u8 {
    return switch (value) {
        .string => |string| string,
        else => error.InvalidConfig,
    };
}

fn expectU32(value: toml.Value) !u32 {
    const int = switch (value) {
        .integer => |integer| integer,
        else => return error.InvalidConfig,
    };
    if (int <= 0 or int > std.math.maxInt(u32)) return error.InvalidConfig;
    return @intCast(int);
}

fn appendStringArray(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), value: toml.Value) !void {
    const array = switch (value) {
        .array => |array| array,
        else => return error.InvalidConfig,
    };
    for (array.items) |item| {
        try out.append(allocator, try expectString(item));
    }
}

fn putSourceUrls(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Source),
    label: []const u8,
    url_templates: []const []const u8,
) !void {
    if (url_templates.len == 0) return error.InvalidConfig;

    const index = try ensureSource(allocator, list, label);
    const source = &list.items[index];
    const new_templates = try dupeStringList(allocator, url_templates);
    freeStringList(allocator, source.url_templates);
    source.url_templates = new_templates;
}

fn putSourceTimeout(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Source),
    label: []const u8,
    seconds: u32,
) !void {
    if (seconds == 0) return error.InvalidConfig;
    const index = try ensureSource(allocator, list, label);
    list.items[index].connect_timeout_seconds = seconds;
}

fn ensureSource(allocator: std.mem.Allocator, list: *std.ArrayList(Source), label: []const u8) !usize {
    for (list.items, 0..) |source, i| {
        if (std.mem.eql(u8, source.label, label)) return i;
    }

    try list.append(allocator, .{
        .label = try allocator.dupe(u8, label),
        .url_templates = &.{},
        .connect_timeout_seconds = default_connect_timeout_seconds,
    });
    return list.items.len - 1;
}

fn dupeStringList(allocator: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    var out = try allocator.alloc([]const u8, list.len);
    errdefer allocator.free(out);

    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |value| allocator.free(value);
    }

    for (list, 0..) |value, i| {
        out[i] = try allocator.dupe(u8, value);
        initialized += 1;
    }
    return out;
}

fn putAlias(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Alias),
    name: []const u8,
    value: []const u8,
) !void {
    for (list.items) |*alias| {
        if (!std.mem.eql(u8, alias.name, name)) continue;
        allocator.free(alias.value);
        alias.value = try allocator.dupe(u8, value);
        return;
    }

    try list.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .value = try allocator.dupe(u8, value),
    });
}

fn ensureAgent(allocator: std.mem.Allocator, list: *std.ArrayList(AgentDef), id: []const u8) !usize {
    for (list.items, 0..) |agent, i| {
        if (std.mem.eql(u8, agent.id, id)) return i;
    }

    try list.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .label = try allocator.dupe(u8, id),
        .dir = try allocator.dupe(u8, id),
        .skills = try allocator.dupe(u8, "skills"),
    });
    return list.items.len - 1;
}

fn validateId(id: []const u8) !void {
    if (id.len == 0) return error.InvalidConfig;
    for (id) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') continue;
        return error.InvalidConfig;
    }
}

test "merge config sources and agents" {
    const allocator = std.testing.allocator;
    var source_list: std.ArrayList(Source) = .empty;
    var agent_list: std.ArrayList(AgentDef) = .empty;
    var alias_list: std.ArrayList(Alias) = .empty;
    defer {
        for (source_list.items) |source| source.deinit(allocator);
        source_list.deinit(allocator);
        for (agent_list.items) |agent| agent.deinit(allocator);
        agent_list.deinit(allocator);
        for (alias_list.items) |alias| alias.deinit(allocator);
        alias_list.deinit(allocator);
    }

    try parseTomlSubset(allocator,
        \\[sources.gitlab]
        \\timeout = 3
        \\urls = [
        \\  "https://gitlab.com/{owner}/{repo}.git",
        \\  "https://mirror.example/{owner}/{repo}.git",
        \\]
        \\
        \\[agents.cursor]
        \\label = "Cursor"
        \\dir = ".cursor"
        \\skills = "skills"
        \\
        \\[aliases]
        \\ham = "@kromahlusenii-ops/ham"
        \\
        \\[aliases.local-demo]
        \\value = "../demo-skill"
        \\
    , &source_list, &agent_list, &alias_list);

    const gitlab = findSource(source_list.items, "gitlab").?;
    try std.testing.expectEqual(@as(u32, 3), gitlab.connect_timeout_seconds);
    const urls = try expandUrls(allocator, gitlab, "team", "repo");
    defer freeStringList(allocator, urls);
    try std.testing.expectEqualStrings("https://gitlab.com/team/repo.git", urls[0]);
    try std.testing.expectEqualStrings("https://mirror.example/team/repo.git", urls[1]);
    try std.testing.expectEqualStrings("cursor", agent_list.items[0].id);
    try std.testing.expectEqualStrings(".cursor", agent_list.items[0].dir);
    try std.testing.expectEqualStrings("@kromahlusenii-ops/ham", findAlias(alias_list.items, "ham").?.value);
    try std.testing.expectEqualStrings("../demo-skill", findAlias(alias_list.items, "local-demo").?.value);
}
