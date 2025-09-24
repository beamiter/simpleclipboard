vim9script
import autoload 'treexplorer_backend.vim' as Backend

# ---------------- 配置 ----------------
# 左侧宽度
g:simpletree_width = get(g:, 'simpletree_width', 30)
# 默认是否隐藏点文件
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
# 分块大小（后端每次返回的最大条数）
g:simpletree_page = get(g:, 'simpletree_page', 200)
# 打开文件后是否把焦点留在树窗口（1=留在树，0=切至文件）
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 1)

# ---------------- 内部状态 ----------------
var s:bufnr: number = -1
var s:winid: number = 0
var s:root: string = ''
var s:hide_dotfiles: bool = !!g:simpletree_hide_dotfiles

var s:state: dict<any> = {}     # path -> {expanded: bool}
var s:cache: dict<list<dict<any>>> = {}   # path -> entries[]
var s:loading: dict<bool> = {}  # path -> true
var s:pending: dict<number> = {} # path -> request id
var s:line_index: list<dict<any>> = []   # 渲染行对应的节点

# ---------------- 工具 ----------------
def s:AbsPath(p: string): string
  if p ==# ''
    return simplify(fnamemodify(getcwd(), ':p'))
  endif
  var ap = fnamemodify(p, ':p')
  if ap ==# ''
    ap = fnamemodify(getcwd() .. '/' .. p, ':p')
  endif
  return simplify(ap)
enddef

def s:IsDir(p: string): bool
  return isdirectory(p)
enddef

def s:Join(base: string, name: string): string
  return simplify(fnamemodify(base .. '/' .. name, ':p'))
enddef

def s:GetNodeState(path: string): dict<any>
  if !has_key(s:state, path)
    s:state[path] = {expanded: false}
  endif
  return s:state[path]
enddef

# ---------------- 与后端交互 ----------------
def s:ScanDirAsync(path: string)
  if has_key(s:cache, path) || get(s:loading, path, false)
    return
  endif
  s:loading[path] = true

  var acc: list<dict<any>> = []
  var p = path " 捕获到 lambda
  var req_id = Backend.List(p, !s:hide_dotfiles, g:simpletree_page,
    (entries) => {
      # entries: [{name, path, is_dir}]
      acc += entries
      s:cache[p] = acc
      call s:Render()
    },
    () => {
      s:loading[p] = false
      s:cache[p] = acc
      if has_key(s:pending, p)
        call remove(s:pending, p)
      endif
      call s:Render()
    },
    (msg) => {
      s:loading[p] = false
      if has_key(s:pending, p)
        call remove(s:pending, p)
      endif
      echohl ErrorMsg | echom '[SimpleTree] list error: ' .. msg | echohl None
    })
  s:pending[p] = req_id
enddef

def s:CancelLoad(path: string)
  if has_key(s:pending, path)
    Backend.Cancel(s:pending[path])
    call remove(s:pending, path)
    s:loading[path] = false
  endif
enddef

# ---------------- 渲染 ----------------
def s:TreePrefix(depth: number, is_last: bool): string
  if depth == 0
    return ''
  endif
  return repeat('  ', depth - 1) .. (is_last ? '└─' : '├─')
enddef

def s:Icon(is_dir: bool, expanded: bool): string
  if is_dir
    return expanded ? '📂' : '📁'
  endif
  return '📄'
enddef

def s:BuildLines(path: string, depth: number): list<dict<any>>
  var lines: list<dict<any>> = []
  if !has_key(s:cache, path)
    # 触发加载
    call s:ScanDirAsync(path)
    # 如果当前目录已展开，则显示一个占位子节点
    if depth >= 1
      lines->add({name: '[loading...]', path: path .. '/.loading', is_dir: false, depth: depth, expanded: false, is_last: true, placeholder: true})
    endif
    return lines
  endif

  var entries = s:cache[path]
  var count = len(entries)
  var i = 0
  for e in entries
    i += 1
    var ns = s:GetNodeState(e.path)
    var node = {
      name: e.name,
      path: e.path,
      is_dir: e.is_dir,
      depth: depth,
      expanded: e.is_dir ? ns.expanded : v:false,
      is_last: (i == count),
    }
    lines->add(node)
    if e.is_dir && ns.expanded
      lines += s:BuildLines(e.path, depth + 1)
    endif
  endfor
  return lines
enddef

def s:EnsureWindow()
  if s:winid != 0 && win_gotoid(s:winid)
    return
  endif
  topleft vsplit
  execute 'vertical resize ' .. g:simpletree_width
  s:winid = win_getid()
  enew
  s:bufnr = bufnr()
  setlocal buftype=nofile bufhidden=hide noswapfile nobuflisted
  setlocal nowrap nonumber norelativenumber signcolumn=no foldmethod=manual
  setlocal cursorline
  setlocal filetype=simpletree

  " 映射
  nnoremap <silent> <buffer> <CR> :<C-U>call treexplorer#OpenOrToggle('edit')<CR>
  nnoremap <silent> <buffer> o    :<C-U>call treexplorer#OpenOrToggle('edit')<CR>
  nnoremap <silent> <buffer> l    :<C-U>call treexplorer#OpenOrToggle('edit')<CR>
  nnoremap <silent> <buffer> s    :<C-U>call treexplorer#OpenOrToggle('split')<CR>
  nnoremap <silent> <buffer> v    :<C-U>call treexplorer#OpenOrToggle('vsplit')<CR>
  nnoremap <silent> <buffer> t    :<C-U>call treexplorer#OpenOrToggle('tab')<CR>
  nnoremap <silent> <buffer> h    :<C-U>call treexplorer#Collapse()<CR>
  nnoremap <silent> <buffer> r    :<C-U>call treexplorer#Refresh()<CR>
  nnoremap <silent> <buffer> R    :<C-U>call treexplorer#RenameEntry()<CR>
  nnoremap <silent> <buffer> a    :<C-U>call treexplorer#CreateEntry()<CR>
  nnoremap <silent> <buffer> d    :<C-U>call treexplorer#DeleteEntry()<CR>
  nnoremap <silent> <buffer> H    :<C-U>call treexplorer#ToggleDotfiles()<CR>
  nnoremap <silent> <buffer> q    :<C-U>call treexplorer#Close()<CR>

  call cursor(3, 1)
enddef

def s:Render()
  if s:bufnr <= 0 || !bufexists(s:bufnr)
    return
  endif

  # 记住当前选中节点（path）
  var cur_path = ''
  var cur_node = treexplorer#CurrentNode()
  if !empty(cur_node)
    cur_path = cur_node.path
  endif

  var header = ' SimpleTree: ' .. s:root .. (s:hide_dotfiles ? '  [H: show hidden]' : '  [H: hide hidden]')
  var lines: list<string> = [header, '']
  s:line_index = []

  # 根行
  var root_line = ' ' .. s:root
  lines->add(root_line)
  s:line_index->add({name: s:root, path: s:root, is_dir: true, depth: 0, expanded: true, is_last: true})

  # 内容
  var nodes = s:BuildLines(s:root, 1)
  for n in nodes
    var prefix = s:TreePrefix(n.depth, n.is_last)
    var icon = n->get('placeholder', v:false) ? '⏳' : s:Icon(n.is_dir, n.expanded)
    var line = printf('%s%s %s', prefix, icon, n.name)
    lines->add(line)
    s:line_index->add(n)
  endfor

  var prevwin = win_getid()
  var prevbuf = bufnr()
  try
    execute 'noautocmd keepjumps buffer ' .. s:bufnr
    setlocal modifiable
    call setline(1, lines)
    var last = line('$')
    if last > len(lines)
      execute (len(lines) + 1) .. ',' .. last .. 'delete _'
    endif
    setlocal nomodifiable
  finally
    if bufnr() != prevbuf
      execute 'noautocmd keepjumps buffer ' .. prevbuf
    endif
    call win_gotoid(prevwin)
  endtry

  " 恢复光标
  if cur_path !=# ''
    call treexplorer#JumpToPath(cur_path)
  endif
enddef

def s:OpenFile(path: string, how: string)
  var treewin = s:winid
  " 切到最近的非树窗口
  var wins = getwininfo()
  var target = 0
  for w in wins
    if w.winid != treewin && getbufvar(w.bufnr, '&buftype') ==# '' && bufname(w.bufnr) !=# ''
      target = w.winid
      break
    endif
  endfor
  if target != 0
    call win_gotoid(target)
  else
    rightbelow vsplit
  endif
  if how ==# 'split'
    execute 'split ' .. fnameescape(path)
  elseif how ==# 'vsplit'
    execute 'vsplit ' .. fnameescape(path)
  elseif how ==# 'tab'
    execute 'tabedit ' .. fnameescape(path)
  else
    execute 'edit ' .. fnameescape(path)
  endif

  if g:simpletree_keep_focus
    call win_gotoid(treewin)
  endif
enddef

# ---------------- 导出 API ----------------

export def Toggle(root: string = '')
  if s:winid != 0 && win_gotoid(s:winid)
    bwipeout!
    s:bufnr = -1
    s:winid = 0
    return
  endif
  s:root = s:AbsPath(root)
  if !isdirectory(s:root)
    echohl ErrorMsg | echom '[SimpleTree] Invalid root: ' .. s:root | echohl None
    return
  endif
  s:hide_dotfiles = !!g:simpletree_hide_dotfiles
  s:state = {}
  s:cache = {}
  s:loading = {}
  s:pending = {}
  s:state[s:root] = {expanded: true}

  if !Backend.EnsureBackend()
    return
  endif
  call s:EnsureWindow()
  call s:Render()
enddef

export def Refresh()
  if s:bufnr <= 0
    return
  endif
  " 刷新当前节点所在目录
  var n = treexplorer#CurrentNode()
  var dir = ''
  if empty(n)
    dir = s:root
  else
    dir = n.is_dir ? n.path : fnamemodify(n.path, ':h')
  endif
  if has_key(s:cache, dir)
    call remove(s:cache, dir)
  endif
  call s:CancelLoad(dir)
  call s:ScanDirAsync(dir)
  call s:Render()
enddef

export def ToggleDotfiles()
  s:hide_dotfiles = !s:hide_dotfiles
  " 清空缓存，触发重载
  s:cache = {}
  s:loading = {}
  for [p, id] in items(s:pending)
    Backend.Cancel(id)
  endfor
  s:pending = {}
  call s:Render()
enddef

export def Collapse()
  var n = treexplorer#CurrentNode()
  if empty(n) || !n.is_dir
    return
  endif
  s:state[n.path] = {expanded: false}
  call s:Render()
enddef

export def OpenOrToggle(how: string = 'edit')
  var n = treexplorer#CurrentNode()
  if empty(n)
    return
  endif
  if n.is_dir
    var st = s:GetNodeState(n.path)
    st.expanded = !st.expanded
    s:state[n.path] = st
    if st.expanded && !has_key(s:cache, n.path)
      call s:ScanDirAsync(n.path)
    endif
    call s:Render()
  else
    call s:OpenFile(n.path, how)
  endif
enddef

export def Close()
  if s:winid != 0 && win_gotoid(s:winid)
    bwipeout!
  endif
  s:bufnr = -1
  s:winid = 0
enddef

# 当前行的节点
export def CurrentNode(): dict<any>
  if bufnr() != s:bufnr
    return {}
  endif
  var lnum = line('.')
  var idx = lnum - 2
  if idx < 1 || idx > len(s:line_index)
    return {}
  endif
  return s:line_index[idx - 1]
enddef

# 跳转到包含某 path 的行
export def JumpToPath(path: string)
  for i in range(0, len(s:line_index) - 1)
    if s:line_index[i].path ==# path
      call cursor(i + 3, 1)
      return
    endif
  endfor
enddef

# 文件操作
export def CreateEntry()
  var n = treexplorer#CurrentNode()
  if empty(n)
    return
  endif
  var base = n.is_dir ? n.path : fnamemodify(n.path, ':h')
  var name = input('[SimpleTree] New name (file or dir; trailing / for dir): ', '', 'file')
  redraw
  if name ==# ''
    return
  endif
  var newp = s:Join(base, name)
  if newp =~ '/$'
    newp = substitute(newp, '/$', '', '')
    if isdirectory(newp)
      echo '[SimpleTree] Directory exists.'
      return
    endif
    try
      call mkdir(newp, 'p')
    catch
      echohl ErrorMsg | echom '[SimpleTree] mkdir failed.' | echohl None
    endtry
  else
    if filereadable(newp)
      echo '[SimpleTree] File exists.'
      return
    endif
    try
      call writefile([], newp)
    catch
      echohl ErrorMsg | echom '[SimpleTree] create file failed.' | echohl None
    endtry
  endif
  call Refresh()
enddef

export def DeleteEntry()
  var n = treexplorer#CurrentNode()
  if empty(n) || n.path ==# s:root
    echo '[SimpleTree] Nothing to delete or refusing to delete root.'
    return
  endif
  var ans = input('[SimpleTree] Delete ' .. n.path .. ' ? (y/N) ')
  redraw
  if ans !~? '^y'
    return
  endif
  try
    if n.is_dir
      call delete(n.path, 'rf')
    else
      call delete(n.path)
    endif
  catch
    echohl ErrorMsg | echom '[SimpleTree] delete failed.' | echohl None
  endtry
  " 清理状态与缓存
  if has_key(s:state, n.path) | call remove(s:state, n.path) | endif
  var parent = fnamemodify(n.path, ':h')
  if has_key(s:cache, parent) | call remove(s:cache, parent) | endif
  call Refresh()
enddef

export def RenameEntry()
  var n = treexplorer#CurrentNode()
  if empty(n) || n.path ==# s:root
    return
  endif
  var newn = input('[SimpleTree] Rename to: ', fnamemodify(n.path, ':t'))
  redraw
  if newn ==# '' || newn ==# fnamemodify(n.path, ':t')
    return
  endif
  var dst = s:Join(fnamemodify(n.path, ':h'), newn)
  if filereadable(dst) || isdirectory(dst)
    echohl WarningMsg | echom '[SimpleTree] Target exists.' | echohl None
    return
  endif
  try
    call rename(n.path, dst)
  catch
    echohl ErrorMsg | echom '[SimpleTree] rename failed.' | echohl None
    return
  endtry
  " 搬运状态
  if has_key(s:state, n.path)
    s:state[dst] = s:state[n.path]
    call remove(s:state, n.path)
  endif
  " 刷新父目录
  var parent = fnamemodify(dst, ':h')
  if has_key(s:cache, parent) | call remove(s:cache, parent) | endif
  call Refresh()
enddef
