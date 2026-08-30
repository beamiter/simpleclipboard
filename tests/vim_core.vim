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
let s:stderr = []
let s:startups = []
let s:order = []
let s:retry_results = []

function! CoreOnEvent(msg) abort
  call add(s:events, a:msg)
endfunction
function! CoreOnLine(line) abort
  call add(s:lines, a:line)
endfunction
function! CoreOnReady(proto, caps) abort
  call add(s:ready, {'proto': a:proto, 'caps': a:caps})
  call add(s:order, 'ready')
endfunction
function! CoreOnStart() abort
  call add(s:startups, {'ready': s:C('Ready'), 'proto': s:C('Protocol')})
  call add(s:order, 'start')
endfunction
function! CoreOnStderr(line) abort
  call add(s:stderr, a:line)
endfunction
function! CoreThrowingOnEvent(msg) abort
  call add(s:events, a:msg)
  throw 'plugin bug in OnEvent'
endfunction
function! CoreThrowingOnReady(proto, caps) abort
  call add(s:ready, {'proto': a:proto, 'caps': a:caps})
  throw 'plugin bug in OnReady'
endfunction
function! CoreOnExit(code, restarting) abort
  call add(s:exits, {'code': a:code, 'restarting': a:restarting})
endfunction
function! CoreStopOnReady(proto, caps) abort
  call add(s:ready, {'proto': a:proto, 'caps': a:caps})
  call s:C('Stop')
endfunction
function! CoreStopOnExit(code, restarting) abort
  call add(s:exits, {'code': a:code, 'restarting': a:restarting})
  call s:C('Stop')
endfunction
function! CoreRetryAfterExit(msg) abort
  call add(s:retry_results, {
        \ 'failed': get(a:msg, '_failed', v:false),
        \ 'ensure': s:C('Ensure'),
        \ })
endfunction

function! s:Fresh(overrides) abort
  call s:C('ResetForTest')
  let s:events = []
  let s:lines = []
  let s:ready = []
  let s:exits = []
  let s:stderr = []
  let s:startups = []
  let s:order = []
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
        \ 'OnStart': function('g:CoreOnStart'),
        \ 'OnStderr': function('g:CoreOnStderr'),
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
" must converge to not-running, tell the plugin, and stop accepting writes —
" the old bug was a cached `running` flag that stayed true for the rest of the
" session.
"
" Ensure()'s `job_status(started) !=# 'run'` guard is NOT what does that here,
" and this section used to be written as though it were.  On Unix job_start()
" cannot report an exec failure synchronously: it forks, and the child does not
" reach execvp() until after job_start() has returned, so job_status() answers
" 'run' for a missing binary, a bad interpreter line and a non-ELF file alike
" (measured on Vim 9.2; 'fail' is reachable only where the platform fails the
" spawn itself, i.e. a CreateProcess error on Windows or a failed fork()).  The
" guard is kept for those platforms, but nothing on this one can delete it and
" be caught, so the assertions below pin what is actually observable: the
" failure is asynchronous, and it has to arrive.
call s:Fresh({'auto_restart': v:false})
let s:notexec = s:root .. '/tests/core-not-executable'
call writefile(['#!/nonexistent/interpreter', 'true'], s:notexec)
call setfperm(s:notexec, 'rwxr-xr-x')
let g:core_test_path = s:notexec
call assert_true(executable(s:notexec), 'the fixture is executable but cannot exec')
call s:C('Ensure')
call assert_true(s:Wait('!s:C("IsRunning")', 3000), 'a failed exec must not stay "running"')
call assert_true(len(s:exits) >= 1,
      \ 'OnExit fires: a caller that gated on Ensure() has to learn the start died')
call assert_equal(1, s:C('Health').crashes,
      \ 'and it is counted as a crash, which is what eventually trips the breaker')
call assert_match('exited unexpectedly', s:C('Health').last_error,
      \ 'the asynchronous failure remains visible through Health()')
call assert_false(s:C('Send', {'type': 'echo'}), 'Send must refuse a dead daemon')
call assert_false(s:C('Ready'), 'a dead daemon is never ready')
call assert_false(s:C('Negotiated'))
call assert_true(s:C('HealthLines')[0] =~# '^\[ERROR\]',
      \ 'and the health report leads with the failure, not with [OK]')
call delete(s:notexec)

" The same guard, in the window it actually exists for.  A daemon that dies
" while Vim is inside a synchronous stretch — a plugin scanning a buffer, a
" user leaning on a key — delivers no callback at all until Vim next idles, but
" job_status() knows the moment anyone asks, because IsRunning() re-queries it
" instead of watching s_job.  A cached-handle version (`return s_job !=
" null_job`) answers "running" for the whole of that window and converges only
" when exit_cb finally runs — and every wait in this file is written so that
" convergence satisfies it.  In the window itself Ensure() then short-circuits
" and hands a caller true and no daemon, which is the bug the guard is for.
call s:Fresh({'auto_restart': v:false})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
call s:C('Send', {'type': 'crash', 'code': 5})
let s:blocked = reltime()
while reltimefloat(reltime(s:blocked)) < 0.4
endwhile
call assert_false(s:C('IsRunning'),
      \ 'job_status() reports the death without waiting for exit_cb')
call assert_false(s:C('Ready'), 'and nothing is ready in that window')
let s:starts_in_window = s:C('Health').starts
call assert_true(s:C('Ensure'), 'Ensure() in that window answers true')
call assert_equal(s:starts_in_window + 1, s:C('Health').starts,
      \ 'and it is true because a process was started, not because a handle was stale')
call assert_true(s:Wait('s:C("Ready")', 3000))
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" ------------------------------------------------------ executable lookup ---

" Every start in this file sets path_var, so FindExe() returned from its first
" branch every time and nothing below it was ever taken.  The runtimepath/lib
" branch is the one every *installed* plugin uses: install-common.sh puts the
" daemon at lib/<exe> inside the plugin directory, and nothing else finds it
" for a user who never set g:<plugin>_daemon_path.  Deleting that loop outright
" left core-verify, defcompile and this suite green in all ten carriers.
call s:Fresh({})
let g:core_test_path = ''
let s:lookup = s:root .. '/tests/lookup'
call mkdir(s:lookup .. '/lib', 'p')
call mkdir(s:lookup .. '/target/debug', 'p')
call mkdir(s:lookup .. '/bin', 'p')
let s:lib_exe = s:lookup .. '/lib/fake_daemon.py'
let s:dev_exe = s:lookup .. '/target/debug/fake_daemon.py'
let s:path_exe = s:lookup .. '/bin/fake_daemon.py'
for s:copy in [s:lib_exe, s:dev_exe, s:path_exe]
  call writefile(readfile(s:fake), s:copy)
  call setfperm(s:copy, 'rwxr-xr-x')
endfor
let s:saved_rtp = &runtimepath
let s:saved_path = $PATH
execute 'set runtimepath^=' .. fnameescape(s:lookup)
let $PATH = s:lookup .. '/bin:' .. s:saved_path

call assert_equal(s:lib_exe, s:C('FindExe'),
      \ 'an installed daemon is found under runtimepath/lib')
call assert_true(s:C('Ensure'), 'and the supervisor starts it from there')
call assert_equal(s:lib_exe, s:C('ExePath'))
call assert_true(s:Wait('s:C("Ready")', 3000), 'a lib/ daemon handshakes like any other')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" Order matters as much as presence: an installed daemon outranks a stale cargo
" build in the same checkout, and both outrank whatever is on $PATH.
call delete(s:lib_exe)
call assert_equal(s:dev_exe, s:C('FindExe'),
      \ 'with no installed copy the dev build is the fallback')
call delete(s:dev_exe)
call assert_equal(s:path_exe, s:C('FindExe'), 'and $PATH is the last resort')
let $PATH = s:saved_path
let &runtimepath = s:saved_rtp
call delete(s:path_exe)
call delete(s:lookup .. '/lib', 'd')
call delete(s:lookup .. '/target/debug', 'd')
call delete(s:lookup .. '/target', 'd')
call delete(s:lookup .. '/bin', 'd')
call delete(s:lookup, 'd')

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
call assert_true(s:C('Negotiated'))
call s:C('Configure', 'handshake', {})
call assert_true(s:C('Negotiated'),
      \ 'changing config cannot erase a handshake completed by this generation')
call assert_true(s:C('Health').handshake_expected)

" handshake.forward defaults to true, so the plugin still sees its own pong.
call assert_true(len(filter(copy(s:events), {_, e -> get(e, "type", "") ==# "pong"})) > 0,
      \ 'the handshake reply is forwarded to OnEvent')

" Ensure() on a live daemon is a no-op, not a second process.
let s:starts = s:C('Health').starts
call assert_true(s:C('Ensure'))
call assert_equal(s:starts, s:C('Health').starts)

" handshake.forward:false is the documented way for a plugin to keep its own
" pong out of its OnEvent dispatcher.  Nothing ever configured it, so deleting
" the branch that honours it — forwarding every pong — was invisible.
call s:Fresh({'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong',
      \ 'forward': v:false}})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
call assert_equal(3, s:C('Protocol'), 'the reply is still consumed')
call assert_equal(0,
      \ len(filter(copy(s:events), {_, e -> get(e, 'type', '') ==# 'pong'})),
      \ 'but forward:false keeps it out of OnEvent')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" proto_key/caps_key exist for a daemon that reports under its own field names.
" The fixture emits *only* those names here, so a core that reads a hardcoded
" protocol_version finds no version, calls the handshake invalid and fails the
" start — which is what a plugin with a renamed field would have suffered.
call s:Fresh({
      \ 'env': {'FAKE_PROTO_KEY': 'ver', 'FAKE_CAPS_KEY': 'features'},
      \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong',
      \               'proto_key': 'ver', 'caps_key': 'features'},
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000), 'a renamed version field still negotiates')
call assert_equal(3, s:C('Protocol'))
call assert_true(s:C('HasCap', 'alpha'), 'and a renamed capability field is read too')
call assert_true(s:C('Negotiated'))
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" OnReady is allowed to synchronously stop the daemon.  Once it does, the
" handshake pong belongs to a stopping generation and must not leak through a
" second callback as an ordinary event.
call s:Fresh({'auto_restart': v:false,
      \ 'OnReady': function('g:CoreStopOnReady')})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('len(s:ready) == 1', 3000), 'the stopping OnReady callback runs')
call assert_true(s:Wait('!s:C("IsRunning")', 3000), 'OnReady can stop the process')
call assert_equal(0,
      \ len(filter(copy(s:events), {_, e -> get(e, 'type', '') ==# 'pong'})),
      \ 'a pong is not forwarded after OnReady stopped its generation')

" The request tests below share one ordinary, negotiated daemon.
call s:Fresh({})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))

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

" Caller-supplied ids cannot replace an in-flight callback. The second request
" is assigned a fresh id, and both replies still reach their owners.
let s:replies = []
let s:duplicate1 = s:C('Request',
      \ {'type': 'slow', 'id': 77, 'v': 'first', 'ms': 120},
      \ function('g:CoreCollect'), -1)
let s:duplicate2 = s:C('Request',
      \ {'type': 'echo', 'id': 77, 'v': 'second'},
      \ function('g:CoreCollect'), -1)
call assert_equal(77, s:duplicate1)
call assert_notequal(77, s:duplicate2, 'a pending id is never overwritten')
call assert_true(s:Wait('len(s:replies) >= 2', 3000))
call assert_equal(['first', 'second'], sort(map(copy(s:replies), {_, r -> r.v})))
call assert_equal(0, s:C('PendingCount'))

" Routing is by id, and nothing above proves it.  Every request in this file
" shared one callback, and the assertions keyed on the reply's own `id` field —
" which fake_daemon.py echoes back from the request.  That proves the daemon
" echoed the id, not that the supervisor routed by it: a ResolvePending() that
" ignored its id argument and answered whichever request was newest passed the
" whole suite.
"
" Three things are needed to see it.  Distinct callbacks, so "who was called"
" is observable at all.  Replies that do not arrive in request order, which is
" why `slow` answers on a thread — with a single-threaded fixture every reply
" arrives in request order and arrival-order routing is indistinguishable from
" correct routing.  And the *middle* request answering first: answering in
" reverse order would make "always the newest" right by accident, exactly as
" answering in order makes "always the oldest" right by accident.
let s:got_a = []
let s:got_b = []
let s:got_c = []
let s:arrivals = []
function! CoreCbA(msg) abort
  call add(s:got_a, get(a:msg, 'v', ''))
  call add(s:arrivals, 'A')
endfunction
function! CoreCbB(msg) abort
  call add(s:got_b, get(a:msg, 'v', ''))
  call add(s:arrivals, 'B')
endfunction
function! CoreCbC(msg) abort
  call add(s:got_c, get(a:msg, 'v', ''))
  call add(s:arrivals, 'C')
endfunction
let s:id_a = s:C('Request', {'type': 'slow', 'ms': 250, 'v': 'for-A'},
      \ function('g:CoreCbA'), -1)
let s:id_b = s:C('Request', {'type': 'slow', 'ms': 80, 'v': 'for-B'},
      \ function('g:CoreCbB'), -1)
let s:id_c = s:C('Request', {'type': 'slow', 'ms': 450, 'v': 'for-C'},
      \ function('g:CoreCbC'), -1)
call assert_true(s:id_a > 0 && s:id_b > s:id_a && s:id_c > s:id_b,
      \ 'ids are handed out in request order')
call assert_true(s:Wait('len(s:arrivals) >= 3', 6000), 'all three replies arrive')
call assert_equal(['B', 'A', 'C'], s:arrivals,
      \ 'the middle request answers first, which is what gives this block its teeth')
call assert_equal(['for-A'], s:got_a, 'each caller gets its own answer, not another one')
call assert_equal(['for-B'], s:got_b)
call assert_equal(['for-C'], s:got_c)
call assert_equal(0, s:C('PendingCount'))

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
"
" The daemon has to outlive the stop for that to be under test.  A daemon that
" dies on SIGTERM takes its unread output down with it, and then no event
" arrives whether the s_stopping fence is there or not — the assertion measures
" the kill, not the fence, and stays green with the fence deleted.
" FAKE_IGNORE_TERM plus kill_after_ms:0 holds the channel open with 200 lines
" already queued on it and s_stopping set, which is the only state the fence is
" about.
call s:Fresh({'auto_restart': v:false, 'kill_after_ms': 0,
      \ 'env': {'FAKE_IGNORE_TERM': '1'}})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000), 'the TERM-proof fixture handshakes normally')
call s:C('Send', {'type': 'emit', 'n': 200})
let s:replies = []
call s:C('Request', {'type': 'silent'}, function('g:CoreCollect'), -1)
call assert_equal(1, s:C('PendingCount'))
call s:C('Stop')
call assert_true(s:C('IsRunning'), 'the fixture ignores SIGTERM, so the channel is still open')
call assert_false(s:C('Ready'), 'a stopping daemon is never exposed as ready')
call assert_true(s:C('Health').stopping)
call assert_false(s:C('Health').ready)
call assert_true(s:C('HealthLines')[1] =~# 'stopping')
call assert_equal(0, s:C('PendingCount'), 'Stop immediately retires pending requests')
call assert_equal(1, len(s:replies))
call assert_true(get(s:replies[0], '_failed', v:false))
call assert_false(s:C('Send', {'type': 'echo'}), 'Send rejects a stopping daemon')
call assert_equal(0, s:C('Request', {'type': 'echo'}, function('g:CoreCollect'), -1),
      \ 'Request reports immediate failure while Stop is in flight')
call assert_equal(0, s:C('PendingCount'))
let s:events = []
sleep 300m
call assert_equal(0, len(s:events), 'queued output is fenced off by Stop()')
call assert_true(s:C('IsRunning'),
      \ 'and the fence is what dropped it — the daemon is still alive and still writing')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000), 'SIGKILL finishes what SIGTERM would not')
call assert_true(s:C('Ensure'), 'the supervisor starts again after a fenced stop')
call assert_true(s:Wait('s:C("Ready")', 3000), 'and the replacement handshakes normally')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" Undecodable output is logged and skipped, never fatal.
call s:Fresh({})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
call s:C('Send', {'type': 'garbage'})
sleep 100m
call assert_true(s:C('IsRunning'), 'a garbage line must not kill the supervisor')

" ------------------------------------------------- callback containment ---

" A callback is plugin code, and plugin code throws.  core.vim wraps every
" configured callback so a throwing OnEvent cannot leave the job unmanaged —
" and no callback in this file ever threw, so removing the wrapper left the
" suite green.  In a real session the exception escapes the channel callback
" and takes the sourcing script down with it, which is what "documented as real
" and compiled away" looks like in Vim script.
call s:Fresh({'OnEvent': function('g:CoreThrowingOnEvent')})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000), 'a throwing OnEvent still sees the pong')
let s:events = []
call s:C('Send', {'type': 'emit', 'n': 5})
call assert_true(s:Wait('len(s:events) >= 5', 3000), 'every event is still delivered')
call assert_true(s:C('IsRunning'), 'and the supervisor survives all five throws')
call assert_equal(0, s:C('PendingCount'))
call assert_true(len(filter(copy(s:C('LogLines')), {_, l -> l =~# 'OnEvent threw'})) >= 5,
      \ 'the catch arm records what it swallowed, so the plugin bug stays findable')
" A later, well-behaved handler still gets its events: nothing was unhooked.
call s:C('Configure', 'OnEvent', function('g:CoreOnEvent'))
let s:events = []
call s:C('Send', {'type': 'emit', 'n': 2})
call assert_true(s:Wait('len(s:events) >= 2', 3000),
      \ 'the event stream is intact after a callback threw')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" OnReady throws on the handshake path rather than the event path, and that
" path has more state to corrupt: the negotiation is complete but the forward
" to OnEvent has not happened yet.
call s:Fresh({'OnReady': function('g:CoreThrowingOnReady')})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('len(s:ready) == 1', 3000), 'the throwing OnReady runs')
call assert_true(s:C('IsRunning'), 'the daemon it threw out of is still managed')
call assert_true(s:C('Ready'), 'and the handshake it threw out of still completed')
call assert_true(s:C('Negotiated'))
call assert_true(len(filter(copy(s:C('LogLines')), {_, l -> l =~# 'OnReady threw'})) > 0)
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" ----------------------------------------------------- OnStart / OnStderr ---

" Neither was ever configured here, so err_cb was never invoked at all and
" three separate deletions inside it — the OnStart fire, the OnStderr fire, and
" err_cb's own copy of the stopping fence — were each individually invisible.
" OnStart is live production code in simpletree, simpletreesitter and
" simplefinder; OnStderr is in simplecc.
call s:Fresh({})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
call assert_equal(1, len(s:startups), 'OnStart fires exactly once per start')
call assert_equal(['start', 'ready'], s:order,
      \ 'and before OnReady: it is the cue to prepare for a handshake, not its result')
call assert_false(s:startups[0].ready, 'nothing is ready when OnStart runs')
call assert_equal(0, s:startups[0].proto)

call s:C('Send', {'type': 'stderr', 'v': 'daemon-said-this'})
call assert_true(s:Wait('len(s:stderr) >= 1', 3000), 'a stderr line reaches OnStderr')
call assert_equal('daemon-said-this', s:stderr[0])
call assert_true(len(filter(copy(s:C('LogLines')),
      \ {_, l -> l =~# 'stderr: daemon-said-this'})) > 0,
      \ 'and lands in the log the user is asked to quote')
call assert_equal(0,
      \ len(filter(copy(s:events), {_, e -> get(e, 'type', '') ==# 'stderr'})),
      \ 'stderr never enters the decoded event stream')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" err_cb carries its own copy of the stopping fence, and the out_cb test above
" does not cover it: stderr already on the wire when the caller stops the
" daemon has to be dropped for the same reason stdout is.
call s:Fresh({'auto_restart': v:false, 'kill_after_ms': 0,
      \ 'env': {'FAKE_IGNORE_TERM': '1'}})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
call s:C('Send', {'type': 'stderr', 'v': 'queued-before-stop', 'n': 200})
call s:C('Stop')
call assert_true(s:C('IsRunning'), 'the fixture ignores SIGTERM, so it is still writing')
let s:stderr = []
sleep 300m
call assert_equal(0, len(s:stderr), 'queued stderr is fenced off by Stop() too')
call assert_true(s:C('IsRunning'),
      \ 'and the fence is what dropped it — the daemon is alive and still writing')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" -------------------------------------------------------- pending on exit ---

" A daemon that dies mid-flight must fail its in-flight requests rather than
" strand the caller's callback forever.
call s:Fresh({})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:replies = []
call s:C('Request', {'type': 'silent'}, function('g:CoreCollect'), -1)
call assert_equal(1, s:C('PendingCount'))
call s:C('Send', {'type': 'crash', 'code': 3})
call assert_true(s:Wait('len(s:replies) >= 1', 3000), 'in-flight requests fail on exit')
call assert_true(get(s:replies[0], '_failed', v:false))
call assert_equal(0, s:C('PendingCount'))

" ------------------------------------------- a handshake that never lands ---

" `timeout_ms` is documented as a deadline whose expiry fails the start.  It
" used to arm a timer whose whole body was one WarningMsg: the daemon kept
" running, s_ready stayed false for the life of the session, every gated
" feature degraded in silence, and HealthLines()[0] still answered
" `[OK] daemon: …` because it keys on running, not ready.  `quiet: true`
" suppressed even the warning.  FAKE_NO_PONG is the fixture knob built for
" this case, and until now no test in any of the plugins referenced it.
call s:Fresh({
      \ 'auto_restart': v:false,
      \ 'env': {'FAKE_NO_PONG': '1'},
      \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong', 'timeout_ms': 200},
      \ })
let s:deadline_armed = reltime()
call assert_true(s:C('Ensure'), 'the daemon starts; it simply never answers')
call assert_true(s:C('IsRunning'))
call assert_false(s:C('Ready'), 'nothing is ready before the pong')
call assert_true(s:Wait('!s:C("IsRunning")', 3000),
      \ 'a missed handshake deadline fails the start instead of parking on it forever')
call assert_true(reltimefloat(reltime(s:deadline_armed)) < 1.0,
      \ 'and it fails at its deadline rather than being extended indefinitely')
call assert_false(s:C('Ready'))
call assert_false(s:C('Negotiated'))
call assert_match('handshake', s:C('Health').last_error,
      \ 'the reason is recorded, not echoed once and lost')
call assert_equal(1, s:C('Health').crashes, 'a failed start is counted as one')
call assert_true(len(s:exits) >= 1, 'OnExit fires, so the plugin can tear its state down')
call assert_false(s:exits[0].restarting, 'auto_restart:false means no restart')
call assert_true(s:C('HealthLines')[0] =~# '^\[ERROR\]',
      \ 'the health report must not answer [OK] for a start that failed')

" A reply with the right id/type is not sufficient: accepting malformed
" protocol metadata would mark an incompatible daemon ready and disable the
" deadline. Both malformed fields fail the start immediately.
for s:bad_pong in ['id', 'type', 'protocol', 'capabilities', 'burst']
  call s:Fresh({
        \ 'auto_restart': v:false,
        \ 'env': {'FAKE_BAD_PONG': s:bad_pong},
        \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong', 'timeout_ms': 200},
        \ })
  call assert_true(s:C('Ensure'))
  call assert_true(s:Wait('!s:C("IsRunning")', 3000),
        \ 'a malformed ' .. s:bad_pong .. ' reply fails the start')
  call assert_false(s:C('Ready'))
  call assert_false(s:C('Negotiated'))
  call assert_equal([], s:ready,
        \ 'queued output cannot resurrect a failed ' .. s:bad_pong .. ' handshake')
  call assert_match('handshake', s:C('Health').last_error)
  call assert_equal(1, s:C('Health').crashes)
endfor

" With auto_restart on, a daemon that never handshakes is a crash loop and the
" breaker has to catch it.  stable_ms is deliberately shorter than the deadline
" here: without the handshake-failure exemption in OnExit() every attempt would
" look "stable", reset the backoff, and respawn a mute daemon for ever.
call s:Fresh({
      \ 'backoff_min_ms': 10,
      \ 'backoff_max_ms': 20,
      \ 'max_restarts': 2,
      \ 'restart_window_ms': 60000,
      \ 'stable_ms': 50,
      \ 'env': {'FAKE_NO_PONG': '1'},
      \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong', 'timeout_ms': 150},
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Health").breaker_open', 8000),
      \ 'a daemon that never handshakes trips the breaker instead of running mute')
call assert_false(s:C('IsRunning'))

" A daemon may die on its own before the handshake deadline. Uptime alone must
" not forgive those crashes: it was never ready, so repeated starts still trip
" the breaker even when each process outlives stable_ms.
call s:Fresh({
      \ 'backoff_min_ms': 10,
      \ 'backoff_max_ms': 20,
      \ 'max_restarts': 2,
      \ 'restart_window_ms': 60000,
      \ 'stable_ms': 50,
      \ 'env': {'FAKE_NO_PONG': '1', 'FAKE_CRASH_AFTER': '100'},
      \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong', 'timeout_ms': 1000},
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Health").breaker_open', 5000),
      \ 'never-ready self-exits cannot reset the crash history')
call assert_false(s:C('IsRunning'))

" timeout_ms:0 disables the deadline, which is a different promise, not the
" same one: the daemon stays up and stays un-negotiated, and the report says so.
call s:Fresh({
      \ 'auto_restart': v:false,
      \ 'env': {'FAKE_NO_PONG': '1'},
      \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong', 'timeout_ms': 0},
      \ })
call assert_true(s:C('Ensure'))
let s:replies = []
let s:handshake_collision = s:C('Request',
      \ {'type': 'echo', 'id': 1, 'v': 'handshake-id'},
      \ function('g:CoreCollect'), -1)
call assert_notequal(1, s:handshake_collision,
      \ 'an in-flight handshake id is reserved from ordinary requests')
call assert_true(s:Wait('len(s:replies) == 1', 3000))
call assert_equal('handshake-id', s:replies[0].v)
sleep 300m
call assert_true(s:C('IsRunning'), 'timeout_ms:0 means no deadline')
call assert_false(s:C('Ready'), 'but nothing was negotiated, so nothing is ready')
call assert_true(s:C('HealthLines')[1] =~# 'handshake pending',
      \ 'and the state line says which of the two it is')
call s:C('Stop')
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" ----------------------------------- a deadline Vim itself made expire ---

" timeout_ms is a claim about the daemon, but a timer measures Vim.  Timers and
" channel callbacks are serviced at the same idle points, so any synchronous
" stretch longer than the deadline — a plugin scanning a large buffer, a user
" leaning on a key — leaves an already-delivered pong sitting on the channel
" behind an already-expired timer, and whichever Vim runs first decides whether
" a healthy daemon is killed.  The shipped core killed it and recorded 'daemon
" did not answer the handshake within 200ms' about a daemon that had answered
" in single-digit milliseconds; the !s_handshake_failed fence then dropped the
" pong that was there all along, so it could not recover, and with auto_restart
" on every retry was another crash until the breaker opened.
"
" ch_canread() cannot arbitrate this — measured false in exactly this window,
" because the reply is still in the kernel pipe Vim never got round to reading.
" The timer's own lateness can, and that is what core.vim now keys on.
call s:Fresh({
      \ 'auto_restart': v:false,
      \ 'handshake': {'request': {'type': 'ping'}, 'reply_type': 'pong', 'timeout_ms': 200},
      \ })
call assert_true(s:C('Ensure'))
let s:blocked = reltime()
while reltimefloat(reltime(s:blocked)) < 0.7
endwhile
call assert_true(s:Wait('s:C("Ready")', 3000),
      \ 'a pong that was on the wire all along completes the handshake')
call assert_true(s:C('IsRunning'),
      \ 'the daemon that answered on time is not killed for Vim being busy')
call assert_equal(3, s:C('Protocol'))
call assert_equal(1, len(s:ready), 'and OnReady fires, once')
call assert_equal(0, s:C('Health').crashes, 'no crash is invented')
call assert_equal('', s:C('Health').last_error,
      \ 'and nothing false is recorded: ' .. s:C('Health').last_error)
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

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

" OnExit runs before an automatic restart is committed.  Stop() from inside
" that callback is an explicit veto, not a request that a later-created timer
" may silently undo.
call s:Fresh({
      \ 'backoff_min_ms': 20,
      \ 'backoff_max_ms': 40,
      \ 'OnExit': function('g:CoreStopOnExit'),
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:starts_before_exit_veto = s:C('Health').starts
call s:C('Send', {'type': 'crash', 'code': 8})
call assert_true(s:Wait('len(s:exits) == 1', 3000))
call assert_true(s:exits[0].restarting, 'the callback sees the restart candidate')
sleep 200m
call assert_equal(s:starts_before_exit_veto, s:C('Health').starts,
      \ 'Stop() in OnExit cancels an automatic replacement')
call assert_false(s:C('IsRunning'))

" The same veto applies to the zero-delay replacement requested by Restart().
call s:Fresh({'auto_restart': v:false,
      \ 'OnExit': function('g:CoreStopOnExit')})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:starts_before_manual_veto = s:C('Health').starts
call assert_true(s:C('Restart'))
call assert_true(s:Wait('len(s:exits) == 1', 3000))
call assert_true(s:exits[0].restarting)
sleep 200m
call assert_equal(s:starts_before_manual_veto, s:C('Health').starts,
      \ 'Stop() in OnExit cancels a manual replacement')
call assert_false(s:C('IsRunning'))

" Restart waits for the old generation's real exit. A one-shot zero-delay
" poll loses the request when a daemon ignores SIGTERM until the kill timer.
call s:Fresh({'auto_restart': v:false, 'kill_after_ms': 100,
      \ 'env': {'FAKE_IGNORE_TERM': '1'}})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:starts_before_manual_restart = s:C('Health').starts
call assert_true(s:C('Restart'))
call assert_false(s:C('Ready'))
call assert_true(s:Wait(
      \ 's:C("Health").starts > s:starts_before_manual_restart && s:C("Ready")',
      \ 5000), 'manual restart starts a replacement after delayed exit')
call assert_true(len(s:exits) >= 1)
call assert_true(s:exits[0].restarting,
      \ 'OnExit reports that a manual replacement is pending')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" ------------------------------------------------------- restart backoff ---

" backoff_min_ms, backoff_max_ms, stable_ms and restart_window_ms were passed
" into six configurations above and below without a single assertion on a
" timing consequence of any of them: NextBackoff() could return a constant 0
" for ever and every one of those blocks still held.  These three pin the
" policy itself.
"
" With min 200 and max 400 the delays are 200, 400, 400, 400, so five starts
" cannot arrive sooner than 1400ms — which kills a backoff that does not grow,
" and one that ignores backoff_min_ms — and cannot take much longer, which
" kills a backoff that doubles past its ceiling (200+400+800+1600 = 3000ms).
call s:Fresh({
      \ 'backoff_min_ms': 200,
      \ 'backoff_max_ms': 400,
      \ 'max_restarts': 8,
      \ 'restart_window_ms': 60000,
      \ 'stable_ms': 600000,
      \ 'env': {'FAKE_CRASH_AFTER': '10'},
      \ })
let s:backoff_at = reltime()
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Health").starts >= 5', 12000),
      \ 'a daemon that dies instantly is restarted until the breaker stops it')
let s:backoff_ms = float2nr(reltimefloat(reltime(s:backoff_at)) * 1000)
call assert_true(s:backoff_ms >= 1400,
      \ printf('four restarts wait 200+400+400+400ms, not less (%dms)', s:backoff_ms))
call assert_true(s:backoff_ms < 2800,
      \ printf('and backoff_max_ms stops the doubling (%dms)', s:backoff_ms))
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" stable_ms is what keeps a long-lived session from slowly tripping its own
" breaker.  Only its two exemptions were pinned — a start that was never ready,
" and one killed for missing its handshake — so deleting the rule itself was
" green.  Here every process is ready and outlives stable_ms before it dies, so
" each crash is forgiven and a budget of one crash is never exceeded.
call s:Fresh({
      \ 'backoff_min_ms': 100,
      \ 'backoff_max_ms': 100,
      \ 'max_restarts': 1,
      \ 'restart_window_ms': 60000,
      \ 'stable_ms': 150,
      \ 'env': {'FAKE_CRASH_AFTER': '400'},
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Health").crashes >= 3', 8000),
      \ 'a daemon that keeps dying after a stable run keeps being restarted')
call assert_false(s:C('Health').breaker_open,
      \ 'uptime past stable_ms forgives the crash history that ended it')
call assert_true(s:Wait('s:C("Ready")', 5000), 'and the daemon is back')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" restart_window_ms is the other half: crashes older than the window stop
" counting, so a daemon that dies once an hour never accumulates into a tripped
" breaker.  Every other configuration in this file uses a 60s window inside a
" run of a few seconds, where the pruning cannot fire — deleting it was green.
" A 300ms window against a >400ms cycle puts each crash outside the next one's
" window.
call s:Fresh({
      \ 'backoff_min_ms': 400,
      \ 'backoff_max_ms': 400,
      \ 'max_restarts': 1,
      \ 'restart_window_ms': 300,
      \ 'stable_ms': 600000,
      \ 'env': {'FAKE_CRASH_AFTER': '10'},
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Health").crashes >= 3', 8000),
      \ 'crashes spaced further apart than the window never accumulate')
call assert_false(s:C('Health').breaker_open,
      \ 'which is the whole purpose of restart_window_ms')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" ------------------------------------------------------- circuit breaker ---

" Crash accounting must precede pending-request callbacks.  With a zero-crash
" budget, a callback that immediately retries should see the freshly opened
" breaker instead of starting a process that Health() simultaneously calls
" tripped.
let s:retry_results = []
call s:Fresh({
      \ 'max_restarts': 0,
      \ 'restart_window_ms': 60000,
      \ })
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
call s:C('Request', {'type': 'silent'}, function('g:CoreRetryAfterExit'), -1)
call assert_equal(1, s:C('PendingCount'))
call s:C('Send', {'type': 'crash', 'code': 6})
call assert_true(s:Wait('len(s:retry_results) == 1', 3000))
call assert_true(s:retry_results[0].failed)
call assert_false(s:retry_results[0].ensure,
      \ 'a pending callback cannot retry before this crash opens the breaker')
sleep 100m
let s:retry_health = s:C('Health')
call assert_true(s:retry_health.breaker_open)
call assert_false(s:retry_health.running)
call assert_equal(1, s:retry_health.starts)

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

" The other half of "two fences, not one": a superseded job with output still
" on the wire.  This read as unreachable — Ensure() short-circuits while the
" old job is alive — until you notice how a daemon dies during a synchronous
" stretch.  job_status() reports it dead the instant anyone asks, so the
" replacement starts before Vim has read a single line the dead job already
" wrote.  s_stopping is false throughout, so nothing but the generation check
" keeps those lines out of the replacement's OnEvent.
call s:Fresh({'auto_restart': v:false})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:events = []
call s:C('Send', {'type': 'emit', 'n': 200})
call s:C('Send', {'type': 'crash', 'code': 0})
let s:blocked = reltime()
while reltimefloat(reltime(s:blocked)) < 0.4
endwhile
call assert_false(s:C('IsRunning'), 'the daemon is gone')
call assert_equal(0, len(s:events), 'and Vim has not read a line of its output yet')
let s:starts_before_replacement = s:C('Health').starts
call assert_true(s:C('Ensure'), 'so the replacement starts on top of the unread output')
call assert_equal(s:starts_before_replacement + 1, s:C('Health').starts)
call assert_true(s:Wait('s:C("Ready")', 3000), 'the replacement handshakes')
sleep 300m
call assert_equal(0,
      \ len(filter(copy(s:events), {_, e -> get(e, 'type', '') ==# 'tick'})),
      \ 'the dead generation output never reaches the replacement OnEvent')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" --------------------------------------------- Ensure() while stopping ---

" Stop() keeps the job until its exit callback runs, so there is a window in
" which the daemon is alive, s_stopping is set, and nothing is staged to
" replace it.  Every other "Ensure after Stop" in this file first waits for
" !IsRunning(), so the window itself was never tested — which is how a version
" of Ensure() that answered false inside it shipped to ten plugins whose
" callers are all shaped `if !EnsureDaemon() | return | endif`.  A
" disable-then-enable in one tick then left the plugin off, with no message and
" no daemon.  Answering true and doing nothing would be worse: an unkept
" promise.  The replacement is staged on the exit that is already coming.
call s:Fresh({'auto_restart': v:false, 'kill_after_ms': 150,
      \ 'env': {'FAKE_IGNORE_TERM': '1'}})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:starts_before_stopping_ensure = s:C('Health').starts
call s:C('Stop')
call assert_true(s:C('IsRunning'), 'the fixture ignores SIGTERM, so the stop is really in flight')
call assert_true(s:C('Health').stopping)
call assert_true(s:C('Ensure'),
      \ 'a caller asking for a daemon in that window is not told to give up')
call assert_true(s:C('Ensure'), 'and asking twice is not two promises')
call assert_true(s:Wait(
      \ 's:C("Health").starts > s:starts_before_stopping_ensure && s:C("Ready")', 6000),
      \ 'the promise is kept once the old process is reaped')
call assert_equal(s:starts_before_stopping_ensure + 1, s:C('Health').starts,
      \ 'exactly one replacement, not one per Ensure()')
call s:C('Stop', v:true)
call assert_true(s:Wait('!s:C("IsRunning")', 3000))

" Stop() is still the last word: it clears the staged replacement rather than
" racing it, which is the same field OnExit lets a callback clear.
call s:Fresh({'auto_restart': v:false, 'kill_after_ms': 150,
      \ 'env': {'FAKE_IGNORE_TERM': '1'}})
call assert_true(s:C('Ensure'))
call assert_true(s:Wait('s:C("Ready")', 3000))
let s:starts_before_vetoed_ensure = s:C('Health').starts
call s:C('Stop')
call assert_true(s:C('Ensure'))
call s:C('Stop')
call assert_true(s:Wait('!s:C("IsRunning")', 5000))
sleep 300m
call assert_equal(s:starts_before_vetoed_ensure, s:C('Health').starts,
      \ 'a later Stop() cancels the staged replacement')
call assert_false(s:C('IsRunning'))

" ------------------------------------------------------------- raw codec ---

call s:Fresh({'codec': 'raw', 'handshake': {}})
call assert_true(s:C('Ensure'))

" No handshake configured is not the same as a handshake that completed.  This
" is the configuration simplecc, simpletree and simpletreesitter ship — they
" negotiate by hand afterwards — and the branch sets s_ready at spawn, so
" without these assertions the health report is free to print
" "[OK] state: running, ready" for a protocol nobody ever exchanged, and
" nothing stops a refactor from dropping the OnReady that is those plugins'
" only cue to start negotiating.
call assert_true(s:C('Ready'), 'with nothing to negotiate the daemon is usable at once')
call assert_false(s:C('Negotiated'), 'but nothing was negotiated')
call assert_false(s:C('Health').negotiated)
call assert_equal(0, s:C('Protocol'), 'and there is no protocol to report')
call assert_equal(1, len(s:ready),
      \ 'OnReady still fires exactly once — it is the cue to negotiate by hand')
call assert_equal(0, s:ready[0].proto)
let s:hl = s:C('HealthLines')
call assert_true(s:hl[1] =~# 'no handshake configured',
      \ 'the state line says what is true: ' .. string(s:hl))
call assert_false(s:hl[1] =~# 'ready',
      \ 'and never claims a negotiation that did not happen: ' .. string(s:hl))
call s:C('Configure', 'handshake', {'request': {'type': 'ping'}})
call assert_false(s:C('Negotiated'),
      \ 'changing config cannot invent a handshake this generation never sent')
call assert_false(s:C('Health').handshake_expected)
call assert_true(s:C('HealthLines')[1] =~# 'no handshake configured')

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
call assert_true(s:h.negotiated, 'a completed handshake is a negotiation')
call assert_equal(3, s:h.protocol)
call assert_false(s:h.breaker_open)

" uptime_ms is the field a user quotes when reporting a restart loop, so it has
" to be a clock.  `>= 0` was true of any non-negative expression, the constant
" 0 included, and it was the only assertion on uptime in the whole suite.
let s:up0 = s:h.uptime_ms
call assert_true(s:up0 > 0, 'a daemon that has handshaked has been up for a measurable time')
sleep 300m
let s:up1 = s:C('Health').uptime_ms
call assert_true(s:up1 - s:up0 >= 200,
      \ printf('uptime_ms tracks elapsed time (%d then %d)', s:up0, s:up1))
call assert_true(s:up1 < 300000, 'and is measured from this start, not from the epoch')

let s:hl = s:C('HealthLines')
call assert_true(len(s:hl) >= 2)
call assert_true(s:hl[0] =~# '^\[OK\] daemon: ')
call assert_true(s:hl[1] =~# 'ready')
call assert_true(s:hl[1] =~# 'uptime [0-9]\+\.[0-9]s',
      \ 'and reaches the user through the report: ' .. string(s:hl))
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
