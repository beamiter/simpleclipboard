vim9script

# 内部状态
var s_pick_mode: bool = false
var s_pick_map: dict<number> = {}   # digit -> bufnr
var s_last_visible: list<number> = []

# MRU 与索引分配
var s_idx_to_buf: dict<number> = {}        # digit(1..9,0) -> bufnr
var s_buf_to_idx: dict<number> = {}        # bufnr -> digit(1..9,0)

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

# 返回 abs 相对于 root 的相对路径；若不在 root 下，返回空字符串
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
    # 新 buffer 在左侧：bufnr 大的排前面
    sort(res, (a, b) => b.bufnr - a.bufnr)
  else
    # 默认：新 buffer 在右侧
    sort(res, (a, b) => a.bufnr - b.bufnr)
  endif

  return res
enddef

# 生成在 Tabline 上显示的名称：默认相对 SimpleTree 根并缩写
# g:simpletabline_path_mode: 'abbr'|'rel'|'tail'|'abs'
# g:simpletabline_fallback_cwd_root: 1 使用 CWD 作为 root（当未打开 SimpleTree 或 root 为空）
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
    # 不在 root 下时，避免太长，退化为文件名
    return fnamemodify(n, ':t')
  endif

  if mode ==# 'rel'
    return rel
  elseif mode ==# 'abbr'
    return AbbrevRelPath(rel)
  elseif mode ==# 'abs'
    return abs
  else
    # 未知配置，回退为缩写
    return AbbrevRelPath(rel)
  endif
enddef

# 计算单项标签的“可见文字宽度”（不含高亮控制符）
# 已移除 prefix/suffix，保证与渲染一致
def LabelText(b: dict<any>, key: string): string
  var name = BufDisplayName(b)
  var sep = Conf('simpletabline_key_sep', ' ')
  var show_mod = Conf('simpletabline_show_modified', 1) != 0
  var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

  var key_txt = key
  if key_txt !=# '' && ConfBool('simpletabline_superscript_index', true)
    key_txt = SupDigit(key_txt)
  endif

  var base = (key_txt !=# '' ? key_txt .. sep : '') .. name .. mod_mark
  return base
enddef

# 构建当前可见窗口的缓冲区序列：
# - 若当前 buffer 在 s_last_visible 中，且宽度预算允许，则保持 s_last_visible 不动；
# - 若超出预算，则仅从两端裁剪（优先裁剪离当前更远的一侧），始终保留当前；
# - 否则按原有“居中扩展”算法计算。
def ComputeVisible(all: list<dict<any>>, buf_keys: dict<string>): list<number>
  var cols = max([&columns, 20])
  var sep = Conf('simpletabline_item_sep', ' | ')
  var sep_w = strdisplaywidth(sep)

  # 当前缓冲区索引
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

  # 预生成每个 bufnr 的 label 宽度（使用当前已分配的 key；未分配为空）
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

  # 留出一些边缘空间，避免溢出
  var budget = cols - 2

  # ---------- 粘性分支：若当前在上次可见集内，尽量保持不动 ----------
  if len(s_last_visible) > 0
    # 仅保留当前 still-present 的 bufnr
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
      # 计算 cand 的总宽度
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

      # 裁剪两端直到满足预算：始终保留 curbn，优先裁剪离当前更远的一侧（平衡）
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
  # ---------- 结束粘性分支 ----------

  # 原有“以当前为中心左右扩展”的计算
  var visible_idx: list<number> = [cur_idx]
  var used = widths[cur_idx]
  var left = cur_idx - 1
  var right = cur_idx + 1

  # 向两侧扩展，优先右侧，再左侧
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

# MRU 更新与索引分配
def IsEligibleBuffer(bn: number): bool
  if bn <= 0 || bufexists(bn) == 0
    return false
  endif
  var bt = getbufvar(bn, '&buftype')
  if type(bt) != v:t_string || bt !=# ''
    return false
  endif

  var use_listed = ConfBool('simpletabline_listed_only', true)

  # 安全读取 &buflisted 为布尔
  var bl = getbufvar(bn, '&buflisted')
  var is_listed = (type(bl) == v:t_bool) ? bl : (bl != 0)

  return use_listed ? is_listed : true
enddef

export def Tabline(): string
  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var sep = Conf('simpletabline_item_sep', ' | ')
  var ellipsis = Conf('simpletabline_ellipsis', ' … ')
  var show_keys = 1

  # 第一次：不带数字，估算可见集
  var buf_keys1: dict<string> = {}
  for binfo in all
    buf_keys1[string(binfo.bufnr)] = ''
  endfor
  var visible1 = ComputeVisible(all, buf_keys1)

  # 基于 visible1 从左到右分配 1..9,0
  AssignDigitsForVisible(visible1)

  # 第二次：带上数字再计算一次可见集，保证宽度准确
  var buf_keys2: dict<string> = {}
  for binfo in all
    var dg2 = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys2[string(binfo.bufnr)] = dg2 < 0 ? '' : (dg2 == 0 ? '0' : string(dg2))
  endfor
  var visible2 = ComputeVisible(all, buf_keys2)

  # 用最终的可见集再分配一次数字，确保“可见项左到右编号”
  AssignDigitsForVisible(visible2)

  # 用最终分配生成 buf_keys
  var buf_keys: dict<string> = {}
  for binfo in all
    var dg = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys[string(binfo.bufnr)] = dg < 0 ? '' : (dg == 0 ? '0' : string(dg))
  endfor
  var visible = visible2

  # 后续保持你原有的渲染逻辑
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

  # Pick 映射取本次可见分配
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

    # 输出分隔符（非第一个项）
    if !first
      var use_cur_sep = (prev_is_cur || is_cur)
      if use_cur_sep
        s ..= '%#SimpleTablineSepCurrent#' .. sep .. '%#None#'
      else
        s ..= '%#SimpleTablineSep#' .. sep .. '%#None#'
      endif
    endif

    # 索引显示文本（可选上标 + 独立高亮组；Pick 模式优先）
    var key_raw = get(buf_keys, string(b.bufnr), '')
    var key_txt = key_raw
    if key_txt !=# '' && ConfBool('simpletabline_superscript_index', true)
      key_txt = SupDigit(key_txt)
    endif
    var key_part = ''
    if show_keys && key_txt !=# ''
      var key_grp = s_pick_mode ? '%#SimpleTablinePickDigit#' : (is_cur ? '%#SimpleTablineIndexActive#' : '%#SimpleTablineIndex#')
      key_part = key_grp .. key_txt .. '%#None#' .. Conf('simpletabline_key_sep', ' ')
    endif

    # 名称 + 修改标记（现有激活/非激活组）
    var grp_item = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'
    var name = BufDisplayName(b)
    var show_mod = Conf('simpletabline_show_modified', 1) != 0
    var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
    var name_part = grp_item .. name .. mod_mark .. '%#None#'

    # 不再使用 prefix/suffix，只输出键位和名称
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

# 进入/退出 Pick 模式：只在 Pick 模式下覆盖 0..9
def MapDigit(n: number)
  try
    execute 'nnoremap <nowait> <silent> ' .. (n == 0 ? '0' : string(n)) .. ' :call simpletabline#PickDigit(' .. n .. ')<CR>'
  catch
  endtry
enddef

def UnmapDigit(n: number)
  try
    execute 'nunmap ' .. (n == 0 ? '0' : string(n))
  catch
  endtry
enddef

export def BufferPick()
  if s_pick_mode
    call CancelPick()
    return
  endif
  s_pick_mode = true
  s_pick_map = copy(s_idx_to_buf)
  for n in range(1, 9)
    MapDigit(n)
  endfor
  MapDigit(0)
  try
    nnoremap <nowait> <silent> <Esc> :call simpletabline#CancelPick()<CR>
  catch
  endtry
  echo '[SimpleTabline] Pick: press 1..9 or 0 to switch; Esc to cancel.'
  redrawstatus
enddef

export def CancelPick()
  s_pick_mode = false
  for n in range(1, 9)
    UnmapDigit(n)
  endfor
  UnmapDigit(0)
  try
    nunmap <Esc>
  catch
  endtry
  echo '[SimpleTabline] Pick canceled.'
  redrawstatus
enddef

export def PickDigit(n: number)
  if !has_key(s_pick_map, n)
    echo '[SimpleTabline] No buffer bound to ' .. (n == 0 ? '0' : string(n))
    call CancelPick()
    return
  endif
  var bn = s_pick_map[n]
  if bn > 0 && bufexists(bn)
    execute 'buffer ' .. bn
  else
    echo '[SimpleTabline] Invalid buffer'
  endif
  call CancelPick()
enddef

export def BufferJump(n: number)
  # 如果还没分配过索引（刚启动），先触发一次渲染
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
