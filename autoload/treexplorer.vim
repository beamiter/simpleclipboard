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

# 剪贴板（复制/剪切）
var s_clipboard: dict<any> = {mode: '', items: []}  # {mode: 'copy'|'cut', items: [paths...]}

# 帮助面板状态
var s_help_winid: number = 0
var s_help_bufnr: number = -1
var s_help_popupid: number = 0      # 新增：浮窗 ID

# Reveal 定位
var s_reveal_target: string = ''
var s_reveal_timer: number = 0

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
# 去掉尾部斜杠；保留 Unix 根 "/"；保留 Windows 盘根 "C:/" 的形式
def RStripSlash(p: string): string
  if p ==# ''
    return ''
  endif
  var q = substitute(p, '[\\/]\+$', '', '')
  # 如果全是斜杠被去没了，说明原本就是根
  if q ==# ''
    return '/'
  endif
  # Windows 盘根保持加斜杠
  if q =~? '^[A-Za-z]:$'
    return q .. '/'
  endif
  return q
enddef

# 规范化为绝对路径，并做统一的尾斜杠处理
def CanonDir(p: string): string
  var ap = AbsPath(p)
  return RStripSlash(ap)
enddef

def AbsPath(p: string): string
  # Log('AbsPath enter: p="' .. p .. '"', 'MoreMsg')
  if p ==# ''
    var cwdp = simplify(fnamemodify(getcwd(), ':p'))
    Log('AbsPath resolved empty p to cwd: ' .. cwdp)
    return cwdp
  endif
  var ap = fnamemodify(p, ':p')
  if ap ==# ''
    ap = fnamemodify(getcwd() .. '/' .. p, ':p')
    # Log('AbsPath fnamemodify empty -> try cwd join: ' .. ap)
  endif
  ap = simplify(ap)
  # Log('AbsPath result: ' .. ap, 'MoreMsg')
  return ap
enddef

def ParentDir(p: string): string
  var ap = AbsPath(p)
  var no_trail = RStripSlash(ap)
  var up = fnamemodify(no_trail, ':h')
  return CanonDir(up)
enddef

def IsDir(p: string): bool
  var res = isdirectory(p)
  # Log('IsDir("' .. p .. '") => ' .. (res ? 'true' : 'false'))
  return res
enddef

def PathJoin(a: string, b: string): string
  if a ==# ''
    return AbsPath(b)
  endif
  if b ==# ''
    return AbsPath(a)
  endif
  return simplify(a .. '/' .. b)
enddef

def PathExists(p: string): bool
  return filereadable(p) || isdirectory(p)
enddef

# 递归复制：文件或目录
def CopyPath(src: string, dst: string): bool
  # Log('CopyPath "' .. src .. '" -> "' .. dst .. '"')
  if isdirectory(src)
    if !isdirectory(dst)
      try
        call mkdir(dst, 'p')
      catch
        # Log('CopyPath: mkdir exception ' .. v:exception, 'ErrorMsg')
        return false
      endtry
      try
        if exists('*getfperm') && exists('*setfperm')
          var p = getfperm(src)
          if type(p) == v:t_string && p !=# ''
            call setfperm(dst, p)
          endif
        endif
      catch
        # Log('CopyPath: setfperm dir ex ' .. v:exception, 'WarningMsg')
      endtry
    endif
    try
      for name in readdir(src)
        if name ==# '.' || name ==# '..'
          continue
        endif
        if !CopyPath(PathJoin(src, name), PathJoin(dst, name))
          return false
        endif
      endfor
    catch
      # Log('CopyPath: readdir exception ' .. v:exception, 'ErrorMsg')
      return false
    endtry
    return true
  else
    try
      call mkdir(fnamemodify(dst, ':h'), 'p')
    catch
      # Log('CopyPath: mkdir parent exception ' .. v:exception, 'ErrorMsg')
      return false
    endtry
    try
      if writefile(readfile(src, 'b'), dst, 'b') != 0
        # Log('CopyPath: writefile failed dst=' .. dst, 'ErrorMsg')
        return false
      endif
      if exists('*getfperm') && exists('*setfperm')
        var p2 = getfperm(src)
        if type(p2) == v:t_string && p2 !=# ''
          call setfperm(dst, p2)
        endif
      endif
      return true
    catch
      # Log('CopyPath: file copy exception ' .. v:exception, 'ErrorMsg')
      return false
    endtry
  endif
enddef

# 递归删除
def DeletePathRecursive(p: string): bool
  # Log('DeletePathRecursive "' .. p .. '"')
  if !PathExists(p)
    return true
  endif
  try
    var rc = delete(p, 'rf')
    return rc == 0
  catch
    # Log('DeletePathRecursive: delete rf ex ' .. v:exception, 'WarningMsg')
  endtry
  if isdirectory(p)
    try
      for name in readdir(p)
        if name ==# '.' || name ==# '..'
          continue
        endif
        if !DeletePathRecursive(PathJoin(p, name))
          return false
        endif
      endfor
    catch
      # Log('DeletePathRecursive: readdir exception ' .. v:exception, 'ErrorMsg')
      return false
    endtry
    try
      return delete(p, 'd') == 0
    catch
      # Log('DeletePathRecursive: delete dir ex ' .. v:exception, 'ErrorMsg')
      return false
    endtry
  else
    try
      return delete(p) == 0
    catch
      # Log('DeletePathRecursive: delete file ex ' .. v:exception, 'ErrorMsg')
      return false
    endtry
  endif
enddef

# 移动（剪切）：先尝试 rename；失败则 Copy + Delete
def MovePath(src: string, dst: string): bool
  # Log('MovePath "' .. src .. '" -> "' .. dst .. '"')
  try
    call mkdir(fnamemodify(dst, ':h'), 'p')
  catch
    # Log('MovePath: mkdir parent ex ' .. v:exception, 'ErrorMsg')
    return false
  endtry
  try
    var rc = rename(src, dst)
    if rc == 0
      return true
    endif
    # Log('MovePath: rename failed rc=' .. rc .. ', fallback to copy+delete', 'WarningMsg')
  catch
    # Log('MovePath: rename exception ' .. v:exception .. ', fallback to copy+delete', 'WarningMsg')
  endtry
  if !CopyPath(src, dst)
    return false
  endif
  return DeletePathRecursive(src)
enddef

# 冲突处理：询问覆盖或改名或放弃
# 返回最终目标路径，或空字符串表示取消
def ResolveConflict(destDir: string, base: string): string
  var dst = PathJoin(destDir, base)
  if !PathExists(dst)
    return dst
  endif
  var prompt = 'Target exists: ' .. dst .. '. [o]verwrite / [r]ename / [c]ancel: '
  var ans = input(prompt)
  if ans ==# 'o' || ans ==# 'O'
    return dst
  elseif ans ==# 'r' || ans ==# 'R'
    var newname = input('New name: ', base)
    if newname ==# ''
      return ''
    endif
    return ResolveConflict(destDir, newname)
  else
    return ''
  endif
enddef

# 新建时：循环直到唯一名字或取消
def AskUniqueName(destDir: string, base: string): string
  var name = base
  while name !=# ''
    var dst = PathJoin(destDir, name)
    if !PathExists(dst)
      return dst
    endif
    name = input('Exists: ' .. dst .. ' . Input another name (empty to cancel): ', name .. ' copy')
  endwhile
  return ''
enddef

# 只刷新一个目录并在展开时重新扫描
def InvalidateAndRescan(dir_path: string)
  # Log('InvalidateAndRescan dir="' .. dir_path .. '"')
  CancelPending(dir_path)
  if has_key(s_cache, dir_path)
    call remove(s_cache, dir_path)
  endif
  if has_key(s_loading, dir_path)
    call remove(s_loading, dir_path)
  endif
  if GetNodeState(dir_path).expanded
    ScanDirAsync(dir_path)
  endif
enddef

# 操作目的目录：目录取自身；文件取父目录
def TargetDirForNode(node: dict<any>): string
  if empty(node)
    return ''
  endif
  return node.is_dir ? node.path : fnamemodify(node.path, ':h')
enddef

def BufValid(): bool
  var ok = s_bufnr > 0 && bufexists(s_bufnr)
  # Log('BufValid? bufnr=' .. s_bufnr .. ' => ' .. (ok ? 'true' : 'false'))
  return ok
enddef

def WinValid(): bool
  var ok = (s_winid != 0 && win_id2win(s_winid) > 0)
  # Log('WinValid? winid=' .. s_winid .. ' => ' .. (ok ? 'true' : 'false'))
  return ok
enddef

def OtherWindowId(): number
  # Log('OtherWindowId enter')
  var wins = getwininfo()
  for w in wins
    if w.winid != s_winid
      # Log('OtherWindowId found: ' .. w.winid)
      return w.winid
    endif
  endfor
  # Log('OtherWindowId: none')
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
    # Log('GetNodeState init: path="' .. path .. '" expanded=false')
  else
    # Log('GetNodeState hit: path="' .. path .. '" expanded=' .. (s_state[path].expanded ? 'true' : 'false'))
  endif
  return s_state[path]
enddef

# =============================================================
# 后端（合并）
# =============================================================
def BNextId(): number
  s_bnext_id += 1
  # Log('BNextId => ' .. s_bnext_id)
  return s_bnext_id
enddef

def BFindBackend(): string
  # Log('BFindBackend enter')
  var override = get(g:, 'simpletree_daemon_path', '')
  if type(override) == v:t_string && override !=# '' && executable(override)
    # Log('BFindBackend override executable: ' .. override, 'MoreMsg')
    return override
  endif
  # Log('BFindBackend searching &runtimepath', 'MoreMsg')
  for dir in split(&runtimepath, ',')
    var p = dir .. '/lib/simpletree-daemon'
    if executable(p)
      # Log('BFindBackend found: ' .. p, 'MoreMsg')
      return p
    endif
  endfor
  # Log('BFindBackend not found', 'WarningMsg')
  return ''
enddef

def BIsRunning(): bool
  # Log('BIsRunning => ' .. (s_brunning ? 'true' : 'false'))
  return s_brunning
enddef

def BEnsureBackend(cmd: string = ''): bool
  # Log('BEnsureBackend enter cmd="' .. cmd .. '"')
  if BIsRunning()
    # Log('BEnsureBackend already running', 'MoreMsg')
    return true
  endif
  var cmdExe = cmd ==# '' ? BFindBackend() : cmd
  # Log('BEnsureBackend resolved cmdExe="' .. cmdExe .. '"')
  if cmdExe ==# '' || !executable(cmdExe)
    echohl ErrorMsg
    echom '[SimpleTree] backend not found. Set g:simpletree_daemon_path or put simpletree-daemon into runtimepath/lib/.'
    echohl None
    # Log('BEnsureBackend failed: backend not executable', 'ErrorMsg')
    return false
  endif

  s_bbuf = ''
  # Log('BEnsureBackend starting job: ' .. cmdExe, 'Title')
  try
    s_bjob = job_start([cmdExe], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, line) => {
        if line ==# ''
          # Log('out_cb: skip empty line')
          return
        endif
        var ev: any
        try
          ev = json_decode(line)
          # Log('out_cb: json decoded ok: ' .. line)
        catch
          # Log('out_cb: json_decode failed, line="' .. line .. '"', 'WarningMsg')
          return
        endtry
        if type(ev) != v:t_dict || !has_key(ev, 'type')
          # Log('out_cb: unexpected event shape', 'WarningMsg')
          return
        endif
        if ev.type ==# 'list_chunk'
          var id = ev.id
          # Log('out_cb: list_chunk id=' .. id .. ' entries=' .. len(get(ev, 'entries', [])) .. ' done=' .. (get(ev, 'done', v:false) ? 'true' : 'false'), 'MoreMsg')
          if has_key(s_bcbs, id)
            if has_key(ev, 'entries')
              try
                s_bcbs[id].OnChunk(ev.entries)
                # Log('out_cb: OnChunk dispatched id=' .. id)
              catch
                # Log('out_cb: OnChunk handler exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
              endtry
            endif
            if get(ev, 'done', v:false)
              try
                s_bcbs[id].OnDone()
                # Log('out_cb: OnDone dispatched id=' .. id)
              catch
                # Log('out_cb: OnDone handler exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
              endtry
              call remove(s_bcbs, id)
              # Log('out_cb: callbacks removed id=' .. id)
            endif
          else
            # Log('out_cb: id not found in s_bcbs: ' .. id, 'WarningMsg')
          endif
        elseif ev.type ==# 'error'
          var id = get(ev, 'id', 0)
          var msg2 = get(ev, 'message', '')
          # Log('out_cb: error event id=' .. id .. ' message="' .. msg2 .. '"', 'ErrorMsg')
          if id != 0 && has_key(s_bcbs, id)
            try
              s_bcbs[id].OnError(msg2)
              # Log('out_cb: OnError dispatched id=' .. id)
            catch
              # Log('out_cb: OnError handler exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
            endtry
            call remove(s_bcbs, id)
            # Log('out_cb: callbacks removed after error id=' .. id)
          else
            # Log('backend error (no id): ' .. msg2, 'ErrorMsg')
          endif
        else
          # Log('out_cb: unknown ev.type="' .. ev.type .. '"', 'WarningMsg')
        endif
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        # Log('[stderr] ' .. line, 'WarningMsg')
      },
      exit_cb: (ch, code) => {
        # Log('backend exited with code ' .. code, code == 0 ? 'MoreMsg' : 'ErrorMsg')
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
    # Log('BEnsureBackend job_start exception: ' .. v:exception, 'ErrorMsg')
    return false
  endtry

  s_brunning = (s_bjob != v:null)
  # Log('BEnsureBackend success: running=' .. (s_brunning ? 'true' : 'false'))
  return s_brunning
enddef

def BStop(): void
  # Log('BStop enter', 'Title')
  if s_bjob != v:null
    try
      call('job_stop', [s_bjob])
      # Log('BStop job_stop ok')
    catch
      # Log('BStop job_stop exception: ' .. v:exception, 'ErrorMsg')
    endtry
  endif
  s_brunning = false
  s_bjob = v:null
  s_bbuf = ''
  s_bcbs = {}
  # Log('BStop done')
enddef

def BSend(req: dict<any>): void
  if !BIsRunning()
    # Log('BSend skipped: backend not running', 'WarningMsg')
    return
  endif
  try
    var json = json_encode(req) .. "\n"
    # Log('BSend: ' .. json)
    ch_sendraw(s_bjob, json)
  catch
    # Log('BSend exception: ' .. v:exception, 'ErrorMsg')
  endtry
enddef

def BList(path: string, show_hidden: bool, max: number, OnChunk: func, OnDone: func, OnError: func): number
  # Log('BList enter path="' .. path .. '" show_hidden=' .. (show_hidden ? 'true' : 'false') .. ' max=' .. max, 'Title')
  if !BEnsureBackend()
    try
      OnError('backend not available')
      # Log('BList immediate OnError: backend not available', 'ErrorMsg')
    catch
      # Log('BList OnError exception: ' .. v:exception, 'ErrorMsg')
    endtry
    return 0
  endif
  var id = BNextId()
  s_bcbs[id] = {OnChunk: OnChunk, OnDone: OnDone, OnError: OnError}
  # Log('BList sending request id=' .. id)
  BSend({type: 'list', id: id, path: path, show_hidden: show_hidden, max: max})
  return id
enddef

def BCancel(id: number): void
  # Log('BCancel enter id=' .. id)
  if id <= 0 || !BIsRunning()
    # Log('BCancel skipped: invalid id or backend not running')
    return
  endif
  BSend({type: 'cancel', id: id})
  if has_key(s_bcbs, id)
    call remove(s_bcbs, id)
    # Log('BCancel: callbacks removed id=' .. id)
  endif
enddef

# =============================================================
# 前端 <-> 后端
# =============================================================
def CancelPending(path: string)
  # Log('CancelPending enter path="' .. path .. '"')
  if has_key(s_pending, path)
    try
      var pid = s_pending[path]
      # Log('CancelPending: cancel id=' .. pid)
      BCancel(pid)
    catch
      # Log('CancelPending exception: ' .. v:exception, 'ErrorMsg')
    endtry
    call remove(s_pending, path)
    # Log('CancelPending: removed from s_pending path="' .. path .. '"')
  else
    # Log('CancelPending: no pending for path')
  endif
enddef

def ScanDirAsync(path: string)
  # Log('ScanDirAsync enter path="' .. path .. '" hide_dotfiles=' .. (s_hide_dotfiles ? 'true' : 'false'))
  if has_key(s_cache, path) || get(s_loading, path, v:false)
    # Log('ScanDirAsync skip: cache_exists=' .. (has_key(s_cache, path) ? 'true' : 'false') .. ' loading=' .. (get(s_loading, path, v:false) ? 'true' : 'false'))
    return
  endif

  CancelPending(path)

  s_loading[path] = true
  # Log('ScanDirAsync set loading=true path="' .. path .. '"')
  var acc: list<dict<any>> = []
  var p = path
  var req_id: number = 0

  req_id = BList(
    p,
    !s_hide_dotfiles,
    g:simpletree_page,
    (entries) => {
      # Log('ScanDirAsync.OnChunk path="' .. p .. '" entries_len=' .. len(entries))
      acc += entries
      s_cache[p] = acc
      # Log('ScanDirAsync.OnChunk cache_len=' .. len(s_cache[p]))
      Render()
    },
    () => {
      # Log('ScanDirAsync.OnDone path="' .. p .. '" final_len=' .. len(acc), 'MoreMsg')
      s_loading[p] = false
      s_cache[p] = acc
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
        # Log('ScanDirAsync.OnDone removed pending path="' .. p .. '"')
      endif
      Render()
    },
    (_msg) => {
      # Log('ScanDirAsync.OnError path="' .. p .. '" msg="' .. _msg .. '"', 'ErrorMsg')
      s_loading[p] = false
      if has_key(s_pending, p) && s_pending[p] == req_id
        call remove(s_pending, p)
        # Log('ScanDirAsync.OnError removed pending path="' .. p .. '"')
      endif
      # Log('list error for ' .. p, 'ErrorMsg')
      Render()
    }
  )

  # Log('ScanDirAsync BList returned id=' .. req_id)
  if req_id > 0
    s_pending[path] = req_id
    # Log('ScanDirAsync set pending id=' .. req_id .. ' path="' .. path .. '"')
  else
    s_loading[path] = false
    # Log('ScanDirAsync backend failed => set loading=false path="' .. path .. '"', 'WarningMsg')
  endif
enddef

# =============================================================
# 渲染
# =============================================================
def EnsureWindowAndBuffer()
  # Log('EnsureWindowAndBuffer enter', 'Title')
  if WinValid()
    try
      # Log('EnsureWindowAndBuffer: resize to ' .. g:simpletree_width)
      call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)
    catch
      # Log('EnsureWindowAndBuffer: resize exception ' .. v:exception, 'ErrorMsg')
    endtry
    return
  endif

  # Log('EnsureWindowAndBuffer: create vsplit (tree on the left)')
  execute 'topleft vertical vsplit'
  s_winid = win_getid()

  call win_execute(s_winid, 'silent enew')
  s_bufnr = winbufnr(s_winid)

  call win_execute(s_winid, 'file SimpleTree')

  call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)
  # Log('EnsureWindowAndBuffer: created winid=' .. s_winid .. ' bufnr=' .. s_bufnr)

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
    # Log('EnsureWindowAndBuffer: ' .. cmd)
  endfor

  call win_execute(s_winid, 'nnoremap <silent> <buffer> <CR> :call treexplorer#OnEnter()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> l :call treexplorer#OnExpand()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> h :call treexplorer#OnCollapse()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> R :call treexplorer#OnRefresh()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> H :call treexplorer#OnToggleHidden()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> q :call treexplorer#OnClose()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> s :call treexplorer#OnRootHere()<CR>')
  call win_execute(s_winid, 'nnoremap <nowait> <silent> <buffer> U :call treexplorer#OnRootUp()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> C :call treexplorer#OnRootPrompt()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> . :call treexplorer#OnRootCwd()<CR>')
  call win_execute(s_winid, 'nnoremap <nowait> <silent> <buffer> d :call treexplorer#OnRootCurrent()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> L :call treexplorer#OnToggleRootLock()<CR>')
  # File ops
  call win_execute(s_winid, 'nnoremap <silent> <buffer> c :call treexplorer#OnCopy()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> x :call treexplorer#OnCut()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> p :call treexplorer#OnPaste()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> a :call treexplorer#OnNewFile()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> A :call treexplorer#OnNewFolder()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> r :call treexplorer#OnRename()<CR>')
  call win_execute(s_winid, 'nnoremap <silent> <buffer> D :call treexplorer#OnDelete()<CR>')
  # Help
  call win_execute(s_winid, 'nnoremap <silent> <buffer> ? :call treexplorer#ShowHelp()<CR>')
  # Log('EnsureWindowAndBuffer: mappings set')

  call win_execute(s_winid, 'augroup SimpleTreeBuf')
  call win_execute(s_winid, 'autocmd!')
  call win_execute(s_winid, 'autocmd BufWipeout <buffer> ++once call treexplorer#OnBufWipe()')
  call win_execute(s_winid, 'augroup END')
  # Log('EnsureWindowAndBuffer: autocmds set')
enddef

def BuildLines(path: string, depth: number, lines: list<string>, idx: list<dict<any>>)
  # Log('BuildLines enter path="' .. path .. '" depth=' .. depth)
  var want = GetNodeState(path).expanded
  if !want
    # Log('BuildLines: not expanded, return path="' .. path .. '"')
    return
  endif

  var hasCache = has_key(s_cache, path)
  var isLoading = get(s_loading, path, v:false)
  # Log('BuildLines: hasCache=' .. (hasCache ? 'true' : 'false') .. ' isLoading=' .. (isLoading ? 'true' : 'false'))

  if !hasCache
    if !isLoading
      # Log('BuildLines: no cache and not loading => trigger ScanDirAsync(path)', 'WarningMsg')
      ScanDirAsync(path)
    endif
    lines->add(repeat('  ', depth) .. '⏳ Loading...')
    idx->add({path: '', is_dir: false, name: '', depth: depth, loading: true})
    # Log('BuildLines: appended Loading placeholder path="' .. path .. '" depth=' .. depth)
    return
  endif

  var entries = s_cache[path]
  # Log('BuildLines: entries_len=' .. len(entries) .. ' path="' .. path .. '"')
  for e in entries
    var icon = e.is_dir ? (GetNodeState(e.path).expanded ? '▾ ' : '▸ ') : '  '
    var suffix = e.is_dir ? '/' : ''
    var text = repeat('  ', depth) .. icon .. e.name .. suffix
    lines->add(text)
    idx->add({path: e.path, is_dir: e.is_dir, name: e.name, depth: depth})
    # Log('BuildLines: add line "' .. text .. '"')

    if e.is_dir && GetNodeState(e.path).expanded
      # Log('BuildLines: recurse into dir path="' .. e.path .. '" depth=' .. (depth + 1))
      BuildLines(e.path, depth + 1, lines, idx)
    endif
  endfor
enddef

def Render()
  # Log('Render enter', 'Title')
  if s_root ==# ''
    # Log('Render: s_root empty, return', 'WarningMsg')
    return
  endif
  EnsureWindowAndBuffer()

  var lines: list<string> = []
  var idx: list<dict<any>> = []

  var stroot = GetNodeState(s_root)
  stroot.expanded = true
  # Log('Render: root expanded=true s_root="' .. s_root .. '"')

  BuildLines(s_root, 0, lines, idx)

  if len(lines) == 0 && get(s_loading, s_root, v:false)
    lines = ['⏳ Loading...']
    idx = [{path: '', is_dir: false, name: '', depth: 0, loading: true}]
    # Log('Render: only root loading placeholder')
  endif

  if !BufValid()
    # Log('Render: buffer invalid, return', 'ErrorMsg')
    return
  endif

  try
    call setbufvar(s_bufnr, '&modifiable', 1)
    # Log('Render: set modifiable=1')
  catch
    # Log('Render: set modifiable=1 exception ' .. v:exception, 'ErrorMsg')
  endtry

  var out = len(lines) == 0 ? [''] : lines
  # Log('Render: setbufline count=' .. len(out))
  call setbufline(s_bufnr, 1, out)

  var bi = getbufinfo(s_bufnr)
  if len(bi) > 0
    var lc = get(bi[0], 'linecount', 0)
    if lc > len(out)
      try
        call deletebufline(s_bufnr, len(out) + 1, lc)
        # Log('Render: deletebufline from ' .. (len(out) + 1) .. ' to ' .. lc)
      catch
        # Log('Render: deletebufline exception ' .. v:exception, 'ErrorMsg')
      endtry
    endif
  endif

  try
    call setbufvar(s_bufnr, '&modifiable', 0)
    # Log('Render: set modifiable=0')
  catch
    # Log('Render: set modifiable=0 exception ' .. v:exception, 'ErrorMsg')
  endtry

  var maxline = max([1, len(out)])
  try
    call win_execute(s_winid, 'if line(".") > ' .. maxline .. ' | normal! G | endif')
    # Log('Render: cursor clamp maxline=' .. maxline)
  catch
    # Log('Render: cursor clamp exception ' .. v:exception, 'ErrorMsg')
  endtry

  s_line_index = idx
  # Log('Render: index_len=' .. len(idx) .. ' loading_keys=' .. string(keys(s_loading)) .. ' cache_keys=' .. string(keys(s_cache)))
enddef

# =============================================================
# 根路径切换与锁定
# =============================================================
def SetRoot(new_root: string, lock: bool = false)
  # Log('SetRoot enter new_root="' .. new_root .. '" lock=' .. (lock ? 'true' : 'false') ..
  #     ' from_root="' .. s_root .. '" locked=' .. (s_root_locked ? 'true' : 'false'), 'Title')
  var nr = CanonDir(new_root)
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
  # Log('SetRoot: root expanded set true')

  for [p, id] in items(s_pending)
    try
      BCancel(id)
    catch
      # Log('SetRoot: BCancel exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
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
  # Log('OnToggleRootLock => ' .. (s_root_locked ? 'ON' : 'OFF'), 'MoreMsg')
enddef

export def OnRootHere()
  # Log('OnRootHere', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    # Log('OnRootHere: empty or loading node, return', 'WarningMsg')
    return
  endif
  var p = node.is_dir ? node.path : fnamemodify(node.path, ':h')
  SetRoot(p)
enddef

export def OnRootUp()
  # Log('OnRootUp', 'Title')
  # DebugContext('OnRootUp')
  if s_root_locked
    echo '[SimpleTree] root is locked. Press L to unlock.'
    # Log('OnRootUp: root locked, abort', 'WarningMsg')
    return
  endif
  if s_root ==# ''
    Log('OnRootUp: s_root empty', 'WarningMsg')
    return
  endif

  var cur = CanonDir(s_root)
  var up = ParentDir(cur)
  # Log('OnRootUp: current="' .. cur .. '" parent="' .. up .. '"')

  if RStripSlash(up) ==# RStripSlash(cur)
    # 已经在最顶层：Unix "/" 或 Windows "C:/"
    Log('OnRootUp: already top-most, noop', 'WarningMsg')
    return
  endif

  SetRoot(up)
enddef

export def OnRootPrompt()
  # Log('OnRootPrompt', 'Title')
  var start = s_root !=# '' ? s_root : getcwd()
  var inp = input('SimpleTree new root: ', start, 'dir')
  if inp ==# ''
    # Log('OnRootPrompt: empty input', 'WarningMsg')
    return
  endif
  SetRoot(inp)
enddef

export def OnRootCwd()
  # Log('OnRootCwd', 'Title')
  SetRoot(getcwd())
enddef

export def OnRootCurrent()
  # Log('OnRootCurrent', 'Title')
  # DebugContext('OnRootCurrent')
  if s_root_locked
    echo '[SimpleTree] root is locked. Press L to unlock.'
    # Log('OnRootCurrent: root locked, abort', 'WarningMsg')
    return
  endif

  # 优先尝试从“非树窗口”的文件获取路径
  var ap = ''
  var other = OtherWindowId()
  if other != 0
    var wi = getwininfo(other)
    if len(wi) > 0
      var obuf = wi[0].bufnr
      var oname = bufname(obuf)
      var cand = fnamemodify(oname, ':p')
      # Log('OnRootCurrent: other win cand="' .. cand .. '" readable=' .. (filereadable(cand) ? 'true' : 'false'))
      if cand !=# '' && filereadable(cand)
        ap = cand
      endif
    else
      # Log('OnRootCurrent: getwininfo(other) empty', 'WarningMsg')
    endif
  else
    # Log('OnRootCurrent: no other window, fallback to current buffer', 'WarningMsg')
  endif

  # 其次尝试本窗口（如果当前并非树缓冲，也能用）
  if ap ==# ''
    var cur = expand('%:p')
    # Log('OnRootCurrent: fallback current buf path="' .. cur .. '" readable=' .. (filereadable(cur) ? 'true' : 'false'))
    if cur !=# '' && filereadable(cur)
      ap = fnamemodify(cur, ':p')
    endif
  endif

  # 最后兜底使用 cwd
  var p = (ap ==# '') ? getcwd() : fnamemodify(ap, ':h')
  # Log('OnRootCurrent: resolved dir="' .. p .. '"')
  SetRoot(p)
enddef

# 打印当前上下文：当前根/锁、树窗口、另一个窗口及其文件
def DebugContext(tag: string): void
  var curbuf = bufnr('%')
  var curbufname = bufname(curbuf)
  var other = OtherWindowId()
  Log(printf('CTX[%s] root="%s" locked=%s tree_win=%d curbuf=%d curbufname="%s" other_win=%d',
        tag, s_root, (s_root_locked ? 'true' : 'false'), s_winid, curbuf, curbufname, other), 'MoreMsg')
  if other != 0
    var w = getwininfo(other)
    if len(w) > 0
      var obuf = w[0].bufnr
      var oname = bufname(obuf)
      var ap = fnamemodify(oname, ':p')
      Log(printf('CTX[%s] other: bufnr=%d name="%s" abs="%s" readable=%s',
            tag, obuf, oname, ap, (filereadable(ap) ? 'true' : 'false')), 'MoreMsg')
    else
      Log('CTX[' .. tag .. '] other wininfo empty', 'WarningMsg')
    endif
  endif
enddef

# =============================================================
# 用户交互（导出）
# =============================================================
def CursorNode(): dict<any>
  var lnum = line('.')
  if lnum <= 0 || lnum > len(s_line_index)
    # Log('CursorNode: lnum=' .. lnum .. ' out of range', 'WarningMsg')
    return {}
  endif
  var node = s_line_index[lnum - 1]
  # Log('CursorNode: lnum=' .. lnum .. ' node=' .. string(node))
  return node
enddef

# 不再在找不到目标时跳到顶部，保持当前位置
def FocusPath(path: string): void
  # Log('FocusPath enter path="' .. path .. '"')
  if !WinValid()
    # Log('FocusPath: window invalid', 'WarningMsg')
    return
  endif
  if path ==# ''
    # Log('FocusPath: empty path', 'WarningMsg')
    return
  endif
  var target: number = 0
  for i in range(len(s_line_index))
    if get(s_line_index[i], 'path', '') ==# path
      target = i + 1
      break
    endif
  endfor
  if target > 0
    try
      call win_execute(s_winid, 'normal! ' .. target .. 'G')
      # Log('FocusPath: moved cursor to line ' .. target)
    catch
      # Log('FocusPath: win_execute exception ' .. v:exception, 'ErrorMsg')
    endtry
  else
    # Log('FocusPath: path not found, keep cursor unmoved')
  endif
enddef

def FocusFirstChild(dir_path: string): void
  # Log('FocusFirstChild enter dir_path="' .. dir_path .. '"')
  if !WinValid()
    # Log('FocusFirstChild: window invalid', 'WarningMsg')
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
    # Log('FocusFirstChild: dir not found in index', 'WarningMsg')
    return
  endif
  var next_idx = idx_dir + 1
  if next_idx < len(s_line_index)
    var next = s_line_index[next_idx]
    if get(next, 'depth', -1) == dir_depth + 1
      try
        call win_execute(s_winid, 'normal! ' .. (next_idx + 1) .. 'G')
        # Log('FocusFirstChild: moved to first child line ' .. (next_idx + 1))
      catch
        # Log('FocusFirstChild: win_execute exception ' .. v:exception, 'ErrorMsg')
      endtry
    else
      # Log('FocusFirstChild: next line is not a child (depth mismatch)')
    endif
  else
    # Log('FocusFirstChild: no next line')
  endif
enddef

# 折叠最近的已展开祖先
def CollapseNearestExpandedAncestor(path: string): void
  # Log('CollapseNearestExpandedAncestor enter path="' .. path .. '"')
  var p = fnamemodify(path, ':h')
  while p !=# ''
    if p ==# s_root
      # Log('CollapseNearestExpandedAncestor: parent is root, keep cursor unmoved')
      return
    endif
    if GetNodeState(p).expanded
      # Log('CollapseNearestExpandedAncestor: collapse target "' .. p .. '"')
      ToggleDir(p)
      FocusPath(p)
      return
    endif
    var nextp = fnamemodify(p, ':h')
    if nextp ==# p
      # Log('CollapseNearestExpandedAncestor: reached path top, break to avoid loop')
      break
    endif
    p = nextp
  endwhile
  var parent = fnamemodify(path, ':h')
  if parent !=# '' && parent !=# s_root
    FocusPath(parent)
    # Log('CollapseNearestExpandedAncestor: focus parent "' .. parent .. '"')
  else
    # Log('CollapseNearestExpandedAncestor: parent is root or empty, keep cursor unmoved')
  endif
enddef

def ToggleDir(path: string)
  # Log('ToggleDir enter path="' .. path .. '"')
  var st = GetNodeState(path)
  st.expanded = !st.expanded
  # Log('ToggleDir: expanded=' .. (st.expanded ? 'true' : 'false') .. ' path="' .. path .. '"')
  if st.expanded && !has_key(s_cache, path) && !get(s_loading, path, v:false)
    # Log('ToggleDir: expanded without cache/loading, trigger ScanDirAsync', 'MoreMsg')
    ScanDirAsync(path)
  endif
  Render()
enddef

def OpenFile(p: string)
  # Log('OpenFile enter p="' .. p .. '"')
  if p ==# ''
    # Log('OpenFile: empty path, return', 'WarningMsg')
    return
  endif
  var keep = !!g:simpletree_keep_focus
  # Log('OpenFile: keep_focus=' .. (keep ? 'true' : 'false'))

  var other = OtherWindowId()
  if other != 0
    # Log('OpenFile: goto other winid=' .. other)
    call win_gotoid(other)
  else
    # Log('OpenFile: create vsplit')
    execute 'vsplit'
  endif
  # Log('OpenFile: edit ' .. fnameescape(p))
  execute 'edit ' .. fnameescape(p)

  if keep
    # Log('OpenFile: go back to tree winid=' .. s_winid)
    call win_gotoid(s_winid)
  endif
enddef

export def OnEnter()
  # Log('OnEnter', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    # Log('OnEnter: empty or loading node, return', 'WarningMsg')
    return
  endif
  if node.is_dir
    # Log('OnEnter: toggle dir path="' .. node.path .. '"')
    ToggleDir(node.path)
  else
    # Log('OnEnter: open file path="' .. node.path .. '"')
    OpenFile(node.path)
  endif
enddef

# l：目录上展开并定位第一个子项；文件上打开文件
export def OnExpand()
  # Log('OnExpand', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    # Log('OnExpand: empty or loading node, return', 'WarningMsg')
    return
  endif
  if node.is_dir
    if !GetNodeState(node.path).expanded
      # Log('OnExpand: expand dir path="' .. node.path .. '"')
      ToggleDir(node.path)
    else
      # Log('OnExpand: dir already expanded path="' .. node.path .. '"')
    endif
    FocusFirstChild(node.path)
  else
    # Log('OnExpand: node is file => open path="' .. node.path .. '"')
    OpenFile(node.path)
  endif
enddef

# h：目录已展开时折叠当前；目录已折叠或文件时折叠最近的已展开父目录
export def OnCollapse()
  # Log('OnCollapse', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    # Log('OnCollapse: empty or loading node, return', 'WarningMsg')
    return
  endif
  if node.is_dir
    if GetNodeState(node.path).expanded
      # Log('OnCollapse: collapse current dir path="' .. node.path .. '"')
      ToggleDir(node.path)
    else
      var parent = fnamemodify(node.path, ':h')
      if parent ==# s_root
        # Log('OnCollapse: top-level collapsed dir, keep cursor unmoved')
        return
      endif
      # Log('OnCollapse: dir is collapsed, collapse parent chain from "' .. node.path .. '"')
      CollapseNearestExpandedAncestor(node.path)
    endif
  else
    # Log('OnCollapse: node is file => collapse parent chain')
    CollapseNearestExpandedAncestor(node.path)
  endif
enddef

export def OnRefresh()
  # Log('OnRefresh', 'Title')
  Refresh()
enddef

export def OnToggleHidden()
  # Log('OnToggleHidden before s_hide_dotfiles=' .. (s_hide_dotfiles ? 'true' : 'false'), 'Title')
  s_hide_dotfiles = !s_hide_dotfiles
  # Log('OnToggleHidden after s_hide_dotfiles=' .. (s_hide_dotfiles ? 'true' : 'false'))
  Refresh()
enddef

export def OnClose()
  # Log('OnClose', 'Title')
  Close()
enddef

export def OnBufWipe()
  # Log('OnBufWipe', 'Title')
  s_winid = 0
  s_bufnr = -1
enddef

# ===== 文件操作：复制/剪切/粘贴/新建/重命名/删除 =====
export def OnCopy()
  # Log('OnCopy', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    echo '[SimpleTree] nothing to copy'
    return
  endif
  s_clipboard = {mode: 'copy', items: [node.path]}
  echo '[SimpleTree] copy: ' .. node.path
  # Log('OnCopy set clipboard copy ' .. string(s_clipboard))
enddef

export def OnCut()
  # Log('OnCut', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    echo '[SimpleTree] nothing to cut'
    return
  endif
  s_clipboard = {mode: 'cut', items: [node.path]}
  echo '[SimpleTree] cut: ' .. node.path
  # Log('OnCut set clipboard cut ' .. string(s_clipboard))
enddef

export def OnPaste()
  # Log('OnPaste', 'Title')
  if type(s_clipboard) != v:t_dict || get(s_clipboard, 'mode', '') ==# '' || len(get(s_clipboard, 'items', [])) == 0
    echo '[SimpleTree] clipboard empty'
    # Log('OnPaste: clipboard empty', 'WarningMsg')
    return
  endif
  var node = CursorNode()
  if empty(node)
    echo '[SimpleTree] no target selected'
    return
  endif
  var destDir = TargetDirForNode(node)
  if destDir ==# '' || !isdirectory(destDir)
    echo '[SimpleTree] invalid target directory'
    return
  endif

  var mode = s_clipboard.mode
  var srcs: list<string> = s_clipboard.items
  var focused = ''

  for src in srcs
    if !PathExists(src)
      echo '[SimpleTree] skip missing: ' .. src
      continue
    endif
    var base = fnamemodify(src, ':t')
    var dst = ResolveConflict(destDir, base)
    if dst ==# ''
      echo '[SimpleTree] skip: ' .. base
      continue
    endif
    if PathExists(dst) && (mode ==# 'copy' || mode ==# 'cut')
      call DeletePathRecursive(dst)
    endif
    var ok = false
    if mode ==# 'copy'
      ok = CopyPath(src, dst)
    else
      ok = MovePath(src, dst)
    endif
    if ok
      echo '[SimpleTree] ' .. (mode ==# 'copy' ? 'copied' : 'moved') .. ': ' .. base .. ' -> ' .. destDir
      focused = dst
      InvalidateAndRescan(destDir)
      if mode ==# 'cut'
        var sp = fnamemodify(src, ':h')
        if sp !=# destDir
          InvalidateAndRescan(sp)
        endif
      endif
    else
      echohl ErrorMsg
      echom '[SimpleTree] failed to ' .. (mode ==# 'copy' ? 'copy' : 'move') .. ': ' .. src
      echohl None
    endif
  endfor

  Render()
  if focused !=# ''
    Refresh()
    RevealPath(focused)
  endif

  if mode ==# 'cut'
    s_clipboard = {mode: '', items: []}
  endif
enddef

export def OnNewFile()
  # Log('OnNewFile', 'Title')
  var node = CursorNode()
  if empty(node)
    echo '[SimpleTree] no target selected'
    return
  endif
  var destDir = TargetDirForNode(node)
  if destDir ==# '' || !isdirectory(destDir)
    echo '[SimpleTree] invalid target directory'
    return
  endif
  var name = input('New file name: ')
  if name ==# ''
    # Log('OnNewFile: empty name', 'WarningMsg')
    return
  endif
  if name =~ '[\/]'
    echohl ErrorMsg | echom '[SimpleTree] name cannot contain path separator' | echohl None
    return
  endif
  var dst = AskUniqueName(destDir, name)
  if dst ==# ''
    # Log('OnNewFile: canceled or no unique name')
    return
  endif
  try
    if writefile([], dst, 'b') != 0
      echohl ErrorMsg | echom '[SimpleTree] create file failed: ' .. dst | echohl None
      return
    endif
  catch
    echohl ErrorMsg | echom '[SimpleTree] create file exception: ' .. v:exception | echohl None
    return
  endtry
  echo '[SimpleTree] created file: ' .. dst
  Refresh()
  RevealPath(dst)
enddef

export def OnNewFolder()
  # Log('OnNewFolder', 'Title')
  var node = CursorNode()
  if empty(node)
    echo '[SimpleTree] no target selected'
    return
  endif
  var destDir = TargetDirForNode(node)
  if destDir ==# '' || !isdirectory(destDir)
    echo '[SimpleTree] invalid target directory'
    return
  endif
  var name = input('New folder name: ')
  if name ==# ''
    # Log('OnNewFolder: empty name', 'WarningMsg')
    return
  endif
  if name =~ '[\/]'
    echohl ErrorMsg | echom '[SimpleTree] name cannot contain path separator' | echohl None
    return
  endif
  var dst = AskUniqueName(destDir, name)
  if dst ==# ''
    # Log('OnNewFolder: canceled or no unique name')
    return
  endif
  try
    call mkdir(dst, 'p')
  catch
    echohl ErrorMsg | echom '[SimpleTree] create folder exception: ' .. v:exception | echohl None
    return
  endtry
  echo '[SimpleTree] created folder: ' .. dst
  Refresh()
  RevealPath(dst)
enddef

export def OnRename()
  # Log('OnRename', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    echo '[SimpleTree] nothing to rename'
    return
  endif
  var src = node.path
  var parent = fnamemodify(src, ':h')
  var base = fnamemodify(src, ':t')
  var newname = input('Rename to: ', base)
  if newname ==# ''
    # Log('OnRename: empty new name', 'WarningMsg')
    return
  endif
  if newname =~ '[\/]'
    echohl ErrorMsg | echom '[SimpleTree] name cannot contain path separator' | echohl None
    return
  endif
  var dst = PathJoin(parent, newname)
  if dst ==# src
    # Log('OnRename: same name, skip')
    return
  endif

  if PathExists(dst)
    var ans = input('Target exists. Overwrite? [y]es/[n]o: ')
    if ans !=# 'y' && ans !=# 'Y'
      echo '[SimpleTree] rename canceled'
      return
    endif
    if !DeletePathRecursive(dst)
      echohl ErrorMsg | echom '[SimpleTree] failed to remove existing target' | echohl None
      return
    endif
  endif

  if MovePath(src, dst)
    echo '[SimpleTree] renamed: ' .. base .. ' -> ' .. newname
    Refresh()
    RevealPath(dst)
  else
    echohl ErrorMsg | echom '[SimpleTree] rename failed' | echohl None
  endif
enddef

export def OnDelete()
  # Log('OnDelete', 'Title')
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    echo '[SimpleTree] nothing to delete'
    return
  endif
  var p = node.path
  if p ==# '' || !PathExists(p)
    echo '[SimpleTree] path not exists'
    return
  endif
  var ok = 0
  var msg = 'Delete ' .. (node.is_dir ? 'directory (recursively)' : 'file') .. ' "' .. p .. '" ?'
  if exists('*confirm')
    ok = (confirm(msg, "&Yes\n&No", 2) == 1) ? 1 : 0
  else
    ok = (input(msg .. ' [y/N]: ') =~? '^y') ? 1 : 0
  endif
  if !ok
    echo '[SimpleTree] delete canceled'
    return
  endif
  var parent = fnamemodify(p, ':h')
  if !DeletePathRecursive(p)
    echohl ErrorMsg | echom '[SimpleTree] delete failed' | echohl None
    return
  endif
  echo '[SimpleTree] deleted: ' .. p
  Refresh()
  if parent !=# ''
    RevealPath(parent)
  endif
enddef

# ====== 帮助面板（?）======
def BuildHelpLines(): list<string>
  return [
    'SimpleTree 快捷键说明',
    '----------------------------------------',
    '<CR>  打开文件 / 展开或折叠目录',
    'l     展开目录 / 打开文件',
    'h     折叠当前目录；若已折叠或在文件上，则折叠最近的已展开祖先',
    'R     刷新树（仅重扫缓存）',
    'H     显示/隐藏点文件',
    'q     关闭树窗口',
    's     将当前节点设为根（目录；文件取父目录）',
    'U     根上移一层',
    'C     输入路径作为根',
    '.     使用当前工作目录作为根',
    'd     使用当前文件所在目录作为根',
    'L     切换根锁定',
    'c     复制当前节点（文件/目录）',
    'x     剪切当前节点（文件/目录）',
    'p     粘贴到当前选中目录（或文件的父目录）',
    'a     在目标目录中新建文件',
    'A     在目标目录中新建文件夹',
    'r     重命名当前节点',
    'D     删除当前节点（目录为递归删除）',
    '?     显示/关闭本帮助面板',
    '----------------------------------------',
    '提示：粘贴/重命名时若存在同名目标：可选择覆盖或重命名；剪切成功后自动清空剪贴板。',
  ]
enddef

def HelpWinValid(): bool
  return s_help_winid != 0 && win_id2win(s_help_winid) > 0
enddef

# 关闭帮助：同时支持浮窗和分屏
def CloseHelp()
  # 优先关闭浮窗
  if s_help_popupid != 0 && exists('*popup_close')
    try
      call popup_close(s_help_popupid)
    catch
    endtry
    s_help_popupid = 0
    s_help_bufnr = -1
    return
  endif

  # 回退：关闭分屏窗口
  if s_help_winid != 0 && win_id2win(s_help_winid) > 0
    try
      call win_execute(s_help_winid, 'close')
    catch
    endtry
  endif
  s_help_winid = 0
  s_help_bufnr = -1
enddef

# 浮窗优先的帮助显示（不使用 popup_getbuf，修复 E117）
export def ShowHelp()
  # 已经显示则关闭（浮窗优先）
  if s_help_popupid != 0 && exists('*popup_close')
    CloseHelp()
    return
  endif

  var lines = BuildHelpLines()

  # 如果支持 popup_create，用居中浮窗显示
  if exists('*popup_create')
    # 计算宽高（注意逗号后留空格避免 E1069）
    var width = 0
    for l in lines
      width = max([width, strdisplaywidth(l)])
    endfor
    var height = min([max([10, len(lines) + 2]), 30])
    width += 6   # 预留左右边距和边框

    # 创建浮窗（不使用 popup_getbuf）
    var popid = popup_create(lines, {
      title: 'SimpleTree Help',
      pos: 'center',
      minwidth: width,
      minheight: height,
      padding: [0, 2, 0, 2],
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      zindex: 200,
      mapping: 0,
      # 过滤器：按 q 或 Esc 关闭
      filter: (id, key) => {
        if key ==# 'q' || key ==# "\<Esc>"
          try
            popup_close(id)
          catch
          endtry
          s_help_popupid = 0
          s_help_bufnr = -1
          return 1
        endif
        return 0
      }
    })

    s_help_popupid = popid
    s_help_bufnr = -1    # 不再依赖 popup_getbuf

    # 可选：设置高亮（某些版本有 popup_setoptions；没有则跳过）
    if exists('*popup_setoptions')
      try
        call popup_setoptions(popid, {
          highlight: 'Normal',
          borderhighlight: ['FloatBorder']
        })
      catch
      endtry
    endif

    # 返回到树窗口（如果存在）
    if WinValid()
      call win_gotoid(s_winid)
    endif
    return
  endif

  # 不支持 popup 的回退：分屏显示
  var height = min([max([10, len(lines) + 2]), 30])
  execute 'botright split'
  execute printf('resize %d', height)
  s_help_winid = win_getid()
  call win_execute(s_help_winid, 'silent enew')
  s_help_bufnr = winbufnr(s_help_winid)
  call win_execute(s_help_winid, 'file SimpleTree Help')
  var opts = [
    'setlocal buftype=nofile',
    'setlocal bufhidden=wipe',
    'setlocal nobuflisted',
    'setlocal noswapfile',
    'setlocal nowrap',
    'setlocal nonumber',
    'setlocal norelativenumber',
    'setlocal signcolumn=no',
    'setlocal foldcolumn=0',
    'setlocal winfixheight',
    'setlocal cursorline',
    'setlocal filetype=simpletreehelp'
  ]
  for cmd in opts
    call win_execute(s_help_winid, cmd)
  endfor

  call setbufline(s_help_bufnr, 1, lines)
  var bi = getbufinfo(s_help_bufnr)
  if len(bi) > 0
    var lc = get(bi[0], 'linecount', 0)
    if lc > len(lines)
      call deletebufline(s_help_bufnr, len(lines) + 1, lc)
    endif
  endif
  call win_execute(s_help_winid, 'setlocal nomodifiable')
  call win_execute(s_help_winid, 'nnoremap <silent> <buffer> q :close<CR>')
  if WinValid()
    call win_gotoid(s_winid)
  endif
enddef

# ====== Reveal：展开并定位到目标路径 ======
def FocusIfPresent(path: string): bool
  for i in range(len(s_line_index))
    if get(s_line_index[i], 'path', '') ==# path
      FocusPath(path)
      return true
    endif
  endfor
  return false
enddef

def RevealTimerCb(_id: number)
  if s_reveal_target ==# ''
    return
  endif
  if FocusIfPresent(s_reveal_target)
    s_reveal_target = ''
  endif
enddef

def RevealPath(path: string)
  # Log('RevealPath enter path="' .. path .. '"', 'Title')
  if path ==# '' || s_root ==# ''
    return
  endif

  var ap = AbsPath(path)
  s_reveal_target = ap

  # 如果目标是点文件且当前设置为“隐藏点文件”，则自动切换为显示
  # 并刷新后再次执行 Reveal，确保能看到并定位到该文件
  var base = fnamemodify(ap, ':t')
  if filereadable(ap) && base =~ '^\.'
    if s_hide_dotfiles
      s_hide_dotfiles = false
      g:simpletree_hide_dotfiles = 0
      echo '[SimpleTree] dotfiles hidden => OFF (auto). Showing hidden to reveal target.'
      Refresh()
      # 再次调用 RevealPath，以新的显示策略展开并定位到目标
      RevealPath(ap)
      return
    endif
  endif

  var cur_dir = filereadable(ap) ? fnamemodify(ap, ':h') : ap
  var r = s_root
  var guard = 0
  var chain: list<string> = []
  while cur_dir !=# '' && cur_dir !=# r && guard < 500
    chain->insert(cur_dir, 0)
    var nextp = fnamemodify(cur_dir, ':h')
    if nextp ==# cur_dir
      break
    endif
    cur_dir = nextp
    guard += 1
  endwhile

  for d in chain
    var d_state = GetNodeState(d)
    d_state.expanded = true
    if !has_key(s_cache, d)
      ScanDirAsync(d)
    endif
  endfor
  var r_state = GetNodeState(r)
  r_state.expanded = true
  var parent = fnamemodify(ap, ':h')
  if parent !=# '' && !has_key(s_cache, parent)
    ScanDirAsync(parent)
  endif
  Render()

  if exists('*timer_start')
    try
      if s_reveal_timer != 0
        call timer_stop(s_reveal_timer)
      endif
    catch
    endtry
    try
      s_reveal_timer = timer_start(100, (id) => RevealTimerCb(id), {repeat: 30})
    catch
      FocusPath(ap)
    endtry
  else
    FocusPath(ap)
  endif
enddef

# =============================================================
# 导出 API（供命令调用）
# =============================================================
export def Toggle(root: string = '')
  # Log('Toggle enter rootArg="' .. root .. '"', 'Title')
  if WinValid()
    # Log('Toggle: window valid => Close()', 'MoreMsg')
    Close()
    return
  endif

  # 先保存当前文件的绝对路径（在创建树窗口之前），避免 expand('%:p') 指向树缓冲区
  var curf0 = expand('%:p')
  var curf_abs = ''
  if curf0 !=# '' && filereadable(curf0)
    curf_abs = fnamemodify(curf0, ':p')
  endif
  # Log('Toggle: curf_abs "' .. curf_abs .. '"')

  var rootArg = root
  if rootArg ==# ''
    if s_root_locked && s_root !=# '' && IsDir(s_root)
      rootArg = s_root
      # Log('Toggle: use locked root "' .. rootArg .. '"')
    else
      # 优先用当前文件所在目录作为根；没有文件时回落到 cwd
      if curf_abs ==# ''
        rootArg = getcwd()
        # Log('Toggle: no file => use getcwd="' .. rootArg .. '"')
      else
        rootArg = fnamemodify(curf_abs, ':h')
        # Log('Toggle: use current file dir="' .. rootArg .. '"')
      endif
    endif
  endif
  # Log('Toggle rootArg: ' .. rootArg)

  s_root = AbsPath(rootArg)
  if !IsDir(s_root)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. s_root
    echohl None
    # Log('Toggle: invalid root "' .. s_root .. '"', 'ErrorMsg')
    return
  endif
  # Log('Toggle s_root: ' .. s_root)

  EnsureWindowAndBuffer()
  if !BEnsureBackend()
    echohl ErrorMsg
    echom '[SimpleTree] backend not available'
    echohl None
    # Log('Toggle: backend not available', 'ErrorMsg')
    return
  endif

  var st = GetNodeState(s_root)
  st.expanded = true
  # Log('Toggle: root expanded set true')

  ScanDirAsync(s_root)
  Render()

  # 使用之前保存的当前文件路径进行 Reveal（避免树缓冲导致的 expand('%:p') 失效）
  if curf_abs !=# '' && filereadable(curf_abs)
    RevealPath(curf_abs)
  endif
enddef

export def Refresh()
  # Log('Refresh enter', 'Title')
  for [p, id] in items(s_pending)
    # Log('Refresh: cancel pending path="' .. p .. '" id=' .. id)
    try
      BCancel(id)
    catch
      # Log('Refresh: BCancel exception id=' .. id .. ' ex=' .. v:exception, 'ErrorMsg')
    endtry
  endfor
  s_pending = {}
  s_loading = {}
  s_cache = {}
  # Log('Refresh: cleared pending/loading/cache')
  if s_root !=# ''
    # Log('Refresh: rescan root="' .. s_root .. '"')
    ScanDirAsync(s_root)
  else
    # Log('Refresh: s_root empty, skip rescan', 'WarningMsg')
  endif
  Render()
enddef

export def Close()
  # Log('Close enter', 'Title')
  if WinValid()
    try
      call win_execute(s_winid, 'close')
      # Log('Close: closed window id=' .. s_winid)
    catch
      # Log('Close: close exception ' .. v:exception, 'ErrorMsg')
    endtry
  else
    # Log('Close: window not valid')
  endif
  s_winid = 0
  s_bufnr = -1
  # Log('Close: reset win/buf')
enddef

export def Stop()
  # Log('Stop enter', 'Title')
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

# =============================================================
# 用户命令
# =============================================================
command! -nargs=? SimpleTree call treexplorer#Toggle(<q-args>)
