vim9script
import autoload 'treexplorer_backend.vim' as Backend

# 配置
g:simpletree_width = get(g:, 'simpletree_width', 30)
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
g:simpletree_page = get(g:, 'simpletree_page', 200)
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 1)

# 脚本状态
var s_bufnr: number = -1
var s_winid: number = 0
var s_root: string = ''
var s_hide_dotfiles: bool = !!g:simpletree_hide_dotfiles

var s_state: dict<any> = {}               # path -> {expanded: bool}
var s_cache: dict<list<dict<any>>> = {}   # path -> entries[]
var s_loading: dict<bool> = {}            # path -> true
var s_pending: dict<number> = {}          # path -> request id
var s_line_index: list<dict<any>> = []    # 渲染行对应的节点

# ========== 工具函数 ==========
def AbsPath(p: string): string
  if p ==# ''
    return simplify(fnamemodify(getcwd(), ':p'))
  endif
  var ap = fnamemodify(p, ':p')
  if ap ==# ''
    ap = fnamemodify(getcwd() .. '/' .. p, ':p')
  endif
  return simplify(ap)
enddef

def IsDir(p: string): bool
  return isdirectory(p)
enddef

def Join(base: string, name: string): string
  return simplify(fnamemodify(base .. '/' .. name, ':p'))
enddef

def GetNodeState(path: string): dict<any>
  if !has_key(s_state, path)
    s_state[path] = {expanded: false}
  endif
  return s_state[path]
enddef

def BufValid(): bool
  return s_bufnr > 0 && bufexists(s_bufnr)
enddef

def WinValid(): bool
  return s_winid != 0 && win_gotoid(s_winid)
enddef

def OtherWindowId(): number
  var wins = getwininfo()
  for w in wins
    if w.winid != s_winid
      return w.winid
    endif
  endfor
  return 0
enddef

# ========== 后端交互 ==========
def CancelPending(path: string)
  if has_key(s_pending, path)
    try
      Backend.Cancel(s_pending[path])
    catch
    endtry
    call remove(s_pending, path)
  endif
enddef

def ScanDirAsync(path: string)
  # 已有缓存或正在加载则跳过
  if has_key(s_cache, path) || get(s_loading, path, v:false)
    return
  endif

  # 如果之前有未完成请求，先取消
  CancelPending(path)

  s_loading[path] = true
  var acc: list<dict<any>> = []
  var p = path

  var req_id = Backend.List(
    p,
    !s_hide_dotfiles,
    g:simpletree_page,
    (entries) => {
      # 分块回调
      acc += entries
      s_cache[p] = acc
      Render()
    },
    () => {
      # 完成回调
      s_loading[p] = false
      s_cache[p] = acc
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
      endif
      Render()
    },
    (_msg) => {
      # 错误回调
      s_loading[p] = false
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
      endif
      # 可选：回显错误
      if get(g:, 'simpletree_debug', 0)
        echom '[SimpleTree] list error for ' .. p
      endif
      Render()
    }
  )

  if req_id > 0
    s_pending[path] = req_id
  else
    s_loading[path] = false
  endif
enddef

# ========== 渲染 ==========
def EnsureWindowAndBuffer()
  if WinValid()
    # 确保宽度
    try
      call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)
    catch
    endtry
    return
  endif

  # 打开左侧垂直窗口
  execute 'topleft vertical ' .. g:simpletree_width .. 'vsplit'
  s_winid = win_getid()
  s_bufnr = bufnr('%')

  # 配置缓冲区
  execute 'file SimpleTree'
  setlocal buftype=nofile
  setlocal bufhidden=wipe
  setlocal nobuflisted
  setlocal noswapfile
  setlocal nowrap
  setlocal nonumber
  setlocal norelativenumber
  setlocal foldcolumn=0
  setlocal signcolumn=no
  setlocal cursorline
  setlocal winfixwidth
  setlocal winfixbuf
  setlocal filetype=simpletree

  # 键位映射（脚本内函数，用 <SID> 调用）
  nnoremap <silent> <buffer> <CR> :call <SID>OnEnter()<CR>
  nnoremap <silent> <buffer> l :call <SID>OnExpand()<CR>
  nnoremap <silent> <buffer> h :call <SID>OnCollapse()<CR>
  nnoremap <silent> <buffer> R :call <SID>OnRefresh()<CR>
  nnoremap <silent> <buffer> H :call <SID>OnToggleHidden()<CR>
  nnoremap <silent> <buffer> q :call <SID>OnClose()<CR>

  # 离开/清理时将 winid 归零（避免悬挂）
  augroup SimpleTreeBuf
    autocmd!
    autocmd BufWipeout <buffer> call <SID>OnBufWipe()
  augroup END
enddef

def OnBufWipe()
  s_winid = 0
  s_bufnr = -1
enddef

def BuildLines(path: string, depth: number, lines: list<string>, idx: list<dict<any>>)
  # 当目录被标记为展开时，展示其内容
  var want = GetNodeState(path).expanded

  if !want
    return
  endif

  if !has_key(s_cache, path)
    # 未有缓存，触发加载并放一个提示
    if !get(s_loading, path, v:false)
      ScanDirAsync(path)
    endif
    lines->add(repeat('  ', depth) .. '⏳ Loading...')
    idx->add({path: '', is_dir: false, name: '', depth: depth, loading: true})
    return
  endif

  var entries = s_cache[path]
  for e in entries
    var icon = e.is_dir ? (GetNodeState(e.path).expanded ? '▾ ' : '▸ ') : '  '
    var suffix = e.is_dir ? '/' : ''
    var text = repeat('  ', depth) .. icon .. e.name .. suffix
    lines->add(text)
    idx->add({path: e.path, is_dir: e.is_dir, name: e.name, depth: depth})

    if e.is_dir && GetNodeState(e.path).expanded
      BuildLines(e.path, depth + 1, lines, idx)
    endif
  endfor
enddef

def Render()
  if s_root ==# ''
    return
  endif
  EnsureWindowAndBuffer()

  var lines: list<string> = []
  var idx: list<dict<any>> = []

  # 顶层不显示 root 自身，只显示 root 的 children
  # 确保 root 是展开状态
  GetNodeState(s_root).expanded = true
  BuildLines(s_root, 0, lines, idx)

  if len(lines) == 0 && get(s_loading, s_root, v:false)
    lines = ['⏳ Loading...']
    idx = [{path: '', is_dir: false, name: '', depth: 0, loading: true}]
  endif

  if !BufValid()
    return
  endif

  # 写入缓冲区
  var save_winid = win_getid()
  if WinValid()
    call win_gotoid(s_winid)
  endif
  setlocal modifiable
  call setline(1, lines)
  if line('$') > len(lines)
    execute (len(lines) + 1) .. ',' .. '$delete _'
  endif
  setlocal nomodifiable
  # 保持光标不过界
  var lnum = line('.')
  if lnum > max([1, len(lines)])
    execute 'normal! G'
  endif
  if save_winid != s_winid && win_gotoid(save_winid)
    # 返回原窗口
  endif

  s_line_index = idx
enddef

# ========== 用户交互 ==========
def CursorNode(): dict<any>
  var lnum = line('.')
  if lnum <= 0 || lnum > len(s_line_index)
    return {}
  endif
  return s_line_index[lnum - 1]
enddef

def ToggleDir(path: string)
  var st = GetNodeState(path)
  st.expanded = !st.expanded
  if st.expanded && !has_key(s_cache, path) && !get(s_loading, path, v:false)
    ScanDirAsync(path)
  endif
  Render()
enddef

def OpenFile(p: string)
  if p ==# ''
    return
  endif
  var keep = !!g:simpletree_keep_focus
  var back_to_tree = v:false

  # 尽量在其他窗口中打开
  var other = OtherWindowId()
  if other != 0
    call win_gotoid(other)
  else
    # 只有树一个窗口时，开个新窗
    execute 'vsplit'
  endif
  execute 'edit ' .. fnameescape(p)

  if keep
    call win_gotoid(s_winid)
    back_to_tree = v:true
  endif
enddef

# ------- 映射触发的脚本内函数 -------
def OnEnter()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  if node.is_dir
    ToggleDir(node.path)
  else
    OpenFile(node.path)
  endif
enddef

def OnExpand()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  if node.is_dir && !GetNodeState(node.path).expanded
    ToggleDir(node.path)
  endif
enddef

def OnCollapse()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  if node.is_dir && GetNodeState(node.path).expanded
    ToggleDir(node.path)
  endif
enddef

def OnRefresh()
  Refresh()
enddef

def OnToggleHidden()
  s_hide_dotfiles = !s_hide_dotfiles
  Refresh()
enddef

def OnClose()
  Close()
enddef

# ========== 导出 API，供 :SimpleTree 命令调用 ==========
export def Toggle(root: string = '')
  # 若已打开则关闭
  if WinValid()
    Close()
    return
  endif

  if root ==# ''
    var cur = expand('%:p')
    if cur ==# '' || !filereadable(cur)
      root = getcwd()
    else
      root = fnamemodify(cur, ':p:h')
    endif
  endif

  s_root = AbsPath(root)
  if !IsDir(s_root)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. s_root
    echohl None
    return
  endif

  EnsureWindowAndBuffer()
  # 确保后端运行
  if !Backend.EnsureBackend()
    echohl ErrorMsg
    echom '[SimpleTree] backend not available'
    echohl None
    return
  endif

  # 展开根并触发加载
  GetNodeState(s_root).expanded = true
  ScanDirAsync(s_root)
  Render()
enddef

export def Refresh()
  # 取消所有挂起请求
  for [p, id] in items(s_pending)
    try
      Backend.Cancel(id)
    catch
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_cache = {}
  # 保持展开状态，但重新扫描
  if s_root !=# ''
    ScanDirAsync(s_root)
  endif
  Render()
enddef

export def Close()
  if WinValid()
    try
      call win_execute(s_winid, 'close')
    catch
    endtry
  endif
  s_winid = 0
  s_bufnr = -1
enddef
