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
let s:path_project = s:tmp_prefix .. '-path-project'
let s:old_path = $PATH
let s:had_state_home = exists('$XDG_STATE_HOME')
let s:old_state_home = $XDG_STATE_HOME
let s:had_ssh_connection = exists('$SSH_CONNECTION')
let s:old_ssh_connection = $SSH_CONNECTION

" Some Vim builds keep a 'Messages maintainer: ...' header after :messages
" clear; capture the post-clear baseline instead of assuming empty output.
messages clear
let s:empty_messages = trim(execute('messages'))

call delete(s:capture)
call delete(s:state_home, 'rf')
call delete(s:fake_bin, 'rf')
call delete(s:daemon_script)
call delete(s:daemon_log)
call delete(s:path_project, 'rf')
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
call assert_equal(2, exists(':SimpleCopyRegister'))
call assert_equal(2, exists(':SimpleCopyClear'))
call assert_equal(2, exists(':SimpleCopyPath'))
call assert_equal(2, exists(':SimpleCopyLocation'))
call assert_equal(2, exists(':SimpleCopyFormat'))
call assert_equal(2, exists(':SimpleCopyStart'))
call assert_equal(2, exists(':SimpleCopyStatus'))
call assert_equal(2, exists(':SimpleCopyRefresh'))
call assert_equal('<Plug>(SimpleCopyYank)', maparg('<leader>y', 'n'))
call assert_equal('<Plug>(SimpleCopyVisual)', maparg('<leader>y', 'x'))
call assert_match('SimpleCopyPath', maparg('<Plug>(SimpleCopyPath)', 'n'))
call assert_match('SimpleCopyLocation', maparg('<Plug>(SimpleCopyLocation)', 'n'))
call assert_equal(':SimpleCopyFormat ', maparg('<Plug>(SimpleCopyFormat)', 'n'))

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

" Automatic copy can be restricted to selected Vim registers without changing
" the historical all-registers default.  A skipped newer yank must not leave
" an older debounced copy waiting behind it.
let g:simpleclipboard_auto_copy_registers = ['unnamed']
call delete(s:capture)
normal! gg0"ayy
sleep 100m
call assert_false(filereadable(s:capture), 'named register a is outside the allow-list')

let g:simpleclipboard_debounce_ms = 200
call simpleclipboard#CopyYankedToClipboardEvent({
      \ 'operator': 'y', 'regname': '', 'regcontents': ['pending secret'],
      \ 'regtype': 'v',
      \ })
call simpleclipboard#CopyYankedToClipboardEvent({
      \ 'operator': 'y', 'regname': 'a', 'regcontents': ['excluded replacement'],
      \ 'regtype': 'v',
      \ })
sleep 300m
call assert_false(filereadable(s:capture), 'excluded newer yank cancels pending old copy')
let g:simpleclipboard_debounce_ms = 0
normal! gg0yy
sleep 150m
call assert_equal(0z616C7068610A, readblob(s:capture))

" The byte cap applies only to automatic yanks; explicit register copies keep
" their exact contents, including a linewise trailing newline.
let g:simpleclipboard_auto_copy_max_bytes = 4
call delete(s:capture)
normal! gg0yy
sleep 100m
call assert_false(filereadable(s:capture), 'oversized automatic yank is skipped')
call setreg('a', "named register\n", 'V')
SimpleCopyRegister a
sleep 150m
call assert_equal(0z6E616D65642072656769737465720A, readblob(s:capture))

" Clearing goes through the same acknowledged/fallback pipeline and is not
" mistaken for an empty source register.
SimpleCopyClear
sleep 150m
call assert_true(filereadable(s:capture))
call assert_equal(0z, readblob(s:capture))
let g:simpleclipboard_auto_copy_registers = []
let g:simpleclipboard_auto_copy_max_bytes = 0

" g:simpleclipboard_auto_copy is honoured per yank rather than latched when the
" plugin loaded, so disabling it immediately before yanking a credential really
" does keep that credential inside Vim.
call assert_equal(2, exists(':SimpleCopyToggle'))
call assert_equal(2, exists(':SimpleCopyPause'))
call assert_match('SimpleCopyToggle', maparg('<Plug>(SimpleCopyToggle)', 'n'))
call delete(s:capture)
let g:simpleclipboard_auto_copy = 0
normal! gg0yy
sleep 100m
call assert_false(filereadable(s:capture), 'disabling automatic copy takes effect at once')

messages clear
SimpleCopyToggle
call assert_equal(1, g:simpleclipboard_auto_copy)
call assert_match('Automatic clipboard copy enabled.', execute('messages'))
normal! gg0yy
sleep 150m
call assert_equal(0z616C7068610A, readblob(s:capture))
messages clear
SimpleCopyToggle
call assert_equal(0, g:simpleclipboard_auto_copy)
call assert_match('Automatic clipboard copy disabled.', execute('messages'))
SimpleCopyToggle

" A pause is bounded and self-restoring; a malformed one changes nothing.
messages clear
SimpleCopyPause 0
call assert_match('Pause seconds must be between 1 and 86400', execute('messages'))
call assert_equal(1, g:simpleclipboard_auto_copy)
messages clear
SimpleCopyPause soon
call assert_match('Usage: :SimpleCopyPause', execute('messages'))
call assert_equal(1, g:simpleclipboard_auto_copy)

call delete(s:capture)
SimpleCopyPause 1
call assert_equal(0, g:simpleclipboard_auto_copy)
normal! gg0yy
sleep 100m
call assert_false(filereadable(s:capture), 'a paused yank must not reach the clipboard')
sleep 1200m
call assert_equal(1, g:simpleclipboard_auto_copy)
normal! gg0yy
sleep 150m
call assert_equal(0z616C7068610A, readblob(s:capture))

" A quoted port is a common vimrc habit, and it used to throw E1013 out of
" DetectEnvironment(), which sits on the path of every yank, every explicit
" copy and :SimpleCopyStatus itself. Every option is now coerced at the point
" of use and reported once, so a copy still completes through the fallback.
let g:simpleclipboard_daemon_enabled = 1
let g:simpleclipboard_daemon_autostart = 0
let g:simpleclipboard_port = '1'
let g:simpleclipboard_debounce_ms = 'soon'
let g:simpleclipboard_osc52_limit = 0
messages clear
call simpleclipboard#Refresh()
let s:coerced = execute('messages')
call assert_match('g:simpleclipboard_port must be a positive number, but is a string ("1"); using 1', s:coerced)
call assert_match('g:simpleclipboard_debounce_ms must be a number, but is a string ("soon"); using the default 50', s:coerced)
call assert_match('g:simpleclipboard_osc52_limit must be a positive number, but is a number (0); using the default 75000', s:coerced)
call delete(s:capture)
call assert_true(simpleclipboard#CopyToSystemClipboard('quoted port'))
sleep 300m
call assert_equal(['quoted port'], readfile(s:capture, 'b'))
messages clear
call simpleclipboard#Status()
let s:coerced_status = execute('messages')
call assert_match('configuration: 3 problem(s)', s:coerced_status)
call assert_match('address=127.0.0.1:1', s:coerced_status)

" A token is never echoed back, however wrong its type is.
let g:simpleclipboard_token = ['not', 'a', 'string']
messages clear
call simpleclipboard#Refresh()
let s:token_type_problem = execute('messages')
call assert_match('g:simpleclipboard_token must be a string, but is a list of', s:token_type_problem)
call assert_notmatch('not.*a.*string', s:token_type_problem)

let g:simpleclipboard_token = ''
let g:simpleclipboard_port = 12343
let g:simpleclipboard_debounce_ms = 0
let g:simpleclipboard_osc52_limit = 75000
let g:simpleclipboard_daemon_enabled = 0
let g:simpleclipboard_daemon_autostart = 1
messages clear
call simpleclipboard#Refresh()
call assert_equal([], simpleclipboard#ValidateOptions())

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
  call assert_equal(s:empty_messages, trim(execute('messages')))
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
call assert_equal(s:empty_messages, trim(execute('messages')))
call simpleclipboard#StartDaemon(v:true)
call assert_match('Daemon backend is disabled.', execute('messages'))
call simpleclipboard#Refresh()

" File path/location copies keep spaces and UTF-8 exact, default to the
" effective cwd, and use 1-based character columns. Bang selects absolute
" paths without bypassing the existing asynchronous copy pipeline.
let g:simpleclipboard_copy_command = ['tee', s:capture]
call simpleclipboard#Refresh()
let s:path_cwd = getcwd()
let s:path_subdir = s:path_project .. '/sub dir'
let s:path_file = s:path_subdir .. '/名字.rs'
call mkdir(s:path_subdir, 'p', 0700)
call writefile(['zero', 'α beta'], s:path_file)
execute 'edit! ' .. fnameescape(s:path_file)
execute 'lcd ' .. fnameescape(s:path_project)
call cursor(2, 1)
call search('beta')

SimpleCopyPath
sleep 150m
call assert_equal('sub dir/名字.rs', join(readfile(s:capture, 'b'), "\n"))
SimpleCopyPath!
sleep 150m
call assert_equal(s:path_file, join(readfile(s:capture, 'b'), "\n"))
SimpleCopyLocation
sleep 150m
call assert_equal('sub dir/名字.rs:2:3', join(readfile(s:capture, 'b'), "\n"))
SimpleCopyLocation!
sleep 150m
call assert_equal(s:path_file .. ':2:3', join(readfile(s:capture, 'b'), "\n"))

" Format templates are parsed, never evaluated. Inserted path text is not
" reparsed as placeholders, and literal braces use {{ / }}.
let s:format_file = s:path_subdir .. '/名 & {line}.rs'
call writefile(['zero', 'α beta'], s:format_file)
execute 'edit! ' .. fnameescape(s:format_file)
call cursor(2, 1)
call search('beta')
execute 'SimpleCopyFormat {file} @ {path} [{dir}] {line}:{column} {{literal}}'
sleep 150m
call assert_equal('名 & {line}.rs @ sub dir/名 & {line}.rs [sub dir] 2:3 {literal}',
      \ join(readfile(s:capture, 'b'), "\n"))
SimpleCopyFormat! {path}
sleep 150m
call assert_equal(s:format_file, join(readfile(s:capture, 'b'), "\n"))

" Empty, unknown, nested, unclosed, and unmatched templates fail before the
" clipboard pipeline; the previous confirmed clipboard value stays intact.
for s:bad_format in ['', '{unknown}', '{path', '{pa{th}', '}']
  messages clear
  execute 'SimpleCopyFormat ' .. s:bad_format
  sleep 20m
  call assert_equal(s:format_file, join(readfile(s:capture, 'b'), "\n"),
        \ 'malformed format must not copy partial output: ' .. s:bad_format)
  call assert_match('Format template', execute('messages'))
endfor

execute 'lcd ' .. fnameescape(s:path_cwd)
enew!
call delete(s:capture)
messages clear
SimpleCopyPath
call assert_false(filereadable(s:capture), 'unnamed buffers must not copy a fake path')
call assert_match('Current buffer is not a named file', execute('messages'))
file clipboard-test
setlocal buftype=nofile
messages clear
SimpleCopyLocation
call assert_false(filereadable(s:capture), 'non-file buffers must not copy a fake location')
call assert_match('Current buffer is not a named file', execute('messages'))
messages clear
SimpleCopyFormat {path}
call assert_false(filereadable(s:capture), 'non-file buffers must not copy a formatted reference')
call assert_match('Current buffer is not a named file', execute('messages'))
bwipe!

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
call delete(s:path_project, 'rf')

if !empty(v:errors)
  for error in v:errors
    echom error
  endfor
  cquit
endif
qa!
