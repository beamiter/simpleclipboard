" ============================================================================
" simplecore supervisor regression tests
"
" VENDORED FILE — DO NOT EDIT IN PLACE.  Canonical copy: .simplecore/tests/.
" The vendor script rewrites simpleclipboard to the host plugin's autoload namespace.
"
" Run:  vim -Nu NONE -n -es -S tests/vim_core.vim
" ============================================================================

set nocompatible
set nomore
set shortmess+=I

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:ns = 'simpleclipboard#core#'
call delete(s:root .. '/tests/core-errors.log')
execute 'set runtimepath^=' .. fnameescape(s:root)

let s:fake = s:root .. '/tests/fake_daemon.py'
if !executable(s:fake)
  " CI checkouts do not always preserve the mode bit.
  call setfperm(s:fake, 'rwxr-xr-x')
endif

" ---------------------------------------------------------------- helpers ---

function! s:C(name, ...) abort
  return call(s:ns .. a:name, a:000)
endfunction

" Poll until Expr is true or the budget runs out.  sleep lets Vim service
" channel callbacks, which is the only way async daemon output lands.
function! s:Wait(expr, ms) abort
  let l:ticks = a:ms / 10
  let l:i = 0
  while l:i < l:ticks
    if eval(a:expr)
      return 1
    endif
    sleep 10m
    let l:i += 1
  endwhile
  return eval(a:expr)
endfunction

let s:events = []
let s:lines = []
let s:ready = []
let s:exits = []

function! CoreOnEvent(msg) abort
  call add(s:events, a:msg)
endfunction
function! CoreOnLine(line) abort
  call add(s:lines, a:line)
endfunction
function! CoreOnReady(proto, caps) abort
  call add(s:ready, {'proto': a:proto, 'caps': a:caps})
endfunction
function! CoreOnExit(code, restarting) abort
  call add(s:exits, {'code': a:code, 'restarting': a:restarting})
endfunction

function! s:Fresh(overrides) abort
  call s:C('ResetForTest')
  let s:events = []
  let s:lines = []
  let s:ready = []
  let s:exits = []
  let g:core_test_path = s:fake
  let l:cfg = {
        \ 'name': 'CoreTest',
        \ 'exe': 'fake_daemon.py',
        \ 'path_var': 'core_test_path',
        \ 'quiet': v:true,
        \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong'},
        \ 'OnEvent': function('g:CoreOnEvent'),
        \ 'OnLine': function('g:CoreOnLine'),
        \ 'OnReady': function('g:CoreOnReady'),
        \ 'OnExit': function('g:CoreOnExit'),
        \ }
  call extend(l:cfg, a:overrides)
  call s:C('Setup', l:cfg)
endfunction

" ------------------------------------------------- missing / broken binary ---

" A daemon that cannot be found must fail closed, not report itself running.
call s:Fresh({})
let g:core_test_path = ''
let s:saved_rtp = &runtimepath
set runtimepath=
call assert_false(s:C('Ensure'), 'Ensure must fail when the daemon is missing')
call assert_false(s:C('IsRunning'), 'a missing daemon is not running')
call assert_equal('', s:C('FindExe'))
let &runtimepath = s:saved_rtp

" job_start() hands back a job object even when the exec goes on to fail, so
" `job != null` is not a liveness test.  A daemon whose exec dies immediately
" must converge to not-running and stop accepting writes — the old bug was a
" cached `running` flag that stayed true for the rest of the session.
call s:Fresh({'auto_restart': v:false})
let s:notexec = s:root .. '/tests/core-not-executable'
call writefile(['#!/nonexistent/interpreter', 'true'], s:notexec)
call setfperm(s:notexec, 'rwxr-xr-x')
let g:core_test_path = s:notexec
call assert_true(executable(s:notexec), 'the fixture is executable but cannot exec')
call s:C('Ensure')
call assert_true(s:Wait('!s:C("IsRunning")', 3000), 'a failed exec must not stay "running"')
call assert_false(s:C('Send', {'type': 'echo'}), 'Send must refuse a dead daemon')
call assert_false(s:C('Ready'), 'a dead daemon is never ready')
call delete(s:notexec)

" ------------------------------------------------------------- handshake ---

call s:Fresh({})
call assert_true(s:C('Ensure'), 'the fake daemon must start')
call assert_true(s:C('IsRunning'))
call assert_true(s:Wait('s:C("Ready")', 3000), 'handshake must complete')
call assert_equal(3, s:C('Protocol'))
call assert_true(s:C('HasCap', 'alpha'))
call assert_true(s:C('HasCap', 'beta'))
call assert_false(s:C('HasCap', 'gamma'))
call assert_equal(1, len(s:ready), 'OnReady fires exactly once per start')
call assert_equal(3, s:ready[0].proto)

" handshake.forward defaults to true, so the plugin still sees its own pong.
call assert_true(len(filter(copy(s:events), {_, e -> get(e, "type", "") ==# "pong"})) > 0,
      \ 'the handshake reply is forwarded to OnEvent')

" Ensure() on a live daemon is a no-op, not a second process.
let s:starts = s:C('Health').starts
call assert_true(s:C('Ensure'))
call assert_equal(s:starts, s:C('Health').starts)

" ------------------------------------------------------- request/response ---

let s:replies = []
function! CoreCollect(msg) abort
  call add(s:replies, a:msg)
endfunction

let s:id1 = s:C('Request', {'type': 'echo', 'v': 'one'}, function('g:CoreCollect'), -1)
let s:id2 = s:C('Request', {'type': 'echo', 'v': 'two'}, function('g:CoreCollect'), -1)
call assert_true(s:id1 > 0 && s:id2 > 0)
call assert_notequal(s:id1, s:id2, 'ids must be unique')
call assert_true(s:Wait('len(s:replies) >= 2', 3000), 'both replies must arrive')
" Replies are routed by id, never merged into the unsolicited event stream.
let s:by_id = {}
for s:r in s:replies
  let s:by_id[s:r.id] = s:r.v
endfor
call assert_equal('one', s:by_id[s:id1])
call assert_equal('two', s:by_id[s:id2])
call assert_equal(0, s:C('PendingCount'), 'answered requests are retired')

" A resolved request must not also reach OnEvent.
call assert_equal(0, len(filter(copy(s:events), {_, e -> get(e, "type", "") ==# "echo_result"})))

" ---------------------------------------------------------------- timeout ---

let s:replies = []
call s:C('Request', {'type': 'silent'}, function('g:CoreCollect'), 120)
call assert_equal(1, s:C('PendingCount'))
call assert_true(s:Wait('len(s:replies) >= 1', 3000), 'a silent daemon must still time out')
call assert_true(get(s:replies[0], '_timeout', v:false), 'the failure is reported as a timeout')
call assert_true(get(s:replies[0], '_failed', v:false))
call assert_equal(0, s:C('PendingCount'), 'timed-out requests are retired')

" Cancel() drops a request without firing its callback.
let s:replies = []
let s:cid = s:C('Request', {'type': 'silent'}, function('g:CoreCollect'), -1)
call assert_equal(1, s:C('PendingCount'))
call s:C('Cancel', s:cid)
call assert_equal(0, s:C('PendingCount'))
sleep 100m
call assert_equal(0, len(s:replies), 'a cancelled request never calls back')

" ------------------------------------------------------ unsolicited events ---

let s:events = []
call s:C('Send', {'type': 'emit', 'n': 3})
call assert_true(s:Wait('len(s:events) >= 3', 3000), 'unsolicited events reach OnEvent')
call assert_equal('tick', s:events[0].type)

" Output already in flight when the caller stops the daemon must not be
" dispatched: an explicit stop means the plugin has torn its state down and a
" late event would resurrect it.
call s:C('Send', {'type': 'emit', 'n': 200})
call s:C('Stop')
let s:events = []
sleep 300m
call assert_equal(0, len(s:events), 'queued output is fenced off by Stop()')
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000), 'the daemon restarts cleanly after the fence')

" Undecodable output is logged and skipped, never fatal.
call s:C('Send', {'type': 'garbage'})
sleep 100m
call assert_true(s:C('IsRunning'), 'a garbage line must not kill the supervisor')

" -------------------------------------------------------- pending on exit ---

" A daemon that dies mid-flight must fail its in-flight requests rather than
" strand the caller's callback forever.
let s:replies = []
call s:C('Request', {'type': 'silent'}, function('g:CoreCollect'), -1)
call assert_equal(1, s:C('PendingCount'))
call s:C('Send', {'type': 'crash', 'code': 3})
call assert_true(s:Wait('len(s:replies) >= 1', 3000), 'in-flight requests fail on exit')
call assert_true(get(s:replies[0], '_failed', v:false))
call assert_equal(0, s:C('PendingCount'))

" ----------------------------------------------------------- auto-restart ---

call s:Fresh({'backoff_min_ms': 20, 'backoff_max_ms': 40})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:pid_starts = s:C('Health').starts
call s:C('Send', {'type': 'crash', 'code': 7})
call assert_true(s:Wait('len(s:exits) >= 1', 3000), 'OnExit must fire')
call assert_equal(7, s:exits[0].code)
call assert_true(s:exits[0].restarting, 'an unexpected exit schedules a restart')
call assert_true(s:Wait('s:C("Ready")', 5000), 'the daemon comes back by itself')
call assert_true(s:C('Health').starts > s:pid_starts, 'a fresh process was started')
call assert_equal(1, s:C('Health').crashes)

" A deliberate Stop() is not a crash and must not trigger a restart.
let s:exits = []
call s:C('Stop')
call assert_true(s:Wait('len(s:exits) >= 1', 3000))
call assert_false(s:exits[0].restarting, 'Stop() must not schedule a restart')
sleep 200m
call assert_false(s:C('IsRunning'), 'a stopped daemon stays stopped')

" ------------------------------------------------------- circuit breaker ---

" A daemon that dies instantly on every start must not be respawned forever.
call s:Fresh({
      \ 'backoff_min_ms': 10,
      \ 'backoff_max_ms': 20,
      \ 'max_restarts': 3,
      \ 'restart_window_ms': 60000,
      \ 'stable_ms': 600000,
      \ 'env': {'FAKE_CRASH_AFTER': '10', 'FAKE_CRASH_CODE': '4'},
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Health").breaker_open', 8000), 'repeated crashes trip the breaker')
let s:tripped = s:C('Health')
call assert_true(s:tripped.crashes >= 3)
call assert_false(s:C('IsRunning'))
" Once tripped, Ensure() refuses rather than adding to the pile.
let s:crashes_at_trip = s:tripped.crashes
call assert_false(s:C('Ensure'), 'Ensure() is refused while the breaker is open')
sleep 300m
call assert_true(s:C('Health').crashes - s:crashes_at_trip <= 1,
      \ 'a tripped breaker stops the respawn loop')

" Restart() is an explicit user action: it clears the breaker and tries again.
call s:C('Configure', 'env', {})
call assert_true(s:C('Restart'))
call assert_true(s:Wait('s:C("Ready")', 5000), 'Restart() recovers from a tripped breaker')
call assert_false(s:C('Health').breaker_open)

" -------------------------------------------------------- generation guard ---

" Stop-then-start races: Vim reports the old job dead (job_status) before it
" delivers its exit_cb, so a replacement can already be live when the old
" callback finally lands.  That late callback must not touch the new job's
" state — the pre-core code cleared s_job/s_running unconditionally, which
" left the plugin convinced nothing was running.  Several tight cycles make
" landing inside that window near-certain.
call s:Fresh({'auto_restart': v:false, 'kill_after_ms': 0})
let s:cycle = 0
while s:cycle < 4
  call assert_true(s:C('Ensure'), 'cycle ' .. s:cycle .. ': daemon starts')
  call assert_true(s:Wait('s:C("Ready")', 3000), 'cycle ' .. s:cycle .. ': handshake')
  call s:C('Stop')
  call assert_true(s:Wait('!s:C("IsRunning")', 3000), 'cycle ' .. s:cycle .. ': stops')
  let s:cycle += 1
endwhile
call assert_true(s:C('Ensure'), 'a replacement starts right after the last stop')
call assert_true(s:Wait('s:C("Ready")', 3000), 'the replacement completes its handshake')
sleep 400m
call assert_true(s:C('IsRunning'), 'the late exit_cb must not kill the replacement')
let s:replies = []
call s:C('Request', {'type': 'echo', 'v': 'alive'}, function('g:CoreCollect'), 2000)
call assert_true(s:Wait('len(s:replies) >= 1', 3000))
call assert_equal('alive', get(s:replies[0], 'v', ''))

" ------------------------------------------------------------- raw codec ---

call s:Fresh({'codec': 'raw', 'handshake': {}})
call assert_true(s:C('Ensure'))
call s:C('Send', {'type': 'emit', 'n': 2})
call assert_true(s:Wait('len(s:lines) >= 2', 3000), 'raw codec delivers lines verbatim')
call assert_true(s:lines[0] =~# '"type"', 'raw lines are not decoded')
call assert_equal(0, len(s:events), 'raw codec bypasses OnEvent')
" A string payload is written through untouched (with a trailing newline).
call assert_true(s:C('Send', "{\"type\":\"emit\",\"n\":1}"))

" --------------------------------------------------------------- health ---

call s:Fresh({})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:h = s:C('Health')
call assert_equal('CoreTest', s:h.name)
call assert_true(s:h.running)
call assert_true(s:h.ready)
call assert_equal(3, s:h.protocol)
call assert_true(s:h.uptime_ms >= 0)
call assert_false(s:h.breaker_open)
let s:hl = s:C('HealthLines')
call assert_true(len(s:hl) >= 2)
call assert_true(s:hl[0] =~# '^\[OK\] daemon: ')
call assert_true(s:hl[1] =~# 'ready')
call assert_true(len(s:C('LogLines')) > 0, 'the log ring buffer records lifecycle events')

call s:C('Stop')
sleep 100m
let s:h = s:C('Health')
call assert_false(s:h.running)
call assert_true(s:C('HealthLines')[0] =~# '^\[ERROR\]')

call s:C('ResetForTest')

if len(v:errors)
  call writefile(v:errors, s:root .. '/tests/core-errors.log')
  for s:e in v:errors
    echomsg s:e
  endfor
  cquit
endif
qall!
