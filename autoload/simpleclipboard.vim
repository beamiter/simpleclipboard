vim9script

# =============================================================
# 日志与工具函数
# =============================================================

# 取运行时目录（优先 XDG_RUNTIME_DIR，回退 /tmp）
def RuntimeDir(): string
  var dir = getenv('XDG_RUNTIME_DIR')
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

# 加载动态库
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
# 环境检测
# =============================================================

def IsSSH(): bool
  return exists('$SSH_CONNECTION') || exists('$SSH_CLIENT') || exists('$SSH_TTY')
enddef

def InContainer(): bool
  if filereadable('/.dockerenv') || filereadable('/run/.containerenv')
    return true
  endif
  try
    return readfile('/proc/1/cgroup')->join("\n") =~# '\<docker\>\|\<containerd\>\|\<kubepods\>\|\<libpod\>\|\<podman\>\|\<lxc\>'
  catch
    # Ignore errors if file is not readable
  endtry
  return exists('$container') || exists('$DOCKER_CONTAINER') || exists('$KUBERNETES_SERVICE_HOST')
enddef

# =============================================================
# 网络配置、中继与守护进程管理
# =============================================================
g:simpleclipboard_port = get(g:, 'simpleclipboard_port', 12345)
g:simpleclipboard_local_host = get(g:, 'simpleclipboard_local_host', '127.0.0.1')
g:simpleclipboard_relay_setup_done = false

# 轻量级的连接测试函数
def CanConnect(address: string): bool
  TryLoadLib()
  if client_lib ==# ''
    return false
  endif

  var payload = address .. "\x01" .. ""
  try
    return libcallnr(client_lib, 'rust_set_clipboard_tcp', payload) == 1
  catch
    Log($"CanConnect: libcallnr failed with exception: {v:exception}", 'WarningMsg')
    return false
  endtry
enddef

# 主动探测环境并设置中继
export def SetupRelayIfNeeded(): void
  if g:simpleclipboard_relay_setup_done
    return
  endif
  g:simpleclipboard_relay_setup_done = true

  if InContainer()
    Log('In container, starting active probe to determine environment...', 'Question')
    
    var ip_cmd = "ip route | awk '/default/ { print $3 }'"
    var container_host_ip = trim(system(ip_cmd))
    if empty(container_host_ip)
      Log('Could not determine container host IP for probing. Aborting.', 'WarningMsg')
      return
    endif
    Log('Probe: Found container host IP: ' .. container_host_ip, 'MoreMsg')

    var final_port = get(g:, 'simpleclipboard_final_daemon_port', 12345)
    var relay_port = get(g:, 'simpleclipboard_relay_port', 12346)

    var remote_docker_addr = $"{container_host_ip}:{relay_port}"
    var local_docker_addr = $"{container_host_ip}:{final_port}"

    Log('Probe: Testing connection to relay port ' .. remote_docker_addr, 'Identifier')
    if CanConnect(remote_docker_addr)
      Log('Probe successful: Connected to relay port. Assuming remote Docker environment.', 'ModeMsg')
      g:simpleclipboard_port = relay_port
      return
    endif

    Log('Probe: Testing connection to final port ' .. local_docker_addr, 'Identifier')
    if CanConnect(local_docker_addr)
      Log('Probe successful: Connected to final port. Assuming local Docker environment.', 'ModeMsg')
      g:simpleclipboard_port = final_port
      return
    endif

    Log('Probe failed: Cannot connect to either relay or final port. TCP copy will likely fail.', 'WarningMsg')

  elseif IsSSH()
    Log('In SSH session (not in container), checking for relay...', 'MoreMsg')
    var relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
    if CanConnect($"127.0.0.1:{relay_port}")
      Log('Relay found on localhost. Re-routing to relay port.', 'ModeMsg')
      g:simpleclipboard_port = relay_port
    else
      Log('No relay found on localhost. Using default port for SSH tunnel.', 'MoreMsg')
    endif
  
  else
    Log('Assuming local environment, no relay setup needed.', 'MoreMsg')
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

# =============================================================
# 主守护进程管理 (主要用于本地环境)
# =============================================================
var daemon_exe_path: string = ''

def FindDaemonExe(): void
  if daemon_exe_path !=# '' | return | endif
  var override = get(g:, 'simpleclipboard_daemon_path', '')
  if type(override) == v:t_string && override !=# ''
    if filereadable(override)
      daemon_exe_path = override
      return
    endif
  endif
  daemon_exe_path = FindInRuntimepath('lib/simpleclipboard-daemon')
enddef

def IsDaemonRunning(): bool
  var pidfile = RuntimeDir() .. '/simpleclipboard.pid'
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

export def StartDaemon(): void
  if IsSSH() || InContainer()
    Log("Vim is in a remote or containerized environment, daemon management is handled externally. Skipping auto-start.", 'Comment')
    return
  endif

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

export def StopDaemon(): void
  if IsSSH() || InContainer()
    Log("Vim is in a remote or containerized environment, daemon management is handled externally. Skipping auto-stop.", 'Comment')
    return
  endif

  var pidfile = RuntimeDir() .. '/simpleclipboard.pid'
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
