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
# 一键折叠（Collapse All）的快捷键（默认 Z，缓冲区内生效）
g:simpletree_collapse_all_key = get(g:, 'simpletree_collapse_all_key', 'Z')

def NFEnabled(): bool
  return !!get(g:, 'simpletree_use_nerdfont', 0)
enddef

# 图标集合（会根据 NF 状态初始化，并允许 g:simpletree_icons 覆盖）
var s_icons: dict<string> = {}

def SetupIcons()
  if NFEnabled()
    s_icons = {
      dir: '',        # 关闭的目录
      dir_open: '',   # 打开的目录
      file: '',       # 通用文件
      loading: ''     # 加载中
    }
  else
    s_icons = {
      dir: '▸',
      dir_open: '▾',
      file: '  ',
      loading: '⏳'
    }
  endif
  # 允许用户覆盖图标
  for [k, v] in items(get(g:, 'simpletree_icons', {}))
    s_icons[k] = v
  endfor
enddef

# 文件类型图标（常用扩展；未命中时用通用文件图标）
def FileIcon(name: string): string
  if !NFEnabled()
    return s_icons.file
  endif
  var ext = tolower(fnamemodify(name, ':e'))
  if ext ==# ''
    return '󰈙'   # 通用文件（无扩展）
  endif
  var m = {
    'vim': '', 'lua': '', 'py': '', 'rb': '', 'go': '', 'rs': '',
    'js': '', 'ts': '', 'jsx': '', 'tsx': '',
    'c': '', 'h': '', 'cpp': '', 'hpp': '',
    'java': '', 'kt': '',
    'sh': '', 'bash': '', 'zsh': '',
    'md': '', 'txt': '',
    'json': '', 'toml': '', 'yml': '', 'yaml': '', 'ini': '',
    'lock': '',
    'html': '', 'css': '', 'scss': '',
    'png': '', 'jpg': '', 'jpeg': '', 'gif': '', 'svg': '', 'webp': '',
    'pdf': '',
    'zip': '', 'tar': '', 'gz': '', '7z': ''
  }
  return get(m, ext, s_icons.file)
enddef

call SetupIcons()

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
      return false
    endtry
    return true
  else
    try
      call mkdir(fnamemodify(dst, ':h'), 'p')
    catch
      return false
    endtry
    try
      if writefile(readfile(src, 'b'), dst, 'b') != 0
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
      return false
    endtry
  endif
enddef

# 递归删除
def DeletePathRecursive(p: string): bool
  if !PathExists(p)
    return true
  endif
  try
    var rc = delete(p, 'rf')
    return rc == 0
  catch
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
      return false
    endtry
    try
      return delete(p, 'd') == 0
    catch
      return false
    endtry
  else
    try
      return delete(p) == 0
    catch
      return false
    endtry
  endif
enddef

# 移动（剪切）：先尝试 rename；失败则 Copy + Delete
def MovePath(src: string, dst: string): bool
  try
    call mkdir(fnamemodify(dst, ':h'), 'p')
  catch
    return false
  endtry
  try
    var rc = rename(src, dst)
    if rc == 0
      return true
    endif
  catch
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
  return ok
enddef

def WinValid(): bool
  var ok = (s_winid != 0 && win_id2win(s_winid) > 0)
  return ok
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
  var cmdExe = cmd ==# '' ? BFindBackend() : cmd
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
      out_mode: 'nl',
      out_cb: (ch, line) => {
        if line ==# ''
          return
        endif
        var ev: any
        try
          ev = json_decode(line)
        catch
          return
        endtry
        if type(ev) != v:t_dict || !has_key(ev, 'type')
          return
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
          var msg2 = get(ev, 'message', '')
          if id != 0 && has_key(s_bcbs, id)
            try
              s_bcbs[id].OnError(msg2)
            catch
            endtry
            call remove(s_bcbs, id)
          endif
        endif
      },
      err_mode: 'nl',
      err_cb: (ch, line) => {
        # 可选：stderr 日志
      },
      exit_cb: (ch, code) => {
        s_brunning = false
        s_bjob = v:null
        s_bbuf = ''
        s_bcbs = {}
      },
      stoponexit: 'term'
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
    var json = json_encode(req) .. "\n"
    ch_sendraw(s_bjob, json)
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
      var pid = s_pending[path]
      BCancel(pid)
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
  var req_id: number = 0

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
# 语法高亮（SimpleTree / SimpleTree Help）
# =============================================================

def SetupSyntaxTree(): void
  if !WinValid()
    return
  endif
  # 在树窗口内设置语法高亮
  # 说明：
  # - SimpleTreeIcon：行首图标（Nerd Font 或 ASCII）
  # - SimpleTreeDirSlash：目录行的末尾斜杠（当 g:simpletree_folder_suffix=1 时）
  # - SimpleTreeHidden：隐藏文件（以 . 开头）
  # - SimpleTreeLoading：加载提示行中的 "Loading..."
  try
    call win_execute(s_winid, 'silent! syntax clear SimpleTreeIcon SimpleTreeDirSlash SimpleTreeHidden SimpleTreeLoading')
    call win_execute(s_winid, 'syntax match SimpleTreeIcon ''^\s*\zs\S\+\ze\s''')
    call win_execute(s_winid, 'syntax match SimpleTreeDirSlash ''\/$''')
    call win_execute(s_winid, 'syntax match SimpleTreeHidden ''^\s*.\{-}\s\zs\.\S\+''')
    call win_execute(s_winid, 'syntax match SimpleTreeLoading ''Loading\.\.\.''')

    # 默认高亮链接（用户可自行覆盖）
    call win_execute(s_winid, 'highlight default link SimpleTreeIcon Special')
    call win_execute(s_winid, 'highlight default link SimpleTreeDirSlash Directory')
    call win_execute(s_winid, 'highlight default link SimpleTreeHidden Comment')
    call win_execute(s_winid, 'highlight default link SimpleTreeLoading WarningMsg')
  catch
  endtry
enddef

def SetupSyntaxHelp(): void
  if s_help_winid == 0 || win_id2win(s_help_winid) <= 0
    return
  endif
  # 仅对分屏帮助缓冲区设置（浮窗不做细粒度语法，以免依赖 popup_getbuf）
  try
    call win_execute(s_help_winid, 'silent! syntax clear SimpleTreeHelpTitle SimpleTreeHelpSep SimpleTreeHelpKey')
    call win_execute(s_help_winid, 'syntax match SimpleTreeHelpTitle ''^SimpleTree.*$''')
    call win_execute(s_help_winid, 'syntax match SimpleTreeHelpSep ''^-\{2,}$''')
    # 匹配行首的快捷键（以至少两个空格与说明分隔）
    call win_execute(s_help_winid, 'syntax match SimpleTreeHelpKey ''^\zs\S\+\ze\s\{2,}''')

    call win_execute(s_help_winid, 'highlight default link SimpleTreeHelpTitle Title')
    call win_execute(s_help_winid, 'highlight default link SimpleTreeHelpSep Comment')
    call win_execute(s_help_winid, 'highlight default link SimpleTreeHelpKey Identifier')
  catch
  endtry
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

  execute 'topleft vertical vsplit'
  s_winid = win_getid()

  call win_execute(s_winid, 'silent enew')
  s_bufnr = winbufnr(s_winid)

  call win_execute(s_winid, 'file SimpleTree')

  call win_execute(s_winid, 'vertical resize ' .. g:simpletree_width)

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
    'setlocal filetype=simpletree'
  ]
  for cmd in opts
    call win_execute(s_winid, cmd)
  endfor
  call SetupSyntaxTree()

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
  # 一键折叠（Collapse All）
  var ca_key = get(g:, 'simpletree_collapse_all_key', 'Z')
  call win_execute(s_winid, 'nnoremap <nowait> <silent> <buffer> ' .. ca_key .. ' :call treexplorer#OnCollapseAll()<CR>')
  # Help
  call win_execute(s_winid, 'nnoremap <silent> <buffer> ? :call treexplorer#ShowHelp()<CR>')

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

  var hasCache = has_key(s_cache, path)
  var isLoading = get(s_loading, path, v:false)

  if !hasCache
    if !isLoading
      ScanDirAsync(path)
    endif
    lines->add(repeat('  ', depth) .. s_icons.loading .. ' Loading...')
    idx->add({path: '', is_dir: false, name: '', depth: depth, loading: true})
    return
  endif

  var entries = s_cache[path]
  for e in entries
    var icon = ''
    if e.is_dir
      icon = GetNodeState(e.path).expanded ? s_icons.dir_open : s_icons.dir
    else
      icon = !!get(g:, 'simpletree_show_file_icons', 1) ? FileIcon(e.name) : s_icons.file
    endif
    var suffix = (e.is_dir && !!get(g:, 'simpletree_folder_suffix', 1)) ? '/' : ''
    var text = repeat('  ', depth) .. icon .. ' ' .. e.name .. suffix

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

  # 允许运行时切换 Nerd Font
  call SetupIcons()

  var lines: list<string> = []
  var idx: list<dict<any>> = []

  var stroot = GetNodeState(s_root)
  stroot.expanded = true

  BuildLines(s_root, 0, lines, idx)

  if len(lines) == 0 && get(s_loading, s_root, v:false)
    lines = [s_icons.loading .. ' Loading...']
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
# 根路径切换与锁定
# =============================================================
def SetRoot(new_root: string, lock: bool = false)
  var nr = CanonDir(new_root)
  if !IsDir(nr)
    echohl ErrorMsg
    echom '[SimpleTree] invalid root: ' .. nr
    echohl None
    return
  endif
  s_root = nr
  if lock
    s_root_locked = true
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

  for [p, id] in items(s_pending)
    try
      BCancel(id)
    catch
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
enddef

export def OnRootHere()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  var p = node.is_dir ? node.path : fnamemodify(node.path, ':h')
  SetRoot(p)
enddef

export def OnRootUp()
  if s_root_locked
    echo '[SimpleTree] root is locked. Press L to unlock.'
    return
  endif
  if s_root ==# ''
    return
  endif

  var cur = CanonDir(s_root)
  var up = ParentDir(cur)

  if RStripSlash(up) ==# RStripSlash(cur)
    return
  endif

  SetRoot(up)
enddef

export def OnRootPrompt()
  var start = s_root !=# '' ? s_root : getcwd()
  var inp = input('SimpleTree new root: ', start, 'dir')
  if inp ==# ''
    return
  endif
  SetRoot(inp)
enddef

export def OnRootCwd()
  SetRoot(getcwd())
enddef

export def OnRootCurrent()
  if s_root_locked
    echo '[SimpleTree] root is locked. Press L to unlock.'
    return
  endif

  var ap = ''
  var other = OtherWindowId()
  if other != 0
    var wi = getwininfo(other)
    if len(wi) > 0
      var obuf = wi[0].bufnr
      var oname = bufname(obuf)
      var cand = fnamemodify(oname, ':p')
      if cand !=# '' && filereadable(cand)
        ap = cand
      endif
    endif
  endif

  if ap ==# ''
    var cur = expand('%:p')
    if cur !=# '' && filereadable(cur)
      ap = fnamemodify(cur, ':p')
    endif
  endif

  var p = (ap ==# '') ? getcwd() : fnamemodify(ap, ':h')
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
    endif
  endif
enddef

# =============================================================
# 用户交互（导出）
# =============================================================
def CursorNode(): dict<any>
  var lnum = line('.')
  if lnum <= 0 || lnum > len(s_line_index)
    return {}
  endif
  var node = s_line_index[lnum - 1]
  return node
enddef

# 不再在找不到目标时跳到顶部，保持当前位置
def FocusPath(path: string): void
  if !WinValid()
    return
  endif
  if path ==# ''
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
    catch
    endtry
  endif
enddef

def FocusFirstChild(dir_path: string): void
  if !WinValid()
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
    return
  endif
  var next_idx = idx_dir + 1
  if next_idx < len(s_line_index)
    var next = s_line_index[next_idx]
    if get(next, 'depth', -1) == dir_depth + 1
      try
        call win_execute(s_winid, 'normal! ' .. (next_idx + 1) .. 'G')
      catch
      endtry
    endif
  endif
enddef

# 折叠最近的已展开祖先
def CollapseNearestExpandedAncestor(path: string): void
  var p = fnamemodify(path, ':h')
  while p !=# ''
    if p ==# s_root
      return
    endif
    if GetNodeState(p).expanded
      ToggleDir(p)
      FocusPath(p)
      return
    endif
    var nextp = fnamemodify(p, ':h')
    if nextp ==# p
      break
    endif
    p = nextp
  endwhile
  var parent = fnamemodify(path, ':h')
  if parent !=# '' && parent !=# s_root
    FocusPath(parent)
  endif
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

# l：目录上展开并定位第一个子项；文件上打开文件
export def OnExpand()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  if node.is_dir
    if !GetNodeState(node.path).expanded
      ToggleDir(node.path)
    endif
    FocusFirstChild(node.path)
  else
    OpenFile(node.path)
  endif
enddef

# h：目录已展开时折叠当前；目录已折叠或文件时折叠最近的已展开父目录
export def OnCollapse()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    return
  endif
  if node.is_dir
    if GetNodeState(node.path).expanded
      ToggleDir(node.path)
    else
      var parent = fnamemodify(node.path, ':h')
      if parent ==# s_root
        return
      endif
      CollapseNearestExpandedAncestor(node.path)
    endif
  else
    CollapseNearestExpandedAncestor(node.path)
  endif
enddef

# 新增：一键折叠根下所有目录
export def OnCollapseAll()
  if s_root ==# ''
    echo '[SimpleTree] root not set'
    return
  endif
  var count = 0
  # 关闭所有已展开（不含 root）
  for [p, st] in items(s_state)
    if p !=# s_root && get(st, 'expanded', v:false)
      s_state[p].expanded = false
      count += 1
    endif
  endfor
  # 取消所有非 root 的挂起请求与加载标记（避免无谓的后台任务）
  for [p, id] in items(s_pending)
    if p !=# s_root
      try
        BCancel(id)
      catch
      endtry
    endif
  endfor
  for p in keys(s_pending)
    if p !=# s_root
      try
        call remove(s_pending, p)
      catch
      endtry
    endif
  endfor
  for p in keys(s_loading)
    if p !=# s_root
      try
        call remove(s_loading, p)
      catch
      endtry
    endif
  endfor

  Render()
  echo '[SimpleTree] collapsed all under root (' .. count .. ' dirs)'
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

# ===== 文件操作：复制/剪切/粘贴/新建/重命名/删除 =====
export def OnCopy()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    echo '[SimpleTree] nothing to copy'
    return
  endif
  s_clipboard = {mode: 'copy', items: [node.path]}
  echo '[SimpleTree] copy: ' .. node.path
enddef

export def OnCut()
  var node = CursorNode()
  if empty(node) || get(node, 'loading', v:false)
    echo '[SimpleTree] nothing to cut'
    return
  endif
  s_clipboard = {mode: 'cut', items: [node.path]}
  echo '[SimpleTree] cut: ' .. node.path
enddef

export def OnPaste()
  if type(s_clipboard) != v:t_dict || get(s_clipboard, 'mode', '') ==# '' || len(get(s_clipboard, 'items', [])) == 0
    echo '[SimpleTree] clipboard empty'
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
    return
  endif
  if name =~ '[\/]'
    echohl ErrorMsg | echom '[SimpleTree] name cannot contain path separator' | echohl None
    return
  endif
  var dst = AskUniqueName(destDir, name)
  if dst ==# ''
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
    return
  endif
  if name =~ '[\/]'
    echohl ErrorMsg | echom '[SimpleTree] name cannot contain path separator' | echohl None
    return
  endif
  var dst = AskUniqueName(destDir, name)
  if dst ==# ''
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
    return
  endif
  if newname =~ '[\/]'
    echohl ErrorMsg | echom '[SimpleTree] name cannot contain path separator' | echohl None
    return
  endif
  var dst = PathJoin(parent, newname)
  if dst ==# src
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
  var ca_key = get(g:, 'simpletree_collapse_all_key', 'Z')
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
    ca_key .. '     一键折叠根下所有目录',
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
  if s_help_popupid != 0 && exists('*popup_close')
    try
      call popup_close(s_help_popupid)
    catch
    endtry
    s_help_popupid = 0
    s_help_bufnr = -1
    return
  endif

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
  if s_help_popupid != 0 && exists('*popup_close')
    CloseHelp()
    return
  endif

  var lines = BuildHelpLines()

  if exists('*popup_create')
    var width = 0
    for l in lines
      width = max([width, strdisplaywidth(l)])
    endfor
    var height = min([max([10, len(lines) + 2]), 30])
    width += 6

    var popid = popup_create(lines, {
      title: NFEnabled() ? '󰙎 SimpleTree Help' : 'SimpleTree Help',
      pos: 'center',
      minwidth: width,
      minheight: height,
      padding: [0, 2, 0, 2],
      border: [1, 1, 1, 1],
      borderchars: ['─', '│', '─', '│', '┌', '┐', '┘', '└'],
      zindex: 200,
      mapping: 0,
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
    s_help_bufnr = -1

    if exists('*popup_setoptions')
      try
        call popup_setoptions(popid, {
          highlight: 'Normal',
          borderhighlight: ['FloatBorder']
        })
      catch
      endtry
    endif

    if WinValid()
      call win_gotoid(s_winid)
    endif
    return
  endif

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
  call SetupSyntaxHelp()

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
  if path ==# '' || s_root ==# ''
    return
  endif

  var ap = AbsPath(path)
  s_reveal_target = ap

  var base = fnamemodify(ap, ':t')
  if filereadable(ap) && base =~ '^\.'
    if s_hide_dotfiles
      s_hide_dotfiles = false
      g:simpletree_hide_dotfiles = 0
      echo '[SimpleTree] dotfiles hidden => OFF (auto). Showing hidden to reveal target.'
      Refresh()
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
  if WinValid()
    Close()
    return
  endif

  var curf0 = expand('%:p')
  var curf_abs = ''
  if curf0 !=# '' && filereadable(curf0)
    curf_abs = fnamemodify(curf0, ':p')
  endif

  var rootArg = root
  if rootArg ==# ''
    if s_root_locked && s_root !=# '' && IsDir(s_root)
      rootArg = s_root
    else
      if curf_abs ==# ''
        rootArg = getcwd()
      else
        rootArg = fnamemodify(curf_abs, ':h')
      endif
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

  if curf_abs !=# '' && filereadable(curf_abs)
    RevealPath(curf_abs)
  endif
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
