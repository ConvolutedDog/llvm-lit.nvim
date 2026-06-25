-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local M = {}

M.defaults = {
  -- llvm-lit executable (must be on PATH or an absolute path).
  llvm_lit = 'llvm-lit',
  -- Lit CLI flags appended before the testsuite path (-a shows output on PASS).
  lit_args = '-a',
  -- Passed via FILECHECK_OPTS when running with dump enabled.
  filecheck_opts = '--dump-input=always',
  -- Default filter depth when a project has no per-project override.
  filter_depth = 2,
  -- File extensions that get buffer-local keymaps.
  extensions = {
    'mlir', 'py', 'fir', 'sv', 'll', 'td', 'lib', 'test', 'aag',
  },
  keymaps = {
    -- Full output (FILECHECK_OPTS=--dump-input=always) — most common usage.
    run_dump     = '<leader>rt',
    -- Normal run without dump.
    run          = '<leader>rT',
    -- Jump to the output buffer without re-running (nil/'' = disabled).
    focus_output = '<leader>ro',
  },
  -- Directory under $XDG_CONFIG_HOME (or ~/.config) for persisted projects.
  state_dir_name = 'llvm-lit.nvim',
  state_file = 'projects.json',
}

M.options = vim.deepcopy(M.defaults)

return M
