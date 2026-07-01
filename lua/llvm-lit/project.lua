-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- lua/llvm-lit/project.lua — Project detection, resolution, and validation
-- =============================================================================
-- This module bridges the gap between a lit test file on disk and the
-- information needed to run lit against it. Given a buffer (e.g. a .mlir file),
-- it:
--
--   1. Checks if the file type is supported (is_lit_test_file).
--   2. Looks up the registered project configuration from store (find_project_for_file).
--   3. If no project is registered, tries to auto-detect one by walking up
--      the directory tree looking for lit.cfg.py / .git.
--   4. Validates the project config (lit.site.cfg.py must exist).
--   5. Builds the --filter string from the test file's path.
--   6. Returns a fully resolved "info" table that run.lua uses to construct
--      the shell command.
--
-- The auto-detection logic (detect_repo_root, suggest_lit_testsuite) is
-- designed to work out-of-the-box for standard LLVM/MLIR/CIRCT build trees
-- where the source test directory mirrors the build test directory:
--   source:   ~/circt/test/Dialect/Arith/ops.mlir
--   build:    ~/circt/build/test/Dialect/Arith/lit.site.cfg.py
-- =============================================================================

local config = require('llvm-lit.config')
local store = require('llvm-lit.store')

local M = {}

-- ---------------------------------------------------------------------------
-- Auto-detection helpers
-- ---------------------------------------------------------------------------

-- Walk upward from the file's directory to find the first lit.cfg.py.
-- This marks the root of a lit test suite in the source tree.
local function find_lit_cfg(filepath)
  return vim.fs.find('lit.cfg.py', {
    path = vim.fs.dirname(vim.fs.abspath(filepath)),
    upward = true,
    limit = 1,
  })[1]
end

-- Given the path to a lit.cfg.py, determine the repository root.
-- Prefer the git checkout root (parent of .git); if that fails, fall back
-- to the parent directory of the lit.cfg.py's parent (i.e., the test dir).
local function repo_root_from_lit_cfg(cfg)
  local test_dir = vim.fs.dirname(cfg)
  local git = vim.fs.find('.git', { path = test_dir, upward = true, limit = 1 })[1]
  if git then
    return vim.fs.dirname(git)
  end
  return vim.fs.dirname(test_dir)
end

-- Count how many trailing path segments two paths have in common.
-- Used to match a source test subtree to its build counterpart.
-- Example:
--   a = "test/Dialect/Arith", b = "build/test/Dialect/Arith"
--   common suffix = "Dialect/Arith" → score = 2
local function count_common_suffix(a_parts, b_parts)
  local n, i, j = 0, #a_parts, #b_parts
  while i >= 1 and j >= 1 and a_parts[i] == b_parts[j] do
    n = n + 1
    i = i - 1
    j = j - 1
  end
  return n
end

-- Among all lit.site.cfg.py files found under the build tree, pick the one
-- whose path best mirrors the source test directory (highest common suffix score).
local function best_build_testsuite(repo_root, test_dir)
  -- The standard build directory is <repo_root>/build.
  local build_root = vim.fs.normalize(repo_root .. '/build')
  if vim.fn.isdirectory(build_root) ~= 1 then
    return nil
  end

  -- Collect all lit.site.cfg.py files under the build tree.
  local sites = vim.fs.find('lit.site.cfg.py', { path = build_root, limit = 100 })
  if #sites == 0 then
    return nil
  end

  -- Compute the relative path from repo_root to the test directory.
  repo_root = vim.fs.normalize(repo_root)
  test_dir = vim.fs.normalize(test_dir)
  local rel = test_dir:sub(1, #repo_root) == repo_root and test_dir:sub(#repo_root + 2) or ''
  local rel_parts = rel ~= '' and vim.split(rel, '/') or {}

  -- Score each site by how many suffix segments match.
  local best, best_score = nil, -1
  for _, site in ipairs(sites) do
    local suite = vim.fs.dirname(site)
    local suite_rel = suite:sub(#build_root + 2)
    local score = count_common_suffix(rel_parts, vim.split(suite_rel, '/'))
    if score > best_score then
      best_score = score
      best = suite
    end
  end
  return best
end

-- ---------------------------------------------------------------------------
-- Public API: detection
-- ---------------------------------------------------------------------------

-- Walk upward from filepath and return a repository root (git root or
-- testsuite parent). Returns nil if no lit.cfg.py is found.
function M.detect_repo_root(filepath)
  local cfg = find_lit_cfg(filepath)
  if not cfg then
    return nil
  end
  return repo_root_from_lit_cfg(cfg)
end

-- Guess the build testsuite directory from a source test file's location.
-- Strategy:
--   1. If the source path mirrors a build path directly, use that.
--   2. Otherwise, score all lit.site.cfg.py files and pick the best match.
--   3. Fall back to <repo_root>/build/test.
function M.suggest_lit_testsuite(repo_root, filepath)
  repo_root = vim.fs.normalize(repo_root)
  local cfg = find_lit_cfg(filepath or repo_root)
  if not cfg then
    return vim.fs.normalize(repo_root .. '/build/test')
  end

  local test_dir = vim.fs.dirname(cfg)
  local rel = test_dir:sub(1, #repo_root) == repo_root and test_dir:sub(#repo_root + 2) or nil
  if rel and rel ~= '' then
    local mirrored = vim.fs.normalize(repo_root .. '/build/' .. rel)
    if vim.fn.filereadable(mirrored .. '/lit.site.cfg.py') == 1 then
      return mirrored
    end
  end

  local matched = best_build_testsuite(repo_root, test_dir)
  if matched then
    return matched
  end

  return vim.fs.normalize(repo_root .. '/build/test')
end

-- ---------------------------------------------------------------------------
-- Public API: file matching
-- ---------------------------------------------------------------------------

-- Return the list of recognized lit test file extensions (from config).
function M.lit_extensions()
  return config.options.extensions
end

-- Check whether a file path has a lit test extension.
-- This is used by init.lua's buf_matches() to decide which buffers get
-- keymaps.
function M.is_lit_test_file(filepath)
  if filepath == '' then
    return false
  end
  local ext = vim.fn.fnamemodify(filepath, ':e'):lower()
  for _, e in ipairs(M.lit_extensions()) do
    if ext == e then
      return true
    end
  end
  return false
end

-- ---------------------------------------------------------------------------
-- Public API: filter building
-- ---------------------------------------------------------------------------

-- Build the --filter value from the last `depth` segments of the test file
-- path. For example, with depth=2 and path ".../test/Dialect/Arith/ops.mlir",
-- the filter is "Arith/ops.mlir".
--
-- lit uses this filter to run only the matching tests within a test suite,
-- which is much faster than running the entire suite.
function M.make_filter(filepath, depth)
  depth = depth or config.options.filter_depth
  if depth < 1 then
    return nil, 'filter_depth must be >= 1'
  end
  local parts = vim.split(vim.fs.normalize(filepath), '/')
  if #parts < depth then
    return nil, string.format(
      'Not enough path segments: need %d, got %d (%s)',
      depth, #parts, filepath)
  end
  local segs = {}
  for i = #parts - depth + 1, #parts do
    table.insert(segs, parts[i])
  end
  return table.concat(segs, '/')
end

-- ---------------------------------------------------------------------------
-- Public API: validation
-- ---------------------------------------------------------------------------

-- Validate that a project configuration is usable:
--   • lit_testsuite must be set and non-empty.
--   • lit.site.cfg.py must exist in that directory (the build must be complete).
--   • cwd (if set) must be an existing directory.
--
-- Returns (true, suite_path) on success, or (false, error_message) on failure.
function M.validate_project(proj)
  if not proj or type(proj) ~= 'table' then
    return false, 'Project configuration is empty'
  end
  if not proj.lit_testsuite or proj.lit_testsuite == '' then
    return false, 'Lit testsuite path (lit_testsuite) is not configured'
  end
  local suite = vim.fs.normalize(proj.lit_testsuite)
  local site = suite .. '/lit.site.cfg.py'
  if vim.fn.filereadable(site) ~= 1 then
    return false, string.format(
      'Invalid lit testsuite: missing %s\n'
        .. 'Hint: run your build (ninja/cmake) so lit.site.cfg.py exists under the build tree',
      site)
  end
  local cwd = proj.cwd and vim.fs.normalize(proj.cwd) or nil
  if cwd and vim.fn.isdirectory(cwd) ~= 1 then
    return false, 'Working directory does not exist: ' .. cwd
  end
  return true, suite
end

-- ---------------------------------------------------------------------------
-- Public API: resolve (the main entry point for run.lua)
-- ---------------------------------------------------------------------------

-- Given a buffer number, resolve all the information needed to run lit:
--   1. Get the file path and check it's a supported test type.
--   2. Load the project state from disk.
--   3. Look up or auto-detect the project configuration.
--   4. Validate the configuration.
--   5. Build the --filter string.
--   6. Return the info table.
--
-- This is called by run.lua's M.run() every time the user triggers a lit run.
--
-- @param bufnr: buffer number (0 = current buffer)
-- @return:      (info_table, error_message) where info = {
--                 project, project_root, filepath, lit_testsuite,
--                 cwd, filter, filter_depth, state
--               }
function M.resolve(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    return nil, 'Current buffer has no file path (save the file first)'
  end
  if not M.is_lit_test_file(path) then
    return nil, string.format(
      'Unsupported file type: .%s\nSupported extensions: %s',
      vim.fn.fnamemodify(path, ':e'),
      table.concat(M.lit_extensions(), ', '))
  end

  -- Load saved project configurations.
  local state, load_err = store.load()
  if load_err then
    return nil, load_err
  end

  -- Look for a registered project that matches this file path.
  local proj, root = store.find_project_for_file(state, path)
  if not proj then
    -- No project registered — try to auto-detect the repo root.
    local detected = M.detect_repo_root(path)
    if detected then
      return nil, ('Project not registered: %s\nRun :LlvmLitSetup to configure the lit testsuite path'):format(detected), {
        repo_root = detected,
        state = state,
        filepath = path,
        needs_setup = true,
      }
    end
    return nil, 'Could not detect project root (no test/lit.cfg.py marker found upward)\nRun :LlvmLitSetup to configure manually'
  end

  -- Validate the project configuration.
  local ok, err_or_suite = M.validate_project(proj)
  if not ok then
    return nil, string.format('Project "%s" configuration error:\n%s\nRun :LlvmLitSetup to fix',
      proj.name or root, err_or_suite)
  end

  -- Build the --filter value.
  local depth = proj.filter_depth or config.options.filter_depth
  local filter, ferr = M.make_filter(path, depth)
  if not filter then
    return nil, ferr
  end

  -- Everything checks out — return the resolved info.
  return {
    project = proj,
    project_root = root,
    filepath = path,
    lit_testsuite = err_or_suite,
    cwd = proj.cwd and vim.fs.normalize(proj.cwd) or root,
    filter = filter,
    filter_depth = depth,
    state = state,
  }, nil
end

return M
