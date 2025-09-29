vim9script

# =============================================================
# 日志与工具函数
# =============================================================

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

def FindInRuntimepath(rel: string): string
  for dir in split(&runtimepath, ',')
    var path = dir .. '/' .. rel
    if filereadable(path)
      return path
    endif
  endfor
  return ''
enddef

def LibName(): string
  if has('mac')
    return 'libsimpleclipboard.dylib'
  endif
  return 'libsimpleclipboard.so'
enddef

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
  endtry
  return exists('$container') || exists('$DOCKER_CONTAINER') || exists('$KUBERNETES_SERVICE_HOST')
enddef

# =============================================================
# 网络配置、中继与守护进程管理
# =============================================================

var daemon_exe_path: string = ''

def IsPortListening(port: number, host: string = ''): bool
  var pattern = host == '' ? $':{port}' : $"{host}:{port}"
  system($"ss -lnt | grep -q '{pattern}'")
  return v:shell_error == 0
enddef

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

def StartRelay(): void
  var relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
  if IsPortListening(relay_port)
    Log('Persistent relay service is already running.', 'MoreMsg')
    return
  endif

  if get(g:, 'simpleclipboard_relay_method', 'daemon') !=# 'daemon'
    Log($"Relay method is not 'daemon', skipping.", 'Comment')
    return
  endif

  FindDaemonExe()
  if daemon_exe_path ==# ''
    Log("Daemon executable for relay not found.", 'ErrorMsg')
    return
  endif

  if !executable(daemon_exe_path)
    Log("Daemon executable for relay found but is not executable: " .. daemon_exe_path, 'ErrorMsg')
    return
  endif

  Log('Starting persistent relay service with daemon...', 'Question')
  var env_var = $'SIMPLECLIPBOARD_ADDR=0.0.0.0:{relay_port}'
  var command = $"{env_var} nohup {daemon_exe_path} >/dev/null 2>&1 &"
  var argv = ['sh', '-c', command]

  try
    job_start(argv, {stoponexit: 'none'})
    Log($"Executed command to start persistent relay: {command}", 'MoreMsg')
  catch
    Log($"Failed to start persistent relay job. Error: {v:exception}", 'ErrorMsg')
    return
  endtry

  sleep 250m
  if IsPortListening(relay_port)
    Log('Persistent relay service started successfully.', 'ModeMsg')
  else
    Log('Failed to confirm persistent relay service startup.', 'ErrorMsg')
  endif
enddef

# 轻量级的连接测试函数（依赖 rust 客户端库）
def CanConnect_light(address: string): bool
  TryLoadLib()
  if client_lib ==# ''
    return false
  endif

  var payload = address .. "\x01" .. ""
  try
    return libcallnr(client_lib, 'rust_set_clipboard_tcp', payload) == 1
  catch
    Log($"CanConnect_light: libcallnr failed with exception: {v:exception}", 'WarningMsg')
    return false
  endtry
enddef

# 安全的 TCP 连通性测试：不依赖外部命令，不修改剪贴板
def CanConnect(address: string): bool
  try
    # ch_open 支持 "host:port" 字符串；设置较短超时（毫秒）
    var ch = ch_open(address, {'timeout': 500})
    if ch_status(ch) ==# 'open'
      ch_close(ch)
      return true
    endif
  catch
    Log($"CanConnect(ch_open) exception: {v:exception}", 'WarningMsg')
  endtry
  return false
enddef

export def SetupRelayIfNeeded(): void
  if g:simpleclipboard_relay_setup_done != 0 || get(g:, 'simpleclipboard_auto_relay', 1) == 0
    return
  endif

  var changed = false

  if InContainer()
    Log('In container, probing host for reachable relay via socket...', 'Question')
    var ip_cmd = "ip route | awk '/default/ { print $3 }'"
    var container_host_ip = trim(system(ip_cmd))
    if empty(container_host_ip)
      Log('Could not determine container host IP for probing. Aborting.', 'WarningMsg')
    else
      var relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
      var base_port = get(g:, 'simpleclipboard_port', 12344)
      var relay_addr = $"{container_host_ip}:{relay_port}"
      var base_addr = $"{container_host_ip}:{base_port}"

      if CanConnect(relay_addr)
        Log('Container: relay is reachable. Using relay port.', 'ModeMsg')
        g:simpleclipboard_port = relay_port
        changed = true
      elseif CanConnect(base_addr)
        Log('Container: base port is reachable. Using base port.', 'ModeMsg')
        g:simpleclipboard_port = base_port
        changed = true
      else
        Log('Container: relay and base both unreachable. Defaulting to relay port.', 'Comment')
        g:simpleclipboard_port = relay_port
        changed = true
      endif
    endif

  elseif IsSSH()
    Log('In SSH session, checking for tunnel then relay...', 'MoreMsg')
    var final_port = get(g:, 'simpleclipboard_final_daemon_port', 12345)
    if IsPortListening(final_port, '127.0.0.1')
      StartRelay()
      var relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
      if CanConnect($"127.0.0.1:{relay_port}")
        Log('Relay reachable. Switching to relay port.', 'ModeMsg')
        g:simpleclipboard_port = relay_port
        changed = true
      else
        Log('Relay not reachable; using default port.', 'WarningMsg')
      endif
    else
      Log('SSH tunnel not found. Using default port.', 'MoreMsg')
    endif

  else
    Log('Local environment detected; no relay needed.', 'MoreMsg')
  endif

  if changed
    g:simpleclipboard_relay_setup_done = 1
  endif
enddef

def GetDaemonAddress(): string
  var host = get(g:, 'simpleclipboard_local_host', '127.0.0.1')
  var port = g:simpleclipboard_port

  if InContainer()
    var ip_cmd = "ip route | awk '/default/ { print $3 }'"
    var container_host_ip = trim(system(ip_cmd))
    if !empty(container_host_ip)
      host = container_host_ip
    else
      Log('Could not determine container host IP. Falling back to 127.0.0.1.', 'WarningMsg')
      host = '127.0.0.1'
    endif
  elseif IsSSH()
    host = '127.0.0.1'
  endif

  return host .. ':' .. port
enddef

# =============================================================
# 本地主守护进程管理
# =============================================================

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
    Log("Vim is in a remote/container environment, local daemon management is skipped.", 'Comment')
    return
  endif

  if IsDaemonRunning()
    Log('Local daemon is already running.', 'MoreMsg')
    return
  endif

  FindDaemonExe()
  if daemon_exe_path ==# ''
    Log('Local daemon executable not found. Cannot start.', 'ErrorMsg')
    return
  endif

  Log('Starting local daemon: ' .. daemon_exe_path, 'Question')
  try
    var port = g:simpleclipboard_port
    var job_env = {'SIMPLECLIPBOARD_ADDR': '0.0.0.0:' .. port}
    job_start([daemon_exe_path], { 'env': job_env, out_io: 'null', err_io: 'null', stoponexit: 'none' })
    sleep 150m
    if IsDaemonRunning()
      Log('Local daemon started successfully.', 'ModeMsg')
    else
      Log('Failed to confirm local daemon startup.', 'ErrorMsg')
    endif
  catch
    Log('Error starting daemon process: ' .. v:exception, 'ErrorMsg')
  endtry
enddef

export def StopDaemon(): void
  if IsSSH() || InContainer()
    Log("Vim is in a remote/container environment, local daemon management is skipped.", 'Comment')
    return
  endif

  var pidfile = RuntimeDir() .. '/simpleclipboard.pid'
  if !filereadable(pidfile) return endif

  try
    var pid = trim(readfile(pidfile)[0])
    if pid != '' && pid =~ '^\d\+$'
      system('kill ' .. pid)
      Log('Sent TERM signal to local daemon.', 'ModeMsg')
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
    var job = job_start(argv, { in_io: 'pipe', out_io: 'null', err_io: 'null', exit_cb: JobExitCallback })
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
