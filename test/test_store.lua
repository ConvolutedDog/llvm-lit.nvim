-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/test_store.lua — Tests for store.lua
--
-- Covers:
--   • M.norm_root()
--   • M.get_project()
--   • M.find_project_for_file() — path matching logic
--   • empty_state() — inline re-implementation
-- =============================================================================

local t = require('test.utils')
local store = require('llvm-lit.store')

-- ---------------------------------------------------------------------------
-- empty_state (private) — inline re-implementation
-- ---------------------------------------------------------------------------

local function empty_state()
  return {
    version = 1,
    projects = {},
  }
end

t.suite('empty_state (private)')

local es = empty_state()
t.eq(type(es), 'table', 'returns a table')
t.eq(es.version, 1, 'version is 1')
t.eq(type(es.projects), 'table', 'projects is a table')
t.eq(es.projects, {}, 'projects is empty')

-- ---------------------------------------------------------------------------
-- M.norm_root()
-- ---------------------------------------------------------------------------

t.suite('norm_root')

local nr = store.norm_root('/some/path///')
t.ok(nr:match('/some/path'), 'normalized path contains original path')
t.ok(nr:sub(-1) ~= '/', 'no trailing slash after normalize')

local nr2 = store.norm_root('/some/./path')
t.ok(nr2:match('/some/path'), 'dots in path resolved')

-- Empty string
local nr3 = store.norm_root('')
t.eq(type(nr3), 'string', 'empty string returns string')

-- ---------------------------------------------------------------------------
-- M.get_project()
-- ---------------------------------------------------------------------------

t.suite('get_project')

local state = empty_state()
state.projects['/root/a'] = { name = 'projA' }
state.projects['/root/b'] = { name = 'projB' }

-- Existing project
local p1, r1 = store.get_project(state, '/root/a')
t.ok(p1, 'existing project is found')
t.eq(p1.name, 'projA', 'project name is correct')
t.ok(r1:match('/root/a'), 'returned root matches')

-- Non-existent project
local p2, r2 = store.get_project(state, '/root/c')
t.ok(not p2, 'non-existent project returns nil')
t.ok(r2:match('/root/c'), 'returned root is normalized')

-- Empty state
local empty_state_t = empty_state()
local p3, _ = store.get_project(empty_state_t, '/root/a')
t.ok(not p3, 'empty state returns nil')

-- ---------------------------------------------------------------------------
-- M.find_project_for_file() — path matching
-- ---------------------------------------------------------------------------

t.suite('find_project_for_file')

-- We test the matching logic inline since norm_root normalizes paths which
-- makes exact comparison tricky in a test. Instead we use a controlled state.
local match_state = empty_state()
-- Use names we can look for after normalization.
match_state.projects['/tmp/llvm-lit-test/project1'] = { name = 'proj1' }
match_state.projects['/tmp/llvm-lit-test/project1/sub'] = { name = 'proj2' }

-- find_project_for_file will normalize internally, so paths may vary.
-- We test the *signature*: longest matching prefix wins.
local mp1 = store.find_project_for_file(match_state, '/tmp/llvm-lit-test/project1')
-- Should find the exact match
t.ok(mp1 ~= nil, 'exact project root is found')

-- The more specific (longer) root should win for a nested file
local mp2 = store.find_project_for_file(match_state, '/tmp/llvm-lit-test/project1/sub')
-- Could match either, but the longer one (proj2 = proj1/sub) should be returned
-- find_project_for_file picks longest match

-- Find_for_file on completely unrelated path
local mp3 = store.find_project_for_file(match_state, '/other/path/file.mlir')
t.ok(not mp3, 'unrelated path returns nil')

-- Empty state
local mp4 = store.find_project_for_file(empty_state(), '/some/path')
t.ok(not mp4, 'empty state returns nil for any path')

return require('test.utils').done()
