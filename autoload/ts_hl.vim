vim9script

# =============== 状态 ===============
var s_job: any = v:null
var s_running: bool = false
var s_req_timer: number = 0
var s_enabled: bool = false
var s_active_bufs: dict<bool> = {}
# =============== 侧边栏状态 ===============
var s_outline_win: number = 0
var s_outline_buf: number = 0
var s_outline_src_buf: number = 0
var s_outline_items: list<dict<any>> = []
var s_outline_linemap: list<number> = []  # 每一可见行对应 s_outline_items 的下标，-1 表示不可跳转
var s_sym_timer: number = 0

# 待用的 TS 高亮组 -> Vim 高亮组 默认链接
const s_groups = [
  'TSComment', 'TSString', 'TStringRegex', 'TStringEscape', 'TStringSpecial',
  'TSNumber', 'TSBoolean', 'TSConstant', 'TSConstBuiltin',
  'TSKeyword', 'TSKeywordOperator', 'TSOperator',
  'TSPunctDelimiter', 'TSPunctBracket',
  'TSFunction', 'TSFunctionBuiltin', 'TSMethod',
  'TSType', 'TSTypeBuiltin', 'TSNamespace',
  'TSVariable', 'TSVariableParameter', 'TSVariableBuiltin',
  'TSProperty', 'TSField',
  'TSMacro', 'TSAttribute'
  ]

# =============== 工具 ===============
def Log(msg: string)
  if get(g:, 'ts_hl_debug', 0)
    var lf = get(g:, 'ts_hl_log_file', '')
    if type(lf) == v:t_string && lf !=# ''
      try
        call writefile(['[ts-hl] ' .. msg], lf, 'a')
      catch
      endtry
    else
      echom '[ts-hl] ' .. msg
    endif
  endif
enddef

def DetectLang(buf: number): string
  var ft = getbufvar(buf, '&filetype')
  if ft ==# 'rust'
    return 'rust'
  elseif ft ==# 'javascript' || ft ==# 'javascriptreact' || ft ==# 'jsx'
    return 'javascript'
  elseif ft ==# 'c'
    return 'c'
  elseif ft ==# 'cpp' || ft ==# 'cc'
    return 'cpp'
  elseif ft ==# 'vim' || ft ==# 'vimrc'
    return 'vim'
  else
    return ''
  endif
enddef

def IsSupportedLang(buf: number): bool
  var ft = getbufvar(buf, '&filetype')
  var supported = [
    'rust', 'javascript', 'javascriptreact', 'jsx', 'c', 'cpp', 'cc',
    'vim', 'vimrc'
    ]
  return index(supported, ft) >= 0
enddef

def EnsureHlGroupsAndProps()
  # 先给这些组一个合理的默认链接/颜色（用户可覆盖）
  highlight default link TSComment Comment
  highlight default link TSString String
  highlight default link TStringRegex String
  highlight default link TStringEscape SpecialChar
  highlight default link TStringSpecial Special
  highlight default link TSNumber Number
  highlight default link TSBoolean Boolean
  highlight default link TSConstant Constant
  highlight default link TSConstBuiltin Constant

  highlight default link TSKeyword Keyword
  highlight default link TSKeywordOperator Keyword
  highlight default link TSOperator Operator
  highlight default link TSPunctDelimiter Delimiter
  highlight default link TSPunctBracket Delimiter

  highlight default link TSFunction Function
  highlight default link TSFunctionBuiltin Function
  highlight default link TSMethod Function

  highlight default link TSType Type
  highlight default link TSTypeBuiltin Type
  highlight default link TSNamespace Identifier

  # 为了避免"变量全白"，给变量/参数/属性/字段更分明的默认色
  if !hlexists('TSVariable')
    highlight default TSVariable ctermfg=109 guifg=#56b6c2
  else
    highlight default link TSVariable Identifier
  endif
  if !hlexists('TSVariableParameter')
    highlight default TSVariableParameter ctermfg=180 guifg=#d19a66
  else
    highlight default link TSVariableParameter Identifier
  endif
  if !hlexists('TSProperty')
    highlight default TSProperty ctermfg=139 guifg=#c678dd
  else
    highlight default link TSProperty Identifier
  endif
  if !hlexists('TSField')
    highlight default TSField ctermfg=139 guifg=#c678dd
  else
    highlight default link TSField Identifier
  endif
  highlight default link TSVariableBuiltin Constant

  highlight default link TSMacro Macro
  highlight default link TSAttribute PreProc

  # Outline 专用组
  if !hlexists('TsHlOutlineGuide')
    highlight default link TsHlOutlineGuide Comment

    if !hlexists('TsHlOutlinePos')
      highlight default link TsHlOutlinePos LineNr
    endif

    # 为每个组注册 textprop 类型（已存在则忽略异常）
    for g in s_groups
      try
        call prop_type_add(g, {highlight: g, combine: v:true, priority: 11})
      catch
      endtry
    endfor
    # Outline 的 textprop 类型
    try
      call prop_type_add('TsHlOutlineGuide', {highlight: 'TsHlOutlineGuide', combine: v:true, priority: 12})
    catch
    endtry
    try
      call prop_type_add('TsHlOutlinePos', {highlight: 'TsHlOutlinePos', combine: v:true, priority: 12})
    catch
    endtry
  endif
enddef

def FindDaemon(): string
  var p = get(g:, 'ts_hl_daemon_path', '')
  if type(p) == v:t_string && p !=# '' && executable(p)
    return p
  endif
  for dir in split(&runtimepath, ',')
    var exe = dir .. '/lib/ts-hl-daemon'
    if executable(exe)
      return exe
    endif
    # Windows 可执行后缀
    var exe2 = dir .. '/lib/ts-hl-daemon.exe'
    if executable(exe2)
      return exe2
    endif
  endfor
  return ''
enddef

def ApplyHighlights(buf: number, spans: list<dict<any>>)
  if !bufexists(buf)
    return
  endif
  var lnum_end = len(getbufline(buf, 1, '$'))
  try
    call prop_clear(1, lnum_end, {bufnr: buf})
  catch
  endtry

  for s in spans
    var l1 = get(s, 'lnum', 1)
    var c1 = max([1, get(s, 'col', 1)])
    var l2 = get(s, 'end_lnum', l1)
    var c2 = max([1, get(s, 'end_col', c1)])
    var tp = get(s, 'group', 'TSVariable')
    if l1 <= 0 || l2 <= 0
      continue
    endif
    try
      call prop_add(l1, c1, {type: tp, bufnr: buf, end_lnum: l2, end_col: c2})
    catch
    endtry
  endfor
enddef

def OnDaemonEvent(line: string)
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
  if ev.type ==# 'highlights'
    var buf = get(ev, 'buf', 0)
    var spans = get(ev, 'spans', [])
    ApplyHighlights(buf, spans)
  elseif ev.type ==# 'symbols'
    var buf = get(ev, 'buf', 0)
    var syms = get(ev, 'symbols', [])
    ApplySymbols(buf, syms)
  elseif ev.type ==# 'ast'
    var buf = get(ev, 'buf', 0)
    var lines = get(ev, 'lines', [])
    ShowAst(buf, lines)
  elseif ev.type ==# 'error'
    echom '[ts-hl] error: ' .. get(ev, 'message', '')
  endif
enddef

def EnsureDaemon(): bool
  if s_running
    return true
  endif
  var exe = FindDaemon()
  if exe ==# ''
    echohl ErrorMsg
    echom '[ts-hl] daemon not found, set g:ts_hl_daemon_path or place ts-hl-daemon in runtimepath/lib'
    echohl None
    return false
  endif
  try
    s_job = job_start([exe], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, l) => OnDaemonEvent(l),
      err_mode: 'nl',
      err_cb: (ch, l) => Log('daemon stderr: ' .. l),
      exit_cb: (ch, code) => {
        s_running = false
        s_job = v:null
        Log('Daemon exited with code ' .. code)
      },
      stoponexit: 'term'
    })
  catch
    s_job = v:null
    s_running = false
    echohl ErrorMsg
    echom '[ts-hl] failed to start daemon: ' .. v:exception
    echohl None
    return false
  endtry
  s_running = (s_job != v:null)
  if s_running
    EnsureHlGroupsAndProps()
    Log('Daemon started successfully')
  endif
  return s_running
enddef

def Send(req: dict<any>)
  if !s_running
    return
  endif
  try
    var j = json_encode(req) .. "\n"
    ch_sendraw(s_job, j)
  catch
    Log('Failed to send request: ' .. v:exception)
  endtry
enddef

def ScheduleRequest(buf: number)
  if !s_enabled
    return
  endif
  if !IsSupportedLang(buf)
    return
  endif

  if s_req_timer != 0 && exists('*timer_stop')
    try
      call timer_stop(s_req_timer)
    catch
    endtry
    s_req_timer = 0
  endif

  if exists('*timer_start')
    try
      var ms = get(g:, 'ts_hl_debounce', 120)
      s_req_timer = timer_start(ms, (id) => {
        s_req_timer = 0
        RequestNow(buf)
      })
    catch
      RequestNow(buf)
    endtry
  else
    RequestNow(buf)
  endif
enddef

def AutoEnableForBuffer(buf: number)
  if !bufexists(buf)
    return
  endif

  # 检查全局开关
  var auto_enable_ft = get(g:, 'ts_hl_auto_enable_filetypes', [])
  if type(auto_enable_ft) != v:t_list || len(auto_enable_ft) == 0
    return
  endif

  var ft = getbufvar(buf, '&filetype')
  if index(auto_enable_ft, ft) < 0
    return
  endif

  # 如果该缓冲区已标记启用，跳过
  if has_key(s_active_bufs, buf) && s_active_bufs[buf]
    return
  endif

  # 自动启用并标记
  if !s_enabled
    Log('Auto-enabling for filetype: ' .. ft)
    Enable()
  endif
  s_active_bufs[buf] = true

  # 立即请求高亮
  RequestNow(buf)
enddef

def CheckAndStopDaemon()
  var has_active = false
  for [bufnr, active] in items(s_active_bufs)
    if active && bufexists(str2nr(bufnr))
      has_active = true
      break
    endif
  endfor

  if !has_active && s_enabled && get(g:, 'ts_hl_auto_stop', 1)
    Log('No active buffers, stopping daemon')
    Disable()
    s_active_bufs = {}
  endif
enddef

# =============== 导出 API ===============
export def Enable()
  if s_enabled
    return
  endif
  if !EnsureDaemon()
    return
  endif
  s_enabled = true

  augroup TsHl
    autocmd!
    autocmd BufEnter,BufWinEnter * call ts_hl#OnBufEvent(bufnr())
    autocmd FileType * call ts_hl#OnBufEvent(bufnr())
    autocmd TextChanged,TextChangedI * call ts_hl#OnBufEvent(bufnr())
    autocmd BufWinLeave,BufDelete * call ts_hl#OnBufClose(str2nr(expand('<abuf>')))
  augroup END

  # 对当前缓冲立即请求一次
  call ts_hl#OnBufEvent(bufnr())
enddef

export def Disable()
  if !s_enabled
    return
  endif
  s_enabled = false
  augroup TsHl
    autocmd!
  augroup END

  # 停止 daemon
  if s_running && s_job != v:null
    try
      call job_stop(s_job, 'term')
      s_running = false
      s_job = v:null
      Log('Daemon stopped')
    catch
    endtry
  endif

  echo '[ts-hl] disabled'
enddef

export def Toggle()
  if s_enabled
    Disable()
  else
    Enable()
  endif
enddef

export def OnBufEvent(buf: number)
  AutoEnableForBuffer(buf)
  ScheduleRequest(buf)
  # 如果侧边栏打开，调度符号刷新
  ScheduleSymbols(buf)
enddef

export def OnBufClose(buf: number)
  if has_key(s_active_bufs, buf)
    s_active_bufs[buf] = false
  endif
  # 延迟检查，避免频繁启停
  if exists('*timer_start')
    timer_start(2000, (id) => CheckAndStopDaemon())
  endif
enddef

def KindIcon(kind: string): string
  if kind ==# 'function'
    return 'ƒ'
  elseif kind ==# 'method'
    return 'm'
  elseif kind ==# 'type' || kind ==# 'struct' || kind ==# 'class'
    return 'T'
  elseif kind ==# 'enum'
    return 'E'
  elseif kind ==# 'namespace'
    return 'N'
  elseif kind ==# 'variable'
    return 'v'
  elseif kind ==# 'const'
    return 'C'
  elseif kind ==# 'macro'
    return 'M'
  elseif kind ==# 'property' || kind ==# 'field'
    return 'p'
  else
    return '?'
  endif
enddef

# =============== Outline UI/Tree 工具 ===============
# 将 symbol.kind 映射到 TS* 高亮组，用于名称与图标着色
def KindToTSGroup(kind: string): string
  if kind ==# 'function'
    return 'TSFunction'
  elseif kind ==# 'method'
    return 'TSMethod'
  elseif kind ==# 'type' || kind ==# 'class' || kind ==# 'struct' || kind ==# 'enum'
    return 'TSType'
  elseif kind ==# 'namespace'
    return 'TSNamespace'
  elseif kind ==# 'variable'
    return 'TSVariable'
  elseif kind ==# 'const'
    return 'TSConstBuiltin'
  elseif kind ==# 'macro'
    return 'TSMacro'
  elseif kind ==# 'property'
    return 'TSProperty'
  elseif kind ==# 'field'
    return 'TSField'
  else
    return 'TSVariable'
  endif
enddef

# 可配置 fancy 图标（默认启用），ASCII fallback
def FancyIcon(kind: string): string
  var fancy = get(g:, 'ts_hl_outline_fancy', 1)
  if fancy
    if kind ==# 'function'     | return '󰡱' | endif
    if kind ==# 'method'       | return '󰆧' | endif
    if kind ==# 'type'         | return '' | endif
    if kind ==# 'class'        | return '' | endif
    if kind ==# 'struct'       | return '' | endif
    if kind ==# 'enum'         | return '' | endif
    if kind ==# 'namespace'    | return '' | endif
    if kind ==# 'variable'     | return '' | endif
    if kind ==# 'const'        | return '' | endif
    if kind ==# 'macro'        | return '' | endif
    if kind ==# 'property'     | return '' | endif
    if kind ==# 'field'        | return '' | endif
  endif
  # ASCII fallback
  if kind ==# 'function'     | return 'ƒ' | endif
  if kind ==# 'method'       | return 'm' | endif
  if kind ==# 'type'         | return 'T' | endif
  if kind ==# 'class'        | return 'T' | endif
  if kind ==# 'struct'       | return 'T' | endif
  if kind ==# 'enum'         | return 'E' | endif
  if kind ==# 'namespace'    | return 'N' | endif
  if kind ==# 'variable'     | return 'v' | endif
  if kind ==# 'const'        | return 'C' | endif
  if kind ==# 'macro'        | return 'M' | endif
  if kind ==# 'property'     | return 'p' | endif
  if kind ==# 'field'        | return 'p' | endif
  return '?'
enddef

# 基于列缩进 + 顺序 的简易树构建
# 节点结构: {name, kind, lnum, col, idx, children: []}
def BuildTreeByIndent(syms: list<dict<any>>): list<dict<any>>
  var containers = ['namespace', 'class', 'struct', 'enum', 'type']
  var roots: list<dict<any>> = []
  var stack: list<dict<any>> = []

  for i in range(len(syms))
    var s = syms[i]
    var node = {
      name: get(s, 'name', ''),
      kind: get(s, 'kind', 'variable'),
      lnum: get(s, 'lnum', 1),
      col:  get(s, 'col', 1),
      idx:  i,
      children: []
    }

    # 根据列缩进弹栈：新符号列 <= 栈顶列，则回到更上层
    while len(stack) > 0 && node.col <= stack[-1].col
      stack->remove(-1)
    endwhile

    if len(stack) == 0
      roots->add(node)
    else
      stack[-1].children->add(node)
    endif

    if index(containers, node.kind) >= 0
      stack->add(node)
    endif
  endfor
  return roots
enddef

# 生成树前缀（│├└─）
def BuildTreePrefix(ancestor_last: list<bool>, is_last: bool): string
  var use_ascii = get(g:, 'ts_hl_outline_ascii', 0)
  var s_vert = use_ascii ? '|' : '│'
  var s_tee  = use_ascii ? '+-' : '├─'
  var s_end  = use_ascii ? '`-' : '└─'
  var s_pad  = ' '
  var s_bar  = s_vert .. s_pad

  var pref = ''
  for i in range(len(ancestor_last))
    pref ..= (ancestor_last[i] ? '  ' : s_bar)
  endfor
  pref ..= (is_last ? s_end : s_tee) .. ' '
  return pref
enddef

# 渲染树为行，并计算每段的“字节列”区间（1-based）
# 返回: {lines, linemap, meta}
# meta[i] = {prefix_len, icon_col, icon_w, name_start, name_end, pos_start, pos_end, kind}
def RenderTree(nodes: list<dict<any>>, show_pos: bool): dict<any>
  var lines: list<string> = []
  var linemap: list<number> = []
  var meta: list<dict<any>> = []

  def Walk(ns: list<dict<any>>, ancestors: list<bool>)
    for i in range(len(ns))
      var n = ns[i]
      var last = (i == len(ns) - 1)
      var prefix = BuildTreePrefix(ancestors, last)
      var icon = FancyIcon(n.kind)
      var name = n.name
      var pos_str = show_pos ? (' (' .. n.lnum .. ':' .. n.col .. ')') : ''

      var line = prefix .. icon .. ' ' .. name .. pos_str

      # 使用 strlen 计算“字节”长度，textprop 需要字节列
      var pref_bytes = strlen(prefix)
      var icon_bytes = strlen(icon)
      var name_bytes = strlen(name)
      var pos_bytes  = strlen(pos_str)

      var icon_col   = pref_bytes + 1
      var name_start = pref_bytes + icon_bytes + 2           # icon + space
      var name_end   = name_start + name_bytes
      var pos_start  = pos_bytes == 0 ? 0 : name_end         # pos_str 自带开头空格
      var pos_end    = pos_bytes == 0 ? 0 : (pos_start + pos_bytes)

      lines->add(line)
      linemap->add(n.idx)
      meta->add({
      prefix_len: pref_bytes,
      icon_col: icon_col,
      icon_w: icon_bytes,
      name_start: name_start,
      name_end: name_end,
      pos_start: pos_start,
      pos_end: pos_end,
      kind: n.kind
      })

      if len(n.children) > 0
        Walk(n.children, ancestors + [last])
      endif
    endfor
  enddef

  Walk(nodes, [])
  return {lines: lines, linemap: linemap, meta: meta}
enddef

# =============== 符号请求 ===============
def RequestSymbolsNow(buf: number)
  if !EnsureDaemon()
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# ''
    return
  endif
  if !bufexists(buf)
    return
  endif
  var lines = getbufline(buf, 1, '$')
  var text = join(lines, "\n")
  Send({type: 'symbols', buf: buf, lang: lang, text: text})
  Log('Requested symbols for buffer ' .. buf .. ' (' .. lang .. ')')
enddef

def ScheduleSymbols(buf: number)
  # 仅在侧边栏开启且当前 buf 是侧边栏的源 buf 时才调度
  if s_outline_win == 0 || s_outline_src_buf != buf
    return
  endif

  if s_sym_timer != 0 && exists('*timer_stop')
    try
      call timer_stop(s_sym_timer)
    catch
    endtry
    s_sym_timer = 0
  endif

  if exists('*timer_start')
    try
      var ms = get(g:, 'ts_hl_debounce', 120)
      s_sym_timer = timer_start(ms, (id) => {
        s_sym_timer = 0
        RequestSymbolsNow(buf)
      })
    catch
      RequestSymbolsNow(buf)
    endtry
  else
    RequestSymbolsNow(buf)
  endif
enddef

def ShowAst(src_buf: number, lines: list<string>)
  var curwin = win_getid()
  try
    execute 'botright vsplit'
    execute 'enew'
    execute 'file ts-hl-ast'
    setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
    setlocal nowrap nonumber norelativenumber signcolumn=no
    call setline(1, lines)
  finally
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry
enddef

export def DumpAST()
  var buf = bufnr()
  if !bufexists(buf)
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# ''
    echo '[ts-hl] unsupported filetype for AST'
    return
  endif
  var text = join(getbufline(buf, 1, '$'), "\n")
  Send({type: 'dump_ast', buf: buf, lang: lang, text: text})
enddef

# =============== 渲染符号侧边栏（树形 + 高亮） ===============
def ApplySymbols(buf: number, syms: list<dict<any>>)
  if s_outline_win == 0 || s_outline_buf == 0 || s_outline_src_buf != buf
    return
  endif
  if !bufexists(s_outline_buf)
    return
  endif

  # 缓存原始符号（用于跳转）
  s_outline_items = syms

  # 1) 构建树
  var nodes = BuildTreeByIndent(syms)

  # 2) 渲染
  var show_pos = get(g:, 'ts_hl_outline_show_position', 1) ? true : false
  var out = RenderTree(nodes, show_pos)
  var lines = out.lines
  s_outline_linemap = out.linemap

  var curwin = win_getid()
  try
    if win_gotoid(s_outline_win)
      setlocal modifiable
      if len(lines) == 0
        lines = ['<no symbols>']
        s_outline_linemap = [-1]
      endif
      # 覆盖内容
      call setline(1, lines)
      var last = len(lines)
      if last > 0
        call setline(last + 1, [])
      endif

      # 3) 应用 textprop 高亮（树导线、图标/名称、位置列）
      try
        call prop_clear(1, last, {bufnr: s_outline_buf})
      catch
      endtry

      for i in range(len(lines))
        var lnum = i + 1
        if len(out.meta) <= i
          continue
        endif
        var m = out.meta[i]

        # 树导线
        if m.prefix_len > 0
          try
            call prop_add(lnum, 1, {type: 'TsHlOutlineGuide', bufnr: s_outline_buf, end_lnum: lnum, end_col: m.prefix_len + 1})
          catch
          endtry
        endif

        # 图标与名称使用 TS 组
        var grp = KindToTSGroup(m.kind)

        # 图标（多字节按字节宽度）
        try
          call prop_add(lnum, m.icon_col, {type: grp, bufnr: s_outline_buf, end_lnum: lnum, end_col: m.icon_col + m.icon_w})
        catch
        endtry

        # 名称
        if m.name_end > m.name_start
          try
            call prop_add(lnum, m.name_start, {type: grp, bufnr: s_outline_buf, end_lnum: lnum, end_col: m.name_end})
          catch
          endtry
        endif

        # 位置列
        if m.pos_start > 0 && m.pos_end > m.pos_start
          try
            call prop_add(lnum, m.pos_start, {type: 'TsHlOutlinePos', bufnr: s_outline_buf, end_lnum: lnum, end_col: m.pos_end})
          catch
          endtry
        endif
      endfor

      setlocal nomodifiable
    endif
  finally
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry
enddef

# =============== 侧边栏窗口管理 ===============
export def OutlineOpen()
  # 侧边栏展示当前窗口的 buffer 符号
  var src = bufnr()
  if !IsSupportedLang(src)
    echo '[ts-hl] outline unsupported for this &filetype'
    return
  endif
  if !EnsureDaemon()
    return
  endif

  var curwin = win_getid()
  try
    # 打开右侧窗口
    execute 'botright vsplit'

    # 如果已有 buffer，则跳过去，否则新建
    if s_outline_buf != 0 && bufexists(s_outline_buf)
      execute 'buffer ' .. s_outline_buf
    else
      execute 'enew'
      s_outline_buf = bufnr('%')
      # 命名便于识别
      execute 'file ts-hl-outline'
      # 设置成 scratch buffer
      setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
      setlocal nowrap nonumber norelativenumber signcolumn=no
      setlocal foldcolumn=0
      setlocal cursorline
      setlocal filetype=ts_hl_outline
      setlocal nobuflisted
      setlocal conceallevel=0 concealcursor=
      # 侧边栏快捷键
      nnoremap <silent><buffer> <CR> :call ts_hl#OutlineJump()<CR>
      nnoremap <silent><buffer> q :call ts_hl#OutlineClose()<CR>
    endif

    s_outline_win = win_getid()
    s_outline_src_buf = src

    # 调整侧边栏宽度
    var width = get(g:, 'ts_hl_outline_width', 32)
    execute 'vertical resize ' .. width

    # 初次刷新
    OutlineRefresh()
  finally
    # 回到原窗口
    if curwin != 0
      call win_gotoid(curwin)
    endif
  endtry
enddef

export def OutlineClose()
  if s_outline_win != 0
    try
      if win_gotoid(s_outline_win)
        execute 'close'
      endif
    catch
    endtry
  endif
  s_outline_win = 0
  s_outline_buf = 0
  s_outline_items = []
  s_outline_linemap = []
  s_outline_src_buf = 0
  echo '[ts-hl] outline closed'
enddef

export def OutlineToggle()
  if s_outline_win != 0
    OutlineClose()
  else
    OutlineOpen()
  endif
enddef

export def OutlineRefresh()
  if s_outline_src_buf == 0 || !bufexists(s_outline_src_buf)
    return
  endif
  RequestSymbolsNow(s_outline_src_buf)
enddef

export def OutlineJump()
  if s_outline_win == 0 || s_outline_src_buf == 0
    return
  endif
  var idx_line = line('.') - 1
  if idx_line < 0 || idx_line >= len(s_outline_linemap)
    return
  endif
  var sym_idx = s_outline_linemap[idx_line]
  if sym_idx < 0 || sym_idx >= len(s_outline_items)
    return
  endif
  var it = s_outline_items[sym_idx]
  var lnum = get(it, 'lnum', 1)
  var col  = get(it, 'col', 1)

  # 找到源 buffer 的窗口
  var wins = win_findbuf(s_outline_src_buf)
  if len(wins) > 0
    call win_gotoid(wins[0])
  else
    execute 'buffer ' .. s_outline_src_buf
  endif
  call cursor(lnum, col)
  normal! zv
enddef

# =============== 修改：请求调度 ===============
def RequestNow(buf: number)
  if !EnsureDaemon()
    return
  endif
  var lang = DetectLang(buf)
  if lang ==# ''
    return
  endif
  if !bufexists(buf)
    return
  endif
  var lines = getbufline(buf, 1, '$')
  var text = join(lines, "\n")
  Send({type: 'highlight', buf: buf, lang: lang, text: text})
  Log('Requested highlight for buffer ' .. buf .. ' (' .. lang .. ')')

  # 如果侧边栏打开且当前 buf 是源 buf，则同时请求 symbols
  if s_outline_win != 0 && s_outline_src_buf == buf
    Send({type: 'symbols', buf: buf, lang: lang, text: text})
    Log('Requested symbols (inline) for buffer ' .. buf .. ' (' .. lang .. ')')
  endif
enddef
