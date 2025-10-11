vim9script

if exists('g:loaded_ts_hl')
  finish
endif
g:loaded_ts_hl = 1

# =============== 配置项 ===============
# daemon 路径（如果不在 runtimepath 中）
g:ts_hl_daemon_path = get(g:, 'ts_hl_daemon_path', '')

# 触发高亮的 debounce 毫秒（避免高频 TextChanged 造成过多请求）
g:ts_hl_debounce = get(g:, 'ts_hl_debounce', 120)

# 自动启用的文件类型列表（为空则禁用自动启用）
g:ts_hl_auto_enable_filetypes = get(g:, 'ts_hl_auto_enable_filetypes',
  ['rust', 'c', 'cpp', 'javascript', 'vim'])

# 当没有活跃缓冲区时是否自动停止 daemon（1=是, 0=否）
g:ts_hl_auto_stop = get(g:, 'ts_hl_auto_stop', 1)

# 调试开关和日志文件
g:ts_hl_debug = get(g:, 'ts_hl_debug', 0)
g:ts_hl_log_file = get(g:, 'ts_hl_log_file', '/tmp/ts-hl.log')

# 侧边栏宽度
g:ts_hl_outline_width = get(g:, 'ts_hl_outline_width', 32)

# =============== 命令 ===============
command! TsHlEnable  call ts_hl#Enable()
command! TsHlDisable call ts_hl#Disable()
command! TsHlToggle  call ts_hl#Toggle()

# 侧边栏命令
command! TsHlOutlineOpen   call ts_hl#OutlineOpen()
command! TsHlOutlineClose  call ts_hl#OutlineClose()
command! TsHlOutlineToggle call ts_hl#OutlineToggle()
command! TsHlOutlineRefresh call ts_hl#OutlineRefresh()
command! TsHlDumpAST call ts_hl#DumpAST()

# =============== 快捷键 ===============
# 建议快捷键（用户可在 vimrc 中覆盖）
if !hasmapto('<Plug>TsHlToggle')
  nnoremap <silent> <leader>th <Cmd>TsHlToggle<CR>
endif

# 侧边栏 Toggle
if !hasmapto('<Plug>TsHlOutlineToggle')
  nnoremap <silent> <leader>to <Cmd>TsHlOutlineToggle<CR>
endif

# =============== 自动启动逻辑 ===============
# 如果配置了自动启用文件类型，则在第一次打开对应文件时自动启用
augroup TsHlAutoStart
  autocmd!
  autocmd BufEnter,FileType * call ts_hl#OnBufEvent(bufnr())
augroup END
