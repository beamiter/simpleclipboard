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

## Compatibility

| Environment | Preferred path | Available fallbacks |
| --- | --- | --- |
| Linux/X11 | Rust daemon with arboard | `xsel`, `xclip`, OSC52 |
| Linux/Wayland | Rust daemon with arboard `wayland-data-control` | `wl-copy`, XWayland tools, OSC52 |
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
vim -Nu NONE -n -es -c 'helptags ~/.vim/pack/plugins/start/simpleclipboard/doc' -c 'qa!'
~~~

The installer builds the release daemon and client library and places them in
the plugin's `lib/` directory:

- Linux: `lib/libsimpleclipboard.so` and `lib/simpleclipboard-daemon`
- macOS: `lib/libsimpleclipboard.dylib` and `lib/simpleclipboard-daemon`

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
- Run `:SimpleCopyStatus` to inspect the selected backend and address.

To disable automatic copy while keeping the commands and mappings:

~~~vim
let g:simpleclipboard_auto_copy = 0
~~~

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
| `:SimpleCopyStart` | Start the configured local daemon if needed. |
| `:SimpleCopyStop` | Stop only the daemon job started by this Vim instance. |
| `:SimpleCopyStatus` | Always print environment, address, and backend diagnostics. |
| `:SimpleCopyRefresh` | Clear environment/backend caches and detect them again. |

## Configuration

Set options before the plugin is loaded, normally in `vimrc`.

### Core behavior

| Option | Default | Meaning |
| --- | --- | --- |
| `g:simpleclipboard_daemon_enabled` | `1` | Enable the Rust daemon backend. |
| `g:simpleclipboard_daemon_autostart` | `1` | Start a local daemon on `VimEnter` when appropriate. |
| `g:simpleclipboard_daemon_autostop` | `0` | On exit, stop only the daemon job owned by this Vim instance. |
| `g:simpleclipboard_auto_copy` | `1` | Copy successful yank operations from `TextYankPost`. |
| `g:simpleclipboard_auto_copy_registers` | `[]` | Automatic-copy register allow-list; empty preserves all registers except `_`. Use `['unnamed']` to accept only ordinary yanks. |
| `g:simpleclipboard_auto_copy_max_bytes` | `0` | Maximum automatic-yank payload in UTF-8 bytes; `0` is unlimited. Explicit copy commands are never capped. |
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
| `g:simpleclipboard_disable_osc52` | `0` | Disable the OSC52 fallback. |
| `g:simpleclipboard_osc52_limit` | `75000` | Maximum UTF-8 payload bytes accepted by the OSC52 path. |
| `g:simpleclipboard_osc52_truncate` | `0` | When `0`, reject oversized OSC52 payloads without data loss; when `1`, truncate to the configured limit. |

OSC52 is the final fallback after the daemon and command candidates. If it
rejects an oversized value, the copy operation therefore fails visibly.
Truncation is opt-in because a silent partial clipboard is usually worse than
a clear failure.

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

`:SimpleCopyStatus` is intentionally visible even when debug logging is off.
Its daemon health is a real protocol ping; command and OSC52 entries only show
detected candidates or basic prerequisites, not a guaranteed clipboard write.
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
`pbcopy` → `wl-copy` → WSL's `clip.exe` → `xsel` → `xclip`. A configured
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
- `doc/simpleclipboard.txt` — Vim help

The GitHub Actions workflow runs a fixed Vim 9.0 baseline smoke test, the Rust
MSRV compile/tests on Linux, and the full suite on current stable Rust for
Linux and macOS, including a real host-artifact installation and
encrypted/plaintext TCP handshake matrix.

## Credits

SimpleClipboard builds on arboard, RustCrypto AES-GCM, Tokio, and the Vim
job/channel interfaces.
