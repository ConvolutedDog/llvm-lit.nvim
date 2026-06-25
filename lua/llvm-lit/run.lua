-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local config = require('llvm-lit.config')
local project = require('llvm-lit.project')

local M = {}

local output_buf = nil  -- listed output buffer shown in bufferline

local function notify_err(msg)
  vim.notify('[llvm-lit] ' .. msg, vim.log.levels.ERROR, { title = 'llvm-lit' })
end

local function buf_alive(buf)
  return buf ~= nil
    and vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buflisted  -- false after :bd (unlist), so force fresh buffer
end

-- Write to a non-modifiable buffer via the API (toggle modifiable around the call).
local function buf_write(buf, start, end_, lines)
  if not buf_alive(buf) then return end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, start, end_, false, lines)
  vim.bo[buf].modifiable = false
end

local function open_output_buf(header)
  if buf_alive(output_buf) then
    buf_write(output_buf, 0, -1, { header, '' })
    vim.cmd('noautocmd buffer ' .. output_buf)
    return output_buf
  end

  local buf = vim.api.nvim_create_buf(true, true)  -- listed, scratch (nofile)
  pcall(vim.api.nvim_buf_set_name, buf, '[llvm-lit]')
  vim.bo[buf].bufhidden  = 'hide'
  vim.bo[buf].modifiable = false  -- read-only; written only via buf_write()

  buf_write(buf, 0, -1, { header, '' })
  -- Use noautocmd to prevent BufEnter/BufLeave handlers from interfering
  -- (e.g. bufferline, dashboard) and switching away from the output buffer.
  vim.cmd('noautocmd buffer ' .. buf)

  output_buf = buf

  -- Reset output_buf when the user closes this buffer any way (bd, bwipeout, etc.)
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

local function buf_append(buf, lines)
  if not buf_alive(buf) or #lines == 0 then return end
  local last = vim.api.nvim_buf_line_count(buf)
  buf_write(buf, last, last, lines)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == buf then
      pcall(vim.api.nvim_win_set_cursor, win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
  end
  vim.cmd('redraw')
end

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

function M.focus_output()
  if buf_alive(output_buf) then
    vim.api.nvim_set_current_buf(output_buf)
  else
    vim.notify('[llvm-lit] No output buffer yet; run the test first',
      vim.log.levels.WARN, { title = 'llvm-lit' })
  end
end

function M.run(opts)
  opts = opts or {}

  local info, err = project.resolve(opts.bufnr)
  if not info then
    notify_err(err)
    if opts.on_needs_setup and type(err) == 'string' and err:find('LlvmLitSetup') then
      opts.on_needs_setup()
    end
    return false
  end

  local ok_lit, lit_err = check_llvm_lit()
  if not ok_lit then
    notify_err(lit_err)
    return false
  end

  local cmd = M.build_command(info, opts)
  local header = string.format('%s | filter=%s | suite=%s',
    info.project.name or info.project_root,
    info.filter,
    info.lit_testsuite)

  vim.notify('[llvm-lit] ' .. header, vim.log.levels.INFO, { title = 'llvm-lit' })

  local buf = open_output_buf(header)

  -- Neovim's non-buffered jobstart may split a single long line across multiple
  -- on_stdout calls.  The last element of each `data` array is either '' (line
  -- ended with \n) or a partial line to be joined with the next chunk.
  -- `collect` is an optional table; complete lines are appended to it too.
  local function make_handler(pending_ref, collect)
    return vim.schedule_wrap(function(_, data)
      if not data or #data == 0 then return end
      data[1] = pending_ref[1] .. (data[1] or '')
      pending_ref[1] = table.remove(data) or ''  -- last element = new partial line (or '' on EOF)
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
  -- Collect all output lines (stdout + stderr) so we can parse the bash trace
  -- for the opt command.  lit writes the "+ ..." xtrace lines into its stdout
  -- (under "Command Output (stderr):") when running with -a.
  local all_lines = opts.dump_input and {} or nil

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

      -- In dump mode: collect every executed command that isn't FileCheck and
      -- re-run each one standalone to show the properly formatted opt output.
      -- Multiple RUN lines each produce their own entry.
      --
      -- Two lit output formats are handled:
      --   bash xtrace  : "+ <cmd>"          (CIRCT and similar projects)
      --   lit verbose  : "# executed command: <cmd>"  (MLIR / llvm-project)
      if opts.dump_input and all_lines then
        local opt_cmds = {}
        local seen = {}
        local function try_add(cmd_str)
          if not cmd_str:lower():match('filecheck') and not seen[cmd_str] then
            seen[cmd_str] = true
            table.insert(opt_cmds, cmd_str)
          end
        end
        for _, line in ipairs(all_lines) do
          if line:match('^%+ ') then
            try_add(line:sub(3))
          elseif line:match('^# executed command: ') then
            try_add(line:sub(21))
          end
        end

        if #opt_cmds > 0 and buf_alive(buf) then
          -- Run all opt commands sequentially, chaining via on_exit callbacks.
          local function run_next(idx)
            if idx > #opt_cmds or not buf_alive(buf) then
              vim.notify(string.format('[llvm-lit] exit %d — %s', code, info.filter), level)
              return
            end
            local c = opt_cmds[idx]
            local title = #opt_cmds > 1
              and string.format('  Standalone Output  %d / %d', idx, #opt_cmds)
              or  '  Standalone Output'
            -- Wrap long commands by whole tokens (space-separated) so paths are
            -- never split mid-word.  Each continuation line is indented by 4 spaces.
            local first_prefix = '  $ '
            local cont_prefix  = '      '  -- aligns with the first token after "$ "
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
          return  -- defer notify until all opt jobs finish
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
