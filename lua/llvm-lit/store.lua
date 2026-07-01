-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- lua/llvm-lit/store.lua — Persistent state (projects.json)
-- =============================================================================
-- This module manages loading and saving project configurations to a JSON
-- file on disk. Each "project" is a lit testsuite configuration (lit_suite path,
-- working directory, filter depth, etc.) that the user registers via
-- :LlvmLitSetup.
--
-- The state is stored at:
--   $XDG_CONFIG_HOME/llvm-lit.nvim/projects.json
-- or (if XDG_CONFIG_HOME is unset):
--   ~/.config/llvm-lit.nvim/projects.json
--
-- Data flow:
--   user runs :LlvmLitSetup  →  ui.lua collects info  →  store.set_project()
--   →  state table updated in memory AND written to disk (M.save)
--   next Neovim restart    →  store.load() reads from disk
--   project.resolve()      →  store.find_project_for_file() matches filepath
-- =============================================================================

local config = require('llvm-lit.config')

local M = {}

-- ---------------------------------------------------------------------------
-- Path helpers
-- ---------------------------------------------------------------------------

-- Compute the state directory path.
-- Follows the XDG Base Directory Specification: use XDG_CONFIG_HOME if set,
-- otherwise fall back to ~/.config.
local function state_dir()
  local base = os.getenv('XDG_CONFIG_HOME') or (vim.fn.expand('~') .. '/.config')
  return vim.fs.normalize(base .. '/' .. config.options.state_dir_name)
end

-- Compute the full path to the JSON state file.
local function state_path()
  return state_dir() .. '/' .. config.options.state_file
end

-- Return an empty state table (used when the file doesn't exist yet or is
-- corrupted).
local function empty_state()
  return {
    version = 1,
    projects = {},
  }
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Return the path to the state file (for :LlvmLitConfig / diagnostic output).
function M.path()
  return state_path()
end

-- Ensure the state directory exists (create it if necessary).
-- Called before every read or write so we don't crash on a missing directory.
function M.ensure_dir()
  local dir = state_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
end

-- Load the state from disk. Returns the decoded table.
-- If the file doesn't exist or is malformed JSON, returns an empty state
-- (no crash).
function M.load()
  M.ensure_dir()
  local path = state_path()
  if vim.fn.filereadable(path) ~= 1 then
    return empty_state()
  end
  local raw = vim.fn.readfile(path)
  if #raw == 0 then
    return empty_state()
  end
  -- vim.json.decode can throw on invalid JSON — wrap in pcall.
  local ok, decoded = pcall(vim.json.decode, table.concat(raw, '\n'))
  if not ok or type(decoded) ~= 'table' then
    return empty_state(), 'Failed to parse config JSON: ' .. path
  end
  decoded.projects = decoded.projects or {}
  decoded.version = decoded.version or 1
  return decoded
end

-- Save a state table to disk (writes pretty-printed JSON).
function M.save(state)
  M.ensure_dir()
  local path = state_path()
  local encoded = vim.json.encode(state, { indent = true })
  vim.fn.writefile(vim.split(encoded, '\n'), path)
end

-- Normalize a project root path for use as a dictionary key.
-- We use vim.fs.normalize + fnamemodify to resolve symlinks and trailing
-- slashes, so the same directory always maps to the same key.
function M.norm_root(root)
  return vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))
end

-- Look up a project by its root directory. Returns (project_table, normalized_root).
function M.get_project(state, root)
  root = M.norm_root(root)
  return state.projects[root], root
end

-- Register or update a project and persist to disk.
function M.set_project(state, root, project)
  root = M.norm_root(root)
  state.projects[root] = project
  M.save(state)
end

-- Delete a project and persist to disk.
function M.delete_project(state, root)
  root = M.norm_root(root)
  state.projects[root] = nil
  M.save(state)
end

-- Find the registered project whose root is the longest common prefix of a
-- given file path. This allows project roots that are parent directories of
-- the actual test files (e.g. root = ~/circt, file = ~/circt/test/Dialect/...).
--
-- @param state:    the loaded state table
-- @param filepath: absolute path to a test file
-- @return:         (project_table, root_path) or nil
function M.find_project_for_file(state, filepath)
  filepath = vim.fs.normalize(vim.fn.fnamemodify(filepath, ':p'))
  local best_root, best_proj
  for root, proj in pairs(state.projects) do
    local norm = M.norm_root(root)
    -- Check if filepath starts with norm (i.e., the file is inside this project).
    -- We pick the longest matching root (most specific).
    if filepath:sub(1, #norm) == norm and (not best_root or #norm > #best_root) then
      best_root = norm
      best_proj = proj
    end
  end
  return best_proj, best_root
end

return M
