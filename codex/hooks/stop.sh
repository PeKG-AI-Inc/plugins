#!/usr/bin/env bash
# PeKG Stop hook for Codex (turn-end). Same semantics as Claude Code variant.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="codex-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/blockers.sh
# @inline shared/lib/byollm.sh
# @inline shared/lib/hive.sh

main() {
  local input session_id
  input=$(cat 2>/dev/null || true)
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  [ -z "$session_id" ] && exit 0

  pekg_load_config
  [ -z "$PEKG_TOKEN" ] && exit 0

  local cur blockers
  cur=$(pekg_state_read "$session_id" 2>/dev/null || echo '{}')
  blockers=$(printf '%s' "${cur:-{}}" | jq -c '.blockers // []')

  # Codex 0.122+ provides the last assistant text PRE-EXTRACTED in the
  # Stop hook input as `last_assistant_message` (string|null). Use it
  # directly — Codex's transcript JSONL is a different shape from Claude
  # Code's (rollout-style, no documented schema; verified 2026-04-26 via
  # github.com/openai/codex/blob/main/codex-rs/hooks/schema/generated/
  # stop.command.input.schema.json). Falling back to transcript parsing
  # would produce silent empty results.
  local last_assistant transcript_path
  last_assistant=$(printf '%s' "$input" | jq -r '.last_assistant_message // empty')
  transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

  # Run unconditional housekeeping: completed-steps, compile trigger, KB_INGEST,
  # diff-drain. These are independent of blocker presence.
  [ -n "$last_assistant" ] && pekg_track_completed_steps "$session_id" "$last_assistant"
  pekg_maybe_trigger_compile "$session_id" &
  disown 2>/dev/null || true
  [ -n "$last_assistant" ] && pekg_parse_kb_ingest "$session_id" "$last_assistant"
  pekg_drain_pending_diffs "$session_id" &
  disown 2>/dev/null || true

  pekg_has_active_blockers "$blockers" || exit 0
  [ -z "$last_assistant" ] && exit 0

  if pekg_heuristic_ack "$blockers" "$last_assistant"; then
    # Background — BYOLLM subprocess takes 10-30s, Stop timeout is typically 5s.
    # </dev/null detaches stdin so subprocess survives parent's exit.
    (
      if pekg_byollm_verify_ack "$session_id" "$blockers" "$last_assistant"; then
        local cur task blockers_json
        cur=$(pekg_state_read "$session_id" 2>/dev/null || echo '{}')
        task=$(printf '%s' "$cur" | jq -c '.task // {}' | jq -c --arg ts "$(date +%s)" '.ackVerifiedAt = ($ts | tonumber)')
        blockers_json=$(printf '%s' "$cur" | jq -c '.blockers // []')
        pekg_state_write "$session_id" "$task" "$blockers_json" || true
      fi
    ) </dev/null >/dev/null 2>&1 &
    disown 2>/dev/null || true
  fi
}

pekg_track_completed_steps() {
  local sid="$1"
  local text="$2"
  [ -z "$text" ] && return 0
  local steps
  steps=$(printf '%s' "$text" | grep -oE "I (added|fixed|refactored|wrote|created|implemented|removed|moved|renamed|updated|read|ran|tested|verified|built|deployed|installed|configured) [^.]*\." | head -5)
  [ -z "$steps" ] && return 0
  local steps_json
  steps_json=$(printf '%s\n' "$steps" | jq -R -s -c 'split("\n") | map(select(length > 0))')
  local cur task task_updated blockers
  cur=$(pekg_state_read "$sid" 2>/dev/null || echo '{}')
  task=$(printf '%s' "$cur" | jq -c '.task // {}')
  task_updated=$(printf '%s' "$task" | jq -c --argjson new "$steps_json" '
    .completedSteps = ((.completedSteps // []) + $new | unique | .[-10:])
  ')
  blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
  pekg_state_write "$sid" "$task_updated" "$blockers"
}

pekg_maybe_trigger_compile() {
  local sid="$1"
  pekg_offline && return 0
  ( pekg_compile_maybe_run "$sid" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  ( pekg_hive_maybe_transform "$sid" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

pekg_drain_pending_diffs() {
  local sid="$1"
  local diff_dir="$HOME/.pekg/diffs/$sid"
  [ -d "$diff_dir" ] || return 0
  pekg_offline && return 0
  local processed=0 max=3
  for diff_file in "$diff_dir"/*.json; do
    [ -f "$diff_file" ] || continue
    [ "$processed" -ge "$max" ] && break
    local file_path diff_text
    file_path=$(jq -r '.path // empty' "$diff_file" 2>/dev/null || true)
    diff_text=$(jq -r '.diff // empty' "$diff_file" 2>/dev/null || true)
    [ -z "$file_path" ] || [ -z "$diff_text" ] && { rm -f "$diff_file"; continue; }
    local analysis should title type content
    analysis=$(pekg_byollm_analyze_diff "$sid" "$file_path" "$diff_text" 2>/dev/null || true)
    rm -f "$diff_file"
    [ -z "$analysis" ] && continue
    should=$(printf '%s' "$analysis" | jq -r '.shouldIngest // false')
    [ "$should" != "true" ] && continue
    title=$(printf '%s' "$analysis" | jq -r '.title // empty')
    type=$(printf '%s' "$analysis" | jq -r '.type // "learning"')
    content=$(printf '%s' "$analysis" | jq -r '.content // empty')
    [ -z "$title" ] || [ -z "$content" ] && continue
    local project payload
    project=$(pekg_project_origin "$PWD")
    payload=$(jq -n --arg t "$title" --arg ty "$type" --arg c "$content" --arg p "$project" \
      '{title:$t, sourceType:$ty, content:$c, projectOrigin:$p, tags:"plugin-auto-ingest"}')
    pekg_post_json "/api/v1/ingest" "$payload" 5 >/dev/null 2>&1 || true
    processed=$((processed + 1))
  done
}

pekg_parse_kb_ingest() {
  local sid="$1"
  local text="$2"
  [ -z "$text" ] && return 0

  local line title type_str description content
  line=$(printf '%s' "$text" | grep -m1 -E '^KB_INGEST:' || true)
  [ -z "$line" ] && return 0

  title=$(printf '%s' "$line" | sed -E 's/^KB_INGEST:[[:space:]]*//' | awk -F'\\|' '{print $1}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  type_str=$(printf '%s' "$line" | awk -F'\\|' '{print $2}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  description=$(printf '%s' "$line" | awk -F'\\|' '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF ? "|" : "")}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

  [ -z "$title" ] && return 0
  [ -z "$description" ] && return 0

  case "$type_str" in
    bug_fix|pattern|decision|learning|gotcha|architecture|anti_pattern) ;;
    *) return 0 ;;
  esac

  local cur recent_file
  cur=$(pekg_state_read "$sid" 2>/dev/null || echo '{}')
  recent_file=$(printf '%s' "$cur" | jq -r '.task.activeFiles.filesModified // [] | last // empty')
  if [ -n "$recent_file" ]; then
    content=$(printf '%s\n\nRelated file: %s' "$description" "$recent_file")
  else
    content="$description"
  fi

  local project payload
  project=$(pekg_project_origin "$PWD")
  payload=$(jq -n \
    --arg t "$title" \
    --arg type "$type_str" \
    --arg c "$content" \
    --arg p "$project" \
    '{title: $t, sourceType: $type, content: $c, projectOrigin: $p, tags: "agent-self-ingest"}')

  pekg_post_json "/api/v1/ingest" "$payload" 3 >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

main
