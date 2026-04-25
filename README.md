# skill

`skill` is a local skill manager CLI for agent tools. It installs skills from Git repositories or local directories, links them into detected agent skill folders, and records the installed state in a manifest.

Default supported agents:

- Claude Code
- Codex

Additional agents and sources can be added through configuration.

## Requirements

- Zig `0.16.0` or newer
- Git, required for remote installs and updates

## Build

```powershell
zig build
```

The binary is written to:

```text
zig-out/bin/skill
```

For development:

```powershell
zig build run -- help
zig build test
```

## Usage

```text
skill add|-A [-l|--local] [--<agent>|--agent <id>] <source|path>
skill remove|-R [-l|--local] <query> [--<agent>|--agent <id>]
skill delete|-D <project|@owner/project>
skill update|-U [project|@owner/project]
skill list
skill where <query>
skill uninstall
skill version|-V
skill help|-H
```

## Install Skills

Install from GitHub:

```powershell
skill -A @owner/repo
```

Install a skill from a subdirectory:

```powershell
skill -A @owner/repo/path/to/skill
```

Install from a local directory:

```powershell
skill -A C:\path\to\skill
```

Install only for one agent:

```powershell
skill -A @owner/repo --codex
skill -A @owner/repo --agent claude
```

Install into the current project instead of the user home scope:

```powershell
skill -A @owner/repo --local
```

When no agent is specified, `skill` lists available agents and selects detected agent directories by default.

## Manage Skills

List installed skills:

```powershell
skill list
```

Find installed skills by name, project, or source:

```powershell
skill where lark
```

Remove links from agent skill folders while keeping the downloaded copy:

```powershell
skill -R my-skill --codex
```

Delete a downloaded remote skill and remove it from the manifest:

```powershell
skill -D @owner/project
```

Update all remote skills:

```powershell
skill -U
```

Update one skill:

```powershell
skill -U my-skill
```

Remove all recorded links. The command asks whether downloaded copies should also be deleted:

```powershell
skill uninstall
```

## Source Syntax

GitHub is the default remote source:

```text
@owner/repo
@owner/repo/path/to/skill
```

Configured sources can be used with an explicit source label:

```text
gitlab@owner/repo/path/to/skill
```

Inputs without `@` are treated as local paths or aliases.

## Skill Layout

`skill` supports a single skill directory:

```text
my-skill/
  SKILL.md
```

It also supports repositories containing multiple skills:

```text
repo/
  skills/
    first-skill/
      SKILL.md
    second-skill/
      SKILL.md
```

Each child directory under `skills/` that contains `SKILL.md` is installed as one skill.

## Configuration

The data directory is resolved in this order:

1. `SKILL_HOME`
2. `XDG_DATA_HOME/skill`
3. `~/.local/share/skill`

Main files inside the data directory:

- `manifest.json`
- `repos/`
- `config.toml`
- `sources.toml`, kept for legacy source configuration

Example `config.toml`:

```toml
[sources.gitlab]
url = "https://gitlab.com/{owner}/{repo}.git"

[agents.cursor]
label = "Cursor"
dir = ".cursor"
skills = "skills"

[aliases]
demo = "@owner/repo/path/to/skill"

[aliases.local-demo]
value = "C:/path/to/demo-skill"
```

Agent paths are relative to the selected scope unless absolute paths are used. Global scope resolves relative agent directories from the user home. Local scope resolves them from the current working directory.

## Behavior Notes

- Remote installs use shallow Git clones.
- Updates fetch the recorded branch or `HEAD`, then reset to `FETCH_HEAD`.
- Installed skills are exposed through directory links.
- On Windows, `skill` falls back to junctions if directory symlinks are not allowed.
- `delete` only removes downloaded paths inside `repos/`; local skills are not deleted through that command.
