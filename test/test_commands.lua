-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/test_commands.lua — Tests for commands.lua
--
-- These tests exercise pure-Lua functions (no UI), so they run in headless
-- mode without any Neovim window.
-- =============================================================================

local t = require('test.utils')
local cmds = require('llvm-lit.commands')

t.suite('split_args')

t.eq(#cmds.split_args(''), 0, 'empty string returns empty list')
t.eq(#cmds.split_args('   '), 0, 'whitespace-only string returns empty list')

t.eq(cmds.split_args('circt-opt'), { 'circt-opt' }, 'single token')
t.eq(cmds.split_args('circt-opt -opt'), { 'circt-opt', '-opt' }, 'two tokens')
t.eq(
  cmds.split_args('circt-opt %s -opt 2>&1 | FileCheck %s'),
  { 'circt-opt', '%s', '-opt', '2>&1', '|', 'FileCheck', '%s' },
  'pipe and redirection tokens'
)

-- Quote handling
t.eq(cmds.split_args([[echo "hello world"]]), { 'echo', 'hello world' }, 'double-quoted arg')
t.eq(cmds.split_args([[echo 'hello world']]), { 'echo', 'hello world' }, 'single-quoted arg')
t.eq(
  cmds.split_args([[circt-opt "-opt=value with spaces"]]),
  { 'circt-opt', '-opt=value with spaces' },
  'double-quoted flag with spaces'
)
t.eq(cmds.split_args([[a "b c" d]]), { 'a', 'b c', 'd' }, 'mixed quoted and unquoted')

-- Trailing whitespace
t.eq(cmds.split_args('  circt-opt  -opt  '), { 'circt-opt', '-opt' }, 'leading/trailing whitespace')

-- Boundary cases for split_args
-- Unclosed double quote (collects until end of string)
t.eq(cmds.split_args([[echo "hello world]]), { 'echo', 'hello world' }, 'unclosed double quote')
-- Unclosed single quote
t.eq(cmds.split_args([[echo 'hello world]]), { 'echo', 'hello world' }, 'unclosed single quote')
-- Empty quotes (the parser skips empty quotes, no empty arg produced)
t.eq(cmds.split_args([[echo ""]]), { 'echo' }, 'empty double quotes: no empty arg')
t.eq(cmds.split_args([[echo '']]), { 'echo' }, 'empty single quotes: no empty arg')
-- Consecutive double quotes (stripped, treated as grouping)
t.eq(cmds.split_args([[a"b""c"d]]), { 'abcd' }, 'consecutive double quotes stripped')
-- Tab separator (tab == whitespace in Lua's %s)
t.eq(cmds.split_args('a\tb\tc'), { 'a', 'b', 'c' }, 'tab separated tokens')
-- Literal %s token (lit placeholders should work fine)
t.eq(cmds.split_args('circt-opt %s -opt'), { 'circt-opt', '%s', '-opt' }, '%s as a token')
-- Mixed quotes: double inside single
t.eq(cmds.split_args([[echo '"hello" world]]), { 'echo', '"hello" world' }, 'double quotes inside single quotes')
-- Mixed quotes: single inside double
t.eq(cmds.split_args([[echo "'hello' world"]]), { 'echo', "'hello' world" }, 'single quotes inside double quotes')

t.suite('is_skipped_command')

t.ok(cmds.is_skipped_command(''), 'empty string is skipped')
t.ok(cmds.is_skipped_command('  '), 'whitespace-only is skipped')
t.ok(cmds.is_skipped_command(": 'RUN: at line 1'"), 'RUN at line comment is skipped')
t.ok(cmds.is_skipped_command(':'), 'bare colon is skipped')
t.ok(cmds.is_skipped_command('FileCheck %s'), 'FileCheck is skipped')
t.ok(cmds.is_skipped_command('/usr/bin/FileCheck %s'), 'FileCheck with path is skipped')
t.ok(cmds.is_skipped_command('cat %t/log.txt'), 'cat is skipped')
t.ok(cmds.is_skipped_command('rm -rf /tmp/foo'), 'rm is skipped')
t.ok(cmds.is_skipped_command('echo hello'), 'echo is skipped')
t.ok(cmds.is_skipped_command('diff a b'), 'diff is skipped')
t.ok(cmds.is_skipped_command('grep foo bar'), 'grep is skipped')
t.ok(cmds.is_skipped_command('sed s/foo/bar/'), 'sed is skipped')
t.ok(cmds.is_skipped_command('python3 script.py'), 'python3 is skipped')
t.ok(cmds.is_skipped_command('bash -c "echo hi"'), 'bash is skipped')
t.ok(cmds.is_skipped_command('not foo'), 'not is skipped')
t.ok(cmds.is_skipped_command('true'), 'true is skipped')
t.ok(cmds.is_skipped_command('false'), 'false is skipped')

t.ok(not cmds.is_skipped_command('circt-opt %s -opt'), 'circt-opt is NOT skipped')
t.ok(not cmds.is_skipped_command('toyc-ch7 %s -emit=mlir'), 'toyc-ch7 is NOT skipped')
t.ok(not cmds.is_skipped_command('/build/bin/circt-opt %s'), 'circt-opt with path is NOT skipped')

-- Boundary cases for is_skipped_command
-- Case insensitive: uppercase/lowercase should still match
t.ok(cmds.is_skipped_command('FILECHECK %s'), 'FILECHECK (uppercase) is skipped')
t.ok(cmds.is_skipped_command('FileCheck %s'), 'FileCheck (mixed case) is skipped')
-- Tools from the skip list that were missing tests
t.ok(cmds.is_skipped_command('python script.py'), 'python (without 3) is skipped')
t.ok(cmds.is_skipped_command('head -5 file.txt'), 'head is skipped')
t.ok(cmds.is_skipped_command('tail -5 file.txt'), 'tail is skipped')
t.ok(cmds.is_skipped_command('sort file.txt'), 'sort is skipped')
t.ok(cmds.is_skipped_command('wc -l file.txt'), 'wc is skipped')
t.ok(cmds.is_skipped_command('tee output.txt'), 'tee is skipped')
t.ok(cmds.is_skipped_command('touch /tmp/t'), 'touch is skipped')
t.ok(cmds.is_skipped_command('mkdir /tmp/d'), 'mkdir is skipped')
t.ok(cmds.is_skipped_command('cp a b'), 'cp is skipped')
t.ok(cmds.is_skipped_command('mv a b'), 'mv is skipped')
t.ok(cmds.is_skipped_command('awk "{print}"'), 'awk is skipped')
t.ok(cmds.is_skipped_command('sh -c "echo hi"'), 'sh is skipped')
t.ok(cmds.is_skipped_command('env VAR=val cmd'), 'env is skipped')
-- "not" is special (lit's "not" prefix)
t.ok(cmds.is_skipped_command('not circt-opt %s'), 'not circt-opt is skipped')

-- Lots of whitespace in command
t.ok(cmds.is_skipped_command('  FileCheck  %s  '), 'FileCheck with extra whitespace')
t.ok(not cmds.is_skipped_command(' /build/bin/circt-opt '), 'tool with leading/trailing whitespace is NOT skipped')

t.suite('split_pipeline')

t.eq(#cmds.split_pipeline(''), 0, 'empty string returns empty')

local simple = cmds.split_pipeline('circt-opt %s | FileCheck %s')
t.eq(#simple, 1, 'pipe with FileCheck produces one segment')
t.eq(simple[1], 'circt-opt %s', 'segment drops | FileCheck %s')

local no_pipe = cmds.split_pipeline('circt-opt %s -opt')
t.eq(#no_pipe, 1, 'single command (no pipe) produces one segment')
t.eq(no_pipe[1], 'circt-opt %s -opt', 'segment is the full command')

local and_chain = cmds.split_pipeline('circt-opt %s && cat %t/log.txt')
t.eq(#and_chain, 1, '&& chain produces one segment')
t.eq(and_chain[1], 'circt-opt %s', 'segment drops && and everything after')

-- Multiple debuggable segments
local multi = cmds.split_pipeline('circt-opt %s -opt | firtool %s | FileCheck %s')
t.eq(#multi, 2, 'two debuggable segments in pipeline')
t.eq(multi[1], 'circt-opt %s -opt', 'first segment')
t.eq(multi[2], 'firtool %s', 'second segment (drops FileCheck)')

-- Skipped tools are removed
local with_skipped = cmds.split_pipeline('cat %t/log | circt-opt %s | echo done | FileCheck %s')
t.eq(#with_skipped, 1, 'only debuggable segments remain')
t.eq(with_skipped[1], 'circt-opt %s', 'cat and echo and FileCheck are all dropped')

-- Boundary cases for split_pipeline
-- All segments are skipped (nothing debuggable)
t.eq(#cmds.split_pipeline('cat a | FileCheck b | echo c'), 0, 'all skipped: returns empty')

-- Pipeline with only a skipped tool
t.eq(#cmds.split_pipeline('FileCheck %s'), 0, 'only FileCheck: empty')

-- No pipeline (single debuggable command)
t.eq(#cmds.split_pipeline('circt-opt %s'), 1, 'single command, no pipe')

-- Multiple debuggable tools (FileCheck in the middle, removed)
local mid_check = cmds.split_pipeline('circt-opt -opt | FileCheck %s | firtool -verify')
t.eq(#mid_check, 2, 'FileCheck in the middle: two debuggable segments')
t.eq(mid_check[1], 'circt-opt -opt', 'first segment is circt-opt')
t.eq(mid_check[2], 'firtool -verify', 'last segment is firtool')

t.suite('parse_launch_target')

local target, err = cmds.parse_launch_target('circt-opt %s -opt', 1)
t.ok(target, 'parse_launch_target succeeds')
t.eq(target.program, 'circt-opt', 'program is circt-opt')
t.eq(#target.args, 2, 'two args')
t.eq(target.args[1], '%s', 'first arg is %s')
t.eq(target.args[2], '-opt', 'second arg is -opt')
t.eq(target.segment, 1, 'segment index is 1')

-- Pipeline segment index
t.eq(target.segments, 1, '1 segment total')

-- Parse second segment
local t2 = cmds.parse_launch_target('circt-opt %s | firtool %s', 2)
t.ok(t2, 'parse second segment')
t.eq(t2.program, 'firtool', 'program is firtool')

-- Invalid segment index
local t3, err3 = cmds.parse_launch_target('circt-opt %s', 5)
t.ok(not t3, 'invalid segment index returns nil')
t.like(err3, 'out of range', 'error message mentions range')

t.suite('debuggable_segments')

local segs1 = cmds.debuggable_segments('circt-opt %s | FileCheck %s')
t.eq(#segs1, 1, 'one debuggable segment')
t.eq(segs1[1], 'circt-opt %s', 'segment is circt-opt')

t.eq(#cmds.debuggable_segments(''), 0, 'empty string: no segments')
t.eq(#cmds.debuggable_segments('FileCheck %s'), 0, 'only FileCheck: no segments')

t.suite('parse_executed_commands')

-- bash xtrace format (CIRCT/LLVM projects using bash lit shell)
local xtrace_lines = {
  '+ /build/bin/circt-opt /test/file.mlir -opt',
  '+ FileCheck /test/file.mlir',
  '',
  '+ echo done',
}
local xtrace_cmds = cmds.parse_executed_commands(xtrace_lines)
t.eq(#xtrace_cmds, 1, 'xtrace: only circt-opt (FileCheck + echo dropped)')
t.like(xtrace_cmds[1], 'circt-opt', 'xtrace: command is circt-opt')

-- lit verbose format (# executed command: ...)
local verbose_lines = {
  '# executed command: /build/bin/circt-opt /test/file.mlir -opt',
  '# executed command: FileCheck /test/file.mlir',
  '# executed command: echo done',
  '# executed command: rm -rf /tmp/test',
}
local verbose_cmds = cmds.parse_executed_commands(verbose_lines)
t.eq(#verbose_cmds, 1, 'verbose: only circt-opt (FileCheck + echo + rm dropped)')
t.like(verbose_cmds[1], 'circt-opt', 'verbose: command is circt-opt')

-- Both formats mixed
local mixed_lines = {
  '+ circt-opt /test/file.mlir -opt',
  '# executed command: FileCheck /test/file.mlir',
  '+ echo done',
}
local mixed_cmds = cmds.parse_executed_commands(mixed_lines)
t.eq(#mixed_cmds, 1, 'mixed formats: deduplicated')

-- Empty / nil input
t.eq(#cmds.parse_executed_commands({}), 0, 'empty table returns empty')
t.eq(#cmds.parse_executed_commands(nil), 0, 'nil returns empty')

-- No matching lines
local no_match = cmds.parse_executed_commands({ '# just a comment', 'some random text' })
t.eq(#no_match, 0, 'no matching lines returns empty')

-- Expanded RUN line format
local expanded_lines = {
  '# RUN: at line 1',
  '/build/bin/circt-opt /test/file.mlir -opt',
  '# executed command: FileCheck /test/file.mlir',
}
local expanded_cmds = cmds.parse_executed_commands(expanded_lines)
t.eq(#expanded_cmds, 1, 'expanded RUN line is parsed')
t.like(expanded_cmds[1], 'circt-opt', 'expanded RUN yields circt-opt')

-- Multiple RUN lines (common in lit tests)
local multi_run_lines = {
  '# RUN: at line 1',
  '/build/bin/circt-opt /test/file.mlir -opt',
  '# executed command: FileCheck /test/file.mlir --check-prefix=CHECK',
  '# RUN: at line 2',
  '/build/bin/circt-opt /test/file.mlir -opt -additional-pass',
  '# executed command: FileCheck /test/file.mlir --check-prefix=CHECK2',
}
local multi_run_cmds = cmds.parse_executed_commands(multi_run_lines)
t.eq(#multi_run_cmds, 2, 'two RUN commands parsed')

-- ANSI escape stripping
local ansi_lines = {
  '\27[32m+ circt-opt /test/file.mlir -opt\27[0m',
  '\27[31m+ FileCheck /test/file.mlir\27[0m',
}
local ansi_cmds = cmds.parse_executed_commands(ansi_lines)
t.eq(#ansi_cmds, 1, 'ANSI escapes stripped')
t.eq(ansi_cmds[1], 'circt-opt /test/file.mlir -opt',
  'ANSI-stripped command is clean')

-- Boundary cases for parse_executed_commands
-- Only blank/dash lines should produce nothing
t.eq(#cmds.parse_executed_commands({ '', '--', '', '--' }), 0, 'only blank and dash lines: empty')

-- # RUN: line with no following command should not produce output
local run_no_follow = {
  '# RUN: at line 1',
  '# RUN: at line 2',
}
t.eq(#cmds.parse_executed_commands(run_no_follow), 0, 'RUN lines without follow-up: empty')

-- Expended RUN line followed by comment line should still be captured
local exp_comment = {
  '# RUN: at line 1',
  '/build/bin/circt-opt /test/file.mlir',
  '# some other comment',
}
t.eq(#cmds.parse_executed_commands(exp_comment), 1, 'expanded RUN followed by comment: one command')
t.like(cmds.parse_executed_commands(exp_comment)[1], 'circt-opt', 'expanded RUN command captured')

-- Duplicate command from both xtrace and verbose
local dup_lines = {
  '+ /build/bin/circt-opt /test/file.mlir',
  '# executed command: /build/bin/circt-opt /test/file.mlir',
}
t.eq(#cmds.parse_executed_commands(dup_lines), 1, 'duplicate formats: deduplicated')

-- Realistic lit output with # RUN: at line numbers
local realistic = {
  '# RUN: at line 1',
  '/build/bin/circt-opt /test/file.mlir -opt',
  '+ /build/bin/FileCheck /test/file.mlir',
  '# executed command: /build/bin/FileCheck /test/file.mlir --check-prefix=CHECK',
  '',
  '--',
  '# RUN: at line 2',
  '/build/bin/circt-opt /test/file.mlir -opt -extra-pass',
}
t.eq(#cmds.parse_executed_commands(realistic), 2, 'realistic output: 2 commands')
t.like(cmds.parse_executed_commands(realistic)[1], 'circt-opt', 'first realistic command: circt-opt')
t.like(cmds.parse_executed_commands(realistic)[2], 'extra-pass', 'second realistic command: has -extra-pass')

-- Line starting with numbers after RUN: (not a path, should not match)
local num_after_run = {
  '# RUN: at line 1',
  '42 not a path',
}
t.eq(#cmds.parse_executed_commands(num_after_run), 0, 'number after RUN: not captured')

t.suite('wrap_text')

t.eq(cmds.wrap_text('short', 80), { 'short' }, 'short string not wrapped')
local wrapped = cmds.wrap_text(string.rep('a', 100), 50)
t.ok(#wrapped >= 2, 'long string wrapped into multiple lines')
t.eq(#wrapped[1], 50, 'first line is exactly width')
t.eq(#wrapped[2], 50, 'second line is exactly width')

-- Word-boundary wrapping
local sentence = 'hello world foo bar'
local s_wrapped = cmds.wrap_text(sentence, 12)
t.eq(#s_wrapped, 2, 'wrapped at word boundary')
t.eq(s_wrapped[1], 'hello world', 'first line breaks after world')
t.eq(s_wrapped[2], 'foo bar', 'second line has remaining words')

-- Trimming whitespace in wrapped lines
local spaced_wrap = cmds.wrap_text('  hello   world  ', 80)
t.eq(#spaced_wrap, 1, 'single line even with padding')
t.ok(#spaced_wrap[1] <= 80, 'line does not exceed width')

-- Boundary cases for wrap_text
-- Empty string (returns {} because while loop body never executes)
t.eq(cmds.wrap_text('', 80), {}, 'empty string returns {}')
-- width=0 (undefined behavior — skip, just verify pcall doesn't hang)
-- Don't test width=0 directly since it causes infinite loop
-- Width 1
local w1 = cmds.wrap_text('hello', 1)
local w1 = cmds.wrap_text('hello', 1)
t.ok(#w1 >= 5, 'width=1: wraps into at least 5 lines')
-- No spaces (pure sequence with no break points)
local no_spaces = cmds.wrap_text(string.rep('a', 200), 50)
t.ok(#no_spaces >= 4, 'no break chars: wraps at width boundary')
-- Unicode / non-ASCII characters (measurement in bytes, but should not crash)
local unicode = cmds.wrap_text('中文测试一些很长的字符串用于测试换行功能', 20)
t.ok(#unicode >= 2, 'unicode string wraps into multiple lines')
-- Exact fit (text equals width exactly)
t.eq(cmds.wrap_text('hello', 5), { 'hello' }, 'exact width fit: single line')
-- Width larger than text
t.eq(cmds.wrap_text('hello', 100), { 'hello' }, 'width > text length: single line')
-- Text with consecutive spaces
local multi_space = cmds.wrap_text('a     b', 10)
t.eq(#multi_space, 1, 'consecutive spaces: single line')

t.suite('cmd_display_lines')

-- Single short arg
local short_lines = cmds.cmd_display_lines('circt-opt', 88)
t.eq(#short_lines, 1, 'single short arg = 1 line')
t.eq(short_lines[1], 'circt-opt', 'line is the command')

-- Multiple args
local multi_lines = cmds.cmd_display_lines('circt-opt %s -opt', 88)
t.eq(#multi_lines, 3, 'three tokens = 3 lines')
t.eq(multi_lines[1], 'circt-opt', 'first line: program')
t.eq(multi_lines[2], '%s', 'second line: %s')
t.eq(multi_lines[3], '-opt', 'third line: -opt')

-- Path wrapping (long paths broken at /)
local long_lines = cmds.cmd_display_lines(
  'circt-opt /Users/me/project/build/bin/../test/foo.mlir -opt',
  30
)
-- The path should be wrapped — the function wraps non-space content at /
-- OR at the width boundary. We just check it produces more than 3 lines.
t.ok(#long_lines >= 3, 'long path is wrapped into multiple lines')

-- Empty cmd
t.eq(#cmds.cmd_display_lines('', 88), 1, 'empty cmd returns { "" }')

-- Long non-path token wraps at spaces
local long_non_path = cmds.cmd_display_lines(
  'circt-opt ' .. string.rep('a', 50) .. ' -opt',
  20
)
t.ok(#long_non_path >= 3, 'long non-path arg wraps into multiple lines')
t.eq(long_non_path[1], 'circt-opt', 'first line is program')

-- Boundary cases for cmd_display_lines
-- Empty command
t.eq(cmds.cmd_display_lines('', 88), { '' }, 'empty returns { "" }')
-- Single arg exactly at width
t.eq(cmds.cmd_display_lines('circt-opt', 88), { 'circt-opt' }, 'short arg exactly at width')
-- Many small args
local many_small = cmds.cmd_display_lines('a b c d e f g h i j k', 88)
t.eq(#many_small, 11, 'many small args: one arg per line')
-- Long path with multiple slashes
local long_path_cmd = cmds.cmd_display_lines(
  'circt-opt /this/is/a/very/long/path/that/should/be/wrapped/at/slashes/test.mlir',
  30
)
t.ok(#long_path_cmd >= 3, 'long path wraps at slashes into multiple lines')
-- Command with no args (just program name)
t.eq(cmds.cmd_display_lines('circt-opt'), { 'circt-opt' }, 'no args: single line')

return require('test.utils').done()
