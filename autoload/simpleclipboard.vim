vim9script

# ----------------- 日志功能 -----------------
#
# 在你的 vimrc 中添加 `let g:simpleclipboard_debug = 1` 来启用日志
#
def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpleclipboard_debug', 0) == 0
    return
  endif

  echohl hl
  echom '[SimpleClipboard] ' .. msg
  echohl None
enddef

# =============================================================
# 守护进程管理逻辑 (Daemon Management Logic)
# =============================================================

# 配置守护进程和相关文件的路径
# 用户可以在 vimrc 中通过 `let g:simpleclipboard_daemon_path = '...'` 来覆盖
g:simpleclipboard_daemon_path = get(g:, 'simpleclipboard_daemon_path', expand('~/.vim/plugged/simpleclipboard/lib/simpleclipboard-daemon'))
const DAEMON_PATH: string = g:simpleclipboard_daemon_path
const PID_FILE = '/tmp/simpleclipboard.pid'
const SOCKET_FILE = '/tmp/simpleclipboard.sock'

# 初始化Vim实例计数器
if !exists('g:simpleclipboard_vim_instances')
  g:simpleclipboard_vim_instances = 0
endif

# 检查守护进程是否正在运行 (内部函数)
def IsDaemonRunning(): bool
  if !filereadable(PID_FILE)
    return false
  endif
  var pid = trim(readfile(PID_FILE)[0])
  if pid == ''
    return false
  endif

  # 先执行命令，忽略其输出
  silent system('kill -0 ' .. pid)

  # 然后检查 v:shell_error
  # 如果命令成功 (进程存在)，v:shell_error 会是 0
  return v:shell_error == 0
enddef

# 启动守护进程的函数 (导出)
export def StartDaemon()
  g:simpleclipboard_vim_instances += 1
  Log($"Vim instance count incremented to: {g:simpleclipboard_vim_instances}")

  if IsDaemonRunning()
    Log('Daemon is already running.')
    return
  endif

  if !executable(DAEMON_PATH)
    echohl ErrorMsg
    echom $"[SimpleClipboard] Daemon executable not found or not executable: {DAEMON_PATH}"
    echom "[SimpleClipboard] Please set `g:simpleclipboard_daemon_path` in your vimrc to the correct path."
    echohl None
    return
  endif

  Log('Starting daemon...')
  # 启动 job，我们不再关心它的返回值（job 对象）
  var job_obj = job_start([DAEMON_PATH], {'out_io': 'null', 'err_io': 'null'})

  # 检查 job 是否成功启动
  if job_obj is v:null
    echohl ErrorMsg
    echom '[SimpleClipboard] Failed to start daemon job!'
    echohl None
    return
  endif

  # 等待一小会儿，给守护进程足够的时间来创建 PID 文件
  sleep 150m 

  # 确认守护进程是否真的在运行 (通过它自己创建的PID文件)
  if IsDaemonRunning()
    Log('Daemon confirmed to be running via PID file.')
  else
    echohl WarningMsg
    echom '[SimpleClipboard] Daemon job started, but failed to confirm it is running. Check daemon logs if any.'
    echohl None
  endif
enddef

# 停止守护进程的函数 (导出)
export def StopDaemon()
  g:simpleclipboard_vim_instances -= 1
  Log($"Vim instance count decremented to: {g:simpleclipboard_vim_instances}")

  if g:simpleclipboard_vim_instances > 0
    Log('Other Vim instances are still running. Daemon will not be stopped.')
    return
  endif

  if !IsDaemonRunning()
    return
  endif

  var pid = trim(readfile(PID_FILE)[0])
  Log($"Stopping daemon with PID: {pid}...")

  system('kill ' .. pid)

  if filereadable(PID_FILE) | delete(PID_FILE) | endif
  if filereadable(SOCKET_FILE) | delete(SOCKET_FILE) | endif

  Log('Daemon stopped and files cleaned up.')
enddef


# =============================================================
# 复制逻辑 (Clipboard Logic)
# =============================================================

var lib: string = ''

def TryLoadLib(): void
  if lib != ''
    return
  endif

  if type(g:simpleclipboard_libpath) == v:t_string && g:simpleclipboard_libpath !=# ''
    if filereadable(g:simpleclipboard_libpath)
      lib = g:simpleclipboard_libpath
      Log($"Found lib via g:simpleclipboard_libpath: {lib}", 'MoreMsg')
      return
    else
      Log($"g:simpleclipboard_libpath set but file not found: {g:simpleclipboard_libpath}", 'WarningMsg')
    endif
  endif

  var libname = 'libsimpleclipboard.so'
  for dir in split(&runtimepath, ',')
    # 修正：插件的lib文件通常在 'lib/' 目录下，而不是 'target/release'
    var path = dir .. '/lib/' .. libname
    if filereadable(path)
      lib = path
      Log($"Found lib in runtimepath: {path}", 'MoreMsg')
      break
    endif
  endfor
enddef

def CopyViaRust(text: string): bool
  Log('Attempting copy via Rust (Daemon)...', 'Question')
  TryLoadLib()
  if lib == ''
    Log('Skipped Rust: client library (libsimpleclipboard.so) not found.', 'Comment')
    return false
  endif

  try
    var result = libcallnr(lib, 'rust_set_clipboard', text) == 1
    if result
      Log('Success: Sent text to daemon.', 'ModeMsg')
    else
      Log('Failed: Could not send text to daemon. Is it running?', 'ErrorMsg')
    endif
    return result
  catch
    Log($"Failed: Error calling client library. Details: {v:exception}", 'ErrorMsg')
    return false
  endtry
enddef

def CopyViaCmds(text: string): bool
  Log('Attempting copy via external commands...', 'Question')
  # ... (这部分代码保持不变) ...
  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    Log('Trying: wl-copy (Wayland)', 'Identifier')
    system('wl-copy', text)
    if v:shell_error == 0
      Log('Success: Copied via wl-copy.', 'ModeMsg')
      return true
    endif
    Log('Failed: wl-copy command failed.', 'WarningMsg')
  endif

  if executable('xsel')
    Log('Trying: xsel (X11)', 'Identifier')
    system('xsel --clipboard --input', text)
    if v:shell_error == 0
      Log('Success: Copied via xsel.', 'ModeMsg')
      return true
    endif
    Log('Failed: xsel command failed.', 'WarningMsg')
  endif

  if executable('xclip')
    Log('Trying: xclip (X11)', 'Identifier')
    system('xclip -selection clipboard', text)
    if v:shell_error == 0
      Log('Success: Copied via xclip.', 'ModeMsg')
      return true
    endif
    Log('Failed: xclip command failed.', 'WarningMsg')
  endif

  Log('Skipped Cmds: No suitable command (wl-copy, xsel, xclip) found or all failed.', 'Comment')
  return false
enddef

def CopyViaOsc52(text: string): bool
  Log('Attempting copy via OSC52 terminal sequence...', 'Question')
  # ... (这部分代码保持不变) ...
  if !executable('base64')
    Log('Skipped OSC52: `base64` command not executable.', 'Comment')
    return false
  endif

  var payload = text
  var limit = 1000000
  if strchars(payload) > limit
    Log($"Text truncated to {limit} characters for OSC52.", 'Comment')
    payload = strcharpart(payload, 0, limit)
  endif

  var b64 = trim(system('base64 -w0', payload))
  if v:shell_error != 0 || b64 ==# ''
    b64 = system('base64', payload)
    if v:shell_error != 0
      Log('Failed: base64 encoding failed.', 'WarningMsg')
      return false
    endif
    b64 = substitute(b64, '\n', '', 'g')
  endif

  var seq = exists('$TMUX')
  ? "\x1bPtmux;\x1b]52;c;" .. b64 .. "\x07\x1b\\"
  : "\x1b]52;c;" .. b64 .. "\x07"

  try
    if has('unix') && filereadable('/dev/tty')
      writefile([seq], '/dev/tty', 'b')
      Log('Success: Sent OSC52 sequence to /dev/tty.', 'ModeMsg')
    else
      silent! echon seq
      redraw!
      Log('Success: Sent OSC52 sequence via echo.', 'ModeMsg')
    endif
    return true
  catch
    Log($"Failed: Error writing OSC52 sequence. Details: {v:exception}", 'ErrorMsg')
    return false
  endtry
enddef


export def CopyToSystemClipboard(text: string): bool
  # 优先使用守护进程
  return CopyViaRust(text) || CopyViaCmds(text) || CopyViaOsc52(text)
enddef

export def CopyYankedToClipboard()
  # ... (这部分代码保持不变) ...
  var txt = getreg('"')
  if txt ==# ''
    return
  endif
  if !CopyToSystemClipboard(txt)
    echohl WarningMsg
    echom 'SimpleClipboard: copy failed. Check daemon, or install wl-copy/xsel, or ensure OSC52.'
    echohl None
  endif
enddef

export def CopyRangeToClipboard(l1: number, l2: number)
  # ... (这部分代码保持不变) ...
  var lines = getline(l1, l2)
  var txt = join(lines, "\n")
  if CopyToSystemClipboard(txt)
    echom 'Copied selection to system clipboard'
  else
    echohl WarningMsg
    echom 'SimpleClipboard: copy failed.'
    echohl None
  endif
enddef
