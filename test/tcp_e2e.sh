#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
# shellcheck source=e2e_skip_rules.sh
source "$repo_root/test/e2e_skip_rules.sh"
daemon="$repo_root/lib/simpleclipboard-daemon"
client="$repo_root/lib/simpleclipboard-client"
case "$(uname -s)" in
  Darwin) library="$repo_root/lib/libsimpleclipboard.dylib" ;;
  *) library="$repo_root/lib/libsimpleclipboard.so" ;;
esac

if [[ ! -x "$daemon" || ! -x "$client" || ! -f "$library" ]]; then
  echo "Run ./install.sh before test/tcp_e2e.sh" >&2
  exit 1
fi

temporary="$(mktemp -d "${TMPDIR:-/tmp}/simpleclipboard-tcp-e2e.XXXXXX")"
token='simpleclipboard-e2e-long-random-test-key'
daemon_pid=''

cleanup() {
  if [[ -n "$daemon_pid" ]]; then
    kill -TERM "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  rm -rf "$temporary"
}
trap cleanup EXIT

wait_for_port() {
  local log="$1"
  local port
  for _ in {1..100}; do
    port="$(sed -n 's/.*Listening on 127\.0\.0\.1:\([0-9][0-9]*\).*/\1/p' "$log" | head -1)"
    if [[ -n "$port" ]]; then
      printf '%s\n' "$port"
      return 0
    fi
    if [[ -n "$daemon_pid" ]] && ! kill -0 "$daemon_pid" 2>/dev/null; then
      break
    fi
    sleep 0.02
  done
  echo "daemon did not become ready" >&2
  sed -n '1,80p' "$log" >&2 || true
  return 1
}

vim_ping() {
  local port="$1"
  local key="$2"
  local output="$3"
  vim -Nu NONE -i NONE -n -es \
    -c "let sep = nr2char(1)" \
    -c "let payload = 'SCB2' .. sep .. '127.0.0.1:${port}' .. sep .. 'ping' .. sep .. '${key}' .. sep" \
    -c "let result = libcallnr('${library}', 'rust_set_clipboard_tcp_v2', payload)" \
    -c "call writefile([string(result)], '${output}')" \
    -c 'qa!'
}

authenticated_log="$temporary/authenticated.log"
authenticated_pid="$temporary/authenticated.pid"
SIMPLECLIPBOARD_ADDR='127.0.0.1:0' \
SIMPLECLIPBOARD_TOKEN="$token" \
SIMPLECLIPBOARD_PID_FILE="$authenticated_pid" \
  "$daemon" >"$authenticated_log" 2>&1 &
daemon_pid=$!
authenticated_port="$(wait_for_port "$authenticated_log")"

vim_ping "$authenticated_port" "$token" "$temporary/correct"
vim_ping "$authenticated_port" 'definitely-wrong-token' "$temporary/wrong"
[[ "$(<"$temporary/correct")" == 1 ]]
[[ "$(<"$temporary/wrong")" == 0 ]]

# The client binary carries the same requests as the in-process library and is
# the only way to reach a Get, so it is exercised here rather than only through
# libcall.  A ping needs no display server, so it is asserted unconditionally;
# a real set/get round trip does, and only a runner without one may skip it —
# see round_trip_skip_is_allowed in test/e2e_skip_rules.sh.
SIMPLECLIPBOARD_TOKEN="$token" \
  "$client" --address "127.0.0.1:$authenticated_port" --action ping
if ! SIMPLECLIPBOARD_TOKEN='definitely-wrong-token' \
  "$client" --address "127.0.0.1:$authenticated_port" --action ping 2>/dev/null; then
  : # A wrong token must not be accepted.
else
  echo 'client accepted a wrong token' >&2
  exit 1
fi

# The clipboard payload never appears in argv, where every process on the host
# could read it out of /proc; assert the option that would carry it is refused.
if "$client" --address "127.0.0.1:$authenticated_port" --action set \
  --text secret >/dev/null 2>&1; then
  echo 'client accepted clipboard text as a command-line argument' >&2
  exit 1
fi

clipboard_text=$'round trip\n第二行\ttab'
if printf '%s' "$clipboard_text" | SIMPLECLIPBOARD_TOKEN="$token" \
  "$client" --address "127.0.0.1:$authenticated_port" --action set 2>"$temporary/set.err"; then
  SIMPLECLIPBOARD_TOKEN="$token" \
    "$client" --address "127.0.0.1:$authenticated_port" --action get \
    >"$temporary/get.out"
  if [[ "$(<"$temporary/get.out")" != "$clipboard_text" ]]; then
    echo 'clipboard round trip did not preserve the text' >&2
    exit 1
  fi
  echo 'Clipboard set/get round trip passed'
elif round_trip_skip_is_allowed "$temporary/set.err"; then
  echo 'Skipping the set/get round trip: no display server on this host'
  sed -n '1,10p' "$temporary/set.err"
else
  echo 'The client could not set the clipboard, and not because this host has' >&2
  echo 'no display server, so the round trip is a failure rather than a skip:' >&2
  sed -n '1,40p' "$temporary/set.err" >&2
  exit 1
fi

kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=''
[[ ! -e "$authenticated_pid" ]]

plaintext_log="$temporary/plaintext.log"
plaintext_pid="$temporary/plaintext.pid"
env -u SIMPLECLIPBOARD_TOKEN \
  SIMPLECLIPBOARD_ADDR='127.0.0.1:0' \
  SIMPLECLIPBOARD_PID_FILE="$plaintext_pid" \
  "$daemon" >"$plaintext_log" 2>&1 &
daemon_pid=$!
plaintext_port="$(wait_for_port "$plaintext_log")"
vim_ping "$plaintext_port" '' "$temporary/plaintext"
[[ "$(<"$temporary/plaintext")" == 1 ]]

# Writing to a tokenless daemon is a nuisance; reading from one would let every
# account that can reach loopback poll for whatever the user last copied.  The
# refusal is part of the protocol, not of the plugin, so it is asserted here.
if env -u SIMPLECLIPBOARD_TOKEN "$client" \
  --address "127.0.0.1:$plaintext_port" --action get \
  >"$temporary/open_get.out" 2>"$temporary/open_get.err"; then
  echo 'tokenless daemon answered a clipboard read' >&2
  exit 1
fi
grep -q 'get_requires_authentication' "$temporary/open_get.err"
[[ ! -s "$temporary/open_get.out" ]]

kill -TERM "$daemon_pid"
wait "$daemon_pid"
daemon_pid=''
[[ ! -e "$plaintext_pid" ]]

if env -u SIMPLECLIPBOARD_TOKEN \
  SIMPLECLIPBOARD_ADDR='0.0.0.0:0' \
  SIMPLECLIPBOARD_PID_FILE=- \
  "$daemon" >"$temporary/exposure.log" 2>&1; then
  echo 'non-loopback daemon unexpectedly started without a token' >&2
  exit 1
fi
grep -q 'refusing non-loopback TCP listener without SIMPLECLIPBOARD_TOKEN' \
  "$temporary/exposure.log"

echo 'TCP protocol end-to-end checks passed'
