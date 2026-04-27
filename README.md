# PeKG Plugins

Three host CLIs, one source tree:

```
plugins/
  opencode.ts                 # OpenCode plugin (TypeScript, single file, v3.13.1) — production
  claude-code/
    hooks/                    # source hook scripts with `# @inline` markers
    skills/pekg-connect/      # /pekg-connect Skill
    dist/                     # build output: self-contained scripts (CDN target)
  codex/
    hooks/                    # source hook scripts
    prompts/                  # /prompts:pekg-connect custom prompt
    dist/                     # build output: self-contained scripts (CDN target)
  shared/
    lib/                      # bash helpers — repo source only, never deployed
    bin/                      # one-time install scripts (pekg-connect.sh)
  build.sh                    # bundles `# @inline` markers into self-contained dist/ files
```

## Build

```sh
bash plugins/build.sh
```

Each `# @inline shared/lib/<name>.sh` line in a source hook is replaced with the file's stripped contents. Output lands in `<target>/dist/`. Users only ever curl `dist/` files — they don't touch `shared/` or `hooks/`.

`dist/` is gitignored (root `.gitignore` excludes `dist/`); the CDN deploy step runs `build.sh` on the gateway before serving, so the artefacts are always fresh from source.

## Distribution (planned)

CDN at `api.pekg.ai/plugins/`:

| Target | Install | Update |
|---|---|---|
| OpenCode | `curl -o ~/.config/opencode/plugins/pekg.ts https://api.pekg.ai/plugins/opencode.ts` | Plugin self-fetches on session start (in TS source) |
| Claude Code | `curl -fsSL https://api.pekg.ai/plugins/install-claude-code.sh \| bash` | `SessionStart` hook self-fetches updated dist scripts |
| Codex | `curl -fsSL https://api.pekg.ai/plugins/install-codex.sh \| bash` | `SessionStart` hook self-fetches updated dist scripts |

Single-file install per hook: identical to the OpenCode model (single-file plugin), just multiple files because each Claude Code/Codex hook is its own subprocess.

## Ability coverage (vs OpenCode plugin v3.13.1)

OpenCode plugin abilities A1–A60 catalogued in `docs/plans/PEKG_PLUGIN_MULTI_TARGET_PORT.md`. This README only tracks the host-portable subset. ✅ = covered, ⚠️ = lossy workaround (per plan §6), ❌ = pending implementation.

### Claude Code

| Hook | Abilities covered |
|---|---|
| `SessionStart` (sessionstart.sh) | ✅ A7a rehydrate, A13 auto-update, A14 state envelope, A37/A50 KB health line, A38 cleanup TTL, A45 restart prompt, A48 NETWORK_BLOCKER lifecycle |
| `UserPromptSubmit` (userpromptsubmit.sh) | ✅ A1 context inject, A1b relevance thresholds, A19 dedup, A20 first-message gating, A21/A22/A41 proactive queue drain, A33 guaranteed-blocks, A48 inverse, A55 STOP/friendly banner; ⚠️ A2b "treat as system" prefix |
| `PreToolUse` (pretooluse.sh) | ✅ A5a proactive context fetch on read/grep/glob, A5b blocker gate, A5e idempotent gate, A8 auto-deny, A17 dangerous-bash, legacy status-first gate |
| `PostToolUse` (posttooluse.sh) | ✅ A5c/A6b active-files tracking, A6a tech detection, A24/A53/A100 TECH_PATTERNS, A21/A22 proactive queueing, A36 implicit feedback, status-called marker |
| `Stop` (stop.sh) | ✅ A7c degraded ack detection, A30 deterministic-ack heuristic, A102 KB_INGEST parsing |
| `PreCompact` (precompact.sh) | ✅ A4a structured prompt + A4d cache invalidation; ⚠️ A4b wall-clock impossible (plan §6.3) |
| `PermissionRequest` (permissionrequest.sh) | ✅ A8 auto-deny on mutating tool with active blockers |
| Skill `pekg-connect` | ✅ A47 OTP browser auth flow, A2a/A40 install-time CLAUDE.md write, A55 token save 0600, A56 MCP wiring |
| **Pending** | ❌ A6c BYOLLM feedback verifier (needs `claude -p` subprocess), ❌ A23 task-subagent blocker propagation, ❌ A25 diff queueing for ingest analysis, ❌ A39 deferred-rendering bridge (likely unnecessary on CC) |

### Codex

| Hook | Abilities covered |
|---|---|
| `SessionStart` | ✅ A7a, A13 auto-update, A14, A37/A50, A38, A45, A48 |
| `UserPromptSubmit` | ✅ A1, A1b, A19, A20, A21/A22 drain, A33, A48 inverse, A55; ⚠️ A2b workaround |
| `PreToolUse` | ✅ A5a, A5b, A8, A17 |
| `PostToolUse` | ✅ A5c/A6b on `apply_patch`, A6a tech detection, A21/A22 queueing, A36 implicit feedback |
| `Stop` | ✅ A7c degraded, A30, A102 KB_INGEST |
| `PermissionRequest` | ✅ A8 |
| Custom prompt `pekg-connect` | ✅ A47 + A2a/A40 install-time AGENTS.md write |
| **Pending** | ❌ A6c BYOLLM feedback verifier (needs `codex exec --ephemeral`), ❌ A23, ❌ A25, ❌ A4 PreCompact equivalent (Codex has no hook; only `compact_prompt` config — workaround: pekg-connect can write that at install time) |

## Tests

```sh
bash plugins/tests/run.sh
```

Currently **14 smoke tests, all passing** — covers SessionStart no-token / offline / NETWORK_BLOCKER, PreToolUse blocker gate, dangerous-bash, no-blockers allow, PermissionRequest deny, PreCompact structured prompt, Stop KB_INGEST parsing, Codex SessionStart parity, Codex PreToolUse apply_patch gate.

### Items host-impossible (lossy on Claude Code/Codex per §6 of plan)

- **A2b** mid-session per-message system slot — workaround: `additionalContext` with "treat as system" prefix.
- **A3** message-history rewrite — no host primitive at all.
- **A4b** sub-2s flash compaction wall-clock — workaround: `PreCompact` injects content but LLM still summarizes.
- **A10** dynamic tool description rewrite — workaround: install-time system note + rich deny-reason.

## Local install (developer)

For local hacking, run `build.sh` then symlink `dist/` files to host config dirs:

```sh
# Claude Code
mkdir -p ~/.pekg/hooks
for f in plugins/claude-code/dist/*.sh; do
  ln -sf "$PWD/$f" ~/.pekg/hooks/$(basename "$f")
done
# then update ~/.claude/settings.json hooks block manually

# Codex
mkdir -p ~/.codex/hooks
for f in plugins/codex/dist/*.sh; do
  ln -sf "$PWD/$f" ~/.codex/hooks/$(basename "$f")
done
# then update ~/.codex/hooks.json
```

A proper installer that wires `settings.json` / `hooks.json` automatically is part of the next iteration.

## Testing

```sh
# Syntax check all built artefacts
for f in plugins/*/dist/*.sh plugins/shared/bin/*.sh; do bash -n "$f" || echo "FAIL: $f"; done

# Smoke tests with seeded session state
bash plugins/tests/run.sh   # TODO
```
