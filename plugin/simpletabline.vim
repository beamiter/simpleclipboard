vim9script

if exists('g:loaded_simpletabline')
  finish
endif
g:loaded_simpletabline = 1

# 配置项（可在 vimrc 中覆盖）
g:simpletabline_show_modified = get(g:, 'simpletabline_show_modified', 1)
g:simpletabline_item_sep      = get(g:, 'simpletabline_item_sep', ' | ')
g:simpletabline_key_sep       = get(g:, 'simpletabline_key_sep', '')   # 默认无间隙
g:simpletabline_ellipsis      = get(g:, 'simpletabline_ellipsis', ' … ')
g:simpletabline_listed_only   = get(g:, 'simpletabline_listed_only', 1)
g:simpletabline_superscript_index = get(g:, 'simpletabline_superscript_index', 1)
g:simpletabline_pick_chars       = get(g:, 'simpletabline_pick_chars', 'asdfjkl;ghqweruiop')   # 默认无间隙

# 高亮默认链接到内置 TabLine 组（可按需自定义）
highlight default link SimpleTablineActive        TabLineSel
highlight default link SimpleTablineInactive      TabLine
highlight default link SimpleTablineFill          TabLineFill
highlight default link SimpleTablinePickDigit     Title
highlight default link SimpleTablineIndex         TabLine
highlight default link SimpleTablineIndexActive   TabLineSel
highlight default link SimpleTablineSep           TabLineFill
# SepCurrent 将在后续函数里改为青色前景 + 继承 TabLineSel 背景（并加粗）
highlight default link SimpleTablineSepCurrent    TabLineSel
highlight SimpleTablinePickHint guifg=#ff0000 ctermfg=red gui=bold cterm=bold

# 根据当前主题设置 SimpleTablineSepCurrent 为青色（前景），背景沿用 TabLineSel，并加粗
def ApplySepCurrentHL()
  try
    var id = synIDtrans(hlID('TabLineSel'))
    var bg_hex = synIDattr(id, 'bg#')
    var ctermbg = synIDattr(id, 'bg')

    var bg_gui = (bg_hex ==# '' ? 'NONE' : bg_hex)
    var bg_cterm = (ctermbg ==# '' ? 'NONE' : ctermbg)

    # 青色前景：GUI 使用 #00ffff，cterm 使用 14（LightCyan），加粗
    execute 'highlight SimpleTablineSepCurrent guifg=#00ffff guibg=' .. bg_gui .. ' gui=bold ctermfg=14 ctermbg=' .. bg_cterm .. ' cterm=bold'
  catch
  endtry
enddef

# 启用 tabline（函数由 autoload/simpletabline.vim 提供）
set showtabline=2
set tabline=%!simpletabline#Tabline()

# 命令与映射
command! BufferPick  call simpletabline#BufferPick()
nnoremap <silent> <leader>bp :BufferPick<CR>
nnoremap <silent> <leader>bj :BufferPick<CR>
command! BufferJump1 call simpletabline#BufferJump1()
command! BufferJump2 call simpletabline#BufferJump2()
command! BufferJump3 call simpletabline#BufferJump3()
command! BufferJump4 call simpletabline#BufferJump4()
command! BufferJump5 call simpletabline#BufferJump5()
command! BufferJump6 call simpletabline#BufferJump6()
command! BufferJump7 call simpletabline#BufferJump7()
command! BufferJump8 call simpletabline#BufferJump8()
command! BufferJump9 call simpletabline#BufferJump9()
command! BufferJump0 call simpletabline#BufferJump0()

# 自动刷新与主题适配
augroup SimpleTablineAuto
  autocmd!
  # 初始化（进入 Vim 后）
  autocmd VimEnter * try
        \ | call ApplySepCurrentHL()
        \ | redrawstatus
        \ | catch | endtry
  # 其它刷新
  autocmd TabEnter,VimResized * try | redrawstatus | catch | endtry
  # 更换主题时，重新设置高亮
  autocmd ColorScheme * try
        \ | highlight default link SimpleTablineActive        TabLineSel
        \ | highlight default link SimpleTablineInactive      TabLine
        \ | highlight default link SimpleTablineFill          TabLineFill
        \ | highlight default link SimpleTablinePickDigit     Title
        \ | highlight default link SimpleTablineIndex         TabLine
        \ | highlight default link SimpleTablineIndexActive   TabLineSel
        \ | highlight default link SimpleTablineSep           TabLineFill
        \ | highlight default link SimpleTablineSepCurrent    TabLineSel
        \ | call ApplySepCurrentHL()
        \ | catch | endtry
augroup END

augroup SimpleTablineRefresh
  autocmd!
  autocmd User SimpleTablineRefresh redrawtabline
augroup END
