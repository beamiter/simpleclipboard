vim9script

if exists('g:loaded_ts_hl')
  finish
endif
g:loaded_ts_hl = 1

# 配置项
g:ts_hl_daemon_path = get(g:, 'ts_hl_daemon_path', '')
# 触发高亮的 debounce 毫秒（避免高频 TextChanged 造成过多请求）
g:ts_hl_debounce = get(g:, 'ts_hl_debounce', 120)

# 命令
command! TsHlEnable  call ts_hl#Enable()
command! TsHlDisable call ts_hl#Disable()
command! TsHlToggle  call ts_hl#Toggle()

# 建议快捷键
nnoremap <silent> <leader>th <Cmd>TsHlToggle<CR>
