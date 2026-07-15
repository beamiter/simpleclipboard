#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"

"$repo_root/install.sh" --help >/dev/null

expect_usage_error() {
  if "$repo_root/install.sh" "$@" >/dev/null 2>&1; then
    echo "expected install.sh to reject: $*" >&2
    exit 1
  fi
}

expect_usage_error --with-ssh-tunnel
expect_usage_error --ssh-host workstation
expect_usage_error --with-ssh-tunnel --ssh-host '*'
expect_usage_error --with-ssh-tunnel --ssh-host -V
expect_usage_error --daemon-port 0
expect_usage_error --tunnel-port 65536
expect_usage_error --unknown
