# Changelog

All notable user-visible changes to SimpleClipboard are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
SimpleClipboard uses semantic versioning for the Vim interface, TCP protocol,
and packaged Rust components.

## Unreleased - 2026-08-05

### 可分享的文件位置

- 新增 `:SimpleCopyPath[!]`、`:SimpleCopyLocation[!]` 以及对应 `<Plug>` target。
  默认复制相对当前有效 cwd 的路径,`!` 使用绝对路径;location 为 1-based
  `path:line:column`,多字节文本按字符列计数。
- 路径中的空格与 UTF-8 原样进入剪贴板,不混入 shell/fname 转义;无名、help、
  terminal 等非文件 buffer fail closed 并给出明确提示。
- 两个命令复用原有 daemon ACK、串行外部命令、OSC52 回退与状态可观测性;
  冒烟测试通过真实 `tee` 后端校验相对/绝对路径、位置与拒绝边界。

### 精确复制控制

- 新增 `:SimpleCopyRegister [name]`:可直接复制任意 Vim 寄存器,并提供
  `unnamed`/`clipboard`/`primary` 易读别名;新增 `:SimpleCopyClear` 与
  `<Plug>(SimpleCopyClear)`,空文本仍走原有 daemon ACK、外部命令与 OSC52
  回退链,不会被“空寄存器”短路。
- 新增 `g:simpleclipboard_auto_copy_registers` 白名单(默认空列表,保持过去的
  全寄存器行为)与 `g:simpleclipboard_auto_copy_max_bytes`(默认 0,无限制)。两者
  只限制 `TextYankPost`,用户明确执行的复制永远不会被静默截断。
- 被白名单排除或超过字节上限的新 yank 会取消仍在防抖中的旧 yank;否则用户
  已经明确排除的新内容不复制,旧内容却可能在几十毫秒后意外进入系统剪贴板。
- Vim 冒烟测试覆盖 named/unnamed 白名单、自动上限不影响显式复制、行寄存器
  末尾换行以及真实外部命令后端的清空行为;`:SimpleCopyStatus` 现在也显示策略。

### 全套统一

- `.simplecore/` 回来了。10 个仓库里的 supervisor(`autoload/<plugin>/core.vim`
  与三个测试文件)本来就是一套 vendored bundle,但源头目录早已丢失,而每个
  Makefile 都还在引用 `../.simplecore/vendor.sh`。现在 bundle 有了源头,而且
  每个仓库带一份 `.simplecore.manifest` 记录各文件的 sha256,`make core-verify`
  会校验它,`check` 依赖它——手改 vendored 文件会在改它的那个仓库里直接失败,
  不需要 `.simplecore/` 在场。
- 安装器抽成共享的 `install-common.sh`,各仓库的 `install.sh` 只剩配置。
  由此补齐的能力:构建前检查 cargo/rustc 与 MSRV(此前 3 个仓库缺,用户看到的
  是一屏 trait 解析错误);原子替换(此前 2 个仓库是就地覆写,Vim 还开着旧 daemon
  时会 ETXTBSY);Windows 的 `.exe` 后缀;安装前用 `--self-test` 验证刚构建的
  二进制;以及生成 helptags。
- `make check` 现在是每个仓库统一的完整门禁。simplemarkdown 与 simpleminimap
  此前叫 `make test`,旧名字保留为别名。
- daemon 的命令行统一为 `--version` / `--help` / `--self-test`。

### 工具链

- `rust-version` 统一到 1.88(此前 1.85 与 1.88 各半)。实测:1.88 能构建全部
  10 个仓库,1.85 只能构建 5 个。
- `cargo update`:全部为补丁级更新。

  注意:这次更新让 `ignore` 从 0.4.27 升到 0.4.30+,而后者用了 let-chains。
  simplefinder 与 simpletree 此前声明的 1.85 在更新前是真实可用的,更新后不再成立
  ——这是这次依赖刷新付出的代价,不是发现了旧的错误声明。
- MSRV 提到 1.88 后,clippy 的 `collapsible_if` 开始建议用 let-chains 合并
  (该 lint 受 MSRV 门控)。已按建议合并,语义不变。

### 本插件

- `--self-test`:在进程内跑一次完整的认证请求——密钥派生、AEAD 封装、
  分帧,以及把 ack 绑定到请求 nonce 的那层校验。剪贴板本身不碰,
  它需要显示服务器,而安装器不能假设有。
- 保留了自己的 install.sh:它装两个产物(daemon 和 Vim 用 libcall 加载的
  cdylib),并且带暂存目录与回滚,共享安装器做不到这些。
- `Cargo.toml` 里写明了为什么这个 crate 不设 `panic = "abort"`:cdylib 与
  Vim 同进程,abort 会连编辑器一起带走。

### 构建与 CI 修复

- 新增 CI 的 MSRV 作业,按 `rust-version` 声明的最低版本构建。

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
