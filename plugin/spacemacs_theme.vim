vim9script

import autoload 'spacemacs_theme.vim' as Theme

command! SpacemacsThemeToggle Theme.toggle()
command! SpacemacsThemeDark Theme.set('dark')
command! SpacemacsThemeLight Theme.set('light')

# 可选：首次加载时，若用户未设置模式，则以当前 &background 为准
if !exists('g:spacemacs_theme_mode')
  g:spacemacs_theme_mode = &background
endif
