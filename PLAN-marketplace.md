# Plan: Marketplace / Plugin Support

## Goal

`skill add @owner/repo` auto-detects the install method **per agent** after cloning and
routes each agent to its appropriate flow. Three install kinds:

- `git` — SKILL.md / symlink (current, all agents)
- `marketplace` — agent-specific detection → agent-specific CLI install
- `plugin` — agent-specific detection → agent-specific CLI install (no marketplace step)

Plugin detection and command logic is **built-in per agent** (dispatched by `agent.id`),
not configurable via templates. `AgentDef` in config stays unchanged.

No new CLI flags except `--git`. `remove` / `update` / `list` all branch on the `kind`
field stored per-link in the manifest.

---

## Key Design Decisions

### 1. `kind` lives on `Link`, not `Skill`

The same repo can be installed differently per agent:
- Claude → marketplace (plugin CLI)
- Codex → git (no plugin support yet)

So `kind` must be per-agent (per-link), not per-skill.

**Manifest example:**
```json
{
  "name": "claude-hud",
  "owner": "jarrodwatts",
  "project": "claude-hud",
  "source": "https://github.com/jarrodwatts/claude-hud.git",
  "path": "",
  "links": [
    { "agent": "claude", "kind": "marketplace", "path": "", "target": "" },
    { "agent": "codex",  "kind": "git",         "path": "/home/.../.codex/skills/claude-hud", "target": "/home/.../repos/..." }
  ]
}
```

Old links without `kind` field → default to `"git"` (backward-compatible).

### 2. Plugin logic is built-in, not configurable

Each agent's detection format and CLI commands are hardcoded in `plugins.zig`,
dispatched by `agent.id`. Adding a new agent means adding a new function — no TOML
template complexity, no JSON parsing ambiguity across agents.

### 3. Three-layer install-method control

From lowest to highest precedence:

| Layer | Mechanism | Scope |
|---|---|---|
| Auto-detect | `plugins.detect(agent_id, base_path)` | default |
| Persistent override | `prefer_git` list in `config.toml` | per-project |
| One-time override | `--git` flag | per-command |

---

## File-by-file Changes

### 1. `src/core/manifest.zig`

**Add `Kind` enum and `kind` field to `Link` (not `Skill`):**

```zig
pub const Kind = enum { git, marketplace, plugin };

pub const Link = struct {
    agent: []const u8,
    path: []const u8,    // empty string for marketplace/plugin links
    target: []const u8,  // empty string for marketplace/plugin links
    kind: Kind = .git,   // NEW
};
```

**Add optional `kind` to `DiskLink` (backward-compat):**

```zig
const DiskLink = struct {
    agent: []const u8,
    path: []const u8,
    target: []const u8,
    kind: ?[]const u8 = null,  // NEW — null in old manifests → .git
};
```

**Update link clone helper to parse `disk.kind`:**

```zig
fn cloneLink(allocator, disk: DiskLink) !Link {
    const kind: Kind = blk: {
        const s = disk.kind orelse break :blk .git;
        if (std.mem.eql(u8, s, "marketplace")) break :blk .marketplace;
        if (std.mem.eql(u8, s, "plugin"))      break :blk .plugin;
        break :blk .git;
    };
    return .{
        .agent  = try allocator.dupe(u8, disk.agent),
        .path   = try allocator.dupe(u8, disk.path),
        .target = try allocator.dupe(u8, disk.target),
        .kind   = kind,
    };
}
```

**Add `newPluginLink` helper** (path and target are empty for plugin installs):

```zig
pub fn newPluginLink(allocator, agent: []const u8, kind: Kind) !Link {
    return .{
        .agent  = try allocator.dupe(u8, agent),
        .path   = try allocator.dupe(u8, ""),
        .target = try allocator.dupe(u8, ""),
        .kind   = kind,
    };
}
```

No changes to `Skill` struct.

---

### 2. `src/core/plugins.zig` (new file)

Built-in per-agent plugin detection and CLI dispatch. No TOML config involved.

```zig
pub const Kind = manifest.Kind; // .marketplace or .plugin (not .git)

pub const PluginInfo = struct {
    kind: Kind,
    name: []const u8,  // plugin name for install/remove commands
};

/// Returns null if this agent has no built-in plugin support.
/// Returns null if no plugin manifest is found in base_path.
pub fn detect(allocator, io, agent_id, base_path) !?PluginInfo {
    if (std.mem.eql(u8, agent_id, "claude")) return detectClaude(allocator, io, base_path);
    if (std.mem.eql(u8, agent_id, "codex"))  return detectCodex(allocator, io, base_path);
    return null;
}

pub fn install(allocator, io, agent_id, info: PluginInfo, owner, repo) !void {
    if (std.mem.eql(u8, agent_id, "claude")) return installClaude(allocator, io, info, owner, repo);
    return error.PluginNotSupported;
}

pub fn remove(allocator, io, agent_id, name) !void { ... }
pub fn update(allocator, io, agent_id, info: PluginInfo, owner, repo) !void { ... }
```

**Claude implementation:**

```zig
fn detectClaude(allocator, io, base_path) !?PluginInfo {
    // check .claude-plugin/marketplace.json → .marketplace
    // check .claude-plugin/plugin.json      → .plugin
    // parse JSON, extract "name" field
    // return null if neither file exists
}

fn installClaude(allocator, io, info, owner, repo) !void {
    if (info.kind == .marketplace) {
        // run: claude plugin marketplace add owner/repo
    }
    // run: claude plugin install info.name
}
```

**Codex implementation (stub for now):**

```zig
fn detectCodex(...) !?PluginInfo {
    return null; // not yet supported
}
```

**Before implementing:** confirm exact `claude plugin` subcommand names with
`claude plugin --help`, and inspect `jarrodwatts/claude-hud/.claude-plugin/` to confirm
JSON structure and `"name"` field.

---

### 3. `src/core/config.zig` + `config/defaults.toml`

**Add `prefer_git` list to user config** (persistent per-project git override):

```toml
# $SKILL_HOME/config.toml
prefer_git = ["jarrodwatts/claude-hud", "someone/other-plugin"]
```

```zig
pub const Config = struct {
    // ... existing fields ...
    prefer_git: []const []const u8 = &.{},  // NEW
};

pub fn prefersGit(cfg: Config, owner: []const u8, project: []const u8) bool {
    const needle = std.fmt.allocPrint(..., "{s}/{s}", .{owner, project}) ...;
    // linear scan of prefer_git list
}
```

`AgentDef` is unchanged.

---

### 4. `src/cli.zig`

**Add `--git` flag to `AddTarget`:**

```zig
pub const AddTarget = struct {
    inputs: []const []const u8,
    filter: agents.AgentFilter,
    force_git: bool = false,  // NEW — set by --git flag
};
```

Wire up `--git` in the clap parser.

---

### 5. `src/commands/add.zig`

**Per-agent install routing.** Replace `installRemoteLayouts` with a loop over agents:

```zig
fn installRemoteLayouts(ctx, spec, repo_path, selected_source, agent_list, force_git) !void {
    const base_path = try sourceBasePath(ctx.allocator, repo_path, spec.source_path);
    defer ctx.allocator.free(base_path);

    // Determine install kind per agent, collect for display
    const AgentPlan = struct { agent: Agent, kind: manifest.Kind, info: ?plugins.PluginInfo };
    var plans: []AgentPlan = ...;

    for (agent_list, 0..) |agent, i| {
        const use_git = force_git or cfg.prefersGit(spec.owner, spec.repo);
        const plugin_info = if (!use_git) try plugins.detect(ctx.allocator, ctx.io, agent.id, base_path) else null;
        plans[i] = .{
            .agent = agent,
            .kind  = if (plugin_info) |p| p.kind else .git,
            .info  = plugin_info,
        };
    }

    // Print install plan before executing (告知不问)
    try printInstallPlan(ctx.io, spec, plans, force_git);

    // Execute
    for (plans) |plan| {
        switch (plan.kind) {
            .git => try installGitForAgent(ctx, spec, repo_path, selected_source, base_path, plan.agent),
            .marketplace, .plugin => try installPluginForAgent(ctx, spec, plan.agent, plan.info.?),
        }
    }

    // Delete cloned repo if no agent used git install
    const any_git = for (plans) |p| { if (p.kind == .git) break true; } else false;
    if (!any_git) try deleteRepo(ctx.io, repo_path);
}
```

**`printInstallPlan`** — display before executing (no prompt, just inform):

```
Installing claude-hud:
  claude  → marketplace  (claude plugin marketplace add jarrodwatts/claude-hud)
  codex   → git          (symlink)
Tip: use --git to force symlink for all agents.
```

If `force_git` was passed:
```
Installing claude-hud:
  claude  → git  (--git flag, skipping marketplace)
  codex   → git
```

**`installPluginForAgent`:**
1. Run `plugins.install(agent.id, info, owner, repo)`
2. Find or create manifest `Skill` entry
3. Append `manifest.newPluginLink(agent.id, info.kind)`
4. Print confirmation

**Also apply per-agent detection in `addLocal`.**

---

### 6. `src/commands/remove.zig`

**`filterLinkedMatches`**: plugin links have `path = ""` so the existing path-match check
misses them. Fix — include non-git links that match the agent:

```zig
for (skill.links) |link| {
    const matches = switch (link.kind) {
        .git                   => matchesAgentPath(agent_list, link.agent, link.path),
        .marketplace, .plugin  => agentInList(agent_list, link.agent),
    };
    if (matches) { try out.append(allocator, index); break; }
}
```

**In the removal loop**, branch on `link.kind`:

```zig
switch (link.kind) {
    .git => // existing symlink removal
    .marketplace, .plugin => try plugins.remove(ctx.allocator, ctx.io, link.agent, skill.name),
}
```

---

### 7. `src/commands/update.zig`

**Only call `git.check()`** if there are git-kind links to update:

```zig
if (hasAnyGitLink(ctx.manifest, selectors)) try git.check(ctx.allocator, ctx.io);
```

**In `updateOne`**, branch per link:

```zig
for (skill.links) |link| {
    switch (link.kind) {
        .git => { /* existing git pull + symlink flow */ },
        .marketplace, .plugin => {
            const info = plugins.PluginInfo{ .kind = link.kind, .name = skill.name };
            try plugins.update(ctx.allocator, ctx.io, link.agent, info, skill.owner, skill.project);
        },
    }
}
```

---

### 8. `src/commands/list.zig`

Show per-link kind in the links column:

```
# current:  links=[claude,codex]
# new:       links=[claude(mp),codex]
```

```zig
switch (link.kind) {
    .git         => {},
    .marketplace => try links_buf.appendSlice(allocator, "(mp)"),
    .plugin      => try links_buf.appendSlice(allocator, "(plugin)"),
}
```

---

### 9. `src/commands/delete.zig`

Guard: plugin-only skills have `path = ""`. Skip repo deletion, delegate to remove flow:

```zig
const has_git_links = for (skill.links) |l| { if (l.kind == .git) break true; } else false;
if (!has_git_links) {
    // treat as remove
    return;
}
// existing repo-deletion flow
```

---

## Open Questions (resolve before implementing)

1. **`claude plugin` subcommand names** — verify with `claude plugin --help`:
   - Is it `marketplace add` or `marketplace install`?
   - Does `marketplace update` exist? If not, fall back to re-running add + install.
   - Uninstall subcommand: `plugin remove`? `plugin uninstall`?

2. **`.claude-plugin/` JSON structure** — inspect `jarrodwatts/claude-hud` repo:
   - Exact filename(s) under `.claude-plugin/`
   - Field name for the install name (likely `"name"`)
