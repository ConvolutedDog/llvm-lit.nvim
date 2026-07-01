-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- llvm-lit.nvim — Debug Module
-- =============================================================================
-- What this module does (step by step):
--
--   1. The user runs <leader>rd inside a lit test file (e.g. a .mlir file).
--   2. This calls M.run(), which launches `llvm-lit` as a background job.
--   3. lit executes the test and prints each shell command it ran (thanks to
--      `-a` / `-vv` flags, the output includes lines like "# executed command: ...").
--   4. Those commands are parsed and shown in a floating picker window.
--   5. The user picks one command (or a pipeline segment within it).
--   6. The chosen command is launched under nvim-dap (Debug Adapter Protocol),
--      typically using codelldb, so the user can set breakpoints and step through
--      the C++ code of the MLIR/LLVM tool (circt-opt, mlir-opt, toyc-ch7, etc.).
--
-- Key concepts for beginners:
--   - nvim-dap: a Neovim plugin that speaks the Debug Adapter Protocol. It
--     connects to a "debug adapter" (like codelldb) which controls LLDB.
--   - codelldb: a DAP adapter for LLDB, installed via Mason. We spawn it as a
--     background server and tell nvim-dap to connect to it.
--   - lit: LLVM's integrated test runner. It parses `// RUN:` lines from test
--     files, expands `%s` (the test file path) and runs each shell command.
--   - pipeline segment: a single command in a `cmd1 | cmd2 | FileCheck %s`
--     chain. Only the first segment is typically debuggable (the tool you want
--     to step through, not FileCheck which just checks output).
-- =============================================================================

-- Load submodules: commands.lua parses lit output, config.lua reads user
-- settings, run.lua actually spawns the `llvm-lit` process.
local commands = require('llvm-lit.commands')
local config = require('llvm-lit.config')
local run = require('llvm-lit.run')

-- Module table: functions prefixed with M.* are public (callable from other
-- files like init.lua). Everything else is private to this file.
local M = {}

-- uv process handle for the codelldb server we spawn. We keep it here so
-- we can kill it later when the debug session ends or a new one starts.
local codelldb_proc = nil

-- Lua 5.1 compatibility: table.unpack was introduced in 5.2; in Neovim
-- (which uses LuaJIT, based on 5.1), it's just unpack.
local unpack = table.unpack or unpack

-- ---------------------------------------------------------------------------
-- Small helpers used throughout the module
-- ---------------------------------------------------------------------------

-- Shorthand to show an error notification in Neovim's message area.
local function notify_err(msg)
  vim.notify('[llvm-lit] ' .. msg, vim.log.levels.ERROR, { title = 'llvm-lit debug' })
end

-- Try to load nvim-dap. pcall means "protected call": if require('dap')
-- throws an error (because the plugin isn't installed), we catch it and
-- return nil + a helpful message instead of crashing.
local function require_dap()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    return nil, 'nvim-dap is not installed; see README § Debugging'
  end
  return dap
end

-- ===========================================================================
-- PHASE 0: codelldb server management
-- ===========================================================================
-- nvim-dap can either launch a new debug adapter each time (type = 'server',
-- but auto-start) or connect to an already-running adapter. We choose the
-- latter: start codelldb once, keep it alive, and point nvim-dap at it.
-- This avoids the startup delay of spawning codelldb for every debug session.
-- ===========================================================================

-- Search for the codelldb executable, checking a few common locations:
--   1. Mason's unpacked extension binary (preferred — avoids a bash wrapper)
--   2. exepath() — whatever is on $PATH
--   3. Mason's bin/ symlink (a fallback bash wrapper)
--
-- Mason installs codelldb to:
--   ~/.local/share/nvim/mason/packages/codelldb/extension/adapter/codelldb
local function find_codelldb_executable()
  local data = vim.fn.stdpath('data')
  local pkg = data .. '/mason/packages/codelldb'
  -- The real adapter binary — much faster than Mason's shell wrapper.
  local adapter = pkg .. '/extension/adapter/codelldb'
  if vim.fn.executable(adapter) == 1 then
    return adapter
  end

  -- If the user installed codelldb outside Mason, check $PATH.
  local cmd = vim.fn.exepath('codelldb')
  if cmd ~= '' and vim.fn.executable(cmd) == 1 then
    return cmd
  end

  -- Fallback: Mason's bin/ symlink (a small shell script that runs the real binary).
  for _, candidate in ipairs({
    pkg .. '/codelldb',
    data .. '/mason/bin/codelldb',
  }) do
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end

  -- If the package directory exists but no binary is executable, Mason may
  -- still be downloading/compiling it.
  if vim.fn.isdirectory(pkg) == 1 then
    return nil, 'codelldb is still installing in Mason (:Mason); wait until it moves to Installed, then restart nvim'
  end

  return nil, 'codelldb not found; run :MasonInstall codelldb then restart nvim'
end

-- Ask the OS for a free TCP port by binding to port 0 (the kernel assigns
-- one), reading the port number, then closing the socket.
local function get_free_port()
  local uv = vim.loop or vim.uv
  local sock = assert(uv.new_tcp())
  sock:bind('127.0.0.1', 0)
  local port = sock:getsockname().port
  sock:close()
  return port
end

-- Kill the codelldb server if it's still running. The pcall() wrapper
-- catches errors (e.g. if the process already exited).
local function stop_codelldb_server()
  if codelldb_proc and not codelldb_proc:is_closing() then
    pcall(function()
      codelldb_proc:kill('sigterm')
    end)
  end
  codelldb_proc = nil
end

-- After spawning codelldb, we need to wait until it's actually listening
-- for TCP connections before telling nvim-dap to connect. This function
-- polls `lsof` in a loop until the port shows LISTEN status or we time out.
--
-- If lsof isn't available (e.g. minimal systems), we just wait 300ms and
-- hope codelldb is ready (it usually is).
local function wait_for_listen(port, timeout_ms)
  if vim.fn.executable('lsof') ~= 1 then
    vim.wait(300, function()
      return false
    end, 300)
    return true
  end

  local uv = vim.loop or vim.uv
  local deadline = uv.now() + timeout_ms
  while uv.now() < deadline do
    local out = vim.fn.system({ 'sh', '-c', 'lsof -iTCP:' .. port .. ' -sTCP:LISTEN 2>/dev/null' })
    if out ~= '' and out:match('LISTEN') then
      return true
    end
    vim.wait(50, function()
      return false
    end, 50)
  end
  return false
end

-- Main entry point for starting codelldb:
--   1. Kill any existing codelldb process (so we start fresh).
--   2. Find the codelldb executable.
--   3. Pick a free TCP port.
--   4. On macOS, set DYLD_LIBRARY_PATH so LLDB can find its native libraries.
--   5. Spawn codelldb as a child process (uv.spawn).
--   6. Wait for it to start listening.
--   7. Register the adapter in nvim-dap so it knows to connect to localhost:port.
local function start_codelldb_server(dap)
  -- Step 1: clean up any previous server
  stop_codelldb_server()

  -- Step 2: find the executable
  local cmd, err = find_codelldb_executable()
  if not cmd then
    return false, err
  end

  -- Step 3: get a free port
  local port = get_free_port()
  local uv = vim.loop or vim.uv
  local pkg = vim.fn.stdpath('data') .. '/mason/packages/codelldb'

  -- Step 4: macOS needs DYLD_LIBRARY_PATH to find LLDB's shared libraries.
  -- Without this, codelldb crashes on launch with a library-load error.
  local env = nil
  if vim.fn.has('macunix') == 1 then
    env = {
      DYLD_LIBRARY_PATH = pkg .. '/extension/lldb/lib',
    }
  end

  -- Step 5: spawn codelldb. stdio = { nil, nil, nil } means we don't
  -- connect stdin/stdout/stderr — codelldb communicates via TCP.
  local handle, pid_or_err = uv.spawn(cmd, {
    stdio = { nil, nil, nil },
    args = { '--port', tostring(port) },
    cwd = vim.fs.dirname(cmd),
    env = env,
    detached = false,
    hide = true,
  }, function(code)
    -- This callback runs when the process exits (async).
    if codelldb_proc == handle then
      codelldb_proc = nil
    end
    if code ~= 0 then
      vim.schedule(function()
        notify_err('codelldb exited with code ' .. tostring(code))
      end)
    end
  end)

  if not handle then
    return false, 'failed to spawn codelldb: ' .. tostring(pid_or_err)
  end

  codelldb_proc = handle

  -- Step 6: wait for codelldb to bind its TCP port (up to 15 seconds).
  if not wait_for_listen(port, 15000) then
    stop_codelldb_server()
    return false, 'codelldb did not start listening (try :MasonInstall codelldb, then restart nvim)'
  end

  -- Step 7: register the adapter. nvim-dap will connect to this address
  -- when we call dap.run() later.
  local dbg = config.options.debug or {}
  local init_timeout = dbg.initialize_timeout_sec or 120

  dap.adapters.codelldb = {
    type = 'server',
    host = '127.0.0.1',
    port = port,
    options = {
      max_retries = 40,
      initialize_timeout_sec = init_timeout,
      disconnect_timeout_sec = 10,
    },
  }

  return true, port
end

-- Decide which DAP adapter to use. The user can specify a preferred type
-- in their config (debug.dap_type). If they didn't, we try codelldb first
-- (via Mason), then fall back to any registered 'lldb' adapter.
--
-- Returns (adapter_type_string, error_message).
local function resolve_dap_type(dap, dbg)
  dbg = dbg or {}
  local preferred = dbg.dap_type

  -- Default path: try codelldb. If it's installed (find_codelldb_executable
  -- returns a path), use it. Otherwise return the error from the search.
  if preferred == 'codelldb' or preferred == nil or preferred == '' then
    local cmd, err = find_codelldb_executable()
    if cmd then
      return 'codelldb'
    end
    return nil, err
  elseif preferred and dap.adapters[preferred] then
    return preferred
  end

  -- Fallback: if nvim-dap already has an 'lldb' adapter registered, use it.
  if dap.adapters.lldb then
    return 'lldb'
  end

  -- Nothing worked — build a helpful error message listing what IS available.
  local available = vim.tbl_keys(dap.adapters or {})
  table.sort(available)
  local msg = 'no C/C++ DAP adapter (tried codelldb, lldb)'
  if #available > 0 then
    msg = msg .. '; available: ' .. table.concat(available, ', ')
  end
  if preferred and preferred ~= '' then
    msg = msg .. string.format(' (debug.dap_type = %q is not registered)', preferred)
  end
  msg = msg .. '. Install codelldb via :MasonInstall codelldb'
  return nil, msg
end

-- ===========================================================================
-- PHASE 1: Command Picker UI
-- ===========================================================================
-- After lit finishes, the user sees a floating window with two panes:
--   Left:  a list of truncated commands (numbered).
--   Right: a preview of the full command + the original // RUN: line.
--
-- The user navigates with j/k (which wrap around), confirms with Enter,
-- or cancels with Esc/q. Leaving the window (BufLeave) also cancels.
-- ===========================================================================

-- Maximum width of a truncated label before we append "...".
local LIST_LABEL_MAX = 88

-- Highlight groups for the picker windows:
--   NormalFloat → normal text in the float
--   FloatBorder → rounded border lines
--   CursorLine  → the currently selected row (uses the theme's Visual hl)
local PICK_WINHL = 'NormalFloat:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual'

-- Format one line of the list:
--   "  1.  /path/to/tool -flag /long/path/..."
-- or, for pipeline segments:
--   "[1]  /path/to/tool -flag ..."
--
-- The command string is truncated if it exceeds max_len.
-- @param idx:    1-based index of this item
-- @param cmd:    the full command string to display
-- @param count:  total number of items (used to pad the index width)
-- @param bracket: if true, use "[N]" format; otherwise "N."
-- @param max_len: maximum characters before truncation (default: 88)
local function list_label(idx, cmd, count, bracket, max_len)
  max_len = max_len or LIST_LABEL_MAX
  -- Truncate with "..." if the command is too long to fit on one line.
  local truncated = (#cmd > max_len) and (cmd:sub(1, max_len - 3) .. '...') or cmd
  -- Compute the width needed for the index (e.g. " 1." vs "10.").
  local w = math.max(#tostring(count), 1)
  local num
  if bracket then
    num = string.format('[%' .. w .. 'd]', idx)
  else
    num = string.format('%' .. w .. 'd.', idx)
  end
  return '  ' .. num .. '  ' .. truncated
end

-- Apply extmarks to make the index numbers (" 1.", "[2]") use a distinct
-- highlight group. This gives the list a visual style similar to Snacks.picker.
-- An "extmark" is a Neovim feature that attaches metadata (like highlight) to
-- a range of text without modifying the buffer content.
--
-- @param buf:   the buffer handle
-- @param count: how many items (lines) to highlight
local function highlight_left_indices(buf, count)
  local ns = vim.api.nvim_create_namespace('llvm_lit_debug_pick')
  -- Try to use Snacks' index highlight if available; fall back to Comment.
  local idx_hl = 'SnacksPickerIdx'
  if vim.fn.hlexists(idx_hl) == 0 then
    idx_hl = 'Comment'
  end
  for i = 1, count do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ''
    -- Match "  [N]" or "  N." — the index prefix with its 2-space indent.
    local prefix = line:match('^(%s*%[%d+%])') or line:match('^(%s*%d+%.)')
    if prefix then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_col = #prefix,
        hl_group = idx_hl,
      })
    end
  end
end

-- Clean up the prompt string for use as the picker window title:
-- remove leading/trailing whitespace/colons, and strip the "llvm-lit:" prefix.
local function pick_title(prompt)
  return prompt:gsub('^%s*', ''):gsub('[%s:]*$', ''):gsub('^llvm%-lit:%s*', '')
end

-- Apply consistent window options to a picker sub-window.
-- This function is called for both the list window and the preview window.
-- The options make the window look like a clean float: no line numbers, no
-- sign column, no fold column, and (for the list) cursorline highlighting.
--
-- @param win:  the window handle
-- @param opts: { cursorline = bool, winblend = number }
local function apply_pick_wo(win, opts)
  opts = opts or {}
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  vim.wo[win].winhighlight = PICK_WINHL
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = 'no'
  vim.wo[win].foldcolumn = '0'
  vim.wo[win].cursorline = opts.cursorline == true
  vim.wo[win].cursorlineopt = 'line'
  vim.wo[win].wrap = false
  vim.wo[win].colorcolumn = ''
  vim.wo[win].list = false
  vim.wo[win].winblend = opts.winblend or 0
end

-- The main picker UI function. Creates two floating windows (list + preview)
-- centered on screen, with the list vertically centered alongside the preview.
--
-- Navigation:
--   j / k   — move up/down (cyclic: wraps around)
--   Enter   — confirm selection
--   Esc / q — cancel
--   BufLeave (click elsewhere or Ctrl-w) — auto-cancel
--
-- The preview window updates every time the cursor moves in the list window.
--
-- @param items:     table of { idx, cmd, seg, run_line } objects
-- @param prompt:    string shown as the list window title
-- @param on_choice: callback function(selected_item), called when user confirms
local function pick_split_window(items, prompt, on_choice)
  local count = #items
  local gap = 3       -- horizontal gap between list and preview windows
  local pad = 4       -- minimum margin from the edge of the editor

  -- --- Layout calculations ---

  -- List window: width is 36% of screen (capped between 52 and 80).
  local list_w = math.min(80, math.max(52, math.floor(vim.o.columns * 0.36)))
  local label_max = list_w - 12
  local list_h = math.min(count + 2, math.min(20, vim.o.lines - pad * 2))

  -- Preview window: same width as the list (if there's room).
  local preview_w = list_w
  if vim.o.columns - list_w - gap - pad * 2 < list_w + pad then
    preview_w = 0 -- Skip preview when the terminal is too narrow.
  end

  local total_w = list_w + (preview_w > 0 and (gap + preview_w) or 0)
  local preview_h = math.min(18, vim.o.lines - pad * 2)
  local preview_row = math.max(pad, math.floor((vim.o.lines - preview_h) / 2))
  local list_col = math.max(pad, math.floor((vim.o.columns - total_w) / 2))
  local title = pick_title(prompt)

  -- Vertically center the list window within the taller preview window.
  -- This makes the layout look balanced: the list sits in the middle of the
  -- right-hand preview, similar to how git diff --staged shows a file list
  -- beside a diff preview.
  local list_row = preview_row + math.floor((preview_h - list_h) / 2)

  -- --- Build the list buffer ---

  local list_lines = vim.tbl_map(function(it)
    local cmd = it.cmd or it.seg or ''
    return list_label(it.idx, cmd, count, it.seg ~= nil, label_max)
  end, items)
  -- Add a blank separator line + keyboard hint at the bottom.
  table.insert(list_lines, '')
  table.insert(list_lines, '  ⏎ confirm   esc / q cancel')

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
  -- Prevent the user from editing the buffer.
  vim.bo[list_buf].modifiable = false
  -- 'wipe' means the buffer is fully deleted when the window closes.
  vim.bo[list_buf].bufhidden = 'wipe'
  highlight_left_indices(list_buf, count)

  -- --- Build the preview buffer ---

  local preview_buf = nil
  if preview_w > 0 then
    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[preview_buf].buftype = 'nofile'
    vim.bo[preview_buf].bufhidden = 'wipe'
    vim.bo[preview_buf].modifiable = false
  end

  -- Guard flag to prevent double-close race conditions.
  local closed = false
  local list_win, preview_win
  -- Remember the window the user was in before we opened the picker,
  -- so we can restore focus when closing.
  local prev_win = vim.api.nvim_get_current_win()

  -- Close both windows and restore the previous window. Uses pcall so that
  -- if a window was already closed (e.g. by the user) we don't crash.
  local function close_all()
    if closed then
      return
    end
    closed = true
    pcall(vim.api.nvim_win_close, list_win, true)
    if preview_win then
      pcall(vim.api.nvim_win_close, preview_win, true)
    end
    if vim.api.nvim_win_is_valid(prev_win) then
      pcall(vim.api.nvim_set_current_win, prev_win)
    end
  end

  -- --- Open the windows ---

  list_win = vim.api.nvim_open_win(list_buf, true, {
    relative = 'editor',
    row = list_row,
    col = list_col,
    width = list_w,
    height = list_h,
    style = 'minimal',
    border = 'rounded',
    title = '  ' .. title .. '  ',
    title_pos = 'center',
  })
  apply_pick_wo(list_win, { cursorline = true })
  -- Start the cursor at line 1 (the first item).
  vim.api.nvim_win_set_cursor(list_win, { 1, 0 })

  if preview_buf then
    local preview_col = list_col + list_w + gap

    preview_win = vim.api.nvim_open_win(preview_buf, false, {
      relative = 'editor',
      row = preview_row,
      col = preview_col,
      width = preview_w,
      height = preview_h,
      style = 'minimal',
      border = 'rounded',
      title = ' Command ',
      title_pos = 'center',
    })
    -- Configure the preview window for soft text wrapping:
    --   wrap + linebreak breaks lines at word boundaries (not mid-character).
    --   breakindent indents continuation lines to align with the first line.
    vim.wo[preview_win].winhighlight = PICK_WINHL
    vim.wo[preview_win].number = false
    vim.wo[preview_win].relativenumber = false
    vim.wo[preview_win].signcolumn = 'no'
    vim.wo[preview_win].cursorline = false
    vim.wo[preview_win].wrap = true
    vim.wo[preview_win].linebreak = true
    vim.wo[preview_win].breakindent = true
    vim.wo[preview_win].colorcolumn = ''
    vim.wo[preview_win].list = false
  end

  -- Create an autocommand group so we can clean up all listeners at once.
  local group = vim.api.nvim_create_augroup('LlvmLitDebugPick', { clear = true })

  -- --- Preview update logic ---

  -- Whenever the cursor moves in the list, update the preview window to
  -- show the full command for the currently selected item.
  --
  -- The preview shows:
  --   • The command text (with | replaced by a Unicode box-drawing character
  --     for readability).
  --   • A separator line (────), then the original // RUN: line from the
  --     test file, so you can see what the lit test's source looks like.
  local function show_preview()
    if closed or not preview_buf then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[lnum]
    if not item then
      return
    end
    local cmd = item.cmd or item.seg or ''
    local run_line = item.run_line

    local lines = {}
    -- Replace pipe characters with a Unicode "light vertical" character to
    -- make pipeline boundaries visually clearer.
    local disp = cmd:gsub('%s*|%s*', '  │  ')
    vim.list_extend(lines, vim.split(disp, '\n'))

    -- Add the separator and original RUN: line (if we found one).
    if run_line and #run_line > 0 then
      table.insert(lines, '')
      table.insert(lines, string.rep('─', preview_w > 0 and preview_w - 2 or 60))
      table.insert(lines, 'RUN: ' .. run_line)
    end

    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false
    -- Scroll the preview to the top when switching items.
    if vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_win_set_cursor, preview_win, { 1, 0 })
    end
  end

  -- Show the preview for the first item immediately.
  show_preview()

  -- Register CursorMoved so the preview follows the cursor.
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = list_buf,
    callback = show_preview,
  })

  -- --- Finish / confirm / cancel logic ---

  -- Close the picker and call on_choice with the selected item (nil = cancelled).
  local function finish(item)
    if closed then
      return
    end
    close_all()
    vim.api.nvim_del_augroup_by_id(group)
    -- vim.schedule defers the callback to the next Neovim event loop tick,
    -- ensuring we don't call on_choice while still in the middle of handling
    -- a keypress or autocmd.
    vim.schedule(function()
      on_choice(item)
    end)
  end

  -- When the user moves focus away from the list window (e.g. clicks another
  -- window or uses Ctrl-w), treat it as a cancel. This makes the picker feel
  -- less intrusive — you don't have to explicitly press Esc.
  vim.api.nvim_create_autocmd('BufLeave', {
    group = group,
    buffer = list_buf,
    callback = function()
      finish(nil)
    end,
  })

  -- Read the cursor position and call finish() with the selected item.
  local function confirm()
    local lnum = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[lnum]
    if not item then
      return
    end
    finish(item)
  end

  -- --- Keymaps ---

  -- Cyclic j/k: if you press j past the last item, you wrap to the first.
  -- If you press k above the first, you wrap to the last.
  -- This skips the blank separator line and the keyboard hint line entirely
  -- (they're at positions > count, so the wrapping boundary count keeps you
  -- within the items).
  local function move_cursor(dir)
    if closed then
      return
    end
    local lnum = vim.api.nvim_win_get_cursor(list_win)[1]
    local next_lnum = lnum + dir
    if next_lnum < 1 then
      next_lnum = count
    elseif next_lnum > count then
      next_lnum = 1
    end
    pcall(vim.api.nvim_win_set_cursor, list_win, { next_lnum, 0 })
  end

  vim.keymap.set('n', 'j', function() move_cursor(1) end, { buffer = list_buf, nowait = true, desc = 'llvm-lit: down' })
  vim.keymap.set('n', 'k', function() move_cursor(-1) end, { buffer = list_buf, nowait = true, desc = 'llvm-lit: up' })
  vim.keymap.set('n', '<CR>', confirm, { buffer = list_buf, nowait = true, desc = 'llvm-lit: confirm' })
  vim.keymap.set('n', '<Esc>', function()
    finish(nil)
  end, { buffer = list_buf, nowait = true, desc = 'llvm-lit: cancel' })
  vim.keymap.set('n', 'q', function()
    finish(nil)
  end, { buffer = list_buf, nowait = true, desc = 'llvm-lit: cancel' })
end

-- Wrapper around pick_split_window that handles edge cases:
--   • If there are no items, call on_choice(nil) immediately.
--   • If there is exactly one item, auto-select it without showing the UI.
--   • Otherwise, show the picker.
local function ui_select(items, prompt, on_choice)
  if #items == 0 then
    on_choice(nil)
    return
  end
  if #items == 1 then
    on_choice(items[1])
    return
  end

  pick_split_window(items, prompt, on_choice)
end

-- ===========================================================================
-- PHASE 2: nvim-dap session management
-- ===========================================================================
-- After the user picks a command, we need to:
--   a) Count existing breakpoints (set via :DapToggleBreakpoint or <leader>db).
--   b) Launch the chosen tool under nvim-dap.
--   c) Install listeners so that when the debugger stops or exits, we log
--      useful info and (for codelldb) sync breakpoints via raw LLDB commands.
--
-- Breakpoint sync: codelldb's DAP setBreakpoints often fails on statically
-- linked LLVM binaries (it returns "Resolved locations: 0" because it can't
-- map source files). As a workaround, we send raw LLDB commands through the
-- DAP "evaluate" REPL:
--   breakpoint set -f File.cpp -l 42
-- This bypasses codelldb's source-file resolution and talks to LLDB directly.
-- ===========================================================================

-- Count how many breakpoints the user has set across all buffers.
-- Uses nvim-dap's internal breakpoint list (dap.breakpoints.get()).
local function count_breakpoints()
  local ok, bps = pcall(require('dap').list_breakpoints)
  if not ok or not bps or not bps.breakpoints then
    return 0
  end
  local n = 0
  for _, buf_bps in pairs(bps.breakpoints) do
    n = n + #buf_bps
  end
  return n
end

-- Convert the user's config.source_map (which may be an array of pairs like
-- { {"/from", "/to"}, ... }) into the format codelldb expects: a flat map
-- { "/from" = "/to", ... }. Returns nil if no mapping is configured.
local function to_source_map(cfg)
  if not cfg or vim.tbl_isempty(cfg) then
    return nil
  end
  -- Array-of-pairs format?
  if cfg[1] ~= nil then
    local map = {}
    for _, pair in ipairs(cfg) do
      if type(pair) == 'table' and pair[1] and pair[2] then
        map[pair[1]] = pair[2]
      end
    end
    return vim.tbl_isempty(map) and nil or map
  end
  return cfg
end

-- Shell-quote a string so it's safe to use in an LLDB command.
-- Wraps the string in single quotes and escapes any inner single quotes.
local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Collect all nvim-dap breakpoints and format them as LLDB
-- "breakpoint set -f <file> -l <line>" command strings.
--
-- The breakpoint_mode config controls how source files are identified:
--   'file' (default): use just the filename (e.g. "ExportVerilog.cpp").
--   'path':           use the full absolute path.
--
-- We deduplicate by file:line so that two breakpoints on the same line
-- don't generate duplicate LLDB commands.
--
-- @param dbg: the debug config table (from config.options.debug)
-- @return:    list of LLDB command strings
local function collect_lldb_breakpoint_sets(dbg)
  local mode = dbg.breakpoint_mode or 'file'
  local seen = {}
  local specs = {}
  for bufnr, buf_bps in pairs(require('dap.breakpoints').get()) do
    local path = vim.api.nvim_buf_get_name(bufnr)
    if path ~= '' and #buf_bps > 0 then
      local file = (mode == 'path') and vim.fs.normalize(path) or vim.fn.fnamemodify(path, ':t')
      for _, bp in ipairs(buf_bps) do
        local key = file .. ':' .. bp.line
        if not seen[key] then
          seen[key] = true
          table.insert(
            specs,
            string.format('breakpoint set -f %s -l %d', shell_quote(file), bp.line)
          )
        end
      end
    end
  end
  return specs
end

-- Execute a list of LLDB breakpoint-set commands sequentially through the
-- DAP session's "evaluate" REPL. Each command is sent via
-- session:request('evaluate', { expression = ..., context = 'repl' }, callback).
--
-- We chain them recursively: set_next() sends the next command, and when all
-- are done, calls on_done(true). If any command errors, we abort with
-- on_done(false).
--
-- @param session: the active nvim-dap session
-- @param specs:   list of LLDB command strings (from collect_lldb_breakpoint_sets)
-- @param on_done: function(success: boolean)
local function apply_lldb_breakpoint_sets(session, specs, on_done)
  local i = 1
  local function set_next(set_err)
    if set_err then
      notify_err('lldb breakpoint sync failed: ' .. tostring(set_err.message or set_err))
      if on_done then
        on_done(false)
      end
      return
    end
    if i > #specs then
      vim.notify(
        string.format('[llvm-lit] synced %d lldb breakpoint(s)', #specs),
        vim.log.levels.INFO,
        { title = 'llvm-lit debug' }
      )
      if on_done then
        on_done(true)
      end
      return
    end
    local expr = specs[i]
    i = i + 1
    session:request('evaluate', { expression = expr, context = 'repl' }, set_next)
  end
  set_next(nil)
end

-- Check if an LLDB "breakpoint delete" error is benign. Deleting breakpoints
-- when none exist produces "no breakpoints exist" — that's fine, not a real
-- error.
local function delete_err_is_benign(err)
  if not err then
    return false
  end
  local msg = tostring(err.message or err)
  return msg:find('no breakpoints exist', 1, true) ~= nil
end

-- Sync nvim-dap breakpoints to LLDB by:
--   1. Deleting all existing LLDB breakpoints (to avoid duplicates).
--   2. Setting each breakpoint from nvim-dap via raw LLDB commands.
--
-- We do this because codelldb's DAP setBreakpoints often fails on static
-- LLVM binaries (it can't resolve source file → binary locations). Sending
-- commands through the REPL talk directly to LLDB, bypassing the broken
-- file-resolution path.
--
-- @param session: the active nvim-dap session
-- @param dbg:     the debug config
-- @param on_done: function(success: boolean)
local function sync_lldb_breakpoints(session, dbg, on_done)
  local specs = collect_lldb_breakpoint_sets(dbg)
  if #specs == 0 then
    if on_done then
      on_done(true)
    end
    return
  end

  session:request('evaluate', { expression = 'breakpoint delete', context = 'repl' }, function(del_err)
    if del_err and not delete_err_is_benign(del_err) then
      notify_err('lldb breakpoint delete failed: ' .. tostring(del_err.message or del_err))
      if on_done then
        on_done(false)
      end
      return
    end
    apply_lldb_breakpoint_sets(session, specs, on_done)
  end)
end

-- Monkey-patch a DAP session's _step method so that every time the user
-- presses "continue" (F5), we sync breakpoints just before the program
-- resumes. This ensures newly added breakpoints take effect without having
-- to restart the debug session.
--
-- The patching works by saving the original _step, then replacing it with
-- a wrapper that:
--   1. Checks if the request is 'continue' for our session.
--   2. If so, syncs breakpoints first, then calls the original _step.
--   3. For any other request (step into, step over, etc.), just passes
--      through to the original.
local function hook_continue_sync(session, dap_cfg, dbg)
  if session._llvm_lit_hooked then
    return
  end
  session._llvm_lit_hooked = true
  local orig_step = session._step
  function session:_step(req, ...)
    local args = { ... }
    if req == 'continue' and self.config and self.config.name == dap_cfg.name then
      sync_lldb_breakpoints(self, dbg, function()
        orig_step(self, req, unpack(args))
      end)
      return
    end
    return orig_step(self, req, unpack(args))
  end
end

-- Install nvim-dap event listeners for the debug session we're about to start.
-- These listeners let us react to debugger events without polling:
--
--   event_stopped:     The debugger hit a breakpoint or stopped for some
--                      reason. We hook the continue action to sync breakpoints
--                      (only for codelldb).
--   event_terminated:  The debug session ended. Clean up our listeners so
--                      they don't interfere with future sessions.
--   event_exited:      The debugee process exited. Log the exit code and
--                      warn if breakpoints were set but never hit.
--
-- @param dap:      the nvim-dap module
-- @param dap_cfg:  the DAP configuration we'll pass to dap.run()
-- @param dbg:      the debug config (user settings)
-- @param dap_type: the adapter type string (e.g. "codelldb")
local function install_session_listeners(dap, dap_cfg, dbg, dap_type)
  local stop_on_entry = dbg.stop_on_entry ~= false
  local use_lldb_sync = dap_type == 'codelldb'

  -- When the debugger stops (breakpoint hit, step, etc.):
  dap.listeners.after.event_stopped['llvm_lit_debug'] = function(session, body)
    if not session.config or session.config.name ~= dap_cfg.name then
      return
    end
    if use_lldb_sync then
      hook_continue_sync(session, dap_cfg, dbg)
    end
  end

  -- When the session is terminated (user stops debugging or program exits):
  dap.listeners.after.event_terminated['llvm_lit_debug'] = function(session)
    if not session.config or session.config.name ~= dap_cfg.name then
      return
    end
    dap.listeners.after.event_stopped['llvm_lit_debug'] = nil
    dap.listeners.after.event_exited['llvm_lit_debug'] = nil
    dap.listeners.after.event_terminated['llvm_lit_debug'] = nil
  end

  -- When the debugee process exits:
  dap.listeners.after.event_exited['llvm_lit_debug'] = function(session, body)
    if not session.config or session.config.name ~= dap_cfg.name then
      return
    end
    local code = body and body.exitCode or -1
    local prog = vim.fn.fnamemodify(session.config.program or '', ':t')
    vim.notify(
      string.format('[llvm-lit] %s exited with code %d', prog, code),
      code == 0 and vim.log.levels.INFO or vim.log.levels.WARN,
      { title = 'llvm-lit debug' }
    )
    -- Helpful warnings for common scenarios:
    if code == 0 and count_breakpoints() > 0 and use_lldb_sync then
      -- Breakpoints were set but never triggered — probably wrong pass name.
      vim.notify(
        '[llvm-lit] tool exited without hitting breakpoints. '
          .. 'Check the pass runs for this test (e.g. -export-verilog → ExportVerilogPass ~7346, '
          .. 'not ExportSplitVerilogPass ~7525)',
        vim.log.levels.WARN,
        { title = 'llvm-lit debug' }
      )
    elseif code == 0 and count_breakpoints() == 0 and not stop_on_entry then
      -- No breakpoints at all and stop_on_entry is off — the binary runs
      -- to completion instantly.
      vim.notify(
        '[llvm-lit] no breakpoints were set; tool finished instantly. '
          .. 'Set breakpoints in C++ source (<leader>db) or keep stop_on_entry = true',
        vim.log.levels.WARN,
        { title = 'llvm-lit debug' }
      )
    end
  end
end

-- ===========================================================================
-- PHASE 3: Launch the debug session
-- ===========================================================================
-- This is the public entry point that actually launches the debugger.
-- It's called after the user has picked both a command and (optionally) a
-- pipeline segment.
--
-- Steps:
--   1. Load nvim-dap (fail early if not installed).
--   2. Set up custom highlight groups for the stopped-line indicator.
--   3. Parse the command string into a program + args tuple.
--   4. Validate that the program exists and is executable.
--   5. Resolve the DAP adapter type (codelldb preferred).
--   6. Start the codelldb server (if using codelldb).
--   7. Check for breakpoints (warn if none set and stop_on_entry is off).
--   8. Build the DAP configuration table.
--   9. Install session event listeners.
--   10. Call dap.run() to start debugging.
-- ===========================================================================

-- @param info:         table with { cwd, filter, ... } from the lit run
-- @param cmd_str:      the full command string (e.g. "circt-opt / file.mlir -flag | FileCheck %s")
-- @param segment_idx:  1-based index of the pipeline segment to debug (1 = the tool itself)
-- @return:             true on success, false + notify on failure
function M.launch(info, cmd_str, segment_idx)
  -- Step 1: ensure nvim-dap is available.
  local dap, dap_err = require_dap()
  if not dap then
    notify_err(dap_err)
    return false
  end

  -- Step 2: set up bright highlight for the stopped line (theme override).
  M.setup_highlights()

  -- Step 3: parse the command into { program, args }.
  local target, err = commands.parse_launch_target(cmd_str, segment_idx)
  if not target then
    notify_err(err)
    return false
  end

  -- Step 4: verify the program exists.
  if vim.fn.filereadable(target.program) ~= 1 and vim.fn.executable(target.program) ~= 1 then
    notify_err('program not found or not executable: ' .. target.program)
    return false
  end

  -- Step 5: determine which DAP adapter to use.
  local dbg = config.options.debug or {}
  local dap_type, type_err = resolve_dap_type(dap, dbg)
  if not dap_type then
    notify_err(type_err)
    return false
  end

  -- Step 6: start the codelldb server if needed.
  if dap_type == 'codelldb' then
    local ok, start_err = start_codelldb_server(dap)
    if not ok then
      notify_err(start_err)
      return false
    end
  end

  -- Step 7: warn if no breakpoints are set (debug session would be useless).
  local stop_on_entry = dbg.stop_on_entry ~= false
  local nbp = count_breakpoints()
  if nbp == 0 and not stop_on_entry then
    vim.notify(
      '[llvm-lit] no breakpoints set; tool may exit immediately after launch',
      vim.log.levels.WARN,
      { title = 'llvm-lit debug' }
    )
  end

  -- Step 8: build the DAP configuration.
  local dap_cfg = {
    name = string.format('llvm-lit debug (%s)', vim.fn.fnamemodify(target.program, ':t')),
    type = dap_type,
    request = 'launch',
    program = target.program,
    args = target.args,
    cwd = info.cwd,
    stopOnEntry = stop_on_entry,
  }

  if dbg.breakpoint_mode then
    dap_cfg.breakpointMode = dbg.breakpoint_mode
  end

  local source_map = to_source_map(dbg.source_map)
  if source_map then
    dap_cfg.sourceMap = source_map
  end

  -- Log the launch for user feedback.
  vim.notify(
    string.format('[llvm-lit] debug: %s %s', target.program, table.concat(target.args, ' ')),
    vim.log.levels.INFO,
    { title = 'llvm-lit debug' }
  )

  -- Step 9 + 10: install listeners and launch.
  install_session_listeners(dap, dap_cfg, dbg, dap_type)
  dap.run(dap_cfg, { filetype = dbg.filetype or 'cpp' })
  return true
end

-- ===========================================================================
-- PHASE 4: Pick a command (first picker — selecting from lit's output)
-- ===========================================================================
-- After lit runs, we get a list of command strings that were executed (e.g.
-- "/path/to/circt-opt" or "/path/to/mlir-opt", with flags, piped to FileCheck, etc.).
--
-- This function:
--   1. Reads the original test file (source_buf) to extract all // RUN: lines.
--   2. For each executed command, finds the best matching RUN line by scoring
--      how many of its distinctive tokens appear in the expanded command.
--   3. Builds the items table and shows the picker.
--
-- The RUN-line matching is important because lit expands placeholders like
-- %s (→ the test file path) in each RUN line, so the expanded command looks
-- quite different from the source. We match by distinctive flags like -opt,
-- --check-prefix=OPT, etc.
-- ===========================================================================

-- @param cmds:       list of command strings from lit output
-- @param source_buf: buffer handle of the original .mlir / .ll / .py test file
-- @param on_choice:  callback function(selected_command_string_or_nil)
local function pick_command(cmds, source_buf, on_choice)
  if #cmds == 0 then
    on_choice(nil, 'no executed tool commands found in lit output (try lit_args = "-a" or "-vv")')
    return
  end

  -- --- Step 1: parse RUN lines from the test file ---
  -- We need the source buffer, not the current buffer, because by the time
  -- this callback runs, the current buffer is probably the lit output window.
  local run_lines = {}
  local src = source_buf and vim.api.nvim_buf_is_valid(source_buf) and source_buf or vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  for _, line in ipairs(buf_lines) do
    -- Match both // RUN: (.mlir files) and # RUN: (.ll, .py files).
    local run_cmd = line:match('^%s*//%s*RUN:%s*(.+)$') or line:match('^%s*#%s*RUN:%s*(.+)$')
    if run_cmd then
      table.insert(run_lines, vim.trim(run_cmd))
    end
  end

  -- --- Step 2: scoring-based RUN-line matcher ---
  -- Given an expanded command string, find which // RUN: line it came from
  -- by comparing their distinctive tokens.
  --
  -- Tokens we ignore (they're not distinctive):
  --   • The program name (token 1 — can appear in multiple RUN lines).
  --   • Lit placeholders: %s, %t, %S — these are substituted with paths.
  --   • Shell redirections: |, 2>&1, >, >>, etc.
  --
  -- Everything else (flags, --check-prefix values, etc.) gets a point.
  -- The RUN line with the most points wins.
  local function match_run(cmd)
    if #run_lines == 0 then
      return nil
    end
    local best_idx, best_score = nil, 0
    for i, rl in ipairs(run_lines) do
      local tokens = vim.split(rl, '%s+')
      local score = 0
      for j, tok in ipairs(tokens) do
        if j > 1 and tok ~= '%s' and tok ~= '%t' and tok ~= '%S' and
           tok ~= '|' and tok ~= '2>&1' and not tok:match('^[12]?>>?') then
          if cmd:find(tok, 1, true) then
            score = score + 1
          end
        end
      end
      if score > best_score then
        best_score = score
        best_idx = i
      end
    end
    if best_idx and best_score > 0 then
      return run_lines[best_idx]
    end
    -- Fallback: if nothing matched (shouldn't happen), just show the first
    -- RUN line as a rough reference.
    return run_lines[1]
  end

  -- --- Step 3: build items and show picker ---
  local items = {}
  for idx, cmd in ipairs(cmds) do
    table.insert(items, { idx = idx, cmd = cmd, run_line = match_run(cmd) })
  end

  ui_select(items, 'llvm-lit: RUN command to debug', function(sel)
    if not sel then
      on_choice(nil, 'cancelled')
      return
    end
    on_choice(sel.cmd)
  end)
end

-- ===========================================================================
-- PHASE 5: Pick a pipeline segment (second picker)
-- ===========================================================================
-- If a command pipeline has multiple segments (e.g. "circt-opt ... | FileCheck" or
-- "mlir-opt ... | FileCheck"),
-- the user picks which segment to debug. Only the first segment (the actual
-- tool) is typically debuggable — FileCheck is just a test utility that we
-- skip in debug mode.
--
-- This function reuses the same match_run logic and picker UI as above.
-- ===========================================================================

-- @param cmd_str:    the full pipeline command string
-- @param source_buf: buffer handle of the test file (for RUN-line matching)
-- @param on_choice:  callback function(segment_index_or_nil)
local function pick_segment(cmd_str, source_buf, on_choice)
  local segments = commands.debuggable_segments(cmd_str)
  if #segments == 0 then
    on_choice(nil, 'no debuggable command in pipeline')
    return
  end
  if #segments == 1 then
    on_choice(1)
    return
  end

  -- Parse RUN lines (same logic as pick_command).
  local run_lines = {}
  local src = source_buf and vim.api.nvim_buf_is_valid(source_buf) and source_buf or vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  for _, line in ipairs(buf_lines) do
    local run_cmd = line:match('^%s*//%s*RUN:%s*(.+)$') or line:match('^%s*#%s*RUN:%s*(.+)$')
    if run_cmd then
      table.insert(run_lines, vim.trim(run_cmd))
    end
  end

  -- Scoring-based RUN-line matcher (same as pick_command).
  local function match_run(cmd)
    if #run_lines == 0 then
      return nil
    end
    local best_idx, best_score = nil, 0
    for i, rl in ipairs(run_lines) do
      local tokens = vim.split(rl, '%s+')
      local score = 0
      for j, tok in ipairs(tokens) do
        if j > 1 and tok ~= '%s' and tok ~= '%t' and tok ~= '%S' and
           tok ~= '|' and tok ~= '2>&1' and not tok:match('^[12]?>>?') then
          if cmd:find(tok, 1, true) then
            score = score + 1
          end
        end
      end
      if score > best_score then
        best_score = score
        best_idx = i
      end
    end
    if best_idx and best_score > 0 then
      return run_lines[best_idx]
    end
    return run_lines[1]
  end

  local items = {}
  for idx, seg in ipairs(segments) do
    table.insert(items, { idx = idx, seg = seg, run_line = match_run(seg) })
  end

  ui_select(items, 'llvm-lit: pipeline segment to debug', function(sel)
    if not sel then
      on_choice(nil, 'cancelled')
      return
    end
    on_choice(sel.idx)
  end)
end

-- ===========================================================================
-- PHASE 6: Orchestration — M.run()
-- ===========================================================================
-- This is the top-level entry point called by the user (via <leader>rd or
-- :LlitDebug). It:
--   1. Captures the current buffer (the test file) before launching lit.
--   2. Launches lit as a background job (via run.lua's run.run).
--   3. When lit finishes, parses the output for executed commands.
--   4. Shows the command picker → segment picker → launches the debugger.
-- ===========================================================================

-- @param opts: optional table to override defaults (e.g. { on_needs_setup })
function M.run(opts)
  opts = opts or {}
  -- IMPORTANT: Save the current buffer BEFORE running lit. After lit finishes,
  -- the current buffer may be the lit output window, not the test file.
  -- We need the test file to read // RUN: lines for the preview.
  local source_buf = vim.api.nvim_get_current_buf()

  return run.run(vim.tbl_extend('force', {
    collect_output = true,
    on_needs_setup = opts.on_needs_setup,
    on_complete = function(code, all_lines, info, buf)
      -- Try to parse executed commands from the collected output lines.
      local cmds = commands.parse_executed_commands(all_lines)
      -- If that didn't work (e.g. output was too large to collect), try
      -- reading from the output buffer directly.
      if #cmds == 0 and buf and vim.api.nvim_buf_is_valid(buf) then
        cmds = commands.parse_executed_commands(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
      end

      if #cmds == 0 then
        notify_err('no executed tool commands found in lit output (try lit_args = "-a" or "-vv")')
        return
      end

      vim.notify(
        string.format('[llvm-lit] debug: found %d command(s), pick one to debug', #cmds),
        vim.log.levels.INFO,
        { title = 'llvm-lit debug' }
      )

      -- Use vim.schedule because we're inside a libuv callback (from the
      -- job exit handler). Neovim's API requires that UI operations (like
      -- opening windows) happen on the main event loop, not in a libuv
      -- callback.
      vim.schedule(function()
        -- Step A: pick an executed command
        pick_command(cmds, source_buf, function(cmd_str, err)
          if not cmd_str then
            if err ~= 'cancelled' then
              notify_err(err)
            end
            return
          end

          -- Step B: if the command is a pipeline, pick a segment
          pick_segment(cmd_str, source_buf, function(seg, seg_err)
            if not seg then
              if seg_err ~= 'cancelled' then
                notify_err(seg_err)
              end
              return
            end

            -- Step C: launch the debugger
            M.launch(info, cmd_str, seg)

            -- If lit itself exited with a non-zero code, warn the user
            -- (but we still debug — the binary might work even if the
            -- test as a whole fails).
            if code ~= 0 then
              vim.notify(
                string.format('[llvm-lit] lit exited %d (debugging anyway)', code),
                vim.log.levels.WARN,
                { title = 'llvm-lit debug' }
              )
            end
          end)
        end)
      end)
    end,
  }, opts))
end

-- ===========================================================================
-- Highlight setup (called before launching debugger)
-- ===========================================================================
-- Most Neovim themes set the DapStopped sign with a very dim or transparent
-- background, making it hard to see which line the debugger paused on. This
-- function overrides that with a bright yellow background (by default) so
-- the stopped line is immediately visible.
--
-- The highlights are defined with the "force" flag so they survive theme
-- switches (e.g. if you run :colorscheme tokyonight after starting nvim).
-- ===========================================================================

-- @param dbg: optional debug config (auto-reads from config.options.debug)
function M.setup_highlights(dbg)
  dbg = dbg or config.options.debug or {}
  local hl = dbg.highlights
  if hl == false then
    return
  end
  hl = hl or {}

  -- Default: bright yellow background with dark text (works on most themes).
  local line = hl.current_line or { fg = '#1a1b26', bg = '#FFCC00', bold = true }
  local sign_hl = hl.stopped_sign_hl or 'LlvmLitDebugSign'

  vim.api.nvim_set_hl(0, 'LlvmLitDebugLine', vim.tbl_extend('force', { force = true }, line))
  vim.api.nvim_set_hl(0, 'LlvmLitDebugSign', {
    fg = line.bg or '#FFCC00',
    bg = line.fg or '#1a1b26',
    bold = true,
    force = true,
  })

  -- Redefine the DapStopped sign to use our bright highlights.
  vim.fn.sign_define('DapStopped', {
    text = hl.stopped_sign or '▶',
    texthl = sign_hl,
    linehl = 'LlvmLitDebugLine',
    numhl = 'LlvmLitDebugLine',
  })
end

return M
