-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/utils.lua — Lightweight test helpers for headless Neovim testing.
--
-- Usage (from run_tests.sh):
--   nvim --headless -u NONE \
--     -c "set rtp+=<project_root>" \
--     -c "lua require('test.utils')" \
--     -c "lua require('test.test_commands')" \
--     -c "lua require('test.test_debug')" \
--     -c "qa!"
-- =============================================================================

local M = {}

-- Tracks test results.
local pass_count = 0
local fail_count = 0
local failures = {} -- list of { name, expected, actual }
local current_suite = nil

--- Start a named test suite (shown in output).
function M.suite(name)
  current_suite = name
  io.write('\n--- ' .. name .. ' ---\n')
end

--- Assert that a value is truthy.
-- @param ok:       the value to check
-- @param name:     description of the assertion
-- @param expected: (optional) string representation of expected
-- @param actual:   (optional) string representation of actual
function M.ok(ok, name, expected, actual)
  if ok then
    pass_count = pass_count + 1
    io.write('  ✓ ' .. name .. '\n')
  else
    fail_count = fail_count + 1
    local msg = name
    if expected then msg = msg .. '\n    expected: ' .. tostring(expected) end
    if actual   then msg = msg .. '\n    actual:   ' .. tostring(actual) end
    io.write('  ✗ ' .. msg .. '\n')
    table.insert(failures, { name = name, expected = expected, actual = actual })
  end
end

--- Deep-compare two values (handles tables recursively, nil, numbers, strings, booleans).
local function deep_eq(a, b)
  if type(a) ~= type(b) then
    return false
  end
  if type(a) == 'table' then
    local seen = {}
    for k, v in pairs(a) do
      seen[k] = true
      if not deep_eq(v, b[k]) then
        return false
      end
    end
    for k, _ in pairs(b) do
      if not seen[k] then
        return false
      end
    end
    return true
  end
  return a == b
end

--- Assert that two values are equal (deep comparison for tables).
-- @param a:    actual value
-- @param b:    expected value
-- @param name: description
function M.eq(a, b, name)
  M.ok(deep_eq(a, b), name, vim.inspect(b), vim.inspect(a))
end

--- Assert that a string matches a Lua pattern.
-- @param str:   the string to search in
-- @param pat:   the Lua pattern to search for
-- @param name:  description
function M.like(str, pat, name)
  M.ok(type(str) == 'string' and str:find(pat, 1, true) ~= nil,
    name,
    'pattern: ' .. pat,
    type(str) == 'string' and str or vim.inspect(str))
end

--- Print the final test summary and return the failure count.
-- @return number of failed assertions (for use as exit code)
function M.done()
  io.write(string.format(
    '\n=== %s: %d passed, %d failed ===\n',
    current_suite or '(all)',
    pass_count,
    fail_count
  ))
  return fail_count
end

return M
