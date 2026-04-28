#!/usr/bin/env bash
# PeKG PreToolUse hook for Claude Code.
# Abilities: A5b blocker gate, A8 auto-deny, A17 dangerous-bash detection,
#           A48 NETWORK_BLOCKER lifecycle, plus legacy "must call pekg_status first" gate.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="claude-code-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/blockers.sh
# @inline shared/lib/queue.sh

allow() { exit 0; }

deny() {
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

main() {
  local input tool session_id transcript_path
  input=$(cat 2>/dev/null || true)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

  # Always-allow: internal tool-discovery surfaces.
  case "$tool" in
    ToolSearch|ToolList|tool_search|tool_list|ListTools|list_tools) allow ;;
  esac

  # Status-called gate (legacy): track via state-dir for parallel-call race.
  local status_dir="$HOME/.pekg/session-state"
  mkdir -p "$status_dir" 2>/dev/null || true
  local status_marker="$status_dir/${session_id}.status_called"

  if [ "$tool" = "mcp__pekg__status" ] || [ "$tool" = "pekg_status" ]; then
    touch "$status_marker"
    # Run the blocker check below to keep gate consistent.
  fi

  # A5b: read persisted state for this session, deny if active blockers + mutating tool.
  # Issue 8 port: when the target file path is markdown, demote code-domain
  # blockers to warning before deciding whether to gate. Same rules as the
  # OpenCode plugin (security/privacy/compliance carve-outs unchanged).
  #
  # Bash variants intentionally skip THIS gate — they have their own dedicated
  # gate below that calls pekg_is_workspace_mutation_cmd, so read-only commands
  # like `git ls-tree`, `cat`, `grep` flow through even with active blockers.
  # Without this skip, the early gate denied ALL Bash on any active blocker,
  # which forced agents to "bypass" via Read/Grep/Glob just to make progress.
  pekg_load_config
  if [ -n "$session_id" ] && pekg_is_mutating_tool "$tool"; then
    case "$tool" in
      Bash|bash|shell|run_terminal_cmd) ;;  # defer to dedicated bash gate below
      *)
        local state blockers
        state=$(pekg_state_read "$session_id" 2>/dev/null || true)
        if [ -n "$state" ]; then
          blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
          if pekg_has_active_blockers "$blockers"; then
            # A30b: drop blockers acked recently in this session (cooldown).
            local acked_map
            acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
            blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
          fi
          if pekg_has_active_blockers "$blockers"; then
            # Extract target file path from CC's tool_input shape.
            local target_path
            target_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
            local effective_blockers
            effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "$target_path")
            if pekg_has_active_blockers "$effective_blockers"; then
              # A30b: try in-turn ack against the live transcript. If the
              # latest assistant text references the active blockers and
              # describes a concrete mitigation, accept it and persist the
              # ack so subsequent edits in this turn / cooldown window
              # flow through without re-acking.
              if pekg_try_in_turn_ack "$session_id" "$effective_blockers" "$transcript_path"; then
                allow
              fi
              # A30c: loop-bound safety net. Bump per-blocker denial counter;
              # if any blocker hit the threshold, force-ack it and re-evaluate.
              if pekg_record_denial_and_maybe_force_ack "$session_id" "$effective_blockers"; then
                state=$(pekg_state_read "$session_id" 2>/dev/null || true)
                blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
                acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
                blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
                effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "$target_path")
                if ! pekg_has_active_blockers "$effective_blockers"; then
                  allow
                fi
              fi
              local reason
              reason=$(pekg_format_denial_reason "$effective_blockers")
              deny "$reason"
            fi
          fi
        fi
        ;;
    esac
  fi

  # A17: dangerous-bash detection on bash tool.
  # Issue 8 port: if the bash command targets a markdown file, apply the same
  # re-tier so doc-write commands aren't gated by code-domain blockers.
  if [ "$tool" = "Bash" ] || [ "$tool" = "bash" ]; then
    local cmd
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    if [ -n "$cmd" ] && [ -n "$session_id" ]; then
      local state blockers
      state=$(pekg_state_read "$session_id" 2>/dev/null || true)
      if [ -n "$state" ]; then
        blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
        if pekg_has_active_blockers "$blockers"; then
          local acked_map
          acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
          blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
        fi
        if pekg_has_active_blockers "$blockers" && pekg_is_workspace_mutation_cmd "$cmd"; then
          local effective_blockers
          if pekg_bash_cmd_targets_markdown "$cmd"; then
            effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "<bash-target>.md")
          else
            effective_blockers="$blockers"
          fi
          if pekg_has_active_blockers "$effective_blockers"; then
            if pekg_try_in_turn_ack "$session_id" "$effective_blockers" "$transcript_path"; then
              allow
            fi
            if pekg_record_denial_and_maybe_force_ack "$session_id" "$effective_blockers"; then
              state=$(pekg_state_read "$session_id" 2>/dev/null || true)
              blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
              acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
              blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
              if pekg_bash_cmd_targets_markdown "$cmd"; then
                effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "<bash-target>.md")
              else
                effective_blockers="$blockers"
              fi
              if ! pekg_has_active_blockers "$effective_blockers"; then
                allow
              fi
            fi
            local reason
            reason=$(pekg_format_denial_reason "$effective_blockers")
            deny "$reason"$'\n\nDangerous bash command detected (sed -i / tee / file redirect / git apply / etc).'
          fi
        fi
      fi
    fi
  fi

  # A57: file content pre-capture before Edit/Write so PostToolUse can compute a diff.
  if [ "$tool" = "Edit" ] || [ "$tool" = "Write" ] || [ "$tool" = "MultiEdit" ]; then
    local path
    path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
    if [ -n "$path" ] && [ -n "$session_id" ] && [ -f "$path" ]; then
      local cap_dir="$HOME/.pekg/precap/${session_id}"
      mkdir -p "$cap_dir" 2>/dev/null || true
      # Encode path → safe filename via base64.
      local safe
      safe=$(printf '%s' "$path" | base64 | tr -d '\n=' | tr '/+' '__')
      head -c 102400 "$path" > "$cap_dir/${safe}.before" 2>/dev/null || true
    fi
  fi

  # A23: task-subagent blocker propagation. When agent invokes Task (Claude Code)
  # subagent spawn, mutate tool_input.prompt to prepend active blockers so the
  # spawned child inherits enforcement state.
  #
  # CC 2.1.119 hook contract (verified 2026-04-26): the mutation field is
  # `updatedInput` (NOT modifiedToolInput), nested under hookSpecificOutput
  # alongside `permissionDecision: "allow"`. updatedInput REPLACES the entire
  # input object — must include all original fields unmodified alongside the
  # changed ones (jq spread `($ti | .prompt = $p)` does this since $ti has
  # the full original input). Wrong field name = silent no-op (the SDK plugin
  # anti-pattern).
  if [ "$tool" = "Task" ] || [ "$tool" = "task" ] || [ "$tool" = "spawn_agent" ]; then
    if [ -n "$session_id" ]; then
      local state blockers
      state=$(pekg_state_read "$session_id" 2>/dev/null || true)
      if [ -n "$state" ]; then
        blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
        if pekg_has_active_blockers "$blockers"; then
          local prefix orig_prompt new_prompt
          prefix=$(printf '%s' "$blockers" | jq -r '
            "<pekg-blockers-inherited>\nThe parent session has unacknowledged PeKG blockers. Address them in your output:\n" +
            (map("- " + .title + ": " + (.recommendation // "no recommendation")) | join("\n")) +
            "\n</pekg-blockers-inherited>\n\n"
          ')
          orig_prompt=$(printf '%s' "$input" | jq -r '.tool_input.prompt // .tool_input.description // empty')
          new_prompt=$(printf '%s%s' "$prefix" "$orig_prompt")
          jq -n --arg p "$new_prompt" --argjson ti "$(printf '%s' "$input" | jq -c '.tool_input // {}')" '
            {hookSpecificOutput: {
              hookEventName: "PreToolUse",
              permissionDecision: "allow",
              updatedInput: ($ti | .prompt = $p)
            }}'
          exit 0
        fi
      fi
    fi
  fi

  # A5a proactive context fetch on read/grep/glob — queue for next userpromptsubmit.
  case "$tool" in
    Read)
      local rp
      rp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
      if [ -n "$rp" ] && [ -n "$session_id" ]; then
        pekg_proactive_fetch "$session_id" "$(basename "$rp")"
      fi
      ;;
    Grep|Glob)
      local pattern
      pattern=$(printf '%s' "$input" | jq -r '.tool_input.pattern // .tool_input.query // empty')
      if [ -n "$pattern" ] && [ -n "$session_id" ]; then
        pekg_proactive_fetch "$session_id" "$pattern"
      fi
      ;;
  esac

  # Pekg-prefix sanity: reject obvious typos/look-alikes early.
  case "$tool" in
    mcp__pekg__status|mcp__pekg__ingest|mcp__pekg__search|mcp__pekg__compile|mcp__pekg__context|mcp__pekg__health|mcp__pekg__scan|mcp__pekg__deep_scan|mcp__pekg__graph|mcp__pekg__feedback|mcp__pekg__hive|mcp__pekg__pending_writes|mcp__pekg__complete_write|pekg_status|pekg_ingest|pekg_search|pekg_compile|pekg_context|pekg_health|pekg_scan|pekg_deep_scan|pekg_graph|pekg_feedback|pekg_hive|pekg_pending_writes|pekg_complete_write)
      allow
      ;;
    mcp__pekg__*|pekg_*)
      deny "Tool $tool is not a valid PeKG tool. Valid: mcp__pekg__{status,ingest,search,compile,context,health,scan,deep_scan,graph,feedback,hive,pending_writes,complete_write}."
      ;;
  esac

  # If config has no token, allow everything (PeKG not set up).
  if [ -z "$PEKG_TOKEN" ]; then
    allow
  fi

  # Status-first soft gate (legacy, default OFF as of 2026-04-27).
  # Opt-IN via PEKG_LEGACY_STATUS_GATE=1 if you want the historic "must call
  # status before any other tool" check. The real blocker enforcement (A5b
  # above) is the proper gate; this legacy gate added 5s synchronous wait
  # to every fresh session for negligible safety value, so it now defaults
  # off. Headless `claude -p` runs and CI flows benefit most from the flip.
  if [ "${PEKG_LEGACY_STATUS_GATE:-0}" = "1" ] && [ ! -f "$status_marker" ]; then
    local elapsed=0
    while [ ! -f "$status_marker" ] && [ "$elapsed" -lt 5000 ]; do
      sleep 0.1
      elapsed=$((elapsed + 100))
    done
    if [ ! -f "$status_marker" ]; then
      deny "pekg: call mcp__pekg__status before other tools (required once per session — see CLAUDE.md session-start protocol)."
    fi
  fi

  allow
}

# Proactive context fetch helper. Best-effort, fire-and-forget; budget 3s.
pekg_proactive_fetch() {
  local sid="$1" query="$2"
  pekg_offline && return 0
  local cwd project payload result
  cwd="$PWD"
  project=$(pekg_project_origin "$cwd")
  payload=$(jq -n --arg p "$project" --arg q "$query" '{projectOrigin:$p, query:$q}')
  # Run in background so the hook does not block the tool call.
  (
    result=$(pekg_post_json "/api/v1/search" "$payload" 3 2>/dev/null || true)
    [ -z "$result" ] && exit 0
    local count i
    count=$(printf '%s' "$result" | jq '.results // [] | length' 2>/dev/null || echo 0)
    [ "$count" -gt 3 ] && count=3
    for ((i=0; i<count; i++)); do
      local art
      art=$(printf '%s' "$result" | jq -c ".results[$i]" 2>/dev/null || true)
      [ -n "$art" ] && pekg_queue_push "$sid" "$art"
    done
  ) >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

main
