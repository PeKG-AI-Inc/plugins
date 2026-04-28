#!/usr/bin/env bash
# PeKG PostToolUse hook for Claude Code.
# Abilities: legacy status-called marker, A5c/A6b active-files tracking,
#           A6a/A24/A53/A100 tech detection, A21/A22 proactive-context queue,
#           A36 implicit feedback (best-effort) on successful edit.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.87"
PEKG_UA_PRODUCT="claude-code-pekg-plugin"

# --- inlined from shared/lib/config.sh ---
pekg_load_config() {
  PEKG_TOKEN=""
  if [ -n "${PEKG_TOKEN_OVERRIDE:-}" ]; then
    PEKG_TOKEN="$PEKG_TOKEN_OVERRIDE"
    return 0
  fi
  if [ -f "$HOME/.pekg/config.json" ]; then
    PEKG_TOKEN=$(jq -r '.token // empty' "$HOME/.pekg/config.json" 2>/dev/null || true)
  fi
  export PEKG_TOKEN
}

# A16b: Project-origin detection via git rev-parse + cwd basename fallback.
# Cached per-process via PEKG_PROJECT_ORIGIN env. Caller passes desired cwd.
pekg_project_origin() {
  local cwd="${1:-$PWD}"
  if [ -n "${PEKG_PROJECT_ORIGIN:-}" ]; then
    printf '%s' "$PEKG_PROJECT_ORIGIN"
    return 0
  fi
  local git_root
  git_root=$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)
  if [ -n "$git_root" ]; then
    PEKG_PROJECT_ORIGIN=$(basename "$git_root")
  else
    PEKG_PROJECT_ORIGIN=$(basename "$cwd")
  fi
  export PEKG_PROJECT_ORIGIN
  printf '%s' "$PEKG_PROJECT_ORIGIN"
}

# A16c: User-Agent stamping. Each adapter overrides PEKG_UA_PRODUCT.
pekg_ua() {
  local product="${PEKG_UA_PRODUCT:-pekg-plugin}"
  local version="${PEKG_PLUGIN_VERSION:-0.0.0}"
  printf '%s/%s' "$product" "$version"
}

# A16d / A70: PEKG_OFFLINE early-bailout check.
pekg_offline() {
  [ "${PEKG_OFFLINE:-}" = "1" ]
}

# A60: Honor PEKG_FULL_CONTEXT_EVERY_TURN env override.
pekg_full_context_every_turn() {
  [ "${PEKG_FULL_CONTEXT_EVERY_TURN:-}" = "1" ]
}
# --- end inline ---
# --- inlined from shared/lib/fetch.sh ---
PEKG_API_BASE="${PEKG_API_BASE:-https://api.pekg.ai}"
PEKG_DEFAULT_TIMEOUT="${PEKG_DEFAULT_TIMEOUT:-5}"

# A70: Offline mode short-circuits to "no result, no blocker."
# A49: AbortSignal-equivalent via curl --max-time.
pekg_fetch() {
  # Args: METHOD PATH [JSON_BODY] [TIMEOUT_SECONDS]
  local method="$1"
  local path="$2"
  local body="${3:-}"
  local timeout="${4:-$PEKG_DEFAULT_TIMEOUT}"

  if pekg_offline; then
    return 1
  fi
  if [ -z "${PEKG_TOKEN:-}" ]; then
    return 1
  fi

  local ua
  ua=$(pekg_ua)
  local url="${PEKG_API_BASE}${path}"

  if [ -n "$body" ]; then
    curl -sS --max-time "$timeout" -X "$method" \
      -H "Authorization: Bearer $PEKG_TOKEN" \
      -H "Content-Type: application/json" \
      -H "User-Agent: $ua" \
      --fail-with-body \
      -d "$body" \
      "$url" 2>/dev/null
  else
    curl -sS --max-time "$timeout" -X "$method" \
      -H "Authorization: Bearer $PEKG_TOKEN" \
      -H "User-Agent: $ua" \
      --fail-with-body \
      "$url" 2>/dev/null
  fi
}

# Convenience: GET with default timeout.
pekg_get() {
  pekg_fetch GET "$1" "" "${2:-$PEKG_DEFAULT_TIMEOUT}"
}

# Convenience: POST JSON.
pekg_post_json() {
  pekg_fetch POST "$1" "$2" "${3:-$PEKG_DEFAULT_TIMEOUT}"
}
# --- end inline ---
# --- inlined from shared/lib/state.sh ---
PEKG_SESSION_DIR="$HOME/.pekg/sessions"
PEKG_SESSION_TTL_DAYS="${PEKG_SESSION_TTL_DAYS:-7}"
PEKG_SESSION_MAX_FILES="${PEKG_SESSION_MAX_FILES:-100}"
# Per-blocker TTL — drop entries with firstSeenAt older than this on read.
# Stops a single blocker from gating an active session indefinitely. New
# blockers reset the clock; addressed-then-irrelevant blockers self-clear
# within an hour without needing an explicit ack signal.
PEKG_BLOCKER_TTL_SECS="${PEKG_BLOCKER_TTL_SECS:-3600}"

pekg_state_path() {
  local sid="$1"
  # Sanitize for filesystem.
  sid=$(printf '%s' "$sid" | tr -c 'a-zA-Z0-9_-' '_')
  printf '%s/%s.json' "$PEKG_SESSION_DIR" "$sid"
}

# A49 lazy mkdir.
pekg_state_ensure_dir() {
  mkdir -p "$PEKG_SESSION_DIR" 2>/dev/null || true
  chmod 700 "$PEKG_SESSION_DIR" 2>/dev/null || true
}

# A14 + A98: read state, honoring TTL. Returns "" if expired or missing.
# Per-blocker TTL filter: blockers with firstSeenAt older than
# PEKG_BLOCKER_TTL_SECS are dropped on read. Legacy entries without
# firstSeenAt fall back to the envelope timestamp so they don't deadlock
# forever after the upgrade.
pekg_state_read() {
  local sid="$1"
  local path
  path=$(pekg_state_path "$sid")
  [ -f "$path" ] || return 0

  local now expires
  now=$(date +%s)
  expires=$(jq -r '.expiresAt // 0' "$path" 2>/dev/null || echo 0)
  # expiresAt is unix-seconds; if 0, treat as legacy and write fresh.
  if [ "$expires" -gt 0 ] && [ "$expires" -lt "$now" ]; then
    rm -f "$path" 2>/dev/null || true
    return 0
  fi

  local cutoff=$((now - PEKG_BLOCKER_TTL_SECS))
  jq --argjson cutoff "$cutoff" '
    if has("blockers") and (.blockers | type) == "array" then
      # Only filter blockers that have an explicit firstSeenAt older than the
      # cutoff. Legacy / fixture entries without the field pass through
      # untouched — pekg_state_write will stamp them on the next persist.
      .blockers |= map(select(.firstSeenAt == null or .firstSeenAt >= $cutoff))
    else . end
  ' "$path" 2>/dev/null || cat "$path" 2>/dev/null
}

# A14 single-writer envelope.
# Args: sessionId, taskJson (object), blockersJson (array of {id,title,recommendation}).
# Each blocker gets a firstSeenAt stamp on first write; subsequent writes
# preserve the original stamp for blocker IDs that are still present, so the
# TTL clock measures "how long has THIS blocker been hanging around" rather
# than "how long since the last write."
#
# ackedBlockers (in-turn ack persistence) is preserved transparently — if a
# prior state had ackedBlockers and the caller doesn't supply a fresh map,
# we keep the existing one. Use pekg_state_write_with_acked to overwrite.
pekg_state_write() {
  local sid="$1"
  local task_json="${2:-{\}}"
  local blockers_json="${3:-[]}"

  local prior_acked="{}" prior_denials="{}"
  local path
  path=$(pekg_state_path "$sid")
  if [ -f "$path" ]; then
    prior_acked=$(jq -c '.ackedBlockers // {}' "$path" 2>/dev/null || echo '{}')
    prior_denials=$(jq -c '.denialCounts // {}' "$path" 2>/dev/null || echo '{}')
  fi
  pekg_state_write_full "$sid" "$task_json" "$blockers_json" "$prior_acked" "$prior_denials"
}

# Compat wrapper: persist envelope with explicit ackedBlockers map; preserves
# prior denialCounts.
pekg_state_write_with_acked() {
  local sid="$1"
  local task_json="${2:-{\}}"
  local blockers_json="${3:-[]}"
  local acked_json="${4:-{\}}"

  local prior_denials="{}"
  local path
  path=$(pekg_state_path "$sid")
  if [ -f "$path" ]; then
    prior_denials=$(jq -c '.denialCounts // {}' "$path" 2>/dev/null || echo '{}')
  fi
  pekg_state_write_full "$sid" "$task_json" "$blockers_json" "$acked_json" "$prior_denials"
}

# Full envelope writer including denialCounts (per-blocker consecutive-deny
# counter for the loop-bound safety net — see pekg_record_denial_and_maybe_force_ack).
pekg_state_write_full() {
  local sid="$1"
  local task_json="${2:-{\}}"
  local blockers_json="${3:-[]}"
  local acked_json="${4:-{\}}"
  local denials_json="${5:-{\}}"

  pekg_state_ensure_dir
  local path
  path=$(pekg_state_path "$sid")

  local now expires_at
  now=$(date +%s)
  expires_at=$(( now + PEKG_SESSION_TTL_DAYS * 86400 ))

  local prior_blockers="[]"
  if [ -f "$path" ]; then
    prior_blockers=$(jq -c '.blockers // []' "$path" 2>/dev/null || echo '[]')
  fi

  local stamped_blockers
  stamped_blockers=$(jq -n \
    --argjson fresh "$blockers_json" \
    --argjson prior "$prior_blockers" \
    --argjson now "$now" '
    ($prior | map(select(.id != null and .firstSeenAt != null)
                  | {(.id|tostring): .firstSeenAt})
            | add // {}) as $first_seen |
    $fresh | map(. + {firstSeenAt: ($first_seen[(.id // "")|tostring] // $now)})
  ' 2>/dev/null) || stamped_blockers="$blockers_json"

  # Prune ackedBlockers entries whose ts is older than 2× cooldown window
  # so this map doesn't grow unbounded across long-lived sessions.
  local prune_cutoff=$(( now - 2 * ${PEKG_BLOCKER_ACK_COOLDOWN_SECS:-600} ))
  local pruned_acked
  pruned_acked=$(printf '%s' "$acked_json" | jq -c --argjson c "$prune_cutoff" '
    with_entries(select(.value >= $c))
  ' 2>/dev/null) || pruned_acked="$acked_json"

  # Prune denialCounts to only IDs still present in current blockers — a
  # blocker that's no longer active doesn't need its counter persisted.
  local pruned_denials
  pruned_denials=$(jq -n \
    --argjson denials "$denials_json" \
    --argjson blockers "$stamped_blockers" '
    ($blockers | map(.id // "" | tostring) | map(select(length > 0))) as $ids |
    $denials | with_entries(select(.key | IN($ids[])))
  ' 2>/dev/null) || pruned_denials="$denials_json"

  local tmp="${path}.tmp.$$"
  jq -n \
    --argjson task "$task_json" \
    --argjson blockers "$stamped_blockers" \
    --argjson acked "$pruned_acked" \
    --argjson denials "$pruned_denials" \
    --arg ts "$now" \
    --arg exp "$expires_at" \
    '{
      task: $task,
      blockers: $blockers,
      ackedBlockers: $acked,
      denialCounts: $denials,
      timestamp: ($ts | tonumber),
      expiresAt: ($exp | tonumber)
    }' > "$tmp" 2>/dev/null || return 1

  mv "$tmp" "$path" 2>/dev/null || { rm -f "$tmp"; return 1; }
  return 0
}

# A38 lazy cleanup, max once per hour.
pekg_state_cleanup() {
  local marker="$HOME/.pekg/.last-cleanup"
  local now last
  now=$(date +%s)
  last=0
  [ -f "$marker" ] && last=$(cat "$marker" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt 3600 ]; then
    return 0
  fi
  printf '%s' "$now" > "$marker"

  # Delete files older than TTL (mtime-based fallback if file lacks expiresAt).
  find "$PEKG_SESSION_DIR" -maxdepth 1 -type f -name '*.json' \
    -mtime +"$PEKG_SESSION_TTL_DAYS" -delete 2>/dev/null || true

  # A79: cap at max files by mtime ascending eviction.
  local count
  count=$(find "$PEKG_SESSION_DIR" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$count" -gt "$PEKG_SESSION_MAX_FILES" ]; then
    local excess=$((count - PEKG_SESSION_MAX_FILES))
    find "$PEKG_SESSION_DIR" -maxdepth 1 -type f -name '*.json' -print0 2>/dev/null \
      | xargs -0 ls -tr 2>/dev/null \
      | head -n "$excess" \
      | xargs rm -f 2>/dev/null || true
  fi
}
# --- end inline ---
# --- inlined from shared/lib/queue.sh ---
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
# --- end inline ---
# --- inlined from shared/lib/tech.sh ---
PEKG_TECH_PATTERNS=(
  'drizzle|from .[\x27"]drizzle-orm|import.*drizzle|drizzle,postgres-js,ORM'
  'clickhouse|from .[\x27"]@clickhouse|clickhouse.*client|clickhouse,ReplacingMergeTree,AggregatingMergeTree'
  'redis|from .[\x27"]ioredis|from .[\x27"]redis|new Redis\(|redis,connection pool,ioredis'
  'postgresql|from .[\x27"]pg[\x27"]|from .[\x27"]postgres[\x27"]|PostgreSQL|postgresql,postgres,connection'
  'auth|OAuth|from .[\x27"]jose[\x27"]|JWT|jsonwebtoken|OAuth,JWT,authentication,token'
  'better-auth|from .[\x27"]better-auth|better-auth,OAuth,authentication'
  'fastify|from .[\x27"]fastify|Fastify|fastify,middleware,bodyLimit'
  'express|from .[\x27"]express[\x27"]|express\(\)|express,middleware,cors'
  'hono|from .[\x27"]hono[\x27"]|new Hono\(|hono,middleware'
  'nextjs|from .[\x27"]next|NextResponse|getServerSideProps|nextjs,App Router,fetch caching'
  'react|from .[\x27"]react[\x27"]|useState|useEffect|react,hooks,state'
  'mcp|@modelcontextprotocol|MCP|StreamableHTTP|MCP,session,StreamableHTTP'
  'temporal|from .[\x27"]@temporalio|Temporal\.|temporal,workflow,activity'
  'tailwind|tailwindcss|@tailwind|tailwind,utility-first,css'
  'fastapi|from fastapi|FastAPI\(|fastapi,python,async'
)

# pekg_detect_techs <file_path>
# Echoes detected tech names (one per line), deduped.
pekg_detect_techs() {
  local file="$1"
  [ -f "$file" ] || return 0
  # Skip large files (>200KB) to keep hook fast.
  local size
  size=$(wc -c < "$file" 2>/dev/null || echo 0)
  [ "$size" -gt 204800 ] && return 0

  local content
  content=$(head -c 204800 "$file" 2>/dev/null || true)
  [ -z "$content" ] && return 0

  local entry name regex
  for entry in "${PEKG_TECH_PATTERNS[@]}"; do
    name="${entry%%|*}"
    local rest="${entry#*|}"
    # The regex is everything between the first | and the last | (search terms).
    regex="${rest%|*}"
    if printf '%s' "$content" | grep -iqE "$regex" 2>/dev/null; then
      echo "$name"
    fi
  done | sort -u
}

# pekg_search_terms_for <tech-name>
# Echoes comma-joined search terms for a detected tech (for proactive context).
pekg_search_terms_for() {
  local target="$1"
  local entry name terms
  for entry in "${PEKG_TECH_PATTERNS[@]}"; do
    name="${entry%%|*}"
    if [ "$name" = "$target" ]; then
      terms="${entry##*|}"
      printf '%s' "$terms"
      return 0
    fi
  done
}
# --- end inline ---
# --- inlined from shared/lib/feedback.sh ---
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
# --- end inline ---
# --- inlined from shared/lib/byollm.sh ---
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
# --- end inline ---

main() {
  local input tool session_id
  input=$(cat 2>/dev/null || true)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  [ -z "$session_id" ] && exit 0

  # Legacy status-called marker for the soft pretooluse gate.
  if [ "$tool" = "mcp__pekg__status" ] || [ "$tool" = "pekg_status" ]; then
    local status_dir="$HOME/.pekg/session-state"
    mkdir -p "$status_dir" 2>/dev/null || true
    touch "$status_dir/${session_id}.status_called" 2>/dev/null || true
    find "$status_dir" -maxdepth 1 -type f -name '*.status_called' -mtime +1 -delete 2>/dev/null || true
  fi

  pekg_load_config
  [ -z "$PEKG_TOKEN" ] && exit 0

  # A27: failed-approach extraction. PostToolUse fires for both success AND
  # error in Claude Code 2.1.119. tool_response shape varies by tool:
  #   - Built-in tools (Edit/Write/Bash/Read): { is_error, content[].text }
  #   - MCP tools (mcp__pekg__*): MCP CallToolResult { isError, content[].text }
  #   - Bash specifically may also have: { exit_code, stdout, stderr }
  # Try all three.
  local tool_error
  tool_error=$(printf '%s' "$input" | jq -r '
    if (.tool_response.isError // .tool_response.is_error // false) then
      (.tool_response.content // [] | map(select(.type == "text") | .text) | join(" "))
    elif ((.tool_response.exit_code // 0) != 0) then
      (.tool_response.stderr // .tool_response.stdout // empty)
    elif (.tool_response.error // empty) then
      .tool_response.error
    else empty end
  ' 2>/dev/null | head -c 240)
  if [ -n "$tool_error" ]; then
    local sanitized
    sanitized=$(printf '%s' "$tool_error" \
      | sed -E 's|sk-[A-Za-z0-9_-]+|<sk-redacted>|g' \
      | sed -E 's|ghp_[A-Za-z0-9_]+|<ghp-redacted>|g' \
      | sed -E 's|Bearer [A-Za-z0-9._-]+|Bearer <redacted>|g' \
      | sed -E 's|password[[:space:]]*[:=][[:space:]]*[^[:space:]]+|password=<redacted>|gI' \
      | tr -d '\n' | head -c 200)
    [ -n "$sanitized" ] && pekg_track_failed_approach "$session_id" "$tool"" — ""$sanitized"
  fi

  # A5c/A6b active-files tracking on edit/write tools.
  local path
  case "$tool" in
    Edit|Write|MultiEdit|NotebookEdit)
      path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
      ;;
    Read)
      # Track read-files separately; useful for resumed-session block (A85).
      local read_path
      read_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // empty')
      if [ -n "$read_path" ]; then
        pekg_track_read "$session_id" "$read_path"
      fi
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
  [ -z "$path" ] && exit 0

  pekg_track_modified "$session_id" "$path"

  # A25/A57: compute diff vs pre-captured snapshot, queue for ingest analysis if ≥10 lines.
  pekg_queue_diff_for_ingest "$session_id" "$path"

  # A6a/A24/A53 tech detection on the edited file.
  if [ -f "$path" ]; then
    local techs term_set
    techs=$(pekg_detect_techs "$path")
    if [ -n "$techs" ]; then
      # Build search-terms list (comma-joined).
      term_set=""
      while IFS= read -r t; do
        [ -z "$t" ] && continue
        local terms
        terms=$(pekg_search_terms_for "$t")
        if [ -n "$term_set" ]; then term_set="${term_set},${terms}"; else term_set="$terms"; fi
      done <<< "$techs"

      # A21/A22: fetch context for the search terms, queue for next userpromptsubmit.
      if [ -n "$term_set" ]; then
        local payload result
        payload=$(jq -n --arg terms "$term_set" --arg q "$(basename "$path")" '{
          query: $q,
          searchTerms: ($terms | split(","))
        }')
        result=$(pekg_post_json "/api/v1/search" "$payload" 4 2>/dev/null || true)
        if [ -n "$result" ]; then
          # Queue top 3 articles by relevance.
          local top3
          top3=$(printf '%s' "$result" | jq -c '.results // [] | sort_by(-(.relevance // 0))[0:3]')
          local count i
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

  # A36 + A12b: feedback submission, BYOLLM-classified when budget allows.
  # For each blocker in state (≤3 to bound work):
  #   1. Try A12b BYOLLM verifier to classify signal (applied|avoided_bug|ignored).
  #   2. If BYOLLM declines (cost cap, recursion guard, no host CLI, missing
  #      transcript), fall back to A36 default "applied" signal.
  #   3. Submit via A32 queue-aware feedback (offline → file queue, replay later).
  local cur blockers blocker_ids
  cur=$(pekg_state_read "$session_id" 2>/dev/null || true)
  if [ -n "$cur" ]; then
    blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
    blocker_ids=$(printf '%s' "$blockers" | jq -r '.[].id // empty' | head -3)
    if [ -n "$blocker_ids" ]; then
      # Read recent edited content (≤4KB) so the verifier can classify
      # whether the edit applied the blocker's recommendation.
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
        # Fallback to A36 default if BYOLLM declined.
        [ -z "$signal" ] && signal="applied"

        pekg_feedback_submit "$bid" "$signal" "$(jq -n --arg p "$path" '{filePath:$p}')" || true
      done <<< "$blocker_ids"
    fi
  fi
}

# A27 helper: append a sanitized failed-approach entry (≤5 dedup, last-N).
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

# Helper: track filesModified into state.
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

# Helper: track filesRead into state.
# A25 + A57: diff queue. Compute unified diff vs pre-captured snapshot;
# queue file if ≥10 lines for the Stop hook's BYOLLM ingest analysis.
pekg_queue_diff_for_ingest() {
  local sid="$1" path="$2"
  [ -f "$path" ] || return 0
  local cap_dir="$HOME/.pekg/precap/${sid}"
  local safe before after diff lines diff_dir
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
  local fname="$(date +%s)-${safe:0:32}"
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
