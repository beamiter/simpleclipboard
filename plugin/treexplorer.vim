vim9script

if exists('g:loaded_simpletree')
  finish
endif
g:loaded_simpletree = 1

# 命令：:SimpleTree [root]
command! -nargs=? -complete=dir SimpleTree call treexplorer#Toggle(<q-args>)
command! SimpleTreeRefresh call treexplorer#Refresh()
command! SimpleTreeClose call treexplorer#Close()

# 默认映射：<leader>e 打开/关闭
nnoremap <silent> <leader>e :SimpleTree<CR>

# 退出时停止后端（可选）
augroup SimpleTreeBackend
  autocmd!
  autocmd VimLeavePre * try | call treexplorer_backend#Stop() | catch | endtry
augroup END
