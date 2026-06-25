-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local config = require('llvm-lit.config')
local project = require('llvm-lit.project')
local run = require('llvm-lit.run')
local ui = require('llvm-lit.ui')

local M = {}

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

local function buf_matches(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return project.is_lit_test_file(name)
end

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
  map(k.focus_output, function() run.focus_output() end, 'llvm-lit: focus output buffer')
end

local function ext_patterns()
  local pats = {}
  for _, e in ipairs(config.options.extensions or {}) do
    table.insert(pats, '*.' .. e)
  end
  return pats
end

function M.setup(opts)
  config.options = vim.tbl_deep_extend('force', vim.deepcopy(config.defaults), opts or {})

  local group = vim.api.nvim_create_augroup('LlvmLit', { clear = true })
  local patterns = ext_patterns()

  vim.api.nvim_create_autocmd({ 'BufReadPost', 'BufNewFile' }, {
    group = group,
    pattern = patterns,
    callback = function(args)
      set_buffer_keymaps(args.buf)
    end,
  })

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and buf_matches(buf) then
      set_buffer_keymaps(buf)
    end
  end
end

M.setup_project = ui.setup_project
M.manage_projects = ui.manage_projects
M.show_config_path = ui.show_config_path

return M
