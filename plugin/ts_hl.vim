vim9script

if exists('g:loaded_ts_hl')
  finish
endif
g:loaded_ts_hl = 1

# =============== 配置项 ===============
g:ts_hl_daemon_path = get(g:, 'ts_hl_daemon_path', '')
g:ts_hl_debounce = get(g:, 'ts_hl_debounce', 120)
g:ts_hl_auto_enable_filetypes = get(g:, 'ts_hl_auto_enable_filetypes',
  ['rust', 'c', 'cpp', 'javascript', 'vim'])
g:ts_hl_auto_stop = get(g:, 'ts_hl_auto_stop', 1)

g:ts_hl_debug = get(g:, 'ts_hl_debug', 0)
g:ts_hl_log_file = get(g:, 'ts_hl_log_file', '/tmp/ts-hl.log')

g:ts_hl_outline_width = get(g:, 'ts_hl_outline_width', 32)

# Outline UI 配置
g:ts_hl_outline_fancy = get(g:, 'ts_hl_outline_fancy', 1)
g:ts_hl_outline_ascii = get(g:, 'ts_hl_outline_ascii', 0)
g:ts_hl_outline_show_position = get(g:, 'ts_hl_outline_show_position', 1)

# 新增：Outline 过滤配置
g:ts_hl_outline_hide_inner_functions = get(g:, 'ts_hl_outline_hide_inner_functions', 1)
g:ts_hl_outline_exclude_patterns = get(g:, 'ts_hl_outline_exclude_patterns', [])

# =============== 命令 ===============
command! TsHlEnable  call ts_hl#Enable()
command! TsHlDisable call ts_hl#Disable()
command! TsHlToggle  call ts_hl#Toggle()

command! TsHlOutlineOpen    call ts_hl#OutlineOpen()
command! TsHlOutlineClose   call ts_hl#OutlineClose()
command! TsHlOutlineToggle  call ts_hl#OutlineToggle()
command! TsHlOutlineRefresh call ts_hl#OutlineRefresh()
command! TsHlDumpAST        call ts_hl#DumpAST()

# =============== 快捷键 ===============
if !hasmapto('<Plug>TsHlToggle')
  nnoremap <silent> <leader>th <Cmd>TsHlToggle<CR>
endif
if !hasmapto('<Plug>TsHlOutlineToggle')
  nnoremap <silent> <leader>to <Cmd>TsHlOutlineToggle<CR>
endif

# =============== 自动启动逻辑 ===============
augroup TsHlAutoStart
  autocmd!
  autocmd BufEnter,FileType * call ts_hl#OnBufEvent(bufnr())
augroup END
