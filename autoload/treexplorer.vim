vim9script

# =============================================================
# 配置
# =============================================================
g:simpletree_width = get(g:, 'simpletree_width', 30)
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
g:simpletree_page = get(g:, 'simpletree_page', 200)
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 1)
g:simpletree_debug = get(g:, 'simpletree_debug', 0)
g:simpletree_daemon_path = get(g:, 'simpletree_daemon_path', '')

# =============================================================
# 前端状态
# =============================================================
var s_bufnr: number = -1
var s_winid: number = 0
var s_root: string = ''
var s_hide_dotfiles: bool = !!g:simpletree_hide_dotfiles

var s_state: dict<any> = {}               # path -> {expanded: bool}
var s_cache: dict<list<dict<any>>> = {}   # path -> entries[]
var s_loading: dict<bool> = {}            # path -> true
var s_pending: dict<number> = {}          # path -> request id
var s_line_index: list<dict<any>> = []    # 渲染行对应的节点

# =============================================================
# 后端状态（合并）
# =============================================================
var s_bjob: any = v:null     # 后端 job 句柄（any，避免类型冲突）
var s_brunning: bool = false
var s_bbuf: string = ''      # 处理分包的缓冲
var s_bnext_id = 0
var s_bcbs: dict<any> = {}   # id -> {OnChunk, OnDone, OnError}

# =============================================================
# 工具函数
# =============================================================
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

def BufValid(): bool
  return s_bufnr > 0 && bufexists(s_bufnr)
enddef

def WinValid(): bool
  return s_winid != 0 && win_id2win(s_winid) > 0
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

def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpletree_debug', 0) == 0
    return
  endif
  try
    echohl hl
    echom '[SimpleTree] ' .. msg
  catch
  finally
    echohl None
  endtry
enddef

def GetNodeState(path: string): dict<any>
  if !has_key(s_state, path)
    s_state[path] = {expanded: false}
  endif
  return s_state[path]
enddef

# =============================================================
# 后端（合并）
# =============================================================
def BNextId(): number
  s_bnext_id += 1
  return s_bnext_id
enddef

def BFindBackend(): string
  var override = get(g:, 'simpletree_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    return override
  endif
  for dir in split(&runtimepath, ',')
    var p = dir .. '/lib/simpletree-daemon'
    if executable(p)
      return p
    endif
  endfor
  return ''
enddef

def BIsRunning(): bool
  return s_brunning
enddef

def BEnsureBackend(cmd: string = ''): bool
  if BIsRunning()
    return true
  endif
  var cmdExe = cmd
  if cmdExe ==# ''
    cmdExe = BFindBackend()
  endif
  if cmdExe ==# '' || !executable(cmdExe)
    echohl ErrorMsg
    echom '[SimpleTree] backend not found. Set g:simpletree_daemon_path or put simpletree-daemon into runtimepath/lib/.'
    echohl None
    return false
  endif

  s_bbuf = ''
  try
    s_bjob = job_start([cmdExe], {
      in_io: 'pipe',
      out_mode: 'raw',
      out_cb: (ch, msg) => {
        s_bbuf ..= msg
        var lines = split(s_bbuf, "\n", 1)
        var last_idx = len(lines) - 1
        s_bbuf = last_idx >= 0 ? lines[last_idx] : ''
        for i in range(0, len(lines) - 2)
          var line = lines[i]
          if line ==# ''
            continue
          endif
          var ev: any
          try
            ev = json_decode(line)
          catch
            continue
          endtry
          if type(ev) != v:t_dict || !has_key(ev, 'type')
            continue
          endif
          if ev.type ==# 'list_chunk'
            var id = ev.id
            if has_key(s_bcbs, id)
              if has_key(ev, 'entries')
                try
                  s_bcbs[id].OnChunk(ev.entries)
                catch
                endtry
              endif
              if get(ev, 'done', v:false)
                try
                  s_bcbs[id].OnDone()
                catch
                endtry
                call remove(s_bcbs, id)
              endif
            endif
          elseif ev.type ==# 'error'
            var id = get(ev, 'id', 0)
            if id != 0 && has_key(s_bcbs, id)
              try
                s_bcbs[id].OnError(get(ev, 'message', ''))
              catch
              endtry
              call remove(s_bcbs, id)
            else
              Log('backend error: ' .. get(ev, 'message', ''))
            endif
          endif
        endfor
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        Log('[stderr] ' .. line)
      },
      exit_cb: (ch, code) => {
        Log('backend exited with code ' .. code)
        s_brunning = false
        s_bjob = v:null
        s_bbuf = ''
        s_bcbs = {}
      },
      stoponexit: 'term',
    })
  catch
    s_bjob = v:null
    s_brunning = false
    echohl ErrorMsg
    echom '[SimpleTree] job_start failed: ' .. v:exception
    echohl None
    return false
  endtry

  s_brunning = (s_bjob != v:null)
  return s_brunning
enddef

def BStop(): void
  if s_bjob != v:null
    try
      call('job_stop', [s_bjob])
    catch
    endtry
  endif
  s_brunning = false
  s_bjob = v:null
  s_bbuf = ''
  s_bcbs = {}
enddef

def BSend(req: dict<any>): void
  if !BIsRunning()
    return
  endif
  try
    call('chansend', [s_bjob, json_encode(req) .. "\n"])
  catch
  endtry
enddef

def BList(path: string, show_hidden: bool, max: number, OnChunk: func, OnDone: func, OnError: func): number
  if !BEnsureBackend()
    try
      OnError('backend not available')
    catch
    endtry
    return 0
  endif
  var id = BNextId()
  s_bcbs[id] = {OnChunk: OnChunk, OnDone: OnDone, OnError: OnError}
  BSend({type: 'list', id: id, path: path, show_hidden: show_hidden, max: max})
  return id
enddef

def BCancel(id: number): void
  if id <= 0 || !BIsRunning()
    return
  endif
  BSend({type: 'cancel', id: id})
  if has_key(s_bcbs, id)
    call remove(s_bcbs, id)
  endif
enddef

# =============================================================
# 前端 <-> 后端
# =============================================================
def CancelPending(path: string)
  if has_key(s_pending, path)
    try
      BCancel(s_pending[path])
    catch
    endtry
    call remove(s_pending, path)
  endif
enddef

def ScanDirAsync(path: string)
  if has_key(s_cache, path) || get(s_loading, path, v:false)
    return
  endif

  CancelPending(path)

  s_loading[path] = true
  var acc: list<dict<any>> = []
  var p = path
  var req_id: number = 0   # 先声明，供 lambda 捕获

  req_id = BList(
    p,
    !s_hide_dotfiles,
    g:simpletree_page,
    (entries) => {
      acc += entries
      s_cache[p] = acc
      Render()
    },
    () => {
      s_loading[p] = false
      s_cache[p] = acc
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
      endif
      Render()
    },
    (_msg) => {
      s_loading[p] = false
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
      endif
      Log('list error for ' .. p)
      Render()
    }
  )

  if req_id > 0
    s_pending[path] = req_id
  else
    s_loading[path] = false
  endif
enddef

# =============================================================
# 渲染
# =============================================================
def EnsureWindowAndBuffer()
  if WinValid()
    try
      call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)
    catch
    endtry
    return
  endif

  # 关键修复：先分屏，再单独 resize，避免 30vsplit 触发 E1050
  execute 'topleft vertical vsplit'
  s_winid = win_getid()
  s_bufnr = bufnr('%')

  call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)

  execute 'file SimpleTree'

  call win_execute(s_winid, 'setlocal buftype=nofile')
  call win_execute(s_winid, 'setlocal bufhidden=wipe')
  call win_execute(s_winid, 'setlocal nobuflisted')
  call win_execute(s_winid, 'setlocal noswapfile')
  call win_execute(s_winid, 'setlocal nowrap')
  call win_execute(s_winid, 'setlocal nonumber')
  call win_execute(s_winid, 'setlocal norelativenumber')
  call win_execute(s_winid, 'setlocal foldcolumn=0')
  call win_execute(s_winid, 'setlocal signcolumn=no')
  call win_execute(s_winid, 'setlocal cursorline')
  call win_execute(s_winid, 'setlocal winfixwidth')
  call win_execute(s_winid, 'setlocal winfixbuf')
  call win_execute(s_winid, 'setlocal filetype=simpletree')

  call win_execute(s_winid, 'nnoremap <silent> <buffer> <CR> :call treexplorer#OnEnter()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> l :call treexplorer#OnExpand()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> h :call treexplorer#OnCollapse()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> R :call treexplorer#OnRefresh()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> H :call treexplorer#OnToggleHidden()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> q :call treexplorer#OnClose()<CR>')

  call win_execute(s_winid, 'augroup SimpleTreeBuf')
  call win_execute(s_winid, 'autocmd!')
  call win_execute(s_winid, 'autocmd BufWipeout <buffer> ++once call treexplorer#OnBufWipe()')
  call win_execute(s_winid, 'augroup END')
enddef

def BuildLines(path: string, depth: number, lines: list<string>, idx: list<dict<any>>)
  var want = GetNodeState(path).expanded
  if !want
    return
  endif

  if !has_key(s_cache, path)
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

  var stroot = GetNodeState(s_root)
  stroot.expanded = true

  BuildLines(s_root, 0, lines, idx)

  if len(lines) == 0 && get(s_loading, s_root, v:false)
    lines = ['⏳ Loading...']
    idx = [{path: '', is_dir: false, name: '', depth: 0, loading: true}]
  endif

  if !BufValid()
    return
  endif

  try
    call setbufvar(s_bufnr, '&modifiable', 1)
  catch
  endtry

  var out = len(lines) == 0 ? [''] : lines
  call setbufline(s_bufnr, 1, out)

  var bi = getbufinfo(s_bufnr)
  if len(bi) > 0
    var lc = get(bi[0], 'linecount', 0)
    if lc > len(out)
      try
        call deletebufline(s_bufnr, len(out) + 1, lc)
      catch
      endtry
    endif
  endif

  try
    call setbufvar(s_bufnr, '&modifiable', 0)
  catch
  endtry

  var maxline = max([1, len(out)])
  try
    call win_execute(s_winid, 'if line(".") > ' .. maxline .. ' | normal! G | endif')
  catch
  endtry

  s_line_index = idx
enddef

# =============================================================
# 用户交互（导出）
# =============================================================
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

  var other = OtherWindowId()
  if other != 0
    call win_gotoid(other)
  else
    execute 'vsplit'
  endif
  execute 'edit ' .. fnameescape(p)

  if keep
    call win_gotoid(s_winid)
  endif
enddef

export def OnEnter()
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

export def OnExpand()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  if node.is_dir && !GetNodeState(node.path).expanded
    ToggleDir(node.path)
  endif
enddef

export def OnCollapse()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  if node.is_dir && GetNodeState(node.path).expanded
    ToggleDir(node.path)
  endif
enddef

export def OnRefresh()
  Refresh()
enddef

export def OnToggleHidden()
  s_hide_dotfiles = !s_hide_dotfiles
  Refresh()
enddef

export def OnClose()
  Close()
enddef

export def OnBufWipe()
  s_winid = 0
  s_bufnr = -1
enddef

# =============================================================
# 导出 API（供命令调用）
# =============================================================
export def Toggle(root: string = '')
  if WinValid()
    Close()
    return
  endif

  var rootArg = root
  if rootArg ==# ''
    var cur = expand('%:p')
    if cur ==# '' || !filereadable(cur)
      rootArg = getcwd()
    else
      rootArg = fnamemodify(cur, ':p:h')
    endif
  endif

  s_root = AbsPath(rootArg)
  if !IsDir(s_root)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. s_root
    echohl None
    return
  endif

  EnsureWindowAndBuffer()
  if !BEnsureBackend()
    echohl ErrorMsg
    echom '[SimpleTree] backend not available'
    echohl None
    return
  endif

  var st = GetNodeState(s_root)
  st.expanded = true

  ScanDirAsync(s_root)
  Render()
enddef

export def Refresh()
  for [p, id] in items(s_pending)
    try
      BCancel(id)
    catch
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_cache = {}
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

export def Stop()
  BStop()
enddef