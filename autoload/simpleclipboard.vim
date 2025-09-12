vim9script

# =============================================================
# 日志与工具函数
# =============================================================

# 取运行时目录（优先 XDG_RUNTIME_DIR，回退 /tmp）
def RuntimeDir(): string
  var dir = getenv('XDG_RUNTIME_DIR')
  if dir ==# ''
    dir = '/tmp'
  endif
  return dir
enddef

def PidFile(): string
  return RuntimeDir() .. '/simpleclipboard.pid'
enddef

def SocketFile(): string
  return RuntimeDir() .. '/simpleclipboard.sock'
enddef

# 判断 socket 文件是否存在（socket 对 filereadable 可能返回 0，用 getftype 兼容）
def SocketExists(sock: string): bool
  return filereadable(sock) || (has('unix') && getftype(sock) ==# 'socket')
enddef

def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpleclipboard_debug', 0) == 0
    return
  endif

  if get(g:, 'simpleclipboard_debug_to_file', 0)
    try
      var f = get(g:, 'simpleclipboard_debug_file', RuntimeDir() .. '/simpleclipboard.log')
      var line = strftime('%Y-%m-%d %H:%M:%S ') .. msg
      writefile([line], expand(f), 'a')
    catch
      # 如果写文件失败，退回 echom
      echohl hl
      echom '[SimpleClipboard] ' .. msg
      echohl None
    endtry
    return
  endif

  echohl hl
  echom '[SimpleClipboard] ' .. msg
  echohl None
enddef

# 在 runtimepath 中查找某文件
def FindInRuntimepath(rel: string): string
  for dir in split(&runtimepath, ',')
    var path = dir .. '/' .. rel
    if filereadable(path)
      return path
    endif
  endfor
  return ''
enddef

# 查找守护进程可执行文件
def FindDaemon(): string
  var override = get(g:, 'simpleclipboard_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    return override
  endif

  var path = FindInRuntimepath('lib/simpleclipboard-daemon')
  if path !=# '' && executable(path)
    return path
  endif

  return ''
enddef

# 选择动态库文件名（Linux/macOS）
def LibName(): string
  if has('mac')
    return 'libsimpleclipboard.dylib'
  endif
  return 'libsimpleclipboard.so'
enddef

# 加载动态库：优先 g:simpleclipboard_libpath；否则在 runtimepath/lib 下寻找
var client_lib: string = ''

def TryLoadLib(): void
  if client_lib !=# ''
    return
  endif

  var override = get(g:, 'simpleclipboard_libpath', '')
  if type(override) == v:t_string && override !=# ''
    if filereadable(override)
      client_lib = override
      Log('Found lib via g:simpleclipboard_libpath: ' .. client_lib, 'MoreMsg')
      return
    else
      Log('g:simpleclipboard_libpath set but file not found: ' .. override, 'WarningMsg')
    endif
  endif

  var libname = LibName()
  var path = FindInRuntimepath('lib/' .. libname)
  if path !=# ''
    client_lib = path
    Log('Found lib in runtimepath: ' .. path, 'MoreMsg')
  endif
enddef

# =============================================================
# Daemon 就绪检测与等待
# =============================================================

# 检测守护进程是否就绪
# - 优先尝试连接 Unix Socket（使用 call('sockconnect', ...) 动态调用，兼容无 +channel 的 Vim）
# - 不可连接时回退到仅检查 socket 文件是否存在
def IsDaemonReady(): bool
  var sock = SocketFile()
  if !SocketExists(sock)
    return false
  endif

  if exists('*sockconnect')
    try
      var ch = call('sockconnect', ['unix', sock, {timeout: 100}])
      if type(ch) == v:t_number && ch > 0
        if exists('*ch_close')
          call('ch_close', [ch])
        endif
        return true
      endif
    catch
      # ignore
    endtry
    return false
  endif

  # 无 sockconnect 功能时，退回到 socket 文件存在性判断
  return true
enddef

# 等待守护进程在指定时间内就绪
def WaitForDaemon(timeout_ms: number): bool
  var elapsed = 0
  while elapsed < timeout_ms
    if IsDaemonReady()
      return true
    endif
    sleep 50m
    elapsed += 50
  endwhile
  return false
enddef

# =============================================================
# 守护进程管理
# =============================================================

export def StartDaemon()
  var enabled = get(g:, 'simpleclipboard_daemon_enabled', 1)
  if !enabled
    Log('Daemon disabled by g:simpleclipboard_daemon_enabled.', 'Comment')
    return
  endif

  if IsDaemonReady()
    Log('Daemon already running (socket ready).', 'MoreMsg')
    return
  endif

  var daemon = FindDaemon()
  if daemon ==# ''
    echohl ErrorMsg
    echom '[SimpleClipboard] Daemon executable not found. ' ..
          'Set g:simpleclipboard_daemon_path or put simpleclipboard-daemon into runtimepath/lib/.'
    echohl None
    return
  endif

  Log('Starting daemon: ' .. daemon)

  # 注意：去掉不兼容的 'detach' 选项，仅保留 stoponexit: 'none'
  var job_obj = job_start([daemon], {
        out_io: 'null',
        err_io: 'null',
        stoponexit: 'none',
      })

  if job_obj is v:null
    # 兜底：极老版本 Vim 使用 shell 后台启动
    try
      var cmd = 'nohup ' .. shellescape(daemon) .. ' >/dev/null 2>&1 &'
      system(cmd)
    catch
      echohl ErrorMsg
      echom '[SimpleClipboard] Failed to start daemon via job_start and shell fallback.'
      echohl None
      return
    endtry
  endif

  if WaitForDaemon(1500)
    Log('Daemon is up (socket detected).', 'MoreMsg')
  else
    echohl WarningMsg
    echom '[SimpleClipboard] Daemon started but not ready (timeout).'
    echohl None
  endif
enddef

export def StopDaemon()
  var autostop = get(g:, 'simpleclipboard_daemon_autostop', 0)
  if !autostop
    Log('Autostop disabled; skip stopping daemon.', 'Comment')
    return
  endif

  var pidfile = PidFile()
  var sock = SocketFile()

  if filereadable(pidfile)
    try
      var pid = trim(readfile(pidfile)[0])
      if pid !=# ''
        Log('Stopping daemon with PID: ' .. pid .. '...')
        system('kill ' .. pid)
      endif
    catch
      # ignore
    endtry
    try
      delete(pidfile)
    catch
      # ignore
    endtry
  endif

  if SocketExists(sock)
    try
      delete(sock)
    catch
      # ignore
    endtry
  endif

  Log('Daemon stop requested and files cleaned (if any).', 'MoreMsg')
enddef

# =============================================================
# 复制逻辑（守护进程优先，命令行工具与 OSC52 作为回退）
# =============================================================

def CopyViaRust(text: string): bool
  Log('Attempting copy via Rust (daemon)...', 'Question')
  TryLoadLib()
  if client_lib ==# ''
    Log('Skipped Rust: client library not found.', 'Comment')
    return false
  endif

  try
    if libcallnr(client_lib, 'rust_set_clipboard', text) == 1
      Log('Success: Sent text to daemon.', 'ModeMsg')
      return true
    endif

    # 首次尝试失败：按需启动守护进程并重试
    if get(g:, 'simpleclipboard_daemon_enabled', 1)
      Log('First try failed. Starting daemon on-demand...', 'WarningMsg')
      StartDaemon()
      if WaitForDaemon(1500) && libcallnr(client_lib, 'rust_set_clipboard', text) == 1
        Log('Success after starting daemon.', 'ModeMsg')
        return true
      endif
    endif

    Log('Failed: Could not send text to daemon.', 'ErrorMsg')
    return false
  catch
    Log('Error calling client library: ' .. v:exception, 'ErrorMsg')
    return false
  endtry
enddef

# 用异步 job_start 发送数据，避免同步 system 引起的重绘闪屏
def StartCopyJob(argv: list<string>, text: string): bool
  if exists('*job_start')
    try
      var job = job_start(argv, {out_io: 'null', err_io: 'null', in_io: 'pipe'})
      if job isnot v:null
        try
          # 有 chansend/chanclose 用之；无则走后面的 system 兜底
          if exists('*chansend')
            call('chansend', [job, text])
          else
            throw 'no_chansend'
          endif
          if exists('*chanclose')
            call('chanclose', [job, 'in'])
          endif
          return true
        catch
          # 发送失败则回退到同步 system
        endtry
      endif
    catch
      # job_start 不可用或出错，走兜底
    endtry
  endif

  # 兜底：同步 system（老 Vim 或无 chansend）
  system(join(map(copy(argv), 'shellescape(v:val)'), ' '), text)
  return v:shell_error == 0
enddef

def CopyViaCmds(text: string): bool
  Log('Attempting copy via external commands...', 'Question')

  # macOS
  if has('mac') || executable('pbcopy')
    Log('Trying: pbcopy (macOS)', 'Identifier')
    if StartCopyJob(['pbcopy'], text)
      Log('Success: Copied via pbcopy.', 'ModeMsg')
      return true
    endif
    Log('Failed: pbcopy command failed.', 'WarningMsg')
  endif

  # Wayland
  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    Log('Trying: wl-copy (Wayland)', 'Identifier')
    if StartCopyJob(['wl-copy'], text)
      Log('Success: Copied via wl-copy.', 'ModeMsg')
      return true
    endif
    Log('Failed: wl-copy command failed.', 'WarningMsg')
  endif

  # X11: xsel
  if executable('xsel')
    Log('Trying: xsel (X11)', 'Identifier')
    if StartCopyJob(['xsel', '--clipboard', '--input'], text)
      Log('Success: Copied via xsel.', 'ModeMsg')
      return true
    endif
    Log('Failed: xsel command failed.', 'WarningMsg')
  endif

  # X11: xclip
  if executable('xclip')
    Log('Trying: xclip (X11)', 'Identifier')
    if StartCopyJob(['xclip', '-selection', 'clipboard'], text)
      Log('Success: Copied via xclip.', 'ModeMsg')
      return true
    endif
    Log('Failed: xclip command failed.', 'WarningMsg')
  endif

  Log('Skipped Cmds: No suitable command (pbcopy/wl-copy/xsel/xclip) found or all failed.', 'Comment')
  return false
enddef

def CopyViaOsc52(text: string): bool
  if get(g:, 'simpleclipboard_disable_osc52', 0)
    Log('Skipped OSC52: disabled by g:simpleclipboard_disable_osc52.', 'Comment')
    return false
  endif

  Log('Attempting copy via OSC52 terminal sequence...', 'Question')

  if !executable('base64')
    Log('Skipped OSC52: `base64` command not executable.', 'Comment')
    return false
  endif

  var payload = text
  var limit = 16000000
  if strchars(payload) > limit
    Log('Text truncated to ' .. limit .. ' characters for OSC52.', 'Comment')
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
      # 为避免闪屏，不用 echon/redraw 路径
      Log('Skipped OSC52 echo path: /dev/tty not available.', 'Comment')
      return false
    endif
    return true
  catch
    Log('Failed: Error writing OSC52 sequence. Details: ' .. v:exception, 'ErrorMsg')
    return false
  endtry
enddef

export def CopyToSystemClipboard(text: string): bool
  # 优先使用守护进程，其次外部命令，最后 OSC52
  return CopyViaRust(text) || CopyViaCmds(text) || CopyViaOsc52(text)
enddef

export def CopyYankedToClipboard(_timer_id: any = 0)
  var txt = getreg('"')
  if txt ==# ''
    return
  endif
  if !CopyToSystemClipboard(txt)
    echohl WarningMsg
    echom 'SimpleClipboard: copy failed. Check daemon, or install wl-copy/xsel/xclip, or ensure OSC52.'
    echohl None
  endif
enddef

export def CopyRangeToClipboard(l1: number, l2: number)
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
