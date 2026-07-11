-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- lua/llvm-lit/ui.lua — Interactive UI helpers (setup wizard, project manager)
-- =============================================================================
-- This module provides the interactive user-facing commands:
--   • setup_project()  — :LlvmLitSetup wizard: walks the user through
--     configuring a lit testsuite for their project (name, suite path,
--     filter depth, working directory).
--   • manage_projects() — :LlvmLitProjects picker: lists all registered
--     projects and lets the user view details, edit, or delete them.
--   • show_config_path() — :LlvmLitConfig: display the path to projects.json.
--
-- The module uses a simple custom floating-window picker (open_picker) rather
-- than vim.ui.select, because it predates Neovim 0.10's vim.ui.select and
-- provides explicit j/k navigation with custom key actions (e, d, <CR>).
--
-- Data flow:
--   setup_project()
--     → reads current file path
--     → auto-detects repo root and testsuite (from project.lua)
--     → prompts user for each field (with defaults)
--     → validates the configuration (via project.validate_project)
--     → saves to store (via store.set_project)
-- =============================================================================

local config  = require('llvm-lit.config')
local project = require('llvm-lit.project')
local store   = require('llvm-lit.store')

local M = {}

-- ---------------------------------------------------------------------------
-- Notification / input helpers
-- ---------------------------------------------------------------------------

local function notify(msg, level)
  vim.notify('[llvm-lit] ' .. msg, level or vim.log.levels.INFO, { title = 'llvm-lit' })
end

--- Prompt the user for text input with a completion-enabled prompt.
-- Wraps vim.fn.input with pcall (safe against <C-c> cancellation).
-- Returns the trimmed string, or nil if cancelled.
local function input(prompt, default)
  default = default or ''
  local ok, result = pcall(vim.fn.input, {
    prompt = prompt,
    default = default,
    completion = 'file',
  })
  if not ok or not result or result == '' then
    return nil
  end
  return vim.trim(result)
end

--- Prompt for a yes/no confirmation.
local function confirm(msg)
  return vim.fn.confirm(msg, '&Yes\n&No', 2) == 1
end

-- ---------------------------------------------------------------------------
-- Simple floating-window picker
-- ---------------------------------------------------------------------------
-- A reusable helper that displays a list of items in a floating window with
-- j/k navigation and custom key bindings.
--
-- This is used by manage_projects() and (in debug.lua) by the command picker.
-- Why not vim.ui.select? This predates it and gives us full control over
-- keymaps (we need 'd' delete, 'e' edit, etc. per-item).
--
-- @param title:       window title string
-- @param items:       list of { label = string, ... }
-- @param keymaps_spec: table mapping key → function(item, close_fn)
-- @param opts:        optional { header = {line,...}, hint = string }
local function open_picker(title, items, keymaps_spec, opts)
  opts = opts or {}
  local header_lines = opts.header or {}
  local hint = opts.hint

  -- Build the display lines.
  local lines = {}
  -- Header (if any): separated by a dashed line.
  if #header_lines > 0 then
    for _, h in ipairs(header_lines) do
      table.insert(lines, '  ' .. h)
    end
    table.insert(lines, '  ' .. string.rep('─', 34))
  end
  -- Item lines: each gets a 2-space indent.
  for _, item in ipairs(items) do
    table.insert(lines, '  ' .. item.label)
  end
  table.insert(lines, '')
  table.insert(lines, '  ' .. (hint or 'q quit'))

  local header_count = #header_lines > 0 and (#header_lines + 1) or 0
  local first_item = header_count + 1

  -- Compute window dimensions from content.
  local max_w = 0
  for _, l in ipairs(lines) do
    if #l > max_w then max_w = #l end
  end
  max_w = math.min(max_w + 4, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)

  -- Create the scratch buffer.
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  -- Create the floating window, centered on screen.
  local win = vim.api.nvim_open_win(buf, true, {
    relative   = 'editor',
    row        = math.floor((vim.o.lines - height) / 2),
    col        = math.floor((vim.o.columns - max_w) / 2),
    width      = max_w,
    height     = height,
    border     = 'rounded',
    style      = 'minimal',
    title      = ' ' .. title .. ' ',
    title_pos  = 'center',
  })
  vim.wo[win].cursorline = true
  vim.api.nvim_win_set_cursor(win, { first_item, 0 })

  -- Dim the header lines.
  if header_count > 0 then
    for i = 1, header_count do
      vim.api.nvim_buf_add_highlight(buf, -1, 'Comment', i - 1, 0, -1)
    end
  end

  -- Close the picker window.
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  -- Get the item at the current cursor position (account for header offset).
  local function cur_item()
    if not vim.api.nvim_win_is_valid(win) then return nil end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local idx = row - header_count
    if idx < 1 or idx > #items then return nil end
    return items[idx]
  end

  -- Move cursor by delta (clamped to item bounds, skipping header/footer).
  local function move(delta)
    if not vim.api.nvim_win_is_valid(win) then return end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local new = math.max(first_item, math.min(first_item + #items - 1, row + delta))
    vim.api.nvim_win_set_cursor(win, { new, 0 })
  end

  -- Navigation keymaps.
  local o = { buffer = buf, nowait = true }
  vim.keymap.set('n', 'j',      function() move(1) end,  o)
  vim.keymap.set('n', 'k',      function() move(-1) end, o)
  vim.keymap.set('n', '<Down>', function() move(1) end,  o)
  vim.keymap.set('n', '<Up>',   function() move(-1) end, o)
  vim.keymap.set('n', 'q',     close, o)
  vim.keymap.set('n', '<Esc>', close, o)

  -- Custom action keymaps (from keymaps_spec).
  for key, fn in pairs(keymaps_spec) do
    local k = key
    vim.keymap.set('n', k, function()
      local item = cur_item()
      if item then fn(item, close) end
    end, o)
  end

  -- Auto-close when focus leaves (user clicks another window, etc.).
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer   = buf,
    once     = true,
    callback = vim.schedule_wrap(close),
  })
end

-- ---------------------------------------------------------------------------
-- :LlvmLitSetup — Interactive project configuration wizard
-- ---------------------------------------------------------------------------

--- Walk the user through setting up a new lit testsuite project.
-- This is invoked automatically when `run()` detects an unregistered project,
-- or manually via :LlvmLitSetup.
--
-- The wizard prompts for:
--   1. Project root (auto-detected or manual)
--   2. Project name (derived from directory name)
--   3. Lit testsuite path (auto-suggested via project.suggest_lit_testsuite)
--   4. Filter depth (number of path segments for --filter)
--   5. Working directory (cwd for the lit command)
--
-- Each field defaults to the existing configuration if re-editing.
-- Configuration is validated before saving.
function M.setup_project(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or 0
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    notify('Please save the file first', vim.log.levels.ERROR)
    return
  end

  -- Repository root: auto-detect or prompt.
  local repo_root = opts.repo_root or project.detect_repo_root(path)
  if not repo_root then
    repo_root = input('Project root: ', vim.fs.dirname(path))
  end
  if not repo_root then
    notify('Cancelled', vim.log.levels.WARN)
    return
  end
  repo_root = store.norm_root(repo_root)

  local state    = store.load()
  local existing = state.projects[repo_root]

  -- Project name.
  local default_name = existing and existing.name or vim.fn.fnamemodify(repo_root, ':t')
  local name = input('Project name: ', default_name)
  if not name then notify('Cancelled', vim.log.levels.WARN); return end

  -- Lit testsuite path (where lit.site.cfg.py lives).
  local default_suite = existing and existing.lit_testsuite
    or project.suggest_lit_testsuite(repo_root, path)
  local suite = input('Lit testsuite path (directory containing lit.site.cfg.py): ', default_suite)
  if not suite then notify('Cancelled', vim.log.levels.WARN); return end
  suite = vim.fs.normalize(vim.fn.fnamemodify(suite, ':p'))

  -- Filter depth.
  local default_depth = tostring((existing and existing.filter_depth) or config.options.filter_depth)
  local depth_str = input('Filter path segments (last N levels): ', default_depth)
  if not depth_str then notify('Cancelled', vim.log.levels.WARN); return end
  local depth = tonumber(depth_str)
  if not depth or depth < 1 then
    notify('filter_depth must be a positive integer', vim.log.levels.ERROR)
    return
  end

  -- Working directory.
  local default_cwd = existing and existing.cwd or repo_root
  local cwd = input('Working directory (cd): ', default_cwd)
  if not cwd then notify('Cancelled', vim.log.levels.WARN); return end
  cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ':p'))

  local proj = { name = name, lit_testsuite = suite, filter_depth = depth, cwd = cwd }

  -- Validate before saving.
  local ok, err = project.validate_project(proj)
  if not ok then
    notify('Configuration validation failed:\n' .. err, vim.log.levels.ERROR)
    if not confirm('Save this configuration anyway?') then return end
  end

  store.set_project(state, repo_root, proj)
  notify(string.format('Saved project "%s"\n  root: %s\n  testsuite: %s\n  config: %s',
    name, repo_root, suite, store.path()))
end

-- ---------------------------------------------------------------------------
-- :LlvmLitProjects — List / view / edit / delete projects
-- ---------------------------------------------------------------------------

--- Display a picker with all registered projects.
-- Each entry shows name, filter depth, and testsuite path.
-- Actions:
--   <CR> — show full project details
--   e    — edit this project (re-runs setup_project with defaults)
--   d    — delete this project (with confirmation)
--   q    — close
function M.manage_projects()
  local state = store.load()
  local roots = vim.tbl_keys(state.projects)
  table.sort(roots)

  if #roots == 0 then
    notify('No saved projects yet; open a test file and run :LlvmLitSetup', vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, root in ipairs(roots) do
    local p = state.projects[root]
    local depth = p.filter_depth or config.options.filter_depth
    items[#items + 1] = {
      label   = string.format('%-16s  depth=%-2s  %s',
        p.name or vim.fn.fnamemodify(root, ':t'), depth, p.lit_testsuite or ''),
      root    = root,
      project = p,
    }
  end

  open_picker('Projects', items, {
    ['<CR>'] = function(item, _)
      local p = item.project
      notify(string.format(
        'root: %s\ntestsuite: %s\ncwd: %s\nfilter_depth: %s\nconfig: %s',
        item.root, p.lit_testsuite,
        p.cwd or item.root,
        p.filter_depth or config.options.filter_depth,
        store.path()))
    end,
    e = function(item, close)
      close()
      vim.schedule(function() M.setup_project({ repo_root = item.root }) end)
    end,
    d = function(item, close)
      local p = item.project
      if confirm(string.format('Delete project "%s"?\n%s', p.name or '', item.root)) then
        store.delete_project(state, item.root)
        notify('Deleted: ' .. item.root)
        close()
        vim.schedule(function() M.manage_projects() end)
      end
    end,
  }, { hint = 'Enter show info · e edit · d delete · q close' })
end

-- ---------------------------------------------------------------------------
-- :LlvmLitDelConfig — Quick project deletion
-- ---------------------------------------------------------------------------

--- Display a picker listing all registered project roots.
-- Press <CR> on a project to delete it (with confirmation).
-- Falls back to ":LlvmLitProjects" style management if needed.
function M.delete_project_config()
  local state = store.load()
  local roots = vim.tbl_keys(state.projects)
  table.sort(roots)

  if #roots == 0 then
    notify('No saved projects to delete; open a test file and run :LlvmLitSetup', vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, root in ipairs(roots) do
    local p = state.projects[root]
    local depth = p.filter_depth or config.options.filter_depth
    items[#items + 1] = {
      label   = string.format('%-16s  depth=%-2s  %s',
        p.name or vim.fn.fnamemodify(root, ':t'), depth, p.lit_testsuite or ''),
      root    = root,
      project = p,
    }
  end

  open_picker('Delete Project', items, {
    ['<CR>'] = function(item, close)
      local p = item.project
      local root = item.root
      if confirm(string.format('Delete project "%s"?\nroot: %s', p.name or '', root)) then
        store.delete_project(state, root)
        notify('Deleted: ' .. root)
        close()
      end
    end,
  }, {
    header = {
      string.format('%-16s  %-5s  %s', 'Project Name', 'Depth', 'Lit Testsuite Path'),
    },
    hint = 'Enter delete · q cancel',
  })
end

-- ---------------------------------------------------------------------------
-- :LlvmLitConfig — Show state file path
-- ---------------------------------------------------------------------------

function M.show_config_path()
  notify('Config file: ' .. store.path())
end

return M
