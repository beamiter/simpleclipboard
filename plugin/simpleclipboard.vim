" plugin/simpleclipboard.vim

vim9script

if exists('g:loaded_simpleclipboard')
  finish
endif
g:loaded_simpleclipboard = 1

if !has('vim9script')
  echoerr 'This plugin requires Vim9 script support'
  finish
endif

# --- 插件配置变量 ---

# 是否在 yank 后自动复制
g:simpleclipboard_auto_copy = get(g:, 'simpleclipboard_auto_copy', 1)

# 可选：手动指定 Rust 库路径（绝对路径）
g:simpleclipboard_libpath = get(g:, 'simpleclipboard_libpath', '')

# --- 新增：守护进程配置 ---
g:simpleclipboard_daemon_enabled = get(g:, 'simpleclipboard_daemon_enabled', 1)


# --- 命令与映射 ---
command! SimpleCopyYank simpleclipboard#CopyYankedToClipboard()
command! -range=% SimpleCopyRange simpleclipboard#CopyRangeToClipboard(<line1>, <line2>)

nnoremap <silent> <Plug>(SimpleCopyYank) <Cmd>SimpleCopyYank<CR>

if !exists('g:simpleclipboard_no_default_mappings') || !g:simpleclipboard_no_default_mappings
  # 普通模式：复制寄存器内容到系统剪贴板
  nmap <leader>y <Plug>(SimpleCopyYank)
  # 可视模式：把选区复制到系统剪贴板（传递范围）
  xnoremap <leader>y :<C-U>'<,'>SimpleCopyRange<CR>
endif

# --- 自动命令 ---

# 自动在 yank 后复制
if g:simpleclipboard_auto_copy
  augroup SimpleClipboardYank
    autocmd!
    autocmd TextYankPost * if g:simpleclipboard_auto_copy | call simpleclipboard#CopyYankedToClipboard() | endif
  augroup END
endif

# 新增：自动管理守护进程
if g:simpleclipboard_daemon_enabled
  augroup SimpleClipboardDaemon
    autocmd!
    # 当Vim启动时，调用autoload中的启动函数
    autocmd VimEnter * call simpleclipboard#StartDaemon()
    # 当Vim退出时，调用autoload中的停止函数
    autocmd VimLeave * call simpleclipboard#StopDaemon()
  augroup END
endif
