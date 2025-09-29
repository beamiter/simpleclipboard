vim9script

# =============================================================
# 日志与工具函数
# =============================================================

# 取运行时目录（优先 XDG_RUNTIME_DIR，回退 /tmp）
def RuntimeDir(): string
  var dir = getenv('XDG_RUNTIME_DIR')
  # 【修正 1】: 使用 empty() 来安全地处理 getenv() 可能返回的 v:null
  if empty(dir)
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

def IsSSH(): bool
  return exists('$SSH_CONNECTION') || exists('$SSH_CLIENT') || exists('$SSH_TTY')
enddef

def InContainer(): bool
  if filereadable('/.dockerenv') || filereadable('/run/.containerenv')
    return true
  endif

  try
    var lines = readfile('/proc/1/cgroup')
    for l in lines
      if l =~# '\<docker\>\|\<containerd\>\|\<kubepods\>\|\<libpod\>\|\<podman\>\|\<lxc\>'
        return true
      endif
    endfor
  catch
  endtry

  if exists('$container') || exists('$DOCKER_CONTAINER') || exists('$KUBERNETES_SERVICE_HOST')
    return true
  endif

  return false
enddef

# =============================================================
# 网络配置、中继与守护进程管理
# =============================================================
g:simpleclipboard_port = get(g:, 'simpleclipboard_port', 12345)
g:simpleclipboard_local_host = get(g:, 'simpleclipboard_local_host', '127.0.0.1')

var daemon_exe_path: string = ''
g:simpleclipboard_relay_setup_done = false

# 检查指定端口是否正在监听
def IsPortListening(port: number, host: string = ''): bool
  # 【修正 2】: 增加对 'ss' 命令的依赖检查
  if !executable('ss')
    Log("Command 'ss' not found. Cannot check for listening ports. Please install 'iproute2' package.", 'WarningMsg')
    return false
  endif

  var pattern = host == '' ? $':{port}' : $"{host}:{port}"
  system($"ss -lnt | grep -q '{pattern}'")
  return v:shell_error == 0
enddef

# 启动中继服务
def StartRelay(): void
  if IsPortListening(get(g:, 'simpleclipboard_relay_port', 12346))
    Log('Relay service is already running.', 'MoreMsg')
    return
  endif

  if get(g:, 'simpleclipboard_relay_method', 'daemon') !=# 'daemon'
    Log($"Relay method is not 'daemon' (current: '{get(g:, 'simpleclipboard_relay_method', 'daemon')}'), skipping.", 'Comment')
    return
  endif
  
  FindDaemonExe()
  if daemon_exe_path ==# ''
    Log("Relay method is 'daemon', but daemon executable not found.", 'ErrorMsg')
    return
  endif

  if !executable(daemon_exe_path)
    Log("Daemon executable found but is not executable: " .. daemon_exe_path, 'ErrorMsg')
    return
  endif

  Log('Starting relay service with daemon...', 'Question')
  var relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
  var env = {'SIMPLECLIPBOARD_ADDR': $'0.0.0.0:{relay_port}'}
  job_start([daemon_exe_path], {env: env, out_io: 'null', err_io: 'null', stoponexit: 'none'})

  sleep 150m
  if IsPortListening(relay_port)
    Log('Relay service started successfully.', 'ModeMsg')
  else
    Log('Failed to confirm relay service startup.', 'ErrorMsg')
  endif
enddef

# [导出] 自动设置中继（如果需要）
export def SetupRelayIfNeeded(): void
  if g:simpleclipboard_relay_setup_done || get(g:, 'simpleclipboard_auto_relay', 1) == 0
    return
  endif
  g:simpleclipboard_relay_setup_done = true

  Log('Checking for relay necessity by looking for a tunnel...', 'MoreMsg')

  var final_port = get(g:, 'simpleclipboard_final_daemon_port', 12345)
  if IsPortListening(final_port, '127.0.0.1')
    Log('SSH tunnel to final daemon found. Setting up relay...', 'Question')
    StartRelay()

    var relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
    if IsPortListening(relay_port)
      Log($"Relay is active. Re-routing this session's traffic to port {relay_port}.", 'ModeMsg')
      g:simpleclipboard_port = relay_port
    else
      Log("Failed to start or find relay service. Will use default port and likely fail.", 'WarningMsg')
    endif
  else
    Log("SSH tunnel not found. Assuming local environment. No relay will be set up.", 'MoreMsg')
  endif
enddef

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
    Log('In SSH session, targeting 127.0.0.1 (relies on port forwarding or relay).', 'MoreMsg')
  endif

  return host .. ':' .. port
enddef

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

# 检查守护进程是否正在运行 (基于主 PID 文件)
def IsDaemonRunning(): bool
  var pidfile = PidFilePath()
  if !filereadable(pidfile)
    return false
  endif

  try
    var pid = trim(readfile(pidfile)[0])
    if pid == '' || pid !~ '^\d\+$'
      return false
    endif

    if has('unix')
      system('ps -p ' .. pid .. ' > /dev/null 2>&1')
      return v:shell_error == 0
    endif
  catch
    return false
  endtry
  return false
enddef

# [导出函数] 启动主守护进程
export def StartDaemon(): void
  if IsDaemonRunning()
    Log('Main daemon is already running.', 'MoreMsg')
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

  Log('Starting main daemon: ' .. daemon_exe_path, 'Question')
  try
    var port = g:simpleclipboard_port
    var job_env = {'SIMPLECLIPBOARD_ADDR': '0.0.0.0:' .. port}
    job_start([daemon_exe_path], { 'env': job_env, out_io: 'null', err_io: 'null', stoponexit: 'none', })

    sleep 150m
    if IsDaemonRunning()
      Log('Main daemon started successfully.', 'ModeMsg')
    else
      Log('Failed to confirm main daemon startup.', 'ErrorMsg')
    endif
  catch
    Log('Error starting daemon process: ' .. v:exception, 'ErrorMsg')
    echohl ErrorMsg | echom '[SimpleClipboard] Failed to start daemon job.' | echohl None
  endtry
enddef

# [导出函数] 停止主守护进程
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
var running_copy_jobs: list<job> = []

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
  TryLoadLib()
  if client_lib ==# ''
    Log('Skipped TCP: client library not found.', 'Comment')
    return false
  endif

  var address = GetDaemonAddress()
  Log('Targeting daemon at: ' .. address, 'Identifier')

  var payload = address .. "\x01" .. text

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
  SetupRelayIfNeeded()

  Log('Attempting copy via TCP daemon...', 'Question')
  if CopyViaDaemonTCP(text)
    return true
  endif

  Log('TCP daemon failed, falling back to other methods...', 'WarningMsg')

  if IsSSH() || InContainer()
    return CopyViaOsc52(text) || CopyViaCmds(text)
  endif

  return CopyViaCmds(text) || CopyViaOsc52(text)
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
