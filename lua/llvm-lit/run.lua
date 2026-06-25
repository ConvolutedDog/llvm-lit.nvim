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
    vim.api.nvim_set_current_buf(output_buf)
    return output_buf
  end

  local buf = vim.api.nvim_create_buf(true, true)  -- listed, scratch (nofile)
  pcall(vim.api.nvim_buf_set_name, buf, '[llvm-lit]')
  vim.bo[buf].filetype   = 'llvm-lit'
  vim.bo[buf].bufhidden  = 'hide'
  vim.bo[buf].modifiable = false  -- read-only; written only via buf_write()

  buf_write(buf, 0, -1, { header, '' })
  vim.api.nvim_set_current_buf(buf)

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
  local function make_handler(pending_ref)
    return vim.schedule_wrap(function(_, data)
      if not data then return end
      data[1] = pending_ref[1] .. data[1]   -- prepend any leftover from last chunk
      pending_ref[1] = table.remove(data)   -- last element = new partial line
      if #data > 0 then buf_append(buf, data) end
    end)
  end

  local out_pending = { '' }
  local err_pending = { '' }

  local job = vim.fn.jobstart({ 'bash', '-c', cmd }, {
    cwd = info.cwd,
    env = { PYTHONUNBUFFERED = '1', COLORTERM = 'truecolor' },
    on_stdout = make_handler(out_pending),
    on_stderr = make_handler(err_pending),
    on_exit = vim.schedule_wrap(function(_, code)
      -- Flush any remaining partial lines.
      if out_pending[1] ~= '' then buf_append(buf, { out_pending[1] }) end
      if err_pending[1] ~= '' then buf_append(buf, { err_pending[1] }) end
      local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
      vim.notify(string.format('[llvm-lit] exit %d — %s', code, info.filter), level)
    end),
  })

  if job <= 0 then
    notify_err('failed to start job (code ' .. job .. '): ' .. cmd)
  end

  return true
end

return M
