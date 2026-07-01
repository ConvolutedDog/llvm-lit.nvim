-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- lua/llvm-lit/commands.lua — Lit output parsing and command manipulation
-- =============================================================================
-- This module is a pure-Lua utility library with NO Neovim UI dependencies.
-- It can be tested headlessly (see test/test_commands.lua). Its jobs are:
--
--   1. Quote-aware command-line splitting (split_args).
--   2. Recognizing and filtering out "skipped" tools (is_skipped_command)
--      that are not debuggable (FileCheck, cat, echo, etc.).
--   3. Splitting shell pipelines into segments (split_pipeline).
--   4. Parsing lit's two output formats (bash xtrace "+ ..." and lit's own
--      "# executed command: ...") into a clean list of tool commands
--      (parse_executed_commands).
--   5. Extracting the tool program and arguments for DAP launch
--      (parse_launch_target).
--   6. Pretty-printing commands for the preview window (cmd_display_lines).
--
-- Why the skip list matters:
--   When lit runs a test like:
--     // RUN: circt-opt %s -opt | FileCheck %s
--   It executes TWO commands: the tool (circt-opt, mlir-opt, toyc-ch7, …)
--   AND FileCheck. Only the tool is debuggable (FileCheck just reads stdin
--   and checks patterns). So we filter FileCheck out, leaving only the
--   tool command for the user to pick.
-- =============================================================================

local M = {}

-- ---------------------------------------------------------------------------
-- Tool skip list
-- ---------------------------------------------------------------------------
-- Tools listed here are recognized by their basename (lowercased). When
-- splitting pipelines or parsing lit output, commands whose first token
-- matches any of these are discarded. They are either:
--   • Test infrastructure (FileCheck, not, diff, grep, sed, ...)
--   • Shell built-ins / utilities (cat, echo, rm, true, false, ...)
--   • lit no-ops (: 'RUN: at line N')
--
-- The user should only ever debug the actual compiler/optimizer tool, not
-- the test harness around it.
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
  [':'] = true,    -- shell no-op
  ['not'] = true,  -- lit's "not" prefix (inverts exit code)
}

-- ---------------------------------------------------------------------------
-- Command string manipulation
-- ---------------------------------------------------------------------------

--- Quote-aware shell argument splitting.
-- This is NOT a full POSIX shell parser — it does not expand $VAR, `backtick`,
-- or ~. It handles:
--   • Single-quoted strings:  'hello world' → one arg
--   • Double-quoted strings:  "hello world" → one arg
--   • Whitespace delimiters:  a b c → three args
--   • Consecutive whitespace: a    b → two args
--
-- @param cmd: a shell command string
-- @return:    list of argument strings
function M.split_args(cmd)
  local args, cur, quote = {}, '', nil
  local i = 1
  while i <= #cmd do
    local c = cmd:sub(i, i)
    if quote then
      -- Inside a quote: collect until the matching close-quote.
      if c == quote then
        quote = nil
      else
        cur = cur .. c
      end
    elseif c == "'" or c == '"' then
      quote = c
    elseif c:match('%s') then
      -- Whitespace outside quotes: flush the current arg.
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

-- Extract the lowercased basename from a tool path.
--   "/usr/bin/FileCheck" → "filecheck"
--   "circt-opt" or "/build/bin/mlir-opt" → "circt-opt" / "mlir-opt"
local function tool_basename(token)
  return (token:match('([^/]+)$') or token):lower()
end

--- Check whether a command should be skipped (i.e., is not debuggable).
-- @param cmd_str: the command string
-- @return:        true if the command should be filtered out
function M.is_skipped_command(cmd_str)
  local trimmed = cmd_str:match('^%s*(.-)%s*$') or cmd_str
  if trimmed == '' then
    return true
  end
  -- lit no-op: the shell ':' command with a RUN: at line N comment.
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

--- Split a shell pipeline ('|') into individual segments, filtering out
-- skipped tools (FileCheck, etc.).
--
-- Also handles '&&' chains: only the first command before '&&' is kept
-- (the rest are typically auxiliary, like `cat %t/log`).
--
-- @param cmd_str: a pipeline command string
-- @return:        list of debuggable segment strings
function M.split_pipeline(cmd_str)
  local segments = {}
  for seg in cmd_str:gmatch('[^|]+') do
    seg = seg:match('^%s*(.-)%s*$')
    -- If there's an &&, keep only the part before it.
    seg = seg:match('^(.-)%s*&&') or seg
    if seg ~= '' and not M.is_skipped_command(seg) then
      table.insert(segments, seg)
    end
  end
  return segments
end

-- ---------------------------------------------------------------------------
-- ANSI / whitespace normalization
-- ---------------------------------------------------------------------------

--- Strip ANSI SGR escape sequences (color codes) from a string.
-- lit often outputs with terminal colors when run interactively; we need
-- to remove those before parsing.
local function strip_ansi(s)
  return (s:gsub('\27%[[0-9;]*m', ''))
end

--- Normalize a line: strip ANSI escapes, then trim leading/trailing whitespace.
local function normalize_line(line)
  if not line or line == '' then
    return ''
  end
  line = strip_ansi(line)
  return line:match('^%s*(.-)%s*$') or line
end

-- ---------------------------------------------------------------------------
-- Parsing lit output
-- ---------------------------------------------------------------------------

--- Parse lit verbose / bash xtrace output into a deduplicated list of
-- standalone tool commands.
--
-- Two output formats are recognized:
--   1. bash xtrace (CIRCT / LLVM projects using bash lit shell):
--        "+ /build/bin/circt-opt /test/file.mlir -opt"
--        "+ /build/bin/mlir-opt /test/file.mlir --some-pass"
--   2. lit's internal shell verbose mode:
--        "# executed command: /build/bin/circt-opt /test/file.mlir -opt"
--   3. Expanded RUN lines (substituted, before split into commands):
--        "# RUN: at line 1"
--        "/build/bin/circt-opt /test/file.mlir -opt"   ← captured
--
-- Commands matching SKIP_TOOLS are excluded. Duplicates are merged.
--
-- @param all_lines: list of output lines from lit (stdout + stderr combined)
-- @return:          list of unique tool command strings (unsorted)
function M.parse_executed_commands(all_lines)
  local cmds = {}
  local seen = {}
  local function try_add(cmd_str)
    cmd_str = normalize_line(cmd_str)
    if cmd_str == '' or M.is_skipped_command(cmd_str) then
      return
    end
    -- Deduplicate: lit may print the same command multiple times.
    if seen[cmd_str] then
      return
    end
    seen[cmd_str] = true
    table.insert(cmds, cmd_str)
  end

  -- State for tracking expanded RUN lines.
  -- After a "# RUN:" comment, the NEXT non-comment line that starts with "/"
  -- is an expanded RUN line (the substitution already happened).
  local expect_expanded_run = false
  for _, raw in ipairs(all_lines or {}) do
    local line = normalize_line(raw)
    if line == '' or line == '--' then
      goto continue
    end

    -- Format 1: bash xtrace
    local xtrace = line:match('^%+ (.+)$')
    if xtrace then
      try_add(xtrace)
      expect_expanded_run = false
      goto continue
    end

    -- Format 2: lit verbose
    local executed = line:match('^#%s*executed%s+command:%s*(.+)$')
    if executed then
      try_add(executed)
      expect_expanded_run = false
      goto continue
    end

    -- Format 3 preamble: "# RUN:"
    if line:match('^# RUN:') then
      expect_expanded_run = true
      goto continue
    end

    -- Format 3 body: expanded RUN line (starts with "/")
    if expect_expanded_run and line:match('^/') then
      try_add(line)
      expect_expanded_run = false
      goto continue
    end

    -- Any other non-comment line after a "# RUN:" resets the expectation.
    if expect_expanded_run and not line:match('^#') then
      expect_expanded_run = false
    end

    ::continue::
  end

  return cmds
end

-- ---------------------------------------------------------------------------
-- DAP launch target extraction
-- ---------------------------------------------------------------------------

--- Given a command string and an optional pipeline segment index, parse
-- out the program and arguments for nvim-dap.
--
-- @param cmd_str:     a full pipeline command string (e.g. "circt-opt %s | FileCheck %s")
-- @param segment_idx: which segment of the pipeline to debug (1-based, default 1)
-- @return:            { program, args, command, segment, segments } or (nil, error)
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

--- Alias for split_pipeline — returns which segments of a command are
-- debuggable. Used by the segment picker in debug.lua.
function M.debuggable_segments(cmd_str)
  return M.split_pipeline(cmd_str)
end

-- ---------------------------------------------------------------------------
-- Text wrapping utilities (for the preview window)
-- ---------------------------------------------------------------------------

--- Wrap a string at word boundaries (spaces) to a given width.
-- Trims whitespace at the start of lines.
--
-- @param text:  the string to wrap
-- @param width: maximum line width (default 80)
-- @return:      list of wrapped lines
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

--- Wrap a long path-like argument, preferring break points at '/' characters.
-- Continuation lines are indented by `indent` (default: two spaces).
--
-- @param arg:    the path string
-- @param width:  maximum line width
-- @param indent: string prepended to continuation lines
-- @return:       list of wrapped lines
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
      -- Break at the last '/' within the width.
      local piece = rest:sub(1, slash)
      table.insert(lines, (#lines == 0) and piece or (indent .. piece))
      pos = pos + slash
    else
      -- No '/' found — hard break at width.
      local piece = rest:sub(1, width)
      table.insert(lines, (#lines == 0) and piece or (indent .. piece))
      pos = pos + width
    end
  end
  return lines
end

--- Format a command string for display in the preview window: one token per
-- line, with long tokens (paths, flags) wrapped intelligently.
--
-- This is used by debug.lua's show_preview() to display the selected command.
--
-- @param cmd:   the command string
-- @param width: maximum line width (default 88)
-- @return:      list of display lines
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
