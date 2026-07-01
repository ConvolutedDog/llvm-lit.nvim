-- Copyright (c) 2026 Jianchao Yang
-- Licensed under the MIT License - see the LICENSE file for details.

-- =============================================================================
-- test/test_run.lua — Tests for run.lua
--
-- Covers:
--   • M.build_command() — pure function, most valuable test
--   • check_llvm_lit() — inline re-implementation
--   • buf_alive() — inline re-implementation
-- =============================================================================

local t = require('test.utils')
local run = require('llvm-lit.run')

-- ---------------------------------------------------------------------------
-- M.build_command(info, opts)
-- ---------------------------------------------------------------------------

t.suite('build_command')

-- Minimal info table — build a normal command
local info = {
  cwd           = '/home/user/project',
  lit_testsuite = '/home/user/project/build/test',
  filter        = 'Dialect/Arith/ops.mlir',
}

local cmd1 = run.build_command(info)
t.ok(type(cmd1) == 'string', 'build_command returns a string')
t.like(cmd1, 'cd ', 'command starts with cd')
t.like(cmd1, '/home/user/project', 'cwd is included')
t.like(cmd1, 'llvm-lit', 'llvm-lit binary is included')
t.like(cmd1, '/home/user/project/build/test', 'testsuite path is included')
t.like(cmd1, '--filter', '--filter flag is included')
t.like(cmd1, 'Dialect/Arith/ops.mlir', 'filter value is included')
t.like(cmd1, '&&', 'cd && chain is used')

-- dump_input mode adds FILECHECK_OPTS
local cmd2 = run.build_command(info, { dump_input = true })
t.like(cmd2, 'FILECHECK_OPTS', 'dump mode includes FILECHECK_OPTS')

-- Non-dump mode does NOT include FILECHECK_OPTS
t.ok(not cmd1:find('FILECHECK_OPTS'), 'normal mode does not include FILECHECK_OPTS')

-- Custom project name in header (M.build_command doesn't add the header,
-- it just builds the shell command — we verify the structure is right)
t.like(cmd1, 'llvm-lit', 'contains llvm-lit')

-- ---------------------------------------------------------------------------
-- check_llvm_lit (private) — inline re-implementation
-- ---------------------------------------------------------------------------

t.suite('check_llvm_lit (private)')

local function check_llvm_lit_inline(bin)
  if bin:match('/') then
    if vim.fn.filereadable(bin) ~= 1 then
      return false, 'llvm-lit not found: ' .. bin
    end
    return true
  end
  if vim.fn.executable(bin) ~= 1 then
    return false, 'llvm-lit is not in PATH'
  end
  return true
end

-- With absolute path: /bin/sh should always be readable.
local ok1 = check_llvm_lit_inline('/bin/sh')
t.ok(ok1, '/bin/sh is readable (absolute path)')

-- Non-existent absolute path
local ok2, err2 = check_llvm_lit_inline('/nonexistent/binary12345')
t.ok(not ok2, 'non-existent absolute path fails')
t.like(err2, 'not found', 'error mentions not found')

-- With simple name (not in PATH in headless mode won't find anything)
local ok3, _ = check_llvm_lit_inline('thisbinarydefinitelydoesnotexist__')
t.ok(not ok3, 'non-existent binary name fails')

-- With a known binary — llvm-lit is unlikely to be in PATH in the sandbox.
-- But 'sh' or 'bash' usually are not executable names for this check
-- (they need to be on PATH). We just verify the mechanism.

-- ---------------------------------------------------------------------------
-- buf_alive (private) — inline re-implementation
-- ---------------------------------------------------------------------------

t.suite('buf_alive (private)')

local function buf_alive_inline(buf)
  return buf ~= nil
    and vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buflisted
end

-- nil
t.ok(not buf_alive_inline(nil), 'nil returns false')

-- Valid scratch buffer (created but not listed)
local buf = vim.api.nvim_create_buf(false, false)  -- listed = false
t.ok(not buf_alive_inline(buf), 'unlisted buffer returns false')

-- Valid listed buffer
local buf2 = vim.api.nvim_create_buf(true, false)  -- listed = true
t.ok(buf_alive_inline(buf2), 'listed buffer returns true')

-- After bdelete
pcall(vim.api.nvim_buf_delete, buf, { force = true })
pcall(vim.api.nvim_buf_delete, buf2, { force = true })
t.ok(not buf_alive_inline(buf), 'deleted buffer returns false')
t.ok(not buf_alive_inline(buf2), 'deleted listed buffer returns false')

-- Invalid number
t.ok(not buf_alive_inline(999999), 'invalid buffer number returns false')

return require('test.utils').done()
