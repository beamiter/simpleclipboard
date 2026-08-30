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
#   * Optionally negotiating a protocol version / capability set at startup,
#     and failing the start when the daemon never answers.
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
#   timeout_ms: number   deadline for the reply, default 5000; 0 disables it.
#                        A missed handshake is a failed start, not a warning:
#                        the daemon is killed and its exit travels the crash
#                        path, so auto_restart, the backoff and the crash-loop
#                        breaker apply exactly as they do to a daemon that
#                        died on its own.  Configure no handshake at all if
#                        the plugin negotiates its own protocol.  The deadline
#                        counts time Vim could actually listen: an expiry
#                        observed only because Vim was blocked is extended
#                        rather than believed — see HandshakeDeadline().
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
var s_negotiated: bool = false
var s_proto: number = 0
var s_caps: dict<any> = {}
var s_handshake_id: number = 0
var s_handshake_timer: number = 0
var s_handshake_expected: bool = false
var s_handshake_config: dict<any> = {}
# Set when the current job is being killed for missing its handshake deadline.
# The exit is a crash like any other, with one exception: it must not be
# forgiven by the stable_ms rule below, or a timeout_ms longer than stable_ms
# would reset the backoff on every attempt and the breaker would never trip.
var s_handshake_failed: bool = false

# Request correlation: id -> {Cb: func, timer: number, sent_ms: number}
var s_next_id: number = 0
var s_pending: dict<any> = {}

# Restart policy.
var s_backoff_ms: number = 0
var s_restart_timer: number = 0
var s_kill_timer: number = 0
# Restart intent for the exiting generation.  Restart() sets it while waiting
# for the process to die; OnExit also stages an automatic intent before calling
# plugin callbacks.  Stop() clears it, so a callback can veto a replacement
# before its timer exists without racing the rest of OnExit.
var s_restart_after_exit_generation: number = 0
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

# A handshake is configured only when there is something to send.  `handshake:
# {}` and a missing key both mean the same thing: this plugin negotiates its
# own protocol, or none, and the core must not claim to have negotiated one.
def HandshakeConfigured(): bool
  var hs = Cfg('handshake', {})
  return type(hs) == v:t_dict && has_key(hs, 'request')
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

# Usable — which is not the same as negotiated.  True when the daemon is
# running and, if a handshake was configured, that handshake completed.  A
# plugin that configures none has nothing to wait for, so its daemon is usable
# the moment it runs; ask Negotiated() when the question is whether a protocol
# was actually agreed.
export def Ready(): bool
  return !s_stopping && IsRunning() && s_ready
enddef

# Did a configured handshake actually complete?  False while one is in flight,
# and false for a plugin that configures none and negotiates by hand — the
# distinction Ready() cannot express, and the one the health report used to
# paper over by printing "ready" for a protocol nobody ever exchanged.
export def Negotiated(): bool
  return Ready() && s_negotiated
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

def OnHandshakeReply(msg: dict<any>): bool
  if s_handshake_failed
    return false
  endif
  var hs = s_handshake_config
  var proto = get(msg, get(hs, 'proto_key', 'protocol_version'), 0)
  if type(proto) != v:t_number || proto <= 0
    FailStart('daemon returned an invalid handshake protocol version')
    return false
  endif
  var caps = get(msg, get(hs, 'caps_key', 'capabilities'), {})
  if type(caps) != v:t_dict
    FailStart('daemon returned invalid handshake capabilities')
    return false
  endif
  s_proto = proto
  s_caps = caps
  s_ready = true
  s_negotiated = true
  s_handshake_id = 0
  if s_handshake_timer > 0
    timer_stop(s_handshake_timer)
    s_handshake_timer = 0
  endif
  Log(printf('handshake ok: protocol v%d, %d capabilities', s_proto, len(s_caps)))
  Fire('OnReady', [s_proto, copy(s_caps)])
  return true
enddef

def Dispatch(generation: number, line: string)
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
  if s_handshake_id > 0 && type(id) == v:t_number && id == s_handshake_id
    var hs = s_handshake_config
    var want = get(hs, 'reply_type', '')
    var reply_type = get(msg, 'type', '')
    if type(want) != v:t_string || type(reply_type) != v:t_string
      FailStart('daemon returned an invalid handshake message type')
      return
    endif
    if want ==# '' || reply_type ==# want
      if !OnHandshakeReply(msg)
        return
      endif
      # OnReady is plugin code and may synchronously Stop(), Restart(), or even
      # reset the supervisor.  The out_cb fence was checked before Dispatch,
      # so re-check it after that callback before an old pong can leak into the
      # new/stopping generation's OnEvent handler.
      if generation != s_generation || s_stopping || s_handshake_failed || !IsRunning()
        return
      endif
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
  if s_stopping || s_handshake_failed || !IsRunning()
    var reason = s_stopping ? 'daemon stopping' :
      s_handshake_failed ? 'daemon failed its handshake' : 'daemon not running'
    Log('send dropped: ' .. reason)
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

def IdInUse(id: number): bool
  return id == s_handshake_id || has_key(s_pending, string(id))
enddef

export def NextId(): number
  while true
    s_next_id += 1
    if !IdInUse(s_next_id)
      return s_next_id
    endif
  endwhile
  return 0
enddef

# Send a request and route exactly one reply back to Cb.  A timeout of 0 uses
# cfg.request_timeout_ms; pass -1 to disable the timeout for this call.
# Returns the request id, or 0 if the send failed.
export def Request(req: dict<any>, Cb: func, timeout_ms: number = 0): number
  var msg = copy(req)
  var id: number
  var given = get(msg, 'id', 0)
  if type(given) == v:t_number && given > 0 && !IdInUse(given)
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
  var generation = s_generation
  s_restart_count += 1
  Log(printf('restarting daemon in %dms (attempt %d)', delay, s_restart_count))
  s_restart_timer = timer_start(delay, (_) => {
    s_restart_timer = 0
    if generation == s_generation && !s_stopping && !IsRunning()
      Ensure()
    endif
  })
enddef

# ─────────────────────────── lifecycle ───────────────────────────

def OnExit(generation: number, code: number)
  # A stopped daemon can exit after its replacement has already started; that
  # stale callback must not touch the live job's state.
  if generation != s_generation
    if s_restart_after_exit_generation == generation
      s_restart_after_exit_generation = 0
    endif
    Log(printf('stale generation %d exited with code %d', generation, code))
    return
  endif

  var was_expected = s_stopping
  var was_ready = s_ready
  var handshake_failed = s_handshake_failed
  var manual_restart = s_restart_after_exit_generation == generation
  if manual_restart
    s_restart_after_exit_generation = 0
  endif
  var uptime = s_started_ms > 0 ? NowMs() - s_started_ms : 0

  s_job = null_job
  s_ready = false
  s_negotiated = false
  s_proto = 0
  s_caps = {}
  s_handshake_id = 0
  s_handshake_expected = false
  s_handshake_config = {}
  s_handshake_failed = false
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

  var restarting = false
  if was_expected
    Log('daemon stopped')
    ResetBackoff()
  else
    s_crash_count += 1
    var crash_message = printf(
      'daemon exited unexpectedly with code %d after %dms', code, uptime)
    Log(crash_message)
    # A handshake failure already recorded a more specific reason. Every other
    # asynchronous exit still needs a durable explanation in Health().
    if s_last_error ==# ''
      s_last_error = crash_message
    endif
    # A daemon that stayed up a good while is not crash-looping; forgive the
    # accumulated history so a long-lived session does not slowly trip.  A
    # start killed for missing its handshake never counts as stable however
    # long it sat there: it never became usable, and forgiving it would let a
    # timeout_ms above stable_ms respawn a mute daemon forever.
    if uptime >= Cfg('stable_ms', 10000) && was_ready && !handshake_failed
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

  # Finish crash/breaker accounting before invoking any user callback.  A
  # failed pending request is allowed to call Ensure(), and it must see the
  # breaker produced by this very exit rather than sneak in a replacement.
  var restart_pending = restarting || manual_restart
  s_restart_after_exit_generation = restart_pending ? generation : 0
  ClearPending(was_expected ? 'daemon stopped' : printf('daemon exited (code %d)', code))

  # ClearPending callbacks may already have started a replacement or cancelled
  # the staged intent.  Report the state as it stands when OnExit runs, then let
  # OnExit cancel it too by calling Stop().
  restart_pending = s_restart_after_exit_generation == generation && generation == s_generation
  Fire('OnExit', [code, restart_pending])

  if s_restart_after_exit_generation != generation || generation != s_generation
    return
  endif
  s_restart_after_exit_generation = 0
  if manual_restart
    s_restart_timer = timer_start(0, (_) => {
      s_restart_timer = 0
      if generation == s_generation && !s_stopping && !IsRunning()
        Ensure()
      endif
    })
  elseif restarting
    ScheduleRestart()
  endif
enddef

# A start that timed out or returned an invalid handshake is a failed start,
# not a running daemon. Stop() is deliberately not reused: it marks the exit
# expected, which would suppress the restart and leave the failure invisible.
# The kill is ungraceful on purpose — an unresponsive or incompatible process
# has not earned a SIGTERM grace period.
def FailStart(reason: string)
  if s_handshake_failed
    return
  endif
  s_handshake_failed = true
  s_ready = false
  s_negotiated = false
  s_handshake_id = 0
  if s_handshake_timer > 0
    timer_stop(s_handshake_timer)
    s_handshake_timer = 0
  endif
  Notify(reason)
  if s_job == null_job
    return
  endif
  try
    job_stop(s_job, 'kill')
  catch
    Log('job_stop failed after a missed handshake: ' .. v:exception)
  endtry
enddef

def SendHandshake()
  var configured = Cfg('handshake', {})
  s_handshake_expected = HandshakeConfigured()
  s_handshake_config = s_handshake_expected ? deepcopy(configured) : {}
  if !s_handshake_expected
    # Nothing to negotiate: the daemon is usable as soon as it is running, and
    # OnReady still fires so a plugin that negotiates its own protocol has its
    # cue.  Negotiated() stays false — nothing was agreed here.
    s_ready = true
    Fire('OnReady', [0, {}])
    return
  endif
  var hs = s_handshake_config

  var req = copy(hs.request)
  s_handshake_id = NextId()
  req.id = s_handshake_id
  if !Send(req)
    return
  endif

  var limit = get(hs, 'timeout_ms', 5000)
  if limit > 0
    ArmHandshakeDeadline(s_generation, limit, NowMs() + limit, 0)
  endif
enddef

# A deadline timer that runs no later than this past its due time was serviced
# while Vim was listening: had a reply been sitting on the channel, the same
# idle moment would have delivered it.  Anything later measured Vim, not the
# daemon.
const HANDSHAKE_SLACK_MS = 50
# How many times a blocked Vim may push the deadline out.  Bounded, so a plugin
# that blocks over and over cannot keep a genuinely mute daemon alive for ever.
const HANDSHAKE_MAX_EXTENSIONS = 4

def ArmHandshakeDeadline(generation: number, limit: number, due_ms: number, extensions: number)
  var delay = due_ms - NowMs()
  s_handshake_timer = timer_start(delay > 0 ? delay : 0,
    (_) => HandshakeDeadline(generation, limit, due_ms, extensions))
enddef

# The deadline is a claim about the daemon, and it can only measure the daemon
# while Vim is listening.  Timers and channel callbacks are serviced at the same
# idle points, so any synchronous stretch longer than timeout_ms — a plugin
# scanning a large buffer, a user leaning on a key — leaves an already-delivered
# reply queued behind an already-expired timer, and whichever of the two Vim
# happens to run first decides whether a healthy daemon is killed.  Measured on
# Vim 9.2: a 700ms busy loop against a 200ms deadline killed a daemon that had
# answered in single-digit milliseconds, wrote 'daemon did not answer the
# handshake within 200ms' into Health(), and — because the !s_handshake_failed
# fence then drops the pong that was there all along — could not recover.
#
# ch_canread() cannot arbitrate this, though it looks like the obvious test:
# measured false in exactly that window, because the reply is still in the
# kernel pipe that Vim never got round to reading.  The timer's own lateness
# can.  A timer that runs far past its due time is proof that Vim was blocked,
# which is the one case in which the elapsed time says nothing about the daemon.
# Hand back the time it was denied and re-check; fail only from a deadline that
# expired while Vim could actually have heard an answer.
def HandshakeDeadline(generation: number, limit: number, due_ms: number, extensions: number)
  s_handshake_timer = 0
  if generation != s_generation || s_ready || !IsRunning()
    return
  endif
  var late = NowMs() - due_ms
  if late > HANDSHAKE_SLACK_MS && extensions < HANDSHAKE_MAX_EXTENSIONS
    var grace = max([HANDSHAKE_SLACK_MS, min([late, limit])])
    Log(printf(
      'handshake deadline ran %dms late — Vim was blocked, not the daemon; extending %dms',
      late, grace))
    ArmHandshakeDeadline(generation, limit, NowMs() + grace, extensions + 1)
    return
  endif
  FailStart(printf(
    'daemon did not answer the handshake within %dms; the start failed', limit))
enddef

export def Ensure(): bool
  if IsRunning()
    # A start that missed or failed its handshake is being killed; this
    # generation will never serve anyone, and the exit travels the crash path
    # where auto_restart decides what happens next.  That is a real refusal.
    if s_handshake_failed
      return false
    endif
    if !s_stopping
      return true
    endif
    # A Stop() in flight is not a refusal.  The job is kept until its exit
    # callback runs, so there is a window in which the daemon is alive and
    # winding down — and callers across the family are written
    # `if !EnsureDaemon() | return | endif`, so answering false there turned a
    # disable-then-enable in one tick into a plugin that stayed off, with no
    # message and no daemon.  Answering true and doing nothing would be worse:
    # an unkept promise.  Stage the replacement on the exit that is already
    # coming, exactly as Restart() does; a later Stop() still vetoes it by
    # clearing the same field.
    if s_tripped
      Log('start refused: circuit breaker open')
      return false
    endif
    s_restart_after_exit_generation = s_generation
    Log('start requested while stopping; staged for the pending exit')
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
  #
  # The first fence long read as untestable — Ensure() short-circuits while the
  # old job is alive, so how is a superseded job still writing?  Like this: the
  # daemon dies while Vim is inside a synchronous stretch, IsRunning() answers
  # false the moment anyone asks (it re-queries job_status rather than watching
  # a flag), Ensure() starts the replacement, and only afterwards does Vim idle
  # and read the lines the dead job had already written.  Without the
  # generation check those land in the replacement's OnEvent, and s_stopping is
  # false throughout, so the second fence never sees them.  tests/vim_core.vim
  # builds exactly that state.
  opts.out_cb = (_, line) => {
    if generation == s_generation && !s_stopping && !s_handshake_failed
      Dispatch(generation, line)
    endif
  }
  opts.err_cb = (_, line) => {
    if generation == s_generation && !s_stopping && !s_handshake_failed
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

  # job_start() succeeds even when the spawn did not, and only job_status()
  # knows.  This catches a synchronous spawn failure — a CreateProcess error on
  # Windows, a failed fork() anywhere.  It cannot catch a failed *exec* on
  # Unix: the child does not reach execvp() until after job_start() has
  # returned, so job_status() answers 'run' here for a missing binary or a bad
  # interpreter line, and that failure arrives later through exit_cb like any
  # other death.  IsRunning() is what stays honest in the meantime, because it
  # re-queries job_status() on every call instead of caching a flag.
  if job_status(started) !=# 'run'
    s_job = null_job
    Notify(printf('daemon failed to start (%s)', exe))
    return false
  endif

  s_job = started
  s_stopping = false
  s_restart_after_exit_generation = 0
  s_ready = false
  s_negotiated = false
  s_handshake_expected = false
  s_handshake_config = {}
  s_handshake_failed = false
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
def StopInternal(force: bool, restart_after_exit: bool)
  s_restart_after_exit_generation = restart_after_exit ? s_generation : 0
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
    s_restart_after_exit_generation = 0
    return
  endif

  s_stopping = true
  ClearPending(restart_after_exit ? 'daemon restarting' : 'daemon stopping')
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

export def Stop(force: bool = false)
  StopInternal(force, false)
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
    StopInternal(false, true)
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
    stopping: s_stopping,
    failed_start: s_handshake_failed,
    handshake_expected: s_handshake_expected,
    ready: Ready(),
    negotiated: Negotiated(),
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
    # Three states, not two.  The old line keyed on s_ready alone and so
    # printed "[OK] state: running, ready" for the plugins that configure no
    # handshake — an OK that was true by construction rather than measured,
    # sitting in the report directly above their own line saying the protocol
    # had never been negotiated.
    if h.failed_start
      add(lines, printf('[ERROR] state: failed start, stopping, uptime %.1fs',
        h.uptime_ms / 1000.0))
    elseif h.stopping
      add(lines, printf('[INFO] state: stopping, uptime %.1fs', h.uptime_ms / 1000.0))
    elseif !h.handshake_expected
      add(lines, printf('[INFO] state: running, no handshake configured, uptime %.1fs',
        h.uptime_ms / 1000.0))
    else
      add(lines, printf('[%s] state: running, %s, uptime %.1fs',
        h.negotiated ? 'OK' : 'WARN',
        h.negotiated ? 'ready' : 'handshake pending',
        h.uptime_ms / 1000.0))
    endif
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
  s_negotiated = false
  s_proto = 0
  s_caps = {}
  s_handshake_id = 0
  s_handshake_expected = false
  s_handshake_config = {}
  s_handshake_failed = false
  s_restart_after_exit_generation = 0
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
