-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- lua/llvm-lit/run.lua — Execute lit and display output
-- =============================================================================
-- This is the core execution engine. Given a resolved project info table
-- (from project.resolve()), it:
--
--   1. Builds a shell command: cd <cwd> && llvm-lit -a <suite> --filter <path>
--   2. Opens (or reuses) an output buffer named "[llvm-lit]".
--   3. Spawns the command as a Neovim job (jobstart) with stdout + stderr
--      streaming into the output buffer in real time.
--   4. Handles partial-line buffering (jobs deliver data in chunks that may
--      split a line at any character).
--   5. If dump_input is enabled, additionally parses the executed commands
--      from the output and re-runs each one standalone (without FileCheck)
--      so you can see the tool's raw output.
--   6. Notifies on exit and provides the output buffer for further inspection.
--
-- The output buffer persists across runs (reused on each :LlvmLitRun) and
-- can be focused with <leader>ro or :LlvmLitFocusOutput.
--
-- Key design decisions:
--   • The shell command is wrapped in 'bash -c' so that FILECHECK_OPTS env
--     var and the cd && chain work correctly on all platforms.
--   • Lines are written via buf_write(), which temporarily toggles 'modifiable'
--     on the buffer (since it's marked as read-only for user interaction).
--   • The make_handler() closure handles Neovim's streaming output, joining
--     partial lines (a line ending in \n produces '' as its last element,
--     which we use as a splice marker).
-- =============================================================================

local commands = require('llvm-lit.commands')
local config   = require('llvm-lit.config')
local project  = require('llvm-lit.project')

local M = {}

-- The single output buffer instance. We reuse it across runs rather than
-- creating a new buffer each time.
local output_buf = nil

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function notify_err(msg)
  vim.notify('[llvm-lit] ' .. msg, vim.log.levels.ERROR, { title = 'llvm-lit' })
end

--- Check if a buffer is still alive (exists, valid, and still listed).
-- We check buflisted because :bd (bdelete) sets it to false, which is the
-- user's way of saying "I'm done with this buffer".
local function buf_alive(buf)
  return buf ~= nil
    and vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buflisted
end

--- Write lines to a read-only buffer via the API.
-- The buffer has 'modifiable' set to false for user safety, so we toggle it
-- on temporarily for the API call.
local function buf_write(buf, start, end_, lines)
  if not buf_alive(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, end_, false, lines)
  vim.bo[buf].modifiable = false
end

--- Open (or reuse) the output buffer and write the initial header line.
-- The buffer is listed so it appears in bufferline / :ls.
local function open_output_buf(header)
  if buf_alive(output_buf) then
    buf_write(output_buf, 0, -1, { header, '' })
    vim.cmd('noautocmd buffer ' .. output_buf)
    return output_buf
  end

  local buf = vim.api.nvim_create_buf(true, true)  -- listed, scratch (nofile)
  pcall(vim.api.nvim_buf_set_name, buf, '[llvm-lit]')
  vim.bo[buf].bufhidden  = 'hide'
  vim.bo[buf].modifiable = false  -- written only via buf_write()

  buf_write(buf, 0, -1, { header, '' })
  vim.cmd('noautocmd buffer ' .. buf)

  output_buf = buf

  -- Reset the global when the user closes this buffer.
  vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
    buffer   = buf,
    once     = true,
    callback = function()
      if output_buf == buf then
        output_buf = nil
      end
    end,
  })

  return buf
end

--- Append lines to the end of a buffer and scroll the window to the bottom.
local function buf_append(buf, lines)
  if not buf_alive(buf) or #lines == 0 then return end
  local last = vim.api.nvim_buf_line_count(buf)
  buf_write(buf, last, last, lines)
  -- Scroll any window displaying this buffer to the end.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
  vim.cmd('redraw')
end

--- Verify that the llvm-lit binary is available.
-- If the configured path contains '/', we check vim.fn.filereadable.
-- Otherwise we check vim.fn.executable (which searches $PATH).
local function check_llvm_lit()
  local bin = config.options.llvm_lit
  if bin:match('/') then
    if vim.fn.filereadable(bin) ~= 1 then
      return false, 'llvm-lit not found: ' .. bin
    end
    return true
  end
  if vim.fn.executable(bin) ~= 1 then
    return false, 'llvm-lit is not in PATH; set llvm_lit to an absolute path in setup()'
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Build the shell command string from a resolved info table.
-- The command looks like:
--   cd <cwd> && [FILECHECK_OPTS=...] llvm-lit -a <suite> --filter <pattern>
--
-- @param info: resolved project info (from project.resolve())
-- @param opts: { dump_input? } — if true, prepends FILECHECK_OPTS
-- @return:     the concatenated bash command string
function M.build_command(info, opts)
  opts = opts or {}
  local parts = { 'cd', vim.fn.shellescape(info.cwd), '&&' }

  if opts.dump_input then
    table.insert(parts, 'FILECHECK_OPTS=' .. vim.fn.shellescape(config.options.filecheck_opts))
  end

  table.insert(parts, config.options.llvm_lit)
  for _, arg in ipairs(vim.split(config.options.lit_args, '%s+')) do
    if arg ~= '' then
      table.insert(parts, vim.fn.shellescape(arg))
    end
  end
  table.insert(parts, vim.fn.shellescape(info.lit_testsuite))
  table.insert(parts, '--filter')
  table.insert(parts, vim.fn.shellescape(info.filter))

  return table.concat(parts, ' ')
end

--- Switch to the output buffer (if it still exists).
-- Bound to <leader>ro by default.
function M.focus_output()
  if buf_alive(output_buf) then
    vim.api.nvim_set_current_buf(output_buf)
  else
    vim.notify('[llvm-lit] No output buffer yet; run the test first',
      vim.log.levels.WARN, { title = 'llvm-lit' })
  end
end

--- Run lit and stream the output into the output buffer.
--
-- This is the main entry point called by init.lua's M.run() and M.run_dump().
--
-- Flow:
--   1. Resolve the project configuration for the current buffer.
--   2. Verify llvm-lit is reachable.
--   3. Build the shell command.
--   4. Open the output buffer.
--   5. Start jobstart('bash -c <cmd>') with stdout/stderr handlers.
--   6. On exit, optionally parse executed commands and re-run each one
--      standalone (for dump_input mode), then notify the result.
--
-- @param opts: { bufnr, dump_input, on_needs_setup, on_complete, collect_output? }
-- @return:     true on success (job launched), nil on error
function M.run(opts)
  opts = opts or {}

  -- Step 1: Resolve project info.
  local info, err = project.resolve(opts.bufnr)
  if not info then
    notify_err(err)
    -- If the error suggested :LlvmLitSetup, invoke the setup callback.
    if opts.on_needs_setup and type(err) == 'string' and err:find('LlvmLitSetup') then
      opts.on_needs_setup()
    end
    return false
  end

  -- Step 2: Verify llvm-lit binary.
  local ok_lit, lit_err = check_llvm_lit()
  if not ok_lit then
    notify_err(lit_err)
    return false
  end

  -- Step 3: Build the shell command.
  local cmd = M.build_command(info, opts)
  local header = string.format('%s | filter=%s | suite=%s',
    info.project.name or info.project_root,
    info.filter,
    info.lit_testsuite)

  vim.notify('[llvm-lit] ' .. header, vim.log.levels.INFO, { title = 'llvm-lit' })

  -- Step 4: Open (or reuse) the output buffer.
  local buf = open_output_buf(header)

  -- Step 5: Set up the job handlers.
  --
  -- Neovim's jobstart (non-buffered mode) splits long output lines across
  -- multiple on_stdout callbacks. Each data array has this structure:
  --   ["line1", "line2", ..., "lineN"]  or  ["line1", "line2", ..., ""]
  -- The last element is "" when the chunk ends with \n (i.e., the last line
  -- is complete). If it's non-empty, that's a partial line that continues
  -- in the next callback.
  --
  -- Our handler:
  --   1. Prepends the pending (partial) line from the previous callback.
  --   2. Pops the last element as the new pending (or '' if complete).
  --   3. Writes complete lines to the buffer.
  --   4. If collect is set, also appends to an all_lines table for parsing.
  local function make_handler(pending_ref, collect)
    return vim.schedule_wrap(function(_, data)
      if not data or #data == 0 then return end
      data[1] = pending_ref[1] .. (data[1] or '')
      pending_ref[1] = table.remove(data) or ''
      if #data > 0 then
        buf_append(buf, data)
        if collect then
          for _, line in ipairs(data) do table.insert(collect, line) end
        end
      end
    end)
  end

  local out_pending = { '' }
  local err_pending = { '' }
  -- Collect all output for parsing executed commands.
  -- lit writes "+ ..." (bash xtrace) or "# executed command: ...".
  local collect = opts.dump_input or opts.collect_output
  local all_lines = collect and {} or nil

  local job = vim.fn.jobstart({ 'bash', '-c', cmd }, {
    cwd = info.cwd,
    env = { PYTHONUNBUFFERED = '1', COLORTERM = 'truecolor' },
    on_stdout = make_handler(out_pending, all_lines),
    on_stderr = make_handler(err_pending, all_lines),
    on_exit = vim.schedule_wrap(function(_, code)
      -- Flush any remaining partial lines.
      if out_pending[1] ~= '' then
        buf_append(buf, { out_pending[1] })
        if all_lines then table.insert(all_lines, out_pending[1]) end
      end
      if err_pending[1] ~= '' then
        buf_append(buf, { err_pending[1] })
        if all_lines then table.insert(all_lines, err_pending[1]) end
      end

      local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR

      -- Step 6: If on_complete callback is provided, invoke it with the
      -- collected output (used by debug.lua to show the picker).
      if opts.on_complete and all_lines then
        opts.on_complete(code, all_lines, info, buf)
      end

      -- Step 6b: If dump_input mode, parse executed commands and re-run
      -- each one standalone (without FileCheck) so the user sees raw output.
      if opts.dump_input and all_lines then
        local opt_cmds = commands.parse_executed_commands(all_lines)

        if #opt_cmds > 0 and buf_alive(buf) then
          -- Run all opt commands sequentially, chaining via on_exit.
          local function run_next(idx)
            if idx > #opt_cmds or not buf_alive(buf) then
              vim.notify(string.format('[llvm-lit] exit %d — %s', code, info.filter), level)
              return
            end
            local c = opt_cmds[idx]
            local title = #opt_cmds > 1
              and string.format('  Standalone Output  %d / %d', idx, #opt_cmds)
              or  '  Standalone Output'
            -- Pretty-print the command with word wrapping.
            local first_prefix = '  $ '
            local cont_prefix  = '      '
            local wrap = 72
            local cmd_lines = {}
            local tokens = vim.split(c, ' ')
            local cur = first_prefix .. tokens[1]
            for i = 2, #tokens do
              local tok = tokens[i]
              if #cur + 1 + #tok <= wrap then
                cur = cur .. ' ' .. tok
              else
                table.insert(cmd_lines, cur)
                cur = cont_prefix .. tok
              end
            end
            table.insert(cmd_lines, cur)

            local header_lines = {
              '',
              string.rep('─', 72),
              title,
            }
            for _, l in ipairs(cmd_lines) do table.insert(header_lines, l) end
            table.insert(header_lines, '  NOTE: FileCheck removed from the RUN pipeline; not all scenarios')
            table.insert(header_lines, '        are covered. Refer to the full lit output above for details.')
            table.insert(header_lines, string.rep('─', 72))
            table.insert(header_lines, '')
            buf_append(buf, header_lines)
            local op = { '' }
            local ep = { '' }
            vim.fn.jobstart({ 'bash', '-c', c }, {
              cwd = info.cwd,
              env = { PYTHONUNBUFFERED = '1' },
              on_stdout = make_handler(op),
              on_stderr = make_handler(ep),
              on_exit = vim.schedule_wrap(function(_, _)
                if op[1] ~= '' then buf_append(buf, { op[1] }) end
                if ep[1] ~= '' then buf_append(buf, { ep[1] }) end
                run_next(idx + 1)
              end),
            })
          end
          run_next(1)
          return  -- defer notify until all standalone jobs finish
        end
      end

      vim.notify(string.format('[llvm-lit] exit %d — %s', code, info.filter), level)
    end),
  })

  if job <= 0 then
    notify_err('failed to start job (code ' .. job .. '): ' .. cmd)
  end

  return true
end

return M
