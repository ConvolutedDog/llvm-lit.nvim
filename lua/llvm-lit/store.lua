-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local config = require('llvm-lit.config')

local M = {}

local function state_dir()
  local base = os.getenv('XDG_CONFIG_HOME') or (vim.fn.expand('~') .. '/.config')
  return vim.fs.normalize(base .. '/' .. config.options.state_dir_name)
end

local function state_path()
  return state_dir() .. '/' .. config.options.state_file
end

local function empty_state()
  return {
    version = 1,
    projects = {},
  }
end

function M.path()
  return state_path()
end

function M.ensure_dir()
  local dir = state_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end
end

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
  local ok, decoded = pcall(vim.json.decode, table.concat(raw, '\n'))
  if not ok or type(decoded) ~= 'table' then
    return empty_state(), 'Failed to parse config JSON: ' .. path
  end
  decoded.projects = decoded.projects or {}
  decoded.version = decoded.version or 1
  return decoded
end

function M.save(state)
  M.ensure_dir()
  local path = state_path()
  local encoded = vim.json.encode(state, { indent = true })
  vim.fn.writefile(vim.split(encoded, '\n'), path)
end

--- Normalize project root keys for stable lookup.
function M.norm_root(root)
  return vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))
end

function M.get_project(state, root)
  root = M.norm_root(root)
  return state.projects[root], root
end

function M.set_project(state, root, project)
  root = M.norm_root(root)
  state.projects[root] = project
  M.save(state)
end

function M.delete_project(state, root)
  root = M.norm_root(root)
  state.projects[root] = nil
  M.save(state)
end

--- Longest matching registered project root containing filepath.
function M.find_project_for_file(state, filepath)
  filepath = vim.fs.normalize(vim.fn.fnamemodify(filepath, ':p'))
  local best_root, best_proj
  for root, proj in pairs(state.projects) do
    local norm = M.norm_root(root)
    if filepath:sub(1, #norm) == norm and (not best_root or #norm > #best_root) then
      best_root = norm
      best_proj = proj
    end
  end
  return best_proj, best_root
end

return M
