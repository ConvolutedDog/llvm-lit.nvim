-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local config = require('llvm-lit.config')
local store = require('llvm-lit.store')

local M = {}

local function find_lit_cfg(filepath)
  return vim.fs.find('lit.cfg.py', {
    path = vim.fs.dirname(vim.fs.abspath(filepath)),
    upward = true,
    limit = 1,
  })[1]
end

--- Prefer the git checkout root; otherwise parent of the source testsuite dir.
local function repo_root_from_lit_cfg(cfg)
  local test_dir = vim.fs.dirname(cfg)
  local git = vim.fs.find('.git', { path = test_dir, upward = true, limit = 1 })[1]
  if git then
    return vim.fs.dirname(git)
  end
  return vim.fs.dirname(test_dir)
end

local function count_common_suffix(a_parts, b_parts)
  local n, i, j = 0, #a_parts, #b_parts
  while i >= 1 and j >= 1 and a_parts[i] == b_parts[j] do
    n = n + 1
    i = i - 1
    j = j - 1
  end
  return n
end

--- Pick the build testsuite whose path best mirrors the source testsuite tree.
local function best_build_testsuite(repo_root, test_dir)
  local build_root = vim.fs.normalize(repo_root .. '/build')
  if vim.fn.isdirectory(build_root) ~= 1 then
    return nil
  end

  local sites = vim.fs.find('lit.site.cfg.py', { path = build_root, limit = 100 })
  if #sites == 0 then
    return nil
  end

  repo_root = vim.fs.normalize(repo_root)
  test_dir = vim.fs.normalize(test_dir)
  local rel = test_dir:sub(1, #repo_root) == repo_root and test_dir:sub(#repo_root + 2) or ''
  local rel_parts = rel ~= '' and vim.split(rel, '/') or {}

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

--- Walk upward from filepath and return a repository root (git root or testsuite parent).
function M.detect_repo_root(filepath)
  local cfg = find_lit_cfg(filepath)
  if not cfg then
    return nil
  end
  return repo_root_from_lit_cfg(cfg)
end

--- Guess build testsuite dir from source test tree location.
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

function M.lit_extensions()
  return config.options.extensions
end

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

--- Build --filter value from the last `depth` path segments.
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

  local state, load_err = store.load()
  if load_err then
    return nil, load_err
  end

  local proj, root = store.find_project_for_file(state, path)
  if not proj then
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

  local ok, err_or_suite = M.validate_project(proj)
  if not ok then
    return nil, string.format('Project "%s" configuration error:\n%s\nRun :LlvmLitSetup to fix',
      proj.name or root, err_or_suite)
  end

  local depth = proj.filter_depth or config.options.filter_depth
  local filter, ferr = M.make_filter(path, depth)
  if not filter then
    return nil, ferr
  end

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
