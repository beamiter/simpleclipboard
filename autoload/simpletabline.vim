vim9script

# 内部状态
var s_pick_mode: bool = false
var s_pick_map: dict<number> = {}   # digit -> bufnr
var s_last_visible: list<number> = []

# Pick 模式用的字母序列（可配置）
var s_pick_chars: list<string> = []
var s_char_to_bufnr: dict<number> = {}

# MRU 与索引分配
var s_idx_to_buf: dict<number> = {}        # digit(1..9,0) -> bufnr
var s_buf_to_idx: dict<number> = {}        # bufnr -> digit(1..9,0)

def Log(msg: string, hl: string = 'None')
  if get(g:, 'simpletabline_debug', 0) == 0
    return
  endif
  try
    echohl hl
    echom '[SimpleTabline] ' .. msg
  catch
  finally
    echohl None
  endtry
enddef

# 配置获取（带默认）
def Conf(name: string, default: any): any
  return get(g:, name, default)
enddef

# 将 g: 配置值安全地转成 bool
def ConfBool(name: string, default_val: bool): bool
  var v = get(g:, name, default_val)
  if type(v) == v:t_bool
    return v
  endif
  if type(v) == v:t_number
    return v != 0
  endif
  return default_val
enddef

# 将普通数字串转为上标（0..9 -> ⁰..⁹），不识别的字符原样返回
def SupDigit(s: string): string
  if s ==# ''
    return ''
  endif
  var m: dict<string> = {
    '0': '⁰', '1': '¹', '2': '²', '3': '³', '4': '⁴',
    '5': '⁵', '6': '⁶', '7': '⁷', '8': '⁸', '9': '⁹'
  }
  var out = ''
  for ch in split(s, '\zs')
    out ..= get(m, ch, ch)
  endfor
  return out
enddef

# 读取 SimpleTree 的 root（若不可用返回空字符串）
def TreeRoot(): string
  var r = ''
  if exists('*simpletree#GetRoot')
    try
      r = simpletree#GetRoot()
    catch
    endtry
  endif
  return type(r) == v:t_string ? r : ''
enddef

def IsWin(): bool
  return has('win32') || has('win64') || has('win95') || has('win32unix')
enddef

def NormPath(p: string): string
  var ap = fnamemodify(p, ':p')
  ap = simplify(substitute(ap, '\\', '/', 'g'))
  var q = substitute(ap, '/\+$', '', '')
  if q ==# ''
    return '/'
  endif
  if q =~? '^[A-Za-z]:$'
    return q .. '/'
  endif
  return q
enddef

# 返回 abs 相对于 root 的相对路径；若不在 root 下,返回空字符串
def RelToRoot(abs: string, root: string): string
  if abs ==# '' || root ==# ''
    return ''
  endif
  var A = NormPath(abs)
  var R = NormPath(root)
  var aCmp = IsWin() ? tolower(A) : A
  var rCmp = IsWin() ? tolower(R) : R
  if aCmp ==# rCmp
    return fnamemodify(A, ':t')
  endif
  var rprefix = (R =~? '^[A-Za-z]:/$') ? R : (R .. '/')
  var rprefixCmp = IsWin() ? tolower(rprefix) : rprefix
  if stridx(aCmp, rprefixCmp) == 0
    return strpart(A, strlen(rprefix))
  endif
  return ''
enddef

# 将相对路径缩写为目录首字母 + 文件名；优先使用内置 pathshorten()
def AbbrevRelPath(rel: string): string
  if rel ==# ''
    return rel
  endif
  if exists('*pathshorten')
    try
      return pathshorten(rel)
    catch
    endtry
  endif
  var parts = split(rel, '/')
  if len(parts) <= 1
    return rel
  endif
  var out: list<string> = []
  var i = 0
  while i < len(parts) - 1
    var seg = parts[i]
    if seg ==# '' || seg ==# '.'
      out->add(seg)
    else
      out->add(strcharpart(seg, 0, 1))
    endif
    i += 1
  endwhile
  out->add(parts[-1])
  return join(out, '/')
enddef

# 按可见顺序为可见 buffers 分配 1..9,0；只分配给可见项
def AssignDigitsForVisible(visible: list<number>)
  s_idx_to_buf = {}
  s_buf_to_idx = {}
  var digits: list<number> = []
  for d in range(1, 9)
    digits->add(d)
  endfor
  digits->add(0)

  var i = 0
  var j = 0
  while i < len(visible) && j < len(digits)
    var bn = visible[i]
    if IsEligibleBuffer(bn)
      var dg = digits[j]
      s_idx_to_buf[dg] = bn
      s_buf_to_idx[bn] = dg
      j += 1
    endif
    i += 1
  endwhile
enddef

def ListedNormalBuffers(): list<dict<any>>
  var use_listed = Conf('simpletabline_listed_only', 1) != 0
  var bis = use_listed ? getbufinfo({'buflisted': 1}) : getbufinfo({'bufloaded': 1})
  var res: list<dict<any>> = []
  for b in bis
    var bt = getbufvar(b.bufnr, '&buftype')
    if type(bt) == v:t_string && bt ==# ''
      res->add(b)
    endif
  endfor

  var side = get(g:, 'simpletabline_newbuf_side', 'right')
  if side ==# 'left'
    sort(res, (a, b) => b.bufnr - a.bufnr)
  else
    sort(res, (a, b) => a.bufnr - b.bufnr)
  endif

  return res
enddef

# 生成在 Tabline 上显示的名称：默认相对 SimpleTree 根并缩写
def BufDisplayName(b: dict<any>): string
  var n = bufname(b.bufnr)
  if n ==# ''
    return '[No Name]'
  endif

  var mode = get(g:, 'simpletabline_path_mode', 'abbr')
  if mode ==# 'tail'
    return fnamemodify(n, ':t')
  endif

  var abs = fnamemodify(n, ':p')
  var root = TreeRoot()
  if root ==# '' && !!get(g:, 'simpletabline_fallback_cwd_root', 1)
    root = getcwd()
  endif

  var rel = (root !=# '') ? RelToRoot(abs, root) : ''
  if rel ==# ''
    return fnamemodify(n, ':t')
  endif

  if mode ==# 'rel'
    return rel
  elseif mode ==# 'abbr'
    return AbbrevRelPath(rel)
  elseif mode ==# 'abs'
    return abs
  else
    return AbbrevRelPath(rel)
  endif
enddef

# 计算单项标签的"可见文字宽度"（不含高亮控制符）
def LabelText(b: dict<any>, key: string): string
  var name = BufDisplayName(b)
  var sep_key = Conf('simpletabline_key_sep', '')
  var show_mod = Conf('simpletabline_show_modified', 1) != 0
  var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

  var key_txt = key
  if key_txt !=# '' && ConfBool('simpletabline_superscript_index', true)
    key_txt = SupDigit(key_txt)
  endif

  var base = (key_txt !=# '' ? key_txt .. sep_key : '') .. name .. mod_mark
  return base
enddef

# 构建当前可见窗口的缓冲区序列
def ComputeVisible(all: list<dict<any>>, buf_keys: dict<string>): list<number>
  var cols = max([&columns, 20])
  var sep = Conf('simpletabline_item_sep', ' | ')
  var sep_w = strdisplaywidth(sep)

  var curbn = bufnr('%')
  var cur_idx = -1
  for i in range(len(all))
    if all[i].bufnr == curbn
      cur_idx = i
      break
    endif
  endfor
  if cur_idx < 0
    cur_idx = 0
  endif

  var widths: list<number> = []
  var widths_by_bn: dict<number> = {}
  var i = 0
  while i < len(all)
    var key = get(buf_keys, string(all[i].bufnr), '')
    var txt = LabelText(all[i], key)
    var w = strdisplaywidth(txt)
    widths->add(w)
    widths_by_bn[all[i].bufnr] = w
    i += 1
  endwhile

  var budget = cols - 2

  # 粘性分支
  if len(s_last_visible) > 0
    var present: dict<number> = {}
    for bi in all
      present[bi.bufnr] = 1
    endfor
    var cand: list<number> = []
    for bn in s_last_visible
      if has_key(present, bn)
        cand->add(bn)
      endif
    endfor

    if index(cand, curbn) >= 0
      def ComputeUsed(lst: list<number>): number
        var used = 0
        var k = 0
        while k < len(lst)
          used += get(widths_by_bn, lst[k], 1)
          if k > 0
            used += sep_w
          endif
          k += 1
        endwhile
        return used
      enddef

      var used_cand = ComputeUsed(cand)
      if used_cand <= budget
        s_last_visible = cand
        return copy(cand)
      endif

      var bs = copy(cand)
      while len(bs) > 0 && ComputeUsed(bs) > budget
        var idx_cur = index(bs, curbn)
        if idx_cur < 0
          break
        endif
        var dist_left = idx_cur
        var dist_right = len(bs) - 1 - idx_cur
        if dist_right >= dist_left
          try | bs->remove(len(bs) - 1) | catch | break | endtry
        else
          try | bs->remove(0) | catch | break | endtry
        endif
      endwhile
      s_last_visible = bs
      return bs
    endif
  endif

  # 以当前为中心左右扩展
  var visible_idx: list<number> = [cur_idx]
  var used = widths[cur_idx]
  var left = cur_idx - 1
  var right = cur_idx + 1

  while true
    var added = 0
    if right < len(all)
      var want = used + sep_w + widths[right]
      if want <= budget
        visible_idx->add(right)
        used = want
        right += 1
        added = 1
      endif
    endif
    if left >= 0
      var want2 = used + sep_w + widths[left]
      if want2 <= budget
        visible_idx->insert(left, 0)
        used = want2
        left -= 1
        added = 1
      endif
    endif
    if added == 0
      break
    endif
  endwhile

  s_last_visible = []
  for j in range(len(visible_idx))
    s_last_visible->add(all[visible_idx[j]].bufnr)
  endfor

  return s_last_visible
enddef

def IsEligibleBuffer(bn: number): bool
  if bn <= 0 || bufexists(bn) == 0
    return false
  endif
  var bt = getbufvar(bn, '&buftype')
  if type(bt) != v:t_string || bt !=# ''
    return false
  endif

  var use_listed = ConfBool('simpletabline_listed_only', true)
  var bl = getbufvar(bn, '&buflisted')
  var is_listed = (type(bl) == v:t_bool) ? bl : (bl != 0)

  return use_listed ? is_listed : true
enddef

# 生成 Pick 模式专用的 Tabline（高亮字母提示）
def TablinePickMode(): string
  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  # 计算可见项（不带键位标记）
  var buf_keys_empty: dict<string> = {}
  for binfo in all
    buf_keys_empty[string(binfo.bufnr)] = ''
  endfor
  var visible = ComputeVisible(all, buf_keys_empty)

  var bynr: dict<dict<any>> = {}
  for binfo in all
    bynr[string(binfo.bufnr)] = binfo
  endfor

  var sep = Conf('simpletabline_item_sep', ' | ')
  var ellipsis = Conf('simpletabline_ellipsis', ' … ')
  var left_omitted = (len(visible) > 0 && visible[0] != all[0].bufnr)
  var right_omitted = (len(visible) > 0 && visible[-1] != all[-1].bufnr)

  var s = ''
  var curbn = bufnr('%')
  var first = true
  var prev_is_cur = false

  if left_omitted
    s ..= '%#SimpleTablineInactive#' .. ellipsis
  endif

  # 为每个可见 buffer 分配字母提示
  s_char_to_bufnr = {}
  var char_idx = 0

  for vbn in visible
    var k = string(vbn)
    if !has_key(bynr, k)
      continue
    endif
    var b = bynr[k]
    var is_cur = (b.bufnr == curbn)

    # 输出分隔符
    if !first
      var use_cur_sep = (prev_is_cur || is_cur)
      if use_cur_sep
        s ..= '%#SimpleTablineSepCurrent#' .. sep .. '%#None#'
      else
        s ..= '%#SimpleTablineSep#' .. sep .. '%#None#'
      endif
    endif

    # 获取提示字母
    var hint_char = ''
    if char_idx < len(s_pick_chars)
      hint_char = s_pick_chars[char_idx]
      s_char_to_bufnr[hint_char] = b.bufnr
      char_idx += 1
    endif

    # 生成显示名称
    var name = BufDisplayName(b)
    var show_mod = Conf('simpletabline_show_modified', 1) != 0
    var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

    # 高亮字母 + 剩余名称
    var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
    var name_part = ''

    if hint_char !=# '' && len(name) > 0
      # 用红色高亮提示字母
      var rest_name = name
      name_part = '%#SimpleTablinePickHint#' .. hint_char .. '%#None#' 
            \ .. grp_item .. rest_name .. mod_mark .. '%#None#'
    else
      name_part = grp_item .. name .. mod_mark .. '%#None#'
    endif

    s ..= name_part
    first = false
    prev_is_cur = is_cur
  endfor

  if right_omitted
    s ..= '%#SimpleTablineInactive#' .. ellipsis .. '%#None#'
  endif

  s ..= '%=%#SimpleTablineFill#'
  return s
enddef

export def Tabline(): string
  # Pick 模式下使用特殊渲染
  if s_pick_mode
    return TablinePickMode()
  endif

  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var sep = Conf('simpletabline_item_sep', ' | ')
  var ellipsis = Conf('simpletabline_ellipsis', ' … ')
  var show_keys = 1

  # 计算可见集
  var buf_keys1: dict<string> = {}
  for binfo in all
    buf_keys1[string(binfo.bufnr)] = ''
  endfor
  var visible1 = ComputeVisible(all, buf_keys1)

  AssignDigitsForVisible(visible1)

  var buf_keys2: dict<string> = {}
  for binfo in all
    var dg2 = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys2[string(binfo.bufnr)] = dg2 < 0 ? '' : (dg2 == 0 ? '0' : string(dg2))
  endfor
  var visible2 = ComputeVisible(all, buf_keys2)

  AssignDigitsForVisible(visible2)

  var buf_keys: dict<string> = {}
  for binfo in all
    var dg = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys[string(binfo.bufnr)] = dg < 0 ? '' : (dg == 0 ? '0' : string(dg))
  endfor
  var visible = visible2

  var bynr: dict<dict<any>> = {}
  for binfo in all
    bynr[string(binfo.bufnr)] = binfo
  endfor

  var left_omitted = (len(visible) > 0 && visible[0] != all[0].bufnr)
  var right_omitted = (len(visible) > 0 && visible[-1] != all[-1].bufnr)

  var s = ''
  var curbn = bufnr('%')

  if left_omitted
    s ..= '%#SimpleTablineInactive#' .. ellipsis
  endif

  s_pick_map = copy(s_idx_to_buf)

  var first = true
  var prev_is_cur = false

  for vbn in visible
    var k = string(vbn)
    if !has_key(bynr, k)
      continue
    endif
    var b = bynr[k]
    var is_cur = (b.bufnr == curbn)

    if !first
      var use_cur_sep = (prev_is_cur || is_cur)
      if use_cur_sep
        s ..= '%#SimpleTablineSepCurrent#' .. sep .. '%#None#'
      else
        s ..= '%#SimpleTablineSep#' .. sep .. '%#None#'
      endif
    endif

    var key_raw = get(buf_keys, string(b.bufnr), '')
    var key_txt = key_raw
    if key_txt !=# '' && ConfBool('simpletabline_superscript_index', true)
      key_txt = SupDigit(key_txt)
    endif
    var key_part = ''
    if show_keys && key_txt !=# ''
      var key_grp = is_cur ? '%#SimpleTablineIndexActive#' : '%#SimpleTablineIndex#'
      var sep_key = Conf('simpletabline_key_sep', '')
      key_part = key_grp .. key_txt .. '%#None#' .. sep_key
    endif

    var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
    var name = BufDisplayName(b)
    var show_mod = Conf('simpletabline_show_modified', 1) != 0
    var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
    var name_part = grp_item .. name .. mod_mark .. '%#None#'

    var item = key_part .. name_part

    if s ==# ''
      s = item
    else
      s ..= item
    endif

    first = false
    prev_is_cur = is_cur
  endfor

  if right_omitted
    s ..= '%#SimpleTablineInactive#' .. ellipsis .. '%#None#'
  endif

  s ..= '%=%#SimpleTablineFill#'
  return s
enddef

# 初始化 Pick 字母序列（类似 EasyMotion）
def InitPickChars()
  # 可通过 g:simpletabline_pick_chars 自定义字母顺序
  var chars_str = get(g:, 'simpletabline_pick_chars', 'asdfghjklqwertyuiopzxcvbnm')
  s_pick_chars = split(chars_str, '\zs')
enddef

# 强制刷新 tabline
def ForceRedrawTabline()
  # 方法1: 触发 tabline 重绘
  try
    redrawtabline
  catch
  endtry

  # 方法2: 强制完全重绘（备用）
  try
    redraw!
  catch
  endtry

  # 方法3: 触发事件（备用）
  try
    execute 'doautocmd User SimpleTablineRefresh'
  catch
  endtry
enddef

# 进入 Pick 模式
export def BufferPick()
  if s_pick_mode
    call CancelPick()
    return
  endif

  InitPickChars()
  s_pick_mode = true
  s_char_to_bufnr = {}

  # 映射所有可能的字母
  for ch in s_pick_chars
    try
      execute 'nnoremap <nowait> <silent> ' .. ch .. ' :call simpletabline#PickChar("' .. ch .. '")<CR>'
    catch
    endtry
  endfor

  # ESC 取消
  try
    nnoremap <nowait> <silent> <Esc> :call simpletabline#CancelPick()<CR>
  catch
  endtry

  # 强制刷新 tabline 显示
  ForceRedrawTabline()

  Log('Pick mode: press highlighted letter to switch buffer, ESC to cancel')
enddef

export def CancelPick()
  if !s_pick_mode
    return
  endif

  s_pick_mode = false
  s_char_to_bufnr = {}

  # 取消所有字母映射
  for ch in s_pick_chars
    try
      execute 'nunmap ' .. ch
    catch
    endtry
  endfor

  try
    nunmap <Esc>
  catch
  endtry

  # 强制刷新 tabline 恢复正常显示
  ForceRedrawTabline()

  Log('Pick mode canceled')
enddef

# 根据字母跳转 buffer
export def PickChar(ch: string)
  if !has_key(s_char_to_bufnr, ch)
    echo '[SimpleTabline] No buffer bound to "' .. ch .. '"'
    call CancelPick()
    return
  endif

  var bn = s_char_to_bufnr[ch]
  if bn > 0 && bufexists(bn)
    execute 'buffer ' .. bn
  else
    echo '[SimpleTabline] Invalid buffer'
  endif

  call CancelPick()
enddef

# 数字快速跳转（保留原有功能）
export def BufferJump(n: number)
  if empty(keys(s_idx_to_buf))
    try | redrawstatus | catch | endtry
  endif

  if !has_key(s_idx_to_buf, n)
    echo '[SimpleTabline] No visible buffer bound to ' .. (n == 0 ? '0' : string(n))
    return
  endif
  var bn = s_idx_to_buf[n]
  if bn > 0 && bufexists(bn)
    execute 'buffer ' .. bn
  else
    echo '[SimpleTabline] Invalid buffer'
  endif
enddef

export def BufferJump1()
  BufferJump(1)
enddef
export def BufferJump2()
  BufferJump(2)
enddef
export def BufferJump3()
  BufferJump(3)
enddef
export def BufferJump4()
  BufferJump(4)
enddef
export def BufferJump5()
  BufferJump(5)
enddef
export def BufferJump6()
  BufferJump(6)
enddef
export def BufferJump7()
  BufferJump(7)
enddef
export def BufferJump8()
  BufferJump(8)
enddef
export def BufferJump9()
  BufferJump(9)
enddef
export def BufferJump0()
  BufferJump(0)
enddef

# 废弃的 PickDigit（保留兼容性）
export def PickDigit(n: number)
  BufferJump(n)
enddef
