# Changelog

All notable user-visible changes to SimpleClipboard are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
SimpleClipboard uses semantic versioning for the Vim interface, TCP protocol,
and packaged Rust components.

## Unreleased - 2026-08-05

### `simpleclipboard-client --selection` 只对 get 生效,现在会这么说

- `--selection` 此前对所有 action 都照收不误,但只有 `get` 会把它送上线:
  `PlainRequest::Set` 里根本没有选区字段,守护进程的写入路径写死
  `Selection::Clipboard`。于是
  `simpleclipboard-client --action set --selection primary` 写的是
  CLIPBOARD,PRIMARY 一个字节没动,退出码还是 0——脚本作者最不会去检查的
  那种结果。
- 现在给 `get` 以外的 action 指定选区是用法错误（退出码 64,和"守护进程
  连不上"的 1 分得开）,`--help` 里也写明"只对 get 生效"。README 与
  `:help simpleclipboard` 同步。
- 客户端从此有了自己的单元测试:参数解析抽成 `parse_arguments()`,覆盖
  set/ping 上的选区被拒、不带选区的 set 照常通过、get 把选区带进请求、
  以及 `--help` 里那句话确实在。

### 加了引号的 OSC52 上限,报告里不再提那个没有生效的默认值

- `let g:simpleclipboard_osc52_limit = '0'`（或 `'-5'`）此前报的是
  "using the default 75000",而 `Osc52Limit()` 其实把 OSC52 整条路径
  封掉了——`:SimpleCopyStatus` 同一屏上写着 `OSC52: blocked (invalid limit)`,
  每一次 OSC52 复制都失败。数字字符串按十进制解释是文档明确鼓励的写法
  （"引号包住端口是常见写法"）,所以这是一个真能配出来的配置,而"报一个
  并没有生效的默认值"正是选项校验存在的意义所要排除的那种错。
- 现在失败关闭的选项在数值可读但被 `positive` 拒绝时报的是它自己的注记
  （OSC52 上限:"OSC52 is skipped until it is fixed"）,和不加引号的 `0`
  一字不差。可读且为正的字符串不受影响,`' 12 '` 仍然报 "using 12"。
- 冒烟测试补上了加引号的 `'0'`（此前只覆盖不加引号的 `0`,走的是另一条
  分支）与 `' 12 '` 两例,并断言 `'0'` 之下 OSC52 确实一个字节都不发。

### 协议学会了读剪贴板,并且多了一个独立的客户端程序

- SCB1 新增 `get` 请求(tag `0x04`,后跟一个选区字节:`0x00` CLIPBOARD、
  `0x01` PRIMARY)与一种带数据的 ack body(tag `0x02`,在 `ok` 和 detail
  之后再跟一段长度前缀的 UTF-8 文本)。原有 ping/set/legacy 的字节布局
  一个字节都没变,握手、AEAD 封装与 ack 绑定也完全复用。
- ack 的长度上界按种类区分:状态 ack 仍是 4 KiB,数据 ack 才允许到帧上限。
  客户端按自己发出的请求决定愿意读回多少,所以一个 ping 不可能被回一个
  十兆字节的应答。
- 新增 `lib/simpleclipboard-client`。同一个 `send_request` 逐字复用,只是
  搬到了子进程里——`libcallnr()` 只能返回数字,`get` 的文本本来无处可回,
  而子进程也是将来能被异步等待、不必冻住 UI 线程的形状。
  **但插件目前还没有驱动它**:`autoload/simpleclipboard.vim` 的每一次复制
  仍然走同步的 `libcallnr()`,`get` 在 Vim 侧根本没有调用方。也就是说,
  这个版本里它只是一个能从 shell 里手工运行的程序,复制的响应性一如既往。
  README 与 `:help simpleclipboard` 现在都列出了 `lib/simpleclipboard-client`
  并写明这条注意事项。
- token 走环境变量、剪贴板正文走标准输入,都不进 argv——Linux 上
  `/proc/<pid>/cmdline` 是全局可读的。
- 安全边界:**tokenless 的守护进程拒绝 `get`**(`get_requires_authentication`)。
  往别人的剪贴板里写是骚扰,能随时读走别人刚复制的密码则是另一回事,而
  loopback 在共享主机上等于"机器上的每个账号"。写入的语义不变。
- 守护进程的剪贴板工作线程改为读写共用一条连接:arboard 的 X11 后端由取得
  选区的那个线程负责提供内容,另开连接去读有死锁的可能。
- 读超时就是读失败:写有可能已经写了一半,所以要告诉调用方别去 fallback;
  读不会改变任何东西,于是不再复用 `clipboard_outcome_unknown` 这个代码。
- `test/tcp_e2e.sh` 现在跑真正的 set/get 往返、断言错误 token 被拒、
  断言剪贴板正文不能当命令行参数传,并断言 tokenless 守护进程拒绝 `get`
  且不回任何数据。往返只在"这台机器根本没有显示服务器"这一种情况下跳过:
  判据抽到了 `test/e2e_skip_rules.sh`,要求 `DISPLAY`/`WAYLAND_DISPLAY`
  都没有、且客户端报的是 `clipboard_unavailable`;别的失败一律是失败。
  此前是 `--action set` 只要非零退出就跳过,于是分帧回归、读不了标准输入、
  token 环境变量改名,在 CI 的无头 Linux 上都会被当成"没有显示服务器"。
- 新增 `test/doc_claims.sh`(接入 `make check`):文档里点名的粘贴命令必须
  是插件真能运行的、文档里写的 `:Simple…` 命令必须真的定义过,而
  `simpleclipboard-client` 的"插件还没驱动它"这句注意事项,必须在插件确实
  不驱动它时出现、在插件开始驱动它时消失。SECURITY.md 此前描述了一条
  本地粘贴命令的回退链,而插件根本没有粘贴功能,现已改为如实说明。

### OSC52 有了第一批测试,顺带修好了它一直没人发现的三个洞

- OSC52 是裸 SSH（没有隧道）下唯一能用的通道,却是唯一一条完全没有测试的
  通道:冒烟测试全程 `g:simpleclipboard_disable_osc52 = 1`,然后断言它是
  disabled。现在改为逐字节断言真实发出的序列。
- screen 的 DCS 封装此前只看 $STY。用 wrapper 启动 screen、或从别的环境
  重新 attach 的人只剩 $TERM 可依据,漏判的后果是剪贴板被悄悄截断而不是
  报错。现在 $STY、`'term'` 与 $TERM 三者任一以 screen 开头都会封装。
- screen 会不声不响地截断超过约 768 字节的 DCS 字符串。现在超长序列被拆成
  多个 DCS 分片:screen 剥掉每层封装后原样转发,外层终端看到的仍是一条完整
  的 OSC 52。测试会把分片重新拼回去,逐字节对比原序列。
- 新增 `g:simpleclipboard_osc52_terminator`（`'bel'` / `'st'`）、
  `g:simpleclipboard_osc52_selection`（`'c'` / `'p'`,PRIMARY 选区,仅
  OSC52 这条路径）与 `g:simpleclipboard_osc52_tty`。默认值就是原来的行为。
- 序列现在优先经 |echoraw()| 写进 Vim 真正驱动的终端;`sudo -u`、
  `:terminal` 里的 Vim、某些 tmux popup 配置下 /dev/tty 并不是那个终端。
  没有终端可写时（例如 -es）仍退回 /dev/tty。
- 枚举型选项按去空格、转小写后匹配,写错时报告一次并退回文档默认值,
  报错文案会把整套合法取值列出来。

### `:SimpleCopyStatus` 不再被一个类型写错的 token 打断

- `g:simpleclipboard_token` 写成列表时,`:SimpleCopyStatus` 在拼状态行时用
  `==#` 拿它和 `''` 比较,直接抛 `E691: Can only compare List with List`。于是
  最该解释这次配置错误的那条命令,自己以同样的方式失败了:守护进程摘要往下
  的每一行——包括点名这个 token 的 `configuration:` 报告——一行都没打出来。
- 现在按 token 校验规则分类,依旧不回显取值:
  `token=off` / `token=configured` / `token=invalid (must be a string)`。
- 冒烟测试覆盖:列表 token 下 `:SimpleCopyStatus` 打完整状态、点名问题、
  不出现 `E691`,也不出现 token 的内容。

### 关掉自动复制之后,yank 不再为它复制一遍 regcontents

- 让 `g:simpleclipboard_auto_copy` 运行期生效的代价是 `TextYankPost` autocmd
  无条件挂上,这没问题;但 autocmd 传的是 `deepcopy(v:event)`,而参数在处理函数
  有机会看一眼开关之前就求值了。于是把自动复制关掉的用户,每次 yank 仍要为
  整个 regcontents 复制一份。
- 处理函数改成自己读 `v:event`(事件只在 autocmd 内同步使用,本来就没有复制的
  理由)。本机实测:300000 行缓冲区 `ggVGy`,关掉自动复制时 0.037s → 0.019s;
  完全不加载插件是 0.008s,剩下的差额是 Vim 构造 `v:event` 本身,只要挂着
  `TextYankPost` autocmd 就躲不掉。
- 显式传事件的调用方(测试,以及任何重放 yank 的代码)不受影响。

### 文档里的示例输出改成代码真的会打印的那一行

- README.md 与 `doc/simpleclipboard.txt` 引用的选项校验示例写的是
  `g:simpleclipboard_port must be a number, but is a string ("12343"); using
  12343`,而 `g:simpleclipboard_port` 声明为正数,真实文案是 `must be a positive
  number ... using the default 12343`。照着文档去 grep 自己刚看到的报错、或者
  照着文档写匹配规则的人,一条都对不上。
- 冒烟测试现在从两份文档里读出示例行,再让 `ValidateOptions()` 原样复现它,
  所以下一次漂移会挂在这里而不是挂在用户的终端里。

### `g:simpleclipboard_osc52_limit` 重新失败关闭

- 上一轮把所有选项统一改成"读不出就退回默认值"时,把这个选项也一起卷了进去:
  置 0(或负数、或读不出数字)此前会挡住整条 OSC52 通道,改完之后却悄悄按
  75000 继续,把 payload 写进终端。一个原本失败关闭的选项变成了失败开放——
  恰好是最不该这样处理的那个:转义序列一旦发出就收不回来,它已经进了终端
  模拟器,在 tmux/screen 下还会进外层会话的日志。
- 现在它和 `g:simpleclipboard_auto_copy_registers`、
  `g:simpleclipboard_auto_copy_max_bytes` 一样失败关闭:取值无法解释时
  OSC52 直接跳过,`last error` 写明是哪个选项的问题,`:SimpleCopyStatus` 显示
  `OSC52: blocked (invalid limit)`。带引号的数字仍按十进制解释。
- `CopyViaOsc52()` 先查配置再查环境,所以坏掉的上限报告的是它自己,而不是这台
  机器今天恰好缺的 `base64`。
- 冒烟测试覆盖:上限为 0 时状态行显示 blocked、复制失败、且什么都没写出去。

### 自动复制可以当场关掉

- `g:simpleclipboard_auto_copy` 现在每次 yank 都重新读取,不再只在插件加载时
  latch 一次。此前把它置 0 之后再 yank 密码,`TextYankPost` autocmd 仍然挂着,
  凭据照样被推进系统剪贴板——而文档一直把这个变量写成关闭自动复制的办法。
  兄弟选项 `g:simpleclipboard_auto_copy_registers` 本来就是运行期生效的,这种
  不对称本身就误导人。
- 新增 `:SimpleCopyToggle`、`:SimpleCopyPause {seconds}` 与
  `<Plug>(SimpleCopyToggle)`。暂停由一次性定时器恢复暂停前的取值:重复暂停
  会重新计时但保留最初的取值,toggle 取消进行中的暂停,没有 `+timers` 时命令
  拒绝执行而不是永久关闭自动复制。
- 关闭自动复制还会丢弃仍在防抖窗口里的旧 yank,否则刚被关掉的通道仍会在几十
  毫秒后再写一次剪贴板。
- 冒烟测试覆盖:置 0 后 yank 不落盘、toggle 之后落盘、非法的
  `:SimpleCopyPause` 参数不改变状态、暂停期间的 yank 不落盘且到期自动恢复。

### 第二个 Vim 不再 fork 一个注定失败的守护进程

- VimEnter 自动启动走的是 `StartDaemon(false, false)`,而"探测地址是否已被占用"
  和"启动后等待就绪"此前是同一个参数,于是自动启动把两者一起跳过了:第一个
  Vim(或 systemd unit)已经持有 127.0.0.1:12343 时,之后每个 Vim 都会 fork 一个
  只能在 bind 上失败的守护进程,而 `err_io: 'null'` 让失败悄无声息。
- 现在启动前总会做一次 loopback 探测(端口真的空闲时连接立即被拒,几乎不花
  时间),已被占用就直接复用。冒烟测试用一个占住端口的监听进程覆盖这一点。

### CI 重新变绿

- `.github/workflows/ci.yml` 的 MSRV 任务与 linux matrix 都钉在
  `dtolnay/rust-toolchain@1.85.0`,而 `Cargo.toml` 声明 `rust-version = "1.88"`。
  cargo 把"声明的 rust-version 高于当前工具链"当作硬错误,于是每次 push 在编译
  第一行代码之前就红了。两处都改为 1.88.0,并新增一步从 `Cargo.toml` 读出
  `rust-version` 与实际 `rustc --version` 比对,不一致直接失败并指出该改哪里,
  这样两者不会再悄悄分叉。
- CI 不再手抄 Makefile 目标的子集:Vim 9.0 基线任务改跑 `make vim-check`,
  macOS 去掉与 `make check` 重复的 `make defcompile` / `make vim-core`,
  workflow 里的 `bash -n` 与 `shellcheck` 分别由 `make installer-check` 与新的
  `make shell-check` 覆盖(本机没装 shellcheck 时跳过),后者也进了 `make check`。
  Makefile 现在是门禁的唯一事实来源。
- 安装校验的版本号从 `Cargo.toml` 推导,不再硬编码 `0.2.0`。

### 安装器验证刚构建的二进制,帮助文档不再承诺没有的东西

- `install.sh` 在把任何产物移进 `lib/` 之前先跑 `--self-test`(密钥派生、AEAD
  封装、分帧与 ack 绑定各一遍,不碰桌面剪贴板)。此前只检查文件存在与可执行,
  于是一个能链接但跑不起来的二进制会替掉正常安装,并且没有回滚。失败时旧的
  `lib/` 原封不动,消息说明失败原因。帮助文档此前就写着安装器会这么做。
- `install.sh` 现在还会生成 helptags,`:help simpleclipboard` 装完即可用。
- 更正帮助文档中不成立的描述:daemon 不是"由 simplecore 管理"、也不"用
  stdin/stdout 上的 JSON 通信"——插件自己用 `job_start()` 持有 job,请求走
  TCP 上的定长帧二进制协议;没有指数退避重启、崩溃循环断路器,也没有请求
  id 关联与超时;`:SimpleCopyHealth` 是 `:SimpleCopyStatus` 的别名,不报告
  协商到的协议版本、uptime 或崩溃计数;`:SimpleCopyLog` 显示的是插件自己的
  通知记录,而不是 daemon stderr(daemon 输出被丢弃)。文档现在写这些真实
  保证,以及明确"不做的事"。
- `test/install_args.sh` 用 stub 工具链在临时目录里跑一次安装器:`--self-test`
  失败时安装必须失败、`lib/` 必须没有被动过。

### 选项写错不再炸掉复制

- 14 个 `g:` 选项此前只有 4 个做类型检查。`let g:simpleclipboard_port = '12343'`
  这种常见写法会让 `DetectEnvironment()` 抛 `E1013: Argument 2: type mismatch`,
  而它位于每次 yank、每次显式复制以及 `:SimpleCopyStatus` 的必经路径上——
  唯一能解释故障的命令,以同样的方式失败。
- 新增 `simpleclipboard#ValidateOptions()`:按声明顺序逐条给出期望类型、
  实际取值与随之采取的行为。插件加载、`:SimpleCopyRefresh` 与
  `:SimpleCopyStatus`(新增 `configuration:` 行)都会报告。
- 所有消费点改为在使用处强制类型:数字字符串按十进制解释,其余无法解释的
  取值退回文档中的默认值,因此坏选项的代价是一条警告而不是整条流水线。
  `g:simpleclipboard_auto_copy_registers` 与
  `g:simpleclipboard_auto_copy_max_bytes` 例外——它们决定什么可以离开 Vim,
  写错时仍然跳过自动复制,而不是猜一个更宽松的默认值。
- `g:simpleclipboard_token` 只按类型和长度报告,不回显取值。
- 列表选项还会校验元素类型:`g:simpleclipboard_copy_command` 必须是非空字符串
  列表,`g:simpleclipboard_auto_copy_registers` 必须是字符串列表。此前元素写错
  只是被静默丢弃,表现为"剪贴板莫名其妙不工作了"。
- 冒烟测试覆盖:带引号的端口仍然能通过回退链完成复制并给出一条可执行的
  警告、非正数的 OSC52 上限退回默认值、错误类型的 token 不被回显。

### 选项报告写的就是真正生效的取值

- `let g:simpleclipboard_auto_copy_max_bytes = '1000'` 此前会同时给出两个互相
  矛盾的说法:警告说 `using 1000`,而消费端直接看原始 g: 值、遇到非数字就
  整条跳过,于是每次 yank 都被悄悄丢掉(只有开了 debug 才看得见),
  `:SimpleCopyStatus` 同一次输出里还写着 `max=invalid (expected number)`。
  现在字节上限和其他数字选项一样解释数字字符串,`'1000'` 就是 1000 字节;
  只有完全读不出数字时才 fail closed,并如实报告"跳过自动复制"。
- `let g:simpleclipboard_port = v:true` 此前警告说"用默认值 12343",实际
  强制转换成 1,于是 `:SimpleCopyStatus` 紧接着显示 `address=127.0.0.1:1`,
  守护进程也是照 1 号端口启动的。所有分支的"随之采取的行为"现在都由真正
  生效的取值算出来,不再假设"只要不是正常数字就用默认值"。
- 冒烟测试覆盖:带引号的字节上限会拦下超限 yank 但放行未超限 yank、
  `:SimpleCopyStatus` 显示 `max=4 bytes`;读不出数字的上限仍然 fail closed;
  布尔端口报告 `using 1` 且 `NumberOption()` 与 `:SimpleCopyStatus` 一致。

### `:SimpleCopyLog` 真的无条件记录失败与路由

- 帮助文档承诺这份记录包含"失败的后端和这次复制为什么走了这条路",而且
  "不依赖 |g:simpleclipboard_debug|"。实际上环形缓冲区只在 `Notify()` 里追加,
  失败与路由判断走的是 `Log()`——默认关闭 debug 时直接 return。默认配置下
  跑完一次全链路失败的复制,`:SimpleCopyLog` 只有一行缓存刷新记录。
- 现在 `MarkFailure()`、每次成功复制的路由(`Copy route: <method> (N bytes)`)
  以及路由判断(守护进程路由被禁用/被拒、拒绝明文、跳过自动复制的原因)都
  无条件进入环形缓冲区,开了 debug 才额外回显。没人会在复制出错之前先打开
  debug 日志,这正是这份记录存在的理由。
- 冒烟测试覆盖:debug 关闭时跑完一次全链路失败的复制,记录里必须有失败的
  后端、最终结论和上一条成功复制走的路由。

### 可组合文件引用

- 新增 `:SimpleCopyFormat[!] {template}` 与 `<Plug>(SimpleCopyFormat)`,可用
  `{path}`、`{dir}`、`{file}`、`{line}`、`{column}` 组合 issue、聊天或日志所需
  的文件引用；`!` 让路径字段使用绝对路径。
- 模板只做白名单解析而不执行表达式,`{{`/`}}` 输出字面大括号；空模板、未知
  占位符、嵌套或不配对大括号在任何后端运行前 fail closed,路径中形似占位符的
  文本也不会二次展开。
- 冒烟测试覆盖含空格、UTF-8、`&` 和大括号的路径、Unicode 字符列、绝对路径、
  所有拒绝分支及非文件 buffer。

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
