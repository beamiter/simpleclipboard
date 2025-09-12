vim9script
# simpleclipboard.vim

# ----------------- 新增的日志功能 -----------------
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
# ---------------------------------------------------


var lib: string = ''

def TryLoadLib(): void
  if lib != ''
    return
  endif

  # 检查用户指定的路径
  if type(g:simpleclipboard_libpath) == v:t_string && g:simpleclipboard_libpath !=# ''
    if filereadable(g:simpleclipboard_libpath)
      lib = g:simpleclipboard_libpath
      Log($"Found lib via g:simpleclipboard_libpath: {lib}", 'MoreMsg') # ---> LOG
      return
    else
      Log($"g:simpleclipboard_libpath set but file not found: {g:simpleclipboard_libpath}", 'WarningMsg') # ---> LOG
    endif
  endif

  # 遍历 runtimepath 寻找库文件
  var libname = 'libsimpleclipboard.so'
  for dir in split(&runtimepath, ',')
    var path = dir .. '/target/release/' .. libname
    if filereadable(path)
      lib = path
      Log($"Found lib in runtimepath: {path}", 'MoreMsg') # ---> LOG
      break
    endif
  endfor
enddef

def CopyViaRust(text: string): bool
  Log('Attempting copy via Rust...', 'Question') # ---> LOG
  TryLoadLib()
  if lib == ''
    Log('Skipped Rust: library not found.', 'Comment') # ---> LOG
    return false
  endif

  try
    var result = libcallnr(lib, 'rust_set_clipboard', text) == 1
    if result
      Log('Success: Copied via Rust library.', 'ModeMsg') # ---> LOG
    else
      Log('Failed: Rust library call did not return success.', 'WarningMsg') # ---> LOG
    endif
    return result
  catch
    Log($"Failed: Error calling Rust library. Details: {v:exception}", 'ErrorMsg') # ---> LOG
    return false
  endtry
enddef

def CopyViaCmds(text: string): bool
  Log('Attempting copy via external commands...', 'Question') # ---> LOG

  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    Log('Trying: wl-copy (Wayland)', 'Identifier') # ---> LOG
    system('wl-copy', text)
    if v:shell_error == 0
      Log('Success: Copied via wl-copy.', 'ModeMsg') # ---> LOG
      return true
    endif
    Log('Failed: wl-copy command failed.', 'WarningMsg') # ---> LOG
  endif

  if executable('xsel')
    Log('Trying: xsel (X11)', 'Identifier') # ---> LOG
    system('xsel --clipboard --input', text)
    if v:shell_error == 0
      Log('Success: Copied via xsel.', 'ModeMsg') # ---> LOG
      return true
    endif
    Log('Failed: xsel command failed.', 'WarningMsg') # ---> LOG
  endif

  if executable('xclip')
    Log('Trying: xclip (X11)', 'Identifier') # ---> LOG
    system('xclip -selection clipboard', text)
    if v:shell_error == 0
      Log('Success: Copied via xclip.', 'ModeMsg') # ---> LOG
      return true
    endif
    Log('Failed: xclip command failed.', 'WarningMsg') # ---> LOG
  endif
  
  Log('Skipped Cmds: No suitable command (wl-copy, xsel, xclip) found or all failed.', 'Comment') # ---> LOG
  return false
enddef

def CopyViaOsc52(text: string): bool
  Log('Attempting copy via OSC52 terminal sequence...', 'Question') # ---> LOG
  if !executable('base64')
    Log('Skipped OSC52: `base64` command not executable.', 'Comment') # ---> LOG
    return false
  endif

  # 使用本地变量避免给参数赋值；按字符数安全截断，避免 UTF-8 截断
  var payload = text
  var limit = 1000000
  if strchars(payload) > limit
    Log($"Text truncated to {limit} characters for OSC52.", 'Comment') # ---> LOG
    payload = strcharpart(payload, 0, limit)
  endif

  var b64 = trim(system('base64 -w0', payload))
  if v:shell_error != 0 || b64 ==# ''
    b64 = system('base64', payload)
    if v:shell_error != 0
      Log('Failed: base64 encoding failed.', 'WarningMsg') # ---> LOG
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
      Log('Success: Sent OSC52 sequence to /dev/tty.', 'ModeMsg') # ---> LOG
    else
      silent! echon seq
      redraw!
      Log('Success: Sent OSC52 sequence via echo.', 'ModeMsg') # ---> LOG
    endif
    return true
  catch
    Log($"Failed: Error writing OSC52 sequence. Details: {v:exception}", 'ErrorMsg') # ---> LOG
    return false
  endtry
enddef

export def CopyToSystemClipboard(text: string): bool
  # 链式调用，如果前者成功，则后者不会执行
  # 日志将准确反映出执行路径
  return CopyViaRust(text) || CopyViaCmds(text) || CopyViaOsc52(text)
  # return CopyViaCmds(text)
enddef

export def CopyYankedToClipboard()
  var txt = getreg('"')
  if txt ==# ''
    return
  endif
  if !CopyToSystemClipboard(txt)
    echohl WarningMsg
    echom 'SimpleClipboard: copy failed. Build libsimpleclipboard.so or install wl-copy/xsel, or ensure OSC52.'
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
