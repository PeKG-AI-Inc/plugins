#!/usr/bin/env bash
# PeKG shared HTTP wrapper (A49 fetch timeout + A48 NETWORK_BLOCKER signaling
# + A71 Bearer + UA on every request). Source after config.sh.

# Output convention:
#   stdout: response body (empty on error)
#   exit:   0 on 2xx response, 1 on network error / timeout / non-2xx
# Caller decides whether to inject NETWORK_BLOCKER.

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
