vim9script

if exists('g:loaded_simpletree')
  finish
endif
g:loaded_simpletree = 1

# ---------------- 配置项（可在 vimrc 中覆盖） ----------------
g:simpletree_width = get(g:, 'simpletree_width', 30)
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
g:simpletree_page = get(g:, 'simpletree_page', 200)
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 1)
g:simpletree_debug = get(g:, 'simpletree_debug', 0)
g:simpletree_daemon_path = get(g:, 'simpletree_daemon_path', '')

# ---------------- 命令与映射 ----------------
command! -nargs=? -complete=dir SimpleTree treexplorer#Toggle(<q-args>)
command! SimpleTreeRefresh treexplorer#Refresh()
command! SimpleTreeClose treexplorer#Close()

nnoremap <silent> <leader>e <Cmd>SimpleTree<CR>

# ---------------- 自动命令 ----------------
augroup SimpleTreeBackend
  autocmd!
  autocmd VimLeavePre * try | call treexplorer#Stop() | catch | endtry
augroup END