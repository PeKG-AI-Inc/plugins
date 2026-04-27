#!/usr/bin/env bash
# PeKG Stop hook for Claude Code (turn-end).
# Abilities: A7c (degraded) ack detection at end of turn — when an agent quoted
#           the blocker title and described mitigation, mark blocker(s) acked.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="claude-code-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/blockers.sh
# @inline shared/lib/byollm.sh
# @inline shared/lib/hive.sh

main() {
  local input session_id transcript_path
  input=$(cat 2>/dev/null || true)
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')
  [ -z "$session_id" ] && exit 0

  pekg_load_config
  [ -z "$PEKG_TOKEN" ] && exit 0

  local cur blockers
  cur=$(pekg_state_read "$session_id" 2>/dev/null || echo '{}')
  blockers=$(printf '%s' "${cur:-{}}" | jq -c '.blockers // []')

  # Read the last assistant turn from the transcript (jsonl) — we need it for
  # A28 completed-steps + A102 KB_INGEST regardless of blocker presence.
  local last_assistant=""
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    # Transcript shape (Claude Code 2.1.119): each line is a JSON event;
    # assistant turns have type=="assistant" and message.content is an array
    # of {type, text} blocks. Concatenate text blocks of the LAST assistant
    # event (use grep to pre-filter so jq -s doesn't choke on attachment lines).
    last_assistant=$(tail -200 "$transcript_path" 2>/dev/null \
      | grep '"type":"assistant"' \
      | tail -1 \
      | jq -r '.message.content[]? | select(.type == "text") | .text' 2>/dev/null \
      | tr '\n' ' ')
  fi

  # A28: completed-steps tracking — runs whether or not blockers are active.
  [ -n "$last_assistant" ] && pekg_track_completed_steps "$session_id" "$last_assistant"

  # A37: idle-equivalent compile trigger — also runs unconditionally.
  pekg_maybe_trigger_compile "$session_id" &
  disown 2>/dev/null || true

  # A102: KB_INGEST agent-side pattern parsing — runs unconditionally.
  [ -n "$last_assistant" ] && pekg_parse_kb_ingest "$session_id" "$last_assistant"

  # A25 + A12e: drain pending diffs, run BYOLLM ingest analysis — unconditional.
  pekg_drain_pending_diffs "$session_id" &
  disown 2>/dev/null || true

  # The remaining work (BYOLLM ack verification) only runs when blockers exist.
  if ! pekg_has_active_blockers "$blockers"; then
    exit 0
  fi
  [ -z "$last_assistant" ] && exit 0

  # A30 + A12a: deterministic heuristic GATES the BYOLLM verifier.
  # If heuristic rejects the ack, no point spending a child session — gate stays.
  # If heuristic passes, run A12a BYOLLM verifier (subject to A29 cost cap)
  # for stronger confirmation. If verifier also passes, mark ack-verified
  # in session state so future userpromptsubmit fetches can clear (A59
  # still defers actual clearance to server returning empty blockers).
  if pekg_heuristic_ack "$blockers" "$last_assistant"; then
    # BYOLLM verifier (claude -p subprocess) takes 5-30s; Stop hook timeout
    # is typically 5s in settings.json. Background the verifier so Stop
    # returns fast; verifier writes ackVerifiedAt asynchronously, next
    # session reads it. </dev/null detaches stdin so subprocess survives
    # parent's exit (claude was killing orphans on stdin EOF).
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

# A28: parse "I added/fixed/refactored/wrote/created/...; "I implemented X" etc.
# Append up to 5 to sessionTaskState.completedSteps.
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

# A37 + A12c: idle compile trigger. Tries pekg_compile_maybe_run (A12c)
# which fetches a manifest and runs BYOLLM cluster compilation in
# background. A12d hive transformation runs in parallel. Both gated by
# their own cooldowns (5min / 10min) + locks.
pekg_maybe_trigger_compile() {
  local sid="$1"
  pekg_offline && return 0
  ( pekg_compile_maybe_run "$sid" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
  ( pekg_hive_maybe_transform "$sid" ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

# A25 + A12e: drain ~/.pekg/diffs/<sid>/*.json; for each, run BYOLLM analysis;
# POST to /api/v1/ingest if shouldIngest=true.
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
    payload=$(jq -n \
      --arg t "$title" --arg ty "$type" --arg c "$content" --arg p "$project" \
      '{title:$t, sourceType:$ty, content:$c, projectOrigin:$p, tags:"plugin-auto-ingest"}')
    pekg_post_json "/api/v1/ingest" "$payload" 5 >/dev/null 2>&1 || true
    processed=$((processed + 1))
  done
}

# A102 — scan agent text for `KB_INGEST: title | type | description` and POST.
pekg_parse_kb_ingest() {
  local sid="$1"
  local text="$2"
  [ -z "$text" ] && return 0

  local line title type_str description content
  line=$(printf '%s' "$text" | grep -m1 -E '^KB_INGEST:' || true)
  [ -z "$line" ] && return 0

  # Parse "KB_INGEST: <title> | <type> | <description>"
  title=$(printf '%s' "$line" | sed -E 's/^KB_INGEST:[[:space:]]*//' | awk -F'\\|' '{print $1}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  type_str=$(printf '%s' "$line" | awk -F'\\|' '{print $2}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  description=$(printf '%s' "$line" | awk -F'\\|' '{for(i=3;i<=NF;i++) printf "%s%s", $i, (i<NF ? "|" : "")}' | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')

  [ -z "$title" ] && return 0
  [ -z "$description" ] && return 0

  # Whitelist allowed types.
  case "$type_str" in
    bug_fix|pattern|decision|learning|gotcha|architecture|anti_pattern) ;;
    *) return 0 ;;
  esac

  # Build content with description + most-recent modified file from state.
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

  # Fire-and-forget.
  pekg_post_json "/api/v1/ingest" "$payload" 3 >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

main
