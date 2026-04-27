#!/usr/bin/env bash
# PeKG installer for Codex CLI.
#
# Public CDN entry: https://api.pekg.ai/plugins/install-codex.sh
# Usage: curl -fsSL https://api.pekg.ai/plugins/install-codex.sh | bash
#
# Idempotent. Re-running upgrades hook scripts and rewrites the PeKG block
# in ~/.codex/config.toml + ~/.codex/hooks.json.

set -euo pipefail

PEKG_API_BASE="${PEKG_API_BASE:-https://api.pekg.ai}"
PEKG_HOOKS_DIR="$HOME/.pekg/hooks"
PEKG_BIN_DIR="$HOME/.pekg/bin"
CODEX_CFG="$HOME/.codex/config.toml"
CODEX_HOOKS_JSON="$HOME/.codex/hooks.json"
CODEX_PROMPTS_DIR="$HOME/.codex/prompts"
INSTALL_VERSION="0.1.0"

log() { printf "[pekg-install] %s\n" "$*"; }
die() { printf "[pekg-install] ERROR: %s\n" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}
require_cmd curl
require_cmd jq

mkdir -p "$PEKG_HOOKS_DIR" "$PEKG_BIN_DIR" "$HOME/.codex" "$CODEX_PROMPTS_DIR"

# 6 hooks for Codex (no PreCompact — Codex has no equivalent hook).
HOOKS=(sessionstart userpromptsubmit pretooluse posttooluse stop permissionrequest)

log "downloading Codex hooks to $PEKG_HOOKS_DIR ..."
for h in "${HOOKS[@]}"; do
  url="$PEKG_API_BASE/plugins/codex/${h}.sh"
  dest="$PEKG_HOOKS_DIR/codex-${h}.sh"
  tmp="${dest}.tmp.$$"
  if curl -fsSL --max-time 15 -o "$tmp" "$url"; then
    chmod +x "$tmp"
    mv "$tmp" "$dest"
    log "  ok  codex-$h"
  else
    rm -f "$tmp"
    die "failed to download $url"
  fi
done

# pekg-connect script.
log "downloading pekg-connect ..."
curl -fsSL --max-time 15 -o "$PEKG_BIN_DIR/pekg-connect.sh" \
  "$PEKG_API_BASE/plugins/shared/bin/pekg-connect.sh"
chmod +x "$PEKG_BIN_DIR/pekg-connect.sh"

# Custom slash prompt.
log "installing /prompts:pekg-connect ..."
curl -fsSL --max-time 15 -o "$CODEX_PROMPTS_DIR/pekg-connect.md" \
  "$PEKG_API_BASE/plugins/codex/prompts/pekg-connect.md" || \
  log "prompt download failed (non-fatal)"

# Enable codex_hooks feature flag in config.toml (idempotent block-replace).
log "ensuring [features] codex_hooks=true in $CODEX_CFG ..."
[ -f "$CODEX_CFG" ] || touch "$CODEX_CFG"

PEKG_TOML_BEGIN="# === BEGIN PeKG (auto-managed; do not edit) ==="
PEKG_TOML_END="# === END PeKG (auto-managed; do not edit) ==="

# Strip prior PeKG block from config.toml.
if grep -qF "$PEKG_TOML_BEGIN" "$CODEX_CFG"; then
  awk -v b="$PEKG_TOML_BEGIN" -v e="$PEKG_TOML_END" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }
  ' "$CODEX_CFG" > "${CODEX_CFG}.tmp" && mv "${CODEX_CFG}.tmp" "$CODEX_CFG"
fi

# TOML disallows duplicate section headers. Detect each conflict-prone section.
HAS_FEATURES_SECTION=0
HAS_MCP_PEKG_SECTION=0
HAS_COMPACT_PROMPT=0
grep -q "^\[features\]" "$CODEX_CFG" && HAS_FEATURES_SECTION=1
grep -q "^\[mcp_servers\.pekg\]" "$CODEX_CFG" && HAS_MCP_PEKG_SECTION=1
grep -q "^compact_prompt" "$CODEX_CFG" && HAS_COMPACT_PROMPT=1

if [ "$HAS_FEATURES_SECTION" = "1" ]; then
  if ! awk '/^\[features\]/{f=1; next} /^\[/{f=0} f && /^codex_hooks[[:space:]]*=[[:space:]]*true/{found=1} END{exit !found}' "$CODEX_CFG"; then
    awk '/^\[features\]/ && !done { print; print "codex_hooks = true"; done=1; next } 1' \
      "$CODEX_CFG" > "${CODEX_CFG}.tmp" && mv "${CODEX_CFG}.tmp" "$CODEX_CFG"
  fi
fi

{
  echo ""
  echo "$PEKG_TOML_BEGIN"
  if [ "$HAS_FEATURES_SECTION" = "0" ]; then
    echo "[features]"
    echo "codex_hooks = true"
    echo ""
  fi
  if [ "$HAS_MCP_PEKG_SECTION" = "0" ]; then
    cat <<'TOML_MCP'
[mcp_servers.pekg]
url = "https://mcp.pekg.ai/mcp"
bearer_token_env_var = "PEKG_TOKEN"

TOML_MCP
  fi
  if [ "$HAS_COMPACT_PROMPT" = "0" ]; then
    cat <<'TOML_BODY'
# A4 partial: instruct Codex's compactor to preserve PeKG state across compaction.
compact_prompt = """
Summarize the visible conversation to free tokens. CRITICAL: at the top of your
summary, preserve a structured PeKG block with these sections (use exactly these
markdown headings):

## Project
## Current Task
## Files Modified
## Files Read
## Failed Approaches (do NOT repeat)
## Active Blockers (must address)

For Active Blockers, list each by quoted title and recommendation. The agent
must reach an explicit acknowledgment of each blocker (quoting the title verbatim
and describing concrete mitigation) before any file-mutating tool will work.
Generic acks like "acknowledged" or "noted" are auto-rejected.

After the PeKG block, summarize the rest of the conversation normally.
"""
TOML_BODY
  fi
  echo "$PEKG_TOML_END"
} >> "$CODEX_CFG"

# Write hooks.json with all 6 hooks.
log "writing $CODEX_HOOKS_JSON ..."
jq -n \
  --arg ss "$PEKG_HOOKS_DIR/codex-sessionstart.sh" \
  --arg ups "$PEKG_HOOKS_DIR/codex-userpromptsubmit.sh" \
  --arg pre "$PEKG_HOOKS_DIR/codex-pretooluse.sh" \
  --arg post "$PEKG_HOOKS_DIR/codex-posttooluse.sh" \
  --arg stop "$PEKG_HOOKS_DIR/codex-stop.sh" \
  --arg pr "$PEKG_HOOKS_DIR/codex-permissionrequest.sh" \
  '{
    hooks: {
      SessionStart: [{
        matcher: "startup|resume",
        hooks: [{type:"command", command:$ss, timeout:15, statusMessage:"Connecting to PeKG..."}]
      }],
      UserPromptSubmit: [{
        hooks: [{type:"command", command:$ups, timeout:5, statusMessage:"Loading PeKG context..."}]
      }],
      PreToolUse: [{
        matcher: "*",
        hooks: [{type:"command", command:$pre, timeout:5}]
      }],
      PostToolUse: [{
        matcher: "*",
        hooks: [{type:"command", command:$post, timeout:5}]
      }],
      Stop: [{
        hooks: [{type:"command", command:$stop, timeout:5}]
      }],
      PermissionRequest: [{
        hooks: [{type:"command", command:$pr, timeout:5}]
      }]
    }
  }' > "$CODEX_HOOKS_JSON"

if ! jq empty "$CODEX_HOOKS_JSON" >/dev/null 2>&1; then
  die "hooks.json validation failed after write"
fi

log "hooks + config installed."

# Run pekg-connect if no token yet.
if [ ! -f "$HOME/.pekg/config.json" ] || ! jq -e '.token' "$HOME/.pekg/config.json" >/dev/null 2>&1; then
  log "running pekg-connect for first-time pairing ..."
  "$PEKG_BIN_DIR/pekg-connect.sh" || log "pekg-connect did not finish; you can run it later via $PEKG_BIN_DIR/pekg-connect.sh"
else
  log "PeKG already configured. Skipping connect."
fi

cat <<EOF

PeKG installer (Codex) v$INSTALL_VERSION done.
  hooks:        $PEKG_HOOKS_DIR/codex-*.sh
  config:       $CODEX_CFG
  hooks.json:   $CODEX_HOOKS_JSON
  prompts:      $CODEX_PROMPTS_DIR/pekg-connect.md
  connect:      $PEKG_BIN_DIR/pekg-connect.sh

Set: export PEKG_TOKEN="\$(jq -r .token ~/.pekg/config.json)"
And restart Codex.
EOF
