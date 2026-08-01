vim9script

# =============================================================================
# simplecore — shared daemon supervisor for the simple* Vim plugin suite
#
# VENDORED FILE — DO NOT EDIT IN PLACE.
#   The canonical copy lives in the suite's .simplecore/core.vim.  Every
#   plugin carries a byte-identical copy at autoload/<plugin>/core.vim so the
#   plugins stay independently installable (each is its own git repository and
#   must not depend on a sibling being present).  The install path decides the
#   namespace, so the file contents never change: simplefinder reaches it as
#   simplefinder#core#Ensure(), simpletree as simpletree#core#Ensure(), and so
#   on.  Edit .simplecore/core.vim and re-run .simplecore/vendor.sh.
#
# What it owns
#   * Locating the daemon executable (explicit override → runtimepath/lib →
#     dev target/release → $PATH), with Windows .exe resolution.
#   * Starting it with generation-guarded callbacks, so a dead daemon's late
#     exit_cb can never clobber the state of the replacement that already
#     took its place.
#   * Treating a 'fail'-status job as not running.  job_start() hands back a
#     job object even when the exec itself failed, so `job != null` is not a
#     liveness test — only job_status() is.
#   * Restarting automatically with exponential backoff, and tripping a
#     circuit breaker (loudly, once) when the daemon crash-loops instead of
#     spinning forever.
#   * Correlating JSON-lines requests to replies by id with per-request
#     timeouts, so a wedged daemon cannot strand a caller's callback.
#   * Optionally negotiating a protocol version / capability set at startup.
#
# What it deliberately does not own
#   Event routing and UI.  Each plugin keeps its own OnEvent dispatcher; the
#   core hands it decoded messages and stays out of the way.
# =============================================================================

# ─────────────────────────── configuration ───────────────────────────

# Set by Setup().  Recognised keys, all optional unless marked required:
#
#   name              (required) display name used in messages, e.g. 'SimpleFinder'
#   exe               (required) daemon basename, e.g. 'simplefinder-daemon'
#   path_var          g: variable holding an explicit daemon path
#   debug_var         g: variable gating debug logging (truthy = log)
#   args              list<string> extra argv appended after the executable
#   env               dict<string> environment for the daemon process
#   codec             'json' (default) or 'raw' — 'raw' passes lines through
#                     verbatim and lets the plugin parse them itself
#   cwd               working directory for the daemon
#   auto_restart      bool, default true
#   max_restarts      crash-loop threshold, default 5
#   restart_window_ms window the threshold applies over, default 60000
#   backoff_min_ms    first restart delay, default 100
#   backoff_max_ms    backoff ceiling, default 5000
#   stable_ms         uptime after which backoff resets, default 10000
#   kill_after_ms     SIGTERM→SIGKILL escalation delay on Stop, default 2000
#   request_timeout_ms default timeout for Request(), default 0 (disabled)
#   handshake         dict — see below; omit to skip the built-in handshake
#   quiet             bool, suppress user-visible error messages
#   OnEvent           func(dict<any>)  decoded message ('json' codec)
#   OnLine            func(string)     raw line ('raw' codec)
#   OnStderr          func(string)     daemon stderr line
#   OnReady           func(number, dict<any>)  protocol version, capabilities
#   OnExit            func(number, bool)       exit code, restart pending
#   OnStart           func()                   daemon accepted, before handshake
#
# The callbacks are invoked from Vim9 context, where an unqualified name
# resolves against the script scope.  A legacy global function must therefore
# be passed as function('g:Name') or funcref('Name'); a bare function('Name')
# compiles fine and then fails at call time with E117.  Vim9 `def` functions
# and lambdas need no special treatment.
#
# handshake = {
#   request:   dict<any> sent verbatim once the daemon starts (an id is added)
#   reply_type: string   value of the reply's 'type' field, e.g. 'pong'
#   proto_key:  string   default 'protocol_version'
#   caps_key:   string   default 'capabilities'
#   timeout_ms: number   default 5000; a missed handshake is a failed start
#   forward:    bool     default true — also hand the reply to OnEvent
# }
var s_cfg: dict<any> = {}

# ─────────────────────────── daemon state ───────────────────────────

var s_job: job = null_job
var s_generation: number = 0        # bumped per start; guards stale callbacks
var s_stopping: bool = false        # Stop() in flight — suppress auto-restart
var s_exe_path: string = ''
var s_started_ms: number = 0

# Protocol negotiation.
var s_ready: bool = false
var s_proto: number = 0
var s_caps: dict<any> = {}
var s_handshake_id: number = 0
var s_handshake_timer: number = 0

# Request correlation: id -> {Cb: func, timer: number, sent_ms: number}
var s_next_id: number = 0
var s_pending: dict<any> = {}

# Restart policy.
var s_backoff_ms: number = 0
var s_restart_timer: number = 0
var s_kill_timer: number = 0
var s_crash_times: list<number> = []   # reltime-ms of recent unexpected exits
var s_tripped: bool = false            # circuit breaker open
var s_last_error: string = ''

# Counters surfaced by Health().
var s_start_count: number = 0
var s_crash_count: number = 0
var s_restart_count: number = 0

# Debug log ring buffer.
var s_log: list<string> = []

# ─────────────────────────── small helpers ───────────────────────────

def NowMs(): number
  return float2nr(reltimefloat(reltime()) * 1000.0)
enddef

def Cfg(key: string, fallback: any): any
  return get(s_cfg, key, fallback)
enddef

def Name(): string
  return Cfg('name', 'simple')
enddef

def Debugging(): bool
  var v = Cfg('debug_var', '')
  if v ==# ''
    return false
  endif
  return !!get(g:, v, 0)
enddef

export def Log(msg: string)
  add(s_log, strftime('%H:%M:%S') .. ' ' .. msg)
  if len(s_log) > 500
    s_log = s_log[-300 : ]
  endif
  if Debugging()
    echom printf('[%s] %s', Name(), msg)
  endif
enddef

export def LogLines(): list<string>
  return copy(s_log)
enddef

export def ShowLog()
  new
  setlocal buftype=nofile bufhidden=wipe noswapfile
  setline(1, empty(s_log) ? ['(no log entries)'] : s_log)
  setlocal nomodifiable
  normal! G
enddef

def Notify(msg: string, hl: string = 'ErrorMsg')
  s_last_error = msg
  Log('! ' .. msg)
  if Cfg('quiet', false)
    return
  endif
  echohl {hl}
  echom printf('[%s] %s', Name(), msg)
  echohl None
enddef

# Invoke a configured callback without letting a plugin-side error tear down
# the supervisor: a throwing OnEvent must not leave the job unmanaged.
def Fire(key: string, args: list<any> = [])
  var Cb = get(s_cfg, key, null_function)
  if Cb == null_function
    return
  endif
  try
    call(Cb, args)
  catch
    Log(printf('%s threw: %s', key, v:exception))
  endtry
enddef

# ─────────────────────────── executable lookup ───────────────────────────

def ExeName(): string
  var base = Cfg('exe', '')
  if base ==# ''
    return ''
  endif
  if has('win32') && base !~? '\.exe$'
    return base .. '.exe'
  endif
  return base
enddef

# Explicit override → runtimepath/lib → dev build output → $PATH.
export def FindExe(): string
  var pathvar = Cfg('path_var', '')
  if pathvar !=# ''
    var custom = get(g:, pathvar, '')
    if type(custom) == v:t_string && custom !=# '' && executable(custom)
      return custom
    endif
  endif

  var base = ExeName()
  if base ==# ''
    return ''
  endif

  for dir in split(&runtimepath, ',')
    var p = dir .. '/lib/' .. base
    if executable(p)
      return p
    endif
  endfor

  # Developer convenience: a cargo build in the plugin checkout, no install.
  for dir in split(&runtimepath, ',')
    for sub in ['/target/release/', '/target/debug/']
      var p = dir .. sub .. base
      if executable(p)
        return p
      endif
    endfor
  endfor

  var onpath = exepath(base)
  if onpath !=# '' && executable(onpath)
    return onpath
  endif

  return ''
enddef

export def ExePath(): string
  return s_exe_path
enddef

# ─────────────────────────── liveness ───────────────────────────

# The only honest liveness test.  job_start() returns a job object even when
# the exec failed, in which case job_status() is 'fail' and every write to the
# channel is silently dropped.
export def IsRunning(): bool
  if s_job == null_job
    return false
  endif
  return job_status(s_job) ==# 'run'
enddef

export def Ready(): bool
  return IsRunning() && s_ready
enddef

export def Protocol(): number
  return s_proto
enddef

export def Caps(): dict<any>
  return copy(s_caps)
enddef

export def HasCap(name: string): bool
  return !!get(s_caps, name, false)
enddef

# ─────────────────────────── setup ───────────────────────────

export def Setup(cfg: dict<any>)
  s_cfg = cfg
enddef

export def Configure(key: string, value: any)
  s_cfg[key] = value
enddef

# ─────────────────────────── message plumbing ───────────────────────────

def ClearPending(reason: string)
  var pending = s_pending
  s_pending = {}
  for [id, entry] in items(pending)
    if get(entry, 'timer', 0) > 0
      timer_stop(entry.timer)
    endif
    var Cb = get(entry, 'Cb', null_function)
    if Cb != null_function
      try
        call(Cb, [{type: 'error', message: reason, id: str2nr(id), _failed: true}])
      catch
        Log('pending callback threw: ' .. v:exception)
      endtry
    endif
  endfor
enddef

def ResolvePending(id: number, msg: dict<any>): bool
  var key = string(id)
  if !has_key(s_pending, key)
    return false
  endif
  var entry = s_pending[key]
  remove(s_pending, key)
  if get(entry, 'timer', 0) > 0
    timer_stop(entry.timer)
  endif
  var Cb = get(entry, 'Cb', null_function)
  if Cb != null_function
    try
      call(Cb, [msg])
    catch
      Log('request callback threw: ' .. v:exception)
    endtry
  endif
  return true
enddef

def OnHandshakeReply(msg: dict<any>)
  var hs = Cfg('handshake', {})
  s_proto = get(msg, get(hs, 'proto_key', 'protocol_version'), 0)
  var caps = get(msg, get(hs, 'caps_key', 'capabilities'), {})
  s_caps = type(caps) == v:t_dict ? caps : {}
  s_ready = true
  s_handshake_id = 0
  if s_handshake_timer > 0
    timer_stop(s_handshake_timer)
    s_handshake_timer = 0
  endif
  Log(printf('handshake ok: protocol v%d, %d capabilities', s_proto, len(s_caps)))
  Fire('OnReady', [s_proto, copy(s_caps)])
enddef

def Dispatch(line: string)
  if line ==# ''
    return
  endif

  if Cfg('codec', 'json') ==# 'raw'
    Fire('OnLine', [line])
    return
  endif

  var msg: any
  try
    msg = json_decode(line)
  catch
    Log('decode error: ' .. line)
    return
  endtry
  if type(msg) != v:t_dict
    return
  endif

  var id = get(msg, 'id', 0)

  # Handshake reply: consume it, then forward unless told not to, so a plugin
  # that already understood its own pong keeps seeing it.
  if s_handshake_id > 0 && id == s_handshake_id
    var hs = Cfg('handshake', {})
    var want = get(hs, 'reply_type', '')
    if want ==# '' || get(msg, 'type', '') ==# want
      OnHandshakeReply(msg)
      if !get(hs, 'forward', true)
        return
      endif
    endif
  endif

  if type(id) == v:t_number && id > 0 && ResolvePending(id, msg)
    return
  endif

  Fire('OnEvent', [msg])
enddef

# ─────────────────────────── sending ───────────────────────────

# Accepts a dict (encoded as a JSON line) or a pre-formatted string.  Returns
# false when the daemon is not writable, so callers can fail fast instead of
# waiting on a reply that will never come.
export def Send(payload: any): bool
  if !IsRunning()
    Log('send dropped: daemon not running')
    return false
  endif
  var wire: string
  if type(payload) == v:t_string
    wire = payload =~# "\n$" ? payload : payload .. "\n"
  else
    try
      wire = json_encode(payload) .. "\n"
    catch
      Log('encode error: ' .. v:exception)
      return false
    endtry
  endif
  try
    ch_sendraw(s_job, wire)
  catch
    Log('send error: ' .. v:exception)
    return false
  endtry
  return true
enddef

export def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

# Send a request and route exactly one reply back to Cb.  A timeout of 0 uses
# cfg.request_timeout_ms; pass -1 to disable the timeout for this call.
# Returns the request id, or 0 if the send failed.
export def Request(req: dict<any>, Cb: func, timeout_ms: number = 0): number
  var msg = copy(req)
  var id: number
  var given = get(msg, 'id', 0)
  if type(given) == v:t_number && given > 0
    id = given
  else
    id = NextId()
    msg.id = id
  endif

  var limit = timeout_ms
  if limit == 0
    limit = Cfg('request_timeout_ms', 0)
  endif

  var entry = {Cb: Cb, timer: 0, sent_ms: NowMs()}
  s_pending[string(id)] = entry

  if !Send(msg)
    ResolvePending(id, {type: 'error', message: 'daemon not running', id: id, _failed: true})
    return 0
  endif

  if limit > 0
    entry.timer = timer_start(limit, (_) => ExpireRequest(id, limit))
  endif
  return id
enddef

# Kept out of the timer lambda on purpose: a multi-line dictionary literal
# nested inside a Vim9 lambda block body trips the parser with E723.
def ExpireRequest(id: number, limit: number)
  var key = string(id)
  if !has_key(s_pending, key)
    return
  endif
  Log(printf('request %d timed out after %dms', id, limit))
  s_pending[key].timer = 0
  var failure = {
    type: 'error',
    message: printf('request timed out after %dms', limit),
    id: id,
    _timeout: true,
    _failed: true,
  }
  ResolvePending(id, failure)
enddef

# Drop a still-pending request without firing its callback (used when a UI
# closes and no longer cares about the answer).
export def Cancel(id: number)
  var key = string(id)
  if !has_key(s_pending, key)
    return
  endif
  var entry = remove(s_pending, key)
  if get(entry, 'timer', 0) > 0
    timer_stop(entry.timer)
  endif
enddef

export def PendingCount(): number
  return len(s_pending)
enddef

# ─────────────────────────── restart policy ───────────────────────────

def ResetBackoff()
  s_backoff_ms = 0
  s_crash_times = []
  s_tripped = false
enddef

def NoteCrash(): bool
  # Returns true when the breaker should stay closed (restart allowed).
  var now = NowMs()
  var window = Cfg('restart_window_ms', 60000)
  add(s_crash_times, now)
  s_crash_times = filter(s_crash_times, (_, t) => now - t <= window)
  var limit = Cfg('max_restarts', 5)
  return len(s_crash_times) <= limit
enddef

def NextBackoff(): number
  var lo = Cfg('backoff_min_ms', 100)
  var hi = Cfg('backoff_max_ms', 5000)
  s_backoff_ms = s_backoff_ms <= 0 ? lo : min([s_backoff_ms * 2, hi])
  return s_backoff_ms
enddef

def ScheduleRestart()
  if s_restart_timer > 0
    timer_stop(s_restart_timer)
  endif
  var delay = NextBackoff()
  s_restart_count += 1
  Log(printf('restarting daemon in %dms (attempt %d)', delay, s_restart_count))
  s_restart_timer = timer_start(delay, (_) => {
    s_restart_timer = 0
    if !IsRunning()
      Ensure()
    endif
  })
enddef

# ─────────────────────────── lifecycle ───────────────────────────

def OnExit(generation: number, code: number)
  # A stopped daemon can exit after its replacement has already started; that
  # stale callback must not touch the live job's state.
  if generation != s_generation
    Log(printf('stale generation %d exited with code %d', generation, code))
    return
  endif

  var was_expected = s_stopping
  var uptime = s_started_ms > 0 ? NowMs() - s_started_ms : 0

  s_job = null_job
  s_ready = false
  s_proto = 0
  s_caps = {}
  s_handshake_id = 0
  s_stopping = false
  s_started_ms = 0
  if s_handshake_timer > 0
    timer_stop(s_handshake_timer)
    s_handshake_timer = 0
  endif
  if s_kill_timer > 0
    timer_stop(s_kill_timer)
    s_kill_timer = 0
  endif

  ClearPending(was_expected ? 'daemon stopped' : printf('daemon exited (code %d)', code))

  var restarting = false
  if was_expected
    Log('daemon stopped')
    ResetBackoff()
  else
    s_crash_count += 1
    Log(printf('daemon exited unexpectedly with code %d after %dms', code, uptime))
    # A daemon that stayed up a good while is not crash-looping; forgive the
    # accumulated history so a long-lived session does not slowly trip.
    if uptime >= Cfg('stable_ms', 10000)
      ResetBackoff()
    endif
    if Cfg('auto_restart', true)
      if NoteCrash()
        restarting = true
      elseif !s_tripped
        s_tripped = true
        Notify(printf(
          'daemon crashed %d times in %ds — giving up. Run :%sRestart after fixing it (:%sLog for details).',
          len(s_crash_times), Cfg('restart_window_ms', 60000) / 1000, Name(), Name()))
      endif
    endif
  endif

  Fire('OnExit', [code, restarting])

  if restarting
    ScheduleRestart()
  endif
enddef

def SendHandshake()
  var hs = Cfg('handshake', {})
  if empty(hs) || !has_key(hs, 'request')
    # No handshake configured: the daemon is usable as soon as it is running.
    s_ready = true
    Fire('OnReady', [0, {}])
    return
  endif

  var req = copy(hs.request)
  s_handshake_id = NextId()
  req.id = s_handshake_id
  if !Send(req)
    return
  endif

  var limit = get(hs, 'timeout_ms', 5000)
  if limit > 0
    var generation = s_generation
    s_handshake_timer = timer_start(limit, (_) => {
      s_handshake_timer = 0
      if generation == s_generation && !s_ready && IsRunning()
        Notify(printf('daemon did not answer the handshake within %dms', limit), 'WarningMsg')
      endif
    })
  endif
enddef

export def Ensure(): bool
  if IsRunning()
    return true
  endif
  if s_tripped
    Log('start refused: circuit breaker open')
    return false
  endif

  var exe = FindExe()
  if exe ==# ''
    Notify(printf('daemon %s not found. Run ./install.sh%s.',
      ExeName(),
      Cfg('path_var', '') ==# '' ? '' : printf(' or set g:%s', Cfg('path_var', ''))))
    return false
  endif
  s_exe_path = exe

  var argv = [exe] + Cfg('args', [])
  var opts: dict<any> = {
    in_io: 'pipe',
    out_mode: 'nl',
    err_mode: 'nl',
    stoponexit: 'term',
  }

  var env = Cfg('env', {})
  if !empty(env)
    opts.env = env
  endif
  var cwd = Cfg('cwd', '')
  if cwd !=# ''
    opts.cwd = cwd
  endif

  s_generation += 1
  var generation = s_generation

  # Two fences, not one.  The generation check drops output from a superseded
  # job; the s_stopping check drops output that was already queued when the
  # caller asked this job to stop, which would otherwise keep mutating plugin
  # state after an explicit :Stop or :Disable.
  opts.out_cb = (_, line) => {
    if generation == s_generation && !s_stopping
      Dispatch(line)
    endif
  }
  opts.err_cb = (_, line) => {
    if generation == s_generation && !s_stopping
      Log('stderr: ' .. line)
      Fire('OnStderr', [line])
    endif
  }
  opts.exit_cb = (_, code) => {
    OnExit(generation, code)
  }

  var started: job
  try
    started = job_start(argv, opts)
  catch
    s_job = null_job
    Notify('job_start failed: ' .. v:exception)
    return false
  endtry

  # job_start() succeeds even when the exec did not; only job_status() knows.
  if job_status(started) !=# 'run'
    s_job = null_job
    Notify(printf('daemon failed to start (%s)', exe))
    return false
  endif

  s_job = started
  s_stopping = false
  s_ready = false
  s_started_ms = NowMs()
  s_start_count += 1
  s_last_error = ''
  Log(printf('daemon started: %s', exe))

  Fire('OnStart', [])
  SendHandshake()
  return true
enddef

# Stop the daemon.  Graceful by default: SIGTERM, then SIGKILL after
# cfg.kill_after_ms if it is still alive.
export def Stop(force: bool = false)
  if s_restart_timer > 0
    timer_stop(s_restart_timer)
    s_restart_timer = 0
  endif
  if s_handshake_timer > 0
    timer_stop(s_handshake_timer)
    s_handshake_timer = 0
  endif

  if s_job == null_job
    ClearPending('daemon stopped')
    return
  endif

  s_stopping = true
  var doomed = s_job
  var generation = s_generation

  try
    job_stop(doomed, force ? 'kill' : 'term')
  catch
    Log('job_stop failed: ' .. v:exception)
  endtry

  if force
    return
  endif

  var grace = Cfg('kill_after_ms', 2000)
  if grace > 0
    if s_kill_timer > 0
      timer_stop(s_kill_timer)
    endif
    s_kill_timer = timer_start(grace, (_) => {
      s_kill_timer = 0
      if generation == s_generation && job_status(doomed) ==# 'run'
        Log('daemon ignored SIGTERM; sending SIGKILL')
        try
          job_stop(doomed, 'kill')
        catch
        endtry
      endif
    })
  endif
enddef

# Re-arm auto-restart without forcing a start right now.  For plugins with an
# explicit enable/disable switch, where flipping it back on is the user's way
# of saying "try again".
export def ClearBreaker()
  ResetBackoff()
  s_restart_count = 0
enddef

# Manual restart.  Clears the circuit breaker — the user is explicitly asking
# for another attempt, and may well have just fixed the cause.
export def Restart(): bool
  ResetBackoff()
  s_restart_count = 0
  if IsRunning()
    var generation = s_generation
    Stop()
    # Ensure() from the exit callback would race with the stop; hop through a
    # timer so the old job is fully reaped first.
    timer_start(0, (_) => {
      if !IsRunning()
        Ensure()
      endif
    })
    return true
  endif
  return Ensure()
enddef

# ─────────────────────────── health ───────────────────────────

export def Health(): dict<any>
  return {
    name: Name(),
    exe: ExeName(),
    exe_path: s_exe_path ==# '' ? FindExe() : s_exe_path,
    running: IsRunning(),
    ready: s_ready,
    protocol: s_proto,
    capabilities: copy(s_caps),
    uptime_ms: s_started_ms > 0 ? NowMs() - s_started_ms : 0,
    starts: s_start_count,
    crashes: s_crash_count,
    restarts: s_restart_count,
    pending: len(s_pending),
    breaker_open: s_tripped,
    last_error: s_last_error,
  }
enddef

export def HealthLines(): list<string>
  var h = Health()
  var lines: list<string> = []
  var exe = h.exe_path ==# '' ? '(not found)' : h.exe_path
  add(lines, printf('[%s] daemon: %s', h.running ? 'OK' : 'ERROR', exe))
  if h.running
    add(lines, printf('[%s] state: running, %s, uptime %.1fs',
      h.ready ? 'OK' : 'WARN',
      h.ready ? 'ready' : 'handshake pending',
      h.uptime_ms / 1000.0))
    if h.protocol > 0
      add(lines, printf('[OK] protocol: v%d%s', h.protocol,
        empty(h.capabilities) ? '' : ', caps: ' .. join(sort(keys(h.capabilities)), ', ')))
    endif
  else
    add(lines, '[ERROR] state: not running')
  endif
  if h.crashes > 0
    add(lines, printf('[%s] crashes: %d (restarts: %d)',
      h.breaker_open ? 'ERROR' : 'WARN', h.crashes, h.restarts))
  endif
  if h.breaker_open
    add(lines, '[ERROR] auto-restart disabled after repeated crashes; run the Restart command')
  endif
  if h.pending > 0
    add(lines, printf('[INFO] in-flight requests: %d', h.pending))
  endif
  if h.last_error !=# ''
    add(lines, printf('[WARN] last error: %s', h.last_error))
  endif
  return lines
enddef

# Reset every scrap of supervisor state.  Used by tests.
export def ResetForTest()
  Stop(true)
  s_job = null_job
  s_generation += 1
  s_stopping = false
  s_ready = false
  s_proto = 0
  s_caps = {}
  s_handshake_id = 0
  s_next_id = 0
  s_pending = {}
  s_log = []
  s_started_ms = 0
  s_start_count = 0
  s_crash_count = 0
  s_restart_count = 0
  s_last_error = ''
  ResetBackoff()
enddef
