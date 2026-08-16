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
# Options
# -----------------------------------------------------------------------------

# Every documented option, the type its consumers may assume, and the value
# used when the configured one cannot be honoured.
#
# Vim9 checks argument types at run time, so an option read straight out of g:
# and handed to a typed function is a stack trace waiting for a vimrc typo: a
# quoted port (`let g:simpleclipboard_port = '12343'`, a common habit) used to
# throw E1013 out of DetectEnvironment(), and that function is on the path of
# every yank, every explicit copy and :SimpleCopyStatus itself — so the one
# command that could explain the failure failed the same way.  Nothing here
# throws: ValidateOptions() reports each problem once, the accessors below
# coerce at the point of use, and a bad option costs a warning instead of the
# whole clipboard pipeline.
#
# `note` replaces the default "using the default X" remedy for the options whose
# consumers deliberately fail closed rather than fall back: guessing "copy
# everything" for a malformed allow-list or byte cap would push exactly the
# payload the user was trying to exclude, and quietly restoring the 75000-byte
# OSC52 default for an unusable limit would write to the terminal on behalf of
# someone whose configuration said, however clumsily, "do not".
const OPTION_SPECS: list<dict<any>> = [
  {name: 'simpleclipboard_daemon_enabled', kind: 'bool', default: 1},
  {name: 'simpleclipboard_daemon_autostart', kind: 'bool', default: 1},
  {name: 'simpleclipboard_daemon_autostop', kind: 'bool', default: 0},
  {name: 'simpleclipboard_auto_copy', kind: 'bool', default: 1},
  {name: 'simpleclipboard_auto_copy_registers', kind: 'list', default: [],
    elements: 'string', note: 'automatic copy is skipped until it is fixed'},
  # `nonpositive` names what a value of zero or less really does, for an option
  # whose consumer switches off rather than clamps: the cap is enforced by
  # `bytes > 0`, so reporting "using -5" alone would put a cap on screen that
  # :SimpleCopyStatus prints as max=unlimited two lines later.
  {name: 'simpleclipboard_auto_copy_max_bytes', kind: 'number', default: 0,
    note: 'automatic copy is skipped until it is fixed',
    nonpositive: 'applies no cap'},
  {name: 'simpleclipboard_libpath', kind: 'string', default: ''},
  {name: 'simpleclipboard_daemon_path', kind: 'string', default: ''},
  {name: 'simpleclipboard_no_default_mappings', kind: 'bool', default: 0},
  {name: 'simpleclipboard_debug', kind: 'bool', default: 0},
  {name: 'simpleclipboard_debug_to_file', kind: 'bool', default: 0},
  {name: 'simpleclipboard_debug_file', kind: 'string', default: ''},
  {name: 'simpleclipboard_disable_osc52', kind: 'bool', default: 0},
  {name: 'simpleclipboard_osc52_limit', kind: 'number', default: 75000, positive: true,
    note: 'OSC52 is skipped until it is fixed'},
  {name: 'simpleclipboard_osc52_truncate', kind: 'bool', default: 0},
  {name: 'simpleclipboard_osc52_terminator', kind: 'string', default: 'bel',
    allowed: ['bel', 'st']},
  {name: 'simpleclipboard_osc52_selection', kind: 'string', default: 'c',
    allowed: ['c', 'p']},
  {name: 'simpleclipboard_osc52_tty', kind: 'string', default: ''},
  {name: 'simpleclipboard_bind_addr', kind: 'string', default: '127.0.0.1'},
  {name: 'simpleclipboard_port', kind: 'number', default: 12343, positive: true},
  {name: 'simpleclipboard_tunnel_port', kind: 'number', default: 12345, positive: true},
  # The token is the one option whose value must never be echoed back.
  {name: 'simpleclipboard_token', kind: 'string', default: '', secret: true},
  {name: 'simpleclipboard_address', kind: 'string', default: ''},
  {name: 'simpleclipboard_copy_command', kind: 'list', default: [],
    elements: 'argv', note: 'the configured command is ignored'},
  {name: 'simpleclipboard_paste_command', kind: 'list', default: [],
    elements: 'argv', note: 'the configured command is ignored'},
  {name: 'simpleclipboard_paste_timeout_ms', kind: 'number', default: 10000, positive: true},
  {name: 'simpleclipboard_debounce_ms', kind: 'number', default: 50},
  {name: 'simpleclipboard_container_host', kind: 'string', default: ''},
]

var option_specs_by_name: dict<dict<any>> = {}

def OptionSpec(name: string): dict<any>
  if empty(option_specs_by_name)
    for spec in OPTION_SPECS
      option_specs_by_name[spec.name] = spec
    endfor
  endif
  return option_specs_by_name[name]
enddef

const NUMERIC_STRING = '^\s*-\?\d\+\s*$'

def Coercible(raw: any): bool
  # A quoted number is a vimrc habit, not a different intent.
  return type(raw) == v:t_number || type(raw) == v:t_bool
    || (type(raw) == v:t_string && raw =~# NUMERIC_STRING)
enddef

# The number a coercible value denotes, before `positive` decides whether the
# consumer will accept it.  EffectiveNumber() clamps a rejected value to the
# default; the reporting below needs the unclamped one, because that is what
# tells "using 12" apart from a limit that blocks the backend outright.
def CoercedNumber(raw: any): number
  if type(raw) == v:t_number
    return raw
  endif
  if type(raw) == v:t_bool
    return raw == v:true ? 1 : 0
  endif
  return str2nr(trim(raw), 10)
enddef

def EffectiveNumber(spec: dict<any>, raw: any): number
  var fallback: number = spec.default
  if !Coercible(raw)
    return fallback
  endif
  var value = CoercedNumber(raw)
  return get(spec, 'positive', false) && value <= 0 ? fallback : value
enddef

export def NumberOption(name: string): number
  var spec = OptionSpec(name)
  return EffectiveNumber(spec, get(g:, name, spec.default))
enddef

export def BoolOption(name: string): bool
  return NumberOption(name) != 0
enddef

export def StringOption(name: string): string
  var spec = OptionSpec(name)
  var raw = get(g:, name, spec.default)
  return type(raw) == v:t_string ? raw : spec.default
enddef

# Enumerated options are matched on the trimmed, lower-cased value: 'BEL' and
# ' bel ' are the same intent, and rejecting them would only produce a warning
# nobody learns anything from.
def NormalizeEnum(value: string): string
  return tolower(trim(value))
enddef

export def EnumOption(name: string): string
  var spec = OptionSpec(name)
  var raw = get(g:, name, spec.default)
  var value = type(raw) == v:t_string ? NormalizeEnum(raw) : ''
  return index(spec.allowed, value) >= 0 ? value : spec.default
enddef

def TypeName(value: any): string
  var names = {
    [v:t_number]: 'a number', [v:t_string]: 'a string', [v:t_func]: 'a funcref',
    [v:t_list]: 'a list', [v:t_dict]: 'a dictionary', [v:t_float]: 'a float',
    [v:t_bool]: 'a boolean', [v:t_none]: 'null', [v:t_job]: 'a job',
    [v:t_channel]: 'a channel', [v:t_blob]: 'a blob',
  }
  return get(names, type(value), 'an unsupported value')
enddef

def DescribeValue(value: any): string
  var text = type(value) == v:t_string ? $'"{value}"' : string(value)
  return strchars(text) > 48 ? strcharpart(text, 0, 45) .. '...' : text
enddef

def Remedy(spec: dict<any>): string
  return get(spec, 'note', $'using the default {DescribeValue(spec.default)}')
enddef

# The options that decide what may leave Vim carry a `note` and fail closed:
# their consumers skip automatic copy instead of falling back to a more
# permissive default.
def FailsClosed(spec: dict<any>): bool
  return has_key(spec, 'note')
enddef

# The byte cap, coerced the way ValidateOptions() reports it: a quoted number
# is honoured, anything else is unreadable and `valid` is false so automatic
# copy stops rather than guessing "no cap".
def AutoCopyLimit(): dict<any>
  var raw = get(g:, 'simpleclipboard_auto_copy_max_bytes', 0)
  if type(raw) == v:t_string && raw =~# NUMERIC_STRING
    return {valid: true, bytes: str2nr(trim(raw), 10)}
  endif
  if type(raw) != v:t_number
    return {valid: false, bytes: 0}
  endif
  return {valid: true, bytes: raw}
enddef

# The OSC52 byte cap, coerced the same way and for the same reason.  This one
# fails closed rather than reverting to the 75000-byte default: writing an
# escape sequence to the terminal is the one backend that cannot be taken back
# once emitted - it has already crossed into the terminal emulator, and under
# tmux or screen into whatever is logging the outer session - so `0`, a
# negative number or a value nobody can read blocks OSC52 instead of quietly
# granting it a limit its owner never chose.
def Osc52Limit(): dict<any>
  var raw = get(g:, 'simpleclipboard_osc52_limit', 75000)
  var bytes = -1
  if type(raw) == v:t_number
    bytes = raw
  elseif type(raw) == v:t_string && raw =~# NUMERIC_STRING
    bytes = str2nr(trim(raw), 10)
  endif
  return bytes > 0 ? {valid: true, bytes: bytes} : {valid: false, bytes: 0}
enddef

def OptionProblem(spec: dict<any>, raw: any): string
  var name = 'g:' .. spec.name
  # A wrong token still must not be printed; its length is enough to identify.
  var seen = get(spec, 'secret', false)
    ? $'{TypeName(raw)} of {strlen(string(raw))} bytes'
    : $'{TypeName(raw)} ({DescribeValue(raw)})'
  if spec.kind ==# 'string'
    if type(raw) != v:t_string
      return $'{name} must be a string, but is {seen}; {Remedy(spec)}'
    endif
    # An option with a closed set of values is worth naming the whole set for:
    # the usual reason a value is wrong here is that the user guessed a synonym.
    if has_key(spec, 'allowed') && index(spec.allowed, NormalizeEnum(raw)) < 0
      var choices = join(map(copy(spec.allowed), (_, v) => $'"{v}"'), ', ')
      return $'{name} must be one of {choices}, but is {seen}; {Remedy(spec)}'
    endif
    return ''
  endif
  if spec.kind ==# 'list'
    if type(raw) != v:t_list
      return $'{name} must be a list, but is {seen}; {Remedy(spec)}'
    endif
    # A list of the wrong things is as unusable as a non-list: both consumers
    # drop the offending entry without a word, which is how a mistyped copy
    # command becomes "my clipboard silently stopped working".
    var elements = get(spec, 'elements', '')
    if elements ==# ''
      return ''
    endif
    for part in raw
      if type(part) != v:t_string || (elements ==# 'argv' && part ==# '')
        var wanted_element = elements ==# 'argv' ? 'non-empty strings' : 'strings'
        return $'{name} must be a list of {wanted_element}, but contains '
          .. $'{TypeName(part)} ({DescribeValue(part)}); {Remedy(spec)}'
      endif
    endfor
    return ''
  endif
  var positive = get(spec, 'positive', false)
  var wanted = positive ? 'a positive number' : 'a number'
  if type(raw) == v:t_number || (spec.kind ==# 'bool' && type(raw) == v:t_bool)
    if !positive || (type(raw) == v:t_number && raw > 0)
      return ''
    endif
    return $'{name} must be {wanted}, but is {seen}; {Remedy(spec)}'
  endif
  # Report the value the consumer will really use.  EffectiveNumber() coerces a
  # boolean to 0/1, so claiming the default is in force would be false for
  # every option read through NumberOption(); the fail-closed options honour a
  # quoted number, and nothing else, exactly as their consumers do.
  var readable = type(raw) == v:t_string
    ? raw =~# NUMERIC_STRING
    : type(raw) == v:t_bool && !FailsClosed(spec)
  # Readable is not the same as accepted.  A quoted "0" or "-5" for a positive
  # fail-closed option coerces cleanly and is then refused: Osc52Limit() blocks
  # it exactly as it blocks the unquoted number, so falling through to
  # EffectiveNumber() here would name the 75000-byte default for a limit that
  # is not in force - on the one backend whose output cannot be taken back.
  if !readable || (positive && FailsClosed(spec) && CoercedNumber(raw) <= 0)
    return $'{name} must be {wanted}, but is {seen}; {Remedy(spec)}'
  endif
  var effective = EffectiveNumber(spec, raw)
  var remedy = effective == spec.default
    ? $'using the default {effective}' : $'using {effective}'
  # The value in force is not always a value that does anything.  A byte cap of
  # zero or less is not a cap: AutoCopyLimit() hands the coerced number to an
  # enforcement that reads `bytes > 0`, and :SimpleCopyStatus prints it as
  # max=unlimited - so naming "-5" on its own contradicts the status line on
  # the same screen and reads as a cap no yank will ever meet.  Say what the
  # number does, alongside the number itself.
  if has_key(spec, 'nonpositive') && effective <= 0
    remedy ..= $', which {spec.nonpositive}'
  endif
  return $'{name} must be {wanted}, but is {seen}; {remedy}'
enddef

# One actionable line per misconfigured option, in declaration order, naming
# the expected type, the value actually seen, and what happens instead.
export def ValidateOptions(): list<string>
  var problems: list<string> = []
  for spec in OPTION_SPECS
    if !has_key(g:, spec.name)
      continue
    endif
    var problem = OptionProblem(spec, g:[spec.name])
    if problem !=# ''
      add(problems, problem)
    endif
  endfor
  return problems
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
  return StringOption('simpleclipboard_debug_file') ==# ''
enddef

def DebugFile(): string
  return UsesDefaultDebugFile()
    ? StateDir() .. '/simpleclipboard.log'
    : expand(StringOption('simpleclipboard_debug_file'))
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
  if !BoolOption('simpleclipboard_debug')
    return
  endif
  if BoolOption('simpleclipboard_debug_to_file')
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

# Every notification, every backend failure and every route decision is
# retained so :SimpleCopyLog can explain a copy that silently took the wrong
# route.  The ring is deliberately independent of g:simpleclipboard_debug:
# nobody has debug logging on before the copy that goes wrong.
var log_ring: list<string> = []

def Record(msg: string)
  log_ring->add(strftime('%H:%M:%S') .. ' ' .. msg)
  if len(log_ring) > 500
    log_ring = log_ring[-300 : ]
  endif
enddef

# A route decision or a failed backend: recorded unconditionally, echoed only
# when debug logging asked for it.
def Trace(msg: string, hl: string = 'None')
  Record(msg)
  Log(msg, hl)
enddef

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
  Record(msg)
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
  var override = StringOption('simpleclipboard_libpath')
  if override !=# '' && filereadable(override)
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
  var override = StringOption('simpleclipboard_daemon_path')
  if override !=# '' && executable(override) == 1
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
    Trace($'TCP probe failed for {address}: {v:exception}', 'WarningMsg')
  endtry
  return false
enddef

def ResolveContainerHostIP(): string
  var configured = StringOption('simpleclipboard_container_host')
  if configured !=# ''
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

  if !BoolOption('simpleclipboard_daemon_enabled') || !has('libcall')
    daemon_address = ''
    Trace(environment_kind .. ': daemon routing disabled; skipping network probes.', 'Comment')
    return
  endif

  var override = StringOption('simpleclipboard_address')
  var token = get(g:, 'simpleclipboard_token', '')
  var token_error = TokenValidationError(token)
  if token_error !=# ''
    daemon_address = ''
    daemon_route_error = token_error
    Trace(token_error .. '; daemon routing blocked.', 'ErrorMsg')
    return
  endif
  if override !=# ''
    custom_address = true
    environment_kind = 'custom'
    if type(token) != v:t_string || token ==# ''
      daemon_address = ''
      daemon_route_error = 'custom daemon routing requires g:simpleclipboard_token'
      Trace(daemon_route_error .. '; refusing plaintext daemon traffic.', 'ErrorMsg')
      return
    endif
    daemon_address = override
    tunnel_available = true
    Trace('Using g:simpleclipboard_address: ' .. daemon_address, 'MoreMsg')
    return
  endif

  if is_remote && (type(token) != v:t_string || token ==# '')
    daemon_address = ''
    daemon_route_error = 'remote daemon routing requires g:simpleclipboard_token'
    Trace(daemon_route_error .. '; skipping route probes and plaintext daemon traffic.', 'ErrorMsg')
    return
  endif

  var daemon_port = NumberOption('simpleclipboard_port')
  var tunnel_port = NumberOption('simpleclipboard_tunnel_port')
  if !is_remote
    if IsWSL()
      environment_kind = 'wsl'
      daemon_address = ''
      return
    endif
    environment_kind = 'local'
    var configured_host = StringOption('simpleclipboard_bind_addr')
    var client_host = configured_host ==# '0.0.0.0' ? '127.0.0.1'
      : configured_host ==# '::' || configured_host ==# '[::]' ? '::1' : configured_host
    if !IsLoopbackHost(client_host) && (type(token) != v:t_string || token ==# '')
      daemon_address = ''
      daemon_route_error = 'non-loopback daemon routing requires g:simpleclipboard_token'
      Trace(daemon_route_error .. '; refusing plaintext daemon traffic.', 'ErrorMsg')
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
  Trace(environment_kind .. ': no daemon route detected; fallbacks remain available.', 'Comment')
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
    Trace(token_error .. '.', 'ErrorMsg')
    return DAEMON_FAILURE
  endif
  if target ==# '' || stridx(target, FIELD_SEPARATOR) >= 0
    return DAEMON_FAILURE
  endif
  if token ==# '' && (is_remote || custom_address || !IsLoopbackAddress(target))
    Trace('Refusing plaintext daemon traffic outside the default local loopback route.', 'ErrorMsg')
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
      Trace('Delimiter-safe client ABI unavailable; trying v0.1 compatibility ABI.', 'WarningMsg')
    endtry
  endif

  if stridx(text, FIELD_SEPARATOR) >= 0
    Trace('Legacy client ABI cannot safely carry U+0001 text.', 'ErrorMsg')
    return DAEMON_FAILURE
  endif
  try
    var legacy = target .. FIELD_SEPARATOR .. action .. FIELD_SEPARATOR .. text
      .. FIELD_SEPARATOR .. token
    return NormalizeDaemonResult(libcallnr(client_lib, 'rust_set_clipboard_tcp', legacy))
  catch
    Trace('Client library call failed: ' .. v:exception, 'ErrorMsg')
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
    Trace('Daemon exited with status ' .. string(status) .. '.', 'WarningMsg')
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
  if !BoolOption('simpleclipboard_daemon_enabled')
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
  # Probing for a listener is not the same thing as waiting for readiness, and
  # the VimEnter autostart passes wait_for_ready false, so it used to skip both:
  # every Vim after the first forked a daemon that could only lose the bind,
  # exit 1 on EADDRINUSE, and — with err_io null — say nothing about why.  One
  # loopback connect attempt is cheap, and refusal is immediate when the port
  # really is free.
  if !DaemonJobRunning() && IsTcpOpen(GetDaemonAddress())
    LifecycleMessage('Another process already owns the daemon address; not starting a second one.',
      'MoreMsg', interactive)
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

  var port = NumberOption('simpleclipboard_port')
  var bind_host = StringOption('simpleclipboard_bind_addr')
  var token = get(g:, 'simpleclipboard_token', '')
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
  Record($'Copy route: {method} ({last_copy_bytes} bytes).')
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
  Record(detail)
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

const OSC52_TERMINATORS = {bel: "\x07", st: "\x1b\\"}

# GNU screen truncates a DCS string past roughly this many bytes, and it does so
# without a word: the clipboard ends up holding a prefix of what was copied,
# which is the exact failure g:simpleclipboard_osc52_truncate exists to refuse.
# One OSC sequence may be split across several DCS envelopes because screen
# strips each envelope and forwards the bytes it contains unchanged, so the
# outer terminal still sees one continuous OSC 52.
const SCREEN_DCS_CHUNK_BYTES = 768

def InScreen(): bool
  # $STY is set by screen itself, but a user who runs screen through a wrapper,
  # or reattaches from a different environment, can end up with only $TERM to
  # go on - and getting this wrong means a silently truncated clipboard.
  return $STY !=# '' || &term =~# '^screen' || $TERM =~# '^screen'
enddef

def ChunkBytes(text: string, size: number): list<string>
  var chunks: list<string> = []
  var offset = 0
  while offset < strlen(text)
    add(chunks, strpart(text, offset, size))
    offset += size
  endwhile
  return chunks
enddef

# The terminal-visible OSC 52 write, wrapped for whatever multiplexer is in the
# way.  base64 is ASCII, so byte-oriented splitting cannot cut a character.
export def Osc52Sequence(encoded: string): string
  var selection = EnumOption('simpleclipboard_osc52_selection')
  var terminator = OSC52_TERMINATORS[EnumOption('simpleclipboard_osc52_terminator')]
  var direct = $"\x1b]52;{selection};{encoded}{terminator}"
  if $TMUX !=# ''
    # tmux passthrough needs each ESC in the payload doubled; OSC 52 contains
    # exactly one, at the start, so escaping the prefix is sufficient.
    return "\x1bPtmux;\x1b" .. direct .. "\x1b\\"
  endif
  if InScreen()
    return join(map(ChunkBytes(direct, SCREEN_DCS_CHUNK_BYTES),
      (_, chunk) => "\x1bP" .. chunk .. "\x1b\\"), '')
  endif
  return direct
enddef

# Where the escape sequence goes.  echoraw() writes to the terminal Vim is
# actually driving, which /dev/tty is not when Vim's controlling terminal is a
# different one - under `sudo -u`, inside a `:terminal`, or in some tmux popup
# configurations.  g:simpleclipboard_osc52_tty overrides both, for the case
# where the user knows which device is the display and Vim cannot.
def EmitOsc52(sequence: string): bool
  var device = StringOption('simpleclipboard_osc52_tty')
  if device !=# ''
    return WriteOsc52ToDevice(sequence, expand(device))
  endif
  # &term is empty in batch mode (-es), where echoraw has no terminal to reach
  # and would only write escape bytes into whatever is reading stdout.
  if exists('*echoraw') && &term !=# ''
    echoraw(sequence)
    MarkSuccess('OSC52')
    return true
  endif
  return WriteOsc52ToDevice(sequence, '/dev/tty')
enddef

def WriteOsc52ToDevice(sequence: string, device: string): bool
  try
    # 'b' keeps writefile() from appending the newline that would end up in the
    # terminal - and, under a multiplexer, inside the DCS envelope.
    writefile([sequence], device, 'b')
    MarkSuccess('OSC52')
    return true
  catch
    MarkFailure($'could not write OSC52 to {device}: ' .. v:exception)
    Log(last_error, 'WarningMsg')
    return false
  endtry
enddef

def CopyViaOsc52(text: string): bool
  if BoolOption('simpleclipboard_disable_osc52')
    return false
  endif
  # Configuration is checked before the environment, so a limit nobody can read
  # is reported as itself rather than as whatever the machine happens to be
  # missing today.
  var limit = Osc52Limit()
  if !limit.valid
    MarkFailure('g:simpleclipboard_osc52_limit must be a positive number; OSC52 skipped')
    Log(last_error, 'WarningMsg')
    return false
  endif
  if executable('base64') != 1
    MarkFailure('base64 is unavailable for OSC52')
    return false
  endif

  var payload = text
  if strlen(payload) > limit.bytes
    if !BoolOption('simpleclipboard_osc52_truncate')
      MarkFailure($'OSC52 refused {strlen(payload)} bytes (limit {limit.bytes})')
      Log(last_error, 'WarningMsg')
      return false
    endif
    payload = TruncateUtf8(payload, limit.bytes)
    Trace($'OSC52 payload truncated to {strlen(payload)} bytes.', 'WarningMsg')
  endif

  var encoded = trim(system('base64 -w0', payload))
  if v:shell_error != 0
    encoded = substitute(system('base64', payload), '\n', '', 'g')
  endif
  if v:shell_error != 0
    MarkFailure('base64 encoding failed')
    return false
  endif

  return EmitOsc52(Osc52Sequence(encoded))
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

  if BoolOption('simpleclipboard_daemon_enabled') && daemon_address !=# ''
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
      if BoolOption('simpleclipboard_daemon_enabled')
        && has('libcall')
        && BoolOption('simpleclipboard_daemon_autostart')
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

# Stable suite integration API: callers provide text, SimpleClipboard owns the
# unnamed register and the best available local/daemon/OSC52 clipboard route.
# It deliberately does not echo so the originating plugin can describe the
# semantic action.
export def CopyText(text: string): bool
  setreg('"', text)
  return CopyToSystemClipboard(text)
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
    Trace('g:simpleclipboard_auto_copy_registers must be a list; automatic copy skipped.',
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

# The remote path a SimpleRemote buffer stands for, or '' for any other buffer.
#
# SimpleRemote fills two kinds of buffer from a remote workspace, and neither
# is the file the buffer name suggests.  In virtual mode the buffer is named
# remote:///abs/path, has &buftype acwrite, and carries
# b:vimrc_remote = {path, uri, generation}; the filesystem check below would
# refuse it outright.  In the projected modes (sshfs, docker-bind, local-map)
# the buffer is an ordinary local file under the workspace mount and carries
# b:simpleremote_path; its name would pass every check and copy the local
# mount path - which is exactly what nobody on the remote side can open.  Both
# variables are plain buffer state, so nothing here needs SimpleRemote loaded,
# and a buffer without them takes the ordinary filesystem route.
def RemoteFilePath(): string
  var virtual = getbufvar('%', 'vimrc_remote', {})
  var path: any = type(virtual) == v:t_dict ? get(virtual, 'path', '') : ''
  if type(path) == v:t_string && path !=# ''
    return path
  endif
  var projected = getbufvar('%', 'simpleremote_path', '')
  if type(projected) != v:t_string || projected ==# ''
    return ''
  endif
  # b:simpleremote_path is stamped on BufEnter for the workspace connected at
  # the time and is not removed when that workspace goes away, so it can
  # outlive a switch to another one.  A buffer stamped for a generation other
  # than the workspace now connected is a plain local file again; with no
  # workspace connected there is nothing to contradict it.  Both ids are
  # compared only once both are numbers: Vim9 raises E1030 on a number/string
  # comparison, and that error is not catchable where it happens, so a
  # workspace dictionary of an unexpected shape would break the copy itself.
  var workspace = get(g:, 'simpleremote_workspace', {})
  var stamped = getbufvar('%', 'simpleremote_workspace_id', '')
  if type(workspace) == v:t_dict && type(stamped) == v:t_number
    var connected: any = get(workspace, 'id', v:null)
    if type(connected) == v:t_number && stamped != connected
      return ''
    endif
  endif
  return projected
enddef

# A remote path is never relative to the local cwd, so the relative form is
# root-relative: strip the workspace root SimpleRemote reports.  Without a
# connected SimpleRemote (a session restored before its workspace reconnected)
# or for a path outside the root, the absolute path is the only honest answer.
def RelativeRemotePath(path: string): string
  if !exists('*g:SimpleRemoteWorkspaceRoot')
    return path
  endif
  var root: any = ''
  try
    root = g:SimpleRemoteWorkspaceRoot()
  catch
    return path
  endtry
  if type(root) != v:t_string || root ==# ''
    return path
  endif
  var clean_root = root ==# '/' ? '/' : substitute(root, '/\+$', '', '')
  var prefix = clean_root ==# '/' ? '/' : clean_root .. '/'
  if stridx(path, prefix) == 0 && strlen(path) > strlen(prefix)
    return strpart(path, strlen(prefix))
  endif
  return path
enddef

def CurrentFilePath(absolute: bool): string
  var remote = RemoteFilePath()
  if remote !=# ''
    return absolute ? remote : RelativeRemotePath(remote)
  endif
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

# "file path" / "absolute remote file location": the message names what was
# copied, and a remote path deserves the word, because the local mount path
# it is not is what the user may have expected.
def FileValueDescription(kind: string, absolute: bool): string
  var origin = RemoteFilePath() !=# '' ? 'remote file' : 'file'
  return absolute ? $'absolute {origin} {kind}' : $'{origin} {kind}'
enddef

# Copy the current file path relative to the effective cwd. Bang uses an
# absolute path, useful when the receiver is outside Vim's project context.
# In a SimpleRemote buffer the value is the remote path, relative to the
# workspace root rather than to the local cwd.
export def CopyPathToClipboard(absolute: bool = false): void
  CopyFileValue(CurrentFilePath(absolute), FileValueDescription('path', absolute))
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
    FileValueDescription('location', absolute))
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
  CopyFileValue(expanded[1], RemoteFilePath() !=# ''
    ? 'formatted remote file reference' : 'formatted file reference')
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
  return BoolOption('simpleclipboard_auto_copy')
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
  # Omitting the argument means "read v:event", which is what the TextYankPost
  # autocommand does: reading it here rather than deep-copying it into the
  # autocommand argument keeps the cost of a yank at one dictionary lookup for
  # users who have automatic copy switched off, instead of a full copy of every
  # yank's regcontents made before the flag was even consulted.  Callers that
  # pass an event explicitly - the tests, and anything replaying a yank - are
  # unaffected.
  var yanked: any = type(event) == v:t_none ? v:event : event
  # A newer yank supersedes a pending older one even when the newer register is
  # excluded or its payload is over the automatic-copy limit.
  if type(yanked) == v:t_dict && get(yanked, 'operator', '') ==# 'y'
    CancelPendingYank()
  endif
  var text = TextFromYankEvent(yanked)
  if text ==# ''
    return
  endif
  var limit = AutoCopyLimit()
  if !limit.valid
    Trace('g:simpleclipboard_auto_copy_max_bytes must be a number; automatic copy skipped.',
      'WarningMsg')
    return
  endif
  if limit.bytes > 0 && strlen(text) > limit.bytes
    Trace($'Automatic copy skipped: {strlen(text)} bytes exceeds limit {limit.bytes}.',
      'WarningMsg')
    return
  endif
  var delay = NumberOption('simpleclipboard_debounce_ms')
  if exists('*timer_start') && delay > 0
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
# Paste: reading the system clipboard
# -----------------------------------------------------------------------------

# Reading the clipboard is not the mirror image of writing it.  Every copy
# route above ends in a process or terminal that owns the destination; a read
# has to come back with text, and the daemon deliberately answers a read only
# over an authenticated connection (see |simpleclipboard-security|), which the
# default local setup does not have.  So PasteText() never asks the daemon.  It
# reads the "+ / "* register when this Vim has +clipboard and something behind
# it, and otherwise runs a paste program as an asynchronous job whose standard
# output is the answer: the user's own g:simpleclipboard_paste_command, then
# pbpaste, wl-paste, xsel --output and xclip -o.  Nothing that could hold
# clipboard text or a secret ever appears on a command line, and the text is
# handed to the callback only - no register, no buffer, no log entry.

const PASTE_SELECTIONS = ['clipboard', 'primary']

# A paste program that never exits would otherwise hold its callback forever;
# the copy side has no such deadline because its jobs are fire-and-forget.
def PasteTimeoutMs(): number
  return NumberOption('simpleclipboard_paste_timeout_ms')
enddef

def AddPasteCandidate(candidates: list<dict<any>>, argv: list<string>,
    name: string): void
  add(candidates, {argv: argv, name: name})
enddef

# The custom command serves the CLIPBOARD selection only: it is configured for
# the common case, and running it for PRIMARY would silently return the wrong
# selection.  pbpaste has no PRIMARY at all.
def PasteCandidates(selection: string): list<dict<any>>
  var primary = selection ==# 'primary'
  var candidates: list<dict<any>> = []
  var configured = get(g:, 'simpleclipboard_paste_command', [])
  if !primary && ValidCommand(configured)
    AddPasteCandidate(candidates, copy(configured), 'custom paste command')
  endif
  if !primary && executable('pbpaste') == 1
    AddPasteCandidate(candidates, ['pbpaste'], 'pbpaste')
  endif
  if getenv('WAYLAND_DISPLAY') !=# '' && executable('wl-paste') == 1
    AddPasteCandidate(candidates,
      primary ? ['wl-paste', '--primary', '--no-newline'] : ['wl-paste', '--no-newline'],
      'wl-paste')
  endif
  if executable('xsel') == 1
    AddPasteCandidate(candidates,
      ['xsel', primary ? '--primary' : '--clipboard', '--output'], 'xsel')
  endif
  if executable('xclip') == 1
    AddPasteCandidate(candidates,
      ['xclip', '-selection', primary ? 'primary' : 'clipboard', '-o'], 'xclip')
  endif
  return candidates
enddef

def PasteCandidateNames(selection: string): list<string>
  var names: list<string> = []
  for candidate in PasteCandidates(selection)
    add(names, candidate.name)
  endfor
  return names
enddef

# Output may still be delivered after exit_cb runs, and close_cb runs when the
# output ends whether or not the process has been reaped, so the answer is
# complete only once both have happened.  A stopped-by-deadline job reports a
# non-zero status and takes the failure path like any other.
def FinishPaste(state: dict<any>): void
  if state.done || !state.closed || !state.exited
    return
  endif
  state.done = true
  if state.timer >= 0
    timer_stop(state.timer)
    state.timer = -1
  endif
  var name: string = state.candidates[state.index].name
  if state.status == 0
    var text = join(state.chunks, '')
    Trace($'Paste route: {name} ({strlen(text)} bytes).')
    call(state.Cb, [true, text])
    return
  endif
  var detail = state.timed_out
    ? $'{name} did not answer within {PasteTimeoutMs()} ms'
    : $'{name} exited with status {state.status}'
  Trace(detail .. '.', 'WarningMsg')
  StartPasteCandidate(state.candidates, state.index + 1, state.Cb,
    state.register, detail)
enddef

def OnPasteOutput(state: dict<any>, data: string): void
  add(state.chunks, data)
enddef

def OnPasteClosed(state: dict<any>): void
  state.closed = true
  FinishPaste(state)
enddef

def OnPasteTimeout(state: dict<any>, paste_job: job): void
  state.timed_out = true
  job_stop(paste_job)
enddef

def OnPasteExited(state: dict<any>, status: number): void
  state.exited = true
  state.status = status
  FinishPaste(state)
enddef

def PasteJobStarted(state: dict<any>, argv: list<string>): bool
  var paste_job: job
  try
    paste_job = job_start(argv, {
      in_io: 'null',
      out_io: 'pipe',
      out_mode: 'raw',
      err_io: 'null',
      out_cb: (_, data) => OnPasteOutput(state, data),
      close_cb: (_) => OnPasteClosed(state),
      exit_cb: (_, status) => OnPasteExited(state, status),
    })
  catch
    Trace($'Could not start {argv[0]}: {v:exception}', 'WarningMsg')
    return false
  endtry
  if job_status(paste_job) ==# 'fail'
    Trace($'Could not start {argv[0]}.', 'WarningMsg')
    return false
  endif
  if exists('*timer_start')
    state.timer = timer_start(PasteTimeoutMs(), (_) => OnPasteTimeout(state, paste_job))
  endif
  return true
enddef

# {register} is the "+ or "* register that was consulted first and found
# empty, or '' when this Vim has no +clipboard; a final failure names it so
# that "the clipboard is empty" and "nothing could read the clipboard" stay
# distinguishable in the message the caller shows.
def StartPasteCandidate(candidates: list<dict<any>>, index: number,
    Cb: func, register: string, previous_error: string): void
  var current = index
  while current < len(candidates)
    var state: dict<any> = {candidates: candidates, index: current, Cb: Cb,
      register: register, chunks: [], closed: false, exited: false,
      status: -1, done: false, timer: -1, timed_out: false}
    if PasteJobStarted(state, candidates[current].argv)
      return
    endif
    # A job that failed to start has no live callbacks; should one arrive
    # anyway it must not start a second chain beside the one continuing here.
    state.done = true
    current += 1
  endwhile
  var reason = previous_error ==# ''
    ? 'no clipboard paste program could be started' : previous_error
  Cb(false, register ==# '' ? reason
    : $'the "{register} register is empty and {reason}')
enddef

# Suite integration API, the reading counterpart of CopyText(): hand the system
# clipboard's text to {Cb} as Cb(true, text), or Cb(false, reason) when no
# backend could read it.  {selection} is 'clipboard' (the default) or
# 'primary'.  The callback runs exactly once - before PasteText() returns when
# the answer is immediate (a filled "+ / "* register, an unusable selection, no
# backend at all), otherwise from the paste program's exit - and receives the
# text untouched: no register is written and nothing is echoed, so the caller
# owns both the message and what the text becomes.  The daemon is never asked;
# see |simpleclipboard-security|.
export def PasteText(Cb: func, selection: string = 'clipboard'): void
  if index(PASTE_SELECTIONS, selection) < 0
    Cb(false, $'selection must be "clipboard" or "primary", not "{selection}"')
    return
  endif
  var register = ''
  if has('clipboard')
    register = selection ==# 'primary' ? '*' : '+'
    var text = ''
    try
      text = getreg(register)
    catch
      text = ''
    endtry
    if text !=# ''
      Trace($'Paste route: "{register} register ({strlen(text)} bytes).')
      Cb(true, text)
      return
    endif
  endif
  var candidates = PasteCandidates(selection)
  if empty(candidates)
    if register !=# ''
      # Nothing contradicts the register: the clipboard is empty.
      Trace($'Paste route: "{register} register (empty).')
      Cb(true, '')
    else
      Cb(false, 'no clipboard paste backend is available'
        .. ' (this Vim has no +clipboard and no pbpaste, wl-paste, xsel or xclip)')
    endif
    return
  endif
  StartPasteCandidate(candidates, 0, Cb, register, '')
enddef

# -----------------------------------------------------------------------------
# Diagnostics and cache refresh
# -----------------------------------------------------------------------------

# Suite integration API: how the most recent copy went, for a caller that wants
# to describe it - CopyText() answers true for a copy that is merely queued
# behind a slower external program, or one whose daemon write is uncertain, and
# a message saying "copied" for either is a promise this plugin has not kept
# yet.  outcome is one of 'none' (nothing copied yet), 'pending', 'queued',
# 'success', 'uncertain' and 'failed'; method names the backend ('daemon',
# 'xclip', 'OSC52', 'custom command', ...) or 'failed'; bytes is the size of
# the last payload; error is the last backend failure, '' when there was none;
# at is a local timestamp, '' before the first copy.  The values are the ones
# :SimpleCopyStatus prints, so it never reveals more than that command does.
export def LastCopy(): dict<any>
  return {method: last_method, outcome: last_outcome, bytes: last_copy_bytes,
    error: last_error, at: last_copy_at}
enddef

export def Status(): void
  DetectEnvironment()
  TryLoadLib()
  FindDaemonExe()
  DetectCopyCmd()
  var daemon_health = 'disabled'
  if BoolOption('simpleclipboard_daemon_enabled')
    daemon_health = !has('libcall') ? 'unavailable (+libcall missing)'
      : daemon_route_error !=# '' ? 'blocked (configuration)'
      : daemon_address ==# '' ? 'no route'
      : PingDaemon(daemon_address) ? 'reachable' : 'unreachable'
  endif
  # A non-string token used to throw E691 right here, out of the one command
  # whose whole job is to explain a misconfiguration - so the configuration
  # summary, the token warning and every line below this one went unprinted.
  # Classify it instead, still without echoing the value.
  var configured_token = get(g:, 'simpleclipboard_token', '')
  var token_problem = TokenValidationError(configured_token)
  var token_state = token_problem !=# ''
    ? $'invalid ({substitute(token_problem, "^g:simpleclipboard_token ", "", "")})'
    : configured_token ==# '' ? 'off' : 'configured'
  var command_summary = empty(cached_copy_names) ? 'none' : join(cached_copy_names, ' -> ')
  var paste_names = PasteCandidateNames('clipboard')
  var paste_summary = (has('clipboard') ? ['"+ register'] : [])
    ->extend(paste_names)
    ->join(' -> ')
  if paste_summary ==# ''
    paste_summary = 'none'
  endif
  var osc52_state = BoolOption('simpleclipboard_disable_osc52') ? 'disabled'
    : !Osc52Limit().valid ? 'blocked (invalid limit)'
    : executable('base64') != 1 ? 'unavailable (base64 missing)'
    : 'enabled'
  var register_policy = 'invalid (expected list)'
  var configured_registers = get(g:, 'simpleclipboard_auto_copy_registers', [])
  if type(configured_registers) == v:t_list
    var names: list<string> = []
    for value in configured_registers
      add(names, type(value) == v:t_string ? value : '<invalid>')
    endfor
    register_policy = empty(names) ? 'all non-black-hole registers' : join(names, ',')
  endif
  var auto_limit = AutoCopyLimit()
  var limit_policy = !auto_limit.valid ? 'invalid (expected number)'
    : auto_limit.bytes <= 0 ? 'unlimited' : string(auto_limit.bytes) .. ' bytes'
  var lines = [
    $'SimpleClipboard {VERSION}',
    $'environment: {environment_kind} (ssh={string(IsSSH())}, container={string(InContainer())})',
    $'daemon: {daemon_health}; address={daemon_address ==# "" ? "none" : daemon_address}; token={token_state}',
    $'daemon route error: {daemon_route_error ==# "" ? "none" : daemon_route_error}',
    $'client library: {client_lib ==# "" ? "not found" : client_lib}',
    $'daemon executable: {daemon_exe_path ==# "" ? "not found" : daemon_exe_path}',
    $'external commands: {command_summary}',
    $'paste: {paste_summary}',
    $'OSC52: {osc52_state}',
    $'automatic copy: registers={register_policy}; max={limit_policy}',
    $'last copy: method={last_method}, outcome={last_outcome}, bytes={last_copy_bytes}, at={last_copy_at ==# "" ? "never" : last_copy_at}',
    $'last error: {last_error ==# "" ? "none" : last_error}',
  ]
  var problems = ValidateOptions()
  add(lines, $'configuration: {empty(problems) ? "ok" : len(problems) .. " problem(s)"}')
  for line in lines + problems
    Notify(line)
  endfor
enddef

# Reporting is separated from validating so that plugin load can warn without
# routing through the log ring before it exists, and so that a caller such as
# Refresh() reports the same text a user already saw at startup.
export def ReportOptionProblems(): void
  for problem in ValidateOptions()
    Notify(problem, 'WarningMsg')
  endfor
enddef

export def Refresh(): void
  ReportOptionProblems()
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
    if BoolOption('simpleclipboard_daemon_enabled') && has('libcall')
        && !is_remote && !IsWSL() && !custom_address
      StartDaemon(true)
    else
      Notify('Owned daemon stopped and was not restarted for the current environment.', 'Comment')
    endif
  endif
  Notify('Environment and backend caches refreshed.')
enddef
