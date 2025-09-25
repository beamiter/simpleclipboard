vim9script

# =============================================================
# 配置
# =============================================================
g:simpletree_width = get(g:, 'simpletree_width', 30)
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
g:simpletree_page = get(g:, 'simpletree_page', 200)
# 打开文件后保持焦点在文件缓冲区
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 0)
g:simpletree_debug = get(g:, 'simpletree_debug', 0)
g:simpletree_daemon_path = get(g:, 'simpletree_daemon_path', '')
g:simpletree_root_locked = get(g:, 'simpletree_root_locked', 1)

# =============================================================
# 前端状态
# =============================================================
var s_bufnr: number = -1
var s_winid: number = 0
var s_root: string = ''
var s_hide_dotfiles: bool = !!g:simpletree_hide_dotfiles
var s_root_locked: bool = !!g:simpletree_root_locked

var s_state: dict<any> = {}               # path -> {expanded: bool}
var s_cache: dict<list<dict<any>>> = {}   # path -> entries[]
var s_loading: dict<bool> = {}            # path -> true
var s_pending: dict<number> = {}          # path -> request id
var s_line_index: list<dict<any>> = []    # 渲染行对应的节点

# =============================================================
# 后端状态（合并）
# =============================================================
var s_bjob: any = v:null
var s_brunning: bool = false
var s_bbuf: string = ''
var s_bnext_id = 0
var s_bcbs: dict<any> = {}   # id -> {OnChunk, OnDone, OnError}

# =============================================================
# 工具函数
# =============================================================
def AbsPath(p: string): string
  Log('AbsPath enter: p="' .. p .. '"', 'MoreMsg')
  if p ==# ''
    var cwdp = simplify(fnamemodify(getcwd(), ':p'))
    Log('AbsPath resolved empty p to cwd: ' .. cwdp)
    return cwdp
  endif
  var ap = fnamemodify(p, ':p')
  if ap ==# ''
    ap = fnamemodify(getcwd() .. '/' .. p, ':p')
    Log('AbsPath fnamemodify empty -> try cwd join: ' .. ap)
  endif
  ap = simplify(ap)
  Log('AbsPath result: ' .. ap, 'MoreMsg')
  return ap
enddef

def ParentDir(p: string): string
  var up = fnamemodify(p, ':h')
  return AbsPath(up)
enddef

def IsDir(p: string): bool
  var res = isdirectory(p)
  Log('IsDir("' .. p .. '") => ' .. (res ? 'true' : 'false'))
  return res
enddef

def BufValid(): bool
  var ok = s_bufnr > 0 && bufexists(s_bufnr)
  Log('BufValid? bufnr=' .. s_bufnr .. ' => ' .. (ok ? 'true' : 'false'))
  return ok
enddef

def WinValid(): bool
  var ok = (s_winid != 0 && win_id2win(s_winid) > 0)
  Log('WinValid? winid=' .. s_winid .. ' => ' .. (ok ? 'true' : 'false'))
  return ok
enddef

def OtherWindowId(): number
  Log('OtherWindowId enter')
  var wins = getwininfo()
  for w in wins
    if w.winid != s_winid
      Log('OtherWindowId found: ' .. w.winid)
      return w.winid
    endif
  endfor
  Log('OtherWindowId: none')
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
    Log('GetNodeState init: path="' .. path .. '" expanded=false')
  else
    Log('GetNodeState hit: path="' .. path .. '" expanded=' .. (s_state[path].expanded ? 'true' : 'false'))
  endif
  return s_state[path]
enddef

# =============================================================
# 后端（合并）
# =============================================================
def BNextId(): number
  s_bnext_id += 1
  Log('BNextId => ' .. s_bnext_id)
  return s_bnext_id
enddef

def BFindBackend(): string
  Log('BFindBackend enter')
  var override = get(g:, 'simpletree_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    Log('BFindBackend override executable: ' .. override, 'MoreMsg')
    return override
  endif
  Log('BFindBackend searching &runtimepath', 'MoreMsg')
  for dir in split(&runtimepath, ',')
    var p = dir .. '/lib/simpletree-daemon'
    if executable(p)
      Log('BFindBackend found: ' .. p, 'MoreMsg')
      return p
    endif
  endfor
  Log('BFindBackend not found', 'WarningMsg')
  return ''
enddef

def BIsRunning(): bool
  Log('BIsRunning => ' .. (s_brunning ? 'true' : 'false'))
  return s_brunning
enddef

def BEnsureBackend(cmd: string = ''): bool
  Log('BEnsureBackend enter cmd="' .. cmd .. '"')
  if BIsRunning()
    Log('BEnsureBackend already running', 'MoreMsg')
    return true
  endif
  var cmdExe = cmd ==# '' ? BFindBackend() : cmd
  Log('BEnsureBackend resolved cmdExe="' .. cmdExe .. '"')
  if cmdExe ==# '' || !executable(cmdExe)
    echohl ErrorMsg
    echom '[SimpleTree] backend not found. Set g:simpletree_daemon_path or put simpletree-daemon into runtimepath/lib/.'
    echohl None
    Log('BEnsureBackend failed: backend not executable', 'ErrorMsg')
    return false
  endif

  s_bbuf = ''
  Log('BEnsureBackend starting job: ' .. cmdExe, 'Title')
  try
    s_bjob = job_start([cmdExe], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, line) => {
        if line ==# ''
          Log('out_cb: skip empty line')
          return
        endif
        var ev: any
        try
          ev = json_decode(line)
          Log('out_cb: json decoded ok: ' .. line)
        catch
          Log('out_cb: json_decode failed, line="' .. line .. '"', 'WarningMsg')
          return
        endtry
        if type(ev) != v:t_dict || !has_key(ev, 'type')
          Log('out_cb: unexpected event shape', 'WarningMsg')
          return
        endif
        if ev.type ==# 'list_chunk'
          var id = ev.id
          Log('out_cb: list_chunk id=' .. id .. ' entries=' .. len(get(ev, 'entries', [])) .. ' done=' .. (get(ev, 'done', v:false) ? 'true' : 'false'), 'MoreMsg')
          if has_key(s_bcbs, id)
            if has_key(ev, 'entries')
              try
                s_bcbs[id].OnChunk(ev.entries)
                Log('out_cb: OnChunk dispatched id=' .. id)
              catch
                Log('out_cb: OnChunk handler exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
              endtry
            endif
            if get(ev, 'done', v:false)
              try
                s_bcbs[id].OnDone()
                Log('out_cb: OnDone dispatched id=' .. id)
              catch
                Log('out_cb: OnDone handler exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
              endtry
              call remove(s_bcbs, id)
              Log('out_cb: callbacks removed id=' .. id)
            endif
          else
            Log('out_cb: id not found in s_bcbs: ' .. id, 'WarningMsg')
          endif
        elseif ev.type ==# 'error'
          var id = get(ev, 'id', 0)
          var msg2 = get(ev, 'message', '')
          Log('out_cb: error event id=' .. id .. ' message="' .. msg2 .. '"', 'ErrorMsg')
          if id != 0 && has_key(s_bcbs, id)
            try
              s_bcbs[id].OnError(msg2)
              Log('out_cb: OnError dispatched id=' .. id)
            catch
              Log('out_cb: OnError handler exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
            endtry
            call remove(s_bcbs, id)
            Log('out_cb: callbacks removed after error id=' .. id)
          else
            Log('backend error (no id): ' .. msg2, 'ErrorMsg')
          endif
        else
          Log('out_cb: unknown ev.type="' .. ev.type .. '"', 'WarningMsg')
        endif
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        Log('[stderr] ' .. line, 'WarningMsg')
      },
      exit_cb: (ch, code) => {
        Log('backend exited with code ' .. code, code == 0 ? 'MoreMsg' : 'ErrorMsg')
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
    Log('BEnsureBackend job_start exception: ' .. v:exception, 'ErrorMsg')
    return false
  endtry

  s_brunning = (s_bjob != v:null)
  Log('BEnsureBackend success: running=' .. (s_brunning ? 'true' : 'false'))
  return s_brunning
enddef

def BStop(): void
  Log('BStop enter', 'Title')
  if s_bjob != v:null
    try
      call('job_stop', [s_bjob])
      Log('BStop job_stop ok')
    catch
      Log('BStop job_stop exception: ' .. v:exception, 'ErrorMsg')
    endtry
  endif
  s_brunning = false
  s_bjob = v:null
  s_bbuf = ''
  s_bcbs = {}
  Log('BStop done')
enddef

def BSend(req: dict<any>): void
  if !BIsRunning()
    Log('BSend skipped: backend not running', 'WarningMsg')
    return
  endif
  try
    var json = json_encode(req) .. "\n"
    Log('BSend: ' .. json)
    ch_sendraw(s_bjob, json)
  catch
    Log('BSend exception: ' .. v:exception, 'ErrorMsg')
  endtry
enddef

def BList(path: string, show_hidden: bool, max: number, OnChunk: func, OnDone: func, OnError: func): number
  Log('BList enter path="' .. path .. '" show_hidden=' .. (show_hidden ? 'true' : 'false') .. ' max=' .. max, 'Title')
  if !BEnsureBackend()
    try
      OnError('backend not available')
      Log('BList immediate OnError: backend not available', 'ErrorMsg')
    catch
      Log('BList OnError exception: ' .. v:exception, 'ErrorMsg')
    endtry
    return 0
  endif
  var id = BNextId()
  s_bcbs[id] = {OnChunk: OnChunk, OnDone: OnDone, OnError: OnError}
  Log('BList sending request id=' .. id)
  BSend({type: 'list', id: id, path: path, show_hidden: show_hidden, max: max})
  return id
enddef

def BCancel(id: number): void
  Log('BCancel enter id=' .. id)
  if id <= 0 || !BIsRunning()
    Log('BCancel skipped: invalid id or backend not running')
    return
  endif
  BSend({type: 'cancel', id: id})
  if has_key(s_bcbs, id)
    call remove(s_bcbs, id)
    Log('BCancel: callbacks removed id=' .. id)
  endif
enddef

# =============================================================
# 前端 <-> 后端
# =============================================================
def CancelPending(path: string)
  Log('CancelPending enter path="' .. path .. '"')
  if has_key(s_pending, path)
    try
      var pid = s_pending[path]
      Log('CancelPending: cancel id=' .. pid)
      BCancel(pid)
    catch
      Log('CancelPending exception: ' .. v:exception, 'ErrorMsg')
    endtry
    call remove(s_pending, path)
    Log('CancelPending: removed from s_pending path="' .. path .. '"')
  else
    Log('CancelPending: no pending for path')
  endif
enddef

def ScanDirAsync(path: string)
  Log('ScanDirAsync enter path="' .. path .. '" hide_dotfiles=' .. (s_hide_dotfiles ? 'true' : 'false'))
  if has_key(s_cache, path) || get(s_loading, path, v:false)
    Log('ScanDirAsync skip: cache_exists=' .. (has_key(s_cache, path) ? 'true' : 'false') .. ' loading=' .. (get(s_loading, path, v:false) ? 'true' : 'false'))
    return
  endif

  CancelPending(path)

  s_loading[path] = true
  Log('ScanDirAsync set loading=true path="' .. path .. '"')
  var acc: list<dict<any>> = []
  var p = path
  var req_id: number = 0

  req_id = BList(
    p,
    !s_hide_dotfiles,
    g:simpletree_page,
    (entries) => {
      Log('ScanDirAsync.OnChunk path="' .. p .. '" entries_len=' .. len(entries))
      acc += entries
      s_cache[p] = acc
      Log('ScanDirAsync.OnChunk cache_len=' .. len(s_cache[p]))
      Render()
    },
    () => {
      Log('ScanDirAsync.OnDone path="' .. p .. '" final_len=' .. len(acc), 'MoreMsg')
      s_loading[p] = false
      s_cache[p] = acc
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
        Log('ScanDirAsync.OnDone removed pending path="' .. p .. '"')
      endif
      Render()
    },
    (_msg) => {
      Log('ScanDirAsync.OnError path="' .. p .. '" msg="' .. _msg .. '"', 'ErrorMsg')
      s_loading[p] = false
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
        Log('ScanDirAsync.OnError removed pending path="' .. p .. '"')
      endif
      Log('list error for ' .. p, 'ErrorMsg')
      Render()
    }
  )

  Log('ScanDirAsync BList returned id=' .. req_id)
  if req_id > 0
    s_pending[path] = req_id
    Log('ScanDirAsync set pending id=' .. req_id .. ' path="' .. path .. '"')
  else
    s_loading[path] = false
    Log('ScanDirAsync backend failed => set loading=false path="' .. path .. '"', 'WarningMsg')
  endif
enddef

# =============================================================
# 渲染
# =============================================================
def EnsureWindowAndBuffer()
  Log('EnsureWindowAndBuffer enter', 'Title')
  if WinValid()
    try
      Log('EnsureWindowAndBuffer: resize to ' .. g:simpletree_width)
      call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)
    catch
      Log('EnsureWindowAndBuffer: resize exception ' .. v:exception, 'ErrorMsg')
    endtry
    return
  endif

  Log('EnsureWindowAndBuffer: create vsplit (tree on the left)')
  execute 'topleft vertical vsplit'
  s_winid = win_getid()

  # 创建独立缓冲，不影响右侧原缓冲
  call win_execute(s_winid, 'silent enew')
  s_bufnr = winbufnr(s_winid)

  call win_execute(s_winid, 'file SimpleTree')

  call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)
  Log('EnsureWindowAndBuffer: created winid=' .. s_winid .. ' bufnr=' .. s_bufnr)

  var opts = [
    'setlocal buftype=nofile',
    'setlocal bufhidden=wipe',
    'setlocal nobuflisted',
    'setlocal noswapfile',
    'setlocal nowrap',
    'setlocal nonumber',
    'setlocal norelativenumber',
    'setlocal foldcolumn=0',
    'setlocal signcolumn=no',
    'setlocal cursorline',
    'setlocal winfixwidth',
    'setlocal winfixbuf',
    'setlocal filetype=simpletree'
  ]
  for cmd in opts
    call win_execute(s_winid, cmd)
    Log('EnsureWindowAndBuffer: ' .. cmd)
  endfor

  # mappings（根路径操作 + h/l）
  call win_execute(s_winid, 'nnoremap <silent> <buffer> <CR> :call treexplorer#OnEnter()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> l :call treexplorer#OnExpand()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> h :call treexplorer#OnCollapse()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> R :call treexplorer#OnRefresh()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> H :call treexplorer#OnToggleHidden()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> q :call treexplorer#OnClose()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> s :call treexplorer#OnRootHere()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> U :call treexplorer#OnRootUp()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> C :call treexplorer#OnRootPrompt()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> . :call treexplorer#OnRootCwd()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> d :call treexplorer#OnRootCurrent()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> L :call treexplorer#OnToggleRootLock()<CR>')
  Log('EnsureWindowAndBuffer: mappings set')

  call win_execute(s_winid, 'augroup SimpleTreeBuf')
  call win_execute(s_winid, 'autocmd!')
  call win_execute(s_winid, 'autocmd BufWipeout <buffer> ++once call treexplorer#OnBufWipe()')
  call win_execute(s_winid, 'augroup END')
  Log('EnsureWindowAndBuffer: autocmds set')
enddef

def BuildLines(path: string, depth: number, lines: list<string>, idx: list<dict<any>>)
  Log('BuildLines enter path="' .. path .. '" depth=' .. depth)
  var want = GetNodeState(path).expanded
  if !want
    Log('BuildLines: not expanded, return path="' .. path .. '"')
    return
  endif

  var hasCache = has_key(s_cache, path)
  var isLoading = get(s_loading, path, v:false)
  Log('BuildLines: hasCache=' .. (hasCache ? 'true' : 'false') .. ' isLoading=' .. (isLoading ? 'true' : 'false'))

  if !hasCache
    if !isLoading
      Log('BuildLines: no cache and not loading => trigger ScanDirAsync(path)', 'WarningMsg')
      ScanDirAsync(path)
    endif
    lines->add(repeat('  ', depth) .. '⏳ Loading...')
    idx->add({path: '', is_dir: false, name: '', depth: depth, loading: true})
    Log('BuildLines: appended Loading placeholder path="' .. path .. '" depth=' .. depth)
    return
  endif

  var entries = s_cache[path]
  Log('BuildLines: entries_len=' .. len(entries) .. ' path="' .. path .. '"')
  for e in entries
    var icon = e.is_dir ? (GetNodeState(e.path).expanded ? '▾ ' : '▸ ') : '  '
    var suffix = e.is_dir ? '/' : ''
    var text = repeat('  ', depth) .. icon .. e.name .. suffix
    lines->add(text)
    idx->add({path: e.path, is_dir: e.is_dir, name: e.name, depth: depth})
    Log('BuildLines: add line "' .. text .. '"')

    if e.is_dir && GetNodeState(e.path).expanded
      Log('BuildLines: recurse into dir path="' .. e.path .. '" depth=' .. (depth + 1))
      BuildLines(e.path, depth + 1, lines, idx)
    endif
  endfor
enddef

def Render()
  Log('Render enter', 'Title')
  if s_root ==# ''
    Log('Render: s_root empty, return', 'WarningMsg')
    return
  endif
  EnsureWindowAndBuffer()

  var lines: list<string> = []
  var idx: list<dict<any>> = []

  # 根保持展开（不折叠根）
  var stroot = GetNodeState(s_root)
  stroot.expanded = true
  Log('Render: root expanded=true s_root="' .. s_root .. '"')

  BuildLines(s_root, 0, lines, idx)

  if len(lines) == 0 && get(s_loading, s_root, v:false)
    lines = ['⏳ Loading...']
    idx = [{path: '', is_dir: false, name: '', depth: 0, loading: true}]
    Log('Render: only root loading placeholder')
  endif

  if !BufValid()
    Log('Render: buffer invalid, return', 'ErrorMsg')
    return
  endif

  try
    call setbufvar(s_bufnr, '&modifiable', 1)
    Log('Render: set modifiable=1')
  catch
    Log('Render: set modifiable=1 exception ' .. v:exception, 'ErrorMsg')
  endtry

  var out = len(lines) == 0 ? [''] : lines
  Log('Render: setbufline count=' .. len(out))
  call setbufline(s_bufnr, 1, out)

  var bi = getbufinfo(s_bufnr)
  if len(bi) > 0
    var lc = get(bi[0], 'linecount', 0)
    if lc > len(out)
      try
        call deletebufline(s_bufnr, len(out) + 1, lc)
        Log('Render: deletebufline from ' .. (len(out) + 1) .. ' to ' .. lc)
      catch
        Log('Render: deletebufline exception ' .. v:exception, 'ErrorMsg')
      endtry
    endif
  endif

  try
    call setbufvar(s_bufnr, '&modifiable', 0)
    Log('Render: set modifiable=0')
  catch
    Log('Render: set modifiable=0 exception ' .. v:exception, 'ErrorMsg')
  endtry

  var maxline = max([1, len(out)])
  try
    call win_execute(s_winid, 'if line(".") > ' .. maxline .. ' | normal! G | endif')
    Log('Render: cursor clamp maxline=' .. maxline)
  catch
    Log('Render: cursor clamp exception ' .. v:exception, 'ErrorMsg')
  endtry

  s_line_index = idx
  Log('Render: index_len=' .. len(idx) .. ' loading_keys=' .. string(keys(s_loading)) .. ' cache_keys=' .. string(keys(s_cache)))
enddef

# =============================================================
# 根路径切换与锁定
# =============================================================
def SetRoot(new_root: string, lock: bool = false)
  Log('SetRoot enter new_root="' .. new_root .. '" lock=' .. (lock ? 'true' : 'false'), 'Title')
  var nr = AbsPath(new_root)
  if !IsDir(nr)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. nr
    echohl None
    Log('SetRoot: invalid root "' .. nr .. '"', 'ErrorMsg')
    return
  endif
  s_root = nr
  if lock
    s_root_locked = true
    Log('SetRoot: root locked')
  endif

  EnsureWindowAndBuffer()
  if !BEnsureBackend()
    echohl ErrorMsg
    echom '[SimpleTree] backend not available'
    echohl None
    Log('SetRoot: backend not available', 'ErrorMsg')
    return
  endif

  var st = GetNodeState(s_root)
  st.expanded = true
  Log('SetRoot: root expanded set true')

  # 清理旧状态
  for [p, id] in items(s_pending)
    try
      BCancel(id)
    catch
      Log('SetRoot: BCancel exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_cache = {}

  ScanDirAsync(s_root)
  Render()
enddef

export def OnToggleRootLock()
  s_root_locked = !s_root_locked
  echo '[SimpleTree] root lock: ' .. (s_root_locked ? 'ON' : 'OFF')
  Log('OnToggleRootLock => ' .. (s_root_locked ? 'ON' : 'OFF'), 'MoreMsg')
enddef

export def OnRootHere()
  Log('OnRootHere', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    Log('OnRootHere: empty or loading node, return', 'WarningMsg')
    return
  endif
  var p = node.is_dir ? node.path : fnamemodify(node.path, ':h')
  SetRoot(p)
enddef

export def OnRootUp()
  Log('OnRootUp', 'Title')
  if s_root ==# ''
    Log('OnRootUp: s_root empty', 'WarningMsg')
    return
  endif
  var up = ParentDir(s_root)
  if up ==# s_root
    Log('OnRootUp: already at top?', 'WarningMsg')
  endif
  SetRoot(up)
enddef

export def OnRootPrompt()
  Log('OnRootPrompt', 'Title')
  var start = s_root !=# '' ? s_root : getcwd()
  var inp = input('SimpleTree new root: ', start, 'dir')
  if inp ==# ''
    Log('OnRootPrompt: empty input', 'WarningMsg')
    return
  endif
  SetRoot(inp)
enddef

export def OnRootCwd()
  Log('OnRootCwd', 'Title')
  SetRoot(getcwd())
enddef

export def OnRootCurrent()
  Log('OnRootCurrent', 'Title')
  var cur = expand('%:p')
  var p = (cur ==# '' || !filereadable(cur)) ? getcwd() : fnamemodify(cur, ':p:h')
  SetRoot(p)
enddef

# =============================================================
# 用户交互（导出）
# =============================================================
def CursorNode(): dict<any>
  var lnum = line('.')
  if lnum <= 0 || lnum > len(s_line_index)
    Log('CursorNode: lnum=' .. lnum .. ' out of range', 'WarningMsg')
    return {}
  endif
  var node = s_line_index[lnum - 1]
  Log('CursorNode: lnum=' .. lnum .. ' node=' .. string(node))
  return node
enddef

# 根据路径定位到树中的行；找不到则退到顶部
def FocusPath(path: string): void
  Log('FocusPath enter path="' .. path .. '"')
  if !WinValid()
    Log('FocusPath: window invalid', 'WarningMsg')
    return
  endif
  if path ==# ''
    Log('FocusPath: empty path', 'WarningMsg')
    return
  endif
  var target: number = 0
  for i in range(len(s_line_index))
    if get(s_line_index[i], 'path', '') ==# path
      target = i + 1
      break
    endif
  endfor
  try
    if target > 0
      call win_execute(s_winid, 'normal! ' .. target .. 'G')
      Log('FocusPath: moved cursor to line ' .. target)
    else
      call win_execute(s_winid, 'normal! gg')
      Log('FocusPath: path not found, moved to top')
    endif
  catch
    Log('FocusPath: win_execute exception ' .. v:exception, 'ErrorMsg')
  endtry
enddef

# 将游标定位到某目录的第一个子项（若已展开或出现 Loading）
def FocusFirstChild(dir_path: string): void
  Log('FocusFirstChild enter dir_path="' .. dir_path .. '"')
  if !WinValid()
    Log('FocusFirstChild: window invalid', 'WarningMsg')
    return
  endif
  var idx_dir = -1
  var dir_depth = -1
  for i in range(len(s_line_index))
    if get(s_line_index[i], 'path', '') ==# dir_path
      idx_dir = i
      dir_depth = get(s_line_index[i], 'depth', -1)
      break
    endif
  endfor
  if idx_dir < 0
    Log('FocusFirstChild: dir not found in index', 'WarningMsg')
    return
  endif
  var next_idx = idx_dir + 1
  if next_idx < len(s_line_index)
    var next = s_line_index[next_idx]
    if get(next, 'depth', -1) == dir_depth + 1
      try
        call win_execute(s_winid, 'normal! ' .. (next_idx + 1) .. 'G')
        Log('FocusFirstChild: moved to first child line ' .. (next_idx + 1))
      catch
        Log('FocusFirstChild: win_execute exception ' .. v:exception, 'ErrorMsg')
      endtry
    else
      Log('FocusFirstChild: next line is not a child (depth mismatch)')
    endif
  else
    Log('FocusFirstChild: no next line')
  endif
enddef

# 折叠最近的已展开祖先：
# - 若遇到根 s_root，则不折叠根、且不移动光标（保持当前位置）
# - 有可折叠祖先则折叠并定位到该祖先
# - 若没有祖先可折叠，且父目录不是根，则定位到父目录；父目录为根则不移动
def CollapseNearestExpandedAncestor(path: string): void
  Log('CollapseNearestExpandedAncestor enter path="' .. path .. '"')
  var p = fnamemodify(path, ':h')
  while p !=# ''
    if p ==# s_root
      Log('CollapseNearestExpandedAncestor: parent is root, keep cursor unmoved')
      return
    endif
    if GetNodeState(p).expanded
      Log('CollapseNearestExpandedAncestor: collapse target "' .. p .. '"')
      ToggleDir(p)
      FocusPath(p)
      return
    endif
    var nextp = fnamemodify(p, ':h')
    if nextp ==# p
      Log('CollapseNearestExpandedAncestor: reached path top, break to avoid loop')
      break
    endif
    p = nextp
  endwhile
  # 没有可折叠的祖先
  var parent = fnamemodify(path, ':h')
  if parent !=# '' && parent !=# s_root
    FocusPath(parent)
    Log('CollapseNearestExpandedAncestor: focus parent "' .. parent .. '"')
  else
    Log('CollapseNearestExpandedAncestor: parent is root or empty, keep cursor unmoved')
  endif
enddef

def ToggleDir(path: string)
  Log('ToggleDir enter path="' .. path .. '"')
  var st = GetNodeState(path)
  st.expanded = !st.expanded
  Log('ToggleDir: expanded=' .. (st.expanded ? 'true' : 'false') .. ' path="' .. path .. '"')
  if st.expanded && !has_key(s_cache, path) && !get(s_loading, path, v:false)
    Log('ToggleDir: expanded without cache/loading, trigger ScanDirAsync', 'MoreMsg')
    ScanDirAsync(path)
  endif
  Render()
enddef

def OpenFile(p: string)
  Log('OpenFile enter p="' .. p .. '"')
  if p ==# ''
    Log('OpenFile: empty path, return', 'WarningMsg')
    return
  endif
  var keep = !!g:simpletree_keep_focus
  Log('OpenFile: keep_focus=' .. (keep ? 'true' : 'false'))

  var other = OtherWindowId()
  if other != 0
    Log('OpenFile: goto other winid=' .. other)
    call win_gotoid(other)
  else
    Log('OpenFile: create vsplit')
    execute 'vsplit'
  endif
  Log('OpenFile: edit ' .. fnameescape(p))
  execute 'edit ' .. fnameescape(p)

  if keep
    Log('OpenFile: go back to tree winid=' .. s_winid)
    call win_gotoid(s_winid)
  endif
enddef

export def OnEnter()
  Log('OnEnter', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    Log('OnEnter: empty or loading node, return', 'WarningMsg')
    return
  endif
  if node.is_dir
    Log('OnEnter: toggle dir path="' .. node.path .. '"')
    ToggleDir(node.path)
  else
    Log('OnEnter: open file path="' .. node.path .. '"')
    OpenFile(node.path)
  endif
enddef

# l：目录上展开并定位第一个子项；文件上打开文件
export def OnExpand()
  Log('OnExpand', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    Log('OnExpand: empty or loading node, return', 'WarningMsg')
    return
  endif
  if node.is_dir
    if !GetNodeState(node.path).expanded
      Log('OnExpand: expand dir path="' .. node.path .. '"')
      ToggleDir(node.path)
    else
      Log('OnExpand: dir already expanded path="' .. node.path .. '"')
    endif
    FocusFirstChild(node.path)
  else
    Log('OnExpand: node is file => open path="' .. node.path .. '"')
    OpenFile(node.path)
  endif
enddef

# h：目录已展开时折叠当前；目录已折叠或文件时折叠最近的已展开父目录；
#    父为根或没有祖先时保持光标不动
export def OnCollapse()
  Log('OnCollapse', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    Log('OnCollapse: empty or loading node, return', 'WarningMsg')
    return
  endif
  if node.is_dir
    if GetNodeState(node.path).expanded
      Log('OnCollapse: collapse current dir path="' .. node.path .. '"')
      ToggleDir(node.path)
    else
      Log('OnCollapse: dir is collapsed, collapse parent chain from "' .. node.path .. '"')
      CollapseNearestExpandedAncestor(node.path)
    endif
  else
    Log('OnCollapse: node is file => collapse parent chain')
    CollapseNearestExpandedAncestor(node.path)
  endif
enddef

export def OnRefresh()
  Log('OnRefresh', 'Title')
  Refresh()
enddef

export def OnToggleHidden()
  Log('OnToggleHidden before s_hide_dotfiles=' .. (s_hide_dotfiles ? 'true' : 'false'), 'Title')
  s_hide_dotfiles = !s_hide_dotfiles
  Log('OnToggleHidden after s_hide_dotfiles=' .. (s_hide_dotfiles ? 'true' : 'false'))
  Refresh()
enddef

export def OnClose()
  Log('OnClose', 'Title')
  Close()
enddef

export def OnBufWipe()
  Log('OnBufWipe', 'Title')
  s_winid = 0
  s_bufnr = -1
enddef

# =============================================================
# 导出 API（供命令调用）
# =============================================================
export def Toggle(root: string = '')
  Log('Toggle enter rootArg="' .. root .. '"', 'Title')
  if WinValid()
    Log('Toggle: window valid => Close()', 'MoreMsg')
    Close()
    return
  endif

  var rootArg = root
  if rootArg ==# ''
    if s_root_locked && s_root !=# '' && IsDir(s_root)
      rootArg = s_root
      Log('Toggle: use locked root "' .. rootArg .. '"')
    else
      var cur = expand('%:p')
      Log('Toggle: resolved current buffer path="' .. cur .. '"')
      if cur ==# '' || !filereadable(cur)
        rootArg = getcwd()
        Log('Toggle: no file => use getcwd="' .. rootArg .. '"')
      else
        rootArg = fnamemodify(cur, ':p:h')
        Log('Toggle: use current file dir="' .. rootArg .. '"')
      endif
    endif
  endif
  Log('Toggle rootArg: ' .. rootArg)

  s_root = AbsPath(rootArg)
  if !IsDir(s_root)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. s_root
    echohl None
    Log('Toggle: invalid root "' .. s_root .. '"', 'ErrorMsg')
    return
  endif
  Log('Toggle s_root: ' .. s_root)

  EnsureWindowAndBuffer()
  if !BEnsureBackend()
    echohl ErrorMsg
    echom '[SimpleTree] backend not available'
    echohl None
    Log('Toggle: backend not available', 'ErrorMsg')
    return
  endif

  var st = GetNodeState(s_root)
  st.expanded = true
  Log('Toggle: root expanded set true')

  Log('Toggle: ScanDirAsync start')
  ScanDirAsync(s_root)
  Log('Toggle: Render start')
  Render()
enddef

export def Refresh()
  Log('Refresh enter', 'Title')
  for [p, id] in items(s_pending)
    Log('Refresh: cancel pending path="' .. p .. '" id=' .. id)
    try
      BCancel(id)
    catch
      Log('Refresh: BCancel exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_cache = {}
  Log('Refresh: cleared pending/loading/cache')
  if s_root !=# ''
    Log('Refresh: rescan root="' .. s_root .. '"')
    ScanDirAsync(s_root)
  else
    Log('Refresh: s_root empty, skip rescan', 'WarningMsg')
  endif
  Render()
enddef

export def Close()
  Log('Close enter', 'Title')
  if WinValid()
    try
      call win_execute(s_winid, 'close')
      Log('Close: closed window id=' .. s_winid)
    catch
      Log('Close: close exception ' .. v:exception, 'ErrorMsg')
    endtry
  else
    Log('Close: window not valid')
  endif
  s_winid = 0
  s_bufnr = -1
  Log('Close: reset win/buf')
enddef

export def Stop()
  Log('Stop enter', 'Title')
  BStop()
enddef

export def DebugStatus()
  echo '[SimpleTree] status:'
  echo '  win_valid: ' .. (WinValid() ? 'yes' : 'no')
  echo '  buf_valid: ' .. (BufValid() ? 'yes' : 'no')
  echo '  root: ' .. s_root
  echo '  root_locked: ' .. (s_root_locked ? 'yes' : 'no')
  echo '  backend_running: ' .. (s_brunning ? 'yes' : 'no')
  echo '  pending: ' .. string(items(s_pending))
  echo '  loading: ' .. string(keys(s_loading))
  echo '  cache_keys: ' .. string(keys(s_cache))
  Log('DebugStatus logged', 'MoreMsg')
enddef
