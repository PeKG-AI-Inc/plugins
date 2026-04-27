#!/usr/bin/env bash
# PeKG PreCompact hook for Claude Code.
# Abilities: A4 partial (A4a structured prompt + A4d cache invalidation).
#           Wall-clock win (A4b) is impossible on Claude Code — host always
#           summarizes; we only ensure PeKG state survives compaction.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.0"
PEKG_UA_PRODUCT="claude-code-pekg-plugin"

# @inline shared/lib/config.sh
# @inline shared/lib/fetch.sh
# @inline shared/lib/state.sh
# @inline shared/lib/blockers.sh
# @inline shared/lib/compaction.sh

main() {
  local input session_id cwd project
  input=$(cat 2>/dev/null || true)
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  [ -z "$session_id" ] && exit 0

  cwd=$(printf '%s' "$input" | jq -r '.cwd // .session.cwd // empty')
  [ -z "$cwd" ] && cwd="$PWD"
  project=$(pekg_project_origin "$cwd")

  pekg_load_config

  # A4a: build structured prompt; injected as additionalContext.
  local prompt
  prompt=$(pekg_build_flash_compaction_prompt "$session_id" "$project")

  # A4d: invalidate per-session caches so post-compaction first message gets fresh fetch.
  local cache_dir="/tmp/pekg-session-${session_id}"
  rm -f "${cache_dir}/seen.txt" "${cache_dir}/first_injected" 2>/dev/null || true

  # A4 max-fidelity (verified 2026-04-26): use replaceCompactSummary:true so
  # our structured PeKG block REPLACES the LLM-generated summary entirely,
  # not just appended after it. Per Claude Code 2.1.105+ via GitHub #24965 —
  # the host's LLM summarization call still runs (host-impossible to suppress;
  # see plan §6.3) but its output is discarded in favor of our prompt.
  jq -n --arg ctx "$prompt" '{
    hookSpecificOutput: {
      hookEventName: "PreCompact",
      additionalContext: $ctx,
      replaceCompactSummary: true
    }
  }'
}

main
