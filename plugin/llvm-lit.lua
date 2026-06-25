-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

if vim.g.loaded_llvm_lit then
  return
end
vim.g.loaded_llvm_lit = true

local function api()
  return require('llvm-lit')
end

local cmd = vim.api.nvim_create_user_command

cmd('LlvmLitRun', function() api().run() end,
  { desc = 'llvm-lit: run current test file' })

cmd('LlvmLitRunDump', function() api().run_dump() end,
  { desc = 'llvm-lit: run with FILECHECK_OPTS dump-input' })

cmd('LlvmLitSetup', function() api().setup_project() end,
  { desc = 'llvm-lit: configure lit testsuite for current project' })

cmd('LlvmLitProjects', function() api().manage_projects() end,
  { desc = 'llvm-lit: list / edit / delete saved projects' })

cmd('LlvmLitConfig', function() api().show_config_path() end,
  { desc = 'llvm-lit: show path to projects.json' })

cmd('LlvmLitHelp', function()
  vim.cmd('help llvm-lit')
end, { desc = 'llvm-lit: open plugin help' })

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h:h')
local doc = root .. '/doc'
if vim.fn.isdirectory(doc) == 1 then
  vim.cmd('silent! helptags ' .. vim.fn.fnameescape(doc))
end
