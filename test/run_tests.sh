#!/usr/bin/env bash
# =============================================================================
# test/run_tests.sh — Run all llvm-lit.nvim tests headlessly.
#
# Usage:
#   bash test/run_tests.sh              # run all tests (exit 0 if all pass)
#   bash test/run_tests.sh -v           # verbose: show test names as they run
#
# Requires:
#   nvim (Neovim >= 0.9) on PATH
# =============================================================================
set -euo pipefail

# Resolve the script's absolute directory first.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Guard: verify we're pointing at the real project root.
if ! [ -f "$ROOT/lua/llvm-lit/init.lua" ]; then
  echo "ERROR: cannot find the project root."
  echo "  Expected lua/llvm-lit/init.lua under: $ROOT"
  echo ""
  echo "  Please run this script from the project root directory:"
  echo "    bash test/run_tests.sh"
  exit 1
fi

if [ "$(pwd)" != "$ROOT" ]; then
  echo "This script must be run from the project root directory."
  echo "  Current: $(pwd)"
  echo "  Expected: $ROOT"
  echo ""
  echo "  cd \"$ROOT\" && bash test/run_tests.sh"
  exit 1
fi

# We run each test file as a separate Neovim invocation so a crash in one
# doesn't mask failures in another. Each returns 0 on success, 1 on failure.

# Determine which tests to run.
TESTS=()
if [ $# -ge 1 ] && [ "${1#-}" != "$1" ]; then
  # Flags only — run all.
  shift
  TESTS=("$@")
fi

if [ ${#TESTS[@]} -eq 0 ]; then
  for f in "$ROOT"/test/test_*.lua; do
    TESTS+=("$f")
  done
fi

fail_count=0
total_passed=0
total_failed=0

for test_file in "${TESTS[@]}"; do
  test_name="$(basename "$test_file" .lua)"
  printf '\n━━━ %s ━━━\n' "$test_name"

  # Run in headless mode: load nothing except rtp + our test infra.
  # The test file itself calls require('test.utils').done() which returns
  # the failure count.
  result=$(nvim --headless -u NONE \
    -c "set rtp+=$ROOT" \
    -c "lua require('test.utils')" \
    -c "lua local f = dofile('$test_file'); if f and f > 0 then vim.cmd('cquit 1') end" \
    -c "qa!" 2>&1 || true)

  # Print the test output (the assertions).
  echo "$result"

  # Determine pass/fail.
  passed=$(echo "$result" | grep -c '✓' || true)
  failed=$(echo "$result" | grep -c '✗' || true)
  total_passed=$((total_passed + passed))
  total_failed=$((total_failed + failed))

  if echo "$result" | grep -qE 'Error detected|E[0-9]+:' \
    && ! echo "$result" | grep -qE 'E886:' \
    && ! echo "$result" | grep -qF 'nvim-dap is not installed'; then
    # Real Neovim Lua error (ignore benign errors):
    #   - E886: sandbox ShaDa write denied
    #   - nvim-dap not installed: expected failure in test_debug
    printf '  ⚠ Lua error detected in %s\n' "$test_name"
    fail_count=$((fail_count + 1))
  elif [ "$failed" -gt 0 ]; then
    printf '  ⚠ Lua error detected in %s\n' "$test_name"
    fail_count=$((fail_count + 1))
  fi
done

printf '\n═══════════════════════════════════════\n'
printf '  Total:  %d passed, %d failed\n' "$total_passed" "$total_failed"
printf '═══════════════════════════════════════\n'

if [ "$fail_count" -gt 0 ]; then
  echo "Test failures detected. Please check the output above."
  exit 1
fi

echo "All tests passed."
exit 0
