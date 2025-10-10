vim9script

export def set(mode: string)
  if mode !=# 'dark' && mode !=# 'light'
    echohl WarningMsg | echom 'spacemacs_theme: invalid mode ' .. mode | echohl None
    return
  endif
  g:spacemacs_theme_mode = mode
  &background = mode
  try
    execute 'colorscheme spacemacs'
  catch
    " 若 colorscheme 文件未就绪，忽略错误
  endtry
enddef

export def toggle()
  var cur = get(g:, 'spacemacs_theme_mode', &background)
  var next = cur ==# 'dark' ? 'light' : 'dark'
  set(next)
enddef
