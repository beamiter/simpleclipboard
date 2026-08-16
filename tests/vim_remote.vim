" ============================================================================
" SimpleRemote integration and suite API tests
"
" Covers the parts of SimpleClipboard that other simple* plugins lean on:
" remote-aware :SimpleCopyPath / :SimpleCopyLocation / :SimpleCopyFormat,
" simpleclipboard#CopyText(), simpleclipboard#LastCopy() and
" simpleclipboard#PasteText().  SimpleRemote itself is never on the
" runtimepath here; the buffer variables it would set and the one global
" function these paths consult are created by hand, so the suite passes in a
" checkout that has no sibling plugins at all.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/vim_remote.vim
" ============================================================================

set nocompatible
set nomore
set shortmess+=I
" Character columns are only meaningful in a known encoding; without a vimrc
" Vim may start in latin1 and count each byte of an accented letter.
set encoding=utf-8
scriptencoding utf-8

let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
call delete(s:root .. '/tests/remote-errors.log')
let s:tmp_prefix = '/tmp/simpleclipboard-vim-remote-' .. getpid()
let s:capture = s:tmp_prefix .. '-capture'
let s:fake_bin = s:tmp_prefix .. '-bin'
let s:project = s:tmp_prefix .. '-project'
let s:old_path = $PATH
let s:had_wayland = exists('$WAYLAND_DISPLAY')
let s:old_wayland = $WAYLAND_DISPLAY

call delete(s:capture)
call delete(s:fake_bin, 'rf')
call delete(s:project, 'rf')
call mkdir(s:fake_bin, 'p', 0700)
call mkdir(s:project .. '/lib', 'p', 0700)
execute 'set runtimepath^=' .. fnameescape(s:root)

" Every copy lands in a file through the custom command, so what reached the
" "system clipboard" can be read back byte for byte.  The daemon and OSC52 are
" out of the picture: this suite is about what is copied, not how.
let g:simpleclipboard_daemon_enabled = 0
let g:simpleclipboard_auto_copy = 0
let g:simpleclipboard_disable_osc52 = 1
let g:simpleclipboard_copy_command = ['tee', s:capture]
runtime plugin/simpleclipboard.vim

" ---------------------------------------------------------------- helpers ---

" Poll until Expr is true or the budget runs out.  sleep lets Vim service
" job callbacks, which is the only way asynchronous copy/paste output lands.
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

" The text the last copy delivered to the fake clipboard command.  The
" pipeline reports success only once tee has exited, so waiting on that
" rather than on the file's existence never reads a half-written capture.
function! s:Copied() abort
  call assert_true(s:Wait('simpleclipboard#LastCopy().outcome ==# "success"', 2000),
        \ 'copy command never finished: ' .. string(simpleclipboard#LastCopy()))
  call assert_true(filereadable(s:capture), 'copy command never wrote its capture file')
  return filereadable(s:capture) ? join(readfile(s:capture, 'b'), "\n") : ''
endfunction

" CopyText() through the same capture, for a direct call.
function! s:CopyTextCaptured(text) abort
  call delete(s:capture)
  let l:accepted = simpleclipboard#CopyText(a:text)
  return [l:accepted, s:Copied()]
endfunction

function! s:CopyCommand(command) abort
  call delete(s:capture)
  messages clear
  execute a:command
  return s:Copied()
endfunction

function! s:LastMessage() abort
  return get(split(execute('messages'), "\n"), -1, '')
endfunction

" ------------------------------------------- remote-aware path commands ---

" A virtual-mode SimpleRemote buffer: named remote:///abs/path, buftype
" acwrite (which the filesystem check would refuse), and b:vimrc_remote
" carrying the remote path.
enew!
file remote:///srv/app/src/main.rs
setlocal buftype=acwrite
call setline(1, ['fn main() {', '    println!("héllo");', '}'])
setlocal nomodified
let b:vimrc_remote = {'path': '/srv/app/src/main.rs',
      \ 'uri': 'remote:///srv/app/src/main.rs', 'generation': 3}
call cursor(2, 1)
call search('llo')

" Without SimpleRemote loaded there is no workspace root to be relative to, so
" both forms are the absolute remote path - never a refusal, never the URI.
call assert_false(exists('*g:SimpleRemoteWorkspaceRoot'))
call assert_equal('/srv/app/src/main.rs', s:CopyCommand('SimpleCopyPath'))
call assert_match('for remote file path queued\.', s:LastMessage())
call assert_equal('/srv/app/src/main.rs', s:CopyCommand('SimpleCopyPath!'))
call assert_match('for absolute remote file path queued\.', s:LastMessage())
call assert_equal('/srv/app/src/main.rs:2:17', s:CopyCommand('SimpleCopyLocation'))
call assert_match('for remote file location queued\.', s:LastMessage())

" With a connected SimpleRemote the relative form strips the workspace root;
" the bang keeps the absolute path.  A root with a trailing slash is the same
" root.
let g:fake_workspace_root = '/srv/app'
function! g:SimpleRemoteWorkspaceRoot() abort
  return g:fake_workspace_root
endfunction
call assert_equal('src/main.rs', s:CopyCommand('SimpleCopyPath'))
call assert_equal('/srv/app/src/main.rs', s:CopyCommand('SimpleCopyPath!'))
call assert_equal('src/main.rs:2:17', s:CopyCommand('SimpleCopyLocation'))
call assert_match('for remote file location queued\.', s:LastMessage())
call assert_equal('/srv/app/src/main.rs:2:17', s:CopyCommand('SimpleCopyLocation!'))
call assert_match('for absolute remote file location queued\.', s:LastMessage())
call assert_equal('main.rs @ src/main.rs [src] 2:17',
      \ s:CopyCommand('SimpleCopyFormat {file} @ {path} [{dir}] {line}:{column}'))
call assert_match('for formatted remote file reference queued\.', s:LastMessage())
call assert_equal('/srv/app/src', s:CopyCommand('SimpleCopyFormat! {dir}'))
let g:fake_workspace_root = '/srv/app/'
call assert_equal('src/main.rs', s:CopyCommand('SimpleCopyPath'))

" A root of / strips only the leading slash; a path outside the root, or no
" root at all (SimpleRemote loaded but disconnected), stays absolute.
let g:fake_workspace_root = '/'
call assert_equal('srv/app/src/main.rs', s:CopyCommand('SimpleCopyPath'))
let g:fake_workspace_root = '/other/root'
call assert_equal('/srv/app/src/main.rs', s:CopyCommand('SimpleCopyPath'))
let g:fake_workspace_root = '/srv/app/src/main.rs'
call assert_equal('/srv/app/src/main.rs', s:CopyCommand('SimpleCopyPath'),
      \ 'a root equal to the file itself must not produce an empty path')
let g:fake_workspace_root = ''
call assert_equal('/srv/app/src/main.rs', s:CopyCommand('SimpleCopyPath'))
let g:fake_workspace_root = '/srv/app'

" The remote path is read for what it is; the relative form must not be
" reinterpreted against the local cwd, however the cwd is set.
let s:old_cwd = getcwd()
execute 'lcd ' .. fnameescape(s:project)
call assert_equal('src/main.rs', s:CopyCommand('SimpleCopyPath'))
execute 'lcd ' .. fnameescape(s:old_cwd)

" b:vimrc_remote of the wrong shape is ignored, and the buffer is then judged
" like any other: this one is acwrite and is refused.
for s:bad in ['/srv/app/src/main.rs', {}, {'path': ''}, {'path': 42}, ['/srv/app']]
  unlet! b:vimrc_remote
  let b:vimrc_remote = s:bad
  call delete(s:capture)
  messages clear
  SimpleCopyPath
  sleep 50m
  call assert_false(filereadable(s:capture),
        \ 'malformed b:vimrc_remote must not copy anything: ' .. string(s:bad))
  call assert_match('Current buffer is not a named file', s:LastMessage())
endfor
unlet! b:vimrc_remote
bwipe!

" A projected-mode buffer: an ordinary local file under the workspace mount
" whose b:simpleremote_path names the remote file.  The copied value is the
" remote path, not the mount path Vim edits.
let s:local_file = s:project .. '/lib/util.rs'
call writefile(['pub fn util() {}'], s:local_file)
execute 'edit! ' .. fnameescape(s:local_file)
let b:simpleremote_path = '/srv/app/lib/util.rs'
let b:simpleremote_workspace_id = 3
call assert_equal('lib/util.rs', s:CopyCommand('SimpleCopyPath'))
call assert_equal('/srv/app/lib/util.rs', s:CopyCommand('SimpleCopyPath!'))
call assert_equal('/srv/app/lib/util.rs:1:1', s:CopyCommand('SimpleCopyLocation!'))
call assert_equal('util.rs', s:CopyCommand('SimpleCopyFormat {file}'))

" b:simpleremote_path is stamped for one workspace generation and outlives
" it.  While a workspace with a different id is connected the buffer is a
" plain local file; the same id, an unstamped buffer, or no connected
" workspace at all keep the remote path.
let g:simpleremote_workspace = {'id': 3, 'kind': 'ssh', 'target': 'dev', 'root': '/srv/app'}
call assert_equal('lib/util.rs', s:CopyCommand('SimpleCopyPath'))
let g:simpleremote_workspace.id = 4
call assert_equal(s:local_file, s:CopyCommand('SimpleCopyPath!'))
call assert_match('for absolute file path queued\.', s:LastMessage())
unlet b:simpleremote_workspace_id
call assert_equal('/srv/app/lib/util.rs', s:CopyCommand('SimpleCopyPath!'))
let b:simpleremote_workspace_id = 4
call assert_equal('/srv/app/lib/util.rs', s:CopyCommand('SimpleCopyPath!'))
let b:simpleremote_workspace_id = 3

" A workspace dictionary of an unexpected shape must not break the copy.  Vim9
" raises E1030 when a number is compared with a string, and that error escapes
" the function it happens in, so the two ids are compared only once both are
" numbers; anything else leaves the buffer's stamp standing.
for s:bad_workspace in [{'id': 'three'}, {'id': []}, {'kind': 'ssh'}, 'ssh:dev', 7]
  let g:simpleremote_workspace = s:bad_workspace
  call assert_equal('/srv/app/lib/util.rs', s:CopyCommand('SimpleCopyPath!'),
        \ 'malformed g:simpleremote_workspace: ' .. string(s:bad_workspace))
endfor
unlet g:simpleremote_workspace
call assert_equal('/srv/app/lib/util.rs', s:CopyCommand('SimpleCopyPath!'))

" b:vimrc_remote wins over b:simpleremote_path when both are present.
let b:vimrc_remote = {'path': '/srv/app/lib/other.rs', 'uri': '', 'generation': 3}
call assert_equal('lib/other.rs', s:CopyCommand('SimpleCopyPath'))
unlet b:vimrc_remote

" Once the projection variable is gone the buffer is a plain local file again.
unlet b:simpleremote_path
call assert_equal(s:local_file, s:CopyCommand('SimpleCopyPath!'))
call assert_match('for absolute file path queued\.', s:LastMessage())
bwipe!

" A non-string b:simpleremote_path is ignored rather than copied or thrown on.
enew!
let b:simpleremote_path = 17
call delete(s:capture)
messages clear
SimpleCopyPath
sleep 50m
call assert_false(filereadable(s:capture))
call assert_match('Current buffer is not a named file', s:LastMessage())
bwipe!

" A workspace-root function that throws must not break the copy: the absolute
" path is copied instead.
function! g:SimpleRemoteWorkspaceRoot() abort
  throw 'simulated SimpleRemote failure'
endfunction
enew!
let b:simpleremote_path = '/srv/app/README'
call assert_equal('/srv/app/README', s:CopyCommand('SimpleCopyPath'))
bwipe!
delfunction g:SimpleRemoteWorkspaceRoot

" ------------------------------------------------ CopyText and LastCopy ---

" Nothing has been copied through the suite API yet in this Vim; the copies
" above went through the same pipeline, so LastCopy() already describes one.
let s:last = simpleclipboard#LastCopy()
call assert_equal(['at', 'bytes', 'error', 'method', 'outcome'], sort(keys(s:last)))
call assert_equal('success', s:last.outcome)
call assert_equal('custom command', s:last.method)

" CopyText() writes the unnamed register synchronously and routes the same
" text to the clipboard; LastCopy() reports "queued" while the external
" command is still running and "success" once it has exited.
call setreg('"', 'previous')
call delete(s:capture)
call assert_true(simpleclipboard#CopyText('x'))
call assert_equal('x', getreg('"'))
let s:queued = simpleclipboard#LastCopy()
call assert_equal('queued', s:queued.outcome)
call assert_equal('custom command (queued)', s:queued.method)
call assert_equal(1, s:queued.bytes)
call assert_equal('', s:queued.error)
call assert_equal('x', s:Copied())
let s:done = simpleclipboard#LastCopy()
call assert_equal('custom command', s:done.method)
call assert_equal(1, s:done.bytes)
call assert_equal('', s:done.error)
call assert_match('^\d\{4}-\d\d-\d\d \d\d:\d\d:\d\d$', s:done.at)

" Multi-line text and UTF-8 survive both the register and the route.
call assert_equal([v:true, "α line\nsecond\n"], s:CopyTextCaptured("α line\nsecond\n"))
call assert_equal("α line\nsecond\n", getreg('"'))
call assert_equal(strlen("α line\nsecond\n"), simpleclipboard#LastCopy().bytes)

" When every backend fails, CopyText() still owns the register and still
" answers true - the command did start, so the copy was accepted as queued -
" and it is LastCopy() that says how it really went, with the backend's error.
let $PATH = s:fake_bin
let g:simpleclipboard_copy_command = ['/bin/false']
call simpleclipboard#Refresh()
messages clear
call assert_true(simpleclipboard#CopyText('doomed'), 'a started command is accepted (queued)')
call assert_equal('doomed', getreg('"'))
call assert_true(s:Wait('simpleclipboard#LastCopy().outcome ==# "failed"', 2000))
let s:failed = simpleclipboard#LastCopy()
call assert_equal('failed', s:failed.method)
call assert_match('exited with status 1', s:failed.error)
call assert_equal(6, s:failed.bytes)
let g:simpleclipboard_copy_command = ['/nonexistent/simpleclipboard-copy']
call simpleclipboard#Refresh()
call assert_true(simpleclipboard#CopyText('still mine'))
call assert_equal('still mine', getreg('"'))
call assert_true(s:Wait('simpleclipboard#LastCopy().outcome ==# "failed"', 2000))
let $PATH = s:old_path
let g:simpleclipboard_copy_command = ['tee', s:capture]
call simpleclipboard#Refresh()

" ------------------------------------------------------------- PasteText ---

let s:pastes = []
function! s:OnPaste(ok, text) abort
  call add(s:pastes, [a:ok, a:text])
endfunction
function! s:PasteAndWait(...) abort
  let s:pastes = []
  call call('simpleclipboard#PasteText', [function('s:OnPaste')] + a:000)
  call assert_true(s:Wait('!empty(s:pastes)', 3000), 'PasteText never called back')
  call assert_equal(1, len(s:pastes), 'PasteText must call back exactly once')
  return get(s:pastes, 0, [v:false, 'no callback'])
endfunction

" A Vim built with +clipboard whose "+ register holds text answers from the
" register, before any program runs; that is the only route this suite cannot
" fake, so it is exercised only where it exists.  Everywhere else the
" programs are all there is, and $PATH is emptied of the real ones so that a
" developer's desktop clipboard cannot leak into an assertion.
let $PATH = s:fake_bin
if s:had_wayland
  unlet $WAYLAND_DISPLAY
endif
let s:register_backed = has('clipboard') && getreg('+') !=# ''
" A +clipboard Vim whose register is empty still consults it first, and a
" final failure says so; every other Vim reports the program failure alone.
let s:empty_register = has('clipboard') ? 'the "+ register is empty and ' : ''
if s:register_backed
  let s:from_register = s:PasteAndWait()
  call assert_equal([v:true, getreg('+')], s:from_register)
else
  " The custom paste program's standard output is the answer, byte for byte:
  " trailing newlines and UTF-8 included, and no register is written.
  let g:simpleclipboard_paste_command = ['/bin/sh', '-c', 'printf "héllo\nworld\n"']
  call setreg('"', 'untouched')
  call assert_equal([v:true, "héllo\nworld\n"], s:PasteAndWait())
  call assert_equal([v:true, "héllo\nworld\n"], s:PasteAndWait('clipboard'))
  call assert_equal('untouched', getreg('"'))

  " The callback runs after PasteText() returns when a program is involved.
  let s:pastes = []
  call simpleclipboard#PasteText(function('s:OnPaste'))
  call assert_equal([], s:pastes, 'a program-backed paste is asynchronous')
  call assert_true(s:Wait('!empty(s:pastes)', 3000))

  " Output larger than a pipe buffer arrives complete.
  let g:simpleclipboard_paste_command = ['/bin/sh', '-c',
        \ 'PATH=/usr/bin:/bin; head -c 200000 /dev/zero | tr "\0" x']
  let s:big = s:PasteAndWait()
  call assert_equal(v:true, s:big[0])
  call assert_equal(200000, strlen(s:big[1]))

  " A failing program is reported with its status; a program that cannot be
  " started counts as failed too.  Neither leaks partial output as success.
  let g:simpleclipboard_paste_command = ['/bin/sh', '-c', 'printf partial; exit 3']
  call assert_equal([v:false, s:empty_register .. 'custom paste command exited with status 3'],
        \ s:PasteAndWait())
  let g:simpleclipboard_paste_command = ['/nonexistent/simpleclipboard-paste']
  let s:missing = s:PasteAndWait()
  call assert_equal(v:false, s:missing[0])
  call assert_match('^' .. s:empty_register .. 'custom paste command exited with status', s:missing[1])

  " A program that never answers is stopped at the deadline and reported as
  " such; partial output is not passed off as the clipboard.
  let g:simpleclipboard_paste_timeout_ms = 300
  let g:simpleclipboard_paste_command = ['/bin/sh', '-c',
        \ 'PATH=/usr/bin:/bin; printf partial; exec sleep 30']
  let s:started = reltime()
  call assert_equal([v:false, s:empty_register .. 'custom paste command did not answer within 300 ms'],
        \ s:PasteAndWait())
  call assert_true(reltimefloat(reltime(s:started)) < 2.5, 'deadline was not enforced')
  let g:simpleclipboard_paste_timeout_ms = 10000

  " A failed custom program advances to the platform candidates: a fake xclip
  " on $PATH answers next, with the selection it was asked for.
  call writefile(['#!/bin/sh', 'printf "xclip:%s" "$2"'], s:fake_bin .. '/xclip')
  call setfperm(s:fake_bin .. '/xclip', 'rwx------')
  let g:simpleclipboard_paste_command = ['/bin/false']
  call assert_equal([v:true, 'xclip:clipboard'], s:PasteAndWait())
  call assert_equal([v:true, 'xclip:primary'], s:PasteAndWait('primary'))

  " The custom command serves CLIPBOARD only; PRIMARY skips it.
  let g:simpleclipboard_paste_command = ['/bin/sh', '-c', 'printf custom']
  call assert_equal([v:true, 'custom'], s:PasteAndWait('clipboard'))
  call assert_equal([v:true, 'xclip:primary'], s:PasteAndWait('primary'))
  call delete(s:fake_bin .. '/xclip')

  " With no program at all the answer depends on whether a register was
  " consulted: an empty "+ register with nothing to contradict it is an empty
  " clipboard, no register and no program is a failure that says what would
  " be needed.  A malformed custom command is ignored, not run.
  for s:no_program in [[], ['/bin/sh', '-c', '']]
    let g:simpleclipboard_paste_command = s:no_program
    let s:none = s:PasteAndWait()
    if has('clipboard')
      call assert_equal([v:true, ''], s:none)
    else
      call assert_equal(v:false, s:none[0])
      call assert_match('no clipboard paste backend is available', s:none[1])
    endif
  endfor
  call assert_match('g:simpleclipboard_paste_command must be a list of non-empty strings',
        \ join(simpleclipboard#ValidateOptions(), "\n"))
endif

" An unknown selection is refused synchronously, whatever the environment.
let g:simpleclipboard_paste_command = []
let s:pastes = []
call simpleclipboard#PasteText(function('s:OnPaste'), 'bogus')
call assert_equal([[v:false, 'selection must be "clipboard" or "primary", not "bogus"']],
      \ s:pastes)

" :SimpleCopyStatus lists the paste programs beside the copy commands.
messages clear
SimpleCopyStatus
call assert_match('\[SimpleClipboard\] paste: ', execute('messages'))

let $PATH = s:old_path
if s:had_wayland
  let $WAYLAND_DISPLAY = s:old_wayland
endif

" ------------------------------------------------------------- teardown ---

call delete(s:capture)
call delete(s:fake_bin, 'rf')
call delete(s:project, 'rf')

if !empty(v:errors)
  for s:error in v:errors
    echom s:error
  endfor
  call writefile(v:errors, s:root .. '/tests/remote-errors.log')
  cquit
endif
qa!
