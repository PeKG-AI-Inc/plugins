#!/usr/bin/env bash
# PeKG BYOLLM child-session subprocess wrapper (A12 + A12a/b/c/d/e).
#
# Spawns the host CLI in non-interactive mode to run a verification prompt
# without polluting the parent's transcript. Returns parsed JSON or null.
#
# Per host:
#   - Claude Code: `claude -p '<prompt>' --output-format json` → JSONL stream;
#     we extract the final assistant message text and parse as JSON.
#   - Codex:       `codex exec --ephemeral --json --output-schema <path> '<prompt>'`
#     → JSONL of {turn,item} events; we extract `turn.completed` final text.
#
# Source after config.sh, fetch.sh, state.sh.

PEKG_BYOLLM_TIMEOUT="${PEKG_BYOLLM_TIMEOUT:-30}"
# A56: small-model preference for verifier subprocesses. Default to haiku for
# Claude Code (cheap, fast); user can override via env. For Codex, default
# to gpt-5.4-nano (per project convention).
PEKG_BYOLLM_CLAUDE_MODEL="${PEKG_BYOLLM_CLAUDE_MODEL:-haiku}"
PEKG_BYOLLM_CODEX_MODEL="${PEKG_BYOLLM_CODEX_MODEL:-gpt-5.4-nano}"

# Detect host CLI. Prefer the CLI that's CURRENTLY invoking the hook, not just
# whichever binary happens to be installed first. Use env vars set by the
# host CLI (CLAUDE_PROJECT_DIR for Claude Code; CODEX_HOME or codex-specific
# vars for Codex). Falls back to binary presence for unambiguous installs.
pekg_byollm_host() {
  if [ -n "${PEKG_BYOLLM_HOST_OVERRIDE:-}" ]; then
    printf '%s' "$PEKG_BYOLLM_HOST_OVERRIDE"
    return 0
  fi
  # In-Claude-Code signal (CLAUDE_PROJECT_DIR or CLAUDE_SESSION_ID).
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] || [ -n "${CLAUDE_SESSION_ID:-}" ] || [ -n "${CLAUDE_ENV_FILE:-}" ]; then
    if command -v claude >/dev/null 2>&1; then
      printf 'claude-code'
      return 0
    fi
  fi
  # In-Codex signal (CODEX_HOME).
  if [ -n "${CODEX_HOME:-}" ] && command -v codex >/dev/null 2>&1; then
    printf 'codex'
    return 0
  fi
  # Fallbacks by binary presence (when invoked outside a host CLI).
  if command -v claude >/dev/null 2>&1; then
    printf 'claude-code'
    return 0
  fi
  if command -v codex >/dev/null 2>&1 && [ -d "$HOME/.codex" ]; then
    printf 'codex'
    return 0
  fi
  printf 'unknown'
}

# pekg_byollm_run <session-id> <system-prompt> <user-prompt> <expected-schema-json>
# Returns parsed JSON on stdout, exit 0 on success / 1 on failure.
# Honors A29 cost cap; budget-side accounting done by caller.
pekg_byollm_run() {
  local sid="$1"
  local system_prompt="$2"
  local user_prompt="$3"
  local schema="${4:-}"

  pekg_offline && return 1

  local host
  host=$(pekg_byollm_host)
  case "$host" in
    claude-code)
      pekg_byollm_run_claude "$sid" "$system_prompt" "$user_prompt"
      ;;
    codex)
      pekg_byollm_run_codex "$sid" "$system_prompt" "$user_prompt" "$schema"
      ;;
    *)
      return 1
      ;;
  esac
}

# Claude Code: `claude -p` returns JSONL. Pull the final assistant text.
pekg_byollm_run_claude() {
  local sid="$1" sys="$2" usr="$3"

  # Empty-args guard (per OpenCode plugin gotcha: empty prompt args can crash
  # the host CLI's TUI / parser). Refuse the spawn if either arg is empty.
  if [ -z "$sys" ] || [ -z "$usr" ]; then
    return 1
  fi

  # Recursion guard: if we're already inside a PeKG-spawned child session,
  # decline to spawn another one (prevents recursive verification loops).
  if [ "${PEKG_BYOLLM_RECURSING:-0}" = "1" ]; then
    return 1
  fi

  # Refuse if claude binary is absent (defensive — installer should ensure it).
  command -v claude >/dev/null 2>&1 || return 1

  local raw
  raw=$(PEKG_BYOLLM_RECURSING=1 \
    PEKG_LEGACY_STATUS_GATE=0 \
    timeout "$PEKG_BYOLLM_TIMEOUT" \
    claude -p "$usr" \
      --append-system-prompt "$sys" \
      --output-format json \
      --dangerously-skip-permissions \
      --model "$PEKG_BYOLLM_CLAUDE_MODEL" \
      2>/dev/null) || return 1

  [ -z "$raw" ] && return 1

  # claude -p --output-format json emits a single JSON object with .result
  # containing the assistant's response text; or for streaming, a stream of
  # events. Try both shapes.
  local text
  text=$(printf '%s' "$raw" | jq -r '.result // .response // empty' 2>/dev/null)
  if [ -z "$text" ]; then
    # Try streaming form: last event with text content.
    text=$(printf '%s' "$raw" | jq -rs '
      [.[] | select(.type == "result" or .type == "completion") | .result // .text // empty]
      | last // empty
    ' 2>/dev/null)
  fi

  [ -z "$text" ] && return 1

  # Try to parse the text as JSON; if it isn't, wrap it.
  if printf '%s' "$text" | jq empty >/dev/null 2>&1; then
    printf '%s' "$text"
  else
    jq -n --arg t "$text" '{result: $t}'
  fi
}

# Codex: `codex exec --ephemeral --json` emits JSONL events.
pekg_byollm_run_codex() {
  local sid="$1" sys="$2" usr="$3" schema="$4"

  if [ -z "$sys" ] || [ -z "$usr" ]; then
    return 1
  fi
  if [ "${PEKG_BYOLLM_RECURSING:-0}" = "1" ]; then
    return 1
  fi
  command -v codex >/dev/null 2>&1 || return 1

  local schema_arg=()
  if [ -n "$schema" ]; then
    local schema_path="$HOME/.pekg/.byollm-schema.$$.json"
    printf '%s' "$schema" > "$schema_path" 2>/dev/null && schema_arg=(--output-schema "$schema_path")
  fi

  local prompt
  prompt=$(printf '%s\n\n%s' "$sys" "$usr")

  local raw
  raw=$(PEKG_BYOLLM_RECURSING=1 \
    timeout "$PEKG_BYOLLM_TIMEOUT" \
    codex exec --ephemeral --json --skip-git-repo-check \
      -c "model=\"$PEKG_BYOLLM_CODEX_MODEL\"" \
      "${schema_arg[@]}" "$prompt" \
      2>/dev/null) || true

  [ -n "${schema_path:-}" ] && rm -f "$schema_path" 2>/dev/null

  [ -z "$raw" ] && return 1

  # Walk JSONL for the last completion text.
  local text
  text=$(printf '%s' "$raw" | jq -rs '
    [.[] | select(.type == "turn.completed" or .item.type == "agent_message") |
      (.item.text // .turn.text // .text // empty)]
    | map(select(length > 0)) | last // empty
  ' 2>/dev/null)

  [ -z "$text" ] && return 1

  if printf '%s' "$text" | jq empty >/dev/null 2>&1; then
    printf '%s' "$text"
  else
    jq -n --arg t "$text" '{result: $t}'
  fi
}

# A29: increment cost counter on session state. Returns 0 if budget remains, 1 if exhausted.
pekg_byollm_charge() {
  local sid="$1"
  local cost="${2:-1}"   # 1 for normal, "0.5" string for failed runs
  local cap="${PEKG_MAX_CHILD_VERIFICATIONS:-5}"
  local cur task verif_count new_count blockers

  cur=$(pekg_state_read "$sid" 2>/dev/null || echo '{}')
  task=$(printf '%s' "$cur" | jq -c '.task // {}')
  verif_count=$(printf '%s' "$task" | jq -r '.verifCount // 0')

  # Cap check before charging.
  awk -v c="$verif_count" -v cap="$cap" 'BEGIN { exit !(c >= cap) }' && return 1

  new_count=$(awk -v c="$verif_count" -v add="$cost" 'BEGIN { printf "%.2f", c + add }')
  task=$(printf '%s' "$task" | jq -c --arg n "$new_count" '.verifCount = ($n | tonumber)')
  blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
  pekg_state_write "$sid" "$task" "$blockers"
  return 0
}

pekg_byollm_charge_failure() {
  pekg_byollm_charge "$1" "0.5"
}

# A12a: blocker ack verifier. Args: session-id, blockers JSON, agent text.
# Returns 0 if BYOLLM verifies ack, 1 otherwise.
pekg_byollm_verify_ack() {
  local sid="$1"
  local blockers="$2"
  local agent_text="$3"

  pekg_byollm_charge "$sid" 1 || return 1  # cost cap exceeded — caller falls back to heuristic

  local sys usr resp verified
  sys="You are a PeKG verification model. Your only job is to decide whether the agent has properly acknowledged blockers. ACCEPT only if the agent (a) quotes each blocker title verbatim AND (b) describes a concrete mitigation. REJECT vague phrases like 'acknowledged', 'noted', 'I understand', 'I'll be careful'. Output ONLY a JSON object: {\"verified\": true} or {\"verified\": false, \"reason\": \"...\"}."
  usr="Blockers:\n$blockers\n\nAgent response:\n$agent_text"

  resp=$(pekg_byollm_run "$sid" "$sys" "$usr" \
    '{"type":"object","properties":{"verified":{"type":"boolean"},"reason":{"type":"string"}},"required":["verified"]}' \
    2>/dev/null) || { pekg_byollm_charge_failure "$sid"; return 1; }

  verified=$(printf '%s' "$resp" | jq -r '.verified // false' 2>/dev/null)
  [ "$verified" = "true" ]
}

# A12b: feedback accuracy classifier. Returns one of: applied | avoided_bug | ignored | empty.
pekg_byollm_classify_feedback() {
  local sid="$1"
  local article_title="$2"
  local article_summary="$3"
  local agent_text="$4"

  pekg_byollm_charge "$sid" 1 || return 1

  local sys usr resp signal
  sys="You are a PeKG verification model. Decide whether the agent applied an article's recommendation, avoided a bug it warned about, or ignored it. Output ONLY a JSON object: {\"signal\":\"applied|avoided_bug|ignored\"}."
  usr=$(printf 'Article: %s\n\nArticle summary:\n%s\n\nAgent response:\n%s' "$article_title" "$article_summary" "$agent_text")

  resp=$(pekg_byollm_run "$sid" "$sys" "$usr" \
    '{"type":"object","properties":{"signal":{"type":"string","enum":["applied","avoided_bug","ignored"]}},"required":["signal"]}' \
    2>/dev/null) || { pekg_byollm_charge_failure "$sid"; return 1; }

  signal=$(printf '%s' "$resp" | jq -r '.signal // empty' 2>/dev/null)
  [ -z "$signal" ] && return 1
  printf '%s' "$signal"
}

# A12e: diff ingest analysis. Decides shouldIngest + title + content for a diff.
# Returns JSON {shouldIngest, title, type, content} on success.
pekg_byollm_analyze_diff() {
  local sid="$1"
  local file_path="$2"
  local diff="$3"

  pekg_byollm_charge "$sid" 1 || return 1

  local sys usr resp
  sys="You analyze code diffs and decide if they contain reusable knowledge for a personal knowledge graph. Set shouldIngest=true ONLY if the diff teaches a non-obvious pattern, decision, gotcha, or learning that would help with similar work later. Set shouldIngest=false for trivial changes (renames, formatting, version bumps). Output ONLY JSON: {\"shouldIngest\":boolean,\"title\":\"<short title>\",\"type\":\"pattern|decision|bug_fix|learning|gotcha\",\"content\":\"<markdown body>\"}."
  usr=$(printf 'File: %s\n\nDiff:\n```\n%s\n```' "$file_path" "$diff")

  resp=$(pekg_byollm_run "$sid" "$sys" "$usr" \
    '{"type":"object","properties":{"shouldIngest":{"type":"boolean"},"title":{"type":"string"},"type":{"type":"string"},"content":{"type":"string"}},"required":["shouldIngest"]}' \
    2>/dev/null) || { pekg_byollm_charge_failure "$sid"; return 1; }

  printf '%s' "$resp"
}
