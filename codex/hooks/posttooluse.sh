#!/usr/bin/env bash
# PeKG PostToolUse hook for Codex.
# Same surface as Claude Code variant; tool name differs (apply_patch).

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="codex-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/queue.sh
# @inline shared/lib/tech.sh
# @inline shared/lib/feedback.sh
# @inline shared/lib/byollm.sh

main() {
  local input tool session_id paths
  input=$(cat 2>/dev/null || true)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  [ -z "$session_id" ] && exit 0

  pekg_load_config
  [ -z "$PEKG_TOKEN" ] && exit 0

  # A27: failed-approach extraction. Codex tool_response is fully untyped
  # (per codex-rs/hooks/schema/generated/post-tool-use.command.input.schema.json
  # which has `"tool_response": true` = any value allowed). For MCP tool
  # calls, the shape is the MCP CallToolResult: {content:[{type:"text",text}],
  # isError?:bool}. For built-in shell tools, it's {exit_code, stdout, stderr}.
  # Try both shapes — verified 2026-04-26.
  local tool_error
  tool_error=$(printf '%s' "$input" | jq -r '
    # MCP shape first (isError + content[].text).
    if (.tool_response.isError // .tool_response.is_error // false) then
      (.tool_response.content // [] | map(select(.type == "text") | .text) | join(" "))
    # Built-in shell shape (non-zero exit_code + stderr).
    elif ((.tool_response.exit_code // 0) != 0) then
      (.tool_response.stderr // .tool_response.stdout // empty)
    elif (.tool_response.error // empty) then .tool_response.error
    else empty end
  ' 2>/dev/null | head -c 240)
  if [ -n "$tool_error" ]; then
    local sanitized
    sanitized=$(printf '%s' "$tool_error" \
      | sed -E 's|sk-[A-Za-z0-9_-]+|<sk-redacted>|g' \
      | sed -E 's|Bearer [A-Za-z0-9._-]+|Bearer <redacted>|g' \
      | tr -d '\n' | head -c 200)
    [ -n "$sanitized" ] && pekg_track_failed_approach "$session_id" "$tool"" — ""$sanitized"
  fi

  case "$tool" in
    apply_patch)
      paths=$(printf '%s' "$input" | jq -r '
        (.tool_input.input // empty) as $raw |
        if $raw == null or $raw == "" then empty
        else $raw | split("\n") | map(select(. | test("^\\*\\*\\* (Update|Add) File:")) | sub("^\\*\\*\\* (Update|Add) File: "; "")) | .[]
        end
      ' 2>/dev/null || true)
      ;;
    Edit|Write|MultiEdit|edit|write|multiedit)
      paths=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
      ;;
    Read|read)
      local read_path
      read_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
      [ -n "$read_path" ] && pekg_track_read "$session_id" "$read_path"
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
  [ -z "$paths" ] && exit 0

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    pekg_track_modified "$session_id" "$path"
    pekg_queue_diff_for_ingest "$session_id" "$path"

    if [ -f "$path" ]; then
      local techs term_set
      techs=$(pekg_detect_techs "$path")
      if [ -n "$techs" ]; then
        term_set=""
        while IFS= read -r t; do
          [ -z "$t" ] && continue
          local terms
          terms=$(pekg_search_terms_for "$t")
          if [ -n "$term_set" ]; then term_set="${term_set},${terms}"; else term_set="$terms"; fi
        done <<< "$techs"

        if [ -n "$term_set" ]; then
          local payload result
          payload=$(jq -n --arg terms "$term_set" --arg q "$(basename "$path")" '{
            query: $q,
            searchTerms: ($terms | split(","))
          }')
          result=$(pekg_post_json "/api/v1/search" "$payload" 4 2>/dev/null || true)
          if [ -n "$result" ]; then
            local top3 count i
            top3=$(printf '%s' "$result" | jq -c '.results // [] | sort_by(-(.relevance // 0))[0:3]')
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

    # A36 implicit feedback per blocker per file.
    local cur blockers blocker_ids
    cur=$(pekg_state_read "$session_id" 2>/dev/null || true)
    if [ -n "$cur" ]; then
      blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
      blocker_ids=$(printf '%s' "$blockers" | jq -r '.[].id // empty' | head -3)
      # Edit excerpt for A12b BYOLLM classification.
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
        [ -z "$signal" ] && signal="applied"

        pekg_feedback_submit "$bid" "$signal" "$(jq -n --arg p "$path" '{filePath:$p}')" || true
      done <<< "$blocker_ids"
    fi
  done <<< "$paths"
}

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

pekg_queue_diff_for_ingest() {
  local sid="$1" path="$2"
  [ -f "$path" ] || return 0
  local cap_dir="$HOME/.pekg/precap/${sid}"
  local safe before diff lines diff_dir fname
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
  fname="$(date +%s)-${safe:0:32}"
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
