#!/usr/bin/env bash
# Build self-contained hook scripts from plugins/{claude-code,codex}/hooks/*.sh
# by expanding `# @inline <relative-path>` markers with the file's contents.
#
# Output: plugins/{claude-code,codex}/dist/*.sh — single-file shippable artefacts.
#
# Usage: bash plugins/build.sh
# Exit non-zero on any error.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
SHARED_DIR="$ROOT/shared/lib"

# Compute build version from git so admin UI's outdated-detection actually
# bumps when plugins change. MAJOR.MINOR are hand-controlled; PATCH = number
# of git commits that touch plugins/ on HEAD. So 0.1.0 (initial) → 0.1.42 etc.
# Falls back to a static label outside a git checkout (e.g. tarball install).
compute_version() {
  local major_minor="0.1"
  local count=""
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    count=$(git -C "$ROOT" rev-list --count HEAD -- "$ROOT" 2>/dev/null || echo "")
  fi
  if [ -z "$count" ]; then
    echo "${major_minor}.0"
  else
    echo "${major_minor}.${count}"
  fi
}

BUILD_VERSION="$(compute_version)"
echo "build: version=$BUILD_VERSION"

# expand_inlines <input-file>
# Reads input, replaces every `# @inline path/to/file.sh` line with the
# stripped contents of $ROOT/<path>. Strips shebang + leading comment block
# from inlined files so the output stays clean.
expand_inlines() {
  local in="$1"
  python3 - "$in" "$ROOT" <<'PY'
import sys, os, re
in_path, root = sys.argv[1], sys.argv[2]

def strip_inlined(text):
    lines = text.splitlines()
    # Drop shebang.
    if lines and lines[0].startswith("#!"):
        lines = lines[1:]
    # Drop leading blank lines.
    while lines and not lines[0].strip():
        lines = lines[1:]
    # Drop a leading top-of-file comment block (until first non-comment, non-blank).
    while lines and (lines[0].startswith("#") or not lines[0].strip()):
        lines = lines[1:]
    return "\n".join(lines)

with open(in_path) as f:
    src = f.read()

out = []
for line in src.splitlines():
    m = re.match(r"^\s*#\s*@inline\s+(\S+)\s*$", line)
    if not m:
        out.append(line)
        continue
    target = os.path.join(root, m.group(1))
    if not os.path.isfile(target):
        sys.stderr.write(f"build: missing inline target: {target}\n")
        sys.exit(2)
    with open(target) as f:
        out.append(f"# --- inlined from {m.group(1)} ---")
        out.append(strip_inlined(f.read()))
        out.append(f"# --- end inline ---")
print("\n".join(out))
PY
}

build_target() {
  local target="$1"  # claude-code or codex
  local src_dir="$ROOT/$target/hooks"
  local out_dir="$ROOT/$target/dist"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"

  shopt -s nullglob
  for src in "$src_dir"/*.sh; do
    local name
    name=$(basename "$src")
    local out="$out_dir/$name"
    local tmp="${out}.tmp.$$"
    # Atomic: write to tmp with exec bit, then rename. Concurrent invocations
    # of the dist file (e.g. another CC agent's PostToolUse) won't see a
    # mid-build window of "exists but not executable".
    expand_inlines "$src" > "$tmp"
    # Stamp the computed build version. Source files carry a placeholder
    # "0.1.0" — replace ALL occurrences (each hook declares the constant
    # itself plus reads it back later in the same dist file).
    # Use a delimiter that can't appear in a semver to keep sed safe.
    sed -i.bak "s|PEKG_PLUGIN_VERSION=\"0.1.0\"|PEKG_PLUGIN_VERSION=\"${BUILD_VERSION}\"|g" "$tmp"
    rm -f "${tmp}.bak"
    chmod +x "$tmp"
    if grep -qE '^\s*(#\s*@inline|source\s+.*shared/)' "$tmp"; then
      rm -f "$tmp"
      echo "build: $out still has unresolved imports" >&2
      exit 3
    fi
    if grep -q 'PEKG_PLUGIN_VERSION="0.1.0"' "$tmp"; then
      rm -f "$tmp"
      echo "build: $out failed to stamp version" >&2
      exit 4
    fi
    mv "$tmp" "$out"
    echo "build: $target/$name ($(wc -l < "$out" | tr -d ' ') lines)"
  done
}

build_target claude-code
build_target codex

# Drop a VERSION file alongside the dist directories so the gateway's
# /plugins/{target}.json manifest endpoint and the admin UI's outdated-
# detection both pick up the same value without a second compute path.
echo -n "$BUILD_VERSION" > "$ROOT/VERSION"

echo "build: done (version $BUILD_VERSION)"
