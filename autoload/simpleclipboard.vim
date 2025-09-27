vim9script

# =============================================================
# 日志与工具函数
# =============================================================

# 取运行时目录（优先 XDG_RUNTIME_DIR，回退 /tmp）
def RuntimeDir(): string
  var dir = getenv('XDG_RUNTIME_DIR')
  if dir ==# ''
    dir = '/tmp'
  endif
  return dir
enddef

def PidFile(): string
  return RuntimeDir() .. '/simpleclipboard.pid'
enddef

def SocketFile(): string
  return RuntimeDir() .. '/simpleclipboard.sock'
enddef

# 判断 socket 文件是否存在（socket 对 filereadable 可能返回 0，用 getftype 兼容）
def SocketExists(sock: string): bool
  return filereadable(sock) || (has('unix') && getftype(sock) ==# 'socket')
enddef

def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpleclipboard_debug', 0) == 0
    return
  endif

  if get(g:, 'simpleclipboard_debug_to_file', 0)
    try
      var f = get(g:, 'simpleclipboard_debug_file', RuntimeDir() .. '/simpleclipboard.log')
      var line = strftime('%Y-%m-%d %H:%M:%S ') .. msg
      writefile([line], expand(f), 'a')
    catch
      echohl hl
      echom '[SimpleClipboard] ' .. msg
      echohl None
    endtry
    return
  endif

  echohl hl
  echom '[SimpleClipboard] ' .. msg
  echohl None
enddef

# 在 runtimepath 中查找某文件
def FindInRuntimepath(rel: string): string
  for dir in split(&runtimepath, ',')
    var path = dir .. '/' .. rel
    if filereadable(path)
      return path
    endif
  endfor
  return ''
enddef

# 查找守护进程可执行文件
def FindDaemon(): string
  var override = get(g:, 'simpleclipboard_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    return override
  endif

  var path = FindInRuntimepath('lib/simpleclipboard-daemon')
  if path !=# '' && executable(path)
    return path
  endif

  return ''
enddef

# 选择动态库文件名（Linux/macOS）
def LibName(): string
  if has('mac')
    return 'libsimpleclipboard.dylib'
  endif
  return 'libsimpleclipboard.so'
enddef

# 加载动态库：优先 g:simpleclipboard_libpath；否则在 runtimepath/lib 下寻找
var client_lib: string = ''

def TryLoadLib(): void
  if client_lib !=# ''
    return
  endif

  var override = get(g:, 'simpleclipboard_libpath', '')
  if type(override) == v:t_string && override !=# ''
    if filereadable(override)
      client_lib = override
      Log('Found lib via g:simpleclipboard_libpath: ' .. client_lib, 'MoreMsg')
      return
    else
      Log('g:simpleclipboard_libpath set but file not found: ' .. override, 'WarningMsg')
    endif
  endif

  var libname = LibName()
  var path = FindInRuntimepath('lib/' .. libname)
  if path !=# ''
    client_lib = path
    Log('Found lib in runtimepath: ' .. path, 'MoreMsg')
  endif
enddef

# =============================================================
# Daemon 就绪检测与等待
# =============================================================

def IsDaemonReady(): bool
  var sock = SocketFile()
  if !SocketExists(sock)
    return false
  endif

  # 在较新的 Vim 上优先使用 sockconnect 进行真实连通性检测
  if exists('*sockconnect')
    try
      var ch = call('sockconnect', ['unix', sock, {timeout: 100}])
      if type(ch) == v:t_number && ch > 0
        ch_close(ch)
        return true
      endif
    catch
      Log('sockconnect failed: ' .. v:exception, 'Comment')
    endtry
    return false
  endif

  Log('sockconnect() not available; fallback to socket file existence.', 'Comment')
  return true
enddef

# 等待守护进程在指定时间内就绪
def WaitForDaemon(timeout_ms: number): bool
  var elapsed = 0
  while elapsed < timeout_ms
    if IsDaemonReady()
      return true
    endif
    sleep 50m
    elapsed += 50
  endwhile
  return false
enddef

# =============================================================
# 守护进程管理
# =============================================================

export def StartDaemon()
  var enabled = get(g:, 'simpleclipboard_daemon_enabled', 1)
  if !enabled
    Log('Daemon disabled by g:simpleclipboard_daemon_enabled.', 'Comment')
    return
  endif

  if IsDaemonReady()
    Log('Daemon already running (socket ready).', 'MoreMsg')
    return
  endif

  var daemon = FindDaemon()
  if daemon ==# ''
    echohl ErrorMsg
    echom '[SimpleClipboard] Daemon executable not found. ' ..
          'Set g:simpleclipboard_daemon_path or put simpleclipboard-daemon into runtimepath/lib/.'
    echohl None
    return
  endif

  Log('Starting daemon: ' .. daemon)

  try
    var job_obj = job_start([daemon], {
          out_io: 'null',
          err_io: 'null',
          stoponexit: 'none',
        })
    # job_start 失败时会抛出异常，无需检查 v:null
  catch
    echohl ErrorMsg
    echom '[SimpleClipboard] Failed to start daemon via job_start: ' .. v:exception
    echohl None
    return
  endtry

  if WaitForDaemon(1500)
    Log('Daemon is up (socket detected).', 'MoreMsg')
  else
    echohl WarningMsg
    echom '[SimpleClipboard] Daemon started but not ready (timeout).'
    echohl None
  endif
enddef

export def StopDaemon()
  var autostop = get(g:, 'simpleclipboard_daemon_autostop', 0)
  if !autostop
    Log('Autostop disabled; skip stopping daemon.', 'Comment')
    return
  endif

  var pidfile = PidFile()
  var sock = SocketFile()

  if filereadable(pidfile)
    try
      var pid = trim(readfile(pidfile)[0])
      if pid !=# ''
        Log('Stopping daemon with PID: ' .. pid .. '...')
        system('kill ' .. pid)
      endif
    catch
      # ignore
    endtry
    try
      delete(pidfile)
    catch
      # ignore
    endtry
  endif

  if SocketExists(sock)
    try
      delete(sock)
    catch
      # ignore
    endtry
  endif

  Log('Daemon stop requested and files cleaned (if any).', 'MoreMsg')
enddef

# =============================================================
# 复制逻辑（守护进程优先，命令行工具与 OSC52 作为回退）
# =============================================================

def CopyViaRust(text: string): bool
  Log('Attempting copy via Rust (daemon)...', 'Question')
  TryLoadLib()
  if client_lib ==# ''
    Log('Skipped Rust: client library not found.', 'Comment')
    return false
  endif

  try
    if libcallnr(client_lib, 'rust_set_clipboard', text) == 1
      Log('Success: Sent text to daemon.', 'ModeMsg')
      return true
    endif

    if get(g:, 'simpleclipboard_daemon_enabled', 1)
      Log('First try failed. Starting daemon on-demand...', 'WarningMsg')
      StartDaemon()
      if WaitForDaemon(1500) && libcallnr(client_lib, 'rust_set_clipboard', text) == 1
        Log('Success after starting daemon.', 'ModeMsg')
        return true
      endif
    endif

    Log('Failed: Could not send text to daemon.', 'ErrorMsg')
    return false
  catch
    Log('Error calling client library: ' .. v:exception, 'ErrorMsg')
    return false
  endtry
enddef

# ===== 关键修正部分开始 =====

# 列表用于保存正在运行的复制任务，防止 job 对象被过早垃圾回收
var running_copy_jobs: list<job> = []

# 当复制任务的 job 结束时，Vim 会自动调用此回调函数
def JobExitCallback(job: job, status: number)
  # 如果任务失败，可以记录日志方便调试
  if status != 0
    var job_info = job_info(job)
    Log($"Copy command '{string(job_info.cmd)}' failed with exit code {status}.", 'WarningMsg')
  endif

  # 从跟踪列表中移除已完成的 job，避免列表无限增长
  var idx = running_copy_jobs->index(job)
  if idx != -1
    running_copy_jobs->remove(idx)
  endif
enddef

# 修正后的函数，用于通过异步 job 运行外部复制命令
def StartCopyJob(argv: list<string>, text: string): bool
  try
    # 使用 exit_cb 选项来指定任务结束时的回调函数
    var job = job_start(argv, {
          \ out_io: 'null',
          \ err_io: 'null',
          \ in_io: 'pipe',
          \ exit_cb: JobExitCallback,
          \ })

    # 将新创建的 job 对象添加到跟踪列表中，以确保其生命周期
    add(running_copy_jobs, job)

    # 向 job 的 stdin 发送文本，并立即关闭输入流
    # ch_close_in 告诉对方进程：数据已经发送完毕
    ch_sendraw(job, text)
    ch_close_in(job)

    return true
  catch
    # 如果 job_start 失败，会在这里捕获异常
    Log('StartCopyJob error: ' .. v:exception, 'WarningMsg')
    return false
  endtry
enddef

# ===== 关键修正部分结束 =====

def CopyViaCmds(text: string): bool
  Log('Attempting copy via external commands...', 'Question')

  # macOS
  if has('mac') || executable('pbcopy')
    Log('Trying: pbcopy (macOS)', 'Identifier')
    if StartCopyJob(['pbcopy'], text)
      Log('Success: Copied via pbcopy.', 'ModeMsg')
      return true
    endif
    Log('Failed: pbcopy command failed.', 'WarningMsg')
  endif

  # Wayland
  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    Log('Trying: wl-copy (Wayland)', 'Identifier')
    if StartCopyJob(['wl-copy'], text)
      Log('Success: Copied via wl-copy.', 'ModeMsg')
      return true
    endif
    Log('Failed: wl-copy command failed.', 'WarningMsg')
  endif

  # X11: xsel
  if executable('xsel')
    Log('Trying: xsel (X11)', 'Identifier')
    if StartCopyJob(['xsel', '--clipboard', '--input'], text)
      Log('Success: Copied via xsel.', 'ModeMsg')
      return true
    endif
    Log('Failed: xsel command failed.', 'WarningMsg')
  endif

  # X11: xclip
  if executable('xclip')
    Log('Trying: xclip (X11)', 'Identifier')
    if StartCopyJob(['xclip', '-selection', 'clipboard'], text)
      Log('Success: Copied via xclip.', 'ModeMsg')
      return true
    endif
    Log('Failed: xclip command failed.', 'WarningMsg')
  endif

  Log('Skipped Cmds: No suitable command (pbcopy/wl-copy/xsel/xclip) found or all failed.', 'Comment')
  return false
enddef

def CopyViaOsc52(text: string): bool
  if get(g:, 'simpleclipboard_disable_osc52', 0)
    Log('Skipped OSC52: disabled by g:simpleclipboard_disable_osc52.', 'Comment')
    return false
  endif

  Log('Attempting copy via OSC52 terminal sequence...', 'Question')

  if !executable('base64')
    Log('Skipped OSC52: `base64` command not executable.', 'Comment')
    return false
  endif

  var payload = text
  var limit = 16000000
  if strchars(payload) > limit
    Log('Text truncated to ' .. limit .. ' characters for OSC52.', 'Comment')
    payload = strcharpart(payload, 0, limit)
  endif

  var b64 = trim(system('base64 -w0', payload))
  if v:shell_error != 0 || b64 ==# ''
    b64 = system('base64', payload)
    if v:shell_error != 0
      Log('Failed: base64 encoding failed.', 'WarningMsg')
      return false
    endif
    b64 = substitute(b64, '\n', '', 'g')
  endif

  var seq = exists('$TMUX')
    ? "\x1bPtmux;\x1b]52;c;" .. b64 .. "\x07\x1b\\"
    : "\x1b]52;c;" .. b64 .. "\x07"

  try
    if has('unix') && filereadable('/dev/tty')
      writefile([seq], '/dev/tty', 'b')
      Log('Success: Sent OSC52 sequence to /dev/tty.', 'ModeMsg')
    else
      Log('Skipped OSC52 echo path: /dev/tty not available.', 'Comment')
      return false
    endif
    return true
  catch
    Log('Failed: Error writing OSC52 sequence. Details: ' .. v:exception, 'ErrorMsg')
    return false
  endtry
enddef

# =============================================================
# 环境检测：SSH/容器（Docker/Podman/K8s）
# =============================================================

# 是否在 SSH 会话中
def IsSSH(): bool
  return exists('$SSH_CONNECTION') || exists('$SSH_CLIENT') || exists('$SSH_TTY')
enddef

# 是否在容器内（Docker/Podman/K8s/LXC 等）
def InContainer(): bool
  # 简单文件标记
  if filereadable('/.dockerenv') || filereadable('/run/.containerenv')
    return true
  endif

  # cgroup 关键词检测
  try
    var lines = readfile('/proc/1/cgroup')
    for l in lines
      if l =~# '\<docker\>\|\<containerd\>\|\<kubepods\>\|\<libpod\>\|\<podman\>\|\<lxc\>'
        return true
      endif
    endfor
  catch
    # 某些系统可能没有该文件或不可读，忽略
  endtry

  # 环境变量线索（不完全但常见）
  if exists('$container') || exists('$DOCKER_CONTAINER') || exists('$KUBERNETES_SERVICE_HOST')
    return true
  endif

  return false
enddef

# 是否默认优先 OSC52（支持用户覆盖）
def PreferOsc52(): bool
  # 用户覆盖：1 强制开启；0 强制关闭；未设置则自动检测
  var override = get(g:, 'simpleclipboard_prefer_osc52', -1)
  if override == 1
    Log('PreferOsc52: forced by g:simpleclipboard_prefer_osc52=1', 'Comment')
    return true
  elseif override == 0
    Log('PreferOsc52: disabled by g:simpleclipboard_prefer_osc52=0', 'Comment')
    return false
  endif

  # 自动策略：SSH 或容器内则优先 OSC52
  if IsSSH() || InContainer()
    Log('PreferOsc52: auto-on (SSH or container detected).', 'MoreMsg')
    return true
  endif

  Log('PreferOsc52: auto-off (local host).', 'Comment')
  return false
enddef

# =============================================================
# 修改复制策略入口：优先 OSC52（在 SSH/容器环境）
# =============================================================

export def CopyToSystemClipboard(text: string): bool
  if PreferOsc52()
    # SSH/容器中优先走 OSC52，避免复制到远端系统剪贴板
    return CopyViaOsc52(text)
  endif

  # 本地环境：守护进程 → 外部命令 → OSC52
  return CopyViaRust(text) || CopyViaCmds(text) || CopyViaOsc52(text)
enddef

export def CopyYankedToClipboard(_timer_id: any = 0)
  var txt = getreg('"')
  if txt ==# ''
    return
  endif
  if !CopyToSystemClipboard(txt)
    echohl WarningMsg
    echom 'SimpleClipboard: copy failed. Check daemon, or install wl-copy/xsel/xclip, or ensure OSC52.'
    echohl None
  endif
enddef

export def CopyRangeToClipboard(l1: number, l2: number)
  var lines = getline(l1, l2)
  var txt = join(lines, "\n")
  if CopyToSystemClipboard(txt)
    echom 'Copied selection to system clipboard'
  else
    echohl WarningMsg
    echom 'SimpleClipboard: copy failed.'
    echohl None
  endif
enddef
