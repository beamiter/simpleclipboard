vim9script

if exists('g:loaded_simpletabline')
  finish
endif
g:loaded_simpletabline = 1

# 配置项（可在 vimrc 中覆盖）
g:simpletabline_show_modified = get(g:, 'simpletabline_show_modified', 1)
g:simpletabline_item_sep      = get(g:, 'simpletabline_item_sep', ' | ')
# 前缀分隔改为一个空格，视觉更清晰
g:simpletabline_key_sep       = get(g:, 'simpletabline_key_sep', '  ')
# 默认关闭上标数字，避免过小不清晰
g:simpletabline_superscript_index = get(g:, 'simpletabline_superscript_index', 1)
g:simpletabline_listed_only   = get(g:, 'simpletabline_listed_only', 1)
g:simpletabline_pick_chars    = get(g:, 'simpletabline_pick_chars', 'asdfjkl;ghqweruiop')

# 可配置的青色（前景），用于当前 buffer 名与当前分隔符
g:simpletabline_cyan_gui   = get(g:, 'simpletabline_cyan_gui', '#00ffff')
g:simpletabline_cyan_cterm = get(g:, 'simpletabline_cyan_cterm', '14')

# 高亮默认链接到内置 TabLine 组（可按需自定义）
highlight default link SimpleTablineActive        TabLineSel
highlight default link SimpleTablineInactive      TabLine
highlight default link SimpleTablineFill          TabLineFill
highlight default link SimpleTablinePickDigit     Title
highlight default link SimpleTablineIndex         TabLine
highlight default link SimpleTablineIndexActive   TabLineSel
highlight default link SimpleTablineSep           TabLine
highlight default link SimpleTablineSepCurrent    TabLineSel
highlight SimpleTablinePickHint guifg=#ff0000 ctermfg=red gui=bold cterm=bold

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

def g:SimpleTablineApplyHL()
  # 当前项背景（TabLineSel）
  var id_sel   = synIDtrans(hlID('TabLineSel'))
  var bg_gui_s = synIDattr(id_sel, 'bg#', 'gui')
  var bg_ctm_s = synIDattr(id_sel, 'bg',  'cterm')
  if bg_gui_s ==# '' | bg_gui_s = 'NONE' | endif
  if bg_ctm_s ==# '' || bg_ctm_s =~# '^\D' | bg_ctm_s = 'NONE' | endif

  var cyan_gui   = g:simpletabline_cyan_gui
  var cyan_cterm = g:simpletabline_cyan_cterm

  # 当前分隔符 / 当前项名称 / 当前索引：青色前景 + TabLineSel 背景，加粗
  execute 'highlight SimpleTablineSepCurrent guifg=' .. cyan_gui .. ' guibg=' .. bg_gui_s .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. bg_ctm_s .. ' cterm=bold'
  execute 'highlight SimpleTablineActive     guifg=' .. cyan_gui .. ' guibg=' .. bg_gui_s .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. bg_ctm_s .. ' cterm=bold'
  execute 'highlight SimpleTablineIndexActive guifg=' .. cyan_gui .. ' guibg=' .. bg_gui_s .. ' gui=bold ctermfg=' .. cyan_cterm .. ' ctermbg=' .. bg_ctm_s .. ' cterm=bold'

  # 非当前分隔符背景（TabLine），避免灰色突兀
  var id_inact    = synIDtrans(hlID('TabLine'))
  var sep_bg_gui  = synIDattr(id_inact, 'bg#', 'gui')
  var sep_bg_ctm  = synIDattr(id_inact, 'bg',  'cterm')
  var sep_fg_gui  = synIDattr(id_inact, 'fg#', 'gui')
  var sep_fg_ctm  = synIDattr(id_inact, 'fg',  'cterm')
  if sep_bg_gui ==# '' | sep_bg_gui = 'NONE' | endif
  if sep_bg_ctm ==# '' || sep_bg_ctm =~# '^\D' | sep_bg_ctm = 'NONE' | endif
  if sep_fg_gui ==# '' | sep_fg_gui = 'NONE' | endif
  if sep_fg_ctm ==# '' || sep_fg_ctm =~# '^\D' | sep_fg_ctm = 'NONE' | endif

  # 非当前分隔符：使用 TabLine 的前景/背景（与 SimpleTablineInactive 一致）
  execute 'highlight SimpleTablineSep guifg=' .. sep_fg_gui .. ' guibg=' .. sep_bg_gui .. ' ctermfg=' .. sep_fg_ctm .. ' ctermbg=' .. sep_bg_ctm
enddef

augroup SimpleTablineAuto
  autocmd!
  autocmd VimEnter * call g:SimpleTablineApplyHL() | redrawstatus
  autocmd ColorScheme * highlight default link SimpleTablineActive        TabLineSel
        \ | highlight default link SimpleTablineInactive      TabLine
        \ | highlight default link SimpleTablineFill          TabLineFill
        \ | highlight default link SimpleTablinePickDigit     Title
        \ | highlight default link SimpleTablineIndex         TabLine
        \ | highlight default link SimpleTablineIndexActive   TabLineSel
        \ | highlight default link SimpleTablineSep           TabLine
        \ | highlight default link SimpleTablineSepCurrent    TabLineSel
        \ | call g:SimpleTablineApplyHL()
augroup END

augroup SimpleTablineRefresh
  autocmd!
  autocmd User SimpleTablineRefresh redrawtabline
augroup END
