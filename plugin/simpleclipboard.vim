vim9script

if exists('g:loaded_simpleclipboard')
  finish
endif
g:loaded_simpleclipboard = 1
g:simpleclipboard_token = get(g:, 'simpleclipboard_token', '')

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
g:simpleclipboard_bind_addr = get(g:, 'simpleclipboard_bind_addr', '127.0.0.1')

# --- 端口规划 ---
# 本地主守护进程监听的端口
g:simpleclipboard_port = get(g:, 'simpleclipboard_port', 12344)
# 中继守护进程监听的端口
g:simpleclipboard_relay_port = get(g:, 'simpleclipboard_relay_port', 12346)
# SSH 隧道在远程主机上监听的端口 (中继的目标)
g:simpleclipboard_final_daemon_port = get(g:, 'simpleclipboard_final_daemon_port', 12345)

# --- 自动化中继配置 ---
g:simpleclipboard_auto_relay = get(g:, 'simpleclipboard_auto_relay', 1)
g:simpleclipboard_relay_method = get(g:, 'simpleclipboard_relay_method', 'daemon')
# 全局状态守卫，防止重复设置
g:simpleclipboard_relay_setup_done = get(g:, 'simpleclipboard_relay_setup_done', 0)

# ---------------- 命令与映射 ----------------
command! SimpleCopyYank simpleclipboard#CopyYankedToClipboard()
command! -range=% SimpleCopyRange simpleclipboard#CopyRangeToClipboard(<line1>, <line2>)
nnoremap <silent> <Plug>(SimpleCopyYank) <Cmd>SimpleCopyYank<CR>
if !g:simpleclipboard_no_default_mappings
  nnoremap <silent> <leader>y <Plug>(SimpleCopyYank)
  xnoremap <silent> <leader>y :<C-U>'<,'>SimpleCopyRange<CR>
endif

# ---------------- 自动命令 ----------------
if g:simpleclipboard_auto_copy
  augroup SimpleClipboardYank
    autocmd!
    if exists('*timer_start')
      autocmd TextYankPost * call timer_start(0, function('simpleclipboard#CopyYankedToClipboardEvent', [v:event]))
    else
      # 无 timer_start 时直接调用，传 1 个参数也匹配上面的函数签名
      autocmd TextYankPost * call simpleclipboard#CopyYankedToClipboardEvent(v:event)
    endif
  augroup END
endif

if g:simpleclipboard_daemon_enabled
  augroup SimpleClipboardDaemon
    autocmd!
    if g:simpleclipboard_daemon_autostart
      autocmd VimEnter * call simpleclipboard#SetupRelayIfNeeded() | call simpleclipboard#StartDaemon()
    endif
    if g:simpleclipboard_daemon_autostop
      autocmd VimLeave * call simpleclipboard#StopDaemon()
    endif
  augroup END
endif
