-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/test_init.lua — Tests for init.lua
--
-- Covers:
--   • buf_matches() — inline re-implementation
--   • ext_patterns() — inline re-implementation
-- =============================================================================

local t = require('test.utils')

-- ---------------------------------------------------------------------------
-- buf_matches (private) — inline re-implementation
-- ---------------------------------------------------------------------------

local function buf_matches_inline(bufnr, extensions)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then
    return false
  end
  local ext = vim.fn.fnamemodify(name, ':e'):lower()
  for _, e in ipairs(extensions or {}) do
    if ext == e then
      return true
    end
  end
  return false
end

t.suite('buf_matches (private)')

local test_exts = { 'mlir', 'py', 'll' }

-- Create a buffer with a .mlir name
local buf_mlir = vim.api.nvim_create_buf(false, true)
pcall(vim.api.nvim_buf_set_name, buf_mlir, '/tmp/test.mlir')
t.ok(buf_matches_inline(buf_mlir, test_exts), 'buffer with .mlir name matches')

-- Buffer with .py name
local buf_py = vim.api.nvim_create_buf(false, true)
pcall(vim.api.nvim_buf_set_name, buf_py, '/tmp/script.py')
t.ok(buf_matches_inline(buf_py, test_exts), 'buffer with .py name matches')

-- Buffer with non-matching extension
local buf_cpp = vim.api.nvim_create_buf(false, true)
pcall(vim.api.nvim_buf_set_name, buf_cpp, '/tmp/main.cpp')
t.ok(not buf_matches_inline(buf_cpp, test_exts), '.cpp buffer does not match')

-- Buffer with no name (empty)
local buf_noname = vim.api.nvim_create_buf(false, true)
t.ok(not buf_matches_inline(buf_noname, test_exts), 'unnamed buffer returns false')

-- Empty extensions list
t.ok(not buf_matches_inline(buf_mlir, {}), 'empty extensions list returns false')

-- nil extensions list
t.ok(not buf_matches_inline(buf_mlir, nil), 'nil extensions list returns false')

-- Case: .MLIR case handling is tested in test_project.lua via M.is_lit_test_file()

-- Cleanup
pcall(vim.api.nvim_buf_delete, buf_mlir, { force = true })
pcall(vim.api.nvim_buf_delete, buf_py, { force = true })
pcall(vim.api.nvim_buf_delete, buf_cpp, { force = true })
pcall(vim.api.nvim_buf_delete, buf_noname, { force = true })
pcall(vim.api.nvim_buf_delete, buf_upper, { force = true })

-- ---------------------------------------------------------------------------
-- ext_patterns (private) — inline re-implementation
-- ---------------------------------------------------------------------------

t.suite('ext_patterns (private)')

local function ext_patterns_inline(extensions)
  local pats = {}
  for _, e in ipairs(extensions or {}) do
    table.insert(pats, '*.' .. e)
  end
  return pats
end

local pats = ext_patterns_inline({ 'mlir', 'py', 'll' })
t.eq(type(pats), 'table', 'returns a table')
t.eq(#pats, 3, '3 patterns for 3 extensions')
t.eq(pats[1], '*.mlir', 'first pattern is *.mlir')
t.eq(pats[2], '*.py', 'second pattern is *.py')
t.eq(pats[3], '*.ll', 'third pattern is *.ll')

-- Empty extensions
t.eq(#ext_patterns_inline({}), 0, 'empty extensions returns empty table')
t.eq(#ext_patterns_inline(nil), 0, 'nil extensions returns empty table')

return require('test.utils').done()
