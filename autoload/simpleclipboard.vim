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
  if has('macunix')
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
# 环境检测（带缓存，只检测一次）
# =============================================================

var cached_is_ssh: number = -1
def IsSSH(): bool
  if cached_is_ssh == -1
    cached_is_ssh = (exists('$SSH_CONNECTION') || exists('$SSH_CLIENT') || exists('$SSH_TTY')) ? 1 : 0
  endif
  return cached_is_ssh == 1
enddef

var cached_in_container: number = -1
def InContainer(): bool
  if cached_in_container == -1
    if filereadable('/.dockerenv') || filereadable('/run/.containerenv')
      cached_in_container = 1
    elseif exists('$container') || exists('$DOCKER_CONTAINER') || exists('$KUBERNETES_SERVICE_HOST')
      cached_in_container = 1
    else
      try
        cached_in_container = readfile('/proc/1/cgroup')->join("\n") =~# '\<docker\>\|\<containerd\>\|\<kubepods\>\|\<libpod\>\|\<podman\>\|\<lxc\>' ? 1 : 0
      catch
        cached_in_container = 0
      endtry
    endif
  endif
  return cached_in_container == 1
enddef

# =============================================================
# 环境探测与网络配置
# =============================================================

var daemon_exe_path: string = ''

def IsTcpOpen(addr: string): bool
  try
    var ch = ch_open(addr, {'timeout': 300})
    if ch_status(ch) ==# 'open'
      ch_close(ch)
      return true
    endif
  catch
  endtry
  return false
enddef

def CanConnect(address: string): bool
  try
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

def ResolveContainerHostIP(): string
  var ip = trim(system("ip route | awk '/default/ { print $3 }'"))
  if empty(ip)
    var host_internal = trim(system("getent hosts host.docker.internal | awk '{print $1}'"))
    if !empty(host_internal)
      ip = host_internal
      Log('Using host.docker.internal as container host IP: ' .. ip, 'Comment')
    endif
  endif
  return ip
enddef

# --- 环境探测结果（模块级状态） ---
var env_detected: bool = false
var is_remote: bool = false
var tunnel_available: bool = false
var daemon_address: string = ''

export def DetectEnvironment(): void
  if env_detected
    return
  endif
  env_detected = true

  var daemon_port = get(g:, 'simpleclipboard_port', 12343)
  var tunnel_port = get(g:, 'simpleclipboard_tunnel_port', 12345)

  if !IsSSH() && !InContainer()
    # 本地环境：直连 daemon
    is_remote = false
    daemon_address = '127.0.0.1:' .. daemon_port
    Log('Local environment. Daemon address: ' .. daemon_address, 'MoreMsg')
    return
  endif

  is_remote = true

  if InContainer() && IsSSH()
    # SSH → Container 嵌套：探测宿主机的 tunnel 端口
    Log('SSH + Container detected, probing host for tunnel...', 'Question')

    # 先试 --network host 场景
    if IsTcpOpen($"127.0.0.1:{tunnel_port}")
      daemon_address = '127.0.0.1:' .. tunnel_port
      tunnel_available = true
      Log('SSH+Container: localhost tunnel reachable (host network mode).', 'ModeMsg')
      return
    endif

    # 再试容器宿主机 IP
    var host_ip = ResolveContainerHostIP()
    if !empty(host_ip)
      g:simpleclipboard_incontainer_host_ip = host_ip
      if CanConnect($"{host_ip}:{tunnel_port}")
        daemon_address = host_ip .. ':' .. tunnel_port
        tunnel_available = true
        g:simpleclipboard_incontainer_target = 'host'
        Log('SSH+Container: host tunnel reachable at ' .. daemon_address, 'ModeMsg')
        return
      endif
    endif

    Log('SSH+Container: no TCP path found, will use OSC52.', 'Comment')

  elseif IsSSH()
    # 纯 SSH：探测隧道
    Log('SSH session detected, probing tunnel port...', 'Question')
    if IsTcpOpen($"127.0.0.1:{tunnel_port}")
      daemon_address = '127.0.0.1:' .. tunnel_port
      tunnel_available = true
      Log('SSH: tunnel reachable at ' .. daemon_address, 'ModeMsg')
    else
      Log('SSH: no tunnel found, will use OSC52.', 'Comment')
    endif

  elseif InContainer()
    # 本地容器：探测宿主机 daemon
    Log('Container detected, probing host for daemon...', 'Question')
    var host_ip = ResolveContainerHostIP()
    if !empty(host_ip)
      g:simpleclipboard_incontainer_host_ip = host_ip
      if CanConnect($"{host_ip}:{daemon_port}")
        daemon_address = host_ip .. ':' .. daemon_port
        tunnel_available = true
        g:simpleclipboard_incontainer_target = 'host'
        Log('Container: host daemon reachable at ' .. daemon_address, 'ModeMsg')
        return
      endif
    endif

    # 试 127.0.0.1（--network host 场景）
    if IsTcpOpen($"127.0.0.1:{daemon_port}")
      daemon_address = '127.0.0.1:' .. daemon_port
      tunnel_available = true
      g:simpleclipboard_incontainer_target = 'local'
      Log('Container: local daemon reachable.', 'ModeMsg')
    else
      Log('Container: no TCP path found, will use OSC52.', 'Comment')
    endif
  endif
enddef

def GetDaemonAddress(): string
  DetectEnvironment()
  return daemon_address
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
      system('kill -0 ' .. pid .. ' 2>/dev/null')
      return v:shell_error == 0
    endif
  catch
    return false
  endtry
  return false
enddef

export def StartDaemon(): void
  if InContainer() || IsSSH()
    Log("Skip local daemon autostart in SSH/container.", 'Comment')
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
    var bind_addr = get(g:, 'simpleclipboard_bind_addr', '127.0.0.1')
    var job_env = {'SIMPLECLIPBOARD_ADDR': bind_addr .. ':' .. port}
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
  if InContainer()
    Log("Vim is in a remote/container environment, local daemon management is skipped.", 'Comment')
    return
  endif

  var pidfile = RuntimeDir() .. '/simpleclipboard.pid'
  if !filereadable(pidfile)
    return
  endif

  try
    var pid = trim(readfile(pidfile)[0])
    if pid != '' && pid =~ '^\d\+$'
      system('kill ' .. pid)
      if v:shell_error == 0
        Log('Sent TERM signal to local daemon.', 'ModeMsg')
      else
        Log('Failed to send TERM to local daemon (pid ' .. pid .. ').', 'WarningMsg')
      endif

      sleep 100m
      try
        delete(pidfile)
      catch
      endtry
    else
      Log('PID file content invalid; removing pid file.', 'WarningMsg')
      try
        delete(pidfile)
      catch
      endtry
    endif
  catch
    Log('Error stopping daemon: ' .. v:exception, 'ErrorMsg')
  endtry
enddef

# =============================================================
# 复制逻辑 (TCP Daemon / OSC52 / 外部命令)
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
  if address ==# ''
    return false
  endif
  Log('Targeting daemon at: ' .. address, 'Identifier')

  var token = get(g:, 'simpleclipboard_token', '')
  var payload = address .. "\x01" .. "set" .. "\x01" .. text .. "\x01" .. token

  try
    if libcallnr(client_lib, 'rust_set_clipboard_tcp', payload) == 1
      Log('Success: Sent text to daemon via TCP (Msg::Set).', 'ModeMsg')
      return true
    endif
    Log('Failed: Could not send text to daemon via TCP.', 'ErrorMsg')
    return false
  catch
    Log('Error calling client library: ' .. v:exception, 'ErrorMsg')
    return false
  endtry
enddef

# 缓存可用的外部复制命令
var cached_copy_cmd: list<any> = []
var cached_copy_cmd_checked: bool = false

def DetectCopyCmd(): void
  if cached_copy_cmd_checked
    return
  endif
  cached_copy_cmd_checked = true

  if has('mac') || executable('pbcopy')
    cached_copy_cmd = [['pbcopy'], 'pbcopy']
    return
  endif
  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    cached_copy_cmd = [['wl-copy'], 'wl-copy']
    return
  endif
  if executable('xsel')
    cached_copy_cmd = [['xsel', '--clipboard', '--input'], 'xsel']
    return
  endif
  if executable('xclip')
    cached_copy_cmd = [['xclip', '-selection', 'clipboard'], 'xclip']
    return
  endif
enddef

def CopyViaCmds(text: string): bool
  Log('Attempting copy via external commands...', 'Question')
  DetectCopyCmd()

  if empty(cached_copy_cmd)
    Log('Skipped Cmds: No suitable command found.', 'Comment')
    return false
  endif

  var argv: list<string> = cached_copy_cmd[0]
  var name: string = cached_copy_cmd[1]
  Log($'Trying: {name}', 'Identifier')
  if StartCopyJob(argv, text)
    Log($'Success: Copied via {name}.', 'ModeMsg')
    return true
  endif
  Log($'Failed: {name} command failed.', 'WarningMsg')
  return false
enddef

def CopyViaOsc52(text: string): bool
  if get(g:, 'simpleclipboard_disable_osc52', 0)
    Log('Skipped OSC52: disabled by g:simpleclipboard_disable_osc52.', 'Comment')
    return false
  endif

  Log('Attempting copy via OSC52 terminal sequence...', 'Question')

  var limit = get(g:, 'simpleclipboard_osc52_limit', 75000)
  var payload = strchars(text) > limit ? strcharpart(text, 0, limit) : text
  if strchars(text) > limit
    Log('Text truncated to ' .. limit .. ' characters for OSC52.', 'Comment')
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
  DetectEnvironment()

  if !is_remote
    # 本地：TCP daemon 优先
    Log('Local: trying TCP daemon...', 'Question')
    if CopyViaDaemonTCP(text)
      return true
    endif
    Log('Local: TCP failed, trying fallbacks...', 'WarningMsg')
    return CopyViaCmds(text) || CopyViaOsc52(text)
  endif

  # 远程场景
  if tunnel_available
    # 有 TCP 通路（隧道或宿主机 daemon）：TCP 优先，OSC52 兜底
    Log('Remote (tunnel available): trying TCP...', 'Question')
    if CopyViaDaemonTCP(text)
      return true
    endif
    Log('Remote: TCP failed, falling back to OSC52...', 'WarningMsg')
  endif

  # 无隧道或 TCP 失败：OSC52 优先
  return CopyViaOsc52(text) || CopyViaCmds(text)
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

var debounce_timer: number = -1

export def CopyYankedToClipboardEvent(ev: any = v:null, _timer_id: any = 0)
  var txt = ''
  if type(ev) == v:t_dict
    if has_key(ev, 'operator') && ev.operator !=# 'y'
      return
    endif
    if has_key(ev, 'regcontents')
      var lines = ev.regcontents
      txt = join(lines, "\n")
    endif
  endif

  if txt ==# ''
    txt = getreg('"')
  endif

  if txt ==# ''
    return
  endif

  if debounce_timer != -1
    timer_stop(debounce_timer)
  endif
  var captured_txt = txt
  debounce_timer = timer_start(50, (_) => {
    debounce_timer = -1
    if !CopyToSystemClipboard(captured_txt)
      echohl WarningMsg
      echom 'SimpleClipboard: All copy methods failed. Check logs for details.'
      echohl None
    endif
  })
enddef

export def Status(): void
  DetectEnvironment()
  Log('IsSSH: ' .. string(IsSSH()), 'Comment')
  Log('InContainer: ' .. string(InContainer()), 'Comment')
  Log('is_remote: ' .. string(is_remote), 'Comment')
  Log('tunnel_available: ' .. string(tunnel_available), 'Comment')
  Log('daemon_address: ' .. daemon_address, 'Comment')
  Log('Port (g:simpleclipboard_port): ' .. string(g:simpleclipboard_port), 'Comment')
  var tunnel_port = get(g:, 'simpleclipboard_tunnel_port', 12345)
  Log('Tunnel port: ' .. tunnel_port .. ' open: ' .. string(IsTcpOpen($"127.0.0.1:{tunnel_port}")), 'Comment')
enddef
