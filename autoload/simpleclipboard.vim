vim9script

# 内部状态：已解析的 Rust 库路径
var s:lib: string = ''

# 尝试找到 Rust 动态库
def s:try_load_lib(): void
  if s:lib != ''
    return
  endif

  if type(g:simpleclipboard_libpath) == v:t_string && g:simpleclipboard_libpath !=# ''
    if filereadable(g:simpleclipboard_libpath)
      s:lib = g:simpleclipboard_libpath
      return
    endif
  endif

  # 默认在 runtimepath/*/lib/libsimpleclipboard.so 搜索
  var libname = 'libsimpleclipboard.so'
  for dir in split(&runtimepath, ',')
    var path = dir .. '/lib/' .. libname
    if filereadable(path)
      s:lib = path
      break
    endif
  endfor
enddef

# 1) 首选：通过 Rust 动态库写剪贴板
def s:copy_via_rust(text: string): bool
  s:try_load_lib()
  if s:lib == ''
    return false
  endif
  try
    # rust_set_clipboard(const char*) -> int
    return libcallnr(s:lib, 'rust_set_clipboard', text) == 1
  catch
    return false
  endtry
enddef

# 2) 回退：使用系统命令（Wayland -> wl-copy；X11 -> xsel/xclip）
def s:copy_via_cmds(text: string): bool
  # Wayland（优先）
  if exists('$WAYLAND_DISPLAY') && executable('wl-copy')
    var _ = system('wl-copy', text)
    return v:shell_error == 0
  endif

  # X11：优先 xsel，再尝试 xclip
  if executable('xsel')
    var _1 = system('xsel --clipboard --input', text)
    return v:shell_error == 0
  endif
  if executable('xclip')
    var _2 = system('xclip -selection clipboard', text)
    return v:shell_error == 0
  endif

  return false
enddef

# 3) 终极回退：OSC52（终端支持/tmux 支持时可用）
# - 需要 base64 命令；先尝试 -w0（GNU coreutils），失败再去掉 -w0 并手动去换行
def s:copy_via_osc52(text: string): bool
  if !executable('base64')
    return false
  endif

  # 避免过长（一些终端有长度限制）
  if strlen(text) > 1000000
    text = text[:999999]
  endif

  var b64 = trim(system('base64 -w0', text))
  if v:shell_error != 0 || b64 ==# ''
    b64 = system('base64', text)
    if v:shell_error != 0
      return false
    endif
    b64 = substitute(b64, '\n', '', 'g')
  endif

  var seq = ''
  if exists('$TMUX')
    # tmux 需要特殊包裹：ESC P tmux; <OSC52> BEL ESC \
    seq = "\x1bPtmux;\x1b]52;c;" .. b64 .. "\x07\x1b\\"
  else
    seq = "\x1b]52;c;" .. b64 .. "\x07"
  endif

  try
    if has('unix') && filereadable('/dev/tty')
      writefile([seq], '/dev/tty', 'b')
      return true
    else
      " 退而求其次：回显序列（可能污染命令行，但能工作）
      silent! echon seq
      redraw!
      return true
    endif
  catch
    return false
  endtry
enddef

# 对外导出：统一复制接口
export def CopyToSystemClipboard(text: string): bool
  return s:copy_via_rust(text) || s:copy_via_cmds(text) || s:copy_via_osc52(text)
enddef

# 复制最近一次 yank 的寄存器（""）
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

# 复制行范围
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
