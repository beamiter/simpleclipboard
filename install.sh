#!/usr/bin/env bash
set -euo pipefail

cargo build --release

# 将产物复制到当前仓库的 lib/ 目录，由插件在 runtimepath 中查找
mkdir -p lib
cp target/release/libsimpleclipboard.so lib/
cp target/release/simpleclipboard-daemon lib/
cp target/release/simpletree-daemon lib/

echo "Installed to ./lib. Ensure this plugin directory is on 'runtimepath'."
