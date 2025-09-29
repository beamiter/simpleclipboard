vim9script

if exists('g:loaded_simpleclipboard')
  finish
endif
g:loaded_simpleclipboard = 1

# ---------------- 配置项（可在 vimrc 中覆盖） ----------------
g:simpleclipboard_daemon_enabled = get(g:, 'simpleclipboard_daemon_enabled', 1)
g:simpleclipboard_daemon_autostart = get(g:, 'simpleclipboard_daemon_autostart', 1)
g:simpleclipboard_daemon_autostop = get(g:, 'simpleclipboard_daemon_autostop', 0)
g:simpleclipboard_auto_copy = get(g:, 'simpleclipboard_auto_copy', 1)
g:simpleclipboard_libpath = get(g:, 'simpleclipboard_libpath', '')
g:simpleclipboard_daemon_path = get(g:, 'simpleclipboard_daemon_path', '')
g:simpleclipboard_no_default_mappings = get(g:, 'simpleclipboard_no_default_mappings', 0)
g:simpleclipboard_debug = get(g:, 'simpleclipboard_debug', 0)
g:simpleclipboard_debug_to_file = get(g:, 'simpleclipboard_debug_to_file', 0)
g:simpleclipboard_disable_osc52 = get(g:, 'simpleclipboard_disable_osc52', 0)

# --- 新增：自动化中继配置 ---
g:simpleclipboard_auto_relay = get(g:, 'simpleclipboard_auto_relay', 1)
g:simpleclipboard_relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
g:simpleclipboard_final_daemon_port = get(g:, 'simpleclipboard_final_daemon_port', 12345)
# 修改点：将默认的中继方法改为 'daemon'
g:simpleclipboard_relay_method = get(g:, 'simpleclipboard_relay_method', 'daemon')

# ---------------- 命令与映射 ----------------
command! SimpleCopyYank simpleclipboard#CopyYankedToClipboard()
command! -range=% SimpleCopyRange simpleclipboard#CopyRangeToClipboard(<line1>, <line2>)
nnoremap <silent> <Plug>(SimpleCopyYank) <Cmd>SimpleCopyYank<CR>
if !g:simpleclipboard_no_default_mappings
  nmap <leader>y <Plug>(SimpleCopyYank)
  xnoremap <leader>y :<C-U>'<,'>SimpleCopyRange<CR>
endif

# ---------------- 自动命令 ----------------
if g:simpleclipboard_auto_copy
  augroup SimpleClipboardYank
    autocmd!
    autocmd TextYankPost * if g:simpleclipboard_auto_copy | if exists('*timer_start') | call timer_start(0, 'simpleclipboard#CopyYankedToClipboard') | else | call simpleclipboard#CopyYankedToClipboard() | endif | endif
  augroup END
endif

if g:simpleclipboard_daemon_enabled
  augroup SimpleClipboardDaemon
    autocmd!
    if g:simpleclipboard_daemon_autostart
      # 在启动主守护进程前先设置好中继
      autocmd VimEnter * call simpleclipboard#SetupRelayIfNeeded() | call simpleclipboard#StartDaemon()
    endif
    if g:simpleclipboard_daemon_autostop
      autocmd VimLeave * call simpleclipboard#StopDaemon()
    endif
  augroup END
endif
