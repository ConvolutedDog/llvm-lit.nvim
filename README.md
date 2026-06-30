# llvm-lit.nvim

Run `llvm-lit` on the current Lit test file from Neovim, with **per-project**
configuration stored under `~/.config/llvm-lit.nvim/`.

Inspired by [mlir-inc-previewer.nvim](../mlir-inc-previewer.nvim).

## Features

- `<leader>rt` — run with `FILECHECK_OPTS=--dump-input=always` + **standalone output** (see below)
- `<leader>rT` — run without dump
- `<leader>rd` — run lit, then **debug** the expanded tool command with nvim-dap (see [Debugging](#debugging))
- `<leader>ro` — jump to output buffer
- Output shown in a regular listed buffer (`[llvm-lit]`); navigate with `<S-h>`/`<S-l>` like any file
- Per-project **lit testsuite** path and **filter depth** configuration
- Project root auto-detected from `.git`; testsuite path inferred from the build tree
- First-time **interactive setup** (`:LlvmLitSetup`)
- **Manage / delete** projects (`:LlvmLitProjects`) with `j`/`k` navigation
- Clear error messages when config or paths are wrong

## Requirements

- Neovim >= 0.10
- `llvm-lit` on `PATH` or configured via `setup()`
- Project built so `lit.site.cfg.py` exists under the testsuite directory
- **Debugging only:** [nvim-dap](https://github.com/mfussenegger/nvim-dap) + `lldb` (built in on macOS)
- **Debugging only:** CIRCT/MLIR built with debug symbols (`RelWithDebInfo` or `Debug`)

## Debugging

`<leader>rd` / `:LlvmLitDebug` runs `llvm-lit` the same way as a normal test run, parses the
**expanded** tool commands from lit's verbose output (`+ …` or `# executed command: …`), lets you
pick a RUN line / pipeline segment, then launches **nvim-dap** on that command (not on `llvm-lit`
itself). This works for CIRCT, MLIR, and other lit-based projects because substitutions come from
lit.

### 1. Install nvim-dap (lazy.nvim)

Add to your Neovim config (alongside llvm-lit.nvim):

```lua
{
  'mfussenegger/nvim-dap',
  dependencies = {
    'mfussenegger/nvim-dap-ui',
  },
  config = function()
    local dap = require('dap')
    local dapui = require('dapui')
    dapui.setup()
    dap.listeners.after.event_initialized['dapui_config'] = dapui.open
    dap.listeners.before.event_terminated['dapui_config'] = dapui.close
    dap.listeners.before.event_exited['dapui_config'] = dapui.close

  -- LazyVim / Mason: enable lang.clangd extra or `:MasonInstall codelldb`.
  -- Adapter is auto-detected; llvm-lit re-registers codelldb with Mason's absolute path.
  end,
}
```

**LazyVim users:** install CodeLLDB via Mason if you have not already:

```vim
:MasonInstall codelldb
```

The plugin resolves the Mason binary automatically (LazyVim's default `command = "codelldb"` often fails with `ECONNREFUSED` when `codelldb` is not on your shell `PATH`).

### 2. Build with symbols

```bash
cmake -G Ninja llvm/llvm -B build \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DLLVM_ENABLE_ASSERTIONS=ON \
  ...
ninja -C build bin/circt-opt bin/llvm-lit
```

### 3. Use

1. `:LlvmLitSetup` once for the project (if not done already).
2. Open a `.mlir` test, set breakpoints in **C++ source** (not the `.mlir` file). Prefer absolute paths:
   `:e /path/to/circt/tools/circt-opt/call.cpp` or `:e /path/to/circt/lib/...`
3. Press `<leader>rd` — lit runs, then pick the command to debug.
4. Use `<leader>dc` (map yourself) or dap-ui to continue / step.

Suggested dap keymaps (add to your config):

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
    -- map: debug-info path prefix -> local checkout (NOT build/ -> source/)
    source_map = { ['/work/circt'] = '/Users/you/circt' },
  },
})
```

## Installation

### lazy.nvim (from GitHub)

```lua
{
  'ConvolutedDog/llvm-lit.nvim',
  cmd = {
    'LlvmLitRun', 'LlvmLitRunDump', 'LlvmLitDebug', 'LlvmLitSetup',
    'LlvmLitProjects', 'LlvmLitConfig', 'LlvmLitHelp',
  },
  ft = { 'mlir', 'py', 'll', 'td' },
  opts = {
    -- llvm_lit is optional if llvm-lit is already on your PATH.
    llvm_lit = '/path/to/build/bin/llvm-lit',
    keymaps = {
      run_dump     = '<leader>rt',  -- full output (most common)
      run          = '<leader>rT',  -- without dump
      debug        = '<leader>rd',  -- lit → nvim-dap
      focus_output = '<leader>ro',  -- jump to output buffer
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
  ft = { 'mlir', 'py', 'll', 'td' },
  opts = {
    -- llvm_lit is optional if llvm-lit is already on your PATH.
    llvm_lit = '/path/to/build/bin/llvm-lit',
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

## First-time setup

1. Open a Lit test file (`.mlir`, `.ll`, `.py`, …)
2. Run `:LlvmLitSetup`
3. Confirm or edit the auto-detected values:
   - **Project root** — detected from `.git`
   - **Lit testsuite path** — inferred from the build tree (e.g. `build/test`, `build/tools/mlir/test`)
   - **filter_depth** — number of trailing path segments used as `--filter` (default `2`)
   - **Working directory** — defaults to the project root

Config is saved to:

```text
~/.config/llvm-lit.nvim/projects.json
```

## Commands

| Command            | Action                                              |
|--------------------|-----------------------------------------------------|
| `:LlvmLitRun`      | Run test (no dump)                                  |
| `:LlvmLitRunDump`  | Run + `FILECHECK_OPTS=--dump-input=always` + standalone output |
| `:LlvmLitDebug`    | Run lit, pick expanded command, launch nvim-dap    |
| `:LlvmLitSetup`    | Configure / update current project                  |
| `:LlvmLitProjects` | Browse, edit, or delete saved projects (j/k to nav) |
| `:LlvmLitConfig`   | Show path to `projects.json`                        |
| `:LlvmLitHelp`     | Open this help                                      |

## Output buffer

Output appears in a read-only listed buffer named `[llvm-lit]`:

- Navigate to it with `<S-l>` (bufferline next) or `<leader>ro`
- Navigate back with `<S-h>` (bufferline previous)
- Close with `<leader>bd` (or any normal buffer-close mapping)

### Dump mode and standalone output (`<leader>rt`)

`<leader>rt` sets `FILECHECK_OPTS=--dump-input=always` before calling `llvm-lit`.
For projects that execute RUN commands via bash (e.g. CIRCT), FileCheck inherits
this variable and the full `Input was: <<< ... >>>` dump appears in the normal lit
output section.

**For MLIR / llvm-project this does not work.** LLVM's lit intentionally strips
`FILECHECK_OPTS` from the subprocess environment to keep the test suite hermetic
(see [D65121](https://reviews.llvm.org/D65121) and
[6cecd3c](https://github.com/llvm/llvm-project/commit/6cecd3c)).
As a result the dump never appears in the lit output for these projects.

To work around this, `<leader>rt` automatically appends a **standalone output**
section at the bottom of the buffer after lit finishes.  It parses the executed
commands from the lit verbose log (bash `+ …` xtrace lines or
`# executed command: …` entries), removes FileCheck from the pipeline, and
re-runs the remaining tool (e.g. `mlir-opt`, `circt-opt`) directly so you can
see the full IR output without FileCheck noise.

```
────────────────────────────────────────────────────────────────────────
  Standalone Output
  $ /path/to/mlir-opt file.mlir --some-pass
  NOTE: FileCheck removed from the RUN pipeline; not all scenarios
        are covered. Refer to the full lit output above for details.
────────────────────────────────────────────────────────────────────────
<clean IR output here>
```

Multiple RUN lines each get their own standalone section (`1 / N`, `2 / N`, …).
Conditional blocks (`%if …`) only appear if lit actually executed them.

## Configuration

```lua
require('llvm-lit').setup({
  llvm_lit      = 'llvm-lit',          -- or absolute path
  lit_args      = '-a',                -- -a: show output on PASS
  filecheck_opts = '--dump-input=always',
  filter_depth  = 2,                   -- last N path segments → --filter
  extensions    = { 'mlir', 'py', 'll', 'td', 'fir', 'sv', 'lib', 'test', 'aag' },
  keymaps = {
    run_dump     = '<leader>rt',
    run          = '<leader>rT',
    debug        = '<leader>rd',
    focus_output = '<leader>ro',
  },
  debug = {
    dap_type = 'lldb',
    stop_on_entry = false,
    -- source_map = { ['/build/path'] = '/local/checkout' },
  },
})
```

See [Debugging](#debugging) for nvim-dap setup.

## Example `projects.json`

Saved automatically by `:LlvmLitSetup` to
`~/.config/llvm-lit.nvim/projects.json`
(or `$XDG_CONFIG_HOME/llvm-lit.nvim/projects.json`).
Keys are stored alphabetically by `vim.json.encode`.

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
| `nvim-dap is not installed` | Add `mfussenegger/nvim-dap` to your plugin list (see Debugging) |
| Breakpoints not hit | Build with `RelWithDebInfo`; set breakpoints in **C++** (not `.mlir`); codelldb syncs via LLDB on continue — look for `synced N lldb breakpoint(s)` notification |
| `no executed tool commands found` | Ensure `lit_args` includes `-a` or `-vv` |

## License

MIT — see [LICENSE](LICENSE).
