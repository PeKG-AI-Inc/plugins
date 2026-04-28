#!/usr/bin/env bash
# PeKG PreToolUse hook for Codex.
# Same gate semantics as Claude Code variant. Codex tools are different names
# (apply_patch instead of Edit/Write), handled in pekg_is_mutating_tool.

set -o pipefail

PEKG_PLUGIN_VERSION="0.1.87"
PEKG_UA_PRODUCT="codex-pekg-plugin"

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
# --- inlined from shared/lib/blockers.sh ---
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
# Wording explicitly names BOTH heuristic arms (reference + action verb) so
# an agent that's silently failing one half knows to fix it. The other agent
# debugging report (Apr 2026) found that not knowing which arm failed wasted
# retry budget on the wrong fix.
pekg_format_denial_reason() {
  local blockers="${1:-[]}"
  printf '%s' "$blockers" | jq -r '
    "PeKG: \(length) active blocker(s). Address before file-mutating tools work:\n" +
    (map("- [\(.id // "?" | tostring | .[0:8])] \(.title): \(.recommendation // "no recommendation")") | join("\n")) +
    "\n\nAck format — heuristic checks BOTH arms; satisfy both:\n" +
    "  (a) Reference each blocker by ID prefix (e.g. [c34d60d4]), title fragment, or key terms.\n" +
    "  (b) Include a concrete action verb (root + common suffixes like -ed/-ing/-s match): replace, use, switch, migrate, add, remove, fix, refactor, change, update, configure, set, wrap, guard, check, validate, drop, move, extract, delete, create, apply, rewrite, revert, implement, address, patch, build, ship, deploy, install, write, edit.\n" +
    "Generic acks (\"acknowledged\", \"will be careful\") are rejected. After 3 consecutive denials of the same blocker, the gate auto-passes — surface the issue so the heuristic can be improved."
  '
}

# A30b helper: detect a concrete action verb in agent text. Accepts the
# canonical English forms (bare / 3sg / past / present-participle) for each
# verb. Explicit enumeration handles e-drop (create→creating), consonant-
# doubling (wrap→wrapping, set→setting), y→ies (apply→applies), and
# irregular pasts (build→built, write→wrote). The earlier `\bverb\b` and
# stem+suffix variants silently rejected forms that don't follow the trivial
# root+suffix pattern, leading to the well-documented "natural ack rejected"
# infinite-loop bug.
#
# To add a verb: include all 4 forms (bare, +s, past, -ing). False positives
# are bounded because the title-arm of pekg_heuristic_ack still has to pass
# independently — this regex only decides "is the response describing
# concrete action vs. just narrating".
pekg_has_action_verb() {
  local lower="${1:-}"
  printf '%s' "$lower" | grep -qE '\b(replace|replaces|replaced|replacing|use|uses|used|using|switch|switches|switched|switching|migrate|migrates|migrated|migrating|add|adds|added|adding|remove|removes|removed|removing|fix|fixes|fixed|fixing|refactor|refactors|refactored|refactoring|change|changes|changed|changing|update|updates|updated|updating|configure|configures|configured|configuring|disable|disables|disabled|disabling|enable|enables|enabled|enabling|set|sets|setting|export|exports|exported|exporting|import|imports|imported|importing|wrap|wraps|wrapped|wrapping|guard|guards|guarded|guarding|check|checks|checked|checking|validate|validates|validated|validating|cast|casts|casting|sanitize|sanitizes|sanitized|sanitizing|drop|drops|dropped|dropping|skip|skips|skipped|skipping|move|moves|moved|moving|extract|extracts|extracted|extracting|inline|inlines|inlined|inlining|delete|deletes|deleted|deleting|create|creates|created|creating|adopt|adopts|adopted|adopting|apply|applies|applied|applying|rewrite|rewrites|rewrote|rewriting|revert|reverts|reverted|reverting|restore|restores|restored|restoring|implement|implements|implemented|implementing|address|addresses|addressed|addressing|patch|patches|patched|patching|build|builds|built|building|ship|ships|shipped|shipping|land|lands|landed|landing|deploy|deploys|deployed|deploying|install|installs|installed|installing|copy|copies|copied|copying|stamp|stamps|stamped|stamping|persist|persists|persisted|persisting|surface|surfaces|surfaced|surfacing|cover|covers|covered|covering|extend|extends|extended|extending|tighten|tightens|tightened|tightening|loosen|loosens|loosened|loosening|harden|hardens|hardened|hardening|write|writes|wrote|written|writing|edit|edits|edited|editing)\b'
}

# A30: deterministic-ack heuristic. Given blockers JSON + agent text, return 0
# if each blocker is referenced (verbatim title, ≥50% significant-word overlap,
# or article-id match) AND the response carries a concrete action verb.
#
# Why this softened: requiring full verbatim title quotes for every blocker
# rejected natural-language acknowledgments ("switching from Express to Fastify
# per the migration blocker") even when the agent had clearly done the work
# the blocker asked for. Now we accept paraphrase as long as enough of the
# title's content words land in the response and an action verb appears.
pekg_heuristic_ack() {
  local blockers="${1:-[]}"
  local text="${2:-}"

  local count
  count=$(printf '%s' "$blockers" | jq 'length' 2>/dev/null || echo 0)
  [ "$count" = "0" ] && return 0  # No blockers = trivially "acked".

  local lower
  lower=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')

  local i
  for ((i=0; i<count; i++)); do
    local row title aid short_aid
    row=$(printf '%s' "$blockers" | jq -c ".[$i]")
    title=$(printf '%s' "$row" | jq -r '.title // ""' | tr '[:upper:]' '[:lower:]')
    aid=$(printf '%s' "$row" | jq -r '.id // ""' | tr '[:upper:]' '[:lower:]')

    # 1. Verbatim title substring. Also accepts the title with its project
    #    prefix stripped, since blockers are often stored as
    #    "Engage OS: Apollo Enrichment Failure Diagnosis and Fix" and an
    #    agent naturally writes just the topic-half ("Apollo Enrichment
    #    Failure Diagnosis and Fix") without restating the project. The
    #    project prefix is split on the FIRST ": " — additional colons in
    #    the topic stay attached.
    if [ -n "$title" ]; then
      if printf '%s' "$lower" | grep -qF -- "$title"; then
        continue
      fi
      local stripped_title="${title#*: }"
      if [ -n "$stripped_title" ] && [ "$stripped_title" != "$title" ] \
         && [ ${#stripped_title} -ge 8 ] \
         && printf '%s' "$lower" | grep -qF -- "$stripped_title"; then
        continue
      fi
    fi
    # 2. Article-id reference (full or first 8 chars, if non-trivial).
    if [ -n "$aid" ]; then
      if printf '%s' "$lower" | grep -qF -- "$aid"; then continue; fi
      short_aid="${aid:0:8}"
      if [ ${#short_aid} -ge 6 ] && printf '%s' "$lower" | grep -qF -- "$short_aid"; then
        continue
      fi
    fi
    # 3. Significant-word overlap: ≥50% of title words ≥4 chars appear.
    #    Match-count floor scales with title length: 1 for short titles
    #    (≤2 sig words), 2 for longer ones. Stops a single common word
    #    in long titles from passing while still accepting legitimate
    #    short-title acks like "Use parameterized SQL queries" → "I added
    #    parameterized helpers" (1 of 2 sig words = 50% = passes).
    if [ -n "$title" ]; then
      local words sig_count match_count floor
      words=$(printf '%s' "$title" | tr -s '[:space:][:punct:]' '\n' | awk 'length($0) >= 4')
      sig_count=$(printf '%s\n' "$words" | grep -c . 2>/dev/null || echo 0)
      match_count=0
      if [ "$sig_count" -gt 0 ]; then
        while IFS= read -r w; do
          [ -z "$w" ] && continue
          if printf '%s' "$lower" | grep -qF -- "$w"; then
            match_count=$((match_count + 1))
          fi
        done <<< "$words"
        floor=2
        [ "$sig_count" -le 2 ] && floor=1
        if [ "$match_count" -ge "$floor" ] && [ $((match_count * 2)) -ge "$sig_count" ]; then
          continue
        fi
      fi
    fi
    return 1
  done

  pekg_has_action_verb "$lower" && return 0
  return 1
}

# In-turn ack support (A30b, 2026-04-27).
#
# Without this, the bash plugin had no path for an agent to clear a blocker
# mid-turn: PreToolUse denies, agent writes an ack in its reply, but the
# heuristic only runs at Stop (turn end). Subsequent edits in the same turn
# kept hitting the same denial — infinite loop until manual state surgery.
#
# Now: pretooluse reads the live transcript, runs the heuristic against the
# latest assistant text, and on pass writes the ack timestamp into
# state.ackedBlockers (a per-blocker-id map). Future tool calls within the
# cooldown window skip the gate for those acked IDs.
PEKG_BLOCKER_ACK_COOLDOWN_SECS="${PEKG_BLOCKER_ACK_COOLDOWN_SECS:-1800}"

# Loop-bound safety net: after this many consecutive denials of the same
# blocker on the same session, force-ack it so the agent isn't stuck in an
# infinite retry loop. Cooperative agents pass the heuristic on attempt 1;
# if we hit attempt N without passing, EITHER the heuristic is broken for
# this writing style OR the agent isn't acking. Either way, ~3 attempts is
# enough signal that a human should look — bound the worst-case pain.
PEKG_BLOCKER_DENIAL_THRESHOLD="${PEKG_BLOCKER_DENIAL_THRESHOLD:-3}"

# Read recent assistant text from a Claude Code / Codex JSONL transcript.
# Returns concatenated text from the last few assistant events (text blocks
# AND thinking blocks). Returns empty if no transcript or no assistant turn yet.
#
# CC 2.1.x splits one logical assistant turn across MULTIPLE JSONL events:
# a "thinking" event, a "text" event (if the agent emits user-visible text),
# and one or more "tool_use" events. The events are atomic — we can't grab
# "the current turn" cleanly from outside. We bias toward recall by:
#   1. Scanning the last ~6 assistant events (covers a couple of tool-call
#      retries within one turn).
#   2. Including BOTH text and thinking blocks. Reasoning that mentions the
#      blocker title + mitigation counts as ack — agents often plan in
#      thinking and then immediately call the tool without restating in text.
pekg_read_last_assistant_from_transcript() {
  local transcript_path="${1:-}"
  [ -z "$transcript_path" ] && return 0
  [ -f "$transcript_path" ] || return 0

  # Claude Code 2.1.x JSONL.
  local out
  out=$(tail -400 "$transcript_path" 2>/dev/null \
    | grep '"type":"assistant"' \
    | tail -6 \
    | jq -r '.message.content[]? | select((.type // "") | IN("text","thinking")) | (.text // .thinking // "")' 2>/dev/null \
    | tr '\n' ' ')
  if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi

  # Codex JSONL fallback: events may carry .role == "assistant" with .content
  # as a plain string or array of text blocks.
  out=$(tail -400 "$transcript_path" 2>/dev/null \
    | jq -r 'select((.role // "") == "assistant") | (
        if (.content | type) == "string" then .content
        elif (.content | type) == "array" then
          ([.content[] | select((.type // "") | IN("text","thinking")) | (.text // .thinking // "")] | join(" "))
        else "" end
      )' 2>/dev/null \
    | tail -6 \
    | tr '\n' ' ')
  [ -n "$out" ] && printf '%s' "$out"
  return 0
}

# Filter blockers, dropping those whose IDs were acked within the cooldown.
# Args: blockers_json acked_map_json now_epoch
pekg_filter_acked_blockers() {
  local blockers="${1:-[]}"
  local acked_map="${2:-{\}}"
  local now="${3:-0}"
  local cutoff=$((now - PEKG_BLOCKER_ACK_COOLDOWN_SECS))
  printf '%s' "$blockers" | jq -c \
    --argjson acked "$acked_map" \
    --argjson cutoff "$cutoff" '
    map(select(
      (.id // "" | tostring) as $bid
      | ($acked[$bid] // 0) < $cutoff
    ))
  '
}

# Try in-turn ack: if the latest assistant text satisfies the heuristic for
# the given blockers, persist ackedBlockers entries for each blocker id and
# return 0. Otherwise return 1. Caller decides whether to deny.
#
# Args: session_id blockers_json transcript_path
pekg_try_in_turn_ack() {
  local sid="$1"
  local blockers="${2:-[]}"
  local transcript_path="${3:-}"

  [ -z "$sid" ] && return 1
  [ -z "$transcript_path" ] && return 1

  local last_assistant
  last_assistant=$(pekg_read_last_assistant_from_transcript "$transcript_path")
  [ -z "$last_assistant" ] && return 1

  if ! pekg_heuristic_ack "$blockers" "$last_assistant"; then
    return 1
  fi

  # Persist ackedBlockers entries for every blocker id we're acking. We don't
  # try to attribute per-blocker — the heuristic accepted the response as a
  # whole, so all currently-active blockers are considered acked together.
  local now
  now=$(date +%s)
  local cur task acked_map updated_acked persisted_blockers
  cur=$(pekg_state_read "$sid" 2>/dev/null || echo '{}')
  task=$(printf '%s' "$cur" | jq -c '.task // {}')
  acked_map=$(printf '%s' "$cur" | jq -c '.ackedBlockers // {}')
  persisted_blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')

  updated_acked=$(jq -n \
    --argjson cur "$acked_map" \
    --argjson blk "$blockers" \
    --argjson now "$now" '
    reduce $blk[] as $b ($cur;
      if ($b.id // "") != "" then .[$b.id | tostring] = $now else . end
    )
  ' 2>/dev/null) || updated_acked="$acked_map"

  pekg_state_write_with_acked "$sid" "$task" "$persisted_blockers" "$updated_acked" || true
  return 0
}

# Loop-bound safety net. Increment denial counters for the given blockers in
# session state. If any blocker's count reaches PEKG_BLOCKER_DENIAL_THRESHOLD,
# force-ack it (write to ackedBlockers, reset its denial count, and emit a
# stderr breadcrumb). Returns 0 if at least one blocker was force-acked
# (caller should re-evaluate effective blockers); 1 otherwise.
#
# Args: session_id blockers_json
pekg_record_denial_and_maybe_force_ack() {
  local sid="$1"
  local blockers="${2:-[]}"

  [ -z "$sid" ] && return 1
  local count
  count=$(printf '%s' "$blockers" | jq 'length' 2>/dev/null || echo 0)
  [ "$count" = "0" ] && return 1

  local now
  now=$(date +%s)
  local cur task acked_map persisted_blockers denial_counts updated
  cur=$(pekg_state_read "$sid" 2>/dev/null || echo '{}')
  task=$(printf '%s' "$cur" | jq -c '.task // {}')
  persisted_blockers=$(printf '%s' "$cur" | jq -c '.blockers // []')
  acked_map=$(printf '%s' "$cur" | jq -c '.ackedBlockers // {}')
  denial_counts=$(printf '%s' "$cur" | jq -c '.denialCounts // {}')

  updated=$(jq -n \
    --argjson blockers "$blockers" \
    --argjson dc "$denial_counts" \
    --argjson acked "$acked_map" \
    --argjson now "$now" \
    --argjson threshold "$PEKG_BLOCKER_DENIAL_THRESHOLD" '
    reduce $blockers[] as $b ({denialCounts: $dc, acked: $acked, forceAcked: []};
      ($b.id // "" | tostring) as $bid |
      if $bid == "" then .
      else
        ((.denialCounts[$bid] // 0) + 1) as $newCount |
        if $newCount >= $threshold then
          .denialCounts[$bid] = 0
          | .acked[$bid] = $now
          | .forceAcked += [$bid]
        else
          .denialCounts[$bid] = $newCount
        end
      end
    )
  ' 2>/dev/null) || return 1

  local new_dc new_acked force_acked_list
  new_dc=$(printf '%s' "$updated" | jq -c '.denialCounts')
  new_acked=$(printf '%s' "$updated" | jq -c '.acked')
  force_acked_list=$(printf '%s' "$updated" | jq -r '.forceAcked | join(",")')

  pekg_state_write_full "$sid" "$task" "$persisted_blockers" "$new_acked" "$new_dc" || true

  if [ -n "$force_acked_list" ]; then
    # Stderr breadcrumb: visible in CC's hook log, surfaces the auto-pass for
    # debugging. Not in the user-visible decision reason — auto-pass is silent
    # to the agent so it doesn't game the threshold.
    printf 'pekg: blocker(s) auto-passed after %d denials: %s\n' \
      "$PEKG_BLOCKER_DENIAL_THRESHOLD" "$force_acked_list" >&2
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
# Threshold hierarchy: blocker is hardest to qualify (highest confidence gate),
# warning is mid, info is lowest (ambient fyi — anything loosely relevant counts).
# An inverted floor — info above warning — would hide low-confidence ambient
# context behind a stricter bar than warnings, which is backwards.
PEKG_BLOCKER_FLOOR="0.80"
PEKG_WARNING_FLOOR="0.55"
PEKG_INFO_FLOOR="0.40"

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
  local input tool session_id transcript_path
  input=$(cat 2>/dev/null || true)
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty')
  session_id=$(printf '%s' "$input" | jq -r '.session_id // empty')
  transcript_path=$(printf '%s' "$input" | jq -r '.transcript_path // empty')

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
            local acked_map
            acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
            blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
          fi
          if pekg_has_active_blockers "$blockers"; then
            local target_path
            target_path=$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty')
            local effective_blockers
            effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "$target_path")
            if pekg_has_active_blockers "$effective_blockers"; then
              if pekg_try_in_turn_ack "$session_id" "$effective_blockers" "$transcript_path"; then
                allow
              fi
              # A30c: loop-bound safety net (same as CC).
              if pekg_record_denial_and_maybe_force_ack "$session_id" "$effective_blockers"; then
                state=$(pekg_state_read "$session_id" 2>/dev/null || true)
                blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
                acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
                blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
                effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "$target_path")
                if ! pekg_has_active_blockers "$effective_blockers"; then
                  allow
                fi
              fi
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
        if pekg_has_active_blockers "$blockers"; then
          local acked_map
          acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
          blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
        fi
        if pekg_has_active_blockers "$blockers" && pekg_is_workspace_mutation_cmd "$cmd"; then
          local effective_blockers
          if pekg_bash_cmd_targets_markdown "$cmd"; then
            effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "<bash-target>.md")
          else
            effective_blockers="$blockers"
          fi
          if pekg_has_active_blockers "$effective_blockers"; then
            if pekg_try_in_turn_ack "$session_id" "$effective_blockers" "$transcript_path"; then
              allow
            fi
            if pekg_record_denial_and_maybe_force_ack "$session_id" "$effective_blockers"; then
              state=$(pekg_state_read "$session_id" 2>/dev/null || true)
              blockers=$(printf '%s' "$state" | jq -c '.blockers // []')
              acked_map=$(printf '%s' "$state" | jq -c '.ackedBlockers // {}')
              blockers=$(pekg_filter_acked_blockers "$blockers" "$acked_map" "$(date +%s)")
              if pekg_bash_cmd_targets_markdown "$cmd"; then
                effective_blockers=$(pekg_filter_blockers_for_file "$blockers" "<bash-target>.md")
              else
                effective_blockers="$blockers"
              fi
              if ! pekg_has_active_blockers "$effective_blockers"; then
                allow
              fi
            fi
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
