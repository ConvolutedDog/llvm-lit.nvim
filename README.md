# llvm-lit.nvim

**Run LLVM Lit tests from Neovim** and optionally debug the tool command with
`nvim-dap` — for any lit-based project (MLIR, CIRCT, LLVM, Flang, etc.).

Stop context-switching to a terminal. Open a `.mlir` / `.ll` / `.py` test file,
press `<leader>rt` to run it, or `<leader>rd` to run it *and* step through the
C++ tool (circt-opt, mlir-opt, flang-new, toyc-ch7, …) in nvim-dap — all inside
Neovim.

Per-project configurations (lit testsuite path, filter depth, working directory)
are persisted in `~/.config/llvm-lit.nvim/projects.json` and auto-detected from
your build tree.

## Features

| Action | Keymap | What happens |
|--------|--------|-------------|
| **Run (dump)** | `<leader>rt` | Runs `llvm-lit` with `FILECHECK_OPTS=--dump-input=always`, then **re-runs each tool standalone** (without FileCheck) so you see the raw IR output |
| **Run (normal)** | `<leader>rT` | Runs `llvm-lit` normally, shows output in a reusable `[llvm-lit]` buffer |
| **Debug** | `<leader>rd` | Runs lit, parses the executed commands from the output, lets you pick one, then launches **nvim-dap** on that binary |
| **Focus output** | `<leader>ro` | Jumps to the `[llvm-lit]` output buffer |

The output buffer is a regular listed buffer — navigate with `<S-h>`/`<S-l>` like
any file, or close with `<leader>bd`.

## Requirements

- Neovim >= 0.10
- `llvm-lit` on `PATH` or configured via `setup()`
- Project built so `lit.site.cfg.py` exists under the testsuite directory
- **Debugging only:** [nvim-dap](https://github.com/mfussenegger/nvim-dap) + `codelldb` (recommended) or `lldb`
- **Debugging only:** Build with debug symbols (`RelWithDebInfo` or `Debug`)

## Quick start

```lua
-- lazy.nvim
{
  'ConvolutedDog/llvm-lit.nvim',
  cmd = {
    'LlvmLitRun', 'LlvmLitRunDump', 'LlvmLitDebug', 'LlvmLitSetup',
    'LlvmLitProjects', 'LlvmLitConfig', 'LlvmLitHelp',
  },
  ft = { 'mlir', 'py', 'll', 'td', 'fir', 'sv' },
  opts = {},
  config = function(_, opts) require('llvm-lit').setup(opts) end,
}
```

Open a lit test file and run `:LlvmLitSetup` once per project. That's it.

## Debugging

`<leader>rd` / `:LlvmLitDebug` runs `llvm-lit` the same way as a normal test
run, parses the **expanded** tool commands from lit's verbose output
(`+ …` bash xtrace or `# executed command: …`), lets you pick a RUN line /
pipeline segment, then launches **nvim-dap** on that command (not on `llvm-lit`
itself). This works for any lit-based project — MLIR, CIRCT, LLVM, Flang, etc.

### 1. Install nvim-dap and codelldb

Add to your Neovim config:

```lua
{
  'mfussenegger/nvim-dap',
  dependencies = { 'rcarriga/nvim-dap-ui' },
  config = function()
    local dap = require('dap')
    local dapui = require('dapui')
    dapui.setup()
    dap.listeners.after.event_initialized['dapui_config'] = dapui.open
    dap.listeners.before.event_terminated['dapui_config'] = dapui.close
    dap.listeners.before.event_exited['dapui_config'] = dapui.close
  end,
}
```

Install `codelldb`:

```vim
:MasonInstall codelldb
```

The plugin resolves the binary from Mason's installation directory automatically.

### 2. Build with symbols

```bash
cmake -G Ninja llvm/llvm -B build \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DLLVM_ENABLE_ASSERTIONS=ON
ninja -C build           # builds everything
# or just:
ninja -C build bin/circt-opt   # circt / mlir project
```

### 3. Use

1. `:LlvmLitSetup` once for the project (if not done already).
2. Open a `.mlir` test, set breakpoints in **C++ source** (not the `.mlir` file).
   Prefer absolute paths:
   `:e /path/to/circt/tools/circt-opt/call.cpp` or `:e /path/to/mlir/tools/mlir-opt/...`
3. Press `<leader>rd` — lit runs, then pick the command to debug.
4. Use `<leader>dc` to continue, `<leader>dn` to step over, etc.

Suggested DAP keymaps:

```lua
vim.keymap.set('n', '<leader>dc', function() require('dap').continue() end, { desc = 'DAP continue' })
vim.keymap.set('n', '<leader>db', function() require('dap').toggle_breakpoint() end, { desc = 'DAP breakpoint' })
vim.keymap.set('n', '<leader>dn', function() require('dap').step_over() end, { desc = 'DAP step over' })
vim.keymap.set('n', '<leader>di', function() require('dap').step_into() end, { desc = 'DAP step into' })
```

### Docker / remote build paths

If breakpoints land in the wrong file, map the build tree to your checkout:

```lua
require('llvm-lit').setup({
  debug = {
    source_map = { ['/work/circt'] = '/Users/you/circt' },
  },
})
```

### Breakpoint syncing

codelldb's DAP `setBreakpoints` can fail on statically linked LLVM binaries
(because it can't resolve source files to binary locations). The plugin works
around this by sending raw LLDB commands through the DAP REPL every time you
press "continue" — so your nvim-dap breakpoints are synced to LLDB
automatically. Look for the notification:
```
[llvm-lit] synced N lldb breakpoint(s)
```

---

## Installation

### lazy.nvim (from GitHub)

```lua
{
  'ConvolutedDog/llvm-lit.nvim',
  cmd = {
    'LlvmLitRun', 'LlvmLitRunDump', 'LlvmLitDebug', 'LlvmLitSetup',
    'LlvmLitProjects', 'LlvmLitConfig', 'LlvmLitHelp',
  },
  ft = { 'mlir', 'py', 'll', 'td', 'fir', 'sv', 'lib', 'test', 'aag' },
  opts = {
    llvm_lit = '/path/to/build/bin/llvm-lit',  -- optional if on PATH
    keymaps = {
      run_dump     = '<leader>rt',
      run          = '<leader>rT',
      debug        = '<leader>rd',
      focus_output = '<leader>ro',
    },
  },
  config = function(_, opts)
    require('llvm-lit').setup(opts)
  end,
}
```

### lazy.nvim (local clone / development)

```lua
{
  dir = vim.fn.expand('~/path/to/llvm-lit.nvim'),
  name = 'llvm-lit.nvim',
  cmd = {
    'LlvmLitRun', 'LlvmLitRunDump', 'LlvmLitDebug', 'LlvmLitSetup',
    'LlvmLitProjects', 'LlvmLitConfig', 'LlvmLitHelp',
  },
  ft = { 'mlir', 'py', 'll', 'td', 'fir', 'sv', 'lib', 'test', 'aag' },
  opts = { llvm_lit = '/path/to/build/bin/llvm-lit' },
  config = function(_, opts) require('llvm-lit').setup(opts) end,
}
```

## First-time setup

1. Open a Lit test file (`.mlir`, `.ll`, `.py`, …)
2. Run `:LlvmLitSetup`
3. Confirm or edit the auto-detected values:

| Field | Auto-detection | Example |
|-------|---------------|---------|
| **Project root** | Upward search for `.git` | `/Users/you/circt` |
| **Lit testsuite** | Inferred from build tree | `/Users/you/circt/build/test` |
| **filter_depth** | Default: `2` (last N path segments → `--filter`) | `2` means `--filter Dialect/Arith` |
| **Working directory** | Same as project root | `/Users/you/circt` |

Config is saved to:
```
~/.config/llvm-lit.nvim/projects.json
```

## Commands

| Command | Action |
|---------|--------|
| `:LlvmLitRun` | Run lit (no dump) |
| `:LlvmLitRunDump` | Run lit with `FILECHECK_OPTS=--dump-input=always` + standalone output |
| `:LlvmLitDebug` | Run lit, pick expanded tool command, launch nvim-dap |
| `:LlvmLitSetup` | Configure / update current project |
| `:LlvmLitProjects` | Browse, edit, or delete saved projects |
| `:LlvmLitConfig` | Show path to `projects.json` |
| `:LlvmLitHelp` | Open this help |

## Standalone output mode (`<leader>rt`)

`<leader>rt` sets `FILECHECK_OPTS=--dump-input=always` before calling `llvm-lit`.
For projects that execute RUN commands via bash (e.g. CIRCT), FileCheck inherits
this variable and the full `Input was: <<< ... >>>` dump appears in the normal
lit output section.

**For MLIR / llvm-project this does not work** — LLVM's lit intentionally strips
`FILECHECK_OPTS` from the subprocess environment (see
[D65121](https://reviews.llvm.org/D65121) and
[6cecd3c](https://github.com/llvm/llvm-project/commit/6cecd3c)).
To work around this, the plugin automatically appends a **standalone output**
section at the bottom of the buffer after lit finishes. It parses the executed
commands from lit's verbose log, removes FileCheck from the pipeline, and
re-runs the remaining tool (e.g. `mlir-opt`, `circt-opt`, `flang-new`) directly
so you see the full IR output without FileCheck noise.

```
────────────────────────────────────────────────────────────────────────
  Standalone Output  1 / 2
  $ /path/to/mlir-opt /path/to/file.mlir --some-pass
  NOTE: FileCheck removed from the RUN pipeline; not all scenarios
        are covered. Refer to the full lit output above for details.
────────────────────────────────────────────────────────────────────────
<clean IR output here>
```

Multiple RUN lines each get their own section (`1 / N`, `2 / N`, …).

## Configuration

```lua
require('llvm-lit').setup({
  llvm_lit      = 'llvm-lit',           -- or absolute path
  lit_args      = '-a',                 -- -a: show output on PASS
  filecheck_opts = '--dump-input=always',
  filter_depth  = 2,                    -- last N path segments → --filter
  extensions    = { 'mlir', 'py', 'll', 'td', 'fir', 'sv', 'lib', 'test', 'aag' },
  keymaps = {
    run_dump     = '<leader>rt',
    run          = '<leader>rT',
    debug        = '<leader>rd',
    focus_output = '<leader>ro',
  },
  debug = {
    dap_type = nil,                    -- nil = auto-detect (codelldb > lldb)
    stop_on_entry = true,              -- stop at main() to set breakpoints
    breakpoint_mode = 'file',          -- 'file' = filename only, 'path' = full path
    initialize_timeout_sec = 120,      -- codelldb cold start timeout
    -- source_map = { ['/build/path'] = '/local/checkout' },
    highlights = {
      current_line  = { fg = '#1a1b26', bg = '#FFCC00', bold = true },
      stopped_sign  = '▶',
      stopped_sign_hl = 'LlvmLitDebugSign',
    },
  },
})
```

## Example `projects.json`

```json
{
  "projects": {
    "/Users/you/circt": {
      "cwd": "/Users/you/circt",
      "filter_depth": 2,
      "lit_testsuite": "/Users/you/circt/build/test",
      "name": "circt"
    },
    "/Users/you/llvm-project": {
      "cwd": "/Users/you/llvm-project",
      "filter_depth": 2,
      "lit_testsuite": "/Users/you/llvm-project/build/tools/mlir/test",
      "name": "mlir"
    }
  },
  "version": 1
}
```

## Common errors

| Message | Fix |
|---------|-----|
| `lit.site.cfg.py not found` | Run `ninja` / `cmake` first; fix path in `:LlvmLitSetup` |
| `Project not registered` | Run `:LlvmLitSetup` once per repo root |
| `llvm-lit not found` | Set `llvm_lit` to an absolute path in `setup()` |
| `nvim-dap is not installed` | Add `mfussenegger/nvim-dap` to your plugin list |
| `Breakpoints not hit` | Build with `RelWithDebInfo`; set breakpoints in **C++** (not `.mlir`); codelldb syncs via LLDB on continue |
| `no executed tool commands found` | Ensure `lit_args` includes `-a` or `-vv` |

## License

MIT — see [LICENSE](LICENSE).
