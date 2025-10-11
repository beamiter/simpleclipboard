vim9script

if exists('g:loaded_simpletabline')
  finish
endif
g:loaded_simpletabline = 1

# 配置项（可在 vimrc 中覆盖）
g:simpletabline_show_modified = get(g:, 'simpletabline_show_modified', 1)
g:simpletabline_item_sep      = get(g:, 'simpletabline_item_sep', ' | ')
g:simpletabline_key_sep       = get(g:, 'simpletabline_key_sep', ' ')
g:simpletabline_ellipsis      = get(g:, 'simpletabline_ellipsis', ' … ')
g:simpletabline_listed_only   = get(g:, 'simpletabline_listed_only', 1)

# 高亮默认链接到内置 TabLine 组（可按需自定义）
highlight default link SimpleTablineActive   TabLineSel
highlight default link SimpleTablineInactive TabLine
highlight default link SimpleTablineFill     TabLineFill
highlight default link SimpleTablinePickDigit Title

# 启用 tabline（函数由 autoload/simpletabline.vim 提供）
set showtabline=2
set tabline=%!simpletabline#Tabline()

# 命令与映射
command! BufferPick call simpletabline#BufferPick()
nnoremap <silent> <leader>bp :BufferPick<CR>

# 自动刷新与 MRU 更新
augroup SimpleTablineAuto
  autocmd!
  # 初始化（进入 Vim 后）
  autocmd VimEnter * try | call simpletabline#OnBufEnter() | redrawstatus | catch | endtry
  # 其它刷新
  autocmd TabEnter,VimResized * try | redrawstatus | catch | endtry
  autocmd ColorScheme * try
        \ | highlight default link SimpleTablineActive   TabLineSel
        \ | highlight default link SimpleTablineInactive TabLine
        \ | highlight default link SimpleTablineFill     TabLineFill
        \ | highlight default link SimpleTablinePickDigit Title
        \ | catch | endtry
augroup END
