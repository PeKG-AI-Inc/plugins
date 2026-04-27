#!/usr/bin/env bash
# Smoke-test harness for plugins/{claude-code,codex}/dist/*.sh
#
# Usage: bash plugins/tests/run.sh
# Exits non-zero if any assertion fails.
#
# Tests run with:
#   PEKG_OFFLINE=1                   to skip real network calls
#   HOME=$tmp                        to isolate from real ~/.pekg state
#   stdin = synthetic JSON event
#   stdout = hook's JSON output
#
# Assertions check the JSON shape via jq filters.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIST_CC="$ROOT/claude-code/dist"
DIST_CX="$ROOT/codex/dist"

# Build before testing.
bash "$ROOT/build.sh" >/dev/null 2>&1 || { echo "build failed"; exit 1; }

# Clear per-session caches that prior runs left under /tmp/. Test session ids
# are reused across runs (e.g. "t15"); leftover firstRun markers + seen-files
# leak A20 / A19 state across test invocations and cause false negatives.
rm -rf /tmp/pekg-session-* 2>/dev/null || true

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$label")
    printf "  FAIL  %s\n    want: %s\n    got:  %s\n" "$label" "$want" "$got"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
    printf "  PASS  %s\n" "$label"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("$label")
    printf "  FAIL  %s\n    needle: %s\n    haystack: %s\n" "$label" "$needle" "$haystack"
  fi
}

with_isolated_home() {
  local tmp
  tmp=$(mktemp -d)
  HOME="$tmp" PEKG_OFFLINE=1 "$@"
  rm -rf "$tmp"
}

run_hook() {
  # run_hook <hook-path> <event-json>
  local hook="$1" event="$2"
  HOME="$TEST_HOME" PEKG_OFFLINE="${PEKG_OFFLINE:-0}" bash "$hook" <<<"$event" 2>/dev/null
}

with_seed() {
  # with_seed <test-name> <seed-block>
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test-token-fake"}' > "$TEST_HOME/.pekg/config.json"
  chmod 600 "$TEST_HOME/.pekg/config.json"
  printf "\n[%s]\n" "$1"
  eval "$2"
  rm -rf "$TEST_HOME"
}

# --- Test 1: SessionStart no token --------------------------------------------
test_sessionstart_no_token() {
  TEST_HOME=$(mktemp -d)
  local out
  out=$(run_hook "$DIST_CC/sessionstart.sh" '{"session_id":"t1"}')
  rm -rf "$TEST_HOME"
  local got
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  assert_contains "Claude Code SessionStart no-token → connect prompt" "not connected" "$got"
}

# --- Test 2: SessionStart offline → NETWORK_BLOCKER ---------------------------
test_sessionstart_offline_blocker() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  chmod 600 "$TEST_HOME/.pekg/config.json"

  local out
  out=$(PEKG_OFFLINE=1 run_hook "$DIST_CC/sessionstart.sh" '{"session_id":"t2"}')

  local got_msg
  got_msg=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
  assert_contains "Claude Code SessionStart offline → unreachable msg" "api unreachable" "$got_msg"

  # State file should be written with synthetic NETWORK_BLOCKER.
  local state_file="$TEST_HOME/.pekg/sessions/t2.json"
  if [ -f "$state_file" ]; then
    local synth_id
    synth_id=$(jq -r '.blockers[0].id // empty' "$state_file")
    assert_eq "Claude Code SessionStart offline → NETWORK_BLOCKER persisted" "00000000-0000-0000-0000-pekgNetworkErr" "$synth_id"
  else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("Claude Code SessionStart offline → state file not written")
    echo "  FAIL  state file missing: $state_file"
  fi

  rm -rf "$TEST_HOME"
}

# --- Test 3: PreToolUse blocker gate denies Edit ------------------------------
test_pretooluse_blocker_gate() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  touch "$TEST_HOME/.pekg/session-state/t3.status_called"  # bypass legacy gate
  jq -n '{
    task: {},
    blockers: [{id:"abc",title:"Use parameterized SQL",recommendation:"prepared statements",tier:"blocker"}],
    timestamp: 0,
    expiresAt: 9999999999
  }' > "$TEST_HOME/.pekg/sessions/t3.json"

  local out
  # Use .ts path to avoid Issue 8 markdown re-tier (which would correctly
  # demote a code-domain "parameterized SQL" blocker on a .txt file).
  out=$(run_hook "$DIST_CC/pretooluse.sh" '{"session_id":"t3","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.ts"}}')
  local decision reason
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
  assert_eq "Claude Code PreToolUse blocker → deny" "deny" "$decision"
  assert_contains "Claude Code PreToolUse blocker → reason mentions title" "Use parameterized SQL" "$reason"

  rm -rf "$TEST_HOME"
}

# --- Test 4: PreToolUse dangerous-bash gate -----------------------------------
test_pretooluse_dangerous_bash() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  touch "$TEST_HOME/.pekg/session-state/t4.status_called"
  jq -n '{task:{},blockers:[{id:"x",title:"Test blocker",recommendation:"do thing",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t4.json"

  local out
  out=$(run_hook "$DIST_CC/pretooluse.sh" '{"session_id":"t4","tool_name":"Bash","tool_input":{"command":"sed -i s/foo/bar/ x.txt"}}')
  local decision
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  assert_eq "Claude Code PreToolUse sed -i + blocker → deny" "deny" "$decision"

  rm -rf "$TEST_HOME"
}

# --- Test 5: PreToolUse no blockers → allow -----------------------------------
test_pretooluse_no_blockers_allow() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  touch "$TEST_HOME/.pekg/session-state/t5.status_called"
  jq -n '{task:{},blockers:[],timestamp:0,expiresAt:9999999999}' > "$TEST_HOME/.pekg/sessions/t5.json"

  local out
  out=$(run_hook "$DIST_CC/pretooluse.sh" '{"session_id":"t5","tool_name":"Edit","tool_input":{"file_path":"/tmp/x.txt"}}')
  # No body = exit 0 = allow.
  assert_eq "Claude Code PreToolUse no blockers → allow (empty stdout)" "" "$out"

  rm -rf "$TEST_HOME"
}

# --- Test 6: PermissionRequest blocker → deny ---------------------------------
test_permissionrequest_blocker() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{task:{},blockers:[{id:"a",title:"Block Y",recommendation:"do Z",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t6.json"

  local out
  out=$(run_hook "$DIST_CC/permissionrequest.sh" '{"session_id":"t6","tool_name":"Write","tool_input":{}}')
  local behavior
  behavior=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.decision.behavior // empty')
  assert_eq "Claude Code PermissionRequest blocker → deny behavior" "deny" "$behavior"

  rm -rf "$TEST_HOME"
}

# --- Test 7: PreCompact emits structured prompt -------------------------------
test_precompact_structured_prompt() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{
    task: { currentTask: "fix login bug", activeFiles: { filesModified: ["src/auth.ts"], filesRead: ["docs/api.md"] } },
    blockers: [{id:"b",title:"Use HTTPS only",recommendation:"redirect HTTP to HTTPS",tier:"blocker"}],
    timestamp: 0,
    expiresAt: 9999999999
  }' > "$TEST_HOME/.pekg/sessions/t7.json"

  local out
  out=$(run_hook "$DIST_CC/precompact.sh" '{"session_id":"t7"}')
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
  assert_contains "Claude Code PreCompact → includes Current Task" "fix login bug" "$ctx"
  assert_contains "Claude Code PreCompact → includes file path" "src/auth.ts" "$ctx"
  assert_contains "Claude Code PreCompact → includes blocker title" "Use HTTPS only" "$ctx"

  rm -rf "$TEST_HOME"
}

# --- Test 8: Stop hook KB_INGEST parsing --------------------------------------
test_stop_kb_ingest() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{task:{activeFiles:{filesModified:["src/foo.ts"]}},blockers:[{id:"x",title:"T",recommendation:"R",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t8.json"
  # Synthesize a transcript ending with the agent quoting the blocker + KB_INGEST.
  local transcript="$TEST_HOME/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"user","message":{"role":"user","content":"do thing"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll address blocker T by doing R.\n\nKB_INGEST: My pattern | pattern | This is a useful learning"}]}}
JSONL

  # Run; the script's parse fires fire-and-forget HTTP — we just want it not to crash.
  run_hook "$DIST_CC/stop.sh" "{\"session_id\":\"t8\",\"transcript_path\":\"$transcript\"}" >/dev/null
  # Asserting "did not crash" via $?.
  assert_eq "Claude Code Stop with KB_INGEST line → exit 0" "0" "$?"

  rm -rf "$TEST_HOME"
}

# --- Test 9: Codex sessionstart parity ----------------------------------------
test_codex_sessionstart() {
  TEST_HOME=$(mktemp -d)
  local out
  out=$(run_hook "$DIST_CX/sessionstart.sh" '{"session_id":"cx1"}')
  local got
  got=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
  assert_contains "Codex SessionStart no-token → connect prompt" "not connected" "$got"
  rm -rf "$TEST_HOME"
}

# --- Test 10: Codex pretooluse blocker gate -----------------------------------
test_codex_pretooluse_blocker() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{task:{},blockers:[{id:"x",title:"Codex blocker",recommendation:"fix it",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/cx2.json"

  local out
  out=$(run_hook "$DIST_CX/pretooluse.sh" '{"session_id":"cx2","tool_name":"apply_patch","tool_input":{"input":"*** Update File: x.py"}}')
  local decision
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  assert_eq "Codex PreToolUse apply_patch + blocker → deny" "deny" "$decision"
  rm -rf "$TEST_HOME"
}

# --- Test 11: A23 task-subagent blocker propagation --------------------------
test_pretooluse_task_subagent_propagation() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  touch "$TEST_HOME/.pekg/session-state/t11.status_called"
  jq -n '{task:{},blockers:[{id:"a",title:"Inherit me",recommendation:"do X",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t11.json"

  local out modified decision
  out=$(run_hook "$DIST_CC/pretooluse.sh" '{"session_id":"t11","tool_name":"Task","tool_input":{"prompt":"original task prompt","subagent_type":"Explore"}}')
  # CC 2.1.119: hook returns hookSpecificOutput.{permissionDecision, updatedInput}.
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)
  modified=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.prompt // empty' 2>/dev/null)
  assert_eq       "Claude Code A23 Task → permissionDecision allow"           "allow" "$decision"
  assert_contains "Claude Code A23 Task → blocker title injected into prompt" "Inherit me" "$modified"
  assert_contains "Claude Code A23 Task → original prompt preserved"          "original task prompt" "$modified"
  # updatedInput must include all original fields (subagent_type) — host
  # replaces input wholesale; missing fields would error at tool dispatch.
  local subagent_type
  subagent_type=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.updatedInput.subagent_type // empty' 2>/dev/null)
  assert_eq       "Claude Code A23 Task → updatedInput preserves subagent_type" "Explore" "$subagent_type"

  rm -rf "$TEST_HOME"
}

# --- Test 12: A57 file content pre-capture ------------------------------------
test_pretooluse_precap_writes_before_snapshot() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  touch "$TEST_HOME/.pekg/session-state/t12.status_called"
  jq -n '{task:{},blockers:[],timestamp:0,expiresAt:9999999999}' > "$TEST_HOME/.pekg/sessions/t12.json"

  local target="$TEST_HOME/file-to-edit.txt"
  echo "original content" > "$target"

  run_hook "$DIST_CC/pretooluse.sh" "{\"session_id\":\"t12\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$target\"}}" >/dev/null
  # Snapshot dir should have one .before file.
  local cap_count
  cap_count=$(find "$TEST_HOME/.pekg/precap/t12" -name '*.before' 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "Claude Code A57 Edit → pre-capture file written" "1" "$cap_count"

  rm -rf "$TEST_HOME"
}

# --- Test 13: A28 completed-steps tracking via Stop ---------------------------
test_stop_completed_steps() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{task:{},blockers:[],timestamp:0,expiresAt:9999999999}' > "$TEST_HOME/.pekg/sessions/t13.json"

  local transcript="$TEST_HOME/transcript.jsonl"
  # Real Claude Code transcript shape: top-level .type, .message.content[].text.
  cat > "$transcript" <<'JSONL'
{"type":"user","message":{"role":"user","content":"do work"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I added the new auth handler. I refactored the login flow. I fixed the typo in README."}]}}
JSONL

  PEKG_OFFLINE=1 run_hook "$DIST_CC/stop.sh" "{\"session_id\":\"t13\",\"transcript_path\":\"$transcript\"}" >/dev/null
  local steps_count
  steps_count=$(jq -r '.task.completedSteps // [] | length' "$TEST_HOME/.pekg/sessions/t13.json" 2>/dev/null || echo 0)
  # Expect 3 first-person completion phrases captured.
  if [ "$steps_count" -ge 1 ]; then
    PASS=$((PASS + 1)); echo "  PASS  Claude Code A28 Stop → completedSteps captured ($steps_count)"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("Claude Code A28 Stop → completedSteps captured")
    echo "  FAIL  Claude Code A28 Stop → expected ≥1 completedStep, got $steps_count"
  fi

  rm -rf "$TEST_HOME"
}

# --- Test 14: A32 feedback queue persistence on offline -----------------------
test_feedback_queue_offline() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  # Persist a blocker and trigger an Edit that submits implicit feedback.
  jq -n '{task:{activeFiles:{}},blockers:[{id:"art-X",title:"T",recommendation:"R",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t14.json"

  local target="$TEST_HOME/edit-target.txt"
  echo "before" > "$target"
  PEKG_OFFLINE=1 run_hook "$DIST_CC/posttooluse.sh" "{\"session_id\":\"t14\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$target\"}}" >/dev/null

  local q_count
  q_count=$(find "$TEST_HOME/.pekg/feedback-queue" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  if [ "$q_count" -ge 1 ]; then
    PASS=$((PASS + 1)); echo "  PASS  Claude Code A32 offline feedback queued ($q_count file)"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("Claude Code A32 offline feedback queued")
    echo "  FAIL  Claude Code A32 expected ≥1 queue file, got $q_count"
  fi

  rm -rf "$TEST_HOME"
}

# --- Test 15: A43 token budget — always-blocker fallback (via real hook) ----
test_userpromptsubmit_always_blocker() {
  TEST_HOME=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"

  # Stub `curl` so the hook's POST to /api/v1/context-lookup returns synthetic
  # data: 2 huge warnings + 1 short blocker. With a tiny budget, the budget
  # filter should fill with warnings, then fallback path injects the blocker.
  local long_summary
  long_summary=$(printf 'x%.0s' {1..400})
  cat > "$STUB_DIR/curl" <<STUB
#!/usr/bin/env bash
# Stub curl: any POST to context-lookup returns the synthetic 3-article payload.
# Any other URL: empty 200.
URL=""
OUT=""
DATA=""
PRINT_OUT=1
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) OUT="\$2"; PRINT_OUT=0; shift 2 ;;
    -d) DATA="\$2"; shift 2 ;;
    -X|--max-time|-H) shift 2 ;;
    -fsSL|-fsfL|-sS|-sf|-fsfL|-s|-f|-S|-L|--fail-with-body) shift ;;
    https://*|http://*) URL="\$1"; shift ;;
    *) shift ;;
  esac
done
case "\$URL" in
  *context-lookup*)
    PAYLOAD='{"relevant":[{"articleId":"w1","title":"Warn 1","summary":"$long_summary","tier":"warning","relevance":0.95},{"articleId":"w2","title":"Warn 2","summary":"$long_summary","tier":"warning","relevance":0.94},{"articleId":"b1","title":"Critical Blocker","summary":"short","tier":"blocker","relevance":0.55}]}'
    ;;
  *)
    PAYLOAD='{}'
    ;;
esac
if [ -n "\$OUT" ]; then printf '%s' "\$PAYLOAD" > "\$OUT"; else printf '%s' "\$PAYLOAD"; fi
exit 0
STUB
  chmod +x "$STUB_DIR/curl"

  local out
  out=$(HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" PEKG_CONTEXT_TOKEN_BUDGET=50 \
    bash "$DIST_CC/userpromptsubmit.sh" <<<'{"session_id":"t15","prompt":"do work","cwd":"/tmp","session":{"cwd":"/tmp"}}' 2>/dev/null)

  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
  assert_contains "A43 token-budget always includes the blocker (Critical Blocker visible in output)" "Critical Blocker" "$ctx"

  rm -rf "$TEST_HOME" "$STUB_DIR"
}

# --- Test 16: A29 cost cap — verifier returns 1 when at cap -------------------
test_byollm_cost_cap() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  # Pre-seed verifCount at the cap (5).
  jq -n '{task:{verifCount:5},blockers:[{id:"x",title:"T",recommendation:"R",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t16.json"

  # Run the Stop hook with a heuristic-passing assistant message; A12a should
  # decline due to cap, leaving ackVerifiedAt unset.
  local transcript="$TEST_HOME/transcript.jsonl"
  cat > "$transcript" <<'JSONL'
{"type":"user","message":{"role":"user","content":"go"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I will replace the call to T by following recommendation R: I added the safer alternative."}]}}
JSONL

  HOME="$TEST_HOME" PEKG_OFFLINE=1 PEKG_BYOLLM_RECURSING=1 \
    bash "$DIST_CC/stop.sh" <<<"{\"session_id\":\"t16\",\"transcript_path\":\"$transcript\"}" >/dev/null 2>&1 || true

  local ack_set
  ack_set=$(jq -r '.task.ackVerifiedAt // empty' "$TEST_HOME/.pekg/sessions/t16.json" 2>/dev/null)
  if [ -z "$ack_set" ]; then
    PASS=$((PASS + 1)); echo "  PASS  A29 cost cap → BYOLLM declines, no ackVerifiedAt set"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("A29 cost cap → BYOLLM declines, no ackVerifiedAt set")
    echo "  FAIL  A29 cost cap — ackVerifiedAt was set despite cap exhaustion: $ack_set"
  fi

  rm -rf "$TEST_HOME"
}

# --- Test 17: A27 failed-approach extraction ---------------------------------
test_posttooluse_failed_approach_extraction() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{task:{},blockers:[],timestamp:0,expiresAt:9999999999}' > "$TEST_HOME/.pekg/sessions/t27.json"

  PEKG_OFFLINE=1 run_hook "$DIST_CC/posttooluse.sh" '{"session_id":"t27","tool_name":"Bash","tool_input":{"command":"git push"},"tool_response":{"is_error":true,"content":[{"type":"text","text":"fatal: refusing to merge unrelated histories"}]}}' >/dev/null
  local count first
  count=$(jq '.task.failedApproaches // [] | length' "$TEST_HOME/.pekg/sessions/t27.json" 2>/dev/null || echo 0)
  first=$(jq -r '.task.failedApproaches // [] | .[0] // empty' "$TEST_HOME/.pekg/sessions/t27.json" 2>/dev/null)
  if [ "$count" -ge 1 ] && printf '%s' "$first" | grep -qF "fatal: refusing"; then
    PASS=$((PASS + 1)); echo "  PASS  A27 failed-approach extracted from tool error"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("A27 failed-approach extracted from tool error")
    echo "  FAIL  A27 — count=$count first=$first"
  fi
  rm -rf "$TEST_HOME"
}

# --- Test 18: A31a feedback cooldown blocks repeat submission ----------------
test_feedback_cooldown_blocks_repeat() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{task:{activeFiles:{}},blockers:[{id:"art-Y","title":"T","recommendation":"R",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t31.json"
  local target="$TEST_HOME/edit.txt"
  echo "before" > "$target"

  # First edit: should queue feedback (offline → cooldown recorded).
  PEKG_OFFLINE=1 run_hook "$DIST_CC/posttooluse.sh" "{\"session_id\":\"t31\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$target\"}}" >/dev/null
  local q1
  q1=$(find "$TEST_HOME/.pekg/feedback-queue" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')

  # Second edit immediately: should be blocked by 30s cooldown.
  PEKG_OFFLINE=1 run_hook "$DIST_CC/posttooluse.sh" "{\"session_id\":\"t31\",\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$target\"}}" >/dev/null
  local q2
  q2=$(find "$TEST_HOME/.pekg/feedback-queue" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')

  if [ "$q1" -ge 1 ] && [ "$q2" -eq "$q1" ]; then
    PASS=$((PASS + 1)); echo "  PASS  A31a cooldown blocked repeat submission ($q1 queued, then no new)"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("A31a cooldown blocked repeat submission")
    echo "  FAIL  A31a — q1=$q1 q2=$q2 (expected q2 == q1)"
  fi
  rm -rf "$TEST_HOME"
}

# --- Test 19: A54 RESUMED SESSION block injection ----------------------------
test_userpromptsubmit_resumed_session_block() {
  TEST_HOME=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  # Pre-seed prior session state with currentTask + filesModified + failedApproaches.
  jq -n '{
    task: {
      currentTask: "fix login bug",
      activeFiles: {filesModified: ["/src/auth.ts"], filesRead: []},
      failedApproaches: ["Edit - patch failed: hunk 1 does not apply"]
    },
    blockers: [],
    timestamp: 0,
    expiresAt: 9999999999
  }' > "$TEST_HOME/.pekg/sessions/t54.json"

  cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
URL=""; OUT=""
while [ $# -gt 0 ]; do case "$1" in -o) OUT="$2"; shift 2 ;; -d|-X|--max-time|-H) shift 2 ;; -fsSL|-fsfL|-sS|-sf|-fsfL|-s|-f|-S|-L|--fail-with-body) shift ;; https://*|http://*) URL="$1"; shift ;; *) shift ;; esac; done
case "$URL" in
  *context-lookup/guaranteed*) PAYLOAD='{"relevant":[]}' ;;
  *context-lookup*) PAYLOAD='{"relevant":[]}' ;;
  *) PAYLOAD='{}' ;;
esac
if [ -n "$OUT" ]; then printf '%s' "$PAYLOAD" > "$OUT"; else printf '%s' "$PAYLOAD"; fi
STUB
  chmod +x "$STUB_DIR/curl"

  local out
  out=$(HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" bash "$DIST_CC/userpromptsubmit.sh" \
    <<<'{"session_id":"t54","prompt":"continue","cwd":"/tmp","session":{"cwd":"/tmp"}}' 2>/dev/null)
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
  assert_contains "A54 resumed-session block includes prior task" "fix login bug" "$ctx"
  assert_contains "A54 resumed-session block includes recent file" "/src/auth.ts" "$ctx"
  assert_contains "A54 resumed-session block includes failed approach" "patch failed" "$ctx"
  rm -rf "$TEST_HOME" "$STUB_DIR"
}

# --- Test 20: A2d update-available notice surfaced + cleared ----------------
test_sessionstart_update_notice() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  echo "PeKG plugin updated from 0.1.0 to 0.2.0 — restart your CLI." > "$TEST_HOME/.pekg/.update-notice"

  local out
  out=$(PEKG_OFFLINE=1 HOME="$TEST_HOME" bash "$DIST_CC/sessionstart.sh" <<<'{"session_id":"t2d"}' 2>/dev/null)
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
  assert_contains "A2d update notice surfaced in SessionStart additionalContext" "PeKG plugin updated" "$ctx"

  # Marker should be cleared.
  if [ ! -f "$TEST_HOME/.pekg/.update-notice" ]; then
    PASS=$((PASS + 1)); echo "  PASS  A2d update notice cleared after surfacing"
  else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("A2d update notice cleared after surfacing")
    echo "  FAIL  A2d marker file still present"
  fi
  rm -rf "$TEST_HOME"
}

# --- Test 21: A58 slash-command warning when blockers active -----------------
test_userpromptsubmit_slash_warning() {
  TEST_HOME=$(mktemp -d)
  STUB_DIR=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions"
  echo '{"token":"test"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{task:{},blockers:[{id:"a","title":"T","recommendation":"R",tier:"blocker"}],timestamp:0,expiresAt:9999999999}' \
    > "$TEST_HOME/.pekg/sessions/t58.json"

  cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
URL=""; OUT=""
while [ $# -gt 0 ]; do case "$1" in -o) OUT="$2"; shift 2 ;; -d|-X|--max-time|-H) shift 2 ;; -fsSL|-fsfL|-sS|-sf|-fsfL|-s|-f|-S|-L|--fail-with-body) shift ;; https://*|http://*) URL="$1"; shift ;; *) shift ;; esac; done
PAYLOAD='{"relevant":[]}'
if [ -n "$OUT" ]; then printf '%s' "$PAYLOAD" > "$OUT"; else printf '%s' "$PAYLOAD"; fi
STUB
  chmod +x "$STUB_DIR/curl"

  local out
  out=$(HOME="$TEST_HOME" PATH="$STUB_DIR:$PATH" bash "$DIST_CC/userpromptsubmit.sh" \
    <<<'{"session_id":"t58","prompt":"/clear","cwd":"/tmp","session":{"cwd":"/tmp"}}' 2>/dev/null)
  local ctx
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty')
  assert_contains "A58 slash warning fired for /clear with blockers" "WARNING: /clear" "$ctx"
  rm -rf "$TEST_HOME" "$STUB_DIR"
}

# --- Issue 8 port (markdown re-tier) ------------------------------------------
test_issue8_markdown_demote_in_blockers_lib() {
  # Pure-bash unit test on pekg_filter_blockers_for_file. Sources the lib
  # directly; no hook invocation needed.
  source "$ROOT/shared/lib/blockers.sh"

  printf "\n[Issue 8: pekg_filter_blockers_for_file]\n"

  # Code-domain blocker on markdown → demoted (filtered out)
  local blockers='[{"id":"a","title":"Async/await server route","tier":"blocker","summary":"avoid blocking event loop"}]'
  local result
  result=$(pekg_filter_blockers_for_file "$blockers" "docs/X.md")
  local count
  count=$(printf '%s' "$result" | jq 'length')
  assert_eq "Issue 8: code-domain blocker on .md → filtered out (canary)" "0" "$count"

  # Security carve-out keeps blocker on markdown
  blockers='[{"id":"a","title":"Don'\''t leak credentials","tier":"blocker","summary":"security scanning"}]'
  result=$(pekg_filter_blockers_for_file "$blockers" "README.md")
  count=$(printf '%s' "$result" | jq 'length')
  assert_eq "Issue 8: security blocker on .md → kept" "1" "$count"

  # Code-domain on .ts → kept (no markdown bypass)
  blockers='[{"id":"a","title":"Async/await server route","tier":"blocker","summary":""}]'
  result=$(pekg_filter_blockers_for_file "$blockers" "src/api.ts")
  count=$(printf '%s' "$result" | jq 'length')
  assert_eq "Issue 8: code-domain blocker on .ts → kept" "1" "$count"

  # Mixed list on markdown — keep only security
  blockers='[{"id":"a","title":"async route","tier":"blocker","summary":""},{"id":"b","title":"compliance audit","tier":"blocker","summary":""}]'
  result=$(pekg_filter_blockers_for_file "$blockers" "docs/X.md")
  count=$(printf '%s' "$result" | jq 'length')
  assert_eq "Issue 8: mixed list on .md → only non-code-domain survives" "1" "$count"

  # Bash cmd targeting markdown is detected
  if pekg_bash_cmd_targets_markdown "sed -i 's/x/y/' README.md"; then
    assert_eq "Issue 8: pekg_bash_cmd_targets_markdown(sed -i README.md)" "0" "0"
  else
    assert_eq "Issue 8: pekg_bash_cmd_targets_markdown(sed -i README.md)" "0" "1"
  fi

  # Bash cmd targeting .ts is NOT detected
  if pekg_bash_cmd_targets_markdown "sed -i 's/x/y/' src/server.ts"; then
    assert_eq "Issue 8: pekg_bash_cmd_targets_markdown(.ts) NOT match" "false" "true"
  else
    assert_eq "Issue 8: pekg_bash_cmd_targets_markdown(.ts) NOT match" "false" "false"
  fi
}

# --- Issue 8 end-to-end: pretooluse.sh respects markdown demote ---------------
test_issue8_pretooluse_markdown_skips_gate() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  touch "$TEST_HOME/.pekg/session-state/t108.status_called"
  # Code-domain blocker (mentions async/server/typescript). Should NOT
  # gate when editing a markdown file post-Issue 8.
  jq -n '{
    task: {},
    blockers: [{id:"abc",title:"Async server route gotcha",recommendation:"wrap in setTimeout",tier:"blocker",summary:"avoid blocking event loop"}],
    timestamp: 0,
    expiresAt: 9999999999
  }' > "$TEST_HOME/.pekg/sessions/t108.json"

  printf "\n[Issue 8 e2e: pretooluse.sh on markdown]\n"

  # Markdown edit → no deny
  local out
  out=$(run_hook "$DIST_CC/pretooluse.sh" '{"session_id":"t108","tool_name":"Edit","tool_input":{"file_path":"docs/STRATEGIC.md"}}')
  local decision
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  assert_eq "Issue 8 e2e: code-domain blocker on .md → no deny (canary)" "" "$decision"

  # .ts edit with same blocker → DOES deny (gate works on code files)
  out=$(run_hook "$DIST_CC/pretooluse.sh" '{"session_id":"t108","tool_name":"Edit","tool_input":{"file_path":"src/api.ts"}}')
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  assert_eq "Issue 8 e2e: same blocker on .ts → deny (no extension bypass)" "deny" "$decision"

  rm -rf "$TEST_HOME"
}

# --- Issue 8 e2e on Codex pretooluse ------------------------------------------
test_issue8_codex_pretooluse_markdown_skips_gate() {
  TEST_HOME=$(mktemp -d)
  mkdir -p "$TEST_HOME/.pekg/sessions" "$TEST_HOME/.pekg/session-state"
  echo '{"token":"test-token"}' > "$TEST_HOME/.pekg/config.json"
  jq -n '{
    task: {},
    blockers: [{id:"abc",title:"Async server route gotcha",recommendation:"wrap in setTimeout",tier:"blocker",summary:"avoid blocking event loop"}],
    timestamp: 0,
    expiresAt: 9999999999
  }' > "$TEST_HOME/.pekg/sessions/t208.json"

  printf "\n[Issue 8 e2e: Codex pretooluse on markdown]\n"

  # Codex Edit on markdown → no deny
  local out decision
  out=$(run_hook "$DIST_CX/pretooluse.sh" '{"session_id":"t208","tool_name":"Edit","tool_input":{"file_path":"docs/RFC.md"}}')
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  assert_eq "Issue 8 e2e (Codex): code-domain blocker on .md → no deny" "" "$decision"

  # Codex Edit on .ts with same blocker → deny
  out=$(run_hook "$DIST_CX/pretooluse.sh" '{"session_id":"t208","tool_name":"Edit","tool_input":{"file_path":"src/api.ts"}}')
  decision=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty')
  assert_eq "Issue 8 e2e (Codex): same blocker on .ts → deny" "deny" "$decision"

  rm -rf "$TEST_HOME"
}

# --- Plugin version sync canary -----------------------------------------------
test_plugin_version_sync() {
  # Asserts that PLUGIN_VERSION constant in opencode.ts == package.json
  # version. Drift here causes confusing user reports ("which version am I
  # running?") so make it a hard CI gate.
  printf "\n[Plugin version sync canary]\n"
  local code_ver pkg_ver
  code_ver=$(grep -E '^const PLUGIN_VERSION' "$ROOT/opencode/opencode.ts" | sed -E 's/.*"([^"]+)".*/\1/')
  pkg_ver=$(jq -r '.version' "$ROOT/opencode/package.json")
  assert_eq "opencode.ts PLUGIN_VERSION matches package.json version" "$code_ver" "$pkg_ver"
  # Also check the JSDoc header agrees.
  local header_ver
  header_ver=$(grep -E '^ \* PeKG OpenCode Plugin v' "$ROOT/opencode/opencode.ts" | sed -E 's/.* v([0-9.]+).*/\1/')
  assert_eq "opencode.ts JSDoc header version matches PLUGIN_VERSION" "$code_ver" "$header_ver"
}

# --- Run all ------------------------------------------------------------------
echo ""
echo "Running plugins smoke tests..."

test_sessionstart_no_token
test_sessionstart_offline_blocker
test_pretooluse_blocker_gate
test_pretooluse_dangerous_bash
test_pretooluse_no_blockers_allow
test_permissionrequest_blocker
test_precompact_structured_prompt
test_stop_kb_ingest
test_codex_sessionstart
test_codex_pretooluse_blocker
test_pretooluse_task_subagent_propagation
test_pretooluse_precap_writes_before_snapshot
test_stop_completed_steps
test_feedback_queue_offline
test_userpromptsubmit_always_blocker
test_byollm_cost_cap
test_posttooluse_failed_approach_extraction
test_feedback_cooldown_blocks_repeat
test_userpromptsubmit_resumed_session_block
test_sessionstart_update_notice
test_userpromptsubmit_slash_warning
test_issue8_markdown_demote_in_blockers_lib
test_issue8_pretooluse_markdown_skips_gate
test_issue8_codex_pretooluse_markdown_skips_gate
test_plugin_version_sync

echo ""
echo "results: $PASS pass, $FAIL fail"
if [ "$FAIL" -gt 0 ]; then
  printf 'failed:\n'
  for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
  exit 1
fi
