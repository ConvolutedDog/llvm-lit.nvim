#!/usr/bin/env bash
# Smoke test: load plugin modules without running lit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export NVIM_APPNAME=nvim
nvim --headless -u NONE \
  -c "set rtp+=$ROOT" \
  -c "lua require('llvm-lit.config')" \
  -c "lua require('llvm-lit.store').ensure_dir()" \
  -c "lua local p=require('llvm-lit.project'); assert(p.make_filter('/a/b/c/foo.mlir',2)=='c/foo.mlir')" \
  -c "qa!"
echo "llvm-lit.nvim smoke test OK"
