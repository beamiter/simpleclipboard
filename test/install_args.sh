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

# A build that links but does not run must never replace a working lib/.  The
# installer is exercised against a stub toolchain in a scratch directory: it
# resolves its own root from BASH_SOURCE, so a copy of the script is a complete
# installation as far as this test is concerned and the real lib/ is untouched.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/simpleclipboard-install-gate.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

case "$(uname -s)" in
  Darwin) stub_library="libsimpleclipboard.dylib" ;;
  *) stub_library="libsimpleclipboard.so" ;;
esac

mkdir -p "$scratch/stub-bin" "$scratch/root/lib"
cp "$repo_root/install.sh" "$scratch/root/install.sh"
printf 'previous install\n' >"$scratch/root/lib/sentinel"

cat >"$scratch/stub-bin/rustc" <<'STUB'
#!/bin/sh
printf 'host: stub-target\n'
STUB

cat >"$scratch/stub-bin/cargo" <<STUB
#!/bin/sh
release="\$CARGO_TARGET_DIR/stub-target/release"
mkdir -p "\$release"
: >"\$release/$stub_library"
cat >"\$release/simpleclipboard-daemon" <<'DAEMON'
#!/bin/sh
case "\$1" in
  --self-test) echo "sealing the request: stub failure" >&2; exit 1 ;;
  --version) echo "simpleclipboard-daemon 0.0.0-stub" ;;
esac
DAEMON
chmod 755 "\$release/simpleclipboard-daemon"
STUB

chmod 755 "$scratch/stub-bin/rustc" "$scratch/stub-bin/cargo"

if PATH="$scratch/stub-bin:$PATH" CARGO_TARGET_DIR="$scratch/target" \
    "$scratch/root/install.sh" >"$scratch/output" 2>&1; then
  echo "install.sh installed a daemon that fails --self-test" >&2
  cat "$scratch/output" >&2
  exit 1
fi
if [[ -e "$scratch/root/lib/simpleclipboard-daemon" ]]; then
  echo "a daemon failing --self-test reached lib/" >&2
  exit 1
fi
if [[ ! -f "$scratch/root/lib/sentinel" ]]; then
  echo "install.sh disturbed the previous lib/ after a failed self-test" >&2
  exit 1
fi
if ! grep -q 'failed --self-test' "$scratch/output"; then
  echo "install.sh did not explain the self-test failure" >&2
  cat "$scratch/output" >&2
  exit 1
fi
