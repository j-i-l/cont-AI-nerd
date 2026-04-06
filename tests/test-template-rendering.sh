#!/usr/bin/env bash
# test-template-rendering.sh — unit tests for systemd template rendering
# =========================================================================
# Verifies that the .in templates render correctly using the shared
# functions from lib/render-template.sh.
#
# Usage:  bash tests/test-template-rendering.sh
#         (no root required, no external dependencies beyond bash + coreutils)
# =========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=../lib/render-template.sh
source "${REPO_ROOT}/lib/render-template.sh"

SYSTEMD_DIR="${REPO_ROOT}/systemd"
PASS=0
FAIL=0

# ── Helpers ──────────────────────────────────────────────────────────────

fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

# assert_no_unreplaced_placeholders <rendered_output> <test_name>
# Fails if any @@WORD@@ tokens remain in the output.
assert_no_unreplaced_placeholders() {
  local output="$1" name="$2"
  if echo "$output" | grep -qE '@@[A-Z_]+@@'; then
    local remaining
    remaining=$(echo "$output" | grep -oE '@@[A-Z_]+@@' | sort -u | tr '\n' ' ')
    fail "${name}: unreplaced placeholders remain: ${remaining}"
  else
    pass "${name}: no unreplaced placeholders"
  fi
}

# assert_no_directives_before_first_section <rendered_output> <test_name>
# Fails if any KEY=VALUE directives appear before the first [Section] header.
# This is the exact bug class we're guarding against — bare directives
# outside of an INI section make Quadlet silently reject the file.
assert_no_directives_before_first_section() {
  local output="$1" name="$2"
  local before_section
  # Extract everything before the first [Section] line
  before_section=$(echo "$output" | sed -n '1,/^\[/{ /^\[/!p }')

  # Check if any non-comment, non-blank lines look like directives (Key=Value)
  if echo "$before_section" | grep -qE '^[A-Za-z]+='; then
    local offending
    offending=$(echo "$before_section" | grep -E '^[A-Za-z]+=')
    fail "${name}: directive(s) before first [Section]: ${offending}"
  else
    pass "${name}: no directives before first section"
  fi
}

# assert_contains <rendered_output> <expected_substring> <test_name>
assert_contains() {
  local output="$1" expected="$2" name="$3"
  if echo "$output" | grep -qF "$expected"; then
    pass "${name}"
  else
    fail "${name}: expected to find '${expected}'"
  fi
}

# assert_line_count <rendered_output> <pattern> <expected_count> <test_name>
assert_line_count() {
  local output="$1" pattern="$2" expected="$3" name="$4"
  local actual
  actual=$(echo "$output" | grep -cF "$pattern" || true)
  if [[ "$actual" -eq "$expected" ]]; then
    pass "${name}"
  else
    fail "${name}: expected ${expected} lines matching '${pattern}', got ${actual}"
  fi
}

# ── Test: Container template — single project path ──────────────────────

echo ""
echo "=== Container template: single project path ==="

VOLUME_LINES_1=$(build_volume_lines \
  "/home/alice/Projects" \
  "/workspace/Projects")

RENDERED_1=$(render_container_unit \
  "${SYSTEMD_DIR}/cont-ai-nerd.container.in" \
  "/home/alice" \
  "/home/alice/.config/cont-ai-nerd" \
  "127.0.0.1" \
  "3000" \
  "$VOLUME_LINES_1")

assert_no_unreplaced_placeholders "$RENDERED_1" "single-path"
assert_no_directives_before_first_section "$RENDERED_1" "single-path"
assert_line_count "$RENDERED_1" "Volume=/home/alice/Projects:/workspace/Projects:rw,Z" 1 \
  "single-path: project volume present"
assert_contains "$RENDERED_1" "Volume=/home/alice/.config/cont-ai-nerd/opencode.json:/etc/cont-ai-nerd/opencode.json:ro" \
  "single-path: policy volume resolved"
assert_contains "$RENDERED_1" "Volume=/home/alice/.config/opencode:/home/agent/.config/opencode:ro" \
  "single-path: opencode config volume resolved"
assert_contains "$RENDERED_1" "Exec=serve --hostname 127.0.0.1 --port 3000" \
  "single-path: host/port resolved in Exec"

# ── Test: Container template — multiple project paths ────────────────────

echo ""
echo "=== Container template: multiple project paths ==="

VOLUME_LINES_3=$(build_volume_lines \
  "/home/bob/code/frontend
/home/bob/code/backend
/home/bob/code/shared" \
  "/workspace/frontend
/workspace/backend
/workspace/shared")

RENDERED_3=$(render_container_unit \
  "${SYSTEMD_DIR}/cont-ai-nerd.container.in" \
  "/home/bob" \
  "/home/bob/.config/cont-ai-nerd" \
  "0.0.0.0" \
  "8080" \
  "$VOLUME_LINES_3")

assert_no_unreplaced_placeholders "$RENDERED_3" "multi-path"
assert_no_directives_before_first_section "$RENDERED_3" "multi-path"
assert_line_count "$RENDERED_3" "Volume=/home/bob/code/" 3 \
  "multi-path: all 3 project volumes present"
assert_contains "$RENDERED_3" "Volume=/home/bob/code/frontend:/workspace/frontend:rw,Z" \
  "multi-path: frontend volume correct"
assert_contains "$RENDERED_3" "Volume=/home/bob/code/backend:/workspace/backend:rw,Z" \
  "multi-path: backend volume correct"
assert_contains "$RENDERED_3" "Volume=/home/bob/code/shared:/workspace/shared:rw,Z" \
  "multi-path: shared volume correct"
assert_contains "$RENDERED_3" "Exec=serve --hostname 0.0.0.0 --port 8080" \
  "multi-path: custom host/port resolved"

# ── Test: Container template — paths with spaces ────────────────────────

echo ""
echo "=== Container template: path with spaces ==="

VOLUME_LINES_SPACE=$(build_volume_lines \
  "/home/user/My Projects/app" \
  "/workspace/My Projects/app")

RENDERED_SPACE=$(render_container_unit \
  "${SYSTEMD_DIR}/cont-ai-nerd.container.in" \
  "/home/user" \
  "/home/user/.config/cont-ai-nerd" \
  "127.0.0.1" \
  "3000" \
  "$VOLUME_LINES_SPACE")

assert_no_unreplaced_placeholders "$RENDERED_SPACE" "spaces-in-path"
assert_no_directives_before_first_section "$RENDERED_SPACE" "spaces-in-path"
assert_contains "$RENDERED_SPACE" "Volume=/home/user/My Projects/app:/workspace/My Projects/app:rw,Z" \
  "spaces-in-path: volume line preserved spaces"

# ── Test: Watcher service template ──────────────────────────────────────

echo ""
echo "=== Watcher service template ==="

RENDERED_WATCHER=$(render_watcher_unit \
  "${SYSTEMD_DIR}/cont-ai-nerd-watcher.service.in" \
  "/opt/cont-ai-nerd" \
  "alice" \
  "agent" \
  "/home/alice/Projects /home/alice/Work")

assert_no_unreplaced_placeholders "$RENDERED_WATCHER" "watcher"
assert_no_directives_before_first_section "$RENDERED_WATCHER" "watcher"
assert_contains "$RENDERED_WATCHER" \
  "ExecStart=/opt/cont-ai-nerd/cont-ai-nerd-watcher.sh alice agent /home/alice/Projects /home/alice/Work" \
  "watcher: ExecStart fully resolved"

# ── Test: Commit service template ───────────────────────────────────────

echo ""
echo "=== Commit service template ==="

RENDERED_COMMIT=$(render_commit_service \
  "${SYSTEMD_DIR}/cont-ai-nerd-commit.service" \
  "/opt/cont-ai-nerd")

assert_no_unreplaced_placeholders "$RENDERED_COMMIT" "commit"
assert_no_directives_before_first_section "$RENDERED_COMMIT" "commit"
assert_contains "$RENDERED_COMMIT" \
  "ExecStart=/opt/cont-ai-nerd/cont-ai-nerd-commit.sh" \
  "commit: ExecStart resolved"

# ── Test: build_volume_lines helper ─────────────────────────────────────

echo ""
echo "=== build_volume_lines helper ==="

VL_RESULT=$(build_volume_lines \
  "/a/b
/c/d" \
  "/workspace/b
/workspace/d")

EXPECTED_VL="Volume=/a/b:/workspace/b:rw,Z
Volume=/c/d:/workspace/d:rw,Z"

if [[ "$VL_RESULT" == "$EXPECTED_VL" ]]; then
  pass "build_volume_lines: correct output for 2 paths"
else
  fail "build_volume_lines: unexpected output"
  echo "  Expected: $(echo "$EXPECTED_VL" | cat -A)"
  echo "  Got:      $(echo "$VL_RESULT" | cat -A)"
fi

# ── Summary ─────────────────────────────────────────────────────────────

echo ""
echo "========================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "========================================"

[[ $FAIL -eq 0 ]] || exit 1
