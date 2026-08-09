#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# The skip in test/tcp_e2e.sh is taken on every CI Linux run, so the predicate
# that grants it is exercised far more often than the round trip it replaces.
# These checks pin what may and may not buy that skip; test/tcp_e2e.sh itself
# needs a built daemon and a live port, which is why the decision is tested
# here instead of there.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=e2e_skip_rules.sh
source "$here/e2e_skip_rules.sh"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/simpleclipboard-skip-rules.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

headless="$scratch/headless.err"
printf '%s\n' \
  'simpleclipboard-client: daemon refused the request: clipboard_unavailable' \
  >"$headless"

framing="$scratch/framing.err"
printf '%s\n' 'simpleclipboard-client: framing bug' >"$framing"

usage_error="$scratch/usage.err"
printf '%s\n' 'simpleclipboard-client: unknown option: --action' >"$usage_error"

empty="$scratch/empty.err"
: >"$empty"

headless_verdict() {
  ( unset DISPLAY WAYLAND_DISPLAY; round_trip_skip_is_allowed "$1" )
}

x11_verdict() {
  ( unset WAYLAND_DISPLAY; export DISPLAY=':0'; round_trip_skip_is_allowed "$1" )
}

wayland_verdict() {
  ( unset DISPLAY; export WAYLAND_DISPLAY='wayland-0'; round_trip_skip_is_allowed "$1" )
}

expect_skip() {
  if ! "$1" "$2"; then
    echo "expected a skip: $1 $2" >&2
    exit 1
  fi
}

expect_failure() {
  if "$1" "$2"; then
    echo "expected a failure rather than a skip: $1 $2" >&2
    exit 1
  fi
}

# The one cause a skip exists for.
expect_skip headless_verdict "$headless"

# Everything else is a regression in the client's set path wearing the
# headless runner's clothes.
expect_failure headless_verdict "$framing"
expect_failure headless_verdict "$usage_error"
expect_failure headless_verdict "$empty"
expect_failure headless_verdict "$scratch/never-written.err"

# A graphical host must complete the round trip, whatever the client said.
expect_failure x11_verdict "$headless"
expect_failure wayland_verdict "$headless"

echo 'End-to-end skip rules passed'
