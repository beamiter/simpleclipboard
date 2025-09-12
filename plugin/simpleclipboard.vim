vim9script

if exists('g:loaded_simpleclipboard')
  finish
endif
g:loaded_simpleclipboard = 1

# ---------------- 配置项（可在 vimrc 中覆盖） ----------------
# 是否启用守护进程相关逻辑
g:simpleclipboard_daemon_enabled = get(g:, 'simpleclipboard_daemon_enabled', 1)
# 自动在 Vim 启动时启动守护进程（推荐开启）
g:simpleclipboard_daemon_autostart = get(g:, 'simpleclipboard_daemon_autostart', 1)
# 自动在 Vim 退出时停止守护进程（默认关闭，避免误杀其他 Vim 正在使用的守护进程）
g:simpleclipboard_daemon_autostop = get(g:, 'simpleclipboard_daemon_autostop', 0)

# 是否在 yank 后自动复制到系统剪贴板
g:simpleclipboard_auto_copy = get(g:, 'simpleclipboard_auto_copy', 1)

# 可选：手动指定 Rust 客户端库与守护进程路径（绝对路径）
# 如果不设置，将自动在 runtimepath 的 lib/ 目录下查找
g:simpleclipboard_libpath = get(g:, 'simpleclipboard_libpath', '')
g:simpleclipboard_daemon_path = get(g:, 'simpleclipboard_daemon_path', '')

# 是否关闭默认映射（<leader>y）
g:simpleclipboard_no_default_mappings = get(g:, 'simpleclipboard_no_default_mappings', 0)

# 调试日志（1 开启，0 关闭）
g:simpleclipboard_debug = get(g:, 'simpleclipboard_debug', 0)

# ---------------- 命令与映射 ----------------
command! SimpleCopyYank simpleclipboard#CopyYankedToClipboard()
command! -range=% SimpleCopyRange simpleclipboard#CopyRangeToClipboard(<line1>, <line2>)

nnoremap <silent> <Plug>(SimpleCopyYank) <Cmd>SimpleCopyYank<CR>

if !g:simpleclipboard_no_default_mappings
  # 普通模式：复制寄存器内容到系统剪贴板
  nmap <leader>y <Plug>(SimpleCopyYank)
  # 可视模式：把选区复制到系统剪贴板（传递范围）
  xnoremap <leader>y :<C-U>'<,'>SimpleCopyRange<CR>
endif

# ---------------- 自动命令 ----------------
if g:simpleclipboard_auto_copy
  augroup SimpleClipboardYank
    autocmd!
    autocmd TextYankPost * if g:simpleclipboard_auto_copy | call simpleclipboard#CopyYankedToClipboard() | endif
  augroup END
endif

if g:simpleclipboard_daemon_enabled
  augroup SimpleClipboardDaemon
    autocmd!
    if g:simpleclipboard_daemon_autostart
      autocmd VimEnter * call simpleclipboard#StartDaemon()
    endif
    if g:simpleclipboard_daemon_autostop
      autocmd VimLeave * call simpleclipboard#StopDaemon()
    endif
  augroup END
endif
