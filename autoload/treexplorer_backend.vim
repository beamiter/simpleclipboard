vim9script

var s_job = v:null
var s_buf = ''         # 处理分包的缓冲
var s_next_id = 0
var s_cbs: dict<any> = {} # id -> {on_chunk, on_done, on_error}

def NextId(): number
  s_next_id += 1
  return s_next_id
enddef

def FindBackend(): string
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

export def IsRunning(): bool
  return s_job isnot v:null && job_status(s_job) ==# 'run'
enddef

export def EnsureBackend(cmd: string = ''): bool
  if IsRunning()
    return true
  endif
  if cmd ==# ''
    cmd = FindBackend()
  endif
  if cmd ==# '' || !executable(cmd)
    echohl ErrorMsg
    echom '[SimpleTree] backend not found. Set g:simpletree_daemon_path or put simpletree-daemon into runtimepath/lib/.'
    echohl None
    return false
  endif

  s_buf = ''
  s_job = job_start([cmd], {
    in_io: 'pipe',
    out_mode: 'raw',
    out_cb: (ch, msg) => {
      s_buf ..= msg
      var lines = split(s_buf, "\n", 1) " 保留未完整行
      s_buf = lines[-1]
      for i in range(0, len(lines) - 2)
        var line = lines[i]
        if line ==# ''
          continue
        endif
        try
          var ev = json_decode(line)
        catch
          continue
        endtry
        if type(ev) != v:t_dict || !has_key(ev, 'type')
          continue
        endif
        if ev.type ==# 'list_chunk'
          var id = ev.id
          if has_key(s_cbs, id)
            if has_key(ev, 'entries')
              try
                s_cbs[id].on_chunk(ev.entries)
              catch
              endtry
            endif
            if get(ev, 'done', v:false)
              try
                s_cbs[id].on_done()
              catch
              endtry
              call remove(s_cbs, id)
            endif
          endif
        elseif ev.type ==# 'error'
          var id = get(ev, 'id', 0)
          if id != 0 && has_key(s_cbs, id)
            try
              s_cbs[id].on_error(get(ev, 'message', ''))
            catch
            endtry
            call remove(s_cbs, id)
          else
            echom '[SimpleTree] backend error: ' .. get(ev, 'message', '')
          endif
        endif
      endfor
    },
    err_mode: 'nl',
    err_cb: (ch, line) => {
      if get(g:, 'simpleclipboard_debug', 0)
        echom '[SimpleTree][stderr] ' .. line
      endif
    },
    exit_cb: (ch, code) => {
      if get(g:, 'simpleclipboard_debug', 0)
        echom '[SimpleTree] backend exited with code ' .. code
      endif
      s_job = v:null
      s_buf = ''
      s_cbs = {}
    },
    stoponexit: 'term',
  })

  return IsRunning()
enddef

export def Stop(): void
  if IsRunning()
    try
      call job_stop(s_job)
    catch
    endtry
  endif
  s_job = v:null
  s_buf = ''
  s_cbs = {}
enddef

def Send(req: dict<any>): void
  if !EnsureBackend()
    return
  endif
  try
    call chansend(s_job, json_encode(req) .. "\n")
  catch
  endtry
enddef

export def List(path: string, show_hidden: bool, max: number, on_chunk: func, on_done: func, on_error: func): number
  if !EnsureBackend()
    call on_error('backend not available')
    return 0
  endif
  var id = NextId()
  s_cbs[id] = {on_chunk: on_chunk, on_done: on_done, on_error: on_error}
  Send({type: 'list', id: id, path: path, show_hidden: show_hidden, max: max})
  return id
enddef

export def Cancel(id: number): void
  if id <= 0 || !IsRunning()
    return
  endif
  Send({type: 'cancel', id: id})
  if has_key(s_cbs, id)
    call remove(s_cbs, id)
  endif
enddef
