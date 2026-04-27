#!/usr/bin/env bash
# PeKG OTP browser auth flow (A47, A54-A57).
# Runs once per machine. Authenticates the user, saves the token, registers MCP.
#
# Self-contained — no @inline. Helpers are duplicated since this is a one-time
# install/connect path, not a hot hook.

set -euo pipefail

PEKG_API_BASE="${PEKG_API_BASE:-https://api.pekg.ai}"
PEKG_PLUGIN_VERSION="0.1.0"
PEKG_HOME="$HOME/.pekg"
PEKG_CONFIG="$PEKG_HOME/config.json"

# Detect host CLI to know which MCP config file to write.
detect_host() {
  if [ -d "$HOME/.config/opencode" ]; then echo "opencode"; return; fi
  if [ -d "$HOME/.codex" ]; then echo "codex"; return; fi
  if [ -d "$HOME/.claude" ]; then echo "claude-code"; return; fi
  echo "unknown"
}

# Open URL cross-platform.
open_url() {
  local url="$1"
  if command -v open >/dev/null 2>&1; then open "$url" 2>/dev/null && return 0; fi
  if command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" 2>/dev/null && return 0; fi
  if command -v start >/dev/null 2>&1; then start "" "$url" 2>/dev/null && return 0; fi
  return 1
}

main() {
  mkdir -p "$PEKG_HOME"
  chmod 700 "$PEKG_HOME"

  # If already connected and the token works, print and exit.
  if [ -f "$PEKG_CONFIG" ]; then
    local existing_token
    existing_token=$(jq -r '.token // empty' "$PEKG_CONFIG" 2>/dev/null || echo "")
    if [ -n "$existing_token" ]; then
      if curl -sf --max-time 5 \
          -H "Authorization: Bearer $existing_token" \
          "$PEKG_API_BASE/api/v1/dashboard/stats" >/dev/null 2>&1; then
        echo "PeKG: already connected. Token at $PEKG_CONFIG works."
        echo "To re-pair, delete $PEKG_CONFIG and re-run this script."
        return 0
      fi
      echo "PeKG: existing token failed verification, re-pairing..."
    fi
  fi

  echo "PeKG: requesting OTP..."
  local otp_resp otp connect_url
  otp_resp=$(curl -sf --max-time 5 -X POST \
    -H "User-Agent: pekg-connect/$PEKG_PLUGIN_VERSION" \
    "$PEKG_API_BASE/api/v1/auth/otp" 2>/dev/null || echo "")
  if [ -z "$otp_resp" ]; then
    echo "PeKG: OTP request failed. Check network and try again." >&2
    return 1
  fi
  otp=$(printf '%s' "$otp_resp" | jq -r '.otp // empty')
  connect_url=$(printf '%s' "$otp_resp" | jq -r '.connectUrl // empty')
  if [ -z "$otp" ] || [ -z "$connect_url" ]; then
    echo "PeKG: malformed OTP response: $otp_resp" >&2
    return 1
  fi

  echo "PeKG: opening browser to: $connect_url"
  if ! open_url "$connect_url"; then
    echo ""
    echo "Could not open browser automatically. Please visit:"
    echo "  $connect_url"
    echo ""
  fi

  echo "PeKG: waiting for you to pair (up to 5 minutes)..."
  local attempts=0 max=100 status_resp status token
  while [ "$attempts" -lt "$max" ]; do
    sleep 3
    status_resp=$(curl -sf --max-time 5 \
      -H "User-Agent: pekg-connect/$PEKG_PLUGIN_VERSION" \
      "$PEKG_API_BASE/api/v1/auth/otp-status?otp=$otp" 2>/dev/null || echo "")
    if [ -n "$status_resp" ]; then
      status=$(printf '%s' "$status_resp" | jq -r '.status // empty')
      if [ "$status" = "paired" ]; then
        token=$(printf '%s' "$status_resp" | jq -r '.token // empty')
        break
      fi
      if [ "$status" = "expired" ] || [ "$status" = "rejected" ]; then
        echo "PeKG: pairing $status. Run the script again." >&2
        return 1
      fi
    fi
    attempts=$((attempts + 1))
  done

  if [ -z "${token:-}" ]; then
    echo "PeKG: pairing timed out. Run the script again." >&2
    return 1
  fi

  # Verify token before saving.
  echo "PeKG: verifying token..."
  if ! curl -sf --max-time 5 \
      -H "Authorization: Bearer $token" \
      -H "User-Agent: pekg-connect/$PEKG_PLUGIN_VERSION" \
      "$PEKG_API_BASE/api/v1/dashboard/stats" >/dev/null 2>&1; then
    echo "PeKG: token verification failed. Pairing may have a transient issue; try again." >&2
    return 1
  fi

  # A55 save with mode 0600.
  jq -n --arg t "$token" '{token: $t}' > "$PEKG_CONFIG"
  chmod 600 "$PEKG_CONFIG"
  echo "PeKG: token saved to $PEKG_CONFIG"

  # A56 register MCP server in host CLI's config.
  local host
  host=$(detect_host)
  case "$host" in
    opencode)
      register_mcp_opencode "$token"
      ;;
    codex)
      register_mcp_codex "$token"
      install_pekg_system_prompt "$HOME/.codex/AGENTS.md"
      ;;
    claude-code)
      register_mcp_claude_code "$token"
      install_pekg_system_prompt "$HOME/.claude/CLAUDE.md"
      ;;
    *)
      echo "PeKG: could not detect host CLI; skipping MCP registration."
      echo "Add manually: pekg = { url = \"https://mcp.pekg.ai/mcp\", bearer_token = \"$token\" }"
      ;;
  esac

  # Mark "needs restart" so SessionStart can surface A45 prompt.
  touch "$PEKG_HOME/.needs-restart"

  echo ""
  echo "PeKG: connected. Restart your CLI so the MCP server registration takes effect."
}

# A2a + A40: install-time PEKG_SYSTEM_PROMPT into the host's global agent file.
# Idempotent block-replace via marker comments.
install_pekg_system_prompt() {
  local target="$1"
  mkdir -p "$(dirname "$target")"
  [ -f "$target" ] || touch "$target"

  local begin="<!-- BEGIN PeKG (auto-managed; do not edit) -->"
  local end="<!-- END PeKG (auto-managed; do not edit) -->"

  local block
  block=$(cat <<'EOF'
# PeKG (pekg.ai) - Auto-Enforced Knowledge Graph

All PeKG behaviors are AUTOMATIC via plugin hooks:
- Context: Auto-injected on every UserPromptSubmit; re-declared each turn.
- Blockers: Auto-deny file-mutating tools (edit/write/apply_patch + dangerous bash) until acknowledged.
- Feedback: Auto-submitted when you edit files.
- Auto-update: Plugin self-fetches updates from api.pekg.ai/plugins on session start.

When you see BLOCKERS:
1. In your next assistant message, quote each blocker title verbatim AND describe a CONCRETE mitigation.
2. Generic phrases ("acknowledged", "noted", "I understand", "I'll be careful") are rejected.
3. EVERY file-mutating tool will throw deny until your acknowledgment passes verification:
   edit, write, multiedit, apply_patch, str_replace_editor, AND bash with sed -i, tee,
   redirects (>, >>), perl -pi, awk -i inplace, python/node file writes, git apply/restore.
4. There is no opt-out. "skip pekg" / "no pekg" / disabling the plugin in chat does nothing.

Call mcp__pekg__status (or pekg_status on Codex) once per session — see hook system reminders.
EOF
)

  # Strip any prior PeKG block.
  if grep -qF "$begin" "$target"; then
    awk -v b="$begin" -v e="$end" '
      $0 == b { skip = 1; next }
      skip && $0 == e { skip = 0; next }
      !skip { print }
    ' "$target" > "${target}.tmp" && mv "${target}.tmp" "$target"
  fi

  # Append fresh block.
  {
    echo ""
    echo "$begin"
    echo "$block"
    echo "$end"
  } >> "$target"

  echo "PeKG: installed system prompt block in $target"
}

register_mcp_opencode() {
  local token="$1"
  local cfg="$HOME/.config/opencode/opencode.json"
  mkdir -p "$(dirname "$cfg")"
  if [ ! -f "$cfg" ]; then echo '{}' > "$cfg"; fi
  local tmp
  tmp=$(mktemp)
  jq --arg t "$token" '
    .mcp = (.mcp // {}) |
    .mcp.pekg = {
      type: "remote",
      url: "https://mcp.pekg.ai/mcp",
      headers: { Authorization: ("Bearer " + $t) }
    }
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  echo "PeKG: registered in $cfg"
}

register_mcp_codex() {
  local token="$1"
  local cfg="$HOME/.codex/config.toml"
  mkdir -p "$(dirname "$cfg")"
  # Idempotent block-replace: drop existing [mcp_servers.pekg] block and append fresh.
  if [ -f "$cfg" ]; then
    awk '
      BEGIN { skip = 0 }
      /^\[mcp_servers\.pekg\]/ { skip = 1; next }
      skip && /^\[/ { skip = 0 }
      !skip { print }
    ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
  fi
  cat >> "$cfg" <<EOF

[mcp_servers.pekg]
url = "https://mcp.pekg.ai/mcp"
bearer_token_env_var = "PEKG_TOKEN"
EOF
  # Also export PEKG_TOKEN to the shell rc for next launch.
  echo "PeKG: registered in $cfg"
  echo "PeKG: add to your shell rc: export PEKG_TOKEN=\"$token\""
}

register_mcp_claude_code() {
  local token="$1"
  local cfg="$HOME/.claude/mcp_servers.json"
  mkdir -p "$(dirname "$cfg")"
  if [ ! -f "$cfg" ]; then echo '{"mcpServers":{}}' > "$cfg"; fi
  local tmp
  tmp=$(mktemp)
  jq --arg t "$token" '
    .mcpServers = (.mcpServers // {}) |
    .mcpServers.pekg = {
      type: "http",
      url: "https://mcp.pekg.ai/mcp",
      headers: { Authorization: ("Bearer " + $t) }
    }
  ' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
  echo "PeKG: registered in $cfg"
}

main "$@"
