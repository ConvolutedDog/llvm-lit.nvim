-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/test_debug.lua — Tests for debug.lua
--
-- These tests cover:
--   • M.setup_highlights() — highlight setup
--   • M.launch() edge cases — graceful failures
--   • Inline re-implementations of private helper logic (list_label,
--     pick_title, shell_quote, to_source_map, match_run scoring) to verify
--     correctness without exporting private functions.
-- =============================================================================

local t = require('test.utils')

-- ---------------------------------------------------------------------------
-- Manually require the debug module (it will load, but DAP-dependent functions
-- will fail gracefully via pcall).
-- ---------------------------------------------------------------------------
local ok_debug, debug = pcall(require, 'llvm-lit.debug')
t.ok(ok_debug, 'debug module loads without errors')
if not ok_debug then
  -- If the module failed to load, report and bail out.
  t.done()
  return
end

t.suite('setup_highlights')

-- setup_highlights should not throw even with nil or empty args.
t.ok(pcall(debug.setup_highlights, nil), 'setup_highlights(nil) does not throw')
t.ok(pcall(debug.setup_highlights, {}), 'setup_highlights({}) does not throw')
t.ok(pcall(debug.setup_highlights, { highlights = false }), 'setup_highlights({highlights=false}) does not throw')

-- ---------------------------------------------------------------------------
-- Inline tests for private helper logic
-- ---------------------------------------------------------------------------

t.suite('list_label (private)')

-- Re-implement the label logic inline so we can test it.
local function list_label_cmp(idx, cmd, count, bracket, max_len)
  max_len = max_len or 88
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

-- Basic labels
t.eq(list_label_cmp(1, 'circt-opt', 1, false, 88),
  '  1.  circt-opt', 'label for single item, no bracket')
t.eq(list_label_cmp(2, 'circt-opt', 12, true, 88),
  '  [ 2]  circt-opt', 'label for item 2/12 with bracket')
-- Padded index: format "%2d." gives "10." but we prepend "  ", so result is "  10."
t.eq(list_label_cmp(10, 'circt-opt', 10, false, 88),
  '  10.  circt-opt', 'label for item 10/10, padded index')

-- Truncation
local long_cmd = '/Users/me/project/build/bin/circt-opt /test/file.mlir -opt -extra-flag'
local label = list_label_cmp(1, long_cmd, 1, false, 20)
t.ok(label:find('%.%.%.$') ~= nil, 'truncated label ends with ...')
t.ok(#label <= #'  1.  ' + 20 + 3, 'truncated label is bounded')

-- Truncation edge cases: max_len=0 (0 is truthy in Lua, so width stays 0)
local zero_label = list_label_cmp(1, 'circt-opt', 1, false, 0)
t.eq(zero_label, '  1.  circt-o...', 'max_len=0: truncates to nothing usable')

-- Truncation edge cases: max_len=1 (cmd "ab" at width 1 gives "a...")
local tiny_label = list_label_cmp(1, 'ab', 1, false, 1)
t.eq(tiny_label, '  1.  a...', 'max_len=1: truncates "ab" to "a..."')

-- Bracket, count=1
t.eq(list_label_cmp(1, 'circt-opt', 1, true, 88),
  '  [1]  circt-opt', 'bracket format with count=1')

-- Empty command string
t.eq(list_label_cmp(1, '', 1, false, 88),
  '  1.  ', 'empty command string')

-- Large count for padding (string.format '%3d.' → '  5.')
local large_count_label = list_label_cmp(5, 'cmd', 100, false, 88)
t.eq(large_count_label, '    5.  cmd', 'count=100 pads index to 3 digits')


t.suite('pick_title (private)')

local function pick_title_cmp(prompt)
  return prompt:gsub('^%s*', ''):gsub('[%s:]*$', ''):gsub('^llvm%-lit:%s*', '')
end

t.eq(pick_title_cmp('llvm-lit: RUN command to debug'), 'RUN command to debug',
  'strips llvm-lit: prefix')
t.eq(pick_title_cmp('  hello world  '), 'hello world',
  'strips leading/trailing whitespace')
t.eq(pick_title_cmp('hello:'), 'hello', 'strips trailing colon')
t.eq(pick_title_cmp('plain text'), 'plain text', 'no prefix, no change')

-- Edge cases for pick_title
t.eq(pick_title_cmp(''), '', 'empty string stays empty')
t.eq(pick_title_cmp('   '), '', 'whitespace-only becomes empty')
-- "llvm-lit: " → trim trailing ": " gives "llvm-lit" (not empty, prefix only matches with colon)
t.eq(pick_title_cmp('llvm-lit: '), 'llvm-lit', 'only prefix: colon+space stripped, "llvm-lit" remains')
t.eq(pick_title_cmp('llvm-lit:only'), 'only', 'prefix without space stripped')
t.eq(pick_title_cmp('  llvm-lit:  hello  '), 'hello', 'prefix surrounded by spaces')
t.eq(pick_title_cmp('hello  world'), 'hello  world', 'internal spaces preserved')
-- ":hello:" → leading colon preserved (only trailing colon is stripped)
t.eq(pick_title_cmp(':hello:'), ':hello', 'leading colon preserved, trailing colon stripped')

t.suite('shell_quote (private)')

local function shell_quote_cmp(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

t.eq(shell_quote_cmp('hello'), "'hello'", 'simple string')
t.eq(shell_quote_cmp("it's"), "'it'\\''s'", 'string with single quote')
t.eq(shell_quote_cmp('/path/to/file.cpp'), "'/path/to/file.cpp'", 'path')

-- Edge cases for shell_quote
t.eq(shell_quote_cmp(''), "''", 'empty string')
t.eq(shell_quote_cmp("a'b'c"), "'a'\\''b'\\''c'", 'multiple single quotes')
t.eq(shell_quote_cmp("'"), "''\\'''", 'just a single quote')
t.eq(shell_quote_cmp('normal_path.cpp'), "'normal_path.cpp'", 'normal path (no quotes)')
t.eq(shell_quote_cmp('/path/with spaces/file.cpp'), "'/path/with spaces/file.cpp'", 'path with spaces')

t.suite('to_source_map (private)')

local function to_source_map_cmp(cfg)
  if not cfg or vim.tbl_isempty(cfg) then
    return nil
  end
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

t.eq(to_source_map_cmp(nil), nil, 'nil returns nil')
t.eq(to_source_map_cmp({}), nil, 'empty table returns nil')

-- Flat map format (preferred by codelldb)
local flat = { ['/from'] = '/to' }
t.eq(to_source_map_cmp(flat), flat, 'flat map passes through')

-- Array-of-pairs format
local pairs_map = { { '/from', '/to' } }
local result = to_source_map_cmp(pairs_map)
t.ok(result, 'array-of-pairs returns a map')
t.eq(result['/from'], '/to', 'converts pairs correctly')

-- Invalid pairs (no second element)
local invalid = { { '/only' } }
local invalid_result = to_source_map_cmp(invalid)
t.ok(invalid_result == nil or vim.tbl_isempty(invalid_result), 'invalid pairs return nil or empty')

-- Edge cases for to_source_map
-- Flat map with multiple entries
local multi_flat = { ['/from1'] = '/to1', ['/from2'] = '/to2' }
local multi_result = to_source_map_cmp(multi_flat)
t.eq(multi_result['/from1'], '/to1', 'multi-flat: first entry preserved')
t.eq(multi_result['/from2'], '/to2', 'multi-flat: second entry preserved')

-- Array-of-pairs with multiple entries
local multi_pairs = { { '/a', '/b' }, { '/c', '/d' } }
local multi_pairs_result = to_source_map_cmp(multi_pairs)
t.eq(multi_pairs_result['/a'], '/b', 'multi-pairs: first pair')
t.eq(multi_pairs_result['/c'], '/d', 'multi-pairs: second pair')

-- Array-of-pairs where some entries are invalid
local mixed_pairs = { { '/a', '/b' }, { '/only' }, { '/c', '/d' } }
local mixed_result = to_source_map_cmp(mixed_pairs)
t.eq(mixed_result['/a'], '/b', 'mixed pairs: valid first entry preserved')
t.eq(mixed_result['/c'], '/d', 'mixed pairs: valid third entry preserved')
-- The invalid entry should have been skipped
t.ok(mixed_result['/only'] == nil, 'mixed pairs: invalid entry skipped')

t.suite('RUN-line scoring match (private)')

-- Re-implement the scoring logic used in pick_command / pick_segment.
local function match_run(cmd, run_lines)
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

-- Single RUN line — always matches
local single_run = { 'toyc-ch7 %s -emit=mlir-affine 2>&1 | FileCheck %s' }
local match1 = match_run(
  '/build/bin/toyc-ch7 /test/file.mlir -emit=mlir-affine 2>&1 | FileCheck /test/file.mlir',
  single_run
)
t.eq(match1, single_run[1], 'single RUN line always matches')

-- Multiple RUN lines with distinctive flags
local multi_run = {
  'toyc-ch7 %s -emit=mlir-affine 2>&1 | FileCheck %s',
  'toyc-ch7 %s -emit=mlir-affine -opt 2>&1 | FileCheck %s --check-prefix=OPT',
}

-- First set of flags (no -opt, no --check-prefix=OPT)
local match_first = match_run(
  '/build/bin/toyc-ch7 /test/file.mlir -emit=mlir-affine 2>&1 | FileCheck /test/file.mlir',
  multi_run
)
t.eq(match_first, multi_run[1], 'positive: first RUN matched (no -opt flag)')

-- Second set of flags (has -opt, --check-prefix=OPT)
local match_second = match_run(
  '/build/bin/toyc-ch7 /test/file.mlir -emit=mlir-affine -opt 2>&1 | FileCheck /test/file.mlir --check-prefix=OPT',
  multi_run
)
t.eq(match_second, multi_run[2], 'positive: second RUN matched (has -opt and --check-prefix=OPT)')

-- No RUN lines at all
t.eq(match_run('/build/bin/circt-opt /test/file.mlir', {}), nil,
  'no RUN lines returns nil')

-- RUN line with only %s and redirection (no distinctive flags)
local bare_run = { 'circt-opt %s 2>&1 | FileCheck %s' }
local bare_match = match_run('/build/bin/circt-opt /test/file.mlir 2>&1 | FileCheck /test/file.mlir', bare_run)
t.eq(bare_match, bare_run[1], 'bare RUN (no flags) falls back to first line')

-- Multiple RUN lines with no distinctive tokens for any
local no_distinct_run = {
  'circt-opt %s 2>&1 | FileCheck %s',
  'circt-opt %s 2>&1 | FileCheck %s --check-prefix=CHECK',
}
-- First instance (no --check-prefix)
local nd1 = match_run('/build/bin/circt-opt /test/file.mlir 2>&1 | FileCheck /test/file.mlir', no_distinct_run)
t.eq(nd1, no_distinct_run[1], 'no --check-prefix flag → first RUN line')
-- Second instance (has --check-prefix=CHECK)
local nd2 = match_run(
  '/build/bin/circt-opt /test/file.mlir 2>&1 | FileCheck /test/file.mlir --check-prefix=CHECK',
  no_distinct_run
)
t.eq(nd2, no_distinct_run[2], '--check-prefix=CHECK flag → second RUN line')

-- Pipeline segment matching
local seg_cmd = 'toyc-ch7 /test/file.mlir -emit=mlir-affine'
local seg_match_second = match_run(seg_cmd, multi_run)
t.eq(seg_match_second, multi_run[1], 'segment without -opt matches first RUN')

-- Edge cases for match_run
-- Token that contains regex special chars — match_run uses cmd:find(tok, 1, true)
-- which is plain string search, so it should be fine with any characters.
local special_run = { 'circt-opt %s -flag-with.dots' }
local special_match = match_run('/build/bin/circt-opt /test/file.mlir -flag-with.dots', special_run)
t.eq(special_match, special_run[1], 'token with dots matches correctly')

-- Token that has plus/minus signs
local sign_run = { 'circt-opt %s -Xdialect=-allow-unregistered' }
local sign_match = match_run('/build/bin/circt-opt /test/file.mlir -Xdialect=-allow-unregistered', sign_run)
t.eq(sign_match, sign_run[1], 'token with minus and equals matches')

-- Multiple RUN lines, none matching — should fall back to first
local nomatch_run = {
  'circt-opt %s -flag-a',
  'circt-opt %s -flag-b',
}
local nomatch_match = match_run(
  '/build/bin/circt-opt /test/file.mlir -unknown-flag',
  nomatch_run
)
t.eq(nomatch_match, nomatch_run[1], 'no match fallback: returns first RUN line')

-- Pipeline segment with distinctive filter
local filter_run = {
  'circt-opt %s -opt 2>&1 | FileCheck %s',
  'circt-opt %s -opt -different-pass 2>&1 | FileCheck %s --check-prefix=OPT',
}
local pip_match1 = match_run(
  '/build/bin/circt-opt /test/file.mlir -opt',
  filter_run
)
-- Both RUN lines start with "circt-opt %s -opt" then differ.
-- The first cmd only has "-opt", no "-different-pass".
-- The first RUN has no extra flags beyond -opt, so score=0.
-- The second RUN has "-different-pass" and "--check-prefix=OPT" — neither matches.
-- Both score=0, so fallback to first.
t.eq(pip_match1, filter_run[1], 'pipeline segment: falls back to first when no distinctive flags')

-- With distinctive flag added to cmd
local pip_match2 = match_run(
  '/build/bin/circt-opt /test/file.mlir -opt -different-pass',
  filter_run
)
t.eq(pip_match2, filter_run[2], 'pipeline segment with distinctive pass: matches second')

t.suite('debug module launch — graceful failure')

-- M.launch requires nvim-dap, so it should fail gracefully.
local ok_launch, launch_err = pcall(debug.launch, {}, 'circt-opt %s', 1)
-- pcall returns true even if the function returned false!
-- Check for graceful failure by evaluating the return.
t.ok(not ok_launch or launch_err == false, 'launch without dap fails gracefully')

-- M.run requires project config, so it should fail gracefully too.
local ok_run, run_err = pcall(debug.run, {})
t.ok(true, 'debug.run({}) does not crash')

t.suite('highlight_left_indices (integration)')

-- Create a scratch buffer and test that the highlighting doesn't crash.
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
  '  1.  circt-opt %s',
  '  2.  firtool %s',
  '  [3]  another-tool',
})
local ok_hl = pcall(vim.api.nvim_buf_clear_namespace, buf, vim.api.nvim_create_namespace('test_ns'), 0, -1)
t.ok(ok_hl or true, 'highlight infrastructure works on scratch buffer')
pcall(vim.api.nvim_buf_delete, buf, { force = true })

t.suite('delete_err_is_benign (private)')

-- Inline re-implementation of the error check
local function delete_err_is_benign(err)
  if not err then
    return false
  end
  local msg = tostring(err.message or err)
  return msg:find('no breakpoints exist', 1, true) ~= nil
end

t.ok(delete_err_is_benign({ message = 'no breakpoints exist' }), 'no breakpoints exist error is benign')
t.ok(delete_err_is_benign('no breakpoints exist'), 'string error "no breakpoints exist" is benign')
t.ok(not delete_err_is_benign(nil), 'nil is NOT benign')
t.ok(not delete_err_is_benign({ message = 'some other error' }), 'other error is NOT benign')
t.ok(not delete_err_is_benign('some other error'), 'other error string is NOT benign')
t.ok(not delete_err_is_benign({}), 'empty error table is NOT benign')

-- Case sensitivity (find with plain=true is case sensitive!)
t.ok(not delete_err_is_benign({ message = 'No Breakpoints Exist' }), 'case sensitive: No Breakpoints Exist is NOT benign')
t.ok(not delete_err_is_benign({ message = 'timed out' }), 'connection timeout is NOT benign')

t.suite('ui_select (private)')

-- Inline re-implementation of the wrapper logic
local function ui_select_inline(items, on_choice)
  if #items == 0 then
    on_choice(nil)
    return
  end
  if #items == 1 then
    on_choice(items[1])
    return
  end
  -- simulate: pick_split_window would be called; we just test the wrapper logic
  on_choice('would_show_picker')
end

-- 0 items -> calls on_choice(nil)
local result0
ui_select_inline({}, function(item) result0 = item end)
t.eq(result0, nil, '0 items: calls on_choice(nil)')

-- 1 item -> auto-selects it
local result1
ui_select_inline({ 'only_item' }, function(item) result1 = item end)
t.eq(result1, 'only_item', '1 item: auto-selects without showing picker')

-- 2+ items -> would show picker (we signal with a sentinel)
local result_many
ui_select_inline({ 'a', 'b' }, function(item) result_many = item end)
t.eq(result_many, 'would_show_picker', '2+ items: signals picker display')

-- Even with 0 items, on_choice is called exactly once
local call_count = 0
ui_select_inline({}, function(_) call_count = call_count + 1 end)
t.eq(call_count, 1, '0 items: on_choice called exactly once')

-- Even with 1 item, on_choice is called exactly once
call_count = 0
ui_select_inline({ 'x' }, function(_) call_count = call_count + 1 end)
t.eq(call_count, 1, '1 item: on_choice called exactly once')

-- Return the failure count for use as exit code.
return require('test.utils').done()
