const std = @import("std");
const config = @import("config.zig");

pub const Agent = struct {
    id: []const u8,
    base: []const u8,
    skills: []const u8,
    plugin: ?[]const u8 = null,
    plugin_dir: ?[]const u8 = null,
    // Borrowed from the config def (outlives the Agent), like `plugin`.
    // `dir` is the repo-relative harness dir (e.g. ".claude") used to locate
    // harness-specific sub-agent sources; `agents` is the sub-agent subdir name.
    dir: []const u8 = "",
    agents: ?[]const u8 = null,

    pub fn deinit(self: Agent, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        allocator.free(self.skills);
    }
};

pub const Candidate = struct {
    id: []const u8,
    label: []const u8,
    base: []const u8,
    skills: []const u8,
    exists: bool,
    plugin: ?[]const u8 = null,
    plugin_dir: ?[]const u8 = null,
    dir: []const u8 = "",
    agents: ?[]const u8 = null,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.base);
        allocator.free(self.skills);
    }
};

pub const AgentFilter = struct {
    ids: []const []const u8 = &.{},
    scope: Scope = .global,

    pub fn deinit(self: AgentFilter, allocator: std.mem.Allocator) void {
        for (self.ids) |id| allocator.free(id);
        allocator.free(self.ids);
    }

    pub fn matches(self: AgentFilter, id: []const u8) bool {
        if (self.ids.len == 0) return true;
        for (self.ids) |selected| {
            if (std.mem.eql(u8, selected, id)) return true;
        }
        return false;
    }

    pub fn hasAny(self: AgentFilter) bool {
        return self.ids.len != 0;
    }
};

pub const Scope = enum { global, local };

pub fn detect(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    cwd: []const u8,
    defs: []const config.AgentDef,
    filter: AgentFilter,
) ![]Agent {
    var list: std.ArrayList(Agent) = .empty;
    errdefer {
        for (list.items) |agent| agent.deinit(allocator);
        list.deinit(allocator);
    }

    for (defs) |def| {
        try maybeAdd(allocator, io, &list, home, cwd, def, filter);
    }

    return list.toOwnedSlice(allocator);
}

pub fn candidates(
    allocator: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    cwd: []const u8,
    defs: []const config.AgentDef,
    scope: Scope,
) ![]Candidate {
    var list: std.ArrayList(Candidate) = .empty;
    errdefer {
        for (list.items) |candidate| candidate.deinit(allocator);
        list.deinit(allocator);
    }

    for (defs) |def| {
        try addCandidate(allocator, io, &list, home, cwd, def, scope);
    }
    return list.toOwnedSlice(allocator);
}

pub fn deinitCandidates(allocator: std.mem.Allocator, list: []Candidate) void {
    for (list) |candidate| candidate.deinit(allocator);
    allocator.free(list);
}

pub fn fromCandidates(
    allocator: std.mem.Allocator,
    candidate_list: []const Candidate,
    selected: []const bool,
) ![]Agent {
    var list: std.ArrayList(Agent) = .empty;
    errdefer {
        for (list.items) |agent| agent.deinit(allocator);
        list.deinit(allocator);
    }

    for (candidate_list, 0..) |candidate, i| {
        if (!selected[i]) continue;
        try list.append(allocator, .{
            .id = candidate.id,
            .base = try allocator.dupe(u8, candidate.base),
            .skills = try allocator.dupe(u8, candidate.skills),
            .plugin = candidate.plugin,
            .plugin_dir = candidate.plugin_dir,
            .dir = candidate.dir,
            .agents = candidate.agents,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn deinitList(allocator: std.mem.Allocator, list: []Agent) void {
    for (list) |agent| agent.deinit(allocator);
    allocator.free(list);
}

pub fn containsId(list: []const Agent, id: []const u8) bool {
    for (list) |agent| {
        if (std.mem.eql(u8, agent.id, id)) return true;
    }
    return false;
}

/// Returns the plugin backend binary name for the agent, or null if the agent
/// has no plugin support or is not in the list.
pub fn pluginBackend(list: []const Agent, id: []const u8) ?[]const u8 {
    for (list) |agent| {
        if (std.mem.eql(u8, agent.id, id)) return agent.plugin;
    }
    return null;
}

fn maybeAdd(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayList(Agent),
    home: []const u8,
    cwd: []const u8,
    def: config.AgentDef,
    filter: AgentFilter,
) !void {
    if (!filter.matches(def.id)) return;

    const base = try agentBase(allocator, scopeRoot(home, cwd, filter.scope), def.dir);
    errdefer allocator.free(base);
    std.Io.Dir.accessAbsolute(io, base, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(base);
            return;
        },
        else => return err,
    };

    const skills = try agentSkills(allocator, base, def.skills);
    errdefer allocator.free(skills);
    try list.append(allocator, .{ .id = def.id, .base = base, .skills = skills, .plugin = def.plugin, .plugin_dir = def.plugin_dir, .dir = def.dir, .agents = def.agents });
}

fn addCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    list: *std.ArrayList(Candidate),
    home: []const u8,
    cwd: []const u8,
    def: config.AgentDef,
    scope: Scope,
) !void {
    const base = try agentBase(allocator, scopeRoot(home, cwd, scope), def.dir);
    errdefer allocator.free(base);
    const exists = blk: {
        std.Io.Dir.accessAbsolute(io, base, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => return err,
        };
        break :blk true;
    };

    const skills = try agentSkills(allocator, base, def.skills);
    errdefer allocator.free(skills);
    try list.append(allocator, .{ .id = def.id, .label = def.label, .base = base, .skills = skills, .exists = exists, .plugin = def.plugin, .plugin_dir = def.plugin_dir, .dir = def.dir, .agents = def.agents });
}

fn scopeRoot(home: []const u8, cwd: []const u8, scope: Scope) []const u8 {
    return switch (scope) {
        .global => home,
        .local => cwd,
    };
}

fn agentBase(allocator: std.mem.Allocator, home: []const u8, dir: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(dir)) return allocator.dupe(u8, dir);
    return std.fs.path.join(allocator, &.{ home, dir });
}

fn agentSkills(allocator: std.mem.Allocator, base: []const u8, skills: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(skills)) return allocator.dupe(u8, skills);
    return std.fs.path.join(allocator, &.{ base, skills });
}

pub fn selectInteractive(
    allocator: std.mem.Allocator,
    io: std.Io,
    candidate_list: []const Candidate,
    filter: AgentFilter,
    initial_selected: ?[]const bool,
) ![]bool {
    const selected = try allocator.alloc(bool, candidate_list.len);
    errdefer allocator.free(selected);

    if (filter.hasAny()) {
        var count: usize = 0;
        for (candidate_list, 0..) |candidate, i| {
            selected[i] = filter.matches(candidate.id);
            if (selected[i]) count += 1;
        }
        if (count == 0) return error.UnknownAgent;
        return selected;
    }

    for (candidate_list, 0..) |candidate, i| {
        const init = if (initial_selected) |s| s[i] else true;
        selected[i] = candidate.exists and init;
    }

    // Partition candidates so the main prompt only lists harnesses whose
    // config dir actually exists on this machine. The rest stay hidden behind
    // an "Other" option so the prompt doesn't grow unwieldy as we support more
    // harnesses. When nothing is detected we fall back to showing everything.
    var detected: std.ArrayList(usize) = .empty;
    defer detected.deinit(allocator);
    var undetected: std.ArrayList(usize) = .empty;
    defer undetected.deinit(allocator);
    for (candidate_list, 0..) |candidate, i| {
        if (candidate.exists) try detected.append(allocator, i) else try undetected.append(allocator, i);
    }

    const primary: []const usize = if (detected.items.len == 0) undetected.items else detected.items;
    const hidden: []const usize = if (detected.items.len == 0) &.{} else undetected.items;

    try printAgentPrompt(io, candidate_list, selected, initial_selected, primary, hidden.len);

    var buf: [256]u8 = undefined;
    var stash: []const u8 = &.{};
    const answer = (try readNextLine(io, &buf, &stash)) orelse return selected;
    if (answer.len == 0) return selected;

    @memset(selected, false);
    var want_other = false;
    try parseSelection(candidate_list, selected, answer, primary, hidden.len, &want_other);

    if (want_other and hidden.len > 0) {
        try printHiddenPrompt(io, candidate_list, hidden);
        if (try readNextLine(io, &buf, &stash)) |answer2| {
            if (answer2.len != 0) {
                try parseSelection(candidate_list, selected, answer2, hidden, 0, &want_other);
            }
        }
    }

    return selected;
}

// Read one line from stdin. A single readStreaming can return several lines at
// once (e.g. piped input), so we buffer the remainder in `stash` and hand it
// back a line at a time before reading again. Returns null at end of input.
fn readNextLine(io: std.Io, buf: []u8, stash: *[]const u8) !?[]const u8 {
    if (stash.len == 0) {
        const n = std.Io.File.readStreaming(.stdin(), io, &.{buf}) catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        if (n == 0) return null;
        stash.* = buf[0..n];
    }
    const rest = stash.*;
    if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
        stash.* = rest[nl + 1 ..];
        return std.mem.trim(u8, rest[0..nl], " \t\r");
    }
    stash.* = &.{};
    return std.mem.trim(u8, rest, " \t\r\n");
}

// Parse a comma/space separated selection line. Numbers index into `menu`
// (1-based); names match any candidate by id or label. When `other_index` is
// non-zero the number `menu.len + 1` (or the word "other") sets `want_other`.
fn parseSelection(
    candidate_list: []const Candidate,
    selected: []bool,
    answer: []const u8,
    menu: []const usize,
    hidden_count: usize,
    want_other: *bool,
) !void {
    var tokens = std.mem.tokenizeAny(u8, answer, ", \t");
    while (tokens.next()) |token| {
        if (std.fmt.parseUnsigned(usize, token, 10)) |index| {
            if (index == 0) return error.InvalidAgentSelection;
            if (index <= menu.len) {
                selected[menu[index - 1]] = true;
                continue;
            }
            if (hidden_count > 0 and index == menu.len + 1) {
                want_other.* = true;
                continue;
            }
            return error.InvalidAgentSelection;
        } else |_| {}

        if (hidden_count > 0 and std.ascii.eqlIgnoreCase(token, "other")) {
            want_other.* = true;
            continue;
        }

        var matched = false;
        for (candidate_list, 0..) |candidate, i| {
            if (std.ascii.eqlIgnoreCase(token, candidate.id) or std.ascii.eqlIgnoreCase(token, candidate.label)) {
                selected[i] = true;
                matched = true;
            }
        }
        if (!matched) return error.InvalidAgentSelection;
    }
}

fn printAgentPrompt(
    io: std.Io,
    candidate_list: []const Candidate,
    selected: []const bool,
    initial_selected: ?[]const bool,
    primary: []const usize,
    hidden_count: usize,
) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, "Available agents:\n");
    for (primary, 0..) |idx, pos| {
        const candidate = candidate_list[idx];
        try std.Io.File.writeStreamingAll(.stdout(), io, if (selected[idx]) "  [+] " else "  [ ] ");
        var number: [32]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number, "{d}. ", .{pos + 1});
        try std.Io.File.writeStreamingAll(.stdout(), io, number_text);
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.label);
        try std.Io.File.writeStreamingAll(.stdout(), io, " (");
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.base);
        try std.Io.File.writeStreamingAll(.stdout(), io, ")");
        if (selected[idx]) {
            try std.Io.File.writeStreamingAll(.stdout(), io, " default");
        } else if (initial_selected != null and !initial_selected.?[idx] and candidate.exists) {
            try std.Io.File.writeStreamingAll(.stdout(), io, " not supported");
        } else if (!candidate.exists) {
            try std.Io.File.writeStreamingAll(.stdout(), io, " not detected");
        }
        try std.Io.File.writeStreamingAll(.stdout(), io, "\n");
    }
    if (hidden_count > 0) {
        var line: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&line, "  [ ] {d}. Other ({d} not detected on this machine)\n", .{ primary.len + 1, hidden_count });
        try std.Io.File.writeStreamingAll(.stdout(), io, text);
    }
    try std.Io.File.writeStreamingAll(.stdout(), io, "Enter numbers or ids to override. ");
    try printDefaultSelection(io, candidate_list, selected);
    try std.Io.File.writeStreamingAll(.stdout(), io, ": ");
}

fn printHiddenPrompt(io: std.Io, candidate_list: []const Candidate, hidden: []const usize) !void {
    try std.Io.File.writeStreamingAll(.stdout(), io, "Not detected on this machine:\n");
    for (hidden, 0..) |idx, pos| {
        const candidate = candidate_list[idx];
        var number: [32]u8 = undefined;
        const number_text = try std.fmt.bufPrint(&number, "  {d}. ", .{pos + 1});
        try std.Io.File.writeStreamingAll(.stdout(), io, number_text);
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.label);
        try std.Io.File.writeStreamingAll(.stdout(), io, " (");
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.base);
        try std.Io.File.writeStreamingAll(.stdout(), io, ")\n");
    }
    try std.Io.File.writeStreamingAll(.stdout(), io, "Enter numbers or ids to add (Enter to skip): ");
}

fn printDefaultSelection(io: std.Io, candidate_list: []const Candidate, selected: []const bool) !void {
    var any = false;
    try std.Io.File.writeStreamingAll(.stdout(), io, "Press Enter for default");
    for (candidate_list, 0..) |candidate, i| {
        if (!selected[i]) continue;
        try std.Io.File.writeStreamingAll(.stdout(), io, if (any) ", " else " ");
        try std.Io.File.writeStreamingAll(.stdout(), io, candidate.id);
        any = true;
    }
    if (!any) try std.Io.File.writeStreamingAll(.stdout(), io, " none");
}
