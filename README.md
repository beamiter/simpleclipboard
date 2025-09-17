
# Table of Contents

1.  [SimpleClipboard (Vim plugin)](#org02de9b5)
    1.  [Why](#orge0c6203)
    2.  [Features](#org06731e6)
    3.  [Requirements](#orgde629b3)
    4.  [Install](#org2a9806c)
    5.  [Quick Start](#org6f0c639)
    6.  [Configuration](#org71be49e)
    7.  [How it works](#org87e04dc)
    8.  [Systemd (optional)](#org62c6a5b)
    9.  [Security and Limits](#org3b63e8e)
    10. [Troubleshooting](#orgcc395f0)
    11. [Notes for macOS](#orgc38f11c)
    12. [Development](#org66a0fb7)
    13. [License](#orge13dd4c)
    14. [Credits](#orgceee28d)


<a id="org02de9b5"></a>

# SimpleClipboard (Vim plugin)

Make copying to the system clipboard Just Work in Vim (without +clipboard).
Linux and macOS supported. Not for Neovim (Vim9 scripts).

-   Primary: Rust daemon over Unix socket + small client library
-   Fallbacks: pbcopy/wl-copy/xsel/xclip, then OSC52
-   Auto-start daemon on VimEnter; optional auto-stop on VimLeave
-   Auto copy on TextYankPost
-   Detailed logging to :messages or to file


<a id="orge0c6203"></a>

## Why

-   Vim without +clipboard cannot reach the system clipboard.
-   External commands and terminal control sequences vary across platforms.
-   This plugin provides a fast, robust, consistent path via a local daemon, with smart fallbacks.


<a id="org06731e6"></a>

## Features

-   y in Normal/Visual to copy to system clipboard
-   Auto copy after yank (TextYankPost)
-   Works on Wayland, X11, and macOS
-   OSC52 fallback (optional)
-   Configurable daemon/lib paths
-   Logging and diagnostics


<a id="orgde629b3"></a>

## Requirements

-   Vim 8.2+ with Vim9 scripts, +job, +channel; +timers optional
-   Rust toolchain (to build the daemon and client library)
-   Optional fallbacks:
    -   macOS: pbcopy
    -   Wayland: wl-copy (requires `WAYLAND_DISPLAY`)
    -   X11: xsel or xclip
    -   OSC52: base64 command and a terminal that supports OSC52


<a id="org2a9806c"></a>

## Install

1.  Install the plugin (choose one)
    -   packpath: put this repo under ~/.vim/pack/whatever/start/simpleclipboard
    -   vim-plug: Plug 'yourname/simpleclipboard'
    -   dein: follow dein’s instructions
2.  Build the Rust backend
    
    1.  Linux (one-liner):
        `./install.sh`
        This copies:
        target/release/libsimpleclipboard.so -> ./lib/
        target/release/simpleclipboard-daemon -> ./lib/
    2.  macOS:
    
    cargo build &#x2013;release
    mkdir -p lib
    cp target/release/libsimpleclipboard.dylib lib/
    cp target/release/simpleclipboard-daemon lib/
3.  Ensure the plugin directory is on 'runtimepath' (so Vim can find ./lib/\*)

4.  Generate help tags:
    :helptags


<a id="org6f0c639"></a>

## Quick Start

-   Default mappings:
    -   Normal: <leader>y copies the unnamed register to the system clipboard
    -   Visual: <leader>y copies the current selection
-   Auto copy after yank: enabled by default
-   Commands:
    -   :SimpleCopyYank
    -   :[range]SimpleCopyRange


<a id="org71be49e"></a>

## Configuration

Set in your vimrc:

    " Daemon control
    let g:simpleclipboard_daemon_enabled = 1
    let g:simpleclipboard_daemon_autostart = 1
    let g:simpleclipboard_daemon_autostop = 0   " off by default to avoid killing shared daemon
    
    " Auto copy on TextYankPost
    let g:simpleclipboard_auto_copy = 1
    
    " Optional: override absolute paths
    let g:simpleclipboard_libpath = ''
    let g:simpleclipboard_daemon_path = ''
    
    " Mappings
    let g:simpleclipboard_no_default_mappings = 0
    
    " Debug & fallbacks
    let g:simpleclipboard_debug = 0
    let g:simpleclipboard_debug_to_file = 0
    let g:simpleclipboard_debug_file = ''       " default: $XDG_RUNTIME_DIR/simpleclipboard.log
    let g:simpleclipboard_disable_osc52 = 0


<a id="org87e04dc"></a>

## How it works

-   Preferred: Vim calls a tiny Rust client library (via libcallnr) which connects to
    `$XDG_RUNTIME_DIR/simpleclipboard.sock` (falls back to /tmp) and sends the text (bincode, up to 16 MB). The daemon sets the system clipboard via arboard.
-   Fallback commands: pbcopy, wl-copy, xsel, xclip (async via `job_start` + chansend).
-   Final fallback: OSC52 control sequence sent to /dev/tty (tmux passthrough if $TMUX is set).
-   Socket readiness is checked with sockconnect() when available.


<a id="org62c6a5b"></a>

## Systemd (optional)

The daemon supports socket activation via listenfd.

Example user socket ~/.config/systemd/user/simpleclipboard.socket:

    [Unit]
    Description=SimpleClipboard user socket
    
    [Socket]
    ListenStream=%t/simpleclipboard.sock
    SocketMode=0600
    
    [Install]
    WantedBy=default.target
    Example user service ~/.config/systemd/user/simpleclipboard.service:
    
    [Unit]
    Description=SimpleClipboard daemon
    
    [Service]
    ExecStart=/absolute/path/to/simpleclipboard-daemon
    Restart=on-failure
    NoNewPrivileges=true
    PrivateTmp=true
    ProtectHome=true
    ProtectSystem=full

-   Enable and start:

systemctl &#x2013;user enable &#x2013;now simpleclipboard.socket
Set let `g:simpleclipboard_daemon_autostart = 0` in Vim to avoid double-starting.


<a id="org3b63e8e"></a>

## Security and Limits

-   Socket file mode 0600; placed in `$XDG_RUNTIME_DIR` (falls back to /tmp if unset).
-   One message limit: 16 MB (daemon and client). OSC52 path truncates over limit.
-   OSC52 writes control sequences to /dev/tty; some terminals/tmux configs may block it.
-   Auto-stop is off by default to avoid stopping a daemon shared by multiple Vim instances.


<a id="orgcc395f0"></a>

## Troubleshooting

-   “Daemon executable not found …”
    -   Ensure `simpleclipboard-daemon` exists under runtimepath/lib/, or set `g:simpleclipboard_daemon_path-`.
-   “client library not found”
    -Ensure libsimpleclipboard.so (Linux) or .dylib (macOS) is under runtimepath/lib/, or set g:simpleclipboard<sub>libpath</sub>.
-   Wayland/X11/macOS fallback issues:
    -   Install wl-copy / xsel / xclip / pbcopy.
-   OSC52:
    -   Ensure base64 is available and the terminal/tmux allows OSC52.
    -   Disable via `g:simpleclipboard_disable_osc52=1` if it causes flicker.
-   Old Vim without sockconnect():
    -   We fallback to “socket file exists” check; upgrade Vim for better readiness probing.
-   Logging:

    - g:simpleclipboard_debug=1
    - g:simpleclipboard_debug_to_file=1, check $XDG_RUNTIME_DIR/simpleclipboard.log.


<a id="orgc38f11c"></a>

## Notes for macOS

-   Build and copy libsimpleclipboard.dylib instead of .so.
-   pbcopy is present by default; the daemon path still provides best latency and reliability.


<a id="org66a0fb7"></a>

## Development

-   Code structure:
    -   autoload/simpleclipboard.vim, plugin/simpleclipboard.vim
    -   src/lib.rs: client library (C ABI)
    -   src/daemon.rs (binary: simpleclipboard-daemon)
-   Build:
    -   cargo build &#x2013;release
-   Test:
    -   Start Vim; :messages or the log file shows detailed steps if `g:simpleclipboard_debug=1`.


<a id="orge13dd4c"></a>

## License

See repository.


<a id="orgceee28d"></a>

## Credits

arboard, bincode, listenfd, ctrlc

