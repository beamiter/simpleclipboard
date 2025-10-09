vim9script

# =============== 状态 ===============
var s_job: any = v:null
var s_running: bool = false
var s_req_timer: number = 0
var s_enabled: bool = false

# 待用的 TS 高亮组 -> Vim 高亮组 默认链接
const s_groups = [
  'TSComment', 'TSString', 'TSNumber', 'TSBoolean',
  'TSKeyword', 'TSFunction', 'TSType', 'TSVariable', 'TSNamespace'
]

# =============== 工具 ===============
def Log(msg: string)
  if get(g:, 'ts_hl_debug', 0)
    echom '[ts-hl] ' .. msg
  endif
enddef

def DetectLang(buf: number): string
  var ft = getbufvar(buf, '&filetype')
  if ft ==# 'rust'
    return 'rust'
  elseif ft ==# 'javascript' || ft ==# 'javascriptreact' || ft ==# 'jsx'
    return 'javascript'
  else
    return ''
  endif
enddef

def EnsureHlGroupsAndProps()
  try
    for g in s_groups
      execute 'highlight default link ' .. g .. ' ' .. (
            g ==# 'TSComment'   ? 'Comment'     :
            g ==# 'TSString'    ? 'String'      :
            g ==# 'TSNumber'    ? 'Number'      :
            g ==# 'TSBoolean'   ? 'Boolean'     :
            g ==# 'TSKeyword'   ? 'Keyword'     :
            g ==# 'TSFunction'  ? 'Function'    :
            g ==# 'TSType'      ? 'Type'        :
            g ==# 'TSNamespace' ? 'Identifier'  :
                                   'Identifier'
      )
      # 每个组建一个 textprop type；已存在会失败，忽略异常
      try
        call prop_type_add(g, {highlight: g, combine: v:true, priority: 11})
      catch
      endtry
    endfor
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
    echohl ErrorMsg | echom '[ts-hl] daemon not found, set g:ts_hl_daemon_path or place vim-ts-daemon in runtimepath/lib' | echohl None
    return false
  endif
  try
    s_job = job_start([exe], {
      in_io: 'pipe',
      out_mode: 'nl',
      out_cb: (ch, l) => OnDaemonEvent(l),
      err_mode: 'nl',
      err_cb: (ch, l) => 0,
      exit_cb: (ch, code) => {
        s_running = false
        s_job = v:null
      },
      stoponexit: 'term'
    })
  catch
    s_job = v:null
    s_running = false
    echohl ErrorMsg | echom '[ts-hl] failed to start daemon: ' .. v:exception | echohl None
    return false
  endtry
  s_running = (s_job != v:null)
  if s_running
    EnsureHlGroupsAndProps()
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
  endtry
enddef

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
enddef

def ScheduleRequest(buf: number)
  if !s_enabled
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
  augroup END

  # 对当前缓冲立即请求一次
  call ts_hl#OnBufEvent(bufnr())
  echo '[ts-hl] enabled'
enddef

export def Disable()
  if !s_enabled
    return
  endif
  s_enabled = false
  augroup TsHl
    autocmd!
  augroup END
  # 不强制停止 daemon，保留复用；如需停止可扩展命令
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
  ScheduleRequest(buf)
enddef
