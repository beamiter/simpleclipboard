vim9script

if exists('g:loaded_simpletree')
  finish
endif
g:loaded_simpletree = 1

# =============================================================
# 配置
# =============================================================
g:simpletree_width = get(g:, 'simpletree_width', 45)
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
g:simpletree_page = get(g:, 'simpletree_page', 200)
# 打开文件后保持焦点在文件缓冲区
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 1)
g:simpletree_debug = get(g:, 'simpletree_debug', 0)
g:simpletree_daemon_path = get(g:, 'simpletree_daemon_path', '')
g:simpletree_root_locked = get(g:, 'simpletree_root_locked', 1)
# 自动跟随当前 buffer（默认开启）
g:simpletree_auto_follow = get(g:, 'simpletree_auto_follow', 1)
# 当当前文件不在根目录下时，是否自动切换根到文件所在目录（默认关闭；尊重根锁）
g:simpletree_auto_follow_change_root = get(g:, 'simpletree_auto_follow_change_root', 0)

# =============================================================
# Nerd Font UI 配置与工具
# =============================================================
# 启用 Nerd Font 图标（若终端/GUI无 Nerd Font，可设为 0）
g:simpletree_use_nerdfont = get(g:, 'simpletree_use_nerdfont', 1)
# 是否为文件显示类型图标
g:simpletree_show_file_icons = get(g:, 'simpletree_show_file_icons', 1)
# 目录是否显示斜杠后缀
g:simpletree_folder_suffix = get(g:, 'simpletree_folder_suffix', 1)
# 图标覆盖（如 {'dir': '', 'dir_open': '', 'file': '', 'loading': ''}）
g:simpletree_icons = get(g:, 'simpletree_icons', {})
# 文件类型图标映射覆盖
g:simpletree_file_icon_map = get(g:, 'simpletree_file_icon_map', {})
# 一键折叠（Collapse All）的快捷键（默认 z，缓冲区内生效）
g:simpletree_collapse_all_key = get(g:, 'simpletree_collapse_all_key', 'z')
# 是否在多窗口时弹出选择目标窗口（默认开启）
g:simpletree_choose_window = get(g:, 'simpletree_choose_window', 1)
g:simpletree_split_force_right = get(g:, 'simpletree_split_force_right', 1)

# ---------------- 命令与映射 ----------------
command! -nargs=? -complete=dir SimpleTree simpletree#Toggle(<q-args>)
command! SimpleTreeRefresh simpletree#Refresh()
command! SimpleTreeClose simpletree#Close()
command! SimpleTreeDebug call simpletree#DebugStatus()

nnoremap <silent> <leader>e <Cmd>SimpleTree<CR>

# ---------------- 自动命令 ----------------
augroup SimpleTreeBackend
  autocmd!
  autocmd VimLeavePre * try | call simpletree#Stop() | catch | endtry
augroup END

augroup SimpleTreeAutoFollow
  autocmd!
  # 进入任意缓冲区后尝试自动跟随；仅在启用时生效
  autocmd BufEnter * if get(g:, 'simpletree_auto_follow', 1) |
        \ try | call simpletree#AutoFollow() | catch | endtry |
        \ endif
augroup END
