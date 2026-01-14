# claude-config

A personal Claude Code plugin for managing custom skills, commands, and agents.

## Overview

This plugin provides a centralized repository for your Claude-related configuration, making it easy to:
- Manage custom slash commands
- Organize specialized agents
- Define reusable skills
- Share configurations across different projects

## Installation

### From Local Directory

1. Clone this repository:
```bash
git clone <your-repo-url> ~/.claude/plugins/claude-config
```

2. Add to your Claude Code settings (`.claude/settings.json`):
```json
{
  "plugins": [
    "claude-config"
  ]
}
```

### From Remote Repository

Add the plugin marketplace to your settings:
```json
{
  "marketplaces": [
    "<your-github-repo-url>"
  ]
}
```

Then install via Claude Code:
```
/plugin install claude-config
```

## Structure

```
claude-config/
├── .claude-plugin/
│   └── plugin.json      # Plugin metadata
├── bin/                # Utility scripts
│   └── statusline-command.sh  # Custom statusline for Claude Code
├── commands/            # Custom slash commands
│   └── hello.md        # Example command
├── agents/             # Specialized agents
├── skills/             # Reusable skills
└── README.md           # This file
```

## Usage

### Commands

All markdown files in the `commands/` directory are automatically available as slash commands:
```
/claude-config:command-name [arguments]
```

Example:
```
/claude-config:hello
```

### Agents

Agents defined in the `agents/` directory can be invoked for specialized tasks.

### Skills

Skills in the `skills/` directory activate automatically based on task context.

### Statusline

The plugin includes a custom statusline command in `bin/statusline-command.sh` that displays:
- Current directory and git branch status
- Model name and context usage
- Cache efficiency
- Cost tracking
- Lines added/removed
- Session duration

To use it, configure your Claude Code statusline settings to point to this script.

## Adding Your Own Content

### Add a Command

Create a new `.md` file in the `commands/` directory:

```markdown
---
description: "Description of what this command does"
arguments: "arg1 arg2"
---

# Your command implementation here
```

### Add an Agent

Create a new `.md` file in the `agents/` directory:

```markdown
---
name: "agent-name"
description: "What this agent does"
version: "1.0.0"
---

# Agent instructions here
```

### Add a Skill

Create a `SKILL.md` file in the `skills/` directory (or subdirectory):

```markdown
---
name: "skill-name"
description: "What this skill does"
version: "1.0.0"
---

# Skill implementation here
```

## License

MIT
