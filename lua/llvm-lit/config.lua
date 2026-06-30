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
    -- Run llvm-lit, then lldb the expanded tool command (requires nvim-dap).
    debug        = '<leader>rd',
    -- Jump to the output buffer without re-running (nil/'' = disabled).
    focus_output = '<leader>ro',
  },
  -- nvim-dap options for :LlvmLitDebug / <leader>rd
  debug = {
    -- nil = auto-detect (codelldb, then lldb). LazyVim/Mason users usually want codelldb.
    dap_type = nil,
    -- nvim-dap filetype for config lookup (mlir tests debug C++ tools).
    filetype = 'cpp',
    stop_on_entry = true,
    -- codelldb: match breakpoints by filename (works with :e lib/... relative paths).
    breakpoint_mode = 'file',
    -- codelldb / circt-opt cold start can exceed nvim-dap's 4s default.
    initialize_timeout_sec = 120,
    -- Only needed when debug-info paths differ from your checkout (Docker/remote builds).
    -- codelldb wants a map, not a list of pairs:
    -- source_map = { ['/work/circt'] = '/Users/you/circt' },
    -- nvim-dap current-line indicator (uses LlvmLitDebugLine, not theme's debugPC).
    highlights = {
      current_line = { fg = '#1a1b26', bg = '#FFCC00', bold = true },
      stopped_sign = '▶',
      stopped_sign_hl = 'LlvmLitDebugSign',
    },
  },
  -- Directory under $XDG_CONFIG_HOME (or ~/.config) for persisted projects.
  state_dir_name = 'llvm-lit.nvim',
  state_file = 'projects.json',
}

M.options = vim.deepcopy(M.defaults)

return M
