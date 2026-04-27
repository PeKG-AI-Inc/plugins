#!/usr/bin/env bash
# PeKG feedback queue persistence + replay (A32).
# Source after config.sh, fetch.sh.

PEKG_FEEDBACK_QUEUE_DIR="$HOME/.pekg/feedback-queue"
PEKG_FEEDBACK_REPLAY_MAX="${PEKG_FEEDBACK_REPLAY_MAX:-10}"
PEKG_FEEDBACK_COOLDOWN_FILE="$HOME/.pekg/.feedback-cooldown.json"
PEKG_FEEDBACK_COOLDOWN_S="${PEKG_FEEDBACK_COOLDOWN_S:-30}"
PEKG_SHOWN_ARTICLES_FILE="$HOME/.pekg/.shown-articles.json"
PEKG_SHOWN_ARTICLES_TTL_S="${PEKG_SHOWN_ARTICLES_TTL_S:-3600}"

# A31a: per-article feedback cooldown. Returns 0 if allowed, 1 if cooled-down.
pekg_feedback_check_cooldown() {
  local article_id="$1"
  [ -z "$article_id" ] && return 0
  [ -f "$PEKG_FEEDBACK_COOLDOWN_FILE" ] || return 0
  local now last
  now=$(date +%s)
  last=$(jq -r --arg id "$article_id" '.[$id] // 0' "$PEKG_FEEDBACK_COOLDOWN_FILE" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$PEKG_FEEDBACK_COOLDOWN_S" ] && return 1
  return 0
}

pekg_feedback_record_cooldown() {
  local article_id="$1"
  [ -z "$article_id" ] && return 0
  mkdir -p "$(dirname "$PEKG_FEEDBACK_COOLDOWN_FILE")" 2>/dev/null
  local now cur
  now=$(date +%s)
  cur='{}'
  [ -f "$PEKG_FEEDBACK_COOLDOWN_FILE" ] && cur=$(cat "$PEKG_FEEDBACK_COOLDOWN_FILE" 2>/dev/null || echo '{}')
  # Also opportunistically prune entries older than 1h.
  printf '%s' "$cur" | jq --arg id "$article_id" --arg now "$now" --arg ttl "3600" \
    '. + {($id): ($now | tonumber)} | with_entries(select(.value > (($now | tonumber) - ($ttl | tonumber))))' \
    > "${PEKG_FEEDBACK_COOLDOWN_FILE}.tmp" && mv "${PEKG_FEEDBACK_COOLDOWN_FILE}.tmp" "$PEKG_FEEDBACK_COOLDOWN_FILE"
}

# A31b: shown-articles tracking with TTL cleanup.
pekg_shown_record() {
  local sid="$1"
  shift
  local article_ids="$*"   # space-separated
  [ -z "$article_ids" ] && return 0
  mkdir -p "$(dirname "$PEKG_SHOWN_ARTICLES_FILE")" 2>/dev/null
  local now cur
  now=$(date +%s)
  cur='{}'
  [ -f "$PEKG_SHOWN_ARTICLES_FILE" ] && cur=$(cat "$PEKG_SHOWN_ARTICLES_FILE" 2>/dev/null || echo '{}')
  local ids_json
  ids_json=$(printf '%s\n' $article_ids | jq -R -s -c 'split("\n") | map(select(length > 0))')
  # Add new ids to session bucket; prune buckets older than TTL.
  printf '%s' "$cur" | jq --arg sid "$sid" --argjson new "$ids_json" --arg now "$now" --arg ttl "$PEKG_SHOWN_ARTICLES_TTL_S" \
    '
      .[$sid] = (
        (.[$sid] // {articles: [], timestamp: ($now | tonumber)})
        | .articles = ((.articles + $new) | unique)
        | .timestamp = ($now | tonumber)
      )
      | with_entries(select(.value.timestamp > (($now | tonumber) - ($ttl | tonumber))))
    ' > "${PEKG_SHOWN_ARTICLES_FILE}.tmp" && mv "${PEKG_SHOWN_ARTICLES_FILE}.tmp" "$PEKG_SHOWN_ARTICLES_FILE"
}

pekg_shown_check() {
  local sid="$1" article_id="$2"
  [ -f "$PEKG_SHOWN_ARTICLES_FILE" ] || return 1
  local found
  found=$(jq -r --arg sid "$sid" --arg id "$article_id" \
    '(.[$sid].articles // []) | index($id) // empty' "$PEKG_SHOWN_ARTICLES_FILE" 2>/dev/null)
  [ -n "$found" ]
}

# pekg_feedback_submit <article-id> <signal> <context-json-or-empty>
# Tries POST /api/v1/feedback; on failure, queues for later replay.
pekg_feedback_submit() {
  local article_id="$1" signal="$2" ctx="${3:-{\}}"
  [ -z "$article_id" ] && return 1

  # A31a: skip if within per-article cooldown window.
  pekg_feedback_check_cooldown "$article_id" || return 0

  local payload
  payload=$(jq -n --arg id "$article_id" --arg s "$signal" --argjson c "$ctx" \
    '{articleId: $id, signal: $s, context: $c}')

  if pekg_offline; then
    pekg_feedback_queue "$payload"
    pekg_feedback_record_cooldown "$article_id"
    return 0
  fi

  if pekg_post_json "/api/v1/feedback" "$payload" 3 >/dev/null 2>&1; then
    pekg_feedback_record_cooldown "$article_id"
    return 0
  fi
  pekg_feedback_queue "$payload"
  pekg_feedback_record_cooldown "$article_id"
}

pekg_feedback_queue() {
  local payload="$1"
  mkdir -p "$PEKG_FEEDBACK_QUEUE_DIR" 2>/dev/null || true
  chmod 700 "$PEKG_FEEDBACK_QUEUE_DIR" 2>/dev/null || true
  local fname="$(date +%s)-$$-$RANDOM.json"
  printf '%s' "$payload" > "$PEKG_FEEDBACK_QUEUE_DIR/$fname"
}

# Replay up to N queued feedback items. Called from SessionStart on success path.
pekg_feedback_replay() {
  [ -d "$PEKG_FEEDBACK_QUEUE_DIR" ] || return 0
  pekg_offline && return 0
  local count=0
  for fb_file in "$PEKG_FEEDBACK_QUEUE_DIR"/*.json; do
    [ -f "$fb_file" ] || continue
    [ "$count" -ge "$PEKG_FEEDBACK_REPLAY_MAX" ] && break
    local body
    body=$(cat "$fb_file" 2>/dev/null || true)
    [ -z "$body" ] && { rm -f "$fb_file"; continue; }
    if pekg_post_json "/api/v1/feedback" "$body" 3 >/dev/null 2>&1; then
      rm -f "$fb_file"
    fi
    count=$((count + 1))
  done
}
