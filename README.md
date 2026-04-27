# PeKG Plugins

Official plugins to connect your AI coding agent to [PeKG](https://pekg.ai) - the personal knowledge graph that makes your agent smarter across all your projects.

## What is PeKG?

PeKG builds a cross-project knowledge graph from your coding sessions. When you fix a bug, discover a gotcha, or learn something new, PeKG captures it and surfaces it back when relevant - even in different projects.

**Key features:**
- **Cross-project learning** - Knowledge from Project A helps you in Project B
- **Blocker enforcement** - Known gotchas are surfaced before you hit them
- **BYOLLM** - Your agent does all the work, PeKG just stores and retrieves
- **Multi-agent support** - Works with OpenCode, Claude Code, Codex, Cursor, and more

## Supported Agents

| Agent | Plugin Type | Install |
|-------|-------------|---------|
| **OpenCode** | TypeScript plugin | `curl -o ~/.config/opencode/plugins/pekg.ts https://api.pekg.ai/plugins/opencode.ts` |
| **Claude Code** | Bash hooks | `curl -fsSL https://api.pekg.ai/plugins/claude-code/install.sh \| bash` |
| **Codex** | Bash hooks | `curl -fsSL https://api.pekg.ai/plugins/codex/install.sh \| bash` |

Or just ask your agent: *"Read https://pekg.ai/llms.txt and set up PeKG"*

## How It Works

1. **Install** - One command or just ask your agent to read `https://pekg.ai/llms.txt`
2. **Connect** - Agent calls `pekg_connect` tool, browser opens for Google sign-in
3. **Code** - Work normally. The plugin tracks context and extracts knowledge
4. **Learn** - PeKG compiles patterns, gotchas, and decisions into your knowledge base
5. **Recall** - Relevant knowledge is injected into future sessions automatically

### Blocker System

When PeKG detects you're about to hit a known issue, it injects a **blocker** that must be acknowledged before file-mutating tools (edit, write, etc.) are allowed. This prevents you from repeating past mistakes.

```
<pekg-active-blockers>
- Deploy Gotcha: SCP files get wiped by git pull + pnpm build
</pekg-active-blockers>
```

You acknowledge by describing your concrete mitigation in the chat, then tools unblock.

## Repository Structure

```
opencode/          # TypeScript plugin (single file)
claude-code/       # Bash hooks for Claude Code
  hooks/           # Individual lifecycle hooks
  skills/          # /pekg-connect skill
codex/             # Bash hooks for Codex CLI
  hooks/           # Individual lifecycle hooks
  prompts/         # Custom prompts
shared/            # Common bash libraries
tests/             # Smoke tests
build.sh           # Builds dist/ from source hooks
```

## Development

### Building

```bash
bash build.sh
```

This inlines `shared/lib/*.sh` into each hook script, producing self-contained files in `*/dist/`.

### Testing

```bash
bash tests/run.sh
```

14 smoke tests covering all major hooks and edge cases.

### Local Install (Dev)

```bash
# OpenCode
cp opencode/opencode.ts ~/.config/opencode/plugins/pekg.ts

# Claude Code (after build)
mkdir -p ~/.pekg/hooks
cp claude-code/dist/*.sh ~/.pekg/hooks/
# Then wire in ~/.claude/settings.json

# Codex (after build)
mkdir -p ~/.codex/hooks
cp codex/dist/*.sh ~/.codex/hooks/
# Then wire in ~/.codex/hooks.json
```

## Links

- **Website**: https://pekg.ai
- **Dashboard**: https://app.pekg.ai

## License

MIT
