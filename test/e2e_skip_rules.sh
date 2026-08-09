#!/usr/bin/env bash
# Rules deciding when an end-to-end check may report a skip instead of a
# failure.  They live in their own sourceable file, rather than inline in
# test/tcp_e2e.sh, so that test/e2e_skip_rules_test.sh can drive them without a
# daemon, a display server or a listening socket.
#
# A skip is a hole in the suite: the run stays green while the assertions
# behind it never execute.  The clipboard round trip needs a real display
# server and the CI Linux runner has none, so that one hole has to exist — but
# it must have exactly one cause, and nothing else may borrow it.  When any
# nonzero exit could produce the skip, a broken stdin read, a renamed token
# environment variable or a framing regression in the client all look exactly
# like a headless runner, and ship with the suite reporting success.

# Usage: round_trip_skip_is_allowed STDERR_FILE
#
# Succeeds only when the client's stderr shows the one refusal a runner
# without a display server produces — the daemon could not open a clipboard at
# all — and only on a host that had no display server to open one with.
round_trip_skip_is_allowed() {
  local stderr_file="${1:-}"

  # A host with a display server has no excuse for failing the round trip, and
  # that includes failing it with clipboard_unavailable: a daemon that cannot
  # reach the display server it was given is a bug, not a missing runner
  # feature.  macOS has a clipboard and no DISPLAY, which is why the display
  # variables gate the skip rather than being required for the round trip.
  if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    return 1
  fi

  # An empty or absent stderr says nothing about why the client failed, so it
  # cannot buy a skip either.
  [[ -s "$stderr_file" ]] || return 1

  grep -q 'clipboard_unavailable' "$stderr_file"
}
