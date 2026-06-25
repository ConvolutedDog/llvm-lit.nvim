# llvm-lit.nvim

Run `llvm-lit` on the current Lit test file from Neovim, with **per-project**
configuration stored under `~/.config/llvm-lit.nvim/`.

Inspired by [mlir-inc-previewer.nvim](../mlir-inc-previewer.nvim).

## Features

- `<leader>rt` — run with `FILECHECK_OPTS=--dump-input=always` (full output)
- `<leader>rT` — run without dump
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

## Installation

### lazy.nvim (from GitHub)

```lua
{
  'ConvolutedDog/llvm-lit.nvim',
  cmd = {
    'LlvmLitRun', 'LlvmLitRunDump', 'LlvmLitSetup',
    'LlvmLitProjects', 'LlvmLitConfig', 'LlvmLitHelp',
  },
  ft = { 'mlir', 'py', 'll', 'td' },
  opts = {
    -- llvm_lit is optional if llvm-lit is already on your PATH.
    llvm_lit = '/path/to/build/bin/llvm-lit',
    keymaps = {
      run_dump     = '<leader>rt',  -- full output (most common)
      run          = '<leader>rT',  -- without dump
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
    'LlvmLitRun', 'LlvmLitRunDump', 'LlvmLitSetup',
    'LlvmLitProjects', 'LlvmLitConfig', 'LlvmLitHelp',
  },
  ft = { 'mlir', 'py', 'll', 'td' },
  opts = {
    -- llvm_lit is optional if llvm-lit is already on your PATH.
    llvm_lit = '/path/to/build/bin/llvm-lit',
    keymaps = {
      run_dump     = '<leader>rt',
      run          = '<leader>rT',
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
| `:LlvmLitRunDump`  | Run + `FILECHECK_OPTS=--dump-input=always`          |
| `:LlvmLitSetup`    | Configure / update current project                  |
| `:LlvmLitProjects` | Browse, edit, or delete saved projects (j/k to nav) |
| `:LlvmLitConfig`   | Show path to `projects.json`                        |
| `:LlvmLitHelp`     | Open this help                                      |

## Output buffer

Output appears in a read-only listed buffer named `[llvm-lit]`:

- Navigate to it with `<S-l>` (bufferline next) or `:LlvmLitConfig` → `<leader>ro`
- Navigate back with `<S-h>` (bufferline previous)
- Close with `<leader>bd` (or any normal buffer-close mapping)

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
    focus_output = '<leader>ro',
  },
})
```

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

## License

MIT — see [LICENSE](LICENSE).
