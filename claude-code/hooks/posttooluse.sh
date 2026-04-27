#!/usr/bin/env bash
# PeKG PostToolUse hook for Claude Code.
# Abilities: legacy status-called marker, A5c/A6b active-files tracking,
#           A6a/A24/A53/A100 tech detection, A21/A22 proactive-context queue,
#           A36 implicit feedback (best-effort) on successful edit.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="claude-code-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/queue.sh
# @inline shared/lib/tech.sh
# @inline shared/lib/feedback.sh
# @inline shared/lib/byollm.sh

main() {
  local input tool session_id
  input=$(cat 2>/dev/null || true)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  [ -z "$session_id" ] && exit 0

  # Legacy status-called marker for the soft pretooluse gate.
  if [ "$tool" = "mcp__pekg__status" ] || [ "$tool" = "pekg_status" ]; then
    local status_dir="$HOME/.pekg/session-state"
    mkdir -p "$status_dir" 2>/dev/null || true
    touch "$status_dir/${session_id}.status_called" 2>/dev/null || true
    find "$status_dir" -maxdepth 1 -type f -name '*.status_called' -mtime +1 -delete 2>/dev/null || true
  fi

  pekg_load_config
  [ -z "$PEKG_TOKEN" ] && exit 0

  # A27: failed-approach extraction. PostToolUse fires for both success AND
  # error in Claude Code 2.1.119. tool_response shape varies by tool:
  #   - Built-in tools (Edit/Write/Bash/Read): { is_error, content[].text }
  #   - MCP tools (mcp__pekg__*): MCP CallToolResult { isError, content[].text }
  #   - Bash specifically may also have: { exit_code, stdout, stderr }
  # Try all three.
  local tool_error
  tool_error=$(printf '%s' "$input" | jq -r '
    if (.tool_response.isError // .tool_response.is_error // false) then
      (.tool_response.content // [] | map(select(.type == "text") | .text) | join(" "))
    elif ((.tool_response.exit_code // 0) != 0) then
      (.tool_response.stderr // .tool_response.stdout // empty)
    elif (.tool_response.error // empty) then
      .tool_response.error
    else empty end
  ' 2>/dev/null | head -c 240)
  if [ -n "$tool_error" ]; then
    local sanitized
    sanitized=$(printf '%s' "$tool_error" \
      | sed -E 's|sk-[A-Za-z0-9_-]+|<sk-redacted>|g' \
      | sed -E 's|ghp_[A-Za-z0-9_]+|<ghp-redacted>|g' \
      | sed -E 's|Bearer [A-Za-z0-9._-]+|Bearer <redacted>|g' \
      | sed -E 's|password[[:space:]]*[:=][[:space:]]*[^[:space:]]+|password=<redacted>|gI' \
      | tr -d '\n' | head -c 200)
    [ -n "$sanitized" ] && pekg_track_failed_approach "$session_id" "$tool"" — ""$sanitized"
  fi

  # A5c/A6b active-files tracking on edit/write tools.
  local path
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
      path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
      ;;
    Read)
      # Track read-files separately; useful for resumed-session block (A85).
      local read_path
      read_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
      if [ -n "$read_path" ]; then
        pekg_track_read "$session_id" "$read_path"
      fi
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
  [ -z "$path" ] && exit 0

  pekg_track_modified "$session_id" "$path"

  # A25/A57: compute diff vs pre-captured snapshot, queue for ingest analysis if ≥10 lines.
  pekg_queue_diff_for_ingest "$session_id" "$path"

  # A6a/A24/A53 tech detection on the edited file.
  if [ -f "$path" ]; then
    local techs term_set
    techs=$(pekg_detect_techs "$path")
    if [ -n "$techs" ]; then
      # Build search-terms list (comma-joined).
      term_set=""
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        local terms
        terms=$(pekg_search_terms_for "$t")
        if [ -n "$term_set" ]; then term_set="${term_set},${terms}"; else term_set="$terms"; fi
      done <<< "$techs"

      # A21/A22: fetch context for the search terms, queue for next userpromptsubmit.
      if [ -n "$term_set" ]; then
        local payload result
        payload=$(jq -n --arg terms "$term_set" --arg q "$(basename "$path")" '{
          query: $q,
          searchTerms: ($terms | split(","))
        }')
        result=$(pekg_post_json "/api/v1/search" "$payload" 4 2>/dev/null || true)
        if [ -n "$result" ]; then
          # Queue top 3 articles by relevance.
          local top3
          top3=$(printf '%s' "$result" | jq -c '.results // [] | sort_by(-(.relevance // 0))[0:3]')
          local count i
          count=$(printf '%s' "$top3" | jq 'length' 2>/dev/null || echo 0)
          for ((i=0; i<count; i++)); do
            local art
            art=$(printf '%s' "$top3" | jq -c ".[$i]")
            pekg_queue_push "$session_id" "$art"
          done
        fi
      fi
    fi
  fi

  # A36 + A12b: feedback submission, BYOLLM-classified when budget allows.
  # For each blocker in state (≤3 to bound work):
  #   1. Try A12b BYOLLM verifier to classify signal (applied|avoided_bug|ignored).
  #   2. If BYOLLM declines (cost cap, recursion guard, no host CLI, missing
  #      transcript), fall back to A36 default "applied" signal.
  #   3. Submit via A32 queue-aware feedback (offline → file queue, replay later).
  local cur blockers blocker_ids
  cur=$(pekg_state_read "$session_id" 2>/dev/null || true)
  if [ -n "$cur" ]; then
    blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
    blocker_ids=$(printf '%s' "$blockers" | jq -r '.[].id // empty' | head -3)
    if [ -n "$blocker_ids" ]; then
      # Read recent edited content (≤4KB) so the verifier can classify
      # whether the edit applied the blocker's recommendation.
      local edit_excerpt=""
      [ -f "$path" ] && edit_excerpt=$(head -c 4096 "$path" 2>/dev/null || true)

      while IFS= read -r bid; do
        [ -z "$bid" ] && continue
        local blocker_obj title summary signal
        blocker_obj=$(printf '%s' "$blockers" | jq -c --arg id "$bid" '.[] | select(.id == $id)')
        title=$(printf '%s' "$blocker_obj" | jq -r '.title // ""')
        summary=$(printf '%s' "$blocker_obj" | jq -r '.recommendation // ""')

        signal=""
        if [ -n "$edit_excerpt" ] && [ -n "$title" ] && [ -n "$summary" ]; then
          signal=$(pekg_byollm_classify_feedback "$session_id" "$title" "$summary" "$edit_excerpt" 2>/dev/null || true)
        fi
        # Fallback to A36 default if BYOLLM declined.
        [ -z "$signal" ] && signal="applied"

        pekg_feedback_submit "$bid" "$signal" "$(jq -n --arg p "$path" '{filePath:$p}')" || true
      done <<< "$blocker_ids"
    fi
  fi
}

# A27 helper: append a sanitized failed-approach entry (≤5 dedup, last-N).
pekg_track_failed_approach() {
  local sid="$1" approach="$2"
  [ -z "$approach" ] && return 0
  local cur task task_updated blockers
  cur=$(pekg_state_read "$sid" 2>/dev/null || echo '{}')
  task=$(printf '%s' "$cur" | jq -c '.task // {}')
  task_updated=$(printf '%s' "$task" | jq -c --arg a "$approach" '
    .failedApproaches = ((.failedApproaches // []) + [$a] | unique | .[-5:])
  ')
  blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
  pekg_state_write "$sid" "$task_updated" "$blockers"
}

# Helper: track filesModified into state.
pekg_track_modified() {
  local sid="$1" path="$2"
  local cur task task_updated blockers
  cur=$(pekg_state_read "$sid" 2>/dev/null || true)
  task=$(printf '%s' "${cur:-{}}" | jq -c '.task // {}')
  task_updated=$(printf '%s' "$task" | jq -c --arg p "$path" '
    .activeFiles = ((.activeFiles // {}) | .filesModified = ((.filesModified // []) + [$p] | unique))
  ')
  blockers=$(printf '%s' "${cur:-{}}" | jq -c '.blockers // []')
  pekg_state_write "$sid" "$task_updated" "$blockers"
}

# Helper: track filesRead into state.
# A25 + A57: diff queue. Compute unified diff vs pre-captured snapshot;
# queue file if ≥10 lines for the Stop hook's BYOLLM ingest analysis.
pekg_queue_diff_for_ingest() {
  local sid="$1" path="$2"
  [ -f "$path" ] || return 0
  local cap_dir="$HOME/.pekg/precap/${sid}"
  local safe before after diff lines diff_dir
  safe=$(printf '%s' "$path" | base64 | tr -d '\n=' | tr '/+' '__')
  before="$cap_dir/${safe}.before"
  [ -f "$before" ] || return 0

  diff=$(diff -u "$before" "$path" 2>/dev/null | head -300)
  [ -z "$diff" ] && { rm -f "$before"; return 0; }

  lines=$(printf '%s' "$diff" | grep -cE '^[+-][^+-]' 2>/dev/null || echo 0)
  if [ "$lines" -lt "${PEKG_INGEST_ANALYSIS_MIN_LINES:-10}" ]; then
    rm -f "$before"
    return 0
  fi

  diff_dir="$HOME/.pekg/diffs/${sid}"
  mkdir -p "$diff_dir" 2>/dev/null || true
  local fname="$(date +%s)-${safe:0:32}"
  jq -n --arg p "$path" --arg d "$diff" '{path:$p, diff:$d}' > "$diff_dir/${fname}.json"
  rm -f "$before"
}

pekg_track_read() {
  local sid="$1" path="$2"
  local cur task task_updated blockers
  cur=$(pekg_state_read "$sid" 2>/dev/null || true)
  task=$(printf '%s' "${cur:-{}}" | jq -c '.task // {}')
  task_updated=$(printf '%s' "$task" | jq -c --arg p "$path" '
    .activeFiles = ((.activeFiles // {}) | .filesRead = ((.filesRead // []) + [$p] | unique | .[-25:]))
  ')
  blockers=$(printf '%s' "${cur:-{}}" | jq -c '.blockers // []')
  pekg_state_write "$sid" "$task_updated" "$blockers"
}

main
