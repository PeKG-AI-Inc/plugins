#!/usr/bin/env bash
# PeKG shared session-state envelope (A14 + A38 TTL/cap).
# Persisted at ~/.pekg/sessions/<sessionId>.json with the same shape OpenCode plugin uses.
# Source after config.sh.

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
