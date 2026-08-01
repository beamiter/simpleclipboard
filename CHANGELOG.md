# Changelog

All notable user-visible changes to SimpleClipboard are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
SimpleClipboard uses semantic versioning for the Vim interface, TCP protocol,
and packaged Rust components.

## Unreleased - 2026-08-01

### 新增

- `:SimpleCopyHealth`(`:SimpleCopyStatus` 的别名,与全套插件命名对齐)、
  `:SimpleCopyRestart`、`:SimpleCopyLog`。
- 所有通知进入环形缓冲区,`:SimpleCopyLog` 可回看一次复制究竟走了哪条路径。

### 可靠性:统一 daemon 监督层 (simplecore)

- 进程生命周期改由 vendored `simplecore` 监督层接管(`autoload/simpleclipboard/core.vim`,
  从 `.simplecore/` 同步,请勿直接编辑)。九个插件共用同一份实现:
  - 存活判定一律走 `job_status()`。`job_start()` 即使 exec 失败也会返回 job
    对象,所以 `job != null` 并不能说明进程还活着。
  - 代际守卫:被替换掉的旧 daemon 的 `exit_cb` 迟到时,不会再清掉接替它的新
    进程的状态。
  - 停止栅栏:显式停止后仍在管道里的事件会被丢弃,不会把刚拆掉的状态又写回去。
  - 指数退避自动重启;同一时间窗内反复崩溃则熔断,只报错一次而不是无限重启。
    手动 `:SimpleCopyRestart` 会重新合闸。
  - 请求按 id 关联并支持超时,卡死的 daemon 不会让回调永远悬着。
- 新增 `:SimpleCopyHealth`、`:SimpleCopyRestart`、`:SimpleCopyLog`,全套插件命名一致。

### 测试

- 新增 `tests/vim_core.vim`:监督层回归套件(存活判定、代际守卫、停止栅栏、
  退避重启、崩溃熔断、请求超时、协议握手、raw/json 两种编解码),由
  `tests/fake_daemon.py` 驱动——一个可以按需应答/静默/乱码/崩溃/忽略 SIGTERM
  的假 daemon。
- 新增 `make defcompile`:强制编译所有 Vim9 `def`。Vim9 惰性编译会把冷分支里的
  语法/类型错误一直藏到用户真正踩中为止。
- `make check` 现在包含以上两项。

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

- Upgraded the AEAD stack to `aes-gcm` 0.11 and replaced the deprecated
  nonce construction; wire format and behavior are unchanged.
- Made the Vim smoke test tolerate Vim builds whose `:messages clear` keeps
  the "Messages maintainer" header line.
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
