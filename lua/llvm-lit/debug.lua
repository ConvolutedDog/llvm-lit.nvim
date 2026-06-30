-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local commands = require('llvm-lit.commands')
local config = require('llvm-lit.config')
local run = require('llvm-lit.run')

local M = {}

local codelldb_proc = nil -- uv process handle when we start codelldb ourselves
local unpack = table.unpack or unpack

local function notify_err(msg)
  vim.notify('[llvm-lit] ' .. msg, vim.log.levels.ERROR, { title = 'llvm-lit debug' })
end

local function require_dap()
  local ok, dap = pcall(require, 'dap')
  if not ok then
    return nil, 'nvim-dap is not installed; see README § Debugging'
  end
  return dap
end

local function find_codelldb_executable()
  local data = vim.fn.stdpath('data')
  local pkg = data .. '/mason/packages/codelldb'
  -- Prefer the real adapter binary over Mason's bash wrapper.
  local adapter = pkg .. '/extension/adapter/codelldb'
  if vim.fn.executable(adapter) == 1 then
    return adapter
  end

  local cmd = vim.fn.exepath('codelldb')
  if cmd ~= '' and vim.fn.executable(cmd) == 1 then
    return cmd
  end

  for _, candidate in ipairs({
    pkg .. '/codelldb',
    data .. '/mason/bin/codelldb',
  }) do
    if vim.fn.executable(candidate) == 1 then
      return candidate
    end
  end

  if vim.fn.isdirectory(pkg) == 1 then
    return nil, 'codelldb is still installing in Mason (:Mason); wait until it moves to Installed, then restart nvim'
  end

  return nil, 'codelldb not found; run :MasonInstall codelldb then restart nvim'
end

local function get_free_port()
  local uv = vim.loop or vim.uv
  local sock = assert(uv.new_tcp())
  sock:bind('127.0.0.1', 0)
  local port = sock:getsockname().port
  sock:close()
  return port
end

local function stop_codelldb_server()
  if codelldb_proc and not codelldb_proc:is_closing() then
    pcall(function()
      codelldb_proc:kill('sigterm')
    end)
  end
  codelldb_proc = nil
end

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

--- Start codelldb and point nvim-dap at it (lsof wait; no TCP probe).
local function start_codelldb_server(dap)
  stop_codelldb_server()

  local cmd, err = find_codelldb_executable()
  if not cmd then
    return false, err
  end

  local port = get_free_port()
  local uv = vim.loop or vim.uv
  local pkg = vim.fn.stdpath('data') .. '/mason/packages/codelldb'
  local env = nil
  if vim.fn.has('macunix') == 1 then
    env = {
      DYLD_LIBRARY_PATH = pkg .. '/extension/lldb/lib',
    }
  end

  local handle, pid_or_err = uv.spawn(cmd, {
    stdio = { nil, nil, nil },
    args = { '--port', tostring(port) },
    cwd = vim.fs.dirname(cmd),
    env = env,
    detached = false,
    hide = true,
  }, function(code)
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

  if not wait_for_listen(port, 15000) then
    stop_codelldb_server()
    return false, 'codelldb did not start listening (try :MasonInstall codelldb, then restart nvim)'
  end

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

local function resolve_dap_type(dap, dbg)
  dbg = dbg or {}
  local preferred = dbg.dap_type

  if preferred == 'codelldb' or preferred == nil or preferred == '' then
    local cmd, err = find_codelldb_executable()
    if cmd then
      return 'codelldb'
    end
    return nil, err
  elseif preferred and dap.adapters[preferred] then
    return preferred
  end

  if dap.adapters.lldb then
    return 'lldb'
  end

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

local LIST_LABEL_MAX = 88

local PICK_WINHL = 'NormalFloat:NormalFloat,FloatBorder:FloatBorder,CursorLine:Visual'

local function list_label(idx, cmd, count, bracket, max_len)
  max_len = max_len or LIST_LABEL_MAX
  local truncated = (#cmd > max_len) and (cmd:sub(1, max_len - 3) .. '...') or cmd
  local w = math.max(#tostring(count), 1)
  local num
  if bracket then
    num = string.format('[%' .. w .. 'd]', idx)
  else
    num = string.format('%' .. w .. 'd.', idx)
  end
  return '  ' .. num .. '  ' .. truncated
end

local function highlight_left_indices(buf, count)
  local ns = vim.api.nvim_create_namespace('llvm_lit_debug_pick')
  local idx_hl = 'SnacksPickerIdx'
  if vim.fn.hlexists(idx_hl) == 0 then
    idx_hl = 'Comment'
  end
  for i = 1, count do
    local line = vim.api.nvim_buf_get_lines(buf, i - 1, i, false)[1] or ''
    -- match "  [N]" or "  N." after the 2-space indent
    local prefix = line:match('^(%s*%[%d+%])') or line:match('^(%s*%d+%.)')
    if prefix then
      vim.api.nvim_buf_set_extmark(buf, ns, i - 1, 0, {
        end_col = #prefix,
        hl_group = idx_hl,
      })
    end
  end
end

local function pick_title(prompt)
  return prompt:gsub('^%s*', ''):gsub('[%s:]*$', ''):gsub('^llvm%-lit:%s*', '')
end

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

--- Two centered windows: left picker + right preview (same width, taller).
local function pick_split_window(items, prompt, on_choice)
  local count = #items
  local gap = 3
  local pad = 4 -- minimum margin from editor edge

  local list_w = math.min(80, math.max(52, math.floor(vim.o.columns * 0.36)))
  local label_max = list_w - 12
  -- list height: items + separator + hint, capped
  local list_h = math.min(count + 2, math.min(20, vim.o.lines - pad * 2))

  local preview_w = list_w
  if vim.o.columns - list_w - gap - pad * 2 < list_w + pad then
    preview_w = 0 -- not enough room
  end

  local total_w = list_w + (preview_w > 0 and (gap + preview_w) or 0)
  local preview_h = math.min(18, vim.o.lines - pad * 2)
  local preview_row = math.max(pad, math.floor((vim.o.lines - preview_h) / 2))
  local list_col = math.max(pad, math.floor((vim.o.columns - total_w) / 2))
  local title = pick_title(prompt)

  -- vertical: center list inside preview
  local list_row = preview_row + math.floor((preview_h - list_h) / 2)

  -- ---- list buffer ----
  local list_lines = vim.tbl_map(function(it)
    local cmd = it.cmd or it.seg or ''
    return list_label(it.idx, cmd, count, it.seg ~= nil, label_max)
  end, items)
  table.insert(list_lines, '')
  table.insert(list_lines, '  ⏎ confirm   esc / q cancel')

  local list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(list_buf, 0, -1, false, list_lines)
  vim.bo[list_buf].modifiable = false
  vim.bo[list_buf].bufhidden = 'wipe'
  highlight_left_indices(list_buf, count)

  -- ---- preview buffer ----
  local preview_buf = nil
  if preview_w > 0 then
    preview_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[preview_buf].buftype = 'nofile'
    vim.bo[preview_buf].bufhidden = 'wipe'
    vim.bo[preview_buf].modifiable = false
  end

  local closed = false
  local list_win, preview_win
  local prev_win = vim.api.nvim_get_current_win()

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

  -- ---- open windows ----
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
    -- soft wrap with breakindent for readability
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

  local group = vim.api.nvim_create_augroup('LlvmLitDebugPick', { clear = true })

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
    -- command section
    local disp = cmd:gsub('%s*|%s*', '  │  ')
    vim.list_extend(lines, vim.split(disp, '\n'))

    -- separator + RUN line
    if run_line and #run_line > 0 then
      table.insert(lines, '')
      table.insert(lines, string.rep('─', preview_w > 0 and preview_w - 2 or 60))
      table.insert(lines, 'RUN: ' .. run_line)
    end

    vim.bo[preview_buf].modifiable = true
    vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, lines)
    vim.bo[preview_buf].modifiable = false
    if vim.api.nvim_win_is_valid(preview_win) then
      pcall(vim.api.nvim_win_set_cursor, preview_win, { 1, 0 })
    end
  end

  show_preview()

  vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
    group = group,
    buffer = list_buf,
    callback = show_preview,
  })

  local function finish(item)
    if closed then
      return
    end
    close_all()
    vim.api.nvim_del_augroup_by_id(group)
    vim.schedule(function()
      on_choice(item)
    end)
  end

  -- cancel when focus leaves the picker
  vim.api.nvim_create_autocmd('BufLeave', {
    group = group,
    buffer = list_buf,
    callback = function()
      finish(nil)
    end,
  })

  local function confirm()
    local lnum = vim.api.nvim_win_get_cursor(list_win)[1]
    local item = items[lnum]
    if not item then
      return
    end
    finish(item)
  end

  -- cyclic j/k: wrap at list boundaries, skip separator + hint
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

local function to_source_map(cfg)
  if not cfg or vim.tbl_isempty(cfg) then
    return nil
  end
  -- codelldb expects a map { "/from/path" = "/to/path" }, not an array of pairs.
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

local function shell_quote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

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

local function delete_err_is_benign(err)
  if not err then
    return false
  end
  local msg = tostring(err.message or err)
  return msg:find('no breakpoints exist', 1, true) ~= nil
end

--- codelldb DAP setBreakpoints often fails on static LLVM tools (Resolved locations: 0).
--- Sync nvim-dap signs via native LLDB commands instead (two evaluate calls; one chain fails).
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

local function install_session_listeners(dap, dap_cfg, dbg, dap_type)
  local stop_on_entry = dbg.stop_on_entry ~= false
  local use_lldb_sync = dap_type == 'codelldb'

  dap.listeners.after.event_stopped['llvm_lit_debug'] = function(session, body)
    if not session.config or session.config.name ~= dap_cfg.name then
      return
    end
    if use_lldb_sync then
      hook_continue_sync(session, dap_cfg, dbg)
      -- Breakpoints sync on continue only (entry sync duplicates lldb bps).
    end
  end

  dap.listeners.after.event_terminated['llvm_lit_debug'] = function(session)
    if not session.config or session.config.name ~= dap_cfg.name then
      return
    end
    dap.listeners.after.event_stopped['llvm_lit_debug'] = nil
    dap.listeners.after.event_exited['llvm_lit_debug'] = nil
    dap.listeners.after.event_terminated['llvm_lit_debug'] = nil
  end

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
    if code == 0 and count_breakpoints() > 0 and use_lldb_sync then
      vim.notify(
        '[llvm-lit] circt-opt exited without hitting breakpoints. '
          .. 'Check the pass runs for this test (e.g. -export-verilog → ExportVerilogPass ~7346, '
          .. 'not ExportSplitVerilogPass ~7525)',
        vim.log.levels.WARN,
        { title = 'llvm-lit debug' }
      )
    elseif code == 0 and count_breakpoints() == 0 and not stop_on_entry then
      vim.notify(
        '[llvm-lit] no breakpoints were set; circt-opt finished instantly. '
          .. 'Set breakpoints in C++ source (<leader>db) or keep stop_on_entry = true',
        vim.log.levels.WARN,
        { title = 'llvm-lit debug' }
      )
    end
  end
end

function M.launch(info, cmd_str, segment_idx)
  local dap, dap_err = require_dap()
  if not dap then
    notify_err(dap_err)
    return false
  end
  M.setup_highlights()

  local target, err = commands.parse_launch_target(cmd_str, segment_idx)
  if not target then
    notify_err(err)
    return false
  end

  if vim.fn.filereadable(target.program) ~= 1 and vim.fn.executable(target.program) ~= 1 then
    notify_err('program not found or not executable: ' .. target.program)
    return false
  end

  local dbg = config.options.debug or {}
  local dap_type, type_err = resolve_dap_type(dap, dbg)
  if not dap_type then
    notify_err(type_err)
    return false
  end

  if dap_type == 'codelldb' then
    local ok, start_err = start_codelldb_server(dap)
    if not ok then
      notify_err(start_err)
      return false
    end
  end

  local stop_on_entry = dbg.stop_on_entry ~= false
  local nbp = count_breakpoints()
  if nbp == 0 and not stop_on_entry then
    vim.notify(
      '[llvm-lit] no breakpoints set; circt-opt may exit immediately after launch',
      vim.log.levels.WARN,
      { title = 'llvm-lit debug' }
    )
  end

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

  vim.notify(
    string.format('[llvm-lit] debug: %s %s', target.program, table.concat(target.args, ' ')),
    vim.log.levels.INFO,
    { title = 'llvm-lit debug' }
  )

  install_session_listeners(dap, dap_cfg, dbg, dap_type)
  dap.run(dap_cfg, { filetype = dbg.filetype or 'cpp' })
  return true
end

local function pick_command(cmds, source_buf, on_choice)
  if #cmds == 0 then
    on_choice(nil, 'no executed tool commands found in lit output (try lit_args = "-a" or "-vv")')
    return
  end

  -- Parse # RUN: or // RUN: lines from the test buffer for matching
  local run_lines = {}
  local src = source_buf and vim.api.nvim_buf_is_valid(source_buf) and source_buf or vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  for _, line in ipairs(buf_lines) do
    local run_cmd = line:match('^%s*//%s*RUN:%s*(.+)$') or line:match('^%s*#%s*RUN:%s*(.+)$')
    if run_cmd then
      table.insert(run_lines, vim.trim(run_cmd))
    end
  end

  local function match_run(cmd)
    if #run_lines == 0 then
      return nil
    end
    -- Score each RUN line by how many of its distinctive tokens (flags, not %s) appear in cmd
    local best_idx, best_score = nil, 0
    for i, rl in ipairs(run_lines) do
      local tokens = vim.split(rl, '%s+')
      local score = 0
      for j, tok in ipairs(tokens) do
        -- skip program name, lit placeholders, and redirection
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

  -- Match RUN line from test buffer
  local run_lines = {}
  local src = source_buf and vim.api.nvim_buf_is_valid(source_buf) and source_buf or vim.api.nvim_get_current_buf()
  local buf_lines = vim.api.nvim_buf_get_lines(src, 0, -1, false)
  for _, line in ipairs(buf_lines) do
    local run_cmd = line:match('^%s*//%s*RUN:%s*(.+)$') or line:match('^%s*#%s*RUN:%s*(.+)$')
    if run_cmd then
      table.insert(run_lines, vim.trim(run_cmd))
    end
  end

  local function match_run(cmd)
    if #run_lines == 0 then
      return nil
    end
    -- Score each RUN line by how many of its distinctive tokens (flags, not %s) appear in cmd
    local best_idx, best_score = nil, 0
    for i, rl in ipairs(run_lines) do
      local tokens = vim.split(rl, '%s+')
      local score = 0
      for j, tok in ipairs(tokens) do
        -- skip program name, lit placeholders, and redirection
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

function M.run(opts)
  opts = opts or {}
  local source_buf = vim.api.nvim_get_current_buf() -- test file buffer

  return run.run(vim.tbl_extend('force', {
    collect_output = true,
    on_needs_setup = opts.on_needs_setup,
    on_complete = function(code, all_lines, info, buf)
      local cmds = commands.parse_executed_commands(all_lines)
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

      vim.schedule(function()
        pick_command(cmds, source_buf, function(cmd_str, err)
          if not cmd_str then
            if err ~= 'cancelled' then
              notify_err(err)
            end
            return
          end

          pick_segment(cmd_str, source_buf, function(seg, seg_err)
            if not seg then
              if seg_err ~= 'cancelled' then
                notify_err(seg_err)
              end
              return
            end

            M.launch(info, cmd_str, seg)

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

--- Brighter nvim-dap stopped-line indicator (Tokyo Night etc. override faint debugPC).
function M.setup_highlights(dbg)
  dbg = dbg or config.options.debug or {}
  local hl = dbg.highlights
  if hl == false then
    return
  end
  hl = hl or {}

  local line = hl.current_line or { fg = '#1a1b26', bg = '#FFCC00', bold = true }
  local sign_hl = hl.stopped_sign_hl or 'LlvmLitDebugSign'

  -- Own groups so colorschemes do not replace with transparent debugPC.
  vim.api.nvim_set_hl(0, 'LlvmLitDebugLine', vim.tbl_extend('force', { force = true }, line))
  vim.api.nvim_set_hl(0, 'LlvmLitDebugSign', {
    fg = line.bg or '#FFCC00',
    bg = line.fg or '#1a1b26',
    bold = true,
    force = true,
  })

  vim.fn.sign_define('DapStopped', {
    text = hl.stopped_sign or '▶',
    texthl = sign_hl,
    linehl = 'LlvmLitDebugLine',
    numhl = 'LlvmLitDebugLine',
  })
end

return M
