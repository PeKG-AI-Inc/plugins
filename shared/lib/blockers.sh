#!/usr/bin/env bash
# PeKG blocker enforcement (A5b, A8, A48 NETWORK_BLOCKER, A59 clearance semantics,
# A30 deterministic ack heuristic). Source after config.sh, fetch.sh, state.sh.

PEKG_NETWORK_BLOCKER_ID="00000000-0000-0000-0000-pekgNetworkErr"

# A48: synthesize a NETWORK_BLOCKER for inclusion in state when API unreachable.
# Returns an empty array when PEKG_OFFLINE=1 — the user has explicitly opted out
# of gating, so persisting a network blocker only creates a deadlock the next
# time pekg_has_active_blockers reads state (the gate doesn't re-check offline).
pekg_synth_network_blocker() {
  if pekg_offline; then
    printf '%s' '[]'
    return 0
  fi
  jq -n '[{
    id: "00000000-0000-0000-0000-pekgNetworkErr",
    title: "PeKG unreachable",
    recommendation: "Network or auth error reaching api.pekg.ai. Edits gated until reachable. Set PEKG_OFFLINE=1 to bypass.",
    tier: "blocker"
  }]'
}

# A48 inverse: take blockers JSON, remove NETWORK_BLOCKER entries, return cleaned.
pekg_strip_network_blocker() {
  local blockers="${1:-[]}"
  printf '%s' "$blockers" | jq --arg id "$PEKG_NETWORK_BLOCKER_ID" '[.[] | select(.id != $id)]'
}

# A5b: given blockers JSON array, return 0 if any unacknowledged blocker exists.
# PEKG_OFFLINE=1 short-circuits to "no blockers" — the env var is the documented
# escape hatch, so it must override even pre-existing persisted state. Without
# this check, an old NETWORK_BLOCKER from a prior online session would deadlock
# offline mode on every prompt (because synthesis only writes; the gate reads).
pekg_has_active_blockers() {
  if pekg_offline; then
    return 1
  fi
  local blockers="${1:-[]}"
  local count
  count=$(printf '%s' "$blockers" | jq 'length' 2>/dev/null || echo 0)
  [ "$count" -gt 0 ]
}

# A8 / A5b: build the rich denial reason text given blockers JSON array.
pekg_format_denial_reason() {
  local blockers="${1:-[]}"
  printf '%s' "$blockers" | jq -r '
    "PeKG: \(length) active blocker(s). Address before file-mutating tools work:\n" +
    (map("- \(.title): \(.recommendation // "no recommendation")") | join("\n")) +
    "\n\nAck format: quote the blocker title verbatim AND describe the concrete mitigation. Generic acknowledgments (\"acknowledged\", \"noted\", \"will be careful\") are rejected."
  '
}

# A30: deterministic-ack heuristic. Given blockers JSON + agent text, return 0
# if every blocker is acknowledged with title quote AND non-generic action.
pekg_heuristic_ack() {
  local blockers="${1:-[]}"
  local text="${2:-}"

  local generic_re='(acknowledged|noted|i understand|will be careful|got it|ok\b|okay\b|sure\b)'

  local titles
  titles=$(printf '%s' "$blockers" | jq -r '.[].title // empty')
  [ -z "$titles" ] && return 0  # No blockers = trivially "acked".

  while IFS= read -r title; do
    [ -z "$title" ] && continue
    # Title must appear verbatim (case-insensitive substring).
    if ! printf '%s' "$text" | grep -iqF -- "$title"; then
      return 1
    fi
  done <<< "$titles"

  # And the response must contain at least one non-generic action verb.
  if printf '%s' "$text" | grep -iqE '\b(replace|use|switch|migrate|add|remove|fix|refactor|change|update|configure|disable|enable|set|export|import|wrap|guard|check|validate|cast|null-check|sanitize)\b'; then
    return 0
  fi
  return 1
}

# FILE_MUTATING_TOOLS set per A26. Each adapter passes the host's tool name.
pekg_is_mutating_tool() {
  case "$1" in
    Edit|Write|MultiEdit|NotebookEdit|str_replace_editor|str_replace_based_edit|apply_patch|patch|edit|write|multiedit|multi_edit) return 0 ;;
    Bash|bash|shell|run_terminal_cmd) return 0 ;;
    *) return 1 ;;
  esac
}

# Issue 6 (relevance floor): per-tier plugin-side floor that's stricter than
# the server's RELEVANCE_THRESHOLD=0.5. Server keeps the loose floor for
# non-gating clients (dashboard search, MCP tool callers); plugins are
# opinionated about gating quality.
#
# Demote-not-drop: a blocker between 0.55 and 0.65 becomes a warning
# (visible, non-gating) rather than disappearing. Items below the warning
# floor (0.55) drop out entirely.
#
# Mirrors PEKG_BLOCKER_FLOOR / PEKG_WARNING_FLOOR / PEKG_INFO_FLOOR in
# plugins/opencode/opencode.ts. **All three lists must stay in sync.**
PEKG_BLOCKER_FLOOR="0.65"
PEKG_WARNING_FLOOR="0.55"
PEKG_INFO_FLOOR="0.7"

# Issue 6: apply per-tier floors to a JSON array of context articles.
# Each article must have .tier and .relevance. Demotes blockers below the
# blocker floor to warning; drops items still below their tier's floor.
#
# Args: articles_json
pekg_apply_tier_floor() {
  local articles="${1:-[]}"
  printf '%s' "$articles" | jq -c \
    --argjson bf "$PEKG_BLOCKER_FLOOR" \
    --argjson wf "$PEKG_WARNING_FLOOR" \
    --argjson if "$PEKG_INFO_FLOOR" '
    map(
      # 1. Demote blockers below blocker floor to warning.
      if .tier == "blocker" and (.relevance // 0) < $bf
      then .tier = "warning"
      else . end
    )
    | map(
      # 2. Drop items still below their tier'\''s floor.
      select(
        (.tier == "blocker" and (.relevance // 0) >= $bf) or
        (.tier == "warning" and (.relevance // 0) >= $wf) or
        (.tier == "info"    and (.relevance // 0) >= $if)
      )
    )
  '
}

# Issue 8 (markdown re-tier): keyword sets used by pekg_effective_tier and
# pekg_filter_blockers_for_file. **Must stay in sync with
# packages/shared/src/code-domain.ts and the inline copies in
# plugins/opencode/opencode.ts.** When adding/removing keywords, update
# all three places. Drift detection lives in CI (see plugins/tests/run.sh).
PEKG_CODE_DOMAIN_KEYWORDS="function async await hook sql query parse plugin config server route endpoint mcp opencode typescript javascript regex stream promise fetch request response schema migration react vue css ui frontend docker kubernetes redis postgres drizzle"
PEKG_NON_CODE_KEYWORDS="security vulnerability credential secret auth privacy pii compliance audit documentation readme changelog policy license"
PEKG_MARKDOWN_EXT_RE='\.(md|mdx|txt|rst|adoc)$'

# Issue 8: returns 0 if the path is a markdown / docs file extension.
pekg_is_markdown_path() {
  local path="${1:-}"
  [ -z "$path" ] && return 1
  printf '%s' "$path" | grep -qiE "$PEKG_MARKDOWN_EXT_RE"
}

# Issue 8: prefix-match (so plurals / -ed / -ing variants count) of any
# keyword in the second-arg space-separated list against the first-arg text.
# Lowercased; word-boundary on left only ("\bcredential" matches both
# "credential" and "credentials"). Returns 0 if any match.
pekg_text_matches_any() {
  local text="${1:-}"
  local kws="${2:-}"
  local lower
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  local kw
  for kw in $kws; do
    if printf '%s' "$lower" | grep -qE "\b${kw}"; then
      return 0
    fi
  done
  return 1
}

# Issue 8: effective-tier decision for ONE blocker given file context.
# Echoes the effective tier — same as input.tier unless markdown context
# triggers blocker→warning demote. Security/privacy/compliance/docs
# carve-out keeps blocker tier even on markdown. Empty-keyword blockers
# default to demote (safer for doc work).
#
# Args: tier title summary file_path
pekg_effective_tier() {
  local tier="${1:-info}"
  local title="${2:-}"
  local summary="${3:-}"
  local file_path="${4:-}"
  if [ "$tier" != "blocker" ]; then printf '%s' "$tier"; return; fi
  if ! pekg_is_markdown_path "$file_path"; then printf '%s' "$tier"; return; fi
  local text="${title} ${summary}"
  if pekg_text_matches_any "$text" "$PEKG_NON_CODE_KEYWORDS"; then
    printf '%s' "$tier"
    return
  fi
  printf '%s' "warning"
}

# Issue 8: filter a blockers JSON array, returning only the ones whose
# effective tier remains "blocker" given the file path context. Used by
# the gate decision in pretooluse.sh.
#
# Args: blockers_json file_path
pekg_filter_blockers_for_file() {
  local blockers="${1:-[]}"
  local file_path="${2:-}"
  if ! pekg_is_markdown_path "$file_path"; then
    # Non-markdown context: no demote applies; return blockers verbatim.
    printf '%s' "$blockers"
    return
  fi
  # On markdown: filter through pekg_effective_tier per element. Use jq
  # to map then drop the demoted ones (which are now "warning").
  local out="[]"
  local count
  count=$(printf '%s' "$blockers" | jq 'length' 2>/dev/null || echo 0)
  if [ "$count" = "0" ]; then printf '%s' "[]"; return; fi
  local i
  for ((i=0; i<count; i++)); do
    local row tier title summary effective
    row=$(printf '%s' "$blockers" | jq -c ".[$i]")
    tier=$(printf '%s' "$row" | jq -r '.tier // "blocker"')
    title=$(printf '%s' "$row" | jq -r '.title // ""')
    summary=$(printf '%s' "$row" | jq -r '.summary // .recommendation // ""')
    effective=$(pekg_effective_tier "$tier" "$title" "$summary" "$file_path")
    if [ "$effective" = "blocker" ]; then
      out=$(printf '%s' "$out" | jq -c ". + [${row}]")
    fi
  done
  printf '%s' "$out"
}

# Issue 8: detect bash command writing to markdown file. Mirror of
# pekgBashCmdTargetsMarkdown in opencode.ts.
pekg_bash_cmd_targets_markdown() {
  local cmd="${1:-}"
  printf '%s' "$cmd" | grep -qiE '(\bsed\s+-[A-Za-z]*i\b|\btee\b|>>?\s*|\bcp\b|\bmv\b)[^|;&]*\.(md|mdx|txt|rst|adoc)\b'
}

# A17: dangerous-bash detection. Returns 0 if the bash command is a
# workspace file mutation. Whitelists scratch dirs (/tmp, /var/folders,
# $TMPDIR, $HOME/.cache, $HOME/.pekg, $HOME/Library/Caches) so commands
# writing to non-workspace paths aren't gated as mutations.
pekg_is_workspace_mutation_cmd() {
  local cmd="${1:-}"
  # File redirects to a workspace path
  if pekg_redirect_targets_workspace "$cmd"; then return 0; fi
  # In-place editors
  if printf '%s' "$cmd" | grep -qE '(^|\s)(sed -i|perl -pi|awk -i inplace|tee\s)'; then return 0; fi
  # Heredoc with redirect
  if printf '%s' "$cmd" | grep -qE '<<\s*EOF.*>'; then return 0; fi
  # Python/Node/Ruby file write idioms
  if printf '%s' "$cmd" | grep -qE 'open\([^)]+,\s*["'\'']w'; then return 0; fi
  if printf '%s' "$cmd" | grep -qE 'fs\.(write|append|create)'; then return 0; fi
  # Git mutating subcommands
  if printf '%s' "$cmd" | grep -qE '(^|\s)git (apply|restore|checkout)'; then return 0; fi
  return 1
}

# Returns 0 if any `>`, `>>`, or `&>` redirect in the command targets a
# workspace path (i.e., not a scratch dir or fd alias). Targets like
# `&1`, `/dev/null`, `/tmp/foo`, `$TMPDIR/bar`, `$HOME/.cache/baz` are
# NOT considered workspace mutations.
pekg_redirect_targets_workspace() {
  local cmd="${1:-}"
  # Quick reject: no redirect operators at all
  printf '%s' "$cmd" | grep -qE '([0-9]?>>?|&>)' || return 1
  # Extract all redirect targets (operator + first non-space token)
  local targets t
  targets=$(printf '%s' "$cmd" \
    | grep -oE '([0-9]?>>?|&>)[[:space:]]*[^[:space:]|;&`]+' \
    | sed -E 's/^([0-9]?>>?|&>)[[:space:]]*//')
  while IFS= read -r t; do
    [ -z "$t" ] && continue
    # Fd alias (e.g. &1, &2): not a file write. Quote the literal & so bash
    # doesn't parse it as the background operator.
    case "$t" in '&'*) continue ;; esac
    # Scratch dirs: not workspace
    case "$t" in
      /dev/*|/tmp/*|/var/tmp/*|/var/folders/*|/private/var/folders/*) continue ;;
      "$HOME"/.cache/*|"$HOME"/.pekg/*|"$HOME"/Library/Caches/*) continue ;;
    esac
    if [ -n "${TMPDIR:-}" ]; then
      case "$t" in "$TMPDIR"*) continue ;; esac
    fi
    return 0
  done <<< "$targets"
  return 1
}
