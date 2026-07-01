-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- lua/llvm-lit/init.lua — Plugin initialization and public API
-- =============================================================================
-- This is the MAIN entry point for the plugin. Users call:
--   require('llvm-lit').setup({ ... })
-- in their Neovim config (e.g., lazy.nvim's opts). It:
--
--   1. Merges user options into the config module (used by ALL submodules).
--   2. Sets up nvim-dap highlight groups and re-applies them on ColorScheme.
--   3. Creates an augroup "LlvmLit" that watches for lit test files being
--      opened (BufReadPost, BufNewFile) and attaches buffer-local keymaps.
--   4. Also sets keymaps on already-loaded buffers (in case setup() is called
--      after some files were already opened).
--
-- The public API surface delegates to three submodules:
--   • run  — M.run(), M.run_dump()
--   • debug — M.debug()
--   • ui   — M.setup_project(), M.manage_projects(), M.show_config_path()
-- =============================================================================

local config  = require('llvm-lit.config')
local debug   = require('llvm-lit.debug')
local project = require('llvm-lit.project')
local run     = require('llvm-lit.run')
local ui      = require('llvm-lit.ui')

local M = {}

-- ---------------------------------------------------------------------------
-- Top-level commands (called from user keymaps)
-- ---------------------------------------------------------------------------

--- Run lit on the current test file (no FILECHECK_OPTS dump).
-- @param opts: optional overrides (e.g., { bufnr = 42 })
function M.run(opts)
  run.run(vim.tbl_extend('force', {
    dump_input = false,
    on_needs_setup = function()
      if vim.fn.confirm(
            'Lit testsuite is not configured for this project. Set it up now?', '&Yes\n&No', 1) == 1 then
        ui.setup_project()
      end
    end,
  }, opts or {}))
end

--- Run lit with FILECHECK_OPTS dump-input enabled.
-- This is useful when a FileCheck test fails and you want to see the actual
-- input that FileCheck received.
function M.run_dump(opts)
  run.run(vim.tbl_extend('force', {
    dump_input = true,
    on_needs_setup = function()
      if vim.fn.confirm(
            'Lit testsuite is not configured for this project. Set it up now?', '&Yes\n&No', 1) == 1 then
        ui.setup_project()
      end
    end,
  }, opts or {}))
end

local function on_needs_setup()
  if vim.fn.confirm(
        'Lit testsuite is not configured for this project. Set it up now?', '&Yes\n&No', 1) == 1 then
    ui.setup_project()
  end
end

--- Run lit then let the user pick a command to debug in nvim-dap.
function M.debug(opts)
  debug.run(vim.tbl_extend('force', {
    on_needs_setup = on_needs_setup,
  }, opts or {}))
end

-- ---------------------------------------------------------------------------
-- Buffer-local keymap setup
-- ---------------------------------------------------------------------------

--- Check whether a buffer contains a lit test file (by extension).
local function buf_matches(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return project.is_lit_test_file(name)
end

--- Attach buffer-local keymaps to a lit test buffer.
-- The keymap LHS values come from config.options.keymaps.
-- Each keymap is set with { buffer = bufnr, silent = true } so it only
-- activates in lit test files.
local function set_buffer_keymaps(bufnr)
  local k = config.options.keymaps or {}
  local function map(lhs, fn, desc)
    if lhs and lhs ~= '' then
      vim.keymap.set('n', lhs, fn, { buffer = bufnr, silent = true, desc = desc })
    end
  end
  map(k.run, function() M.run({ bufnr = bufnr }) end, 'llvm-lit: run test')
  map(k.run_dump, function() M.run_dump({ bufnr = bufnr }) end,
    'llvm-lit: run test (FileCheck dump-input)')
  map(k.debug, function() M.debug({ bufnr = bufnr }) end,
    'llvm-lit: debug tool from lit output')
  map(k.focus_output, function() run.focus_output() end, 'llvm-lit: focus output buffer')
end

--- Build the autocmd pattern list from configured file extensions.
-- e.g., { '*.mlir', '*.py', '*.fir', ... }
local function ext_patterns()
  local pats = {}
  for _, e in ipairs(config.options.extensions or {}) do
    table.insert(pats, '*.' .. e)
  end
  return pats
end

-- ---------------------------------------------------------------------------
-- Plugin setup (the only thing the user calls)
-- ---------------------------------------------------------------------------

--- Initialize the plugin. Call from your Neovim config:
--   require('llvm-lit').setup({ ... })
--
-- @param opts: user config table (merged over M.defaults)
function M.setup(opts)
  -- Step 1: Merge user options into the shared config.options table.
  config.options = vim.tbl_deep_extend('force', vim.deepcopy(config.defaults), opts or {})

  -- Step 2: Create nvim-dap highlight groups for the debug stopped-line
  -- indicator. These survive :colorscheme changes via the ColorScheme autocmd.
  debug.setup_highlights(config.options.debug)

  local hl_group = vim.api.nvim_create_augroup('LlvmLitDapHl', { clear = true })
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = hl_group,
    callback = function()
      debug.setup_highlights(config.options.debug)
    end,
  })

  -- Step 3: Attach buffer-local keymaps to lit test files.
  local group = vim.api.nvim_create_augroup('LlvmLit', { clear = true })
  local patterns = ext_patterns()

  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group,
    pattern = patterns,
    callback = function(args)
      set_buffer_keymaps(args.buf)
    end,
  })

  -- Step 4: Also set keymaps on already-loaded buffers.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and buf_matches(buf) then
      set_buffer_keymaps(buf)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Re-exports for the command definitions in plugin/llvm-lit.lua
-- ---------------------------------------------------------------------------

M.setup_project    = ui.setup_project
M.manage_projects  = ui.manage_projects
M.show_config_path = ui.show_config_path

return M
