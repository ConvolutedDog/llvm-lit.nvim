-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

local M = {}

local SKIP_TOOLS = {
  filecheck = true,
  cat = true,
  rm = true,
  echo = true,
  diff = true,
  cmp = true,
  grep = true,
  sed = true,
  awk = true,
  head = true,
  tail = true,
  wc = true,
  sort = true,
  tee = true,
  touch = true,
  mkdir = true,
  cp = true,
  mv = true,
  python = true,
  ['python3'] = true,
  ['sh'] = true,
  ['bash'] = true,
  ['env'] = true,
  ['true'] = true,
  ['false'] = true,
  [':'] = true,
  ['not'] = true,
}

--- Quote-aware split (no $VAR / backtick expansion).
function M.split_args(cmd)
  local args, cur, quote = {}, '', nil
  local i = 1
  while i <= #cmd do
    local c = cmd:sub(i, i)
    if quote then
      if c == quote then
        quote = nil
      else
        cur = cur .. c
      end
    elseif c == "'" or c == '"' then
      quote = c
    elseif c:match('%s') then
      if #cur > 0 then
        table.insert(args, cur)
        cur = ''
      end
    else
      cur = cur .. c
    end
    i = i + 1
  end
  if #cur > 0 then
    table.insert(args, cur)
  end
  return args
end

local function tool_basename(token)
  return (token:match('([^/]+)$') or token):lower()
end

function M.is_skipped_command(cmd_str)
  local trimmed = cmd_str:match('^%s*(.-)%s*$') or cmd_str
  if trimmed == '' then
    return true
  end
  -- lit no-op: : 'RUN: at line N'
  if trimmed:match("^:%s*'RUN:") or trimmed:match('^:%s*$') then
    return true
  end
  local parts = M.split_args(trimmed)
  if #parts == 0 then
    return true
  end
  local name = tool_basename(parts[1])
  return SKIP_TOOLS[name] == true
end

function M.split_pipeline(cmd_str)
  local segments = {}
  for seg in cmd_str:gmatch('[^|]+') do
    seg = seg:match('^%s*(.-)%s*$')
    -- Debug only the first command in && chains (cat %t/... etc. follow).
    seg = seg:match('^(.-)%s*&&') or seg
    if seg ~= '' and not M.is_skipped_command(seg) then
      table.insert(segments, seg)
    end
  end
  return segments
end

--- Strip ANSI SGR sequences (lit/terminal color codes).
local function strip_ansi(s)
  return (s:gsub('\27%[[0-9;]*m', ''))
end

local function normalize_line(line)
  if not line or line == '' then
    return ''
  end
  line = strip_ansi(line)
  return line:match('^%s*(.-)%s*$') or line
end

--- Parse lit verbose / bash xtrace output into standalone tool commands.
function M.parse_executed_commands(all_lines)
  local cmds = {}
  local seen = {}
  local function try_add(cmd_str)
    cmd_str = normalize_line(cmd_str)
    if cmd_str == '' or M.is_skipped_command(cmd_str) then
      return
    end
    if seen[cmd_str] then
      return
    end
    seen[cmd_str] = true
    table.insert(cmds, cmd_str)
  end

  local expect_expanded_run = false
  for _, raw in ipairs(all_lines or {}) do
    local line = normalize_line(raw)
    if line == '' or line == '--' then
      goto continue
    end

    local xtrace = line:match('^%+ (.+)$')
    if xtrace then
      try_add(xtrace)
      expect_expanded_run = false
      goto continue
    end

    local executed = line:match('^#%s*executed%s+command:%s*(.+)$')
    if executed then
      try_add(executed)
      expect_expanded_run = false
      goto continue
    end

    if line:match('^# RUN:') then
      expect_expanded_run = true
      goto continue
    end

    -- Expanded RUN line (substituted, before split into executed commands).
    if expect_expanded_run and line:match('^/') then
      try_add(line)
      expect_expanded_run = false
      goto continue
    end

    if expect_expanded_run and not line:match('^#') then
      expect_expanded_run = false
    end

    ::continue::
  end

  return cmds
end

function M.parse_launch_target(cmd_str, segment_idx)
  segment_idx = segment_idx or 1
  local segments = M.split_pipeline(cmd_str)
  if #segments == 0 then
    return nil, 'no debuggable command in pipeline'
  end
  if segment_idx < 1 or segment_idx > #segments then
    return nil, 'pipeline segment index out of range'
  end

  local seg = segments[segment_idx]
  local parts = M.split_args(seg)
  if #parts == 0 then
    return nil, 'empty command'
  end

  local program = parts[1]
  local args = {}
  for i = 2, #parts do
    table.insert(args, parts[i])
  end

  return {
    program = program,
    args = args,
    command = seg,
    segment = segment_idx,
    segments = #segments,
  }
end

function M.debuggable_segments(cmd_str)
  return M.split_pipeline(cmd_str)
end

function M.wrap_text(text, width)
  width = width or 80
  local lines = {}
  local pos = 1
  while pos <= #text do
    if #text - pos + 1 <= width then
      table.insert(lines, text:sub(pos))
      break
    end
    local chunk = text:sub(pos, pos + width - 1)
    local break_at = chunk:match('.*()%s')
    if not break_at or break_at < 2 then
      break_at = width
    end
    table.insert(lines, text:sub(pos, pos + break_at - 1):match('^%s*(.-)%s*$'))
    pos = pos + break_at
    while text:sub(pos, pos):match('%s') do
      pos = pos + 1
    end
  end
  return lines
end

local function wrap_path(arg, width, indent)
  indent = indent or '  '
  if #arg <= width then
    return { arg }
  end
  local lines = {}
  local pos = 1
  while pos <= #arg do
    local rest = arg:sub(pos)
    if #rest <= width then
      table.insert(lines, (#lines == 0) and rest or (indent .. rest))
      break
    end
    local chunk = rest:sub(1, width)
    local slash = chunk:match('.*()/')
    if slash and slash > 1 then
      local piece = rest:sub(1, slash)
      table.insert(lines, (#lines == 0) and piece or (indent .. piece))
      pos = pos + slash
    else
      local piece = rest:sub(1, width)
      table.insert(lines, (#lines == 0) and piece or (indent .. piece))
      pos = pos + width
    end
  end
  return lines
end

--- One shell token per line; paths wrap at `/`, other long tokens at spaces.
function M.cmd_display_lines(cmd, width)
  width = width or 88
  local args = M.split_args(cmd)
  if #args == 0 then
    return { cmd }
  end

  local lines = {}
  local cont_indent = '  '
  for _, arg in ipairs(args) do
    if #arg <= width then
      table.insert(lines, arg)
    elseif arg:find('/') then
      vim.list_extend(lines, wrap_path(arg, width, cont_indent))
    else
      local wrapped = M.wrap_text(arg, width)
      table.insert(lines, wrapped[1])
      for i = 2, #wrapped do
        table.insert(lines, cont_indent .. wrapped[i])
      end
    end
  end
  return lines
end

return M
