#!/usr/bin/env bash
# PeKG proactive-context delivery queue (A21/A22/A41).
# Pre-tool hooks queue context-fetch results here; next UserPromptSubmit drains.

# Queue file location (per session).
pekg_queue_path() {
  local sid="$1"
  printf '%s/%s.pending.json' "$PEKG_SESSION_DIR" "$sid"
}

# pekg_queue_push <sessionId> <article-json>
# Appends a single article object (with .articleId, .title, .summary, .tier).
# Idempotent: skip if same articleId already queued.
pekg_queue_push() {
  local sid="$1"
  local article="$2"
  pekg_state_ensure_dir
  local path
  path=$(pekg_queue_path "$sid")

  local cur='[]'
  [ -f "$path" ] && cur=$(cat "$path" 2>/dev/null || echo '[]')

  local aid
  aid=$(printf '%s' "$article" | jq -r '.articleId // empty' 2>/dev/null)

  if [ -n "$aid" ]; then
    # De-dupe by articleId.
    local has
    has=$(printf '%s' "$cur" | jq --arg id "$aid" 'any(.articleId == $id)' 2>/dev/null || echo false)
    [ "$has" = "true" ] && return 0
  fi

  local tmp="${path}.tmp.$$"
  printf '%s' "$cur" | jq -c --argjson a "$article" '. + [$a] | .[-50:]' > "$tmp" 2>/dev/null \
    && mv "$tmp" "$path" || rm -f "$tmp"
}

# pekg_queue_drain <sessionId>
# Reads + clears the queue. Echoes JSON array.
pekg_queue_drain() {
  local sid="$1"
  local path
  path=$(pekg_queue_path "$sid")
  if [ -f "$path" ]; then
    cat "$path"
    rm -f "$path" 2>/dev/null || true
  else
    echo '[]'
  fi
}
