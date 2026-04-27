#!/usr/bin/env bash
# PeKG PermissionRequest hook for Codex.
# Same shape as Claude Code variant; Codex's permission system uses identical
# hookSpecificOutput envelope.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="codex-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/blockers.sh

allow_passthrough() { exit 0; }

deny() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: { behavior: "deny", message: $r }
    }
  }'
  exit 0
}

main() {
  local input tool session_id
  input=$(cat 2>/dev/null || true)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')

  pekg_load_config
  [ -z "$PEKG_TOKEN" ] && allow_passthrough
  [ -z "$session_id" ] && allow_passthrough
  pekg_is_mutating_tool "$tool" || allow_passthrough

  local state blockers
  state=$(pekg_state_read "$session_id" 2>/dev/null || true)
  [ -z "$state" ] && allow_passthrough

  blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
  if pekg_has_active_blockers "$blockers"; then
    local reason
    reason=$(pekg_format_denial_reason "$blockers")
    deny "$reason"
  fi

  allow_passthrough
}

main
