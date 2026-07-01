-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/test_project.lua — Tests for project.lua
--
-- Covers:
--   • count_common_suffix (private, inline)
--   • M.lit_extensions()
--   • M.is_lit_test_file()
--   • M.make_filter()
--   • M.validate_project()
-- =============================================================================

local t = require('test.utils')
local project = require('llvm-lit.project')

-- ---------------------------------------------------------------------------
-- count_common_suffix (private helper) — inline re-implementation
-- ---------------------------------------------------------------------------

local function count_common_suffix(a_parts, b_parts)
  local n, i, j = 0, #a_parts, #b_parts
  while i >= 1 and j >= 1 and a_parts[i] == b_parts[j] do
    n = n + 1
    i = i - 1
    j = j - 1
  end
  return n
end

t.suite('count_common_suffix')

t.eq(count_common_suffix({ 'a', 'b', 'c' }, { 'x', 'b', 'c' }), 2,
  'two matching trailing segments')
t.eq(count_common_suffix({ 'a', 'b', 'c' }, { 'x', 'y', 'z' }), 0,
  'no matching segments')
t.eq(count_common_suffix({}, {}), 0, 'both empty')
t.eq(count_common_suffix({ 'a' }, {}), 0, 'one empty, one not')
t.eq(count_common_suffix({ 'a', 'b' }, { 'a', 'b' }), 2, 'exact match')
t.eq(count_common_suffix(
  { 'test', 'Dialect', 'Arith' },
  { 'build', 'test', 'Dialect', 'Arith' }
), 3, 'common suffix with extra prefix in b')
t.eq(count_common_suffix(
  { 'build', 'test', 'Dialect' },
  { 'test', 'Dialect', 'Arith' }
), 0, 'partial overlap — "Dialect" is not at the same end position')
t.eq(count_common_suffix(
  { 'test', 'dialect', 'arith' },
  { 'test', 'Dialect', 'Arith' }
), 0, 'case sensitive — no position-end parity, and case differs')
t.eq(count_common_suffix({ 'a' }, { 'a', 'b', 'c' }), 0, 'single common segment but at different end positions')

-- ---------------------------------------------------------------------------
-- M.lit_extensions()
-- ---------------------------------------------------------------------------

t.suite('lit_extensions')

local exts = project.lit_extensions()
t.ok(type(exts) == 'table', 'returns a table')
t.ok(#exts > 0, 'has at least one extension')
t.ok(vim.tbl_contains(exts, 'mlir'), 'contains .mlir')
t.ok(vim.tbl_contains(exts, 'll'), 'contains .ll')
t.ok(vim.tbl_contains(exts, 'py'), 'contains .py')

-- ---------------------------------------------------------------------------
-- M.is_lit_test_file()
-- ---------------------------------------------------------------------------

t.suite('is_lit_test_file')

t.ok(not project.is_lit_test_file(''), 'empty string returns false')
t.ok(project.is_lit_test_file('/path/to/test.mlir'), '.mlir is a lit test')
t.ok(project.is_lit_test_file('/path/to/test.ll'), '.ll is a lit test')
t.ok(project.is_lit_test_file('/path/to/test.py'), '.py is a lit test')
t.ok(project.is_lit_test_file('C:\\Users\\test.mlir'), '.mlir with Windows path')
t.ok(not project.is_lit_test_file('/path/to/test.cpp'), '.cpp is NOT a lit test')
t.ok(not project.is_lit_test_file('/path/to/test.h'), '.h is NOT a lit test')
t.ok(not project.is_lit_test_file('/path/to/test.txt'), '.txt is NOT a lit test')
t.ok(not project.is_lit_test_file('/path/to/test'), 'no extension is NOT a lit test')
-- Case sensitivity: .MLIR should match (fnamemodify lowercases)
t.ok(project.is_lit_test_file('/path/to/test.MLIR'), '.MLIR (uppercase) is a lit test')

-- ---------------------------------------------------------------------------
-- M.make_filter()
-- ---------------------------------------------------------------------------

t.suite('make_filter')

local filter1 = project.make_filter('/home/user/project/test/Dialect/Arith/ops.mlir', 2)
t.ok(filter1, 'filter is produced')
t.eq(filter1, 'Arith/ops.mlir', 'last 2 segments: Arith/ops.mlir')

local filter2 = project.make_filter('/home/user/project/test/Dialect/Arith/ops.mlir', 3)
t.eq(filter2, 'Dialect/Arith/ops.mlir', 'last 3 segments')

local filter3 = project.make_filter('/home/user/project/test/Dialect/Arith/ops.mlir', 1)
t.eq(filter3, 'ops.mlir', 'last 1 segment')

-- Error: depth < 1
local f4, err4 = project.make_filter('/path/to/file.mlir', 0)
t.ok(not f4, 'depth=0 returns nil')
t.like(err4, 'filter_depth', 'depth=0 error mentions filter_depth')

-- Error: not enough segments
local f5, err5 = project.make_filter('/path/to/file.mlir', 10)
t.ok(not f5, 'depth > segment count returns nil')
t.like(err5, 'Not enough', 'error mentions Not enough segments')

-- Default depth (from config, should be 2)
local f6 = project.make_filter('/path/a/b/c/d/file.mlir')
t.eq(f6, 'd/file.mlir', 'default depth (=2)')

-- Empty path
local f7, err7 = project.make_filter('', 2)
t.ok(not f7, 'empty path with depth=2 returns nil')

-- ---------------------------------------------------------------------------
-- M.validate_project()
-- ---------------------------------------------------------------------------

t.suite('validate_project')

-- nil / empty
local ok1, _ = project.validate_project(nil)
t.ok(not ok1, 'nil returns false')

local ok2, _ = project.validate_project({})
t.ok(not ok2, 'empty table returns false')

-- Missing lit_testsuite
local ok3, _ = project.validate_project({ name = 'test' })
t.ok(not ok3, 'missing lit_testsuite returns false')

-- lit_testsuite with non-existent directory (lit.site.cfg.py won't exist)
local ok4, _ = project.validate_project({
  name = 'test',
  lit_testsuite = '/nonexistent/path/to/suite',
})
t.ok(not ok4, 'non-existent testsuite path returns false')

-- Valid suite path with lit.site.cfg.py — we can't easily test this without
-- creating temp files, so we verify the validation logic structure.
local ok5, msg5 = project.validate_project({
  name = 'test',
  lit_testsuite = '/tmp',
})
-- /tmp does not contain lit.site.cfg.py, so should fail.
t.ok(not ok5, '/tmp without lit.site.cfg.py fails')

-- lit_testsuite is empty string
local ok6, _ = project.validate_project({ name = 'test', lit_testsuite = '' })
t.ok(not ok6, 'empty lit_testsuite string fails')

return require('test.utils').done()
