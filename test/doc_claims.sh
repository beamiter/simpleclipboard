#!/usr/bin/env bash
set -euo pipefail

# Documentation promises that only stay true while the code keeps backing them.
#
# Prose drifts silently: nothing compiles it, no assertion runs it, and a
# sentence describing a feature reads exactly the same whether or not the
# feature exists.  Two such sentences shipped — a clipboard paste with a
# pbpaste/wl-paste fallback chain that no command reaches, and an asynchronous
# client the plugin never spawns — and both were reachable by grep the whole
# time.  These checks are that grep, run by `make check`.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$repo_root"

failures=0

fail() {
  printf '%s\n' "$@" >&2
  failures=$((failures + 1))
}

user_docs=(README.md SECURITY.md doc/simpleclipboard.txt)
all_docs=("${user_docs[@]}" CHANGELOG.md)
vim_side=(autoload plugin)

# ---------------------------------------------------------------------------
# 1. A helper command named in the documentation must be one the plugin can
#    actually run.  These four only ever read a clipboard, so naming any of
#    them is a promise that SimpleClipboard pastes.
# ---------------------------------------------------------------------------
for helper in pbpaste wl-paste 'xclip -o' 'xsel -o' 'xsel --output'; do
  if grep -rqF -- "$helper" "${all_docs[@]}"; then
    if ! grep -rqF -- "$helper" "${vim_side[@]}"; then
      fail "Documentation offers \`$helper\`, which nothing under autoload/ or plugin/ runs:" \
        "$(grep -rnF -- "$helper" "${all_docs[@]}")"
    fi
  fi
done

# ---------------------------------------------------------------------------
# 1b. The documentation promises that wl-copy and wl-paste are offered only in
#     a Wayland session.  That promise was false for as long as the gate was
#     written getenv('WAYLAND_DISPLAY') !=# '': inside a compiled :def getenv()
#     answers v:null for an unset variable and `v:null !=# ''` is true, so the
#     gate admitted every machine that had the binaries.  $WAYLAND_DISPLAY is
#     an empty string when unset and is the only form that gates.  Behaviour is
#     pinned by tests/vim_remote.vim; this keeps the shape that broke it from
#     coming back by hand.
# ---------------------------------------------------------------------------
if grep -rqF 'WAYLAND_DISPLAY' "${user_docs[@]}"; then
  if ! grep -rqF '$WAYLAND_DISPLAY !=#' "${vim_side[@]}"; then
    fail "Documentation says wl-copy/wl-paste need \$WAYLAND_DISPLAY, but nothing under autoload/ or plugin/ gates on it."
  fi
  # Comment lines are skipped: the one at the gate explains this very trap.
  wayland_getenv="$(grep -rn "getenv( *'WAYLAND_DISPLAY' *)" "${vim_side[@]}" \
    | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
  if [[ -n "$wayland_getenv" ]]; then
    fail "getenv('WAYLAND_DISPLAY') is not a gate in a compiled :def - it answers v:null, and v:null !=# '' is true:" \
      "$wayland_getenv"
  fi
fi

# ---------------------------------------------------------------------------
# 2. Every :Simple… command the user documentation mentions must be defined.
#    A paste command promised in prose and missing from plugin/ is exactly the
#    shape of the SECURITY.md defect.
# ---------------------------------------------------------------------------
while read -r documented; do
  [[ -n "$documented" ]] || continue
  name="${documented#:}"
  if ! grep -qE "^command!.*[[:space:]]${name}([[:space:]]|$)" plugin/simpleclipboard.vim; then
    fail "Documentation mentions :${name}, which plugin/simpleclipboard.vim does not define."
  fi
done < <(grep -rhoE ':Simple[A-Za-z]+' "${user_docs[@]}" | sort -u)

# ---------------------------------------------------------------------------
# 3. simpleclipboard-client is designed to be driven with job_start(), but the
#    Vim side does not spawn it: every copy still goes through the synchronous
#    libcallnr() entry points.  While that is so, each file that introduces the
#    binary to a reader must carry the caveat — and once the plugin does drive
#    it, the caveat becomes the lie and has to go.  The check runs both ways so
#    that neither half of the change can land alone.
# ---------------------------------------------------------------------------
# Matched case-insensitively: the same sentence starts a paragraph in one file
# and finishes one in another.
english_caveat='the plugin does not drive it yet'
chinese_caveat='插件目前还没有驱动它'
english_files=(Cargo.toml README.md src/simpleclipboard/simpleclipboard_client.rs)
chinese_files=(CHANGELOG.md doc/simpleclipboard.txt)

if grep -rqF 'simpleclipboard-client' "${vim_side[@]}"; then
  for file in "${english_files[@]}"; do
    if grep -qiF "$english_caveat" "$file"; then
      fail "$file still says \"$english_caveat\", but the Vim side now references simpleclipboard-client."
    fi
  done
  for file in "${chinese_files[@]}"; do
    if grep -qiF "$chinese_caveat" "$file"; then
      fail "$file still says \"$chinese_caveat\", but the Vim side now references simpleclipboard-client."
    fi
  done
else
  for file in "${english_files[@]}"; do
    if ! grep -qiF "$english_caveat" "$file"; then
      fail "$file describes simpleclipboard-client without saying \"$english_caveat\"; nothing under autoload/ or plugin/ spawns it."
    fi
  done
  for file in "${chinese_files[@]}"; do
    if ! grep -qiF "$chinese_caveat" "$file"; then
      fail "$file describes simpleclipboard-client without saying \"$chinese_caveat\"; nothing under autoload/ or plugin/ spawns it."
    fi
  done

  # The exact sentences that shipped the false claim, kept out by name so a
  # copy-paste cannot quietly restore them.
  for claim in \
    'binary the plugin drives with' \
    'Vim drives simpleclipboard-client with' \
    'the transport Vim drives with' \
    'so Vim can make it with' \
    "Vim 用 \`job_start()\` 驱动它"; do
    # --exclude keeps this file's own list of forbidden sentences from
    # matching itself.
    if grep -rqF --exclude=doc_claims.sh -- "$claim" Cargo.toml src test "${all_docs[@]}"; then
      fail "\"$claim\" claims the plugin drives simpleclipboard-client; nothing under autoload/ or plugin/ spawns it:" \
        "$(grep -rnF --exclude=doc_claims.sh -- "$claim" Cargo.toml src test "${all_docs[@]}")"
    fi
  done
fi

if [[ "$failures" -ne 0 ]]; then
  echo "$failures documentation claim(s) are not backed by the code." >&2
  exit 1
fi

echo 'Documentation claims match the code'
