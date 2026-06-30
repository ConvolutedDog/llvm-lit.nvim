#!/usr/bin/env bash
# Smoke test: load plugin modules without running lit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NVIM_APPNAME=nvim
nvim --headless -u NONE \
  -c "set rtp+=$ROOT" \
  -c "lua require('llvm-lit.config')" \
  -c "lua require('llvm-lit.store').ensure_dir()" \
  -c "lua require('llvm-lit.commands'); local c=require('llvm-lit.commands'); local t=c.parse_launch_target([[ /bin/circt-opt %s -export-verilog | FileCheck %s ]], 1); assert(t.program=='/bin/circt-opt' and t.args[2]=='-export-verilog')" \
  -c "lua require('llvm-lit.debug')" \
  -c "qa!"
echo "llvm-lit.nvim smoke test OK"
