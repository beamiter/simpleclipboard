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
  endtry

  # 环境变量线索
  if exists('$container') || exists('$DOCKER_CONTAINER') || exists('$KUBERNETES_SERVICE_HOST')
    return true
  endif

  return false
enddef

# =============================================================
# 网络配置与地址解析
# =============================================================
g:simpleclipboard_port = get(g:, 'simpleclipboard_port', 12345)
g:simpleclipboard_local_host = get(g:, 'simpleclipboard_local_host', '127.0.0.1')

# 获取守护进程的目标地址
def GetDaemonAddress(): string
  var host = g:simpleclipboard_local_host
  var port = g:simpleclipboard_port

  if InContainer()
    Log('In container, trying to find host IP...', 'MoreMsg')
    var ip_cmd = "ip route | awk '/default/ { print $3 }'"
    var container_host_ip = trim(system(ip_cmd))

    if empty(container_host_ip)
      var route_cmd = "route -n | awk '/^0.0.0.0/ {print $2}'"
      container_host_ip = trim(system(route_cmd))
    endif

    if !empty(container_host_ip)
      host = container_host_ip
      Log('Found container host IP: ' .. host, 'MoreMsg')
    else
      Log('Could not determine container host IP. Falling back to 127.0.0.1.', 'WarningMsg')
      host = '127.0.0.1'
    endif
  elseif IsSSH()
    host = '127.0.0.1'
    Log('In SSH session, targeting 127.0.0.1 (relies on port forwarding).', 'MoreMsg')
  endif

  return host .. ':' .. port
enddef

# =============================================================
# 守护进程管理 (Daemon Management)
# =============================================================

# 缓存守护进程可执行文件路径
var daemon_exe_path: string = ''

# 获取 PID 文件路径
def PidFilePath(): string
  return RuntimeDir() .. '/simpleclipboard.pid'
enddef

# 在 runtimepath 中查找守护进程可执行文件
def FindDaemonExe(): void
  if daemon_exe_path !=# '' | return | endif

  var override = get(g:, 'simpleclipboard_daemon_path', '')
  if type(override) == v:t_string && override !=# ''
    if filereadable(override)
      daemon_exe_path = override
      Log('Found daemon via g:simpleclipboard_daemon_path: ' .. daemon_exe_path, 'MoreMsg')
      return
    else
      Log('g:simpleclipboard_daemon_path set but file not found: ' .. override, 'WarningMsg')
    endif
  endif

  var path = FindInRuntimepath('lib/simpleclipboard-daemon')
  if path !=# ''
    daemon_exe_path = path
    Log('Found daemon in runtimepath: ' .. path, 'MoreMsg')
  endif
enddef

# 检查守护进程是否正在运行
def IsDaemonRunning(): bool
  var pidfile = PidFilePath()
  if !filereadable(pidfile)
    return false
  endif

  try
    # 读取 PID 文件内容并去除空白字符
    var pid = trim(readfile(pidfile)[0])
    if pid == '' || pid !~ '^\d\+$'
      return false
    endif

    # 在 Unix-like 系统上，用 ps 命令检查进程是否存在
    if has('unix')
      system('ps -p ' .. pid .. ' > /dev/null 2>&1')
      # v:shell_error == 0 表示进程存在
      return v:shell_error == 0
    endif
  catch
    # 读取文件失败等异常
    return false
  endtry

  return false
enddef

# [导出函数] 启动守护进程
export def StartDaemon(): void
  if IsDaemonRunning()
    Log('Daemon is already running.', 'MoreMsg')
    return
  endif

  FindDaemonExe()
  if daemon_exe_path ==# ''
    Log('Daemon executable not found. Cannot start.', 'ErrorMsg')
    echohl WarningMsg | echom '[SimpleClipboard] Daemon executable not found.' | echohl None
    return
  endif

  if !executable(daemon_exe_path)
    Log('Daemon file found but is not executable: ' .. daemon_exe_path, 'ErrorMsg')
    echohl ErrorMsg | echom '[SimpleClipboard] Daemon is not executable: ' .. daemon_exe_path | echohl None
    return
  endif

  Log('Starting daemon: ' .. daemon_exe_path, 'Question')
  try
    # 从配置中获取端口，并作为环境变量传递给守护进程
    # 这对应了 daemon.rs 中的 env::var("SIMPLECLIPBOARD_ADDR")
    var port = get(g:, 'simpleclipboard_port', 12345)
    var job_env = {'SIMPLECLIPBOARD_ADDR': '0.0.0.0:' .. port}

    # 使用 job_start 在后台启动守护进程
    job_start([daemon_exe_path], { 'env': job_env, out_io: 'null', err_io: 'null', stoponexit: 'none', })

    # 等待一小段时间，然后再次检查
    sleep 150m
    if IsDaemonRunning()
      Log('Daemon started successfully.', 'ModeMsg')
    else
      Log('Failed to confirm daemon startup. Check permissions or run daemon manually for logs.', 'ErrorMsg')
    endif
  catch
    Log('Error starting daemon process: ' .. v:exception, 'ErrorMsg')
    echohl ErrorMsg | echom '[SimpleClipboard] Failed to start daemon job.' | echohl None
  endtry
enddef

# [导出函数] 停止守护进程
export def StopDaemon(): void
  var pidfile = PidFilePath()
  if !filereadable(pidfile)
    Log('Daemon not running (no PID file found).', 'MoreMsg')
    return
  endif

  try
    var pid = trim(readfile(pidfile)[0])
    if pid == '' || pid !~ '^\d\+$'
      Log('Invalid PID file content. Cannot stop daemon.', 'WarningMsg')
      return
    endif

    if has('unix')
      Log('Stopping daemon with PID: ' .. pid, 'Question')
      system('kill ' .. pid)
      Log('Sent TERM signal to daemon.', 'ModeMsg')
    else
      Log('Auto-stopping daemon is not supported on this OS.', 'Comment')
    endif
  catch
    Log('Error stopping daemon: ' .. v:exception, 'ErrorMsg')
  endtry
enddef

# =============================================================
# 复制逻辑 (TCP Daemon -> Fallbacks)
# =============================================================

# 列表用于保存正在运行的复制任务，防止 job 对象被过早垃圾回收
var running_copy_jobs: list<job> = []

# 当复制任务的 job 结束时，Vim 会自动调用此回调函数
def JobExitCallback(job: job, status: number)
  if status != 0
    var job_info = job_info(job)
    Log($"Copy command '{string(job_info.cmd)}' failed with exit code {status}.", 'WarningMsg')
  endif

  var idx = index(running_copy_jobs, job)
  if idx != -1
    remove(running_copy_jobs, idx)
  endif
enddef

# 通过异步 job 运行外部复制命令
def StartCopyJob(argv: list<string>, text: string): bool
  try
    var job = job_start(argv, {
          \ out_io: 'null',
          \ err_io: 'null',
          \ in_io: 'pipe',
          \ exit_cb: JobExitCallback,
          \ })
    add(running_copy_jobs, job)
    ch_sendraw(job, text)
    ch_close_in(job)
    return true
  catch
    Log('StartCopyJob error: ' .. v:exception, 'WarningMsg')
    return false
  endtry
enddef

def CopyViaDaemonTCP(text: string): bool
  Log('Attempting copy via TCP daemon...', 'Question')
  TryLoadLib()
  if client_lib ==# ''
    Log('Skipped TCP: client library not found.', 'Comment')
    return false
  endif

  var address = GetDaemonAddress()
  Log('Targeting daemon at: ' .. address, 'Identifier')

  # 【关键修正】将 address 和 text 用 NUL 字符拼接
  # address + "\x00" + text
  var payload = address .. "\x01" .. text
  # Log('address: ' .. address)
  # Log('text: ' .. text)
  # Log('payload: ' .. payload)
  # echom map(deepscopy(payload), 'printf("%#x", char2nr(v:val))')

  try
    if libcallnr(client_lib, 'rust_set_clipboard_tcp', payload) == 1
      Log('Success: Sent text to daemon via TCP.', 'ModeMsg')
      return true
    endif

    Log('Failed: Could not send text to daemon via TCP.', 'ErrorMsg')
    return false
  catch
    Log('Error calling client library: ' .. v:exception, 'ErrorMsg')
    return false
  endtry
enddef

def CopyViaCmds(text: string): bool
  Log('Attempting copy via external commands...', 'Question')

  if has('mac') || executable('pbcopy')
    Log('Trying: pbcopy (macOS)', 'Identifier')
    if StartCopyJob(['pbcopy'], text)
      Log('Success: Copied via pbcopy.', 'ModeMsg')
      return true
    endif
    Log('Failed: pbcopy command failed.', 'WarningMsg')
  endif

  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    Log('Trying: wl-copy (Wayland)', 'Identifier')
    if StartCopyJob(['wl-copy'], text)
      Log('Success: Copied via wl-copy.', 'ModeMsg')
      return true
    endif
    Log('Failed: wl-copy command failed.', 'WarningMsg')
  endif

  if executable('xsel')
    Log('Trying: xsel (X11)', 'Identifier')
    if StartCopyJob(['xsel', '--clipboard', '--input'], text)
      Log('Success: Copied via xsel.', 'ModeMsg')
      return true
    endif
    Log('Failed: xsel command failed.', 'WarningMsg')
  endif

  if executable('xclip')
    Log('Trying: xclip (X11)', 'Identifier')
    if StartCopyJob(['xclip', '-selection', 'clipboard'], text)
      Log('Success: Copied via xclip.', 'ModeMsg')
      return true
    endif
    Log('Failed: xclip command failed.', 'WarningMsg')
  endif

  Log('Skipped Cmds: No suitable command found or all failed.', 'Comment')
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

  # OSC52 对超长文本有限制，但远大于原生剪贴板命令
  var limit = get(g:, 'simpleclipboard_osc52_limit', 75000)
  var payload = text
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
      return true
    else
      Log('Skipped OSC52 echo path: /dev/tty not available.', 'Comment')
      return false
    endif
  catch
    Log('Failed: Error writing OSC52 sequence. Details: ' .. v:exception, 'ErrorMsg')
    return false
  endtry
enddef

# =============================================================
# 公共 API
# =============================================================

export def CopyToSystemClipboard(text: string): bool
  # 新的策略：永远优先尝试 TCP 守护进程
  if CopyViaDaemonTCP(text)
    return true
  endif

  Log('TCP daemon failed, falling back to other methods...', 'WarningMsg')

  # 在 SSH/容器中，回退到 OSC52
  if IsSSH() || InContainer()
    return CopyViaOsc52(text) || CopyViaCmds(text) # Cmds 作为 OSC52 的备胎
  endif

  # 在本地，回退到原生命令行工具
  return CopyViaCmds(text) || CopyViaOsc52(text) # OSC52 作为 Cmds 的备胎
enddef

export def CopyYankedToClipboard(_timer_id: any = 0)
  var txt = getreg('"')
  if txt ==# ''
    return
  endif
  if !CopyToSystemClipboard(txt)
    echohl WarningMsg
    echom 'SimpleClipboard: All copy methods failed. Check logs for details.'
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
    echom 'SimpleClipboard: All copy methods failed.'
    echohl None
  endif
enddef
