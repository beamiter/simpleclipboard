vim9script

if exists('g:loaded_simpleclipboard')
  finish
endif
if v:version < 900 || !has('job') || !has('channel')
  echohl ErrorMsg
  echom '[SimpleClipboard] Vim 9.0+ with +job and +channel is required.'
  echohl None
  finish
endif
g:loaded_simpleclipboard = 1

# Configuration defaults. Set these before the plugin is loaded to override.
g:simpleclipboard_daemon_enabled = get(g:, 'simpleclipboard_daemon_enabled', 1)
g:simpleclipboard_daemon_autostart = get(g:, 'simpleclipboard_daemon_autostart', 1)
g:simpleclipboard_daemon_autostop = get(g:, 'simpleclipboard_daemon_autostop', 0)
g:simpleclipboard_auto_copy = get(g:, 'simpleclipboard_auto_copy', 1)
# Empty means every yank register except the black-hole register, preserving
# the historical behaviour.  A non-empty list is an explicit allow-list.
g:simpleclipboard_auto_copy_registers = get(g:, 'simpleclipboard_auto_copy_registers', [])
# 0 keeps automatic yanks unlimited; manual commands are never size-limited.
g:simpleclipboard_auto_copy_max_bytes = get(g:, 'simpleclipboard_auto_copy_max_bytes', 0)
g:simpleclipboard_libpath = get(g:, 'simpleclipboard_libpath', '')
g:simpleclipboard_daemon_path = get(g:, 'simpleclipboard_daemon_path', '')
g:simpleclipboard_no_default_mappings = get(g:, 'simpleclipboard_no_default_mappings', 0)
g:simpleclipboard_debug = get(g:, 'simpleclipboard_debug', 0)
g:simpleclipboard_debug_to_file = get(g:, 'simpleclipboard_debug_to_file', 0)
g:simpleclipboard_debug_file = get(g:, 'simpleclipboard_debug_file', '')
g:simpleclipboard_disable_osc52 = get(g:, 'simpleclipboard_disable_osc52', 0)
g:simpleclipboard_osc52_limit = get(g:, 'simpleclipboard_osc52_limit', 75000)
g:simpleclipboard_osc52_truncate = get(g:, 'simpleclipboard_osc52_truncate', 0)
g:simpleclipboard_bind_addr = get(g:, 'simpleclipboard_bind_addr', '127.0.0.1')
g:simpleclipboard_port = get(g:, 'simpleclipboard_port', 12343)
g:simpleclipboard_tunnel_port = get(g:, 'simpleclipboard_tunnel_port', 12345)
g:simpleclipboard_token = get(g:, 'simpleclipboard_token', '')
g:simpleclipboard_address = get(g:, 'simpleclipboard_address', '')
g:simpleclipboard_copy_command = get(g:, 'simpleclipboard_copy_command', [])
g:simpleclipboard_debounce_ms = get(g:, 'simpleclipboard_debounce_ms', 50)
g:simpleclipboard_container_host = get(g:, 'simpleclipboard_container_host', '')

command! SimpleCopyYank simpleclipboard#CopyYankedToClipboard()
command! -nargs=? -complete=customlist,simpleclipboard#CompleteRegister SimpleCopyRegister simpleclipboard#CopyRegisterToClipboard(<q-args>)
command! SimpleCopyVisual simpleclipboard#CopyVisualSelection()
command! -range=% SimpleCopyRange simpleclipboard#CopyRangeToClipboard(<line1>, <line2>)
command! SimpleCopyClear simpleclipboard#ClearClipboard()
command! -bang SimpleCopyPath simpleclipboard#CopyPathToClipboard('<bang>' ==# '!')
command! -bang SimpleCopyLocation simpleclipboard#CopyLocationToClipboard('<bang>' ==# '!')
command! -bang -nargs=* SimpleCopyFormat simpleclipboard#CopyFormatToClipboard(<q-args>, '<bang>' ==# '!')
command! SimpleCopyStart simpleclipboard#StartDaemon()
command! SimpleCopyStop simpleclipboard#StopDaemon()
command! SimpleCopyStatus simpleclipboard#Status()
# Suite-wide convention: every simple* plugin answers to :<Plugin>Health.
command! SimpleCopyHealth simpleclipboard#Status()
command! SimpleCopyRestart simpleclipboard#RestartDaemon()
command! SimpleCopyToggle simpleclipboard#ToggleAutoCopy()
command! -nargs=1 SimpleCopyPause simpleclipboard#PauseAutoCopy(<q-args>)
command! SimpleCopyLog simpleclipboard#ShowLog()
command! SimpleCopyRefresh simpleclipboard#Refresh()

nnoremap <silent> <Plug>(SimpleCopyYank) <Cmd>SimpleCopyYank<CR>
nnoremap <silent> <Plug>(SimpleCopyClear) <Cmd>SimpleCopyClear<CR>
nnoremap <silent> <Plug>(SimpleCopyPath) <Cmd>SimpleCopyPath<CR>
nnoremap <silent> <Plug>(SimpleCopyLocation) <Cmd>SimpleCopyLocation<CR>
nnoremap <silent> <Plug>(SimpleCopyToggle) <Cmd>SimpleCopyToggle<CR>
# A format needs user input, so this target intentionally opens a prefilled
# command line instead of silently invoking an unusable parameterized command.
nnoremap <Plug>(SimpleCopyFormat) :SimpleCopyFormat<Space>
xnoremap <silent> <Plug>(SimpleCopyVisual) :<C-U>SimpleCopyVisual<CR>

if !g:simpleclipboard_no_default_mappings
  if maparg('<leader>y', 'n') ==# '' && !hasmapto('<Plug>(SimpleCopyYank)', 'n')
    nmap <silent> <leader>y <Plug>(SimpleCopyYank)
  endif
  if maparg('<leader>y', 'x') ==# '' && !hasmapto('<Plug>(SimpleCopyVisual)', 'x')
    xmap <silent> <leader>y <Plug>(SimpleCopyVisual)
  endif
endif

# The autocommand is always installed and the handler decides per yank, so
# g:simpleclipboard_auto_copy takes effect the moment it changes.  Latching it
# here would mean a user who disables automatic copy right before yanking a
# credential still has that credential pushed to the system clipboard.
augroup SimpleClipboardYank
  autocmd!
  autocmd TextYankPost * call simpleclipboard#CopyYankedToClipboardEvent(deepcopy(v:event))
augroup END

if g:simpleclipboard_daemon_enabled
  augroup SimpleClipboardDaemon
    autocmd!
    if g:simpleclipboard_daemon_autostart
      if v:vim_did_enter
        call timer_start(0, (_) => simpleclipboard#StartDaemon(false, false))
      else
        autocmd VimEnter * call timer_start(0, (_) => simpleclipboard#StartDaemon(false, false))
      endif
    endif
    if g:simpleclipboard_daemon_autostop
      autocmd VimLeave * call simpleclipboard#StopDaemon(false)
    endif
  augroup END
endif
