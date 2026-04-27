#!/usr/bin/env bash
# PeKG shared config + project-origin + UA stamping (A16, A60).
# Source from each hook. Sets exported vars; does not call exit.

# A16a: Read ~/.pekg/config.json, extract token, fail-soft if missing.
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
