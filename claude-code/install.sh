#!/usr/bin/env bash
# PeKG installer for Claude Code.
#
# Public CDN entry: https://api.pekg.ai/plugins/install-claude-code.sh
# Usage: curl -fsSL https://api.pekg.ai/plugins/install-claude-code.sh | bash
#
# Idempotent. Re-running upgrades to the latest hook scripts and replaces the
# PeKG block in ~/.claude/settings.json without touching other tools' hooks.

set -euo pipefail

PEKG_API_BASE="${PEKG_API_BASE:-https://api.pekg.ai}"
PEKG_HOOKS_DIR="$HOME/.pekg/hooks"
PEKG_BIN_DIR="$HOME/.pekg/bin"
CC_SETTINGS="$HOME/.claude/settings.json"
INSTALL_VERSION="0.1.0"

log() { printf "[pekg-install] %s\n" "$*"; }
die() { printf "[pekg-install] ERROR: %s\n" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1 (install $2 first)"
}

require_cmd curl curl
require_cmd jq jq

mkdir -p "$PEKG_HOOKS_DIR" "$PEKG_BIN_DIR" "$HOME/.claude"

# 7 hooks for Claude Code.
HOOKS=(sessionstart userpromptsubmit pretooluse posttooluse stop permissionrequest precompact)

log "downloading hooks to $PEKG_HOOKS_DIR ..."
for h in "${HOOKS[@]}"; do
  url="$PEKG_API_BASE/plugins/claude-code/${h}.sh"
  dest="$PEKG_HOOKS_DIR/${h}.sh"
  tmp="${dest}.tmp.$$"
  if curl -fsSL --max-time 15 -o "$tmp" "$url"; then
    chmod +x "$tmp"
    mv "$tmp" "$dest"
    log "  ok  $h"
  else
    rm -f "$tmp"
    die "failed to download $url"
  fi
done

# Connect script (one-time auth flow).
log "downloading pekg-connect ..."
curl -fsSL --max-time 15 -o "$PEKG_BIN_DIR/pekg-connect.sh" \
  "$PEKG_API_BASE/plugins/shared/bin/pekg-connect.sh"
chmod +x "$PEKG_BIN_DIR/pekg-connect.sh"

# Initialize settings.json if absent / corrupt.
if [ ! -f "$CC_SETTINGS" ]; then
  echo '{}' > "$CC_SETTINGS"
fi
if ! jq empty "$CC_SETTINGS" >/dev/null 2>&1; then
  cp "$CC_SETTINGS" "${CC_SETTINGS}.corrupt.$(date +%s)"
  echo '{}' > "$CC_SETTINGS"
fi

log "merging hook entries into $CC_SETTINGS (idempotent strip + append) ..."
TMP_SETTINGS=$(mktemp)

# Step 1: strip every hook entry whose command path contains "/.pekg/hooks/" — that's our managed set.
jq '
  if .hooks == null then . + {hooks: {}} else . end
  | .hooks |= (
      to_entries
      | map(
          .value |= (
            if type == "array" then
              map(
                .hooks |= (
                  if type == "array" then
                    map(select((.command // "") | contains("/.pekg/hooks/") | not))
                  else . end
                )
              ) | map(select((.hooks // []) | length > 0))
            else . end
          )
        )
      | from_entries
    )
' "$CC_SETTINGS" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$CC_SETTINGS"

# Step 2: build the PeKG hook block as JSON, then merge.
TIMEOUT_FAST=5
TIMEOUT_SLOW=15

PEKG_HOOK_JSON=$(cat <<EOF
{
  "SessionStart": [{
    "matcher": "startup|resume",
    "hooks": [{"type":"command","timeout":$TIMEOUT_SLOW,
      "command":"$PEKG_HOOKS_DIR/sessionstart.sh",
      "statusMessage":"Connecting to PeKG..."}]
  }],
  "UserPromptSubmit": [{
    "hooks": [{"type":"command","timeout":$TIMEOUT_FAST,
      "command":"$PEKG_HOOKS_DIR/userpromptsubmit.sh",
      "statusMessage":"Loading PeKG context..."}]
  }],
  "PreToolUse": [{
    "matcher": "*",
    "hooks": [{"type":"command","timeout":$TIMEOUT_FAST,
      "command":"$PEKG_HOOKS_DIR/pretooluse.sh"}]
  }],
  "PostToolUse": [{
    "matcher": "*",
    "hooks": [{"type":"command","timeout":$TIMEOUT_FAST,
      "command":"$PEKG_HOOKS_DIR/posttooluse.sh"}]
  }],
  "Stop": [{
    "hooks": [{"type":"command","timeout":$TIMEOUT_FAST,
      "command":"$PEKG_HOOKS_DIR/stop.sh"}]
  }],
  "PermissionRequest": [{
    "hooks": [{"type":"command","timeout":$TIMEOUT_FAST,
      "command":"$PEKG_HOOKS_DIR/permissionrequest.sh"}]
  }],
  "PreCompact": [{
    "hooks": [{"type":"command","timeout":$TIMEOUT_SLOW,
      "command":"$PEKG_HOOKS_DIR/precompact.sh"}]
  }]
}
EOF
)

# Step 3: append our entries to each event's array, preserving any other tools' hooks.
jq --argjson pekg "$PEKG_HOOK_JSON" '
  (.hooks // {}) as $existing
  | ($pekg | to_entries) as $entries
  | reduce $entries[] as $kv (.;
      .hooks[$kv.key] = ((.hooks[$kv.key] // []) + $kv.value)
    )
' "$CC_SETTINGS" > "$TMP_SETTINGS" && mv "$TMP_SETTINGS" "$CC_SETTINGS"

# Validate.
if ! jq empty "$CC_SETTINGS" >/dev/null 2>&1; then
  die "settings.json validation failed after merge — restore from backup at ${CC_SETTINGS}.corrupt.*"
fi

log "hooks installed. settings.json valid."

# Run pekg-connect if no token yet.
if [ ! -f "$HOME/.pekg/config.json" ] || ! jq -e '.token' "$HOME/.pekg/config.json" >/dev/null 2>&1; then
  log "running pekg-connect for first-time pairing ..."
  "$PEKG_BIN_DIR/pekg-connect.sh" || log "pekg-connect did not finish; you can run it later via $PEKG_BIN_DIR/pekg-connect.sh"
else
  log "PeKG already configured ($HOME/.pekg/config.json present). Skipping connect."
fi

cat <<EOF

PeKG installer (Claude Code) v$INSTALL_VERSION done.
  hooks:    $PEKG_HOOKS_DIR/
  settings: $CC_SETTINGS
  connect:  $PEKG_BIN_DIR/pekg-connect.sh

Restart Claude Code for the new MCP registration to take effect.
EOF
