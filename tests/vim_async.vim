vim9script
set nocompatible
set nomore
set encoding=utf-8
var root = fnamemodify(expand('<sfile>:p'), ':h:h')
execute 'set rtp^=' .. fnameescape(root)
var tmp = tempname()
mkdir(tmp, 'p', 0o700)
var client = tmp .. '/client'
var capture = tmp .. '/capture'
var fallback = tmp .. '/fallback'
writefile(['#!/usr/bin/env python3',
  'import sys, os, time',
  'args=sys.argv[1:]',
  'assert os.environ["SIMPLECLIPBOARD_TOKEN"] == "test-token"',
  'assert "test-token" not in args',
  'n=int(args[args.index("--input-bytes")+1])',
  'if os.environ.get("SCB_MODE")=="early": sys.exit(64)',
  'if os.environ.get("SCB_MODE")=="no-read": time.sleep(20)',
  'time.sleep(0.2)',
  'data=b""',
  'while len(data)<n:',
  '    print("ready", flush=True)',
  '    data+=sys.stdin.buffer.read(min(512,n-len(data)))',
  'assert len(data)==n',
  'with open(os.environ["SCB_CAPTURE"], "ab") as f: f.write(data+b"\n")',
  'mode=os.environ.get("SCB_MODE", "0")',
  'if mode=="hang": time.sleep(20)',
  'sys.exit(int(mode))'], client)
setfperm(client, 'rwx------')
$SCB_CAPTURE = capture
$SCB_MODE = '0'
g:simpleclipboard_client_path = client
g:simpleclipboard_address = '127.0.0.1:12343'
g:simpleclipboard_token = 'test-token'
g:simpleclipboard_daemon_autostart = 0
g:simpleclipboard_auto_copy = 0
g:simpleclipboard_disable_osc52 = 1
g:simpleclipboard_copy_command = ['/usr/bin/tee', fallback]
runtime plugin/simpleclipboard.vim

def WaitOutcome(expected: string): void
  for _ in range(20000)
    if simpleclipboard#LastCopy().outcome ==# expected
      return
    endif
    sleep 1m
  endfor
  assert_equal(expected, simpleclipboard#LastCopy().outcome, string(simpleclipboard#LastCopy()))
enddef

# Larger than pipe capacity: delivery must neither block Vim nor truncate at EOF.
var text = repeat('a', 511) .. "é" .. repeat('a', 300000) .. "\x01\nend"
var started = reltime()
assert_true(simpleclipboard#CopyText(text))
assert_true(reltimefloat(reltime(started)) < 0.15, 'copy blocked on slow child')
assert_equal('queued', simpleclipboard#LastCopy().outcome)
WaitOutcome('success')
assert_equal(text .. "\n", join(readfile(capture, 'b'), "\n"))
assert_false(filereadable(fallback))

# Latest-only serialization: one running request, one pending, no stale overwrite.
delete(capture)
assert_true(simpleclipboard#CopyText('first'))
assert_true(simpleclipboard#CopyText('discard'))
assert_true(simpleclipboard#CopyText('latest'))
WaitOutcome('success')
assert_equal(['first', 'latest'], readfile(capture))

# Empty content requires no ready line and is still a real clipboard write.
assert_true(simpleclipboard#CopyText(''))
WaitOutcome('success')

$SCB_MODE = '1'
assert_true(simpleclipboard#CopyText('fallback text'))
WaitOutcome('success')
assert_equal('fallback text', join(readfile(fallback, 'b'), "\n"))
delete(fallback)

# Unknown writes must not fall back or automatically replay pending text.
$SCB_MODE = '2'
delete(capture)
assert_true(simpleclipboard#CopyText('unknown'))
assert_true(simpleclipboard#CopyText('do not replay'))
WaitOutcome('uncertain')
sleep 300m
assert_false(filereadable(fallback))
assert_equal(['unknown'], readfile(capture))

$SCB_MODE = 'hang'
g:simpleclipboard_copy_timeout_ms = 300
assert_true(simpleclipboard#CopyText('deadline'))
WaitOutcome('uncertain')
assert_false(filereadable(fallback))

$SCB_MODE = 'no-read'
g:simpleclipboard_copy_timeout_ms = 30
assert_true(simpleclipboard#CopyText(text))
WaitOutcome('uncertain')
assert_false(filereadable(fallback))

# An early client error must not leave a nonblocking writer wedged.
$SCB_MODE = 'early'
g:simpleclipboard_copy_timeout_ms = 10000
assert_true(simpleclipboard#CopyText(text))
WaitOutcome('success')
assert_equal(text, join(readfile(fallback, 'b'), "\n"))
delete(fallback)

# A deliberately rejected route must not reach the client.
$SCB_MODE = '0'
g:simpleclipboard_token = ''
assert_true(simpleclipboard#CopyText('no plaintext custom route'))
WaitOutcome('success')
assert_equal('no plaintext custom route', join(readfile(fallback, 'b'), "\n"))

# Real built client: stream framing and CLI integrate without a daemon. A
# refused loopback connection is a definite failure, so fallback is safe.
var built = root .. '/target/release/simpleclipboard-client'
if executable(built)
  g:simpleclipboard_client_path = built
  g:simpleclipboard_token = 'test-token'
  g:simpleclipboard_address = '127.0.0.1:1'
  simpleclipboard#Refresh()
  assert_true(simpleclipboard#CopyText(text))
  WaitOutcome('success')
  assert_equal(text, join(readfile(fallback, 'b'), "\n"))
endif

if !empty(v:errors)
  writefile(v:errors, root .. '/tests/async-errors.log')
  cquit
endif
delete(tmp, 'rf')
qa!
