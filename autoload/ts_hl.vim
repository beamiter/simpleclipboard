vim9script

# =============== 状态 ===============
var s_job: any = v:null
var s_running: bool = false
var s_enabled: bool = false
var s_active_bufs: dict<bool> = {}
# 每个缓冲的请求定时器
var s_req_timers: dict<number> = {}
# 缓冲文本同步定时器（set_text）
var s_sync_timers: dict<number> = {}
# 正在同步（等待 daemon ok）
var s_inflight_sync: dict<bool> = {}
# 已发送的 changedtick（避免重复 set_text）
var s_sent_changedtick: dict<number> = {}
# 上次应用的可见范围缓存 {bufnr: [start_lnum, end_lnum]}
var s_last_ranges: dict<list<number>> = {}
# =============== 侧边栏状态 ===============
var s_outline_win: number = 0
var s_outline_buf: number = 0
var s_outline_src_buf: number = 0
var s_outline_items: list<dict<any>> = []
var s_outline_linemap: list<number> = []  # 每一可见行对应 s_outline_items 的下标，-1 表示不可跳转
var s_sym_timer: number = 0
var s_inflight_syms: dict<bool> = {}
var s_inflight_hl: dict<bool> = {}

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
  'TSMacro', 'TSAttribute',
  'TSVariant'
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
  highlight default link TSVariant Constant

  highlight default link TsHlOutlineGuide Comment
  highlight default link TsHlOutlinePos LineNr

  for g in s_groups
    try
      call prop_type_add(g, {highlight: g, combine: v:true, priority: 11})
    catch
    endtry
  endfor
  try
    call prop_type_add('TsHlOutlineGuide', {highlight: 'TsHlOutlineGuide', combine: v:true, priority: 12})
  catch
  endtry
  try
    call prop_type_add('TsHlOutlinePos', {highlight: 'TsHlOutlinePos', combine: v:true, priority: 12})
  catch
  endtry
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
    var exe2 = dir .. '/lib/ts-hl-daemon.exe'
    if executable(exe2)
      return exe2
    endif
  endfor
  return ''
enddef

def BufLineCount(buf: number): number
  var info = getbufinfo(buf)
  if type(info) == v:t_list && len(info) > 0 && has_key(info[0], 'linecount')
    return info[0].linecount
  endif
  return len(getbufline(buf, 1, '$'))
enddef

def VisibleViewportRangeForBuf(buf: number): list<number>
  var lnum_end = BufLineCount(buf)
  var wins = win_findbuf(buf)
  if len(wins) == 0
    return [1, lnum_end]
  endif
  var start = lnum_end
  var stop  = 1
  for w in wins
    var info = getwininfo(w)[0]
    start = min([start, info.topline])
    stop  = max([stop, info.botline])
  endfor
  return [start, stop]
enddef

def VisibleRangeForBufWithMargin(buf: number, margin: number): list<number>
  var lnum_end = BufLineCount(buf)
  var wins = win_findbuf(buf)
  if len(wins) == 0
    return [1, lnum_end]
  endif
  var start = lnum_end
  var stop  = 1
  for w in wins
    var info = getwininfo(w)[0]
    start = min([start, info.topline])
    stop  = max([stop, info.botline])
  endfor
  start = max([1, start - margin])
  stop  = min([lnum_end, stop + margin])
  return [start, stop]
enddef

def VisibleRangeForBuf(buf: number): list<number>
  var margin = get(g:, 'ts_hl_view_margin', 120)
  return VisibleRangeForBufWithMargin(buf, margin)
enddef

def VisibleRangeForBufSymbols(buf: number): list<number>
  var margin = get(g:, 'ts_hl_symbols_view_margin', 500)
  return VisibleRangeForBufWithMargin(buf, margin)
enddef

def ApplyHighlights(buf: number, spans: list<dict<any>>)
  if !bufexists(buf)
    return
  endif
  var [vstart, vend] = VisibleRangeForBuf(buf)
  if has_key(s_last_ranges, buf)
    var prev = s_last_ranges[buf]
    if len(prev) == 2 && prev[1] >= prev[0]
      try
        call prop_clear(prev[0], prev[1], {bufnr: buf})
      catch
      endtry
    endif
  endif

  var applied = 0
  var max_props = get(g:, 'ts_hl_max_props', 20000)

  for s in spans
    var l1 = get(s, 'lnum', 1)
    var l2 = get(s, 'end_lnum', l1)
    if l2 < vstart || l1 > vend
      continue
    endif
    var c1 = max([1, get(s, 'col', 1)])
    var c2 = max([1, get(s, 'end_col', c1)])
    var tp = get(s, 'group', 'TSVariable')
    if l1 <= 0 || l2 <= 0
      continue
    endif
    try
      call prop_add(l1, c1, {type: tp, bufnr: buf, end_lnum: l2, end_col: c2})
    catch
    endtry
    applied += 1
    if applied >= max_props
      break
    endif
  endfor
  s_last_ranges[buf] = [vstart, vend]
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
    if IsHighlightSuspended(buf)
      if has_key(s_inflight_hl, buf) | s_inflight_hl[buf] = false | endif
      return
    endif
    var spans = get(ev, 'spans', [])
    ApplyHighlights(buf, spans)
    if has_key(s_inflight_hl, buf) | s_inflight_hl[buf] = false | endif
  elseif ev.type ==# 'symbols'
    var buf = get(ev, 'buf', 0)
    var syms = get(ev, 'symbols', [])
    ApplySymbols(buf, syms)
    if has_key(s_inflight_syms, buf) | s_inflight_syms[buf] = false | endif
  elseif ev.type ==# 'ast'
    var buf = get(ev, 'buf', 0)
    var lines = get(ev, 'lines', [])
    ShowAst(buf, lines)
  elseif ev.type ==# 'ok'
    var buf = get(ev, 'buf', 0)
    var op  = get(ev, 'op', '')
    if op ==# 'set_text'
      if has_key(s_inflight_sync, buf) | s_inflight_sync[buf] = false | endif
      # 记录最新 changedtick 已同步
      var ct = GetChangedTick(buf)
      s_sent_changedtick[buf] = ct
      # 收到 OK 后触发当前缓冲的请求
      if !IsHighlightSuspended(buf)
        ScheduleRequest(buf, 'edit')
      endif
      ScheduleSymbols(buf)
    endif
  elseif ev.type ==# 'error'
    var buf = get(ev, 'buf', 0)
    echom '[ts-hl] error: ' .. get(ev, 'message', '')
    # 遇到错误时重置 in-flight，尝试同步文本并重试
    if buf > 0
      if has_key(s_inflight_syms, buf) | s_inflight_syms[buf] = false | endif
      if has_key(s_inflight_hl, buf)  | s_inflight_hl[buf]  = false | endif
      s_inflight_sync[buf] = false
      ScheduleSync(buf)
    endif
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

def StopBufTimer(buf: number)
  if has_key(s_req_timers, buf) && s_req_timers[buf] != 0 && exists('*timer_stop')
    try
      call timer_stop(s_req_timers[buf])
    catch
    endtry
    s_req_timers[buf] = 0
  endif
enddef

def StopSyncTimer(buf: number)
  if has_key(s_sync_timers, buf) && s_sync_timers[buf] != 0 && exists('*timer_stop')
    try
      call timer_stop(s_sync_timers[buf])
    catch
    endtry
    s_sync_timers[buf] = 0
  endif
enddef

# =============== 全局暂停高亮：工具函数 ===============
def IsHighlightSuspended(buf: number): bool
  return s_outline_win != 0 && get(g:, 'ts_hl_suspend_highlight_on_outline', 0)
enddef

def ClearPropsForBuf(buf: number)
  if !bufexists(buf)
    return
  endif
  if getbufvar(buf, '&filetype') ==# 'ts_hl_outline'
    return
  endif
  try
    if get(g:, 'ts_hl_clear_scope_on_suspend', 'visible') ==# 'buffer'
      var last = BufLineCount(buf)
      call prop_clear(1, last, {bufnr: buf})
    else
      var [vs, ve] = VisibleRangeForBuf(buf)
      call prop_clear(vs, ve, {bufnr: buf})
    endif
  catch
  endtry
enddef

def ClearAllVisiblePropsOnSuspend()
  var cur = bufnr()
  if bufexists(cur) | ClearPropsForBuf(cur) | endif
  for [k, active] in items(s_active_bufs)
    if active
      var b = str2nr(k)
      if bufexists(b)
        ClearPropsForBuf(b)
      endif
    endif
  endfor
enddef

def ResumeAllHighlights()
  for [k, active] in items(s_active_bufs)
    if active
      var b = str2nr(k)
      if bufexists(b)
        ScheduleRequest(b, 'edit')
      endif
    endif
  endfor
  var cur = bufnr()
  if bufexists(cur)
    ScheduleRequest(cur, 'edit')
  endif
enddef

def GetChangedTick(buf: number): number
  var info = getbufinfo(buf)
  if type(info) == v:t_list && len(info) > 0 && has_key(info[0], 'changedtick')
    return info[0].changedtick
  endif
  return 0
enddef

def SyncBufferNow(buf: number)
  if !EnsureDaemon() | return | endif
  if !bufexists(buf) | return | endif
  var lang = DetectLang(buf)
  if lang ==# '' | return | endif

  var ct = GetChangedTick(buf)
  var last_ct = get(s_sent_changedtick, buf, 0)
  if last_ct == ct && get(s_inflight_sync, buf, false)
    return
  endif

  var lines = getbufline(buf, 1, '$')
  var text = join(lines, "\n")
  s_inflight_sync[buf] = true
  Send({type: 'set_text', buf: buf, lang: lang, text: text})
  Log('Sent set_text for buffer ' .. buf .. ' (changedtick=' .. ct .. ')')
enddef

def ScheduleSync(buf: number)
  if !bufexists(buf) | return | endif
  if !IsSupportedLang(buf) | return | endif

  var ct = GetChangedTick(buf)
  var last_ct = get(s_sent_changedtick, buf, 0)
  if ct == last_ct && !get(s_inflight_sync, buf, false)
    return
  endif

  StopSyncTimer(buf)
  var ms = get(g:, 'ts_hl_debounce', 120)
  if exists('*timer_start')
    try
      s_sync_timers[buf] = timer_start(ms, (id) => {
        s_sync_timers[buf] = 0
        SyncBufferNow(buf)
      })
    catch
      SyncBufferNow(buf)
    endtry
  else
    SyncBufferNow(buf)
  endif
enddef

def ScheduleRequest(buf: number, reason: string = 'edit')
  if !s_enabled
    return
  endif
  if !IsSupportedLang(buf)
    return
  endif
  if IsHighlightSuspended(buf)
    return
  endif

  # 未同步/正在同步时，先同步文本，跳过这次高亮
  var ct = GetChangedTick(buf)
  var last_ct = get(s_sent_changedtick, buf, 0)
  if ct != last_ct || get(s_inflight_sync, buf, false)
    ScheduleSync(buf)
    return
  endif

  StopBufTimer(buf)
  var ms = reason ==# 'scroll' ? get(g:, 'ts_hl_scroll_debounce', 300) : get(g:, 'ts_hl_debounce', 120)

  if exists('*timer_start')
    try
      s_req_timers[buf] = timer_start(ms, (id) => {
        s_req_timers[buf] = 0
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
  var auto_enable_ft = get(g:, 'ts_hl_auto_enable_filetypes', [])
  if type(auto_enable_ft) != v:t_list || len(auto_enable_ft) == 0
    return
  endif
  var ft = getbufvar(buf, '&filetype')
  if index(auto_enable_ft, ft) < 0
    return
  endif
  if has_key(s_active_bufs, buf) && s_active_bufs[buf]
    return
  endif
  if !s_enabled
    Log('Auto-enabling for filetype: ' .. ft)
    Enable()
  endif
  s_active_bufs[buf] = true
  # 初次进入立即同步
  ScheduleSync(buf)
  ScheduleRequest(buf, 'edit')
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
    autocmd CursorMoved,CursorMovedI * call ts_hl#OnScroll(bufnr())
    autocmd BufWinLeave,BufDelete * call ts_hl#OnBufClose(str2nr(expand('<abuf>')))
  augroup END
enddef

export def Disable()
  if !s_enabled
    return
  endif
  s_enabled = false
  augroup TsHl
    autocmd!
  augroup END

  for [k, tid] in items(s_req_timers)
    if tid != 0 && exists('*timer_stop')
      try | call timer_stop(tid) | catch | endtry
    endif
  endfor
  s_req_timers = {}

  for [k, tid] in items(s_sync_timers)
    if tid != 0 && exists('*timer_stop')
      try | call timer_stop(tid) | catch | endtry
    endif
  endfor
  s_sync_timers = {}
  s_inflight_sync = {}
  s_sent_changedtick = {}

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
  # 先保证文本同步
  ScheduleSync(buf)

  if s_outline_win != 0 && buf != s_outline_buf && getbufvar(buf, '&filetype') !=# 'ts_hl_outline'
    if IsSupportedLang(buf)
      s_outline_src_buf = buf
      ScheduleSymbols(buf)
    else
      if s_outline_buf != 0 && bufexists(s_outline_buf)
        var curwin = win_getid()
        try
          if win_gotoid(s_outline_win)
            setlocal modifiable
            try | call prop_clear(1, line('$'), {bufnr: s_outline_buf}) | catch | endtry
            call setline(1, ['<outline unsupported for this filetype>'])
            setlocal nomodifiable
          endif
        finally
          if curwin != 0
            call win_gotoid(curwin)
          endif
        endtry
      endif
    endif
  endif

  ScheduleRequest(buf, 'edit')
  ScheduleSymbols(buf)
enddef

export def OnScroll(buf: number)
  if !bufexists(buf)
    return
  endif
  AutoEnableForBuffer(buf)
  ScheduleRequest(buf, 'scroll')
enddef

export def OnBufClose(buf: number)
  if has_key(s_active_bufs, buf)
    s_active_bufs[buf] = false
  endif
  StopBufTimer(buf)
  StopSyncTimer(buf)
  if exists('*timer_start')
    timer_start(2000, (id) => CheckAndStopDaemon())
  endif
enddef

def BuildTreeByContainer(syms: list<dict<any>>): list<dict<any>>
  var roots: list<dict<any>> = []
  var containers: dict<any> = {}
  var container_kinds = ['namespace', 'class', 'struct', 'enum', 'type', 'variant', 'function']

  def ContainerKey(k: string, n: string, ln: number, co: number): string
    var l = ln > 0 ? ln : 0
    var c = co > 0 ? co : 0
    return k .. '::' .. n .. '@' .. l .. ':' .. c
  enddef

  for i in range(len(syms))
    var s = syms[i]
    var kind = get(s, 'kind', '')
    if index(container_kinds, kind) >= 0
      var name = get(s, 'name', '')
      var lnum = get(s, 'lnum', 1)
      var col  = get(s, 'col', 1)
      var node = {name: name, kind: kind, lnum: lnum, col: col, idx: i, children: []}
      var key = ContainerKey(kind, name, lnum, col)
      containers[key] = node
      roots->add(node)
    endif
  endfor

  for i in range(len(syms))
    var s = syms[i]
    var kind = get(s, 'kind', '')
    var is_container = index(container_kinds, kind) >= 0
    if is_container
      continue
    endif

    var node = {
      name: get(s, 'name', ''),
      kind: kind,
      lnum: get(s, 'lnum', 1),
      col:  get(s, 'col', 1),
      idx:  i,
      children: []
    }

    var ck = get(s, 'container_kind', '')
    var cn = get(s, 'container_name', '')
    var cl = get(s, 'container_lnum', 0)
    var cc = get(s, 'container_col', 0)

    if type(ck) == v:t_string && ck !=# '' && type(cn) == v:t_string && cn !=# ''
      var pkey = ContainerKey(ck, cn, cl, cc)
      if has_key(containers, pkey)
        containers[pkey].children->add(node)
      else
        var parent = {name: cn, kind: ck, lnum: cl, col: cc, idx: -1, children: [node]}
        containers[pkey] = parent
        roots->add(parent)
      endif
    else
      roots->add(node)
    endif
  endfor

  return roots
enddef

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
      var pos_str = show_pos && n.idx >= 0 ? (' (' .. n.lnum .. ':' .. n.col .. ')') : ''

      var line = prefix .. icon .. ' ' .. name .. pos_str

      var pref_bytes = strlen(prefix)
      var icon_bytes = strlen(icon)
      var name_bytes = strlen(name)
      var pos_bytes  = strlen(pos_str)

      var icon_col   = pref_bytes + 1
      var name_start = pref_bytes + icon_bytes + 2
      var name_end   = name_start + name_bytes
      var pos_start  = pos_bytes == 0 ? 0 : name_end
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
  elseif kind ==# 'variant'
    return 'TSVariant'
  else
    return 'TSVariable'
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
  elseif kind ==# 'variant'
    return 'v'
  else
    return '?'
  endif
enddef

def FancyIcon(kind: string): string
  if get(g:, 'ts_hl_outline_hide_icon', 0)
    return ''
  endif

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
    if kind ==# 'variant'      | return '' | endif
  endif
  if kind ==# 'function'     | return 'f' | endif
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
  if kind ==# 'variant'      | return 'v' | endif
  return ''
enddef

# =============== 符号请求 ===============
def RequestSymbolsNow(buf: number)
  if !EnsureDaemon() | return | endif
  var lang = DetectLang(buf)
  if lang ==# '' || !bufexists(buf) | return | endif

  # 未同步/正在同步时先同步
  var ct = GetChangedTick(buf)
  var last_ct = get(s_sent_changedtick, buf, 0)
  if ct != last_ct || get(s_inflight_sync, buf, false)
    ScheduleSync(buf)
    return
  endif

  if get(s_inflight_syms, buf, false)
    return
  endif
  s_inflight_syms[buf] = true

  var [vstart, vend] = VisibleRangeForBufSymbols(buf)
  var max_items = get(g:, 'ts_hl_outline_max_items', 300)
  Send({type: 'symbols', buf: buf, lang: lang, lstart: vstart, lend: vend, max_items: max_items})
  Log('Requested symbols (range-only) for buffer ' .. buf .. ' ...')
enddef

def ScheduleSymbols(buf: number)
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
    execute 'keepalt botright vsplit'
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

# DumpAST 使用缓存
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
  # 保证先同步
  ScheduleSync(buf)
  Send({type: 'dump_ast', buf: buf, lang: lang})
enddef

# =============== 渲染符号侧边栏（树形 + 高亮） ===============
def ApplySymbols(buf: number, syms: list<dict<any>>)
  if s_outline_win == 0 || s_outline_buf == 0 || s_outline_src_buf != buf
    return
  endif
  if !bufexists(s_outline_buf)
    return
  endif

  var items: list<dict<any>> = syms

  var hide_inner = get(g:, 'ts_hl_outline_hide_inner_functions', 1) ? true : false
  if hide_inner
    var filtered: list<dict<any>> = []
    for s in items
      if get(s, 'container_kind', '') ==# 'function'
        continue
      endif
      filtered->add(s)
    endfor
    items = filtered
  endif

  var pats = get(g:, 'ts_hl_outline_exclude_patterns', [])
  if type(pats) == v:t_list && len(pats) > 0
    var filtered2: list<dict<any>> = []
    for s in items
      var skip = false
      for p in pats
        if type(p) == v:t_string && p !=# '' && match(get(s, 'name', ''), p) >= 0
          skip = true
          break
        endif
      endfor
      if !skip
        filtered2->add(s)
      endif
    endfor
    items = filtered2
  endif

  if get(g:, 'ts_hl_outline_hide_fields', 1)
    var tmp: list<dict<any>> = []
    for s in items
      if get(s, 'kind', '') ==# 'field'
        continue
      endif
      tmp->add(s)
    endfor
    items = tmp
  endif
  if get(g:, 'ts_hl_outline_hide_variants', 1)
    var tmp2: list<dict<any>> = []
    for s in items
      if get(s, 'kind', '') ==# 'variant'
        continue
      endif
      tmp2->add(s)
    endfor
    items = tmp2
  endif

  var max_items = get(g:, 'ts_hl_outline_max_items', 300)
  if len(items) > max_items
    # 使用真实视口（无边距），避免 near 覆盖全文件
    var [vstart, vend] = VisibleViewportRangeForBuf(s_outline_src_buf)
    var total = BufLineCount(s_outline_src_buf)
    # 用整数中心的两倍，避免浮点
    var center2 = vstart + vend

    # 拆成视口内/上方/下方
    var near:  list<dict<any>> = []
    var above: list<dict<any>> = []
    var below: list<dict<any>> = []
    for s in items
      var l = get(s, 'lnum', 1)
      if l >= vstart && l <= vend
        call add(near, s)
      elseif l < vstart
        call add(above, s)
      else
        call add(below, s)
      endif
    endfor

    # 上方：从近到远（大->小），下方：从近到远（小->大）
    call sort(above, (a, b) => get(b, 'lnum', 0) - get(a, 'lnum', 0))
    call sort(below, (a, b) => get(a, 'lnum', 0) - get(b, 'lnum', 0))

    # 初始选择：视口内
    var selected = near[ : max_items - 1]
    var need = max_items - len(selected)
    if need > 0
      # 判断更靠近底部还是顶部，靠底部时优先补上方（即当前屏上方、但接近尾部的符号）
      var bias_above_first = (total - vend) < (vstart - 1)
      if bias_above_first
        if len(above) > 0
          selected += above[ : min([need, len(above)]) - 1]
          need = max_items - len(selected)
        endif
        if need > 0 && len(below) > 0
          selected += below[ : min([need, len(below)]) - 1]
          need = max_items - len(selected)
        endif
      else
        if len(below) > 0
          selected += below[ : min([need, len(below)]) - 1]
          need = max_items - len(selected)
        endif
        if need > 0 && len(above) > 0
          selected += above[ : min([need, len(above)]) - 1]
          need = max_items - len(selected)
        endif
      endif
    endif

    # 若还不够：按离视口中心的“整数距离”补齐
    if len(selected) < max_items
      var rest: list<dict<any>> = []
      for s in items
        if index(selected, s) < 0
          rest->add(s)
        endif
      endfor
      # 距离度量：dist = |2*lnum - center2|
      rest->sort((a, b) => {
        var la = get(a, 'lnum', 0)
        var lb = get(b, 'lnum', 0)
        return abs(la * 2 - center2) - abs(lb * 2 - center2)
      })
      var gap = max_items - len(selected)
      selected += rest[ : min([gap, len(rest)]) - 1]
    endif

    items = selected
  endif

  s_outline_items = items

  var nodes = BuildTreeByContainer(items)
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
      call setline(1, lines)
      var last = len(lines)

      var cur_last = line('$')
      if cur_last > last
        try
          call deletebufline(s_outline_buf, last + 1, '$')
        catch
        endtry
      endif

      var disable_props = get(g:, 'ts_hl_outline_disable_props', 1) ? true : false
      try
        call prop_clear(1, last, {bufnr: s_outline_buf})
      catch
      endtry
      if !disable_props
        for i in range(len(lines))
          var lnum = i + 1
          if len(out.meta) <= i
            continue
          endif
          var m = out.meta[i]
          if m.prefix_len > 0
            try | call prop_add(lnum, 1, {type: 'TsHlOutlineGuide', bufnr: s_outline_buf, end_lnum: lnum, end_col: m.prefix_len + 1}) | catch | endtry
          endif
          var grp = KindToTSGroup(m.kind)
          if m.icon_w > 0
            try | call prop_add(lnum, m.icon_col, {type: grp, bufnr: s_outline_buf, end_lnum: lnum, end_col: m.icon_col + m.icon_w}) | catch | endtry
          endif
          if m.name_end > m.name_start
            try | call prop_add(lnum, m.name_start, {type: grp, bufnr: s_outline_buf, end_lnum: lnum, end_col: m.name_end}) | catch | endtry
          endif
          if m.pos_start > 0 && m.pos_end > m.pos_start
            try | call prop_add(lnum, m.pos_start, {type: 'TsHlOutlinePos', bufnr: s_outline_buf, end_lnum: lnum, end_col: m.pos_end}) | catch | endtry
          endif
        endfor
      endif

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
    execute 'keepalt botright vsplit'

    if s_outline_buf != 0 && bufexists(s_outline_buf)
      execute 'buffer ' .. s_outline_buf
    else
      execute 'enew'
      s_outline_buf = bufnr('%')
      execute 'file ts-hl-outline'
      setlocal buftype=nofile bufhidden=wipe nobuflisted noswapfile
      setlocal nowrap nonumber norelativenumber signcolumn=no
      setlocal foldcolumn=0
      setlocal cursorline
      setlocal filetype=ts_hl_outline
      setlocal nobuflisted
      setlocal conceallevel=0 concealcursor=
      setlocal winfixwidth
      nnoremap <silent><buffer> <CR> :call ts_hl#OutlineJump()<CR>
      nnoremap <silent><buffer> q :call ts_hl#OutlineClose()<CR>
    endif

    s_outline_win = win_getid()
    s_outline_src_buf = src

    var width = get(g:, 'ts_hl_outline_width', 32)
    execute 'vertical resize ' .. width

    # 全局暂停：打开时按配置清理各缓冲已绘制 props
    if get(g:, 'ts_hl_suspend_highlight_on_outline', 0)
          \ && get(g:, 'ts_hl_clear_props_on_suspend', 1)
      ClearAllVisiblePropsOnSuspend()
    endif

    OutlineRefresh()
  finally
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
  Log('[ts-hl] outline closed')

  # 全局暂停 -> 恢复：关闭后主动刷新所有活跃缓冲
  if get(g:, 'ts_hl_suspend_highlight_on_outline', 0)
    ResumeAllHighlights()
  endif
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
  ScheduleSymbols(s_outline_src_buf)
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

  var wins = win_findbuf(s_outline_src_buf)
  if len(wins) > 0
    call win_gotoid(wins[0])
  else
    execute 'buffer ' .. s_outline_src_buf
  endif
  call cursor(lnum, col)
  normal! zv
enddef

# 新增：WinClosed 事件回调（导出），用于判断关闭的是否为 outline 窗口
export def OnWinClosed(wid_str: string)
  var wid = 0
  try
    wid = str2nr(wid_str)
  catch
    wid = 0
  endtry
  if wid != 0 && wid == s_outline_win
    # 如果关闭的是 outline 窗口，则走统一的清理逻辑
    # 注意：此时窗口已被关闭，OutlineClose 内部 win_gotoid(s_outline_win) 会失败，但不影响清理状态
    OutlineClose()
  endif
enddef

# =============== 请求调度 ===============
def RequestNow(buf: number)
  if !EnsureDaemon() | return | endif
  var lang = DetectLang(buf)
  if lang ==# '' || !bufexists(buf) | return | endif
  if IsHighlightSuspended(buf)
    return
  endif

  if get(s_inflight_hl, buf, false)
    return
  endif
  s_inflight_hl[buf] = true

  var [hstart, hend] = VisibleRangeForBuf(buf)
  Send({type: 'highlight', buf: buf, lang: lang, lstart: hstart, lend: hend})
  Log('Requested highlight (range-only) for buffer ' .. buf .. ' ...')
enddef
