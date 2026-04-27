#!/usr/bin/env bash
# PeKG UserPromptSubmit hook for Claude Code.
# Abilities: A1 context injection, A1b relevance thresholds, A19 per-session dedup,
#           A20 first-message gating, A33 guaranteed-blocks, A48 NETWORK_BLOCKER lifecycle,
#           A55 STOP-vs-friendly banner, A48 inverse on success.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="claude-code-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/blockers.sh
# @inline shared/lib/queue.sh
# @inline shared/lib/feedback.sh

main() {
  pekg_load_config
  [ -z "$PEKG_TOKEN" ] && exit 0

  local event session_id cwd project prompt
  event=$(cat 2>/dev/null || true)
  session_id=$(printf '%s' "$event" | jq -r '.session_id // .session.id // empty')
  [ -z "$session_id" ] && session_id="default"
  session_id=$(printf '%s' "$session_id" | tr -c 'a-zA-Z0-9_-' '_')

  cwd=$(printf '%s' "$event" | jq -r '.session.cwd // .cwd // empty')
  [ -z "$cwd" ] && cwd="$PWD"
  project=$(pekg_project_origin "$cwd")

  prompt=$(printf '%s' "$event" | jq -r '.prompt // .user_prompt // empty')
  [ -z "$prompt" ] && prompt="working in ${project}"
  prompt=$(printf '%s' "$prompt" | head -c 500)

  # A58: slash-command intercept warning. Detect leading /clear, /new, /reset,
  # /compact in the user prompt; if blockers are persisted, surface a warning
  # via additionalContext (we can't BLOCK built-in slash commands, but we can
  # ensure the agent sees the gating intent before the host processes them).
  local pre_blockers
  pre_blockers=$(printf '%s' "$(pekg_state_read "$session_id" 2>/dev/null || echo '{}')" | jq -c '.blockers // []')
  local slash_warning=""
  if pekg_has_active_blockers "$pre_blockers"; then
    case "$prompt" in
      /clear*|/new*|/reset*|/compact*|/quit*)
        local cmd
        cmd=$(printf '%s' "$prompt" | awk '{print $1}')
        slash_warning="WARNING: ${cmd} attempted while PeKG blockers are active. PeKG cannot block built-in commands, but state will not survive ${cmd}. Address the blockers FIRST (quote title verbatim + concrete mitigation) before clearing session state."
        ;;
    esac
  fi

  # A19 per-session dedup cache (article IDs already seen this session).
  local cache_dir="/tmp/pekg-session-${session_id}"
  mkdir -p "$cache_dir" 2>/dev/null
  chmod 700 "$cache_dir" 2>/dev/null
  local seen_file="${cache_dir}/seen.txt"
  touch "$seen_file" 2>/dev/null

  # A20 first-message-injected flag.
  local first_marker="${cache_dir}/first_injected"
  local first_run=0
  if [ ! -f "$first_marker" ]; then
    first_run=1
    touch "$first_marker"
  fi

  # A1 + A1b: fetch context with project + prompt.
  local payload result
  payload=$(jq -n --arg p "$project" --arg t "$prompt" '{projectOrigin:$p, currentTask:$t}')
  result=$(pekg_post_json "/api/v1/context-lookup" "$payload" 3 2>/dev/null || true)

  if [ -z "$result" ]; then
    # A48: synthesize NETWORK_BLOCKER, persist for the gate.
    local cur task blockers
    cur=$(pekg_state_read "$session_id" 2>/dev/null || true)
    task=$(printf '%s' "${cur:-{}}" | jq -c '.task // {}')
    blockers=$(pekg_synth_network_blocker)
    pekg_state_write "$session_id" "$task" "$blockers" || true
    exit 0
  fi

  # Issue 6 port (relevance floor): apply plugin-side per-tier floor BEFORE
  # the existing pipeline. Blockers in 0.55–0.65 are demoted to warning
  # (preserves accumulated value); items below their tier's floor drop.
  # Server still uses the loose 0.5 threshold for non-gating clients.
  local floored_relevant
  floored_relevant=$(pekg_apply_tier_floor "$(printf '%s' "$result" | jq -c '.relevant // []')")
  result=$(printf '%s' "$result" | jq --argjson f "$floored_relevant" '.relevant = $f')

  # A1b tier thresholds + A19 dedup + A1c stable order + A43 budget with always-blocker fallback.
  local top
  top=$(printf '%s' "$result" | jq --rawfile seen "$seen_file" --argjson firstRun "$first_run" --argjson budget "${PEKG_CONTEXT_TOKEN_BUDGET:-4000}" --argjson chars "${PEKG_AVG_CHARS_PER_TOKEN:-4}" '
    def threshold($tier): if $tier == "blocker" then 0.65 elif $tier == "warning" then 0.55 else 0.7 end;
    def tier_rank($tier): if $tier == "blocker" then 0 elif $tier == "warning" then 1 else 2 end;
    ($seen | split("\n") | map(select(length > 0))) as $seen_ids |
    ($budget * $chars) as $char_cap |
    # 1. Filter by relevance threshold + first-message gating + dedup.
    # Bind .articleId BEFORE the dedup check — inside `$seen_ids | index(...)`
    # the pipeline value is the seen-array, not the article, so a bare
    # `.articleId` would dereference the array. Capture as $aid first.
    ([ .relevant // [] | .[]
       | (.articleId // "") as $aid
       | select((.relevance // 0) >= threshold(.tier // "info"))
       | select(($firstRun == 1) or (.tier == "blocker" or .tier == "warning"))
       | select($seen_ids | index($aid) | not) ]) as $filtered |
    # 2. A1c stable sort: tier asc → relevance desc → articleId asc.
    ($filtered | sort_by([tier_rank(.tier // "info"), -(.relevance // 0), (.articleId // "")])) as $sorted |
    # 3. A43 budget: greedy fill, ALWAYS include ≥1 blocker if any exists.
    (reduce $sorted[] as $a ([0, []];
      .[0] as $used | .[1] as $acc |
      ((($a.title // "") + ($a.summary // "") + ($a.snippet // "")) | length) as $cost |
      if $used + $cost <= $char_cap or ($acc | length) == 0 then
        [$used + $cost, $acc + [$a]]
      else
        .
      end
    )) as $taken |
    $taken[1] as $picked |
    # 4. If no blocker made it through but blockers exist, force-prepend the highest-relevance blocker.
    if ($picked | any(.tier == "blocker")) then $picked
    else
      ($sorted | map(select(.tier == "blocker")) | .[0]) as $blk |
      if $blk == null then $picked
      else [$blk] + ($picked | map(select(.articleId != $blk.articleId)))
      end
    end
  ' 2>/dev/null || echo '[]')

  # A33: also fetch guaranteed blocks (project_config, user_preferences) on first run.
  local guaranteed='[]'
  if [ "$first_run" = "1" ]; then
    local g_payload g_result
    g_payload=$(jq -n --arg p "$project" '{projectOrigin:$p}')
    g_result=$(pekg_post_json "/api/v1/context-lookup/guaranteed" "$g_payload" 3 2>/dev/null || true)
    if [ -n "$g_result" ]; then
      guaranteed=$(printf '%s' "$g_result" | jq -c '.relevant // []' 2>/dev/null || echo '[]')
    fi
  fi

  # Persist blockers from the result into session state (A14).
  local blockers
  blockers=$(printf '%s' "$result" | jq -c '[.relevant // [] | .[] | select(.tier == "blocker") | {id: .articleId, title, recommendation: .summary, tier}]')
  local cur task
  cur=$(pekg_state_read "$session_id" 2>/dev/null || true)
  task=$(printf '%s' "${cur:-{}}" | jq -c '.task // {}' 2>/dev/null || echo '{}')
  # A48 inverse: clear stale NETWORK_BLOCKER; merge fresh real blockers.
  blockers=$(pekg_strip_network_blocker "$blockers")
  pekg_state_write "$session_id" "$task" "$blockers" || true

  # A54: RESUMED SESSION block — must be computed BEFORE the early-exit
  # check so we surface it even when no fresh context arrived. Only fires
  # on first message of the session AND only when prior state had content.
  local resume_block=""
  if [ "$first_run" = "1" ]; then
    local prior_state prior_task prior_modified prior_read prior_failed prior_completed
    prior_state=$(pekg_state_read "$session_id" 2>/dev/null || echo '{}')
    prior_task=$(printf '%s' "$prior_state" | jq -r '.task.currentTask // empty' 2>/dev/null || echo "")
    prior_modified=$(printf '%s' "$prior_state" | jq -r '.task.activeFiles.filesModified // [] | .[0:5] | .[]?' 2>/dev/null | sort -u)
    prior_read=$(printf '%s' "$prior_state" | jq -r '.task.activeFiles.filesRead // [] | .[0:5] | .[]?' 2>/dev/null | sort -u)
    prior_failed=$(printf '%s' "$prior_state" | jq -r '.task.failedApproaches // [] | .[0:3] | .[]?' 2>/dev/null)
    prior_completed=$(printf '%s' "$prior_state" | jq -r '.task.completedSteps // [] | .[-3:] | .[]?' 2>/dev/null)

    if [ -n "$prior_task" ] || [ -n "$prior_modified" ] || [ -n "$prior_failed" ] || [ -n "$prior_completed" ]; then
      resume_block="RESUMED SESSION (PeKG rehydrated from prior turn):"$'\n'
      [ -n "$prior_task" ]      && resume_block+="  Prior task: $prior_task"$'\n'
      if [ -n "$prior_modified" ]; then
        resume_block+="  Recently modified:"$'\n'
        while IFS= read -r f; do [ -z "$f" ] || resume_block+="    - $f"$'\n'; done <<< "$prior_modified"
      fi
      if [ -n "$prior_read" ]; then
        resume_block+="  Recently read:"$'\n'
        while IFS= read -r f; do [ -z "$f" ] || resume_block+="    - $f"$'\n'; done <<< "$prior_read"
      fi
      if [ -n "$prior_failed" ]; then
        resume_block+="  Failed approaches (do NOT repeat):"$'\n'
        while IFS= read -r a; do [ -z "$a" ] || resume_block+="    - $a"$'\n'; done <<< "$prior_failed"
      fi
      if [ -n "$prior_completed" ]; then
        resume_block+="  Completed steps:"$'\n'
        while IFS= read -r s; do [ -z "$s" ] || resume_block+="    - $s"$'\n'; done <<< "$prior_completed"
      fi
      resume_block+=$'\n'
    fi
  fi

  # If nothing passed all filters and no guaranteed blocks, emit nothing —
  # UNLESS we have a resume_block (A54) or slash_warning (A58) to surface,
  # which are independent of context-fetch results.
  local top_count guaranteed_count
  top_count=$(printf '%s' "$top" | jq 'length' 2>/dev/null || echo 0)
  guaranteed_count=$(printf '%s' "$guaranteed" | jq 'length' 2>/dev/null || echo 0)
  if [ "$top_count" = "0" ] && [ "$guaranteed_count" = "0" ] \
     && [ -z "${resume_block:-}" ] && [ -z "${slash_warning:-}" ]; then
    exit 0
  fi

  # A55: STOP-vs-friendly banner depending on blocker presence.
  local has_blockers context
  has_blockers=$(printf '%s' "$top" | jq 'any(.tier == "blocker")' 2>/dev/null || echo false)

  context="$resume_block"
  [ -n "$slash_warning" ] && context+="$slash_warning"$'\n\n'
  if [ "$has_blockers" = "true" ]; then
    context+="STOP - PeKG BLOCKERS DETECTED. Quote the blocker title verbatim AND describe the concrete mitigation before any file-mutating tool. Generic acks (\"acknowledged\", \"will be careful\") are rejected."$'\n'
  else
    context+="PeKG knowledge:"$'\n'
  fi

  # Top match summary.
  if [ "$top_count" != "0" ]; then
    local top_one tier title aid summary
    top_one=$(printf '%s' "$top" | jq -c '.[0]')
    tier=$(printf '%s' "$top_one" | jq -r '.tier // "info"')
    title=$(printf '%s' "$top_one" | jq -r '.title // ""')
    aid=$(printf '%s' "$top_one" | jq -r '.articleId // ""')
    summary=$(printf '%s' "$top_one" | jq -r '.summary // .snippet // ""' | tr -d '\n' | cut -c1-240)
    [ -n "$aid" ] && echo "$aid" >> "$seen_file"
    context+="[${tier}] ${title} — ${summary}"
  fi

  # A33: append guaranteed blocks (always-active project knowledge) on first run.
  if [ "$guaranteed_count" != "0" ]; then
    local g_text
    g_text=$(printf '%s' "$guaranteed" | jq -r 'map("- " + (.title // "untitled") + ": " + ((.summary // .snippet // "") | gsub("\\n"; " ") | .[0:160])) | join("\n")')
    context+=$'\n\nProject knowledge (always active):\n'"$g_text"
  fi

  # A21/A22/A41: drain proactive-context queue (filled by pretooluse / posttooluse).
  local queued queued_count
  queued=$(pekg_queue_drain "$session_id" 2>/dev/null || echo '[]')
  queued_count=$(printf '%s' "$queued" | jq 'length' 2>/dev/null || echo 0)
  if [ "$queued_count" != "0" ]; then
    local q_text
    q_text=$(printf '%s' "$queued" | jq -r 'map("- " + (.title // "untitled") + ": " + ((.summary // .snippet // "") | gsub("\\n"; " ") | .[0:160])) | unique | join("\n")')
    if [ -n "$q_text" ]; then
      context+=$'\n\nDiscovered while inspecting recently touched files:\n'"$q_text"
    fi
  fi

  # A31b: record shown article ids for this session (used by feedback gating).
  local shown_ids
  shown_ids=$(printf '%s\n%s\n%s' "$top" "$guaranteed" "$queued" \
    | jq -r '.[]?.articleId // empty' 2>/dev/null | tr '\n' ' ')
  [ -n "$shown_ids" ] && pekg_shown_record "$session_id" $shown_ids

  jq -n --arg ctx "$context" '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}'
}

main
