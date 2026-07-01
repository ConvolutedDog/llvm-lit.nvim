-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- plugin/llvm-lit.lua — Neovim plugin entry point
-- =============================================================================
-- This file is loaded automatically by Neovim when the plugin is installed
-- (via the rtp or a plugin manager like LazyVim). Its job is to:
--
--   1. Guard against double-loading (the vim.g.loaded_llvm_lit check).
--   2. Register user commands (:LlvmLitRun, :LlvmLitDebug, etc.) that the
--      user can invoke from any lit test file.
--   3. Generate helptags so that :help llvm-lit works.
--
-- The actual keymaps (<leader>rd, <leader>rt, etc.) are NOT set here.
-- They are set in init.lua via a BufReadPost autocmd, so they only appear
-- when you're actually editing a lit test file (.mlir, .py, etc.).
-- =============================================================================

-- Guard: if this global is already set, the plugin was already loaded.
-- This prevents :source or lazy reload from re-registering all commands.
if vim.g.loaded_llvm_lit then
  return
end
vim.g.loaded_llvm_lit = true

-- Load the public API module. Everything the plugin does goes through this.
local function api()
  return require('llvm-lit')
end

-- Shorthand for nvim_create_user_command.
local cmd = vim.api.nvim_create_user_command

-- :LlvmLitRun        — run the current lit test normally
cmd('LlvmLitRun', function() api().run() end,
  { desc = 'llvm-lit: run current test file' })

-- :LlvmLitRunDump    — run with FILECHECK_OPTS=--dump-input=always
cmd('LlvmLitRunDump', function() api().run_dump() end,
  { desc = 'llvm-lit: run with FILECHECK_OPTS dump-input' })

-- :LlvmLitDebug      — run lit, then let you pick a command to debug in nvim-dap
cmd('LlvmLitDebug', function() api().debug() end,
  { desc = 'llvm-lit: run lit then debug expanded tool command' })

-- :LlvmLitSetup      — interactively configure lit testsuite for the current project
cmd('LlvmLitSetup', function() api().setup_project() end,
  { desc = 'llvm-lit: configure lit testsuite for current project' })

-- :LlvmLitProjects   — list / edit / delete saved project configurations
cmd('LlvmLitProjects', function() api().manage_projects() end,
  { desc = 'llvm-lit: list / edit / delete saved projects' })

-- :LlvmLitConfig     — show the path to projects.json (the state file)
cmd('LlvmLitConfig', function() api().show_config_path() end,
  { desc = 'llvm-lit: show path to projects.json' })

-- :LlvmLitHelp       — open the plugin help file
cmd('LlvmLitHelp', function()
  vim.cmd('help llvm-lit')
end, { desc = 'llvm-lit: open plugin help' })

-- Generate helptags so :help llvm-lit works.
-- debug.getinfo(1, 'S').source gives the path to THIS file (plugin/llvm-lit.lua),
-- so we go up two directories to find the doc/ folder.
local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h')
local doc = root .. '/doc'
if vim.fn.isdirectory(doc) == 1 then
  vim.cmd('silent! helptags ' .. vim.fn.fnameescape(doc))
end
