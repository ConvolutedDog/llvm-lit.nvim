-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local config  = require('llvm-lit.config')
local project = require('llvm-lit.project')
local store   = require('llvm-lit.store')

local M = {}

local function notify(msg, level)
  vim.notify('[llvm-lit] ' .. msg, level or vim.log.levels.INFO, { title = 'llvm-lit' })
end

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

local function confirm(msg)
  return vim.fn.confirm(msg, '&Yes\n&No', 2) == 1
end

-- ---------------------------------------------------------------------------
-- Simple floating-window picker (no vim.ui.select, pure j/k navigation)
-- ---------------------------------------------------------------------------
local function open_picker(title, items, keymaps_spec, hint)
  -- items: list of { label = string, ... arbitrary fields ... }
  -- keymaps_spec: { key = function(item, close_fn) }
  -- hint: optional string shown at the bottom

  local lines = {}
  for _, item in ipairs(items) do
    table.insert(lines, '  ' .. item.label)
  end
  table.insert(lines, '')
  table.insert(lines, '  ' .. (hint or 'q quit'))

  local max_w = 0
  for _, l in ipairs(lines) do
    if #l > max_w then max_w = #l end
  end
  max_w = math.min(max_w + 4, vim.o.columns - 4)
  local height = math.min(#lines, vim.o.lines - 6)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

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
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local function close()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function cur_item()
    if not vim.api.nvim_win_is_valid(win) then return nil end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    return items[row]
  end

  local function move(delta)
    if not vim.api.nvim_win_is_valid(win) then return end
    local row = vim.api.nvim_win_get_cursor(win)[1]
    local new = math.max(1, math.min(#items, row + delta))
    vim.api.nvim_win_set_cursor(win, { new, 0 })
  end

  local o = { buffer = buf, nowait = true }
  vim.keymap.set('n', 'j',      function() move(1) end,  o)
  vim.keymap.set('n', 'k',      function() move(-1) end, o)
  vim.keymap.set('n', '<Down>', function() move(1) end,  o)
  vim.keymap.set('n', '<Up>',   function() move(-1) end, o)
  vim.keymap.set('n', 'q',     close, o)
  vim.keymap.set('n', '<Esc>', close, o)

  for key, fn in pairs(keymaps_spec) do
    local k = key  -- capture
    vim.keymap.set('n', k, function()
      local item = cur_item()
      if item then fn(item, close) end
    end, o)
  end

  -- Close when focus leaves the picker.
  vim.api.nvim_create_autocmd('BufLeave', {
    buffer   = buf,
    once     = true,
    callback = vim.schedule_wrap(close),
  })
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.setup_project(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or 0
  local path  = vim.api.nvim_buf_get_name(bufnr)
  if path == '' then
    notify('Please save the file first', vim.log.levels.ERROR)
    return
  end

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

  local default_name = existing and existing.name or vim.fn.fnamemodify(repo_root, ':t')
  local name = input('Project name: ', default_name)
  if not name then notify('Cancelled', vim.log.levels.WARN); return end

  local default_suite = existing and existing.lit_testsuite
    or project.suggest_lit_testsuite(repo_root, path)
  local suite = input('Lit testsuite path (directory containing lit.site.cfg.py): ', default_suite)
  if not suite then notify('Cancelled', vim.log.levels.WARN); return end
  suite = vim.fs.normalize(vim.fn.fnamemodify(suite, ':p'))

  local default_depth = tostring((existing and existing.filter_depth) or config.options.filter_depth)
  local depth_str = input('Filter path segments (last N levels): ', default_depth)
  if not depth_str then notify('Cancelled', vim.log.levels.WARN); return end
  local depth = tonumber(depth_str)
  if not depth or depth < 1 then
    notify('filter_depth must be a positive integer', vim.log.levels.ERROR)
    return
  end

  local default_cwd = existing and existing.cwd or repo_root
  local cwd = input('Working directory (cd): ', default_cwd)
  if not cwd then notify('Cancelled', vim.log.levels.WARN); return end
  cwd = vim.fs.normalize(vim.fn.fnamemodify(cwd, ':p'))

  local proj = { name = name, lit_testsuite = suite, filter_depth = depth, cwd = cwd }

  local ok, err = project.validate_project(proj)
  if not ok then
    notify('Configuration validation failed:\n' .. err, vim.log.levels.ERROR)
    if not confirm('Save this configuration anyway?') then return end
  end

  store.set_project(state, repo_root, proj)
  notify(string.format('Saved project "%s"\n  root: %s\n  testsuite: %s\n  config: %s',
    name, repo_root, suite, store.path()))
end

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
  }, 'Enter show info · e edit · d delete · q close')
end

function M.show_config_path()
  notify('Config file: ' .. store.path())
end

return M
