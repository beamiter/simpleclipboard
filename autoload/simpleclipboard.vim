vim9script

const VERSION = '0.2.0'
const FIELD_SEPARATOR = "\x01"
const DAEMON_FAILURE = 0
const DAEMON_SUCCESS = 1
const DAEMON_UNCERTAIN = 2
const MAX_TOKEN_BYTES = 4096

def TokenValidationError(token: any): string
  if type(token) != v:t_string
    return 'g:simpleclipboard_token must be a string'
  endif
  if stridx(token, FIELD_SEPARATOR) >= 0
    return 'g:simpleclipboard_token must not contain U+0001'
  endif
  if strlen(token) > MAX_TOKEN_BYTES
    return $'g:simpleclipboard_token exceeds {MAX_TOKEN_BYTES} UTF-8 bytes'
  endif
  return ''
enddef

# -----------------------------------------------------------------------------
# Messages and paths
# -----------------------------------------------------------------------------

def StateDir(): string
  var base = getenv('XDG_STATE_HOME')
  if empty(base) || base[0] !=# '/'
    base = expand('~/.local/state')
  endif
  return base .. '/simpleclipboard'
enddef

def UsesDefaultDebugFile(): bool
  var configured = get(g:, 'simpleclipboard_debug_file', '')
  return type(configured) != v:t_string || configured ==# ''
enddef

def DebugFile(): string
  return UsesDefaultDebugFile()
    ? StateDir() .. '/simpleclipboard.log'
    : expand(get(g:, 'simpleclipboard_debug_file', ''))
enddef

def PrepareDefaultDebugFile(path: string): void
  if !UsesDefaultDebugFile()
    return
  endif
  var dir = fnamemodify(path, ':h')
  var dir_type = getftype(dir)
  if dir_type ==# ''
    mkdir(dir, 'p', 0o700)
  elseif dir_type !=# 'dir'
    throw 'default debug path is not a private directory'
  endif
  if setfperm(dir, 'rwx------') != 1
    throw 'could not secure default debug directory'
  endif
  var file_type = getftype(path)
  if file_type !=# '' && file_type !=# 'file'
    throw 'default debug path is not a regular file'
  endif
enddef

def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpleclipboard_debug', 0) == 0
    return
  endif
  if get(g:, 'simpleclipboard_debug_to_file', 0)
    try
      var path = DebugFile()
      PrepareDefaultDebugFile(path)
      writefile([strftime('%Y-%m-%d %H:%M:%S ') .. msg], path, 'a')
      if UsesDefaultDebugFile() && setfperm(path, 'rw-------') != 1
        throw 'could not secure default debug file'
      endif
      return
    catch
      # Fall through to :messages when the configured file is unavailable.
    endtry
  endif
  echohl hl
  echom '[SimpleClipboard] ' .. msg
  echohl None
enddef

# Every notification is retained so :SimpleCopyLog can explain a copy that
# silently took the wrong route.
var log_ring: list<string> = []

export def ShowLog(): void
  new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setline(1, empty(log_ring) ? ['(no log entries)'] : log_ring)
  setlocal nomodifiable
  normal! G
enddef

export def RestartDaemon(): void
  StopDaemon(false)
  StartDaemon(true, true)
enddef

def Notify(msg: string, hl: string = 'None')
  log_ring->add(strftime('%H:%M:%S') .. ' ' .. msg)
  if len(log_ring) > 500
    log_ring = log_ring[-300 : ]
  endif
  echohl hl
  echom '[SimpleClipboard] ' .. msg
  echohl None
enddef

def FindInRuntimepath(relative: string): string
  for path in globpath(&runtimepath, relative, true, true)
    if filereadable(path)
      return path
    endif
  endfor
  return ''
enddef

def LibName(): string
  return has('macunix') ? 'libsimpleclipboard.dylib' : 'libsimpleclipboard.so'
enddef

var client_lib = ''
var client_abi = 0 # 0 unknown, 1 legacy ABI, 2 delimiter-safe ABI

def TryLoadLib(): void
  if client_lib !=# ''
    return
  endif
  var override = get(g:, 'simpleclipboard_libpath', '')
  if type(override) == v:t_string && override !=# '' && filereadable(override)
    client_lib = override
  else
    client_lib = FindInRuntimepath('lib/' .. LibName())
  endif
  if client_lib !=# ''
    Log('Client library: ' .. client_lib, 'MoreMsg')
  endif
enddef

var daemon_exe_path = ''

def FindDaemonExe(): void
  if daemon_exe_path !=# ''
    return
  endif
  var override = get(g:, 'simpleclipboard_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override) == 1
    daemon_exe_path = override
    return
  endif
  var candidate = FindInRuntimepath('lib/simpleclipboard-daemon')
  if candidate !=# '' && executable(candidate) == 1
    daemon_exe_path = candidate
  endif
enddef

# -----------------------------------------------------------------------------
# Environment discovery
# -----------------------------------------------------------------------------

var cached_is_ssh = -1
var cached_in_container = -1
var cached_is_wsl = -1

def IsSSH(): bool
  if cached_is_ssh == -1
    cached_is_ssh = exists('$SSH_CONNECTION') || exists('$SSH_CLIENT') || exists('$SSH_TTY') ? 1 : 0
  endif
  return cached_is_ssh == 1
enddef

def InContainer(): bool
  if cached_in_container == -1
    if filereadable('/.dockerenv') || filereadable('/run/.containerenv')
      cached_in_container = 1
    elseif exists('$container') || exists('$DOCKER_CONTAINER') || exists('$KUBERNETES_SERVICE_HOST')
      cached_in_container = 1
    else
      try
        cached_in_container = readfile('/proc/1/cgroup')->join("\n")
          =~# '\<docker\>\|\<containerd\>\|\<kubepods\>\|\<libpod\>\|\<podman\>\|\<lxc\>' ? 1 : 0
      catch
        cached_in_container = 0
      endtry
    endif
  endif
  return cached_in_container == 1
enddef

def IsWSL(): bool
  if cached_is_wsl == -1
    try
      cached_is_wsl = readfile('/proc/sys/kernel/osrelease')->join('') =~? 'microsoft' ? 1 : 0
    catch
      cached_is_wsl = 0
    endtry
  endif
  return cached_is_wsl == 1
enddef

def HostPort(host: string, port: number): string
  if host =~# ':' && host !~# '^\[.*\]$'
    return '[' .. host .. ']:' .. string(port)
  endif
  return host .. ':' .. string(port)
enddef

def IsIpv4Loopback(host: string): bool
  var parts = split(host, '\.', true)
  if len(parts) != 4 || parts[0] !=# '127'
    return false
  endif
  for part in parts
    if part !~# '^\d\{1,3}$' || str2nr(part, 10) > 255
      return false
    endif
  endfor
  return true
enddef

def IsLoopbackHost(host: string): bool
  return IsIpv4Loopback(host) || index(['localhost', '::1', '[::1]'], tolower(host)) >= 0
enddef

def IsLoopbackAddress(address: string): bool
  var separator = strridx(address, ':')
  return separator > 0 && IsLoopbackHost(strpart(address, 0, separator))
enddef

def IsTcpOpen(address: string): bool
  try
    var channel = ch_open(address, {waittime: 300, mode: 'raw'})
    if ch_status(channel) ==# 'open'
      ch_close(channel)
      return true
    endif
  catch
    Log($'TCP probe failed for {address}: {v:exception}', 'WarningMsg')
  endtry
  return false
enddef

def ResolveContainerHostIP(): string
  var configured = get(g:, 'simpleclipboard_container_host', '')
  if type(configured) == v:t_string && configured !=# ''
    return configured
  endif

  if executable('ip') == 1
    for line in systemlist('ip route')
      if line =~# '^default\s'
        var fields = split(line)
        var via = index(fields, 'via')
        if via >= 0 && via + 1 < len(fields)
          return fields[via + 1]
        endif
      endif
    endfor
  endif

  if executable('getent') == 1
    var hosts = systemlist('getent hosts host.docker.internal')
    if v:shell_error == 0 && !empty(hosts)
      return split(hosts[0])[0]
    endif
  endif
  return ''
enddef

var env_detected = false
var is_remote = false
var tunnel_available = false
var daemon_address = ''
var environment_kind = 'unknown'
var custom_address = false
var daemon_route_error = ''

export def DetectEnvironment(): void
  if env_detected
    return
  endif
  env_detected = true
  is_remote = IsSSH() || InContainer()
  tunnel_available = false
  custom_address = false
  daemon_route_error = ''

  if IsSSH() && InContainer()
    environment_kind = 'ssh+container'
  elseif IsSSH()
    environment_kind = 'ssh'
  elseif InContainer()
    environment_kind = 'container'
  else
    environment_kind = IsWSL() ? 'wsl' : 'local'
  endif

  if !get(g:, 'simpleclipboard_daemon_enabled', 1) || !has('libcall')
    daemon_address = ''
    Log(environment_kind .. ': daemon routing disabled; skipping network probes.', 'Comment')
    return
  endif

  var override = get(g:, 'simpleclipboard_address', '')
  var token = get(g:, 'simpleclipboard_token', '')
  var token_error = TokenValidationError(token)
  if token_error !=# ''
    daemon_address = ''
    daemon_route_error = token_error
    Log(token_error .. '; daemon routing blocked.', 'ErrorMsg')
    return
  endif
  if type(override) == v:t_string && override !=# ''
    custom_address = true
    environment_kind = 'custom'
    if type(token) != v:t_string || token ==# ''
      daemon_address = ''
      daemon_route_error = 'custom daemon routing requires g:simpleclipboard_token'
      Log(daemon_route_error .. '; refusing plaintext daemon traffic.', 'ErrorMsg')
      return
    endif
    daemon_address = override
    tunnel_available = true
    Log('Using g:simpleclipboard_address: ' .. daemon_address, 'MoreMsg')
    return
  endif

  if is_remote && (type(token) != v:t_string || token ==# '')
    daemon_address = ''
    daemon_route_error = 'remote daemon routing requires g:simpleclipboard_token'
    Log(daemon_route_error .. '; skipping route probes and plaintext daemon traffic.', 'ErrorMsg')
    return
  endif

  var daemon_port = get(g:, 'simpleclipboard_port', 12343)
  var tunnel_port = get(g:, 'simpleclipboard_tunnel_port', 12345)
  if !is_remote
    if IsWSL()
      environment_kind = 'wsl'
      daemon_address = ''
      return
    endif
    environment_kind = 'local'
    var configured_host = get(g:, 'simpleclipboard_bind_addr', '127.0.0.1')
    var client_host = configured_host ==# '0.0.0.0' ? '127.0.0.1'
      : configured_host ==# '::' || configured_host ==# '[::]' ? '::1' : configured_host
    if !IsLoopbackHost(client_host) && (type(token) != v:t_string || token ==# '')
      daemon_address = ''
      daemon_route_error = 'non-loopback daemon routing requires g:simpleclipboard_token'
      Log(daemon_route_error .. '; refusing plaintext daemon traffic.', 'ErrorMsg')
      return
    endif
    daemon_address = HostPort(client_host, daemon_port)
    return
  endif

  if IsSSH() && InContainer()
    environment_kind = 'ssh+container'
    var local_tunnel = HostPort('127.0.0.1', tunnel_port)
    if IsTcpOpen(local_tunnel)
      daemon_address = local_tunnel
      tunnel_available = true
      return
    endif
    var host = ResolveContainerHostIP()
    if host !=# '' && IsTcpOpen(HostPort(host, tunnel_port))
      daemon_address = HostPort(host, tunnel_port)
      tunnel_available = true
      return
    endif
  elseif IsSSH()
    environment_kind = 'ssh'
    var tunnel = HostPort('127.0.0.1', tunnel_port)
    if IsTcpOpen(tunnel)
      daemon_address = tunnel
      tunnel_available = true
      return
    endif
  else
    environment_kind = 'container'
    var host = ResolveContainerHostIP()
    if host !=# '' && IsTcpOpen(HostPort(host, daemon_port))
      daemon_address = HostPort(host, daemon_port)
      tunnel_available = true
      return
    endif
    var local_daemon = HostPort('127.0.0.1', daemon_port)
    if IsTcpOpen(local_daemon)
      daemon_address = local_daemon
      tunnel_available = true
      return
    endif
  endif
  daemon_address = ''
  Log(environment_kind .. ': no daemon route detected; fallbacks remain available.', 'Comment')
enddef

def GetDaemonAddress(): string
  DetectEnvironment()
  return daemon_address
enddef

# -----------------------------------------------------------------------------
# Daemon client and lifecycle
# -----------------------------------------------------------------------------

var daemon_job: job
var daemon_start_attempted = false
var daemon_jobs_being_stopped: list<job> = []

def DaemonJobRunning(): bool
  return job_status(daemon_job) ==# 'run'
enddef

def NormalizeDaemonResult(result: number): number
  return result == DAEMON_SUCCESS || result == DAEMON_UNCERTAIN
    ? result : DAEMON_FAILURE
enddef

def DaemonRequest(action: string, text: string, address: string = ''): number
  if !has('libcall')
    return DAEMON_FAILURE
  endif
  TryLoadLib()
  if client_lib ==# ''
    return DAEMON_FAILURE
  endif
  var target = address ==# '' ? GetDaemonAddress() : address
  var token = get(g:, 'simpleclipboard_token', '')
  var token_error = TokenValidationError(token)
  if token_error !=# ''
    Log(token_error .. '.', 'ErrorMsg')
    return DAEMON_FAILURE
  endif
  if target ==# '' || stridx(target, FIELD_SEPARATOR) >= 0
    return DAEMON_FAILURE
  endif
  if token ==# '' && (is_remote || custom_address || !IsLoopbackAddress(target))
    Log('Refusing plaintext daemon traffic outside the default local loopback route.', 'ErrorMsg')
    return DAEMON_FAILURE
  endif

  if client_abi != 1
    var payload = 'SCB2' .. FIELD_SEPARATOR .. target .. FIELD_SEPARATOR .. action
      .. FIELD_SEPARATOR .. token .. FIELD_SEPARATOR .. text
    try
      var result = libcallnr(client_lib, 'rust_set_clipboard_tcp_v2', payload)
      client_abi = 2
      return NormalizeDaemonResult(result)
    catch
      client_abi = 1
      Log('Delimiter-safe client ABI unavailable; trying v0.1 compatibility ABI.', 'WarningMsg')
    endtry
  endif

  if stridx(text, FIELD_SEPARATOR) >= 0
    Log('Legacy client ABI cannot safely carry U+0001 text.', 'ErrorMsg')
    return DAEMON_FAILURE
  endif
  try
    var legacy = target .. FIELD_SEPARATOR .. action .. FIELD_SEPARATOR .. text
      .. FIELD_SEPARATOR .. token
    return NormalizeDaemonResult(libcallnr(client_lib, 'rust_set_clipboard_tcp', legacy))
  catch
    Log('Client library call failed: ' .. v:exception, 'ErrorMsg')
    return DAEMON_FAILURE
  endtry
enddef

def PingDaemon(address: string = ''): bool
  return DaemonRequest('ping', '', address) == DAEMON_SUCCESS
enddef

def DaemonExitCallback(exited_job: job, status: number)
  var stopped_index = index(daemon_jobs_being_stopped, exited_job)
  var stop_requested = stopped_index >= 0
  if stop_requested
    remove(daemon_jobs_being_stopped, stopped_index)
  endif
  if status != 0 && !stop_requested
    Log('Daemon exited with status ' .. string(status) .. '.', 'WarningMsg')
  endif
  if !stop_requested
    daemon_start_attempted = false
  endif
enddef

def LifecycleMessage(msg: string, hl: string, interactive: bool)
  if interactive
    Notify(msg, hl)
  else
    Log(msg, hl)
  endif
enddef

def StopOwnedDaemon(): bool
  if !DaemonJobRunning()
    return true
  endif
  var stopped_job = daemon_job
  add(daemon_jobs_being_stopped, stopped_job)
  if !job_stop(daemon_job, 'term')
    remove(daemon_jobs_being_stopped, index(daemon_jobs_being_stopped, stopped_job))
    return false
  endif
  # The daemon may spend up to two seconds draining an in-flight clipboard write.
  for _ in range(100)
    if !DaemonJobRunning()
      return true
    endif
    sleep 25m
  endfor
  return !DaemonJobRunning()
enddef

export def StartDaemon(interactive: bool = true, wait_for_ready: bool = true): void
  if !get(g:, 'simpleclipboard_daemon_enabled', 1)
    LifecycleMessage('Daemon backend is disabled.', 'Comment', interactive)
    return
  endif
  if !has('libcall')
    LifecycleMessage('Daemon start skipped because Vim lacks +libcall.', 'WarningMsg', interactive)
    return
  endif
  DetectEnvironment()
  if daemon_route_error !=# ''
    LifecycleMessage(daemon_route_error .. '; daemon start refused.', 'ErrorMsg', interactive)
    return
  endif
  if IsSSH() || InContainer() || IsWSL() || custom_address
    LifecycleMessage('Local daemon start skipped for remote, container, WSL, or custom routing.',
      'Comment', interactive)
    return
  endif
  if wait_for_ready && PingDaemon(GetDaemonAddress())
    LifecycleMessage('Daemon is already reachable.', 'MoreMsg', interactive)
    return
  endif
  if DaemonJobRunning()
    LifecycleMessage('Restarting an owned daemon that failed its health check.',
      'WarningMsg', interactive)
    if !StopOwnedDaemon()
      LifecycleMessage('Owned daemon did not stop; refusing to start a duplicate.',
        'ErrorMsg', interactive)
      return
    endif
  endif

  daemon_start_attempted = true
  FindDaemonExe()
  if daemon_exe_path ==# ''
    LifecycleMessage('Daemon executable not found.', 'ErrorMsg', interactive)
    return
  endif

  var port = get(g:, 'simpleclipboard_port', 12343)
  var bind_host = get(g:, 'simpleclipboard_bind_addr', '127.0.0.1')
  var token = get(g:, 'simpleclipboard_token', '')
  if type(bind_host) != v:t_string
    LifecycleMessage('g:simpleclipboard_bind_addr must be a string.', 'ErrorMsg', interactive)
    return
  endif
  var token_error = TokenValidationError(token)
  if token_error !=# ''
    LifecycleMessage(token_error .. '; daemon start refused.', 'ErrorMsg', interactive)
    return
  endif
  if !IsLoopbackHost(bind_host) && token ==# ''
    LifecycleMessage('Refusing non-loopback daemon without g:simpleclipboard_token.',
      'ErrorMsg', interactive)
    return
  endif

  var job_env = {
    SIMPLECLIPBOARD_ADDR: HostPort(bind_host, port),
    SIMPLECLIPBOARD_TOKEN: token,
  }
  try
    daemon_job = job_start([daemon_exe_path], {
      env: job_env,
      out_io: 'null',
      err_io: 'null',
      stoponexit: 'none',
      exit_cb: DaemonExitCallback,
    })
  catch
    LifecycleMessage('Could not start daemon: ' .. v:exception, 'ErrorMsg', interactive)
    return
  endtry

  if !wait_for_ready
    return
  endif

  for _ in range(8)
    if IsTcpOpen(GetDaemonAddress())
      if PingDaemon(GetDaemonAddress())
        LifecycleMessage('Daemon started and passed protocol health check.', 'ModeMsg', interactive)
        return
      endif
      break
    endif
    if job_status(daemon_job) !=# 'run'
      break
    endif
    sleep 40m
  endfor
  LifecycleMessage('Daemon did not become ready; fallbacks will be used.',
    'WarningMsg', interactive)
enddef

export def StopDaemon(interactive: bool = true): void
  if !DaemonJobRunning()
    LifecycleMessage('No daemon owned by this Vim instance is running.', 'Comment', interactive)
    return
  endif
  if StopOwnedDaemon()
    LifecycleMessage('Stopped daemon owned by this Vim instance.', 'ModeMsg', interactive)
  else
    LifecycleMessage('Failed to stop the owned daemon job.', 'WarningMsg', interactive)
  endif
enddef

# -----------------------------------------------------------------------------
# Copy backends
# -----------------------------------------------------------------------------

var running_copy_jobs: list<job> = []
var cached_copy_cmds: list<list<string>> = []
var cached_copy_names: list<string> = []
var cached_copy_cmd_checked = false
var last_method = 'none'
var last_error = ''
var last_copy_bytes = 0
var last_copy_at = ''
var last_outcome = 'none'
var copy_generation = 0
var pending_copy_text = ''
var pending_copy_waiting = false
var debounce_timer = -1
var pending_yank = ''

def MarkSuccess(method: string)
  last_method = method
  last_error = ''
  last_copy_at = strftime('%Y-%m-%d %H:%M:%S')
  last_outcome = method =~# '(queued)' ? 'queued' : 'success'
enddef

def MarkUncertain(method: string)
  last_method = method .. ' (uncertain)'
  last_error = 'daemon started the clipboard write, but completion is uncertain; fallback suppressed'
  last_copy_at = strftime('%Y-%m-%d %H:%M:%S')
  last_outcome = 'uncertain'
  Notify('Daemon clipboard outcome is uncertain; fallback was suppressed to avoid overwriting it.',
    'WarningMsg')
enddef

def MarkFailure(detail: string)
  last_error = detail
enddef

def StartPendingCopyIfIdle(): void
  if !pending_copy_waiting || !empty(running_copy_jobs)
    return
  endif
  var text = pending_copy_text
  pending_copy_text = ''
  pending_copy_waiting = false
  if !BeginCopy(text, false)
    Notify('Queued copy failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

def CopyJobExitCallback(job: job, status: number, text: string, osc52_fallback: bool,
    generation: number, candidate_index: number, command_name: string)
  var index = index(running_copy_jobs, job)
  if index >= 0
    remove(running_copy_jobs, index)
  endif
  if generation != copy_generation
    StartPendingCopyIfIdle()
    return
  endif
  if status == 0
    MarkSuccess(command_name)
    return
  endif
  MarkFailure($'{command_name} exited with status {status}')
  Log(last_error, 'WarningMsg')
  if StartCopyCandidate(candidate_index + 1, text, osc52_fallback, generation)
    return
  endif
  if osc52_fallback
    if CopyViaOsc52(text)
      return
    endif
  endif
  last_method = 'failed'
  last_outcome = 'failed'
  Notify('All copy backends failed. Run :SimpleCopyStatus.', 'WarningMsg')
  StartPendingCopyIfIdle()
enddef

def StartCopyJob(argv: list<string>, text: string, osc52_fallback: bool,
    generation: number, candidate_index: number, command_name: string): bool
  var callback_owns_fallback = false
  var copy_job: job
  try
    copy_job = job_start(argv, {
      in_io: 'pipe',
      out_io: 'null',
      err_io: 'null',
      exit_cb: (job, status) => CopyJobExitCallback(job, status, text,
        osc52_fallback, generation, candidate_index, command_name),
    })
    if job_status(copy_job) ==# 'fail'
      return false
    endif
    add(running_copy_jobs, copy_job)
    callback_owns_fallback = true
    ch_sendraw(copy_job, text)
    ch_close_in(copy_job)
    return true
  catch
    MarkFailure('Could not start copy command: ' .. v:exception)
    Log(last_error, 'WarningMsg')
    # Once a live job has an exit callback, let that callback advance the
    # candidate chain.  Advancing here as well could launch a duplicate.
    if callback_owns_fallback
      try
        ch_close_in(copy_job)
      catch
      endtry
    endif
    return callback_owns_fallback
  endtry
enddef

def AddCopyCandidate(argv: list<string>, name: string): void
  if index(cached_copy_cmds, argv) >= 0
    return
  endif
  add(cached_copy_cmds, argv)
  add(cached_copy_names, name)
enddef

def ValidCommand(value: any): bool
  if type(value) != v:t_list || empty(value)
    return false
  endif
  for part in value
    if type(part) != v:t_string || part ==# ''
      return false
    endif
  endfor
  return true
enddef

def DetectCopyCmd(): void
  if cached_copy_cmd_checked
    return
  endif
  cached_copy_cmd_checked = true
  var configured = get(g:, 'simpleclipboard_copy_command', [])
  if ValidCommand(configured)
    AddCopyCandidate(copy(configured), 'custom command')
  endif
  if executable('pbcopy') == 1
    AddCopyCandidate(['pbcopy'], 'pbcopy')
  endif
  if getenv('WAYLAND_DISPLAY') !=# '' && executable('wl-copy') == 1
    AddCopyCandidate(['wl-copy'], 'wl-copy')
  endif
  if executable('clip.exe') == 1
    AddCopyCandidate(['clip.exe'], 'clip.exe')
  elseif executable('/mnt/c/Windows/System32/clip.exe') == 1
    AddCopyCandidate(['/mnt/c/Windows/System32/clip.exe'], 'clip.exe')
  endif
  if executable('xsel') == 1
    AddCopyCandidate(['xsel', '--clipboard', '--input'], 'xsel')
  endif
  if executable('xclip') == 1
    AddCopyCandidate(['xclip', '-selection', 'clipboard'], 'xclip')
  endif
enddef

def StartCopyCandidate(candidate_index: number, text: string, osc52_fallback: bool,
    generation: number): bool
  if generation != copy_generation
    return false
  endif
  DetectCopyCmd()
  var index = candidate_index
  while index < len(cached_copy_cmds)
    var name = cached_copy_names[index]
    if StartCopyJob(cached_copy_cmds[index], text, osc52_fallback,
        generation, index, name)
      MarkSuccess(name .. ' (queued)')
      return true
    endif
    index += 1
  endwhile
  return false
enddef

def CopyViaCmds(text: string, osc52_fallback: bool = false): bool
  return StartCopyCandidate(0, text, osc52_fallback, copy_generation)
enddef

def TruncateUtf8(text: string, byte_limit: number): string
  var low = 0
  var high = strchars(text)
  while low < high
    var middle = (low + high + 1) / 2
    if strlen(strcharpart(text, 0, middle)) <= byte_limit
      low = middle
    else
      high = middle - 1
    endif
  endwhile
  return strcharpart(text, 0, low)
enddef

def CopyViaOsc52(text: string): bool
  if get(g:, 'simpleclipboard_disable_osc52', 0)
    return false
  endif
  if executable('base64') != 1
    MarkFailure('base64 is unavailable for OSC52')
    return false
  endif

  var limit = get(g:, 'simpleclipboard_osc52_limit', 75000)
  if type(limit) != v:t_number || limit <= 0
    MarkFailure('simpleclipboard_osc52_limit must be a positive number')
    return false
  endif
  var payload = text
  if strlen(payload) > limit
    if !get(g:, 'simpleclipboard_osc52_truncate', 0)
      MarkFailure($'OSC52 refused {strlen(payload)} bytes (limit {limit})')
      Log(last_error, 'WarningMsg')
      return false
    endif
    payload = TruncateUtf8(payload, limit)
    Log($'OSC52 payload truncated to {strlen(payload)} bytes.', 'WarningMsg')
  endif

  var encoded = trim(system('base64 -w0', payload))
  if v:shell_error != 0
    encoded = substitute(system('base64', payload), '\n', '', 'g')
  endif
  if v:shell_error != 0
    MarkFailure('base64 encoding failed')
    return false
  endif

  var direct = "\x1b]52;c;" .. encoded .. "\x07"
  var sequence = exists('$TMUX')
    ? "\x1bPtmux;\x1b" .. direct .. "\x1b\\"
    : exists('$STY') ? "\x1bP" .. direct .. "\x1b\\" : direct
  try
    writefile([sequence], '/dev/tty', 'b')
    MarkSuccess('OSC52')
    return true
  catch
    MarkFailure('could not write OSC52 to /dev/tty: ' .. v:exception)
    Log(last_error, 'WarningMsg')
    return false
  endtry
enddef

# -----------------------------------------------------------------------------
# Public copy API
# -----------------------------------------------------------------------------

def CancelPendingYank(): void
  if debounce_timer >= 0
    timer_stop(debounce_timer)
  endif
  debounce_timer = -1
  pending_yank = ''
enddef

def BeginCopy(text: string, cancel_pending_yank: bool): bool
  if cancel_pending_yank
    CancelPendingYank()
  endif
  copy_generation += 1
  last_copy_bytes = strlen(text)
  last_method = 'pending'
  last_error = ''
  last_outcome = 'pending'

  # External copy programs own the clipboard write until they exit.  Queue
  # only the newest request so an older, slower program cannot finish after a
  # newer backend and overwrite it.
  if !empty(running_copy_jobs)
    pending_copy_text = text
    pending_copy_waiting = true
    MarkSuccess('latest copy (queued)')
    return true
  endif

  DetectEnvironment()

  if get(g:, 'simpleclipboard_daemon_enabled', 1) && daemon_address !=# ''
    var daemon_method = is_remote || custom_address ? 'daemon (routed)' : 'daemon'
    var daemon_result = DaemonRequest('set', text)
    if daemon_result == DAEMON_SUCCESS
      MarkSuccess(daemon_method)
      return true
    elseif daemon_result == DAEMON_UNCERTAIN
      MarkUncertain(daemon_method)
      return true
    endif
    MarkFailure('daemon request failed')
  endif

  if !is_remote
      if get(g:, 'simpleclipboard_daemon_enabled', 1)
        && has('libcall')
        && get(g:, 'simpleclipboard_daemon_autostart', 1)
        && !custom_address && !IsWSL() && !daemon_start_attempted
      # Unlike the proactive VimEnter start, this path retries the copy
      # immediately, so do not race the daemon's listener initialization.
      StartDaemon(false, true)
      if daemon_address !=# ''
        var retry_result = DaemonRequest('set', text)
        if retry_result == DAEMON_SUCCESS
          MarkSuccess('daemon')
          return true
        elseif retry_result == DAEMON_UNCERTAIN
          MarkUncertain('daemon')
          return true
        endif
      endif
    endif
    if CopyViaCmds(text, true) || CopyViaOsc52(text)
      return true
    endif
    last_method = 'failed'
    last_outcome = 'failed'
    return false
  endif

  if CopyViaCmds(text, true) || CopyViaOsc52(text)
    return true
  endif
  last_method = 'failed'
  last_outcome = 'failed'
  return false
enddef

export def CopyToSystemClipboard(text: string): bool
  return BeginCopy(text, true)
enddef

export def CompleteRegister(arglead: string, _cmdline: string,
    _cursorpos: number): list<string>
  var candidates = ['unnamed', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9',
    'a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm',
    'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z',
    'clipboard', 'primary', '-', '.', ':', '%', '#', '/', '=']
  return filter(candidates, (_, name) => stridx(name, arglead) == 0)
enddef

# Friendly aliases make the command readable while one-character Vim register
# names keep working exactly as written.  The unnamed register normalizes to
# `"`; other multi-character values are invalid.
def NormalizeRegisterName(name: string): string
  var value = trim(name)
  if value ==# '' || value ==# 'unnamed'
    return '"'
  elseif value ==# 'clipboard'
    return '+'
  elseif value ==# 'primary'
    return '*'
  elseif strchars(value) == 1
    return value
  endif
  return ''
enddef

def AutoCopyRegisterAllowed(name: string): bool
  var configured = get(g:, 'simpleclipboard_auto_copy_registers', [])
  if type(configured) != v:t_list
    Log('g:simpleclipboard_auto_copy_registers must be a list; automatic copy skipped.',
      'WarningMsg')
    return false
  endif
  if empty(configured)
    return true
  endif
  var actual = name ==# '' ? '"' : name
  for candidate in configured
    if type(candidate) == v:t_string && NormalizeRegisterName(candidate) ==# actual
      return true
    endif
  endfor
  return false
enddef

export def CopyRegisterToClipboard(name: string = ''): void
  var register = NormalizeRegisterName(name)
  if register ==# ''
    Notify('Register must be one character, unnamed, clipboard, or primary.', 'ErrorMsg')
    return
  endif
  var text = getreg(register)
  if text ==# ''
    Notify($'Register {name ==# "" ? "unnamed" : name} is empty.', 'Comment')
    return
  endif
  if CopyToSystemClipboard(text)
    if last_outcome !=# 'uncertain'
      Notify(last_outcome ==# 'queued'
        ? $'Clipboard copy for register {name ==# "" ? "unnamed" : name} queued.'
        : $'Copied register {name ==# "" ? "unnamed" : name}.')
    endif
  else
    Notify('Register copy failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

export def ClearClipboard(): void
  if CopyToSystemClipboard('')
    if last_outcome !=# 'uncertain'
      Notify(last_outcome ==# 'queued' ? 'Clipboard clear queued.' : 'Clipboard cleared.')
    endif
  else
    Notify('Clipboard clear failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

def CurrentFilePath(absolute: bool): string
  # A URI-like scratch, terminal or help buffer can have a name while still
  # not representing a filesystem path. Refuse it rather than copying a
  # plausible-looking value that downstream tools cannot open.
  var info = getbufinfo(bufnr('%'))
  var name = get(get(info, 0, {}), 'name', '')
  if &buftype !=# '' || name ==# ''
    Notify('Current buffer is not a named file.', 'ErrorMsg')
    return ''
  endif
  # getbufinfo().name is absolute, so a :cd after :edit cannot reinterpret a
  # relative buffer name against the wrong directory.
  var path = fnamemodify(name, ':p')
  if path ==# ''
    Notify('Current buffer is not a named file.', 'ErrorMsg')
    return ''
  endif
  # `:.` uses the effective window/tab/global cwd and keeps spaces/non-ASCII
  # verbatim; shell/fname escaping would corrupt the clipboard value.
  return absolute ? path : fnamemodify(path, ':.')
enddef

def CopyFileValue(text: string, description: string): void
  if text ==# ''
    return
  endif
  if CopyToSystemClipboard(text)
    if last_outcome !=# 'uncertain'
      Notify(last_outcome ==# 'queued'
        ? $'Clipboard copy for {description} queued.'
        : $'Copied {description}.')
    endif
  else
    Notify($'{description} copy failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

# Copy the current file path relative to the effective cwd. Bang uses an
# absolute path, useful when the receiver is outside Vim's project context.
export def CopyPathToClipboard(absolute: bool = false): void
  CopyFileValue(CurrentFilePath(absolute), absolute ? 'absolute file path' : 'file path')
enddef

# Copy an editor/tool-friendly 1-based path:line:column location. Column is a
# character index, not Vim's byte column, so multibyte text remains portable.
export def CopyLocationToClipboard(absolute: bool = false): void
  var path = CurrentFilePath(absolute)
  if path ==# ''
    return
  endif
  var character_col = strchars(strpart(getline('.'), 0, col('.') - 1)) + 1
  CopyFileValue($'{path}:{line(".")}:{character_col}',
    absolute ? 'absolute file location' : 'file location')
enddef

def FormatError(message: string): string
  Notify('Format template ' .. message .. '.', 'ErrorMsg')
  return message
enddef

# Expand only documented placeholders. Double braces are literals; every
# other brace must form one known placeholder. Parsing finishes before the
# clipboard pipeline is entered, so a malformed template can never copy a
# partially expanded value (or accidentally clear the clipboard).
def ExpandFileTemplate(template: string, values: dict<string>): list<string>
  if template ==# ''
    return [FormatError('must not be empty')]
  endif
  var output = ''
  var index = 0
  var length = strchars(template)
  while index < length
    var character = strcharpart(template, index, 1)
    if character ==# '{'
      if index + 1 < length && strcharpart(template, index + 1, 1) ==# '{'
        output ..= '{'
        index += 2
        continue
      endif
      var closing = index + 1
      while closing < length && strcharpart(template, closing, 1) !=# '}'
        if strcharpart(template, closing, 1) ==# '{'
          return [FormatError('contains a nested "{"')]
        endif
        closing += 1
      endwhile
      if closing >= length
        return [FormatError('has an unclosed "{"')]
      endif
      var name = strcharpart(template, index + 1, closing - index - 1)
      if !has_key(values, name)
        return [FormatError($'contains unknown placeholder {{{name}}}')]
      endif
      output ..= values[name]
      index = closing + 1
      continue
    elseif character ==# '}'
      if index + 1 < length && strcharpart(template, index + 1, 1) ==# '}'
        output ..= '}'
        index += 2
        continue
      endif
      return [FormatError('contains an unmatched "}"')]
    endif
    output ..= character
    index += 1
  endwhile
  return ['', output]
enddef

# Build shareable file references without evaluating template text. Bang makes
# {path}/{dir} absolute; {file}, {line}, and the 1-based Unicode {column} are
# otherwise identical.
export def CopyFormatToClipboard(template: string, absolute: bool = false): void
  if template ==# ''
    FormatError('must not be empty')
    return
  endif
  var path = CurrentFilePath(absolute)
  if path ==# ''
    return
  endif
  var character_col = strchars(strpart(getline('.'), 0, col('.') - 1)) + 1
  var values: dict<string> = {
    path: path,
    dir: fnamemodify(path, ':h'),
    file: fnamemodify(path, ':t'),
    line: string(line('.')),
    column: string(character_col),
  }
  var expanded = ExpandFileTemplate(template, values)
  if expanded[0] !=# ''
    return
  endif
  CopyFileValue(expanded[1], 'formatted file reference')
enddef

# -----------------------------------------------------------------------------
# Automatic copy policy
# -----------------------------------------------------------------------------

var auto_copy_pause_timer = -1
var auto_copy_before_pause: any = 1

# The longest pause that is still a pause rather than a disable; anything
# longer is almost certainly a typo (":SimpleCopyPause 3600000") that would
# otherwise silently switch automatic copy off for the rest of the session.
const MAX_PAUSE_SECONDS = 86400

# Re-read on every yank instead of latched when the plugin loads.  A user who
# runs `:let g:simpleclipboard_auto_copy = 0` — or `:SimpleCopyPause 30` — one
# keystroke before yanking a credential expects that yank to stay inside Vim,
# and a single dictionary lookup costs far less than the debounce timer it
# guards.  A non-numeric value keeps the default rather than throwing out of an
# autocommand; :SimpleCopyStatus reports the coercion.
def AutoCopyEnabled(): bool
  var configured = get(g:, 'simpleclipboard_auto_copy', 1)
  if type(configured) == v:t_bool
    return configured == v:true
  endif
  return type(configured) == v:t_number ? configured != 0 : true
enddef

def CancelAutoCopyPause(): void
  if auto_copy_pause_timer >= 0
    timer_stop(auto_copy_pause_timer)
  endif
  auto_copy_pause_timer = -1
enddef

def ResumeAutoCopy(timer_id: number): void
  # A pause that was superseded by an explicit toggle or by a newer pause must
  # not resurrect automatic copying behind the user's back.
  if timer_id != auto_copy_pause_timer
    return
  endif
  auto_copy_pause_timer = -1
  g:simpleclipboard_auto_copy = auto_copy_before_pause
  Notify(AutoCopyEnabled()
    ? 'Automatic clipboard copy resumed.'
    : 'Automatic clipboard copy pause ended; it was already disabled.')
enddef

export def ToggleAutoCopy(): void
  # Toggling is an explicit decision and therefore outranks a running pause.
  CancelAutoCopyPause()
  var enabled = !AutoCopyEnabled()
  g:simpleclipboard_auto_copy = enabled ? 1 : 0
  Notify(enabled
    ? 'Automatic clipboard copy enabled.'
    : 'Automatic clipboard copy disabled.')
enddef

export def PauseAutoCopy(argument: string): void
  var value = trim(argument)
  if value !~# '^\d\+$'
    Notify('Usage: :SimpleCopyPause {seconds}', 'ErrorMsg')
    return
  endif
  var seconds = str2nr(value, 10)
  if seconds <= 0 || seconds > MAX_PAUSE_SECONDS
    Notify($'Pause seconds must be between 1 and {MAX_PAUSE_SECONDS}.', 'ErrorMsg')
    return
  endif
  # Without timers nothing would ever restore the flag, so refuse the pause
  # instead of disabling automatic copy for the rest of the session.
  if !exists('*timer_start')
    Notify('Pausing needs +timers; use :SimpleCopyToggle instead.', 'ErrorMsg')
    return
  endif
  # Pausing twice keeps the value from before the first pause, so resuming
  # cannot re-enable automatic copy for someone who had switched it off.
  if auto_copy_pause_timer < 0
    auto_copy_before_pause = get(g:, 'simpleclipboard_auto_copy', 1)
  endif
  CancelAutoCopyPause()
  g:simpleclipboard_auto_copy = 0
  auto_copy_pause_timer = timer_start(seconds * 1000, ResumeAutoCopy)
  CancelPendingYank()
  Notify($'Automatic clipboard copy paused for {seconds}s.')
enddef

export def CopyYankedToClipboard(_timer_id: any = 0)
  var text = getreg('"')
  if text ==# ''
    return
  endif
  if !CopyToSystemClipboard(text)
    Notify('All copy methods failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

def TextFromYankEvent(event: any): string
  if type(event) != v:t_dict || get(event, 'operator', '') !=# 'y'
    return ''
  endif
  if get(event, 'regname', '') ==# '_'
    return ''
  endif
  if !AutoCopyRegisterAllowed(get(event, 'regname', ''))
    return ''
  endif
  var contents = get(event, 'regcontents', [])
  if type(contents) != v:t_list
    return ''
  endif
  var text = join(contents, "\n")
  if get(event, 'regtype', '') ==# 'V'
    text ..= "\n"
  endif
  return text
enddef

def FlushPendingYank(_timer_id: number)
  debounce_timer = -1
  var text = pending_yank
  pending_yank = ''
  # The flag is re-read here as well: a yank that is still inside the debounce
  # window when automatic copy is switched off must not reach the clipboard.
  if !AutoCopyEnabled()
    return
  endif
  if text !=# '' && !BeginCopy(text, false)
    Notify('Automatic copy failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

export def CopyYankedToClipboardEvent(event: any = v:null)
  if !AutoCopyEnabled()
    # Dropping the pending yank too, so that disabling automatic copy stops
    # everything that has not left Vim yet rather than only future yanks.
    CancelPendingYank()
    return
  endif
  # A newer yank supersedes a pending older one even when the newer register is
  # excluded or its payload is over the automatic-copy limit.
  if type(event) == v:t_dict && get(event, 'operator', '') ==# 'y'
    CancelPendingYank()
  endif
  var text = TextFromYankEvent(event)
  if text ==# ''
    return
  endif
  var max_bytes = get(g:, 'simpleclipboard_auto_copy_max_bytes', 0)
  if type(max_bytes) != v:t_number
    Log('g:simpleclipboard_auto_copy_max_bytes must be a number; automatic copy skipped.',
      'WarningMsg')
    return
  endif
  if max_bytes > 0 && strlen(text) > max_bytes
    Log($'Automatic copy skipped: {strlen(text)} bytes exceeds limit {max_bytes}.',
      'WarningMsg')
    return
  endif
  var delay = get(g:, 'simpleclipboard_debounce_ms', 50)
  if exists('*timer_start') && type(delay) == v:t_number && delay > 0
    pending_yank = text
    debounce_timer = timer_start(delay, FlushPendingYank)
  else
    pending_yank = text
    FlushPendingYank(0)
  endif
enddef

export def GetVisualSelection(): string
  if getpos("'<")[1] == 0 || getpos("'>")[1] == 0
    return ''
  endif
  var unnamed = getreginfo('"')
  var yank_zero = getreginfo('0')
  var scratch = getreginfo('z')
  var view = winsaveview()
  try
    execute 'silent noautocmd normal! gv"zy'
    return getreg('z')
  finally
    setreg('z', scratch)
    setreg('0', yank_zero)
    setreg('"', unnamed)
    winrestview(view)
  endtry
  return ''
enddef

export def CopyVisualSelection(): void
  var text = GetVisualSelection()
  if text ==# ''
    return
  endif
  if CopyToSystemClipboard(text)
    if last_outcome !=# 'uncertain'
      Notify(last_outcome ==# 'queued' ? 'Visual clipboard copy queued.' : 'Copied visual selection.')
    endif
  else
    Notify('Visual copy failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

export def CopyRangeToClipboard(first_line: number, last_line: number)
  var text = join(getline(first_line, last_line), "\n")
  if CopyToSystemClipboard(text)
    if last_outcome !=# 'uncertain'
      Notify(last_outcome ==# 'queued'
        ? $'Clipboard copy for lines {first_line}-{last_line} queued.'
        : $'Copied lines {first_line}-{last_line}.')
    endif
  else
    Notify('Range copy failed. Run :SimpleCopyStatus.', 'WarningMsg')
  endif
enddef

# -----------------------------------------------------------------------------
# Diagnostics and cache refresh
# -----------------------------------------------------------------------------

export def Status(): void
  DetectEnvironment()
  TryLoadLib()
  FindDaemonExe()
  DetectCopyCmd()
  var daemon_health = 'disabled'
  if get(g:, 'simpleclipboard_daemon_enabled', 1)
    daemon_health = !has('libcall') ? 'unavailable (+libcall missing)'
      : daemon_route_error !=# '' ? 'blocked (configuration)'
      : daemon_address ==# '' ? 'no route'
      : PingDaemon(daemon_address) ? 'reachable' : 'unreachable'
  endif
  var token_state = get(g:, 'simpleclipboard_token', '') ==# '' ? 'off' : 'configured'
  var command_summary = empty(cached_copy_names) ? 'none' : join(cached_copy_names, ' -> ')
  var osc52_state = get(g:, 'simpleclipboard_disable_osc52', 0) ? 'disabled'
    : executable('base64') == 1 ? 'enabled' : 'unavailable (base64 missing)'
  var register_policy = 'invalid (expected list)'
  var configured_registers = get(g:, 'simpleclipboard_auto_copy_registers', [])
  if type(configured_registers) == v:t_list
    var names: list<string> = []
    for value in configured_registers
      add(names, type(value) == v:t_string ? value : '<invalid>')
    endfor
    register_policy = empty(names) ? 'all non-black-hole registers' : join(names, ',')
  endif
  var auto_limit = get(g:, 'simpleclipboard_auto_copy_max_bytes', 0)
  var limit_policy = type(auto_limit) == v:t_number
    ? (auto_limit <= 0 ? 'unlimited' : string(auto_limit) .. ' bytes')
    : 'invalid (expected number)'
  var lines = [
    $'SimpleClipboard {VERSION}',
    $'environment: {environment_kind} (ssh={string(IsSSH())}, container={string(InContainer())})',
    $'daemon: {daemon_health}; address={daemon_address ==# "" ? "none" : daemon_address}; token={token_state}',
    $'daemon route error: {daemon_route_error ==# "" ? "none" : daemon_route_error}',
    $'client library: {client_lib ==# "" ? "not found" : client_lib}',
    $'daemon executable: {daemon_exe_path ==# "" ? "not found" : daemon_exe_path}',
    $'external commands: {command_summary}',
    $'OSC52: {osc52_state}',
    $'automatic copy: registers={register_policy}; max={limit_policy}',
    $'last copy: method={last_method}, outcome={last_outcome}, bytes={last_copy_bytes}, at={last_copy_at ==# "" ? "never" : last_copy_at}',
    $'last error: {last_error ==# "" ? "none" : last_error}',
  ]
  for line in lines
    Notify(line)
  endfor
enddef

export def Refresh(): void
  var restart_owned = DaemonJobRunning()
  if restart_owned && !StopOwnedDaemon()
    Notify('Refresh aborted because the owned daemon did not stop.', 'ErrorMsg')
    return
  endif
  copy_generation += 1
  env_detected = false
  is_remote = false
  tunnel_available = false
  daemon_address = ''
  environment_kind = 'unknown'
  custom_address = false
  daemon_route_error = ''
  cached_is_ssh = -1
  cached_in_container = -1
  cached_is_wsl = -1
  cached_copy_cmds = []
  cached_copy_names = []
  cached_copy_cmd_checked = false
  client_lib = ''
  client_abi = 0
  daemon_exe_path = ''
  daemon_start_attempted = false
  DetectEnvironment()
  if restart_owned
    if get(g:, 'simpleclipboard_daemon_enabled', 1) && has('libcall')
        && !is_remote && !IsWSL() && !custom_address
      StartDaemon(true)
    else
      Notify('Owned daemon stopped and was not restarted for the current environment.', 'Comment')
    endif
  endif
  Notify('Environment and backend caches refreshed.')
enddef
