#!/usr/bin/env bash
set -euo pipefail

cargo build --release

# 将产物复制到当前仓库的 lib/ 目录，由插件在 runtimepath 中查找
rm lib -rf
mkdir -p lib
if [[ "$(uname)" == "Darwin" ]]; then
  cp target/release/libsimpleclipboard.dylib lib/
else
  cp target/release/libsimpleclipboard.so lib/
fi
cp target/release/simpleclipboard-daemon lib/

echo "Installed to ./lib. Ensure this plugin directory is on 'runtimepath'."

# --- 可选：配置 SSH auto-tunnel ---
setup_ssh_tunnel() {
  local config="$HOME/.ssh/config"
  local marker="# simpleclipboard auto-tunnel"

  if grep -q "$marker" "$config" 2>/dev/null; then
    echo "SSH auto-tunnel already configured in $config."
    return
  fi

  mkdir -p "$HOME/.ssh"
  chmod 700 "$HOME/.ssh"

  cat >> "$config" << 'EOF'

# simpleclipboard auto-tunnel
# 当本地 daemon 运行时，自动为所有 SSH 连接建立反向隧道
Match host * exec "pgrep -qf simpleclipboard-daemon"
    RemoteForward 12345 127.0.0.1:12343
EOF

  chmod 600 "$config"
  echo "SSH auto-tunnel configured in $config."
  echo "Future SSH connections will auto-forward clipboard when local daemon is running."
}

if [[ "${1:-}" == "--with-ssh-tunnel" ]]; then
  setup_ssh_tunnel
elif [[ -t 0 ]]; then
  echo ""
  echo "=== SSH Auto-Tunnel Setup ==="
  echo "This configures SSH to automatically forward clipboard from remote Vim."
  echo "Without this, remote clipboard still works via OSC52 (terminal-based, ~75KB limit)."
  echo ""
  read -p "Configure SSH auto-tunnel for remote clipboard? (y/N) " answer
  if [[ "$answer" =~ ^[Yy] ]]; then
    setup_ssh_tunnel
  else
    echo "Skipped. Run './install.sh --with-ssh-tunnel' later to set it up."
  fi
else
  echo ""
  echo "SSH auto-tunnel setup skipped (non-interactive mode)."
  echo "Run './install.sh --with-ssh-tunnel' to configure it later."
fi
