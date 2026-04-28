#!/usr/bin/env bash
# PeKG SessionStart hook for Codex.
# Same surface as the Claude Code variant; only difference is User-Agent string.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="codex-pekg-plugin"

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
    jq -n '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:"pekg: not connected — run /prompts:pekg-connect to set up"}}'
    return 0
  fi

  # A7a + A14 + A98: rehydrate persisted state for resume.
  if [ -n "$session_id" ]; then
    pekg_state_read "$session_id" >/dev/null 2>&1 || true
  fi
  pekg_state_cleanup &  # A38 background cleanup

  # A13: self-update check.
  ( pekg_maybe_update "codex" "$HOME/.pekg/hooks" >/dev/null 2>&1 ) &
  disown 2>/dev/null || true

  # A32: replay queued feedback.
  ( pekg_feedback_replay >/dev/null 2>&1 ) &
  disown 2>/dev/null || true

  local stats
  stats=$(pekg_get "/api/v1/dashboard/stats" 3 2>/dev/null || true)

  if [ -z "$stats" ]; then
    # A48 revised (2026-04-27): fail-open. Strip stale NETWORK_BLOCKER and
    # let the session run unblocked — context enrichment is lost this turn,
    # but edits aren't gated by network state.
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
    local offline_msg
    if pekg_offline; then
      offline_msg="pekg: offline mode (PEKG_OFFLINE=1) — context disabled this session"
    else
      offline_msg="pekg: api unreachable — context disabled this session, edits not gated"
    fi
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
    msg="pekg: ${articles} articles, health ${health}% — action needed:${actions}. Call pekg_status, then follow AGENTS.md session-start protocol."
  else
    msg="pekg: ${articles} articles, health ${health}%, healthy — call pekg_status precheck."
  fi

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

pekg_append_pending_markers() {
  local var_name="$1"
  local current="${!var_name}"
  local restart_marker="$HOME/.pekg/.needs-restart"
  if [ -f "$restart_marker" ]; then
    current="${current}"$'\n\n'"PeKG: configuration changed. Restart Codex so the MCP server registration takes effect; until then pekg_* tools may be unavailable."
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
