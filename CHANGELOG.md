# Changelog

All notable user-visible changes to SimpleClipboard are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
SimpleClipboard uses semantic versioning for the Vim interface, TCP protocol,
and packaged Rust components.

## [0.2.0] - Unreleased

Version 0.2 is a compatibility-breaking protocol-validation and lifecycle
upgrade. The Vim plugin, client library, and daemon must be upgraded together.

### Added

- A shared Rust protocol module with a hand-written strict `SCB1` codec,
  bounded fields, exact-decode, and acknowledgement validation.
- `:SimpleCopyVisual` and `<Plug>(SimpleCopyVisual)` for exact characterwise,
  linewise, and blockwise Visual selections.
- `:SimpleCopyStart` and `:SimpleCopyRefresh`, plus richer behavior for the
  existing stop and status commands.
- Explicit address, custom argv copy command, debounce, and safe OSC52
  limit options.
- `clip.exe` fallback for WSL.
- Daemon `--help` and `--version` output plus an optional
  `SIMPLECLIPBOARD_PID_FILE` override.
- Private security reporting guidance in
  [SECURITY.md](SECURITY.md).
- Rust unit tests, Vim integration smoke tests, installer argument tests, real
  TCP handshake tests, a fixed Vim 9.0 baseline, and Linux MSRV/stable plus
  macOS CI.

### Changed

- Standardized the documented transport on the loopback TCP backend that is
  actually shipped. The default endpoint is `127.0.0.1:12343`.
- Centralized and strictly enforced the existing 10 MiB daemon message limit.
- Removed the unmaintained `bincode` network-decoding dependency in favor of
  the bounded in-tree codec.
- Replaced the delimiter-ambiguous Vim/client payload with a versioned,
  text-last `SCB2` ABI and tri-state result, while retaining the legacy export.
- Kept the existing `<leader>y` default while no longer overriding a mapping
  already defined by the user.
- Made `README.md` the canonical project documentation; `README.org` now
  points to it instead of maintaining a second copy.
- Made `:SimpleCopyStatus` visible independently of debug logging.
- Made `:SimpleCopyRefresh` clear environment and backend caches before
  detecting them again.
- Limited `:SimpleCopyStop` to the daemon job owned by the current Vim
  instance.
- Changed oversized OSC52 handling to fail without truncation by default.
  Truncation now requires `g:simpleclipboard_osc52_truncate = 1`.
- Serialized external copy jobs and coalesced waiting requests to the latest
  text so a slow older command cannot overwrite a newer copy.
- Defaulted the Vim-managed daemon to loopback instead of all interfaces.
- Hardened the existing SSH/container routing and added explicit WSL and
  nested-environment handling.
- Bounded concurrent connections and clipboard work, added read/operation
  timeouts, and made SIGINT/SIGTERM/SIGHUP shutdown graceful.
- Made the installer location-independent, locked, host-targeted, staged, and
  non-interactive by default. Optional SSH edits now require an exact host.

### Security

- A daemon configured on a non-loopback address refuses to start without a
  non-empty token.
- A configured token is no longer transmitted: domain-separated keys protect
  requests and acknowledgements with AES-256-GCM. Per-connection challenges,
  request nonces, acknowledgement binding, and a replay cache prevent endpoint
  impersonation and cross-connection replay.
- Tokenless loopback remains plaintext, while remote/custom routing is blocked
  without a key. SSH or VPN remains recommended as defense in depth.
- Process shutdown no longer trusts a shared PID file to identify a daemon
  owned by Vim.
- Hardened daemon PID-file creation against symlinks, cross-user ownership,
  and concurrent ownership.
- Custom copy commands use an argv list and do not invoke a shell.

### Removed

- Stale Unix-socket claims and the obsolete `simpleclipboard.socket` example
  from the 0.1 documentation; neither matched the shipped daemon.
- Claims that OSC52 shares the daemon's message-size limit.

### Upgrade notes

1. Stop every 0.1 daemon.
2. Disable and remove any `simpleclipboard.socket` user unit created from the
   old documentation.
3. Rebuild and install both 0.2 Rust artifacts from the same revision.
4. Remove obsolete Unix-socket configuration and use TCP address/port options.
5. Review token and OSC52 truncation settings.
6. Run `:SimpleCopyRefresh` followed by `:SimpleCopyStatus`.

Do not mix a 0.1 client library with a 0.2 daemon.

## [0.1.0]

- Initial prototype using a Vim9 frontend, Rust clipboard daemon, external
  command fallbacks, and OSC52.
