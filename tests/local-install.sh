#!/usr/bin/env bash
# Local install script for development. Wires the *built dist scripts* into
# ~/.pekg/hooks/ + updates ~/.claude/settings.json + ~/.codex/hooks.json
# without going through the CDN. Used for real-CLI E2E testing.
#
# Usage: bash plugins/tests/local-install.sh
# Idempotent: re-running picks up the latest build output.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOKS_DIR="$HOME/.pekg/hooks"
BIN_DIR="$HOME/.pekg/bin"

bash "$ROOT/build.sh" >/dev/null 2>&1 || { echo "build failed"; exit 1; }

mkdir -p "$HOOKS_DIR" "$BIN_DIR"

# --- Claude Code -------------------------------------------------------------
echo "[local-install] symlinking Claude Code dist scripts → $HOOKS_DIR/"
for f in "$ROOT/claude-code/dist"/*.sh; do
  name=$(basename "$f")
  ln -sf "$f" "$HOOKS_DIR/$name"
done

# Symlink shared connect script.
ln -sf "$ROOT/shared/bin/pekg-connect.sh" "$BIN_DIR/pekg-connect.sh"

# Update ~/.claude/settings.json — strip prior PeKG entries (by /.pekg/hooks/
# substring), then append our 7 entries.
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
jq empty "$SETTINGS" >/dev/null 2>&1 || { echo '{}' > "$SETTINGS"; }

TMP=$(mktemp)
jq '
  if .hooks == null then . + {hooks: {}} else . end
  | .hooks |= (
      to_entries
      | map(.value |= (
          if type == "array" then
            map(.hooks |= (
              if type == "array" then
                map(select((.command // "") | contains("/.pekg/hooks/") | not))
              else . end
            )) | map(select((.hooks // []) | length > 0))
          else . end
        ))
      | from_entries
    )
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"

PEKG_HOOKS=$(cat <<EOF
{
  "SessionStart": [{"matcher":"startup|resume","hooks":[{"type":"command","timeout":15,"command":"$HOOKS_DIR/sessionstart.sh","statusMessage":"Connecting to PeKG..."}]}],
  "UserPromptSubmit": [{"hooks":[{"type":"command","timeout":5,"command":"$HOOKS_DIR/userpromptsubmit.sh","statusMessage":"Loading PeKG context..."}]}],
  "PreToolUse": [{"matcher":"*","hooks":[{"type":"command","timeout":5,"command":"$HOOKS_DIR/pretooluse.sh"}]}],
  "PostToolUse": [{"matcher":"*","hooks":[{"type":"command","timeout":5,"command":"$HOOKS_DIR/posttooluse.sh"}]}],
  "Stop": [{"hooks":[{"type":"command","timeout":5,"command":"$HOOKS_DIR/stop.sh"}]}],
  "PermissionRequest": [{"hooks":[{"type":"command","timeout":5,"command":"$HOOKS_DIR/permissionrequest.sh"}]}],
  "PreCompact": [{"hooks":[{"type":"command","timeout":15,"command":"$HOOKS_DIR/precompact.sh"}]}]
}
EOF
)

jq --argjson p "$PEKG_HOOKS" '
  ($p | to_entries) as $entries
  | reduce $entries[] as $kv (.;
      .hooks[$kv.key] = ((.hooks[$kv.key] // []) + $kv.value)
    )
' "$SETTINGS" > "$TMP" && mv "$TMP" "$SETTINGS"
jq empty "$SETTINGS" >/dev/null 2>&1 || { echo "settings.json invalid after merge"; exit 1; }
echo "[local-install] Claude Code: settings.json updated ($SETTINGS)"

# --- Codex -------------------------------------------------------------------
echo "[local-install] symlinking Codex dist scripts → $HOOKS_DIR/codex-*"
for f in "$ROOT/codex/dist"/*.sh; do
  name=$(basename "$f")
  ln -sf "$f" "$HOOKS_DIR/codex-$name"
done

# Update ~/.codex/config.toml: ensure [features] codex_hooks=true + [mcp_servers.pekg]
# + compact_prompt block between marker comments.
CODEX_CFG="$HOME/.codex/config.toml"
mkdir -p "$HOME/.codex/prompts"
[ -f "$CODEX_CFG" ] || touch "$CODEX_CFG"

PEKG_TOML_BEGIN="# === BEGIN PeKG (auto-managed; do not edit) ==="
PEKG_TOML_END="# === END PeKG (auto-managed; do not edit) ==="

if grep -qF "$PEKG_TOML_BEGIN" "$CODEX_CFG"; then
  awk -v b="$PEKG_TOML_BEGIN" -v e="$PEKG_TOML_END" '
    $0 == b { skip = 1; next }
    skip && $0 == e { skip = 0; next }
    !skip { print }
  ' "$CODEX_CFG" > "${CODEX_CFG}.tmp" && mv "${CODEX_CFG}.tmp" "$CODEX_CFG"
fi

# TOML disallows duplicate section headers. Detect each conflict-prone section
# and either edit-in-place (features) or skip from our managed block (mcp_servers.pekg).
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
  if [ "$HAS_COMPACT_PROMPT" = "1" ]; then
    : # User already set compact_prompt elsewhere; don't override.
  else
    cat <<'TOML_BODY'
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

# Write Codex hooks.json with all 6 hooks.
CODEX_HOOKS_JSON="$HOME/.codex/hooks.json"
jq -n \
  --arg ss "$HOOKS_DIR/codex-sessionstart.sh" \
  --arg ups "$HOOKS_DIR/codex-userpromptsubmit.sh" \
  --arg pre "$HOOKS_DIR/codex-pretooluse.sh" \
  --arg post "$HOOKS_DIR/codex-posttooluse.sh" \
  --arg stop "$HOOKS_DIR/codex-stop.sh" \
  --arg pr "$HOOKS_DIR/codex-permissionrequest.sh" \
  '{hooks:{
    SessionStart:[{matcher:"startup|resume",hooks:[{type:"command",command:$ss,timeout:15,statusMessage:"Connecting to PeKG..."}]}],
    UserPromptSubmit:[{hooks:[{type:"command",command:$ups,timeout:5}]}],
    PreToolUse:[{matcher:"*",hooks:[{type:"command",command:$pre,timeout:5}]}],
    PostToolUse:[{matcher:"*",hooks:[{type:"command",command:$post,timeout:5}]}],
    Stop:[{hooks:[{type:"command",command:$stop,timeout:5}]}],
    PermissionRequest:[{hooks:[{type:"command",command:$pr,timeout:5}]}]
  }}' > "$CODEX_HOOKS_JSON"

cp "$ROOT/codex/prompts/pekg-connect.md" "$HOME/.codex/prompts/pekg-connect.md"
echo "[local-install] Codex: config.toml + hooks.json updated"

echo ""
echo "Local install complete. Hooks point at the live source tree (symlinks)."
echo "  Edit -> bash plugins/build.sh -> changes apply immediately."
echo ""
echo "To test:"
echo "  echo 'hi' | claude -p --output-format stream-json --verbose 2>&1 | head -50"
echo "  echo 'hi' | codex exec --json --skip-git-repo-check 2>&1 | head -50"
echo ""
echo "Backups (pre-port) at:"
ls "$HOME/.claude/settings.json.pre-pekg-port-"* 2>/dev/null || true
ls "$HOME/.codex/hooks.json.pre-pekg-port-"* 2>/dev/null || true
ls "$HOME/.codex/config.toml.pre-pekg-port-"* 2>/dev/null || true
