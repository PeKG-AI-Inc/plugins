#!/usr/bin/env bash
# PeKG PreToolUse hook for Codex.
# Same gate semantics as Claude Code variant. Codex tools are different names
# (apply_patch instead of Edit/Write), handled in pekg_is_mutating_tool.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="codex-pekg-plugin"

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
  local input tool session_id
  input=$(cat 2>/dev/null || true)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')

  pekg_load_config

  # A5b real blocker gate.
  # Issue 8 port: target file path → markdown re-tier. Code-domain blockers
  # are demoted to warning (skip the gate) on .md/.mdx/.txt/.rst/.adoc;
  # security/privacy/compliance blockers stay at blocker.
  #
  # Bash variants intentionally skip THIS gate — they have their own dedicated
  # gate below that calls pekg_is_workspace_mutation_cmd, so read-only commands
  # like `git ls-tree`, `cat`, `grep` flow through even with active blockers.
  # Without this skip, the early gate denied ALL Bash on any active blocker,
  # which forced agents to "bypass" via Read/Grep/Glob just to make progress.
  if [ -n "$session_id" ] && pekg_is_mutating_tool "$tool"; then
    case "$tool" in
      Bash|bash|shell|run_terminal_cmd) ;;  # defer to dedicated bash gate below
      *)
        local state blockers
        state=$(pekg_state_read "$session_id" 2>/dev/null || true)
        if [ -n "$state" ]; then
          blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
          if pekg_has_active_blockers "$blockers"; then
            local target_path
            target_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
            local effective_blockers
            effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "$target_path")
            if pekg_has_active_blockers "$effective_blockers"; then
              local reason
              reason=$(pekg_format_denial_reason "$effective_blockers")
              deny "$reason"
            fi
          fi
        fi
        ;;
    esac
  fi

  # A17 dangerous-bash detection on Codex's Bash tool.
  # Issue 8 port: same markdown demote applies if the bash command writes
  # to a markdown file (sed -i / tee / cp / mv / redirect to *.md).
  if [ "$tool" = "Bash" ] || [ "$tool" = "shell" ]; then
    local cmd
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty')
    if [ -n "$cmd" ] && [ -n "$session_id" ]; then
      local state blockers
      state=$(pekg_state_read "$session_id" 2>/dev/null || true)
      if [ -n "$state" ]; then
        blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
        if pekg_has_active_blockers "$blockers" && pekg_is_workspace_mutation_cmd "$cmd"; then
          local effective_blockers
          if pekg_bash_cmd_targets_markdown "$cmd"; then
            effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "<bash-target>.md")
          else
            effective_blockers="$blockers"
          fi
          if pekg_has_active_blockers "$effective_blockers"; then
            local reason
            reason=$(pekg_format_denial_reason "$effective_blockers")
            deny "$reason"$'\n\nDangerous bash command detected (sed -i / tee / file redirect / git apply / etc).'
          fi
        fi
      fi
    fi
  fi

  # A57: file content pre-capture for diff computation in posttooluse.
  if [ "$tool" = "Edit" ] || [ "$tool" = "Write" ] || [ "$tool" = "apply_patch" ]; then
    local pp
    pp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
    if [ -n "$pp" ] && [ -n "$session_id" ] && [ -f "$pp" ]; then
      local cap_dir="$HOME/.pekg/precap/${session_id}"
      mkdir -p "$cap_dir" 2>/dev/null || true
      local safe
      safe=$(printf '%s' "$pp" | base64 | tr -d '\n=' | tr '/+' '__')
      head -c 102400 "$pp" > "$cap_dir/${safe}.before" 2>/dev/null || true
    fi
  fi

  # A23: task/subagent blocker propagation — DISABLED on Codex.
  # Codex 0.122+ schema parses `updatedInput` from PreToolUse but explicitly
  # REJECTS it as unsupported (codex-rs/hooks/src/engine/output_parser.rs:
  # "PreToolUse hook returned unsupported updatedInput"). The mutation is
  # discarded. There is no other primitive on Codex to mutate tool_input
  # from a hook (verified 2026-04-26 against schemas at
  # github.com/openai/codex/blob/main/codex-rs/hooks/schema/generated/).
  #
  # Net effect: blockers still propagate to subagents via the persisted
  # state envelope (A14). When the spawned subagent runs ITS OWN PreToolUse,
  # it reads the same ~/.pekg/sessions/<sid>.json and A5b enforcement fires
  # there. The propagation works — just via shared state, not in-flight
  # prompt mutation. If Codex adds input mutation in a future release, port
  # the mutation block from plugins/claude-code/hooks/pretooluse.sh.
  case "$tool" in
    spawn_agents_on_csv|spawn_agent|agent)
      : # Subagent inherits blockers via state envelope on its own PreToolUse fire.
      ;;
  esac

  # A5a proactive context fetch on read/grep/glob.
  case "$tool" in
    Read|read)
      local rp
      rp=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
      [ -n "$rp" ] && [ -n "$session_id" ] && pekg_proactive_fetch "$session_id" "$(basename "$rp")"
      ;;
    Grep|grep|Glob|glob)
      local pattern
      pattern=$(printf '%s' "$input" | jq -r '.tool_input.pattern // .tool_input.query // empty')
      [ -n "$pattern" ] && [ -n "$session_id" ] && pekg_proactive_fetch "$session_id" "$pattern"
      ;;
  esac

  allow
}

pekg_proactive_fetch() {
  local sid="$1" query="$2"
  pekg_offline && return 0
  local project payload
  project=$(pekg_project_origin "$PWD")
  payload=$(jq -n --arg p "$project" --arg q "$query" '{projectOrigin:$p, query:$q}')
  (
    local result count i
    result=$(pekg_post_json "/api/v1/search" "$payload" 3 2>/dev/null || true)
    [ -z "$result" ] && exit 0
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
