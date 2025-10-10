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
g:ts_hl_auto_enable_filetypes = get(g:, 'ts_hl_auto_enable_filetypes', ['rust', 'c', 'cpp', 'javascript'])

# 当没有活跃缓冲区时是否自动停止 daemon（1=是, 0=否）
g:ts_hl_auto_stop = get(g:, 'ts_hl_auto_stop', 1)

# 调试模式（1=开启, 0=关闭）
g:ts_hl_debug = get(g:, 'ts_hl_debug', 0)

# =============== 命令 ===============
command! TsHlEnable  call ts_hl#Enable()
command! TsHlDisable call ts_hl#Disable()
command! TsHlToggle  call ts_hl#Toggle()

# =============== 快捷键 ===============
# 建议快捷键（用户可在 vimrc 中覆盖）
if !hasmapto('<Plug>TsHlToggle')
  nnoremap <silent> <leader>th <Cmd>TsHlToggle<CR>
endif

# =============== 自定义高亮组颜色 ===============
# 以下是覆盖默认配色的示例

# # 变量使用青色
# highlight TSVariable ctermfg=14 guifg=#00d7ff
#
# # 参数使用橙色
# highlight TSVariableParameter ctermfg=214 guifg=#ffaf00
#
# # 属性/字段使用紫色
# highlight TSProperty ctermfg=170 guifg=#d75fd7
# highlight TSField ctermfg=170 guifg=#d75fd7
#
# # 函数使用亮蓝色
# highlight TSFunction ctermfg=33 guifg=#0087ff
#
# # 类型使用黄色
# highlight TSType ctermfg=11 guifg=#ffff00
#
# # 关键字加粗
# highlight TSKeyword cterm=bold gui=bold
#
# # 字符串使用绿色
# highlight TSString ctermfg=10 guifg=#00ff00

# =============== 自动启动逻辑 ===============
# 如果配置了自动启用文件类型，则在第一次打开对应文件时自动启用
augroup TsHlAutoStart
  autocmd!
  autocmd BufEnter,FileType * call ts_hl#OnBufEvent(bufnr())
augroup END
