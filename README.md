# SimpleClipboard

SimpleClipboard makes copying from Vim to the system clipboard reliable even
when Vim was built without `+clipboard`.

Version 0.2 uses a small Rust client library and a local clipboard daemon over
loopback TCP. It also supports SSH and container workflows, native copy
commands, and OSC52 as progressively more portable fallbacks.

> [!IMPORTANT]
> Version 0.2 standardizes the shipped implementation on loopback TCP and
> removes the stale Unix-socket/socket-activation guidance from the 0.1 docs.
> If you are upgrading, rebuild both Rust artifacts, stop the old daemon, and
> remove any `simpleclipboard.socket` unit created from those docs. See
> [Upgrading from 0.1](#upgrading-from-01).

## Highlights

- Copies normal yanks automatically through `TextYankPost`.
- Provides a safe default mapping on `<leader>y` without replacing Vim's `y`.
- Preserves exact Visual selections, including characterwise and blockwise
  selections.
- Can explicitly copy any Vim register, clear the system clipboard, and limit
  automatic copying by source register or payload size.
- Uses a framed, acknowledged TCP protocol with a 10 MiB message limit.
- Supports X11, native Wayland data control, macOS, and WSL.
- Detects local, SSH, container, and nested SSH/container environments.
- Falls back to a configured command, `pbcopy`, `wl-copy`, `clip.exe`, `xsel`,
  `xclip`, or OSC52 when the daemon path is unavailable.
- Exposes status and refresh commands for diagnostics.
- Copies the remote path, not the local mount path, from files SimpleRemote
  opens, and offers the other simple* plugins a stable copy/paste API.

## Compatibility

| Environment | Preferred path | Available fallbacks |
| --- | --- | --- |
| Linux/X11 | Rust daemon with arboard | `xsel`, `xclip`, OSC52 |
| Linux/Wayland | Rust daemon with arboard `wayland-data-control` | `wl-copy` (only when `$WAYLAND_DISPLAY` is set), XWayland tools, OSC52 |
| macOS | Rust daemon with arboard | `pbcopy`, OSC52 |
| WSL | `clip.exe` | Explicit authenticated daemon, OSC52 |
| SSH | Explicit address or loopback `RemoteForward` | OSC52, remote copy command |
| Container | Reachable host daemon when configured/detected | OSC52, container copy command |

SimpleClipboard is a Vim9 plugin and does not support Neovim. The supported
baseline is Vim 9.0 or newer with `+job` and `+channel`. `+timers` enables
debouncing; without it, automatic copies run immediately.
`+libcall` is required for the Rust client library; command and OSC52
fallbacks can still be used when `+libcall` is unavailable. The Rust daemon
path also requires Vim's `&encoding` to be `utf-8`.

Building the Rust backend requires a Rust toolchain compatible with the
`rust-version` declared in [Cargo.toml](Cargo.toml). On Debian/Ubuntu, install
the native build requirements with
`sudo apt-get install pkg-config libwayland-dev libxkbcommon-dev`. Optional
fallback tools are listed in the table above; OSC52 also requires `base64` and
a terminal that permits OSC52 clipboard writes.

## Installation

### vim-plug

~~~vim
Plug 'beamiter/simpleclipboard', { 'do': './install.sh' }
~~~

Then run `:PlugInstall` or `:PlugUpdate`.

### Vim packages

~~~sh
git clone https://github.com/beamiter/simpleclipboard.git \
  ~/.vim/pack/plugins/start/simpleclipboard
cd ~/.vim/pack/plugins/start/simpleclipboard
./install.sh
~~~

The installer builds the release daemon, the client library and the client
binary, and places them in the plugin's `lib/` directory:

- Linux: `lib/libsimpleclipboard.so`, `lib/simpleclipboard-daemon` and
  `lib/simpleclipboard-client`
- macOS: `lib/libsimpleclipboard.dylib`, `lib/simpleclipboard-daemon` and
  `lib/simpleclipboard-client`

`lib/simpleclipboard-client` sends one daemon request per run — `ping`, `set`
from standard input, or `get` to standard output — reading the pre-shared key
from `SIMPLECLIPBOARD_TOKEN`. It is the only way to reach a `get`, because
`libcallnr()` can return nothing but a number. `--selection clipboard|primary`
applies to `get` only: SCB1 has no room for a selection in a `set`, so every
write goes to CLIPBOARD, and naming a selection on a `set` or a `ping` is a
usage error (exit 64) rather than a silent write to the other selection.
Note that **the plugin does not drive it yet**: Vim still makes every copy
through the synchronous library entry points, and no Vim command reads the
clipboard. Run it yourself if you want a `get`.

Before any artifact is moved into place, the installer runs
`simpleclipboard-daemon --self-test` on the binary it just built — one
authenticated request through key derivation, sealing, framing and the response
binding, without touching the desktop clipboard. A build that compiles but does
not run therefore never replaces a working `lib/`. It also generates the help
tags, so `:help simpleclipboard` works immediately.

The plugin must remain on Vim's `runtimepath` so it can discover these files.
You can instead set absolute paths with `g:simpleclipboard_libpath` and
`g:simpleclipboard_daemon_path`.

The installer always builds for the current `rustc` host target. This prevents
a Cargo `build.target` setting or stale cross-compiled artifact from being
installed into the running Vim by mistake.

SSH configuration is optional and should be requested explicitly:

~~~sh
./install.sh --with-ssh-tunnel --ssh-host my-workstation
~~~

Replace `my-workstation` with one exact host alias from `~/.ssh/config`.
Wildcards are rejected so the reverse forward cannot silently affect unrelated
SSH destinations. Review the generated OpenSSH configuration before relying on
it. The managed `Match` block is evaluated when an SSH connection opens and is
enabled only when `pgrep` finds a local `simpleclipboard-daemon`; reconnect
after starting the daemon. The installer owns one managed host block, so using
a different `--ssh-host` replaces it; configure manual `Host` blocks when
several aliases need forwards.

Custom tunnel ports can be written explicitly:

~~~sh
./install.sh --with-ssh-tunnel --ssh-host my-workstation \
  --daemon-port 12343 --tunnel-port 12345
~~~

These options only change the managed SSH block. Keep the daemon's
`SIMPLECLIPBOARD_ADDR`, `g:simpleclipboard_port`, and
`g:simpleclipboard_tunnel_port` synchronized yourself, and update an explicit
`g:simpleclipboard_address` if it contains the old tunnel port.

## Quick start

No configuration is required for a local desktop:

- Yank normally with `y`. Successful yank operations are copied automatically.
- Press `<leader>y` in Normal mode to copy the unnamed register.
- Select text and press `<leader>y` to copy the exact Visual selection.
- Run `:SimpleCopyRegister a` to copy register `a`, or `:SimpleCopyClear` to
  explicitly clear the clipboard.
- Run `:SimpleCopyPath` / `:SimpleCopyLocation` to share the current file or
  exact 1-based cursor location; add `!` for an absolute path.
- Run `:SimpleCopyStatus` to inspect the selected backend and address.

To disable automatic copy while keeping the commands and mappings:

~~~vim
let g:simpleclipboard_auto_copy = 0
~~~

That option is re-read on every yank, so a runtime change takes effect at once.
`:SimpleCopyToggle` flips it and reports the new state, and `:SimpleCopyPause
60` suspends automatic copy for a minute before restoring the previous value —
what you want one keystroke before yanking a credential.

To provide your own mappings:

~~~vim
let g:simpleclipboard_no_default_mappings = 1
nmap <leader>Y <Plug>(SimpleCopyYank)
xmap <leader>Y <Plug>(SimpleCopyVisual)
~~~

## Commands

| Command | Description |
| --- | --- |
| `:SimpleCopyYank` | Copy the unnamed register. |
| `:SimpleCopyRegister [name]` | Copy any Vim register (`unnamed`, `clipboard`, and `primary` are accepted aliases). |
| `:SimpleCopyVisual` | Copy the most recent Visual selection exactly. |
| `:[range]SimpleCopyRange` | Copy complete lines in the range; without a range, copy the whole buffer. |
| `:SimpleCopyClear` | Clear the system clipboard through the normal confirmed/fallback pipeline. |
| `:SimpleCopyPath[!]` | Copy the current file path relative to the effective cwd; use `!` for absolute. In a SimpleRemote buffer, the remote path relative to the workspace root. |
| `:SimpleCopyLocation[!]` | Copy `path:line:column` with 1-based character positions; use `!` for absolute. |
| `:SimpleCopyFormat[!] {template}` | Copy a custom file reference using `{path}`, `{dir}`, `{file}`, `{line}`, and `{column}`; `!` makes path fields absolute. |
| `:SimpleCopyToggle` | Turn automatic copy on or off immediately and report the new state. |
| `:SimpleCopyPause {seconds}` | Suspend automatic copy for 1..86400 seconds, then restore the previous value. |
| `:SimpleCopyStart` | Start the configured local daemon if needed. |
| `:SimpleCopyStop` | Stop only the daemon job started by this Vim instance. |
| `:SimpleCopyStatus` | Always print environment, address, and backend diagnostics. |
| `:SimpleCopyRefresh` | Clear environment/backend caches and detect them again. |
| `:SimpleCopyLog` | Open the transcript: notifications, failed backends, route decisions, and the route each copy took — recorded whether or not debug logging was on. |

Path and location commands preserve spaces and UTF-8 literally rather than
copying shell-escaped text. They fail visibly for unnamed and non-file buffers,
and use the same acknowledged daemon, serialized external-command, and OSC52
fallback pipeline as every other explicit copy. In a buffer that
[SimpleRemote](https://github.com/beamiter/simpleremote) opened from a remote
workspace they copy the remote path — see
[SimpleRemote workspaces](#simpleremote-workspaces). Optional Normal-mode mapping
targets are `<Plug>(SimpleCopyPath)` and `<Plug>(SimpleCopyLocation)`.
`<Plug>(SimpleCopyFormat)` opens a prefilled command line so a template can be
entered interactively, and `<Plug>(SimpleCopyToggle)` switches automatic copy.

Format templates are literal text plus the five documented placeholders.
Write `{{` or `}}` for a literal brace. Empty templates, unknown placeholders,
nested braces, and unmatched braces fail before any clipboard backend runs;
inserted path text is never evaluated or expanded a second time.

## Configuration

Set options before the plugin is loaded, normally in `vimrc`. The exception is
`g:simpleclipboard_auto_copy`, which is re-read on every yank; after changing
any other option run `:SimpleCopyRefresh`.

### Core behavior

| Option | Default | Meaning |
| --- | --- | --- |
| `g:simpleclipboard_daemon_enabled` | `1` | Enable the Rust daemon backend. |
| `g:simpleclipboard_daemon_autostart` | `1` | Start a local daemon on `VimEnter` when appropriate. A Vim that finds the address already taken uses that daemon instead of forking a second one. |
| `g:simpleclipboard_daemon_autostop` | `0` | On exit, stop only the daemon job owned by this Vim instance. |
| `g:simpleclipboard_auto_copy` | `1` | Copy successful yank operations from `TextYankPost`. Re-read on every yank, so runtime changes apply immediately; see `:SimpleCopyToggle` and `:SimpleCopyPause`. |
| `g:simpleclipboard_auto_copy_registers` | `[]` | Automatic-copy register allow-list; empty preserves all registers except `_`. Use `['unnamed']` to accept only ordinary yanks. |
| `g:simpleclipboard_auto_copy_max_bytes` | `0` | Maximum automatic-yank payload in UTF-8 bytes; `0` — or any value that reads as zero or less — is unlimited. Explicit copy commands are never capped. |
| `g:simpleclipboard_debounce_ms` | `50` | Debounce automatic copy by this many milliseconds. |
| `g:simpleclipboard_no_default_mappings` | `0` | Do not create the `<leader>y` mappings. |

### Paths and routing

| Option | Default | Meaning |
| --- | --- | --- |
| `g:simpleclipboard_libpath` | `''` | Absolute client-library path; empty means search `runtimepath/lib`. |
| `g:simpleclipboard_daemon_path` | `''` | Absolute daemon path; empty means search `runtimepath/lib`. |
| `g:simpleclipboard_bind_addr` | `'127.0.0.1'` | Address used by a daemon started by Vim. |
| `g:simpleclipboard_port` | `12343` | Local daemon TCP port. |
| `g:simpleclipboard_tunnel_port` | `12345` | Loopback port expected from an SSH reverse tunnel. |
| `g:simpleclipboard_address` | `''` | Explicit `host:port`. When non-empty, it overrides environment and port detection. |
| `g:simpleclipboard_token` | `''` | Optional UTF-8 pre-shared key, at most 4096 bytes and without U+0001. A matching non-empty value enables authenticated encryption; it is required for remote, custom, and non-loopback routes. |
| `g:simpleclipboard_container_host` | `''` | Optional container-host name or IP; empty means inspect the default route and `host.docker.internal`. |

### Fallbacks

| Option | Default | Meaning |
| --- | --- | --- |
| `g:simpleclipboard_copy_command` | `[]` | Custom copy command as `list<string>` argv, for example `['wl-copy']`. No shell is used; the process must stay attached until its clipboard write is complete. |
| `g:simpleclipboard_paste_command` | `[]` | Custom clipboard-reading command as `list<string>` argv whose standard output is the clipboard text, for example `['wl-paste', '--no-newline']`. Used only by `simpleclipboard#PasteText()`, and only for the CLIPBOARD selection; the plugin itself defines no paste command. |
| `g:simpleclipboard_paste_timeout_ms` | `10000` | How long `simpleclipboard#PasteText()` waits for one paste program before stopping it and trying the next. Must be positive. |
| `g:simpleclipboard_disable_osc52` | `0` | Disable the OSC52 fallback. |
| `g:simpleclipboard_osc52_limit` | `75000` | Maximum UTF-8 payload bytes accepted by the OSC52 path. Must be a positive number; `0`, a negative number or a value that cannot be read as one blocks OSC52 entirely rather than falling back to the default. |
| `g:simpleclipboard_osc52_truncate` | `0` | When `0`, reject oversized OSC52 payloads without data loss; when `1`, truncate to the configured limit on a character boundary. |
| `g:simpleclipboard_osc52_terminator` | `'bel'` | Terminator for the OSC 52 sequence: `'bel'` (BEL, `0x07`) or `'st'` (the standard string terminator, `ESC \`). |
| `g:simpleclipboard_osc52_selection` | `'c'` | Which selection OSC 52 writes: `'c'` for CLIPBOARD or `'p'` for the X11/Wayland PRIMARY selection. This affects the OSC52 path only; the daemon and external-command backends still write CLIPBOARD. |
| `g:simpleclipboard_osc52_tty` | `''` | Where the escape sequence is written. Empty prefers `echoraw()` into the terminal Vim is driving and falls back to `/dev/tty`; set it to a device path when only you know which terminal is the display. |

OSC52 is the final fallback after the daemon and command candidates. If it
rejects an oversized value, the copy operation therefore fails visibly.
Truncation is opt-in because a silent partial clipboard is usually worse than
a clear failure.

Multiplexers are handled automatically. With `$TMUX` set, the sequence is
wrapped for tmux passthrough. Under screen — detected by `$STY`, `'term'`, or
`$TERM` beginning with `screen` — it is wrapped in a DCS envelope, and a
sequence longer than 768 bytes is split across several envelopes: screen
truncates an over-long DCS string without a word, which is exactly the silent
half-copy `g:simpleclipboard_osc52_truncate` exists to refuse. Enumerated
values are matched case-insensitively, and an unusable one is reported once and
replaced by the documented default.

### Diagnostics

| Option | Default | Meaning |
| --- | --- | --- |
| `g:simpleclipboard_debug` | `0` | Enable detailed plugin diagnostics. |
| `g:simpleclipboard_debug_to_file` | `0` | Write debug messages to a file instead of `:messages`. |
| `g:simpleclipboard_debug_file` | private state log | Override the debug-log path. The default is `$XDG_STATE_HOME/simpleclipboard/simpleclipboard.log`, or `~/.local/state/simpleclipboard/simpleclipboard.log`. |

The default log directory is forced to mode `0700` and the file to `0600`.
For a custom debug path, create a private regular file and parent directory
yourself; custom paths are not permission- or symlink-checked. Write failures
fall back to `:messages`.

A mistyped option is reported, not fatal. Plugin load, `:SimpleCopyRefresh` and
`:SimpleCopyStatus` each print one line per problem naming the expected type,
the value seen, and what happens instead:

~~~
g:simpleclipboard_port must be a positive number, but is a string ("12343"); using the default 12343
g:simpleclipboard_debounce_ms must be a number, but is a string ("soon"); using the default 50
~~~

Numeric strings are read as decimal, since quoting a port is a common habit,
and a boolean is read as the 0 or 1 it coerces to; anything else falls back to
the documented default. Each message names the value really in force, never a
default that is not. The three options that decide what may leave Vim —
`g:simpleclipboard_auto_copy_registers`, `g:simpleclipboard_auto_copy_max_bytes`
and `g:simpleclipboard_osc52_limit` — fail closed rather than guess a more
permissive default when their value cannot be used: the first two skip
automatic copy when the value cannot be read at all, and an unreadable or
non-positive OSC52 limit blocks the OSC52 path. Quoting changes nothing there:
`'0'` and `'-5'` block OSC52 exactly as `0` and `-5` do, and the message says
so rather than naming the 75000-byte default it does not reinstate. A quoted
byte cap is still a byte cap and is applied as one — but a cap of zero or less
is not a cap at all, since the automatic-copy limit is enforced only when it is
positive, so `'-5'` is reported as `using -5, which applies no cap` rather than
as a cap no yank will ever meet, and `:SimpleCopyStatus` prints the same thing
as `max=unlimited`.
`g:simpleclipboard_token` is
reported by type and length only, never by value. List elements are checked
too: `g:simpleclipboard_copy_command` must be a list of non-empty strings and
`g:simpleclipboard_auto_copy_registers` a list of strings.

`:SimpleCopyStatus` is intentionally visible even when debug logging is off,
and it does not itself fail on a misconfigured option — the moment you need it
most is the moment the configuration is broken. The token is reported by state
only, never by value: `token=off`, `token=configured`, or
`token=invalid (must be a string)`.
Its daemon health is a real protocol ping; command and OSC52 entries only show
detected candidates or basic prerequisites, not a guaranteed clipboard write.
The `paste:` line lists what `simpleclipboard#PasteText()` would try for the
CLIPBOARD selection, in order — the `"+` register when this Vim has
`+clipboard`, then the paste programs found — or `none`.
Use `:SimpleCopyRefresh` after changing routing options or after an SSH tunnel,
display server, or container network becomes available. If this Vim owns a
running daemon, refresh stops it and restarts it with the new local
configuration—even when automatic startup is disabled.

### Example

~~~vim
" Keep the daemon private to this machine.
let g:simpleclipboard_bind_addr = '127.0.0.1'
let g:simpleclipboard_port = 12343

" Refuse partial OSC52 copies.
let g:simpleclipboard_osc52_limit = 75000
let g:simpleclipboard_osc52_truncate = 0

" Optional explicit fallback, passed directly as argv.
" let g:simpleclipboard_copy_command = ['wl-copy', '--type', 'text/plain']

" Enable logs temporarily while diagnosing.
let g:simpleclipboard_debug = 1
let g:simpleclipboard_debug_to_file = 1
~~~

## How it works

The preferred local flow is:

~~~text
Vim
  -> libcallnr() client library
  -> 127.0.0.1:12343
  -> simpleclipboard-daemon
  -> arboard
  -> desktop clipboard
~~~

Vim calls the versioned client ABI as
`SCB2\x01address\x01action\x01token\x01text`. Keeping text last preserves
embedded U+0001 characters. The FFI result is `0` for failure, `1` for
confirmed success, and `2` when a clipboard write may have started but its
outcome cannot be confirmed; the legacy exported entry point remains for
compatibility.

Messages use the `SCB1` framing protocol:

1. The daemon sends a framed, random 32-byte per-connection challenge.
2. Each frame starts with the four ASCII bytes `SCB1` and a four-byte,
   big-endian payload length.
3. The client sends a strictly decoded, hand-written binary request no larger
   than 10 MiB.
4. The daemon returns a separately framed acknowledgement; hello and
   acknowledgement payloads are capped at 4 KiB.

With a non-empty token, SHA-256 domain separation derives independent request
and acknowledgement keys. Requests and acknowledgements are protected with
AES-256-GCM; the request is bound to the server challenge, and the
acknowledgement is bound to both that challenge and the request nonce. The
token and plaintext clipboard value are therefore never placed on the wire,
and a captured request cannot be moved to a new daemon connection. Without a
token, loopback mode remains plaintext for zero-configuration local use.

The daemon keeps the arboard clipboard context alive, which is important on
Linux display systems where the clipboard owner may need to continue serving
the copied data.

The daemon has a deliberately small command-line interface:

~~~text
simpleclipboard-daemon --help
simpleclipboard-daemon --version
~~~

Runtime configuration is provided through environment variables:

| Variable | Meaning |
| --- | --- |
| `SIMPLECLIPBOARD_ADDR` | Listen address; default `127.0.0.1:12343`. |
| `SIMPLECLIPBOARD_TOKEN` | Optional UTF-8 pre-shared key on loopback; mandatory off loopback. Maximum 4096 bytes; U+0001 cannot be used by the Vim ABI. |
| `SIMPLECLIPBOARD_PID_FILE` | PID-file path, or `-` to disable it. Defaults to `$XDG_RUNTIME_DIR/simpleclipboard.pid`; when that variable is unset or empty, it uses a per-user file in the system temporary directory. Its lock permits one daemon per PID-file path. |
| `RUST_LOG` | `error`, `warn`, `info`, `debug`, `trace`, or `simpleclipboard=<level>`. |

If the daemon path is disabled or unavailable, SimpleClipboard chooses an
environment-appropriate native command. The built-in candidate order is
`pbcopy` → `wl-copy` (offered only when `$WAYLAND_DISPLAY` is set, since it
cannot reach an X11 session) → WSL's `clip.exe` → `xsel` → `xclip`. A configured
`g:simpleclipboard_copy_command` is tried first. If a queued command exits with
an error, SimpleClipboard advances through the remaining platform candidates
before its final OSC52 fallback. External jobs are serialized and multiple
waiting requests coalesce to the latest text, preventing a slow older command
from overwriting a newer copy.

## SSH and containers

For a normal SSH session, an OpenSSH reverse tunnel can expose the local
desktop daemon only on the remote host's loopback interface. This is an
unconditional manual configuration; the installer instead generates the
process-gated `Match` block described above:

~~~sshconfig
Host development-host
    RemoteForward 12345 127.0.0.1:12343
    ExitOnForwardFailure yes
~~~

Remote Vim then reaches `127.0.0.1:12345`. Keep OpenSSH's default loopback
binding for the remote forwarding socket. Configure the same non-empty, long
random token on both ends. Remote, container, and explicit custom daemon routes
are blocked before probing or copying when Vim has no token.

Example local daemon environment:

~~~sh
SIMPLECLIPBOARD_ADDR=127.0.0.1:12343 \
SIMPLECLIPBOARD_TOKEN='replace-with-the-same-long-random-value' \
./lib/simpleclipboard-daemon
~~~

Example remote Vim configuration:

~~~vim
let g:simpleclipboard_address = '127.0.0.1:12345'
let g:simpleclipboard_token = 'replace-with-the-same-long-random-value'
let g:simpleclipboard_daemon_autostart = 0
~~~

An explicit `g:simpleclipboard_address` is the most predictable choice for
unusual container networking. Automatic detection also covers common local,
SSH, container, and SSH-inside-container layouts. Run `:SimpleCopyRefresh`
after networking changes.

OpenSSH remote forwards listen on the remote host's loopback interface by
default. A bridge-network container therefore cannot normally reach the
host's forwarded loopback port. Prefer OSC52, host networking, or an explicitly
designed authenticated proxy rather than exposing an unauthenticated TCP port.

## Security

- The Vim-managed daemon binds to `127.0.0.1` by default.
- The daemon refuses a non-loopback bind when no token is configured. Vim also
  refuses remote, container, and custom daemon routes without one.
- A token is a pre-shared encryption key and is never transmitted directly.
  AES-256-GCM authenticates and encrypts request and acknowledgement payloads;
  the per-connection challenge prevents captured requests from being replayed
  into another connection.
- Any local process owned by any user able to reach the loopback port may
  attempt a connection. Tokenless loopback traffic is plaintext, so use a long
  random token on shared systems.
- Encryption does not hide endpoint addresses, ciphertext length, timing, or
  availability. Keep using an SSH tunnel, VPN, or another trusted transport
  across machine boundaries as defense in depth.
- Clipboard contents are sensitive. Avoid debug logs, shell history, public
  issue reports, or configuration repositories that expose copied text or
  tokens.
- OSC52 asks the terminal to modify the clipboard. Terminal and multiplexer
  policies may reject it. Oversized OSC52 payloads fail by default instead of
  being silently truncated.
- Reading the clipboard is not the mirror image of writing it. The daemon
  answers a `get` only over an authenticated connection, and
  `simpleclipboard#PasteText()` never asks it: it reads the `"+`/`"*` register
  or runs a local paste program, hands the text to its callback only, and
  writes no register and no log entry with it. Neither clipboard text nor the
  token ever appears on a command line.
- `:SimpleCopyStop` never kills a daemon merely discovered by PID or port; it
  only stops the job started by that Vim instance.

See [SECURITY.md](SECURITY.md) for the supported-version policy and private
reporting instructions.

## systemd user service

SimpleClipboard 0.2 can run as a normal user service. It does not consume an
inherited socket and must not be paired with a `.socket` unit.

~~~systemd
[Unit]
Description=SimpleClipboard daemon
After=graphical-session.target

[Service]
Type=simple
Environment=SIMPLECLIPBOARD_ADDR=127.0.0.1:12343
Environment=SIMPLECLIPBOARD_PID_FILE=-
ExecStart=%h/.vim/pack/plugins/start/simpleclipboard/lib/simpleclipboard-daemon
Restart=on-failure

[Install]
WantedBy=default.target
~~~

Save this as
`~/.config/systemd/user/simpleclipboard.service`, adjust `ExecStart`, then run:

~~~sh
systemctl --user daemon-reload
systemctl --user enable --now simpleclipboard.service
~~~

When a service owns the daemon, disable Vim's lifecycle management:

~~~vim
let g:simpleclipboard_daemon_autostart = 0
let g:simpleclipboard_daemon_autostop = 0
~~~

If you need authenticated encryption, add an `EnvironmentFile=` directive to
the unit and put `SIMPLECLIPBOARD_TOKEN=...` in that mode-`0600` environment
file. Use the same long, random value in Vim, and do not place it directly in a
world-readable unit file.

## Troubleshooting

Start with:

~~~vim
:SimpleCopyStatus
:messages
~~~

After changing an address, tunnel, display, or executable:

~~~vim
:SimpleCopyRefresh
~~~

Common issues:

- **Client library or daemon not found:** rebuild with `./install.sh`, verify
  the plugin is on `runtimepath`, or set the absolute path options.
- **Address already in use:** another daemon or process owns the selected
  port. Reuse it with the matching token, stop it through its owner, or select
  another port. If another SimpleClipboard daemon holds the default PID-file
  lock, a second instance also needs a distinct `SIMPLECLIPBOARD_PID_FILE`;
  using `-` disables that single-instance guard.
- **Token rejected:** ensure the daemon's `SIMPLECLIPBOARD_TOKEN` and Vim's
  `g:simpleclipboard_token` match exactly. A remote or custom route with an
  empty token is intentionally blocked.
- **Last outcome is `uncertain`:** the daemon may already be executing the
  clipboard write but its final result could not be confirmed. SimpleClipboard
  suppresses immediate fallbacks so a late daemon write cannot overwrite them.
- **Pure Wayland copy fails:** verify the compositor supports the data-control
  protocol; install `wl-copy` for the fallback and run `:SimpleCopyRefresh`.
- **WSL copy fails:** ensure `clip.exe` is reachable from `PATH`, or configure
  it explicitly as `['clip.exe']`.
- **OSC52 has no effect:** allow clipboard access in the terminal; in tmux,
  enable passthrough as appropriate for the installed tmux version.
- **Large copy fails:** the daemon protocol limit is 10 MiB. OSC52 has a
  separate 75,000-byte default and does not truncate unless explicitly
  enabled.
- **Automatic copy feels delayed:** lower
  `g:simpleclipboard_debounce_ms`, or set `g:simpleclipboard_auto_copy = 0`
  and use explicit mappings.

## Upgrading from 0.1

Version 0.2 hardens protocol handling and changes lifecycle behavior. The 0.1
documentation described a Unix socket, although its shipped backend already
used TCP:

1. Stop the 0.1 daemon and disable/remove any `simpleclipboard.socket`
   systemd unit created from the old documentation.
2. Update the repository and run `./install.sh` so the client library and
   daemon come from the same revision.
3. Remove obsolete Unix-socket settings. The supported endpoint is TCP and
   defaults to `127.0.0.1:12343`.
4. Review security settings. Remote, custom, and non-loopback routes require a
   matching token; 0.2 uses it for authenticated encryption.
5. Review OSC52 behavior. Oversized values now fail safely unless
   `g:simpleclipboard_osc52_truncate` is explicitly enabled.
6. Run `:SimpleCopyRefresh` and `:SimpleCopyStatus`.

There is no socket-activation compatibility layer. Do not run a 0.1 client
library against a 0.2 daemon, or the reverse.

See [CHANGELOG.md](CHANGELOG.md) for the complete 0.2 change summary.

## Development

Run the complete local check suite with `make check`, or invoke its parts:

~~~sh
cargo fmt --all -- --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --all-targets
cargo build --locked --release
~~~

Check Vim9 parsing and help tags:

~~~sh
vim -Nu NONE -n -es -i NONE \
  -c 'set runtimepath^=.' \
  -c 'runtime plugin/simpleclipboard.vim' \
  -c 'source autoload/simpleclipboard.vim' \
  -c 'defcompile' \
  -c 'helptags doc' \
  -c 'qa!'
~~~

The source layout is:

- `plugin/simpleclipboard.vim` — defaults, commands, mappings, autocommands
- `autoload/simpleclipboard.vim` — environment detection and copy backends
- `src/simpleclipboard/simpleclipboard_lib.rs` — Vim-loadable TCP client
- `src/simpleclipboard/protocol.rs` — framing and authenticated protocol logic
- `src/simpleclipboard/simpleclipboard_daemon.rs` — clipboard daemon
- `test/` — Vim, installer, and real TCP protocol smoke tests
- `tests/vim_remote.vim` — the suite API (`CopyText`, `LastCopy`,
  `PasteText`) and the SimpleRemote-aware path commands, with SimpleRemote
  simulated by buffer variables and one stub function
- `doc/simpleclipboard.txt` — Vim help

The GitHub Actions workflow runs a fixed Vim 9.0 baseline smoke test, the Rust
MSRV compile/tests on Linux, and `make check` on current stable Rust for Linux
and macOS, including a real host-artifact installation and encrypted/plaintext
TCP handshake matrix. `make check` is the gate in both places, so a target
added to the Makefile runs in CI without editing the workflow. The MSRV jobs
assert their pinned toolchain against `rust-version` in `Cargo.toml`: the two
drifted once, and cargo treats a declared `rust-version` above the active
toolchain as a hard error, which failed every run before compiling a line.

## Credits

SimpleClipboard builds on arboard, RustCrypto AES-GCM, Tokio, and the Vim
job/channel interfaces.

## simple* plugin integration

Other simple* plugins use three functions. All are optional integration
points: feature-detect them with `exists('*simpleclipboard#CopyText')` and
fall back to your own register handling when SimpleClipboard is absent.

- `simpleclipboard#CopyText(text)` writes the unnamed Vim register, routes the
  payload through the configured daemon/native/OSC52 clipboard backend, and
  returns whether the copy was accepted. "Accepted" includes a copy still
  queued behind a slower external command and a daemon write whose outcome is
  uncertain; the function does not echo, so the caller describes the action.
- `simpleclipboard#LastCopy()` returns how the most recent copy went, as
  `{method, outcome, bytes, error, at}`: `method` names the backend
  (`'daemon'`, `'xclip'`, `'OSC52'`, `'custom command'`, ... or `'failed'`),
  `outcome` is one of `'none'`, `'pending'`, `'queued'`, `'success'`,
  `'uncertain'`, `'failed'`, `bytes` is the payload size, `error` the last
  backend failure or `''`, and `at` a local timestamp. The values are the ones
  `:SimpleCopyStatus` prints. A caller can say "queued" instead of "copied"
  while `outcome` is `'queued'`; it turns into `'success'` or `'failed'` when
  the external command exits.
- `simpleclipboard#PasteText(Cb [, selection])` is the reading counterpart:
  it hands the system clipboard's text to `Cb(true, text)`, or `Cb(false,
  reason)` when nothing could read it. `selection` is `'clipboard'` (default)
  or `'primary'`. The callback runs exactly once — before the function returns
  when the answer is immediate (a filled `"+`/`"*` register, an unusable
  selection, no backend at all), otherwise from the paste program's exit — and
  receives the text untouched: no register is written, nothing is echoed. The
  order is the `"+`/`"*` register when this Vim has `+clipboard` and it holds
  text, then `g:simpleclipboard_paste_command`, `pbpaste`, `wl-paste` (with
  `$WAYLAND_DISPLAY`), `xsel`, `xclip`; the first program exiting 0 wins,
  output larger than a pipe buffer is collected whole, and a program that fails
  or exceeds `g:simpleclipboard_paste_timeout_ms` yields to the next. The
  deadline escalates — SIGTERM, SIGKILL 500 ms later, and the job abandoned
  500 ms after that — so the exactly-once callback does not depend on the paste
  program honouring a signal. The daemon is never asked (see
  [Security](#security)). SimpleRemote may later use
  it for a `gp` key in its remote tree that pastes local clipboard text or a
  local path into a remote directory.

### SimpleRemote workspaces

Everything here is feature-detected; without SimpleRemote nothing changes.

Copying: SimpleRemote's remote tree (`y`, `Y`, `gy`) and its finished
downloads copy through `simpleclipboard#CopyText()`, and can consult
`simpleclipboard#LastCopy()` to say "queued" rather than "copied" while a copy
is still in flight. `CopyText()` looks at the
text only, never at the buffer, so yanking inside a `remote://` buffer or the
remote tree — automatic `TextYankPost` copies included — behaves exactly as in
a local file.

Path commands: `:SimpleCopyPath`, `:SimpleCopyLocation` and
`:SimpleCopyFormat` recognise both kinds of SimpleRemote buffer and copy the
remote path instead of refusing or copying the local mount path:

- a virtual-mode buffer is named `remote:///abs/path`, has `buftype=acwrite`
  and carries `b:vimrc_remote = {path, uri, generation}`; its `path` is used;
- a projected-mode buffer (sshfs, docker-bind, local-map) is an ordinary local
  file under the workspace mount carrying `b:simpleremote_path` (the remote
  path) and `b:simpleremote_workspace_id`; `b:simpleremote_path` is used,
  except while a workspace with a different `g:simpleremote_workspace.id` is
  connected — the stamp outlives a workspace switch, and the buffer is then a
  plain local file again. With no workspace connected the stamp is trusted.

`b:vimrc_remote` wins when both are present; a variable of the wrong shape (not
a dictionary, empty or non-string `path`) is ignored and the buffer is judged
like any other. `!` copies the absolute remote path; without it the path is
relative to the workspace root SimpleRemote reports through its global
`SimpleRemoteWorkspaceRoot()` function (a root of `/` strips only the leading
slash), and it stays absolute when SimpleRemote is not loaded, not connected,
the root is not a prefix of the path, or that function throws — a remote path
is never resolved against the local cwd. `{dir}`, `{file}` and
`line:column` are computed as for local files, and the message says so:
`Copied remote file path.`
