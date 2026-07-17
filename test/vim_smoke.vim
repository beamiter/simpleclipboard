let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
let s:tmp_prefix = '/tmp/simpleclipboard-vim-smoke-' .. getpid()
let s:capture = s:tmp_prefix .. '-capture'
let s:state_home = s:tmp_prefix .. '-state'
let s:fake_bin = s:tmp_prefix .. '-bin'
let s:fake_pbcopy = s:fake_bin .. '/pbcopy'
let s:slow_fail = s:fake_bin .. '/slow-fail'
let s:ordered_copy = s:fake_bin .. '/ordered-copy'
let s:daemon_script = s:tmp_prefix .. '-daemon'
let s:daemon_log = s:tmp_prefix .. '-daemon-log'
let s:old_path = $PATH
let s:had_state_home = exists('$XDG_STATE_HOME')
let s:old_state_home = $XDG_STATE_HOME
let s:had_ssh_connection = exists('$SSH_CONNECTION')
let s:old_ssh_connection = $SSH_CONNECTION

call delete(s:capture)
call delete(s:state_home, 'rf')
call delete(s:fake_bin, 'rf')
call delete(s:daemon_script)
call delete(s:daemon_log)
call mkdir(s:fake_bin, 'p', 0700)
let $XDG_STATE_HOME = s:state_home
execute 'set runtimepath^=' .. fnameescape(s:root)

let g:simpleclipboard_daemon_enabled = 0
let g:simpleclipboard_auto_copy = 1
let g:simpleclipboard_debounce_ms = 0
let g:simpleclipboard_disable_osc52 = 1
let g:simpleclipboard_copy_command = ['tee', s:capture]
let g:simpleclipboard_debug = 1
let g:simpleclipboard_debug_to_file = 1
runtime plugin/simpleclipboard.vim

" Default debug output belongs to a private per-user state directory.
call simpleclipboard#DetectEnvironment()
let s:debug_dir = s:state_home .. '/simpleclipboard'
let s:debug_file = s:debug_dir .. '/simpleclipboard.log'
call assert_true(isdirectory(s:debug_dir))
call assert_true(filereadable(s:debug_file))
call assert_equal('rwx------', getfperm(s:debug_dir))
call assert_equal('rw-------', getfperm(s:debug_file))
let g:simpleclipboard_debug = 0
let g:simpleclipboard_debug_to_file = 0

call assert_equal('127.0.0.1', g:simpleclipboard_bind_addr)
call assert_equal(2, exists(':SimpleCopyVisual'))
call assert_equal(2, exists(':SimpleCopyStart'))
call assert_equal(2, exists(':SimpleCopyStatus'))
call assert_equal(2, exists(':SimpleCopyRefresh'))
call assert_equal('<Plug>(SimpleCopyYank)', maparg('<leader>y', 'n'))
call assert_equal('<Plug>(SimpleCopyVisual)', maparg('<leader>y', 'x'))

new
call setline(1, ['alpha beta', 'second line', 'third line'])
call setreg('0', 'keep-zero')
call setreg('z', 'keep-z')
call setreg('"', 'keep-unnamed')
let s:before_unnamed = getreg('"')
let s:before_zero = getreg('0')
execute "normal! gg0v4l\<Esc>"
call assert_equal('alpha', simpleclipboard#GetVisualSelection())
call assert_equal(s:before_unnamed, getreg('"'))
call assert_equal(s:before_zero, getreg('0'))
call assert_equal('keep-z', getreg('z'))

execute "normal! ggVj\<Esc>"
call assert_equal("alpha beta\nsecond line\n", simpleclipboard#GetVisualSelection())

call setline(1, ['abcdEF', 'abXYEF', 'ab12EF'])
execute "normal! gg0\<C-V>2j2l\<Esc>"
call assert_equal("abc\nabX\nab1", simpleclipboard#GetVisualSelection())

call setline(1, ['alpha', 'beta', 'gamma'])
call delete(s:capture)
normal! gg0yy
sleep 200m
call assert_true(filereadable(s:capture))
call assert_equal(0z616C7068610A, readblob(s:capture))

call delete(s:capture)
normal! gg0dd
sleep 100m
call assert_false(filereadable(s:capture), 'delete/change events must not copy')

execute "normal! gg0v2l\<Esc>"
call simpleclipboard#CopyVisualSelection()
sleep 200m
call assert_equal(0z626574, readblob(s:capture))

" External jobs are serialized so the latest request wins even when the old
" command is slower.  An explicit copy also cancels an older yank debounce.
call writefile([
      \ '#!/bin/sh',
      \ 'text=$(/bin/cat)',
      \ 'if [ "$text" = "old" ]; then /bin/sleep 0.5; fi',
      \ 'printf "%s" "$text" > ' .. shellescape(s:capture),
      \ ], s:ordered_copy)
call assert_equal(1, setfperm(s:ordered_copy, 'rwx------'))
let $PATH = s:fake_bin
let g:simpleclipboard_copy_command = [s:ordered_copy]
call simpleclipboard#Refresh()
call delete(s:capture)
call assert_true(simpleclipboard#CopyToSystemClipboard('old'))
sleep 50m
call assert_true(simpleclipboard#CopyToSystemClipboard('new'))
sleep 800m
call assert_equal(['new'], readfile(s:capture, 'b'))

let g:simpleclipboard_debounce_ms = 200
call delete(s:capture)
call simpleclipboard#CopyYankedToClipboardEvent({
      \ 'operator': 'y',
      \ 'regname': '',
      \ 'regcontents': ['debounced-old'],
      \ 'regtype': 'v',
      \ })
call assert_true(simpleclipboard#CopyToSystemClipboard('explicit-new'))
sleep 350m
call assert_equal(['explicit-new'], readfile(s:capture, 'b'))
let g:simpleclipboard_debounce_ms = 0

" A failed custom command advances to the next platform candidate.  The older
" slow callback must not advance the newly refreshed candidate generation.
call writefile(['#!/bin/sh', '/bin/sleep 1', 'exit 1'], s:slow_fail)
call assert_equal(1, setfperm(s:slow_fail, 'rwx------'))
let $PATH = s:fake_bin
let g:simpleclipboard_copy_command = [s:slow_fail]
call simpleclipboard#Refresh()
call delete(s:capture)
call assert_true(simpleclipboard#CopyToSystemClipboard('stale generation'))

call writefile(['#!/bin/sh', '/bin/cat > ' .. shellescape(s:capture)], s:fake_pbcopy)
call assert_equal(1, setfperm(s:fake_pbcopy, 'rwx------'))
let g:simpleclipboard_copy_command = ['/usr/bin/false']
call simpleclipboard#Refresh()
messages clear
call assert_true(simpleclipboard#CopyToSystemClipboard('candidate fallback'))
sleep 1300m
call assert_equal('candidate fallback', join(readfile(s:capture, 'b'), "\n"))
call simpleclipboard#Status()
let s:candidate_status = execute('messages')
call assert_match('last copy: method=pbcopy, outcome=success', s:candidate_status)
call assert_notmatch('All copy backends failed', s:candidate_status)

" Exhausting an asynchronously queued chain produces one clear final result.
call delete(s:fake_pbcopy)
let g:simpleclipboard_copy_command = ['/usr/bin/false']
call simpleclipboard#Refresh()
messages clear
call assert_true(simpleclipboard#CopyToSystemClipboard('expected failure'))
sleep 300m
let s:failure_messages = execute('messages')
call assert_match('All copy backends failed. Run :SimpleCopyStatus.', s:failure_messages)
call simpleclipboard#Status()
let s:failure_status = execute('messages')
call assert_match('external commands: custom command', s:failure_status)
call assert_match('OSC52: disabled', s:failure_status)
call assert_match('last copy: method=failed, outcome=failed', s:failure_status)

" Disabled daemon routing still classifies SSH, but does no route/network probe.
let $SSH_CONNECTION = '203.0.113.5 12345 203.0.113.10 22'
let g:simpleclipboard_debug = 1
let g:simpleclipboard_debug_to_file = 0
messages clear
call simpleclipboard#Refresh()
call simpleclipboard#Status()
let s:disabled_remote_status = execute('messages')
call assert_match('environment: ssh', s:disabled_remote_status)
call assert_match('address=none', s:disabled_remote_status)
call assert_match('daemon routing disabled; skipping network probes', s:disabled_remote_status)
call assert_notmatch('TCP probe', s:disabled_remote_status)
let g:simpleclipboard_debug = 0
if s:had_ssh_connection
  let $SSH_CONNECTION = s:old_ssh_connection
else
  unlet $SSH_CONNECTION
endif
let $PATH = s:old_path

" Empty tokens block remote/custom daemon routing before a Ping or Set request.
let g:simpleclipboard_daemon_enabled = 1
let g:simpleclipboard_address = '198.51.100.7:12343'
let g:simpleclipboard_token = ''
call simpleclipboard#Refresh()
messages clear
call simpleclipboard#Status()
let s:token_status = execute('messages')
call assert_match('daemon: blocked (configuration); address=none', s:token_status)
call assert_match('custom daemon routing requires g:simpleclipboard_token', s:token_status)
messages clear
call simpleclipboard#StartDaemon(v:true)
call assert_match('custom daemon routing requires g:simpleclipboard_token; daemon start refused', execute('messages'))

" Token limits match the daemon: 4096 UTF-8 bytes route normally, 4097 are
" rejected before a network probe or process start.
let g:simpleclipboard_address = '127.0.0.1:1'
let g:simpleclipboard_token = repeat('x', 4096)
call simpleclipboard#Refresh()
messages clear
call simpleclipboard#Status()
let s:max_token_status = execute('messages')
call assert_match('daemon route error: none', s:max_token_status)
call assert_notmatch('exceeds 4096', s:max_token_status)

let g:simpleclipboard_token = repeat('x', 4097)
call simpleclipboard#Refresh()
messages clear
call simpleclipboard#Status()
let s:oversized_token_status = execute('messages')
call assert_match('daemon: blocked (configuration); address=none', s:oversized_token_status)
call assert_match('g:simpleclipboard_token exceeds 4096 UTF-8 bytes', s:oversized_token_status)
messages clear
call simpleclipboard#StartDaemon(v:true)
call assert_match('exceeds 4096 UTF-8 bytes; daemon start refused', execute('messages'))

" The complete IPv4 127/8 range is loopback, matching Rust's exposure check.
let g:simpleclipboard_address = ''
let g:simpleclipboard_bind_addr = '127.0.0.2'
let g:simpleclipboard_token = ''
call simpleclipboard#Refresh()
messages clear
call simpleclipboard#Status()
let s:loopback_status = execute('messages')
call assert_match('address=127.0.0.2:12343', s:loopback_status)
call assert_match('daemon route error: none', s:loopback_status)

let g:simpleclipboard_address = ''
let g:simpleclipboard_bind_addr = '127.0.0.1'
let g:simpleclipboard_token = ''
let g:simpleclipboard_daemon_enabled = 0
call simpleclipboard#Refresh()

" Refresh owns the full stop/re-detect/restart cycle even with autostart off.
call writefile([
      \ '#!/bin/sh',
      \ '/bin/echo "$SIMPLECLIPBOARD_ADDR|$SIMPLECLIPBOARD_TOKEN" >> ' .. shellescape(s:daemon_log),
      \ 'trap "exit 0" TERM INT HUP',
      \ 'while :; do /bin/sleep 1; done',
      \ ], s:daemon_script)
call assert_equal(1, setfperm(s:daemon_script, 'rwx------'))
let s:first_port = 24000 + (getpid() % 10000)
let s:second_port = s:first_port + 1
let g:simpleclipboard_daemon_enabled = 1
let g:simpleclipboard_daemon_autostart = 0
let g:simpleclipboard_daemon_path = s:daemon_script
let g:simpleclipboard_port = s:first_port
let g:simpleclipboard_token = 'first-token'
call simpleclipboard#Refresh()
try
  call simpleclipboard#StartDaemon(v:true)
  call assert_equal(['127.0.0.1:' .. s:first_port .. '|first-token'], readfile(s:daemon_log))

  let g:simpleclipboard_port = s:second_port
  let g:simpleclipboard_token = 'second-token'
  call simpleclipboard#Refresh()
  call assert_equal([
        \ '127.0.0.1:' .. s:first_port .. '|first-token',
        \ '127.0.0.1:' .. s:second_port .. '|second-token',
        \ ], readfile(s:daemon_log))

  messages clear
  call simpleclipboard#StopDaemon(v:true)
  call assert_match('Stopped daemon owned by this Vim instance.', execute('messages'))
  messages clear
  call simpleclipboard#StopDaemon(v:false)
  call assert_equal('', trim(execute('messages')))
  call simpleclipboard#StopDaemon(v:true)
  call assert_match('No daemon owned by this Vim instance is running.', execute('messages'))
finally
  call simpleclipboard#StopDaemon(v:false)
endtry

" A copy-triggered lazy start must wait for daemon readiness before retrying.
" This deliberately non-listening daemon makes the bounded readiness wait
" observable without relying on a desktop clipboard being available in CI.
let g:simpleclipboard_daemon_autostart = 1
let g:simpleclipboard_copy_command = []
let $PATH = s:fake_bin
call simpleclipboard#Refresh()
messages clear
call simpleclipboard#Status()
if execute('messages') =~# 'environment: local'
  let s:lazy_started_at = reltime()
  call assert_false(simpleclipboard#CopyToSystemClipboard('lazy-start readiness'))
  let s:lazy_elapsed = reltimefloat(reltime(s:lazy_started_at))
  call assert_true(s:lazy_elapsed >= 0.25,
        \ 'lazy daemon start returned before its bounded readiness wait')
  call simpleclipboard#StopDaemon(v:false)
endif
let $PATH = s:old_path

let g:simpleclipboard_daemon_enabled = 0
let g:simpleclipboard_daemon_path = ''
let g:simpleclipboard_port = 12343
let g:simpleclipboard_token = ''
messages clear
call simpleclipboard#StartDaemon(v:false)
call assert_equal('', trim(execute('messages')))
call simpleclipboard#StartDaemon(v:true)
call assert_match('Daemon backend is disabled.', execute('messages'))
call simpleclipboard#Refresh()

call delete(s:capture)
bwipe!
silent help simpleclipboard
call assert_equal('help', &buftype)
bwipe!

let $PATH = s:old_path
if s:had_state_home
  let $XDG_STATE_HOME = s:old_state_home
else
  unlet $XDG_STATE_HOME
endif
if s:had_ssh_connection
  let $SSH_CONNECTION = s:old_ssh_connection
else
  silent! unlet $SSH_CONNECTION
endif
call delete(s:capture)
call delete(s:state_home, 'rf')
call delete(s:fake_bin, 'rf')
call delete(s:daemon_script)
call delete(s:daemon_log)

if !empty(v:errors)
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
