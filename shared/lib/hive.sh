#!/usr/bin/env bash
# PeKG hive transformation + cluster compilation client (A12c, A12d, A44).
# Source after config.sh, fetch.sh, byollm.sh.
#
# Hive items are community-sourced raw inputs that need BYOLLM transformation
# into structured articles. Cluster compilation aggregates ingested sources
# into compiled wiki articles. Both spawn child sessions via byollm.sh and
# are gated by per-flow cooldowns + concurrency flags.

PEKG_HIVE_COOLDOWN_FILE="$HOME/.pekg/.hive-cooldown"
PEKG_HIVE_COOLDOWN_S="${PEKG_HIVE_COOLDOWN_S:-600}"   # A44: 10min
PEKG_HIVE_LOCK_FILE="$HOME/.pekg/.hive.lock"
PEKG_COMPILE_COOLDOWN_FILE="$HOME/.pekg/.compile-cooldown"
PEKG_COMPILE_COOLDOWN_S="${PEKG_COMPILE_COOLDOWN_S:-300}"  # 5min
PEKG_COMPILE_LOCK_FILE="$HOME/.pekg/.compile.lock"

# Generic cooldown check. 0 = allowed, 1 = cooled-down.
_pekg_check_cooldown() {
  local marker="$1" cooldown="$2"
  [ -f "$marker" ] || return 0
  local now last
  now=$(date +%s)
  last=$(cat "$marker" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$cooldown" ] && return 1
  return 0
}

_pekg_record_cooldown() {
  local marker="$1"
  mkdir -p "$(dirname "$marker")" 2>/dev/null
  date +%s > "$marker"
}

# Best-effort lock file (advisory only; flock not portable on macOS bash).
# Returns 0 if acquired, 1 if already held.
_pekg_try_lock() {
  local lock="$1"
  if [ -f "$lock" ]; then
    # Check if process is still alive.
    local pid
    pid=$(cat "$lock" 2>/dev/null || echo 0)
    if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
      return 1
    fi
    # Stale lock — proceed.
  fi
  echo $$ > "$lock" 2>/dev/null || return 1
}

_pekg_release_lock() {
  rm -f "$1" 2>/dev/null || true
}

# A12d: hive transformation. Fetches pending hive items, runs BYOLLM child
# session per item to transform into structured article, submits.
# Gated by A44 cooldown + lock. Idempotent. Best-effort.
pekg_hive_maybe_transform() {
  local sid="$1"
  pekg_offline && return 0
  _pekg_check_cooldown "$PEKG_HIVE_COOLDOWN_FILE" "$PEKG_HIVE_COOLDOWN_S" || return 0
  _pekg_try_lock "$PEKG_HIVE_LOCK_FILE" || return 0
  trap "_pekg_release_lock '$PEKG_HIVE_LOCK_FILE'" EXIT

  # Fetch pending hive items (server endpoint).
  local pending
  pending=$(pekg_get "/api/v1/hive/pending?limit=3" 5 2>/dev/null || true)
  if [ -z "$pending" ]; then
    _pekg_release_lock "$PEKG_HIVE_LOCK_FILE"
    trap - EXIT
    return 0
  fi

  local count i
  count=$(printf '%s' "$pending" | jq '.items // [] | length' 2>/dev/null || echo 0)
  [ "$count" = "0" ] && { _pekg_release_lock "$PEKG_HIVE_LOCK_FILE"; trap - EXIT; return 0; }

  for ((i=0; i<count; i++)); do
    local item item_id raw_content sys usr resp title content type_str payload
    item=$(printf '%s' "$pending" | jq -c ".items[$i]")
    item_id=$(printf '%s' "$item" | jq -r '.id // empty')
    raw_content=$(printf '%s' "$item" | jq -r '.content // empty' | head -c 4000)
    [ -z "$item_id" ] || [ -z "$raw_content" ] && continue

    sys="You transform community-sourced raw inputs into structured PeKG articles. Output ONLY a JSON object: {\"title\":\"<short>\", \"type\":\"pattern|decision|bug_fix|learning|gotcha\", \"content\":\"<markdown body>\"}."
    usr=$(printf 'Raw input:\n%s' "$raw_content")

    resp=$(pekg_byollm_run "$sid" "$sys" "$usr" \
      '{"type":"object","properties":{"title":{"type":"string"},"type":{"type":"string"},"content":{"type":"string"}},"required":["title","content"]}' \
      2>/dev/null) || continue

    title=$(printf '%s' "$resp" | jq -r '.title // empty')
    type_str=$(printf '%s' "$resp" | jq -r '.type // "learning"')
    content=$(printf '%s' "$resp" | jq -r '.content // empty')
    [ -z "$title" ] || [ -z "$content" ] && continue

    payload=$(jq -n --arg id "$item_id" --arg t "$title" --arg ty "$type_str" --arg c "$content" \
      '{action:"submit", itemId:$id, title:$t, type:$ty, content:$c}')
    pekg_post_json "/api/v1/hive" "$payload" 5 >/dev/null 2>&1 || true
  done

  _pekg_record_cooldown "$PEKG_HIVE_COOLDOWN_FILE"
  _pekg_release_lock "$PEKG_HIVE_LOCK_FILE"
  trap - EXIT
}

# A12c: cluster compilation. Fetches a compilation manifest from /api/v1/compile,
# runs BYOLLM to synthesize a compiled article from the sources, submits.
pekg_compile_maybe_run() {
  local sid="$1"
  pekg_offline && return 0
  _pekg_check_cooldown "$PEKG_COMPILE_COOLDOWN_FILE" "$PEKG_COMPILE_COOLDOWN_S" || return 0
  _pekg_try_lock "$PEKG_COMPILE_LOCK_FILE" || return 0
  trap "_pekg_release_lock '$PEKG_COMPILE_LOCK_FILE'" EXIT

  # Fetch a manifest (server returns null if no clusters ready).
  local manifest
  manifest=$(pekg_post_json "/api/v1/compile" "{}" 5 2>/dev/null || true)
  if [ -z "$manifest" ] || [ "$(printf '%s' "$manifest" | jq -r '.manifest // empty')" = "" ]; then
    _pekg_release_lock "$PEKG_COMPILE_LOCK_FILE"
    trap - EXIT
    return 0
  fi

  local cluster_id profile sources sys usr resp title content payload
  cluster_id=$(printf '%s' "$manifest" | jq -r '.manifest.clusterId // empty')
  profile=$(printf '%s' "$manifest" | jq -r '.submitParams.compilationProfile // "technical"')
  sources=$(printf '%s' "$manifest" | jq -c '.manifest.sources // []' | head -c 8000)
  [ -z "$cluster_id" ] && { _pekg_release_lock "$PEKG_COMPILE_LOCK_FILE"; trap - EXIT; return 0; }

  sys="You synthesize compiled wiki articles from raw PeKG sources following a compilation profile. Output ONLY a JSON object: {\"title\":\"<short title>\", \"content\":\"<markdown body>\"}. Include [source:UUID] citations from the source array."
  usr=$(printf 'Profile: %s\n\nSources:\n%s' "$profile" "$sources")

  resp=$(pekg_byollm_run "$sid" "$sys" "$usr" \
    '{"type":"object","properties":{"title":{"type":"string"},"content":{"type":"string"}},"required":["title","content"]}' \
    2>/dev/null) || { _pekg_release_lock "$PEKG_COMPILE_LOCK_FILE"; trap - EXIT; return 0; }

  title=$(printf '%s' "$resp" | jq -r '.title // empty')
  content=$(printf '%s' "$resp" | jq -r '.content // empty')
  if [ -n "$title" ] && [ -n "$content" ]; then
    local project
    project=$(pekg_project_origin "$PWD")
    payload=$(jq -n \
      --arg t "$title" --arg c "$content" --arg p "$project" \
      --arg cid "$cluster_id" --arg prof "$profile" \
      '{title:$t, sourceType:"compiled_article", content:$c, projectOrigin:$p, clusterId:$cid, compilationProfile:$prof}')
    pekg_post_json "/api/v1/ingest" "$payload" 8 >/dev/null 2>&1 || true
  fi

  _pekg_record_cooldown "$PEKG_COMPILE_COOLDOWN_FILE"
  _pekg_release_lock "$PEKG_COMPILE_LOCK_FILE"
  trap - EXIT
}
