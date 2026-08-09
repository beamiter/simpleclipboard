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

# $SELF_TEST_EXIT lets the same stub stand in for a build that works and one
# that links but does not run.
cat >"$scratch/stub-bin/cargo" <<STUB
#!/bin/sh
release="\$CARGO_TARGET_DIR/stub-target/release"
mkdir -p "\$release"
: >"\$release/$stub_library"
cat >"\$release/simpleclipboard-daemon" <<DAEMON
#!/bin/sh
case "\\\$1" in
  --self-test)
    if [ "\\\${SELF_TEST_EXIT:-1}" -ne 0 ]; then
      echo "sealing the request: stub failure" >&2
      exit "\\\$SELF_TEST_EXIT"
    fi
    echo ok
    ;;
  --version) echo "simpleclipboard-daemon 0.0.0-stub" ;;
esac
DAEMON
: >"\$release/simpleclipboard-client"
chmod 755 "\$release/simpleclipboard-daemon" "\$release/simpleclipboard-client"
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

# simpleclipboard-client is the only way to reach a Get, and the documentation
# points users at lib/simpleclipboard-client by name, so an install that ships
# only the daemon leaves that instruction pointing at nothing.  A successful
# install must place all three artifacts, and none of them may be left behind
# by the failed attempt above.
mkdir -p "$scratch/ok-root/lib"
cp "$repo_root/install.sh" "$scratch/ok-root/install.sh"
PATH="$scratch/stub-bin:$PATH" CARGO_TARGET_DIR="$scratch/ok-target" \
  SELF_TEST_EXIT=0 "$scratch/ok-root/install.sh" >"$scratch/ok-output" 2>&1
for artifact in "$stub_library" simpleclipboard-daemon simpleclipboard-client; do
  if [[ ! -e "$scratch/ok-root/lib/$artifact" ]]; then
    echo "install.sh did not install $artifact" >&2
    cat "$scratch/ok-output" >&2
    exit 1
  fi
done
