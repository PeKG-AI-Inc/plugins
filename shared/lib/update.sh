#!/usr/bin/env bash
# PeKG self-update mechanism (A13).
# Source after config.sh, fetch.sh.
#
# Invoked from SessionStart. Checks api.pekg.ai/plugins/<target>.json once per
# UPDATE_CHECK_INTERVAL_MS (1h) and replaces stale dist scripts atomically.

PEKG_UPDATE_INTERVAL_S="${PEKG_UPDATE_INTERVAL_S:-3600}"
PEKG_UPDATE_MARKER="$HOME/.pekg/plugin-update-check.json"

# pekg_maybe_update <target> <hooks-dir>
# target: claude-code | codex
# hooks-dir: e.g. ~/.pekg/hooks
pekg_maybe_update() {
  local target="$1"
  local hooks_dir="$2"

  pekg_offline && return 0

  local now last
  now=$(date +%s)
  last=0
  if [ -f "$PEKG_UPDATE_MARKER" ]; then
    last=$(jq -r --arg k "${target}_lastCheck" '.[$k] // 0' "$PEKG_UPDATE_MARKER" 2>/dev/null || echo 0)
  fi
  if [ $((now - last)) -lt "$PEKG_UPDATE_INTERVAL_S" ]; then
    return 0
  fi

  local manifest
  manifest=$(curl -sf --max-time 5 \
    -H "User-Agent: $(pekg_ua)" \
    "$PEKG_API_BASE/plugins/${target}.json" 2>/dev/null || true)

  # Persist last-check timestamp regardless of fetch result.
  pekg_update_marker_set "${target}_lastCheck" "$now"

  [ -z "$manifest" ] && return 0

  local current_version remote_version files
  current_version="${PEKG_PLUGIN_VERSION:-0.0.0}"
  remote_version=$(printf '%s' "$manifest" | jq -r '.version // empty')
  [ -z "$remote_version" ] && return 0
  if [ "$remote_version" = "$current_version" ]; then
    return 0
  fi

  # Files: { "<basename>": "<sha256>", ... } or array of {name,url,sha256}.
  files=$(printf '%s' "$manifest" | jq -c '.files // []')
  [ "$files" = "[]" ] && return 0

  mkdir -p "$hooks_dir"
  local count i
  count=$(printf '%s' "$files" | jq 'length' 2>/dev/null || echo 0)
  for ((i=0; i<count; i++)); do
    local entry name url
    entry=$(printf '%s' "$files" | jq -c ".[$i]")
    name=$(printf '%s' "$entry" | jq -r '.name // empty')
    url=$(printf '%s' "$entry" | jq -r '.url // empty')
    [ -z "$name" ] || [ -z "$url" ] && continue

    local tmp dest
    tmp="${hooks_dir}/.${name}.tmp.$$"
    dest="${hooks_dir}/${name}"
    if curl -sf --max-time 10 -H "User-Agent: $(pekg_ua)" -o "$tmp" "$url" 2>/dev/null; then
      # Sanity: must be a non-empty file.
      if [ -s "$tmp" ]; then
        chmod +x "$tmp"
        mv "$tmp" "$dest"
      else
        rm -f "$tmp"
      fi
    else
      rm -f "$tmp"
    fi
  done

  pekg_update_marker_set "${target}_lastVersion" "$remote_version"
  # A2d: surface a one-time notice on next session indicating an update was
  # downloaded. SessionStart reads + clears.
  printf 'PeKG plugin updated from %s to %s — restart your CLI for changes.' \
    "$current_version" "$remote_version" \
    > "$HOME/.pekg/.update-notice" 2>/dev/null
}

pekg_update_marker_set() {
  local key="$1" val="$2"
  mkdir -p "$(dirname "$PEKG_UPDATE_MARKER")"
  local cur='{}'
  [ -f "$PEKG_UPDATE_MARKER" ] && cur=$(cat "$PEKG_UPDATE_MARKER" 2>/dev/null || echo '{}')
  printf '%s' "$cur" | jq --arg k "$key" --arg v "$val" '.[$k] = $v' > "${PEKG_UPDATE_MARKER}.tmp" \
    && mv "${PEKG_UPDATE_MARKER}.tmp" "$PEKG_UPDATE_MARKER"
}
