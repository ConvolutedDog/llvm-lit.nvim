-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- lua/llvm-lit/config.lua — Plugin configuration and defaults
-- =============================================================================
-- This module defines ALL user-configurable options for llvm-lit.nvim.
-- The user calls require('llvm-lit').setup({ ... }) in their Neovim config
-- (e.g., lazy.nvim's opts), and any fields they pass are merged over the
-- defaults defined here.
--
-- Structure:
--   M.defaults  — the complete set of default options (read-only template)
--   M.options   — the live config table, initially a deep copy of M.defaults
--                 and then extended with user overrides when setup() is called
--                   from init.lua
--
-- Key options explained:
--   llvm_lit          — the path or name of the llvm-lit executable
--   lit_args          — CLI flags passed to lit (e.g. "-a" to show output on PASS)
--   filecheck_opts    — FILECHECK_OPTS when running with dump mode
--   filter_depth      — how many path segments to use for lit's --filter flag
--   extensions        — which file types get buffer-local keymaps
--   keymaps           — the <leader> key bindings for each action
--   debug             — nvim-dap options (adapter type, highlights, breakpoints)
--   state_dir_name    — directory name under ~/.config for persisted data
--   state_file        — JSON file that stores registered project configurations
-- =============================================================================

local M = {}

M.defaults = {
  -- ---------------------------------------------------------------
  -- llvm-lit executable and CLI arguments
  -- ---------------------------------------------------------------
  -- The binary name. If it contains a "/", it's treated as an absolute path;
  -- otherwise Neovim's $PATH is searched via vim.fn.executable().
  llvm_lit = 'llvm-lit',

  -- Flags appended to every "llvm-lit <dir> --filter <pattern>" invocation.
  -- "-a" is important: it makes lit print output even when tests pass, which
  -- is required for the debug feature to parse executed commands.
  lit_args = '-a',

  -- ---------------------------------------------------------------
  -- Dump mode options
  -- ---------------------------------------------------------------
  -- When running in dump mode (<leader>rt), this is set as FILECHECK_OPTS
  -- so FileCheck dumps its input, making it easier to diagnose failures.
  filecheck_opts = '--dump-input=always',

  -- ---------------------------------------------------------------
  -- Filtering
  -- ---------------------------------------------------------------
  -- lit's --filter flag matches against the last N segments of the test path.
  -- For example, with depth=2, a test at
  --   .../test/Dialect/Arith/ops.mlir
  -- becomes --filter "Arith/ops.mlir".
  filter_depth = 2,

  -- ---------------------------------------------------------------
  -- Recognized file extensions
  -- ---------------------------------------------------------------
  -- When you open a file with one of these extensions, the plugin sets up
  -- buffer-local keymaps for running lit commands.
  extensions = {
    'mlir', 'py', 'fir', 'sv', 'll', 'td', 'lib', 'test', 'aag',
  },

  -- ---------------------------------------------------------------
  -- Buffer-local keymaps
  -- ---------------------------------------------------------------
  -- Each entry is a LHS string (e.g. "<leader>rt") or an empty string/nil
  -- to disable that keymap. The <leader> key is whatever the user has
  -- configured (usually space or backslash).
  keymaps = {
    run_dump     = '<leader>rt',  -- run with FILECHECK_OPTS dump-input
    run          = '<leader>rT',  -- normal run without dump
    debug        = '<leader>rd',  -- run then debug in nvim-dap
    focus_output = '<leader>ro',  -- jump to lit output buffer
  },

  -- ---------------------------------------------------------------
  -- nvim-dap debug configuration
  -- ---------------------------------------------------------------
  -- These options control how the plugin launches the debugger when you
  -- pick a command from the lit output.
  debug = {
    -- Which DAP adapter to use. nil = auto-detect (codelldb > lldb).
    -- Set to "codelldb" to force codelldb (recommended for Mason users).
    dap_type = nil,

    -- The filetype passed to nvim-dap's configuration lookup. Since the
    -- plugin debugs C++ LLVM/MLIR tools, "cpp" is the right choice.
    filetype = 'cpp',

    -- If true, nvim-dap stops at the program entry point (main). This gives
    -- you a chance to set breakpoints before the program runs. If you set
    -- breakpoints beforehand, you can turn this off for a faster startup.
    stop_on_entry = true,

    -- How codelldb identifies source files when setting breakpoints.
    -- "file" = filename only (e.g. "ExportVerilog.cpp").
    -- "path" = full absolute path (needed if you have duplicate filenames).
    breakpoint_mode = 'file',

    -- Maximum time (seconds) to wait for codelldb to initialize.
    -- LLVM tools can be slow to load (cold start), especially large binaries
    -- like circt-opt or mlir-opt. The default of 120s should be enough even for debug
    -- builds.
    initialize_timeout_sec = 120,

    -- Source path mappings, for when debug info was built in a different
    -- directory (e.g. Docker / remote builds). codelldb expects a flat map:
    --   source_map = { ['/work/circt'] = '/Users/you/circt' }
    -- source_map = nil,  -- (commented out: nil means no mapping)

    -- Highlight groups for the debug stopped-line indicator.
    -- The default is a bright yellow background so it's visible on any theme.
    highlights = {
      current_line  = { fg = '#1a1b26', bg = '#FFCC00', bold = true },
      stopped_sign  = '▶',
      stopped_sign_hl = 'LlvmLitDebugSign',
    },
  },

  -- ---------------------------------------------------------------
  -- State persistence
  -- ---------------------------------------------------------------
  -- Project configurations are saved to a JSON file so they survive restarts.
  state_dir_name = 'llvm-lit.nvim',
  state_file     = 'projects.json',
}

-- The live options table. It starts as a deep copy of M.defaults, then
-- setup() in init.lua merges user-specified options on top.
M.options = vim.deepcopy(M.defaults)

return M
