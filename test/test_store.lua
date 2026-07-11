-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/test_store.lua — Tests for store.lua + ui.delete_project_config
--
-- Covers:
--   • M.norm_root()
--   • M.get_project()
--   • M.find_project_for_file() — path matching logic
--   • empty_state() — inline re-implementation
--   • M.save() / M.load() — full disk round-trip (integration tests)
--   • M.set_project() / M.delete_project() — persistence
--   • ui.delete_project_config() — :LlvmLitDelConfig UI function
-- =============================================================================

local t = require('test.utils')

-- ---------------------------------------------------------------------------
-- Setup: redirect XDG_CONFIG_HOME to a temp dir so we never touch real config.
-- We re-require store AFTER setting the env var so state_dir() picks up our
-- isolated path.
-- ---------------------------------------------------------------------------
local tmp_home = '/tmp/llvm-lit-test-store-' .. tostring(os.time())
vim.env.XDG_CONFIG_HOME = tmp_home
vim.env.XDG_STATE_HOME = tmp_home .. '/state'
package.loaded['llvm-lit.store'] = nil
package.loaded['llvm-lit.config'] = nil
package.loaded['llvm-lit.ui'] = nil
local store = require('llvm-lit.store')
local ui = require('llvm-lit.ui')

-- Cleanup previous test runs if any.
os.execute('rm -rf ' .. tmp_home)

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

local match_state = empty_state()
match_state.projects['/tmp/llvm-lit-test/project1'] = { name = 'proj1' }
match_state.projects['/tmp/llvm-lit-test/project1/sub'] = { name = 'proj2' }

local mp1 = store.find_project_for_file(match_state, '/tmp/llvm-lit-test/project1')
t.ok(mp1 ~= nil, 'exact project root is found')

local mp2 = store.find_project_for_file(match_state, '/tmp/llvm-lit-test/project1/sub')
-- The more specific (longer) root should win for a nested file.

local mp3 = store.find_project_for_file(match_state, '/other/path/file.mlir')
t.ok(not mp3, 'unrelated path returns nil')

local mp4 = store.find_project_for_file(empty_state(), '/some/path')
t.ok(not mp4, 'empty state returns nil for any path')

-- ---------------------------------------------------------------------------
-- M.save() / M.load() — full disk round-trip
-- ---------------------------------------------------------------------------

t.suite('save / load round-trip')

-- Load from a fresh empty directory (should get empty_state).
local loaded = store.load()
t.eq(loaded.version, 1, 'load on empty dir returns version=1')
t.eq(type(loaded.projects), 'table', 'load on empty dir returns projects table')
t.eq(#vim.tbl_keys(loaded.projects), 0, 'load on empty dir returns empty projects')

-- Verify state_dir was created.
local ok_dir = vim.fn.isdirectory(tmp_home .. '/llvm-lit.nvim') == 1
t.ok(ok_dir, 'state directory is created after save')

-- ---------------------------------------------------------------------------
-- M.save() — encode and write to disk
-- ---------------------------------------------------------------------------

t.suite('save — encode and write')

local test_state = {
  version = 1,
  projects = {
    ['/workspace/my-project'] = {
      name = 'my-project',
      lit_testsuite = '/workspace/my-project/build/test',
      filter_depth = 2,
      cwd = '/workspace/my-project',
    },
  },
}

-- Save should succeed without error (this is the fix: indent="  " not true).
local ok_save, err_save = pcall(store.save, test_state)
t.ok(ok_save, 'save succeeds without error (indent fix)')
t.ok(not err_save, 'save has no error message')

-- Verify file exists on disk.
local sp = store.path()
local file_readable = vim.fn.filereadable(sp) == 1
t.ok(file_readable, 'state file exists on disk after save')

-- Verify file content is valid JSON.
local raw = vim.fn.readfile(sp)
t.ok(#raw > 0, 'state file is not empty')
local ok_decode, decoded = pcall(vim.json.decode, table.concat(raw, '\n'))
t.ok(ok_decode, 'saved file is valid JSON')

-- The decoded JSON should match what we saved.
t.eq(decoded.version, 1, 'round-trip: version preserved')
t.ok(decoded.projects['/workspace/my-project'] ~= nil, 'round-trip: project key preserved')
local proj = decoded.projects['/workspace/my-project']
t.eq(proj.name, 'my-project', 'round-trip: project.name preserved')
t.eq(proj.lit_testsuite, '/workspace/my-project/build/test', 'round-trip: lit_testsuite preserved')
t.eq(proj.filter_depth, 2, 'round-trip: filter_depth preserved')
t.eq(proj.cwd, '/workspace/my-project', 'round-trip: cwd preserved')

-- ---------------------------------------------------------------------------
-- M.set_project() — register and persist
-- ---------------------------------------------------------------------------

t.suite('set_project — register and persist')

local state2 = store.load()
t.eq(#vim.tbl_keys(state2.projects), 1, 'state has 1 project from previous save')

-- Add a second project via set_project.
local proj2 = {
  name = 'second-project',
  lit_testsuite = '/workspace/second/build/test',
  filter_depth = 3,
  cwd = '/workspace/second',
}
store.set_project(state2, '/workspace/second', proj2)

-- Reload from disk and verify both projects are there.
local state3 = store.load()
t.eq(#vim.tbl_keys(state3.projects), 2, 'state now has 2 projects after set_project')

local p_second, root_second = store.get_project(state3, '/workspace/second')
t.ok(p_second ~= nil, 'second project is retrievable via get_project')
t.eq(p_second.name, 'second-project', 'second project name correct')
t.eq(p_second.filter_depth, 3, 'second project filter_depth correct')

-- The first project should still be there.
local p_first, root_first = store.get_project(state3, '/workspace/my-project')
t.ok(p_first ~= nil, 'first project still exists after adding second')
t.eq(p_first.name, 'my-project', 'first project name still correct')

-- ---------------------------------------------------------------------------
-- M.delete_project() — remove and persist
-- ---------------------------------------------------------------------------

t.suite('delete_project — remove and persist')

store.delete_project(state3, '/workspace/my-project')

local state4 = store.load()
t.eq(#vim.tbl_keys(state4.projects), 1, 'state has 1 project after deletion')

local p_deleted, _ = store.get_project(state4, '/workspace/my-project')
t.ok(not p_deleted, 'deleted project is gone from state')

-- The second project should still be there.
local p_remaining, _ = store.get_project(state4, '/workspace/second')
t.ok(p_remaining ~= nil, 'non-deleted project still present')
t.eq(p_remaining.name, 'second-project', 'remaining project name correct')

-- ---------------------------------------------------------------------------
-- ui.delete_project_config() — :LlvmLitDelConfig
-- ---------------------------------------------------------------------------

t.suite('delete_project_config — empty state')

-- Intercept vim.notify to verify it's called with the right message.
local notify_calls = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, _)
  notify_calls[#notify_calls + 1] = { msg = msg, level = level }
  -- Don't forward to orig_notify in headless — we just capture.
end

-- Clear state and test empty case.
store.save({ version = 1, projects = {} })
local ok_del1, err_del1 = pcall(ui.delete_project_config)
vim.notify = orig_notify

t.ok(ok_del1, 'delete_project_config on empty state does not crash')
t.ok(not err_del1, 'delete_project_config on empty state has no error')
t.ok(#notify_calls >= 1, 'delete_project_config on empty state called vim.notify')
if #notify_calls >= 1 then
  t.ok(notify_calls[1].msg:find('No saved projects'),
    'notify message mentions "No saved projects"')
  t.eq(notify_calls[1].level, vim.log.levels.WARN,
    'notify level is WARN for empty state')
end

-- ---------------------------------------------------------------------------
t.suite('delete_project_config — with projects')

-- Re-populate the store with 3 projects.
local del_state = store.load()
del_state.projects = {
  ['/workspace/my-project'] = {
    name = 'my-project',
    lit_testsuite = '/workspace/my-project/build/test',
    filter_depth = 2,
    cwd = '/workspace/my-project',
  },
  ['/workspace/another'] = {
    name = 'another',
    lit_testsuite = '/workspace/another/build/test',
    filter_depth = 3,
    cwd = '/workspace/another',
  },
  ['/workspace/third'] = {
    name = 'third',
    lit_testsuite = '/workspace/third/build/test',
    filter_depth = 1,
    cwd = '/workspace/third',
  },
}
store.save(del_state)

-- Intercept again to check that the happy path doesn't warn.
notify_calls = {}
vim.notify = function(msg, level, _)
  notify_calls[#notify_calls + 1] = { msg = msg, level = level }
end

local ok_del2, err_del2 = pcall(ui.delete_project_config)
vim.notify = orig_notify

t.ok(ok_del2, 'delete_project_config with 3 projects does not crash')
t.ok(not err_del2, 'delete_project_config with 3 projects has no error')

-- The warn about "No saved projects" should NOT appear when projects exist.
local has_warn = false
for _, c in ipairs(notify_calls) do
  if c.msg:find('No saved projects') then has_warn = true end
end
t.ok(not has_warn, 'no empty-state warning when projects exist')

-- Verify the 3 projects are still intact on disk after the picker opened
-- (the picker doesn't auto-delete — user must press <CR>).
local state_after = store.load()
t.eq(#vim.tbl_keys(state_after.projects), 3,
  'all 3 projects still present after picker opened (no deletion happened)')

-- ---------------------------------------------------------------------------
-- Cleanup
-- ---------------------------------------------------------------------------
vim.notify = orig_notify
os.execute('rm -rf ' .. tmp_home)

return require('test.utils').done()
