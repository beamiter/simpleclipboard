#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
with_ssh_tunnel=0
ssh_host=""
daemon_port=12343
tunnel_port=12345
ssh_temporary=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [options]

Build and install the Rust client library and daemon into this plugin's lib/
directory. The script is safe to invoke from any working directory.

Options:
  --with-ssh-tunnel  Explicitly add or update a managed RemoteForward block in
                     ~/.ssh/config. Requires --ssh-host.
  --ssh-host HOST    Exact SSH host alias to which the managed tunnel applies.
                     Wildcards are intentionally rejected.
  --daemon-port N    Local daemon port used by the SSH block (default 12343).
  --tunnel-port N    Remote loopback port used by the SSH block (default 12345).
  -h, --help         Show this help.
EOF
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((1 <= 10#$1 && 10#$1 <= 65535))
}

while (($#)); do
  case "$1" in
    --with-ssh-tunnel)
      with_ssh_tunnel=1
      shift
      ;;
    --ssh-host)
      shift
      if (($# == 0)) || [[ ! "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "Invalid SSH host alias" >&2
        exit 2
      fi
      ssh_host="$1"
      shift
      ;;
    --daemon-port | --tunnel-port)
      option="$1"
      shift
      if (($# == 0)) || ! valid_port "$1"; then
        echo "Invalid port for $option" >&2
        exit 2
      fi
      if [[ "$option" == "--daemon-port" ]]; then
        daemon_port="$1"
      else
        tunnel_port="$1"
      fi
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ((with_ssh_tunnel)) && [[ -z "$ssh_host" ]]; then
  echo "--with-ssh-tunnel requires --ssh-host HOST" >&2
  exit 2
fi
if ((!with_ssh_tunnel)) && [[ -n "$ssh_host" ]]; then
  echo "--ssh-host requires --with-ssh-tunnel" >&2
  exit 2
fi

cd "$repo_root"

host_target="$(rustc -vV | sed -n 's/^host: //p')"
if [[ -z "$host_target" ]]; then
  echo "Could not determine the host Rust target" >&2
  exit 1
fi

target_root="${CARGO_TARGET_DIR:-$repo_root/target}"
if [[ "$target_root" != /* ]]; then
  target_root="$repo_root/$target_root"
fi
CARGO_TARGET_DIR="$target_root" cargo build --release --locked --target "$host_target"

if [[ "$(uname -s)" == "Darwin" ]]; then
  library_name="libsimpleclipboard.dylib"
else
  library_name="libsimpleclipboard.so"
fi

release_dir="$target_root/$host_target/release"
library_source="$release_dir/$library_name"
daemon_source="$release_dir/simpleclipboard-daemon"
client_source="$release_dir/simpleclipboard-client"

if [[ ! -f "$library_source" || ! -x "$daemon_source" || ! -x "$client_source" ]]; then
  echo "Build completed but expected artifacts were not found in $release_dir" >&2
  exit 1
fi
# A binary that links but does not run is worse than no new binary at all: it
# replaces a working install and then fails at the next yank, far away from
# anything that points back at the build.  --self-test drives one authenticated
# request through key derivation, AEAD sealing, framing and the response
# binding in-process, and deliberately never touches the desktop clipboard,
# which an installer cannot assume is reachable.  Nothing has moved yet at this
# point, so a failure here leaves the previous lib/ exactly as it was.
if ! self_test_output="$("$daemon_source" --self-test 2>&1)"; then
  echo "Freshly built daemon failed --self-test; keeping the existing lib/" >&2
  echo "$self_test_output" >&2
  exit 1
fi

if [[ -L "$repo_root/lib" || (-e "$repo_root/lib" && ! -d "$repo_root/lib") ]]; then
  echo "Refusing to replace non-directory or symlinked lib path: $repo_root/lib" >&2
  exit 1
fi

stage_dir="$(mktemp -d "$repo_root/.simpleclipboard-lib.XXXXXX")"
backup_dir=""
lib_mode="0755"
cleanup() {
  if [[ -n "$ssh_temporary" && -f "$ssh_temporary" ]]; then
    rm -f "$ssh_temporary"
  fi
  if [[ -n "$stage_dir" && -d "$stage_dir" ]]; then
    rm -rf "$stage_dir"
  fi
  if [[ -n "$backup_dir" && -d "$backup_dir" && ! -d "$repo_root/lib" ]]; then
    mv "$backup_dir" "$repo_root/lib"
  fi
}
trap cleanup EXIT

if [[ -d "$repo_root/lib" ]]; then
  if [[ "$(uname -s)" == "Darwin" ]]; then
    lib_mode="$(stat -f '%Lp' "$repo_root/lib")"
  else
    lib_mode="$(stat -c '%a' "$repo_root/lib")"
  fi
  cp -a "$repo_root/lib/." "$stage_dir/"
fi
install -m 0755 "$library_source" "$stage_dir/$library_name"
install -m 0755 "$daemon_source" "$stage_dir/simpleclipboard-daemon"
install -m 0755 "$client_source" "$stage_dir/simpleclipboard-client"
chmod "$lib_mode" "$stage_dir"

if [[ -d "$repo_root/lib" ]]; then
  backup_dir="$repo_root/.simpleclipboard-lib.backup.$$"
  if [[ -e "$backup_dir" ]]; then
    echo "Refusing to overwrite unexpected backup path: $backup_dir" >&2
    exit 1
  fi
  mv "$repo_root/lib" "$backup_dir"
fi
mv "$stage_dir" "$repo_root/lib"
stage_dir=""
if [[ -n "$backup_dir" ]]; then
  rm -rf "$backup_dir"
  backup_dir=""
fi

echo "Installed $("$repo_root/lib/simpleclipboard-daemon" --version)"
echo "Artifacts: $repo_root/lib/$library_name, $repo_root/lib/simpleclipboard-daemon"
echo "           and $repo_root/lib/simpleclipboard-client"

# :help simpleclipboard only resolves once tags exist, and looking up the help
# is the first thing a new user does after installing.
if [[ -d "$repo_root/doc" ]] && command -v vim >/dev/null 2>&1; then
  if vim -Nu NONE -i NONE -n -es -c 'helptags doc' -c 'qa!'; then
    echo "Help tags: $repo_root/doc/tags"
  else
    echo "Could not generate help tags; run :helptags $repo_root/doc yourself." >&2
  fi
fi

setup_ssh_tunnel() {
  local ssh_dir="$HOME/.ssh"
  local config="$ssh_dir/config"
  local begin="# simpleclipboard auto-tunnel begin"
  local end="# simpleclipboard auto-tunnel end"
  local backup
  local user_id

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  if [[ -L "$config" ]]; then
    echo "Refusing to replace symlinked SSH config: $config" >&2
    echo "Add the documented RemoteForward block to its real target manually." >&2
    return 1
  fi
  if [[ -e "$config" && ! -f "$config" ]]; then
    echo "Refusing non-regular SSH config path: $config" >&2
    return 1
  fi
  touch "$config"
  chmod 600 "$config"
  user_id="$(id -u)"

  ssh_temporary="$(mktemp "$ssh_dir/config.simpleclipboard.XXXXXX")"
  {
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { if (managed) exit 2; managed = 1; blanks = 0; next }
      $0 == end { if (!managed) exit 2; managed = 0; next }
      managed { next }
      $0 == "" { blanks += 1; next }
      {
        for (i = 0; i < blanks; i += 1) print ""
        blanks = 0
        print
      }
      END { if (managed) exit 2 }
    ' "$config"
    cat <<EOF

$begin
# Applies only while a local SimpleClipboard daemon process is running.
Match originalhost $ssh_host exec "command -v pgrep >/dev/null 2>&1 && pgrep -u $user_id -f '[s]impleclipboard-daemon' >/dev/null 2>&1"
    ExitOnForwardFailure yes
    RemoteForward $tunnel_port 127.0.0.1:$daemon_port
Match all
$end
EOF
  } >"$ssh_temporary"
  chmod 600 "$ssh_temporary"

  if command -v ssh >/dev/null 2>&1; then
    ssh -G -F "$ssh_temporary" -- "$ssh_host" >/dev/null
  fi
  if cmp -s "$config" "$ssh_temporary"; then
    rm -f "$ssh_temporary"
    ssh_temporary=""
    echo "SSH tunnel block for $ssh_host is already up to date in $config."
    return
  fi
  backup="$(mktemp "$ssh_dir/config.simpleclipboard.bak.XXXXXX")"
  cp -p "$config" "$backup"
  mv "$ssh_temporary" "$config"
  ssh_temporary=""
  echo "Added or updated the SSH tunnel block for $ssh_host in $config."
  echo "Backup: $backup"
  echo "Review the block before opening new SSH sessions."
  echo "Use a matching non-empty clipboard token on shared remote hosts."
}

if ((with_ssh_tunnel)); then
  setup_ssh_tunnel
else
  echo "SSH configuration was not changed. Use --with-ssh-tunnel explicitly if needed."
fi

echo "Restart any older daemon, then run :SimpleCopyRefresh and :SimpleCopyStatus."
