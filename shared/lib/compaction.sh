#!/usr/bin/env bash
# PeKG flash compaction prompt builder (A4a + A54).
# Source after config.sh, state.sh.
# Output: a structured markdown block delivered via PreCompact additionalContext.

# pekg_build_flash_compaction_prompt <sessionId> <projectOrigin>
# Reads persisted state, assembles the same sections OpenCode plugin uses:
#   ## Project, ## Instructions, ## Current Task, ## Active Files,
#   ## Failed Approaches, ## Completed Steps, ## Active Blockers
pekg_build_flash_compaction_prompt() {
  local sid="$1"
  local project="${2:-unknown}"

  local state task blockers
  state=$(pekg_state_read "$sid" 2>/dev/null || echo '{}')
  task=$(printf '%s' "$state" | jq -c '.task // {}')
  blockers=$(printf '%s' "$state" | jq -c '.blockers // []')

  local current_task files_modified files_read failed_approaches completed_steps blocker_lines
  current_task=$(printf '%s' "$task" | jq -r '.currentTask // empty')
  files_modified=$(printf '%s' "$task" | jq -r '.activeFiles.filesModified // [] | .[]?' | sort -u | head -10)
  files_read=$(printf '%s' "$task" | jq -r '.activeFiles.filesRead // [] | .[]?' | sort -u | head -10)
  failed_approaches=$(printf '%s' "$task" | jq -r '.failedApproaches // [] | .[]?' | head -3)
  completed_steps=$(printf '%s' "$task" | jq -r '.completedSteps // [] | .[]?' | head -5)
  blocker_lines=$(printf '%s' "$blockers" | jq -r '.[]? | "- [\(.tier // "blocker")] \(.title): \(.recommendation // "no recommendation")"')

  {
    echo "# PeKG Flash-Compacted Context"
    echo ""
    echo "Treat the rest of this message as system-level resume context. The prior conversation was compacted; the structured state below is authoritative. Continue the work from this state without re-asking questions already answered."
    echo ""
    echo "## Project"
    echo "${project}"
    echo ""
    if [ -n "$current_task" ]; then
      echo "## Current Task"
      printf '%s\n\n' "$current_task"
    fi
    if [ -n "$files_modified" ]; then
      echo "## Files Modified"
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo "- $f"
      done <<< "$files_modified"
      echo ""
    fi
    if [ -n "$files_read" ]; then
      echo "## Files Read"
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo "- $f"
      done <<< "$files_read"
      echo ""
    fi
    if [ -n "$failed_approaches" ]; then
      echo "## Failed Approaches (do NOT repeat)"
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        echo "- $f"
      done <<< "$failed_approaches"
      echo ""
    fi
    if [ -n "$completed_steps" ]; then
      echo "## Completed Steps"
      while IFS= read -r s; do
        [ -z "$s" ] && continue
        echo "- $s"
      done <<< "$completed_steps"
      echo ""
    fi
    if [ -n "$blocker_lines" ]; then
      echo "## Active Blockers (must address)"
      printf '%s\n\n' "$blocker_lines"
    fi
    echo "## Instructions"
    echo "Resume the task without re-fetching context already captured above. Address any active blockers by quoting the title verbatim and describing concrete mitigation; generic acks are rejected."
  }
}
