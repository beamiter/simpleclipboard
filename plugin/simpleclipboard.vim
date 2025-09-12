vim9script

if exists('g:loaded_simpleclipboard')
  finish
endif
g:loaded_simpleclipboard = 1

if !has('vim9script')
  echoerr 'This plugin requires Vim9 script support'
  finish
endif

# 选项：是否自动在 yank 后复制到系统剪贴板（默认启用）
if !exists('g:simpleclipboard_auto_copy')
  g:simpleclipboard_auto_copy = 1
endif

# 选项：手动指定 Rust 库路径（默认在 &runtimepath/**/lib/libsimpleclipboard.so 中自动查找）
if !exists('g:simpleclipboard_libpath')
  g:simpleclipboard_libpath = ''
endif

# 命令与映射
command! SimpleCopyYank simpleclipboard#CopyYankedToClipboard()
command! -range=% SimpleCopyRange simpleclipboard#CopyRangeToClipboard(<line1>, <line2>)

nnoremap <Plug>(SimpleCopyYank) <Cmd>SimpleCopyYank<CR>

if !exists('g:simpleclipboard_no_default_mappings') || !g:simpleclipboard_no_default_mappings
  # 普通模式：复制寄存器内容到系统剪贴板
  nmap <leader>y <Plug>(SimpleCopyYank)
  # 可视模式：复制选中文本到系统剪贴板
  vmap <leader>y :<C-U>SimpleCopyRange<CR>
endif

# 自动在 yank 后复制
if g:simpleclipboard_auto_copy
  augroup SimpleClipboard
    autocmd!
    autocmd TextYankPost * simpleclipboard#CopyYankedToClipboard()
  augroup END
endif
