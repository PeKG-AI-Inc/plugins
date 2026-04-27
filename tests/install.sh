#!/usr/bin/env bash
# Install-flow tests. Stub curl to serve from local plugins/ tree, run installers,
# assert filesystem + JSON shape, then re-run to assert idempotency.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PASS=0
FAIL=0
FAILED=()

assert_eq() {
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$1"); printf "  FAIL  %s\n    want: %s\n    got:  %s\n" "$1" "$2" "$3"
  fi
}
assert_file() {
  if [ -f "$2" ]; then
    PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$1"); printf "  FAIL  %s — file missing: %s\n" "$1" "$2"
  fi
}
assert_jq_path() {
  # assert_jq_path <label> <jq-filter> <file> <expected>
  local got
  got=$(jq -r "$2" "$3" 2>/dev/null || echo "<jq-error>")
  if [ "$got" = "$4" ]; then
    PASS=$((PASS + 1)); printf "  PASS  %s\n" "$1"
  else
    FAIL=$((FAIL + 1)); FAILED+=("$1"); printf "  FAIL  %s\n    want: %s\n    got:  %s\n" "$1" "$4" "$got"
  fi
}

# Build first.
bash "$ROOT/build.sh" >/dev/null 2>&1 || { echo "build failed"; exit 1; }

# Stub curl: serve files from $ROOT instead of the real CDN. The installer uses
# $PEKG_API_BASE/plugins/<target>/<file>.sh; we map that to local paths.
make_curl_stub() {
  local stub_dir="$1"
  cat > "$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
# curl stub: rewrite https://api.pekg.ai/<path> to PEKG_LOCAL_ROOT/<path>.
set -e
URL=""
OUT=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -fsSL|-fsfL|-sS|-sf|-fsfL|-s|-f|-S|-L) shift ;;
    --max-time) shift 2 ;;
    https://*|http://*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
if [ -z "$URL" ] || [ -z "$OUT" ]; then exit 22; fi
# Strip API_BASE prefix.
PATH_ONLY="${URL#http*://api.pekg.ai/}"
SRC="$PEKG_LOCAL_ROOT/$PATH_ONLY"
# Rewrite "plugins/claude-code/<f>.sh" -> "plugins/claude-code/dist/<f>.sh".
case "$PATH_ONLY" in
  plugins/claude-code/*.sh)
    name="${PATH_ONLY##*/}"
    SRC="$PEKG_LOCAL_ROOT/plugins/claude-code/dist/$name"
    ;;
  plugins/codex/*.sh)
    name="${PATH_ONLY##*/}"
    SRC="$PEKG_LOCAL_ROOT/plugins/codex/dist/$name"
    ;;
esac
if [ -f "$SRC" ]; then
  cp "$SRC" "$OUT"
else
  echo "stub: missing local file $SRC for url $URL" >&2
  exit 22
fi
STUB
  chmod +x "$stub_dir/curl"
}

# --- Test: Claude Code installer ---------------------------------------------
echo ""
echo "[install: claude-code]"

TEST_HOME=$(mktemp -d)
STUB_DIR=$(mktemp -d)
make_curl_stub "$STUB_DIR"

# Skip the connect step for this test (no real OTP) by pre-seeding a token.
mkdir -p "$TEST_HOME/.pekg"
echo '{"token":"stub-token"}' > "$TEST_HOME/.pekg/config.json"
chmod 600 "$TEST_HOME/.pekg/config.json"

# Run installer with PATH = stub:original so our curl wins.
HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" PEKG_API_BASE="https://api.pekg.ai" \
  PEKG_LOCAL_ROOT="$ROOT/.." \
  bash "$ROOT/claude-code/install.sh" >"$TEST_HOME/install.log" 2>&1 || {
    echo "  installer crashed; log:"
    sed 's/^/    /' "$TEST_HOME/install.log"
  }

assert_file "Claude Code: sessionstart.sh installed"      "$TEST_HOME/.pekg/hooks/sessionstart.sh"
assert_file "Claude Code: userpromptsubmit.sh installed"  "$TEST_HOME/.pekg/hooks/userpromptsubmit.sh"
assert_file "Claude Code: pretooluse.sh installed"        "$TEST_HOME/.pekg/hooks/pretooluse.sh"
assert_file "Claude Code: posttooluse.sh installed"       "$TEST_HOME/.pekg/hooks/posttooluse.sh"
assert_file "Claude Code: stop.sh installed"              "$TEST_HOME/.pekg/hooks/stop.sh"
assert_file "Claude Code: permissionrequest.sh installed" "$TEST_HOME/.pekg/hooks/permissionrequest.sh"
assert_file "Claude Code: precompact.sh installed"        "$TEST_HOME/.pekg/hooks/precompact.sh"
assert_file "Claude Code: pekg-connect.sh installed"      "$TEST_HOME/.pekg/bin/pekg-connect.sh"
assert_file "Claude Code: settings.json present"          "$TEST_HOME/.claude/settings.json"

# Validate settings.json shape.
if [ -f "$TEST_HOME/.claude/settings.json" ]; then
  assert_jq_path "Claude Code: SessionStart hook count"    '.hooks.SessionStart    | length' "$TEST_HOME/.claude/settings.json" "1"
  assert_jq_path "Claude Code: UserPromptSubmit hook count" '.hooks.UserPromptSubmit | length' "$TEST_HOME/.claude/settings.json" "1"
  assert_jq_path "Claude Code: PreToolUse hook count"       '.hooks.PreToolUse       | length' "$TEST_HOME/.claude/settings.json" "1"
  assert_jq_path "Claude Code: PostToolUse hook count"      '.hooks.PostToolUse      | length' "$TEST_HOME/.claude/settings.json" "1"
  assert_jq_path "Claude Code: Stop hook count"             '.hooks.Stop             | length' "$TEST_HOME/.claude/settings.json" "1"
  assert_jq_path "Claude Code: PermissionRequest hook count" '.hooks.PermissionRequest | length' "$TEST_HOME/.claude/settings.json" "1"
  assert_jq_path "Claude Code: PreCompact hook count"       '.hooks.PreCompact       | length' "$TEST_HOME/.claude/settings.json" "1"
  assert_jq_path "Claude Code: PreToolUse command path"     '.hooks.PreToolUse[0].hooks[0].command | endswith("/pretooluse.sh")' "$TEST_HOME/.claude/settings.json" "true"
fi

# Idempotency: re-run installer, assert same counts (not duplicated).
HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" PEKG_API_BASE="https://api.pekg.ai" \
  PEKG_LOCAL_ROOT="$ROOT/.." \
  bash "$ROOT/claude-code/install.sh" >>"$TEST_HOME/install.log" 2>&1 || true

assert_jq_path "Claude Code (re-run idempotent): SessionStart still 1"    '.hooks.SessionStart    | length' "$TEST_HOME/.claude/settings.json" "1"
assert_jq_path "Claude Code (re-run idempotent): PreToolUse still 1"      '.hooks.PreToolUse      | length' "$TEST_HOME/.claude/settings.json" "1"
assert_jq_path "Claude Code (re-run idempotent): all events count match"  '[.hooks | to_entries | .[] | .value | length] | add' "$TEST_HOME/.claude/settings.json" "7"

# Coexistence: add a non-PeKG hook then re-install and verify it survived.
jq '.hooks.PreToolUse += [{"matcher":"Bash","hooks":[{"type":"command","command":"echo other"}]}]' \
  "$TEST_HOME/.claude/settings.json" > "$TEST_HOME/.claude/settings.json.tmp" \
  && mv "$TEST_HOME/.claude/settings.json.tmp" "$TEST_HOME/.claude/settings.json"

HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" PEKG_API_BASE="https://api.pekg.ai" \
  PEKG_LOCAL_ROOT="$ROOT/.." \
  bash "$ROOT/claude-code/install.sh" >>"$TEST_HOME/install.log" 2>&1 || true

# Should now have 2 PreToolUse entries: the foreign + our managed.
assert_jq_path "Claude Code (coexist): PreToolUse count = 2"   '.hooks.PreToolUse | length' "$TEST_HOME/.claude/settings.json" "2"
assert_jq_path "Claude Code (coexist): foreign hook preserved" '[.hooks.PreToolUse[] | .hooks[] | select(.command == "echo other")] | length' "$TEST_HOME/.claude/settings.json" "1"

rm -rf "$TEST_HOME" "$STUB_DIR"

# --- Test: Codex installer ---------------------------------------------------
echo ""
echo "[install: codex]"

TEST_HOME=$(mktemp -d)
STUB_DIR=$(mktemp -d)
make_curl_stub "$STUB_DIR"
mkdir -p "$TEST_HOME/.pekg"
echo '{"token":"stub-token"}' > "$TEST_HOME/.pekg/config.json"
chmod 600 "$TEST_HOME/.pekg/config.json"

HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" PEKG_API_BASE="https://api.pekg.ai" \
  PEKG_LOCAL_ROOT="$ROOT/.." \
  bash "$ROOT/codex/install.sh" >"$TEST_HOME/install.log" 2>&1 || {
    echo "  installer crashed; log:"
    sed 's/^/    /' "$TEST_HOME/install.log"
  }

assert_file "Codex: codex-sessionstart.sh installed"      "$TEST_HOME/.pekg/hooks/codex-sessionstart.sh"
assert_file "Codex: codex-userpromptsubmit.sh installed"  "$TEST_HOME/.pekg/hooks/codex-userpromptsubmit.sh"
assert_file "Codex: codex-pretooluse.sh installed"        "$TEST_HOME/.pekg/hooks/codex-pretooluse.sh"
assert_file "Codex: codex-posttooluse.sh installed"       "$TEST_HOME/.pekg/hooks/codex-posttooluse.sh"
assert_file "Codex: codex-stop.sh installed"              "$TEST_HOME/.pekg/hooks/codex-stop.sh"
assert_file "Codex: codex-permissionrequest.sh installed" "$TEST_HOME/.pekg/hooks/codex-permissionrequest.sh"
assert_file "Codex: pekg-connect.sh installed"            "$TEST_HOME/.pekg/bin/pekg-connect.sh"
assert_file "Codex: hooks.json present"                   "$TEST_HOME/.codex/hooks.json"
assert_file "Codex: config.toml present"                  "$TEST_HOME/.codex/config.toml"
assert_file "Codex: pekg-connect prompt installed"        "$TEST_HOME/.codex/prompts/pekg-connect.md"

if [ -f "$TEST_HOME/.codex/hooks.json" ]; then
  assert_jq_path "Codex: SessionStart hook count"     '.hooks.SessionStart    | length' "$TEST_HOME/.codex/hooks.json" "1"
  assert_jq_path "Codex: PreToolUse hook count"       '.hooks.PreToolUse      | length' "$TEST_HOME/.codex/hooks.json" "1"
  assert_jq_path "Codex: PreToolUse command path"     '.hooks.PreToolUse[0].hooks[0].command | endswith("codex-pretooluse.sh")' "$TEST_HOME/.codex/hooks.json" "true"
fi

# config.toml should contain the codex_hooks=true and compact_prompt block.
if grep -q "codex_hooks = true" "$TEST_HOME/.codex/config.toml"; then
  PASS=$((PASS + 1)); echo "  PASS  Codex: config.toml has codex_hooks=true"
else
  FAIL=$((FAIL + 1)); FAILED+=("Codex: config.toml has codex_hooks=true")
  echo "  FAIL  Codex: config.toml missing codex_hooks=true"
fi

if grep -q "compact_prompt" "$TEST_HOME/.codex/config.toml"; then
  PASS=$((PASS + 1)); echo "  PASS  Codex: config.toml has compact_prompt"
else
  FAIL=$((FAIL + 1)); FAILED+=("Codex: config.toml has compact_prompt")
  echo "  FAIL  Codex: config.toml missing compact_prompt"
fi

# Idempotency for Codex: re-run, assert exactly one PeKG block.
HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" PEKG_API_BASE="https://api.pekg.ai" \
  PEKG_LOCAL_ROOT="$ROOT/.." \
  bash "$ROOT/codex/install.sh" >>"$TEST_HOME/install.log" 2>&1 || true

BEGIN_COUNT=$(grep -c "BEGIN PeKG" "$TEST_HOME/.codex/config.toml" 2>/dev/null || echo 0)
assert_eq "Codex (re-run idempotent): exactly one PeKG block in config.toml" "1" "$BEGIN_COUNT"

rm -rf "$TEST_HOME" "$STUB_DIR"

echo ""
echo "results: $PASS pass, $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed:\n'
  for t in "${FAILED[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
