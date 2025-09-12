vim9script

var lib: string = ''

def TryLoadLib(): void
  if lib != ''
    return
  endif

  if type(g:simpleclipboard_libpath) == v:t_string && g:simpleclipboard_libpath !=# ''
    if filereadable(g:simpleclipboard_libpath)
      lib = g:simpleclipboard_libpath
      return
    endif
  endif

  var libname = 'libsimpleclipboard.so'
  for dir in split(&runtimepath, ',')
    var path = dir .. '/lib/' .. libname
    if filereadable(path)
      lib = path
      break
    endif
  endfor
enddef

def CopyViaRust(text: string): bool
  TryLoadLib()
  if lib == ''
    return false
  endif
  try
    return libcallnr(lib, 'rust_set_clipboard', text) == 1
  catch
    return false
  endtry
enddef

def CopyViaCmds(text: string): bool
  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    system('wl-copy', text)
    return v:shell_error == 0
  endif

  if executable('xsel')
    system('xsel --clipboard --input', text)
    return v:shell_error == 0
  endif
  if executable('xclip')
    system('xclip -selection clipboard', text)
    return v:shell_error == 0
  endif

  return false
enddef

def CopyViaOsc52(text: string): bool
  if !executable('base64')
    return false
  endif

  # 使用本地变量避免给参数赋值；按字符数安全截断，避免 UTF-8 截断
  var payload = text
  var limit = 1000000
  if strchars(payload) > limit
    payload = strcharpart(payload, 0, limit)
  endif

  var b64 = trim(system('base64 -w0', payload))
  if v:shell_error != 0 || b64 ==# ''
    b64 = system('base64', payload)
    if v:shell_error != 0
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
      return true
    else
      silent! echon seq
      redraw!
      return true
    endif
  catch
    return false
  endtry
enddef

export def CopyToSystemClipboard(text: string): bool
  return CopyViaRust(text) || CopyViaCmds(text) || CopyViaOsc52(text)
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
