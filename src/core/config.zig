const std = @import("std");
const build_options = @import("build_options");

pub const Source = struct {
    label: []const u8,
    url_template: []const u8,

    pub fn deinit(self: Source, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.url_template);
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

const ParseState = struct {
    current_kind: Kind = .none,
    current_id: []const u8 = "",

    const Kind = enum { none, source, agent, aliases, alias };
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
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rest = source.url_template;
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
    var state: ParseState = .{};

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const without_comment = if (std.mem.indexOfScalar(u8, raw_line, '#')) |i| raw_line[0..i] else raw_line;
        const line = std.mem.trim(u8, without_comment, " \t\r\n");
        if (line.len == 0) continue;

        if (line[0] == '[') {
            state = try parseSection(line);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse return error.InvalidConfig;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = try parseString(line[eq + 1 ..]);

        switch (state.current_kind) {
            .none => continue,
            .source => if (std.mem.eql(u8, key, "url")) {
                try putSource(allocator, source_list, state.current_id, value);
            },
            .agent => try putAgentField(allocator, agent_list, state.current_id, key, value),
            .aliases => {
                try validateId(key);
                try putAlias(allocator, alias_list, key, value);
            },
            .alias => if (std.mem.eql(u8, key, "value")) {
                try putAlias(allocator, alias_list, state.current_id, value);
            },
        }
    }
}

fn parseSection(line: []const u8) !ParseState {
    if (line[line.len - 1] != ']') return error.InvalidConfig;
    const section = line[1 .. line.len - 1];
    if (std.mem.startsWith(u8, section, "sources.")) {
        const id = section["sources.".len..];
        try validateId(id);
        return .{ .current_kind = .source, .current_id = id };
    }
    if (std.mem.startsWith(u8, section, "agents.")) {
        const id = section["agents.".len..];
        try validateId(id);
        return .{ .current_kind = .agent, .current_id = id };
    }
    if (std.mem.eql(u8, section, "aliases")) {
        return .{ .current_kind = .aliases };
    }
    if (std.mem.startsWith(u8, section, "aliases.")) {
        const id = section["aliases.".len..];
        try validateId(id);
        return .{ .current_kind = .alias, .current_id = id };
    }
    return .{};
}

fn putSource(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(Source),
    label: []const u8,
    url_template: []const u8,
) !void {
    for (list.items) |*source| {
        if (!std.mem.eql(u8, source.label, label)) continue;
        allocator.free(source.url_template);
        source.url_template = try allocator.dupe(u8, url_template);
        return;
    }

    try list.append(allocator, .{
        .label = try allocator.dupe(u8, label),
        .url_template = try allocator.dupe(u8, url_template),
    });
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

fn putAgentField(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(AgentDef),
    id: []const u8,
    key: []const u8,
    value: []const u8,
) !void {
    const index = try ensureAgent(allocator, list, id);
    const agent = &list.items[index];

    if (std.mem.eql(u8, key, "label")) {
        allocator.free(agent.label);
        agent.label = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "dir")) {
        allocator.free(agent.dir);
        agent.dir = try allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "skills")) {
        allocator.free(agent.skills);
        agent.skills = try allocator.dupe(u8, value);
    }
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

fn parseString(raw: []const u8) ![]const u8 {
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len < 2 or value[0] != '"' or value[value.len - 1] != '"') return error.InvalidConfig;
    const inner = value[1 .. value.len - 1];
    if (std.mem.indexOfAny(u8, inner, "\"\\") != null) return error.InvalidConfig;
    return inner;
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
        \\url = "https://gitlab.com/{owner}/{repo}.git"
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
    const url = try expandUrl(allocator, gitlab, "team", "repo");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://gitlab.com/team/repo.git", url);
    try std.testing.expectEqualStrings("cursor", agent_list.items[0].id);
    try std.testing.expectEqualStrings(".cursor", agent_list.items[0].dir);
    try std.testing.expectEqualStrings("@kromahlusenii-ops/ham", findAlias(alias_list.items, "ham").?.value);
    try std.testing.expectEqualStrings("../demo-skill", findAlias(alias_list.items, "local-demo").?.value);
}
