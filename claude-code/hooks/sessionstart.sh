#!/usr/bin/env bash
# PeKG SessionStart hook for Claude Code.
# Abilities: A7a rehydrate, A37/A50 KB health line, A45 token-rotation prompt,
#           A46 init bootstrap, A48 NETWORK_BLOCKER lifecycle, A38 cleanup.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="claude-code-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/blockers.sh
# @inline shared/lib/update.sh
# @inline shared/lib/feedback.sh

main() {
  pekg_load_config

  local input session_id
  input=$(cat 2>/dev/null || true)
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)

  if [ -z "$PEKG_TOKEN" ]; then
    jq -n '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:"pekg: not connected — run /pekg-connect to set up"}}'
    return 0
  fi

  # A7a + A14 + A98: rehydrate persisted state for --continue.
  if [ -n "$session_id" ]; then
    pekg_state_read "$session_id" >/dev/null 2>&1 || true
  fi
  pekg_state_cleanup &  # A38 background cleanup, max 1x/hour

  # A13: self-update check (max 1x/hour). Backgrounded, fire-and-forget.
  ( pekg_maybe_update "claude-code" "$HOME/.pekg/hooks" >/dev/null 2>&1 ) &
  disown 2>/dev/null || true

  # A32: replay queued feedback from prior offline / failed runs.
  ( pekg_feedback_replay >/dev/null 2>&1 ) &
  disown 2>/dev/null || true

  # A37/A50: dashboard stats fetch.
  local stats
  stats=$(pekg_get "/api/v1/dashboard/stats" 3 2>/dev/null || true)

  if [ -z "$stats" ]; then
    # A48: synthesize NETWORK_BLOCKER, persist it for the gate hook to read.
    if [ -n "$session_id" ]; then
      local blockers
      blockers=$(pekg_synth_network_blocker)
      pekg_state_write "$session_id" "{}" "$blockers"
    fi
    local offline_msg="pekg: api unreachable — edits gated; set PEKG_OFFLINE=1 to bypass"
    # A45 + A2d markers should surface even on offline path.
    pekg_append_pending_markers offline_msg
    jq -n --arg m "$offline_msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$m}}'
    return 0
  fi

  local articles pending health actions msg
  articles=$(printf '%s' "$stats" | jq -r '.articleCount // 0')
  pending=$(printf '%s' "$stats" | jq -r '.pendingClusters // 0')
  health=$(printf '%s' "$stats" | jq -r '.healthScore // 0' | awk '{printf "%.0f", $1 * 100}')

  actions=""
  [ "$pending" -gt 0 ] && actions="${actions} ${pending}-pending-compile"
  [ "$articles" -eq 0 ] && actions="${actions} empty-kb-needs-onboarding"

  if [ -n "$actions" ]; then
    msg="pekg: ${articles} articles, health ${health}% — action needed:${actions}. call mcp__pekg__status, then follow CLAUDE.md session-start protocol."
  else
    msg="pekg: ${articles} articles, health ${health}%, healthy — run mcp__pekg__status precheck."
  fi

  # A48 inverse: clear stale NETWORK_BLOCKER if persisted.
  if [ -n "$session_id" ]; then
    local cur task blockers cleaned
    cur=$(pekg_state_read "$session_id" 2>/dev/null || true)
    if [ -n "$cur" ]; then
      task=$(printf '%s' "$cur" | jq -c '.task // {}')
      blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
      cleaned=$(pekg_strip_network_blocker "$blockers")
      pekg_state_write "$session_id" "$task" "$cleaned" || true
    fi
  fi

  pekg_append_pending_markers msg

  jq -n --arg msg "$msg" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$msg}}'
}

# Append A45 (restart prompt) and A2d (update notice) markers to a passed
# variable name (bash nameref). Clears the marker files after surfacing.
# Called from both online and offline SessionStart paths so notices fire
# regardless of API state.
pekg_append_pending_markers() {
  local var_name="$1"
  local current="${!var_name}"

  local restart_marker="$HOME/.pekg/.needs-restart"
  if [ -f "$restart_marker" ]; then
    current="${current}"$'\n\n'"PeKG: configuration changed (token rotated or just installed). Restart Claude Code so the MCP server registration takes effect; until then mcp__pekg__* tools may be unavailable."
    rm -f "$restart_marker" 2>/dev/null || true
  fi

  local update_notice_file="$HOME/.pekg/.update-notice"
  if [ -f "$update_notice_file" ]; then
    local update_notice
    update_notice=$(cat "$update_notice_file" 2>/dev/null || true)
    [ -n "$update_notice" ] && current="${current}"$'\n\n'"$update_notice"
    rm -f "$update_notice_file" 2>/dev/null || true
  fi

  printf -v "$var_name" '%s' "$current"
}

main
