vim9script

# 内部状态
var s_pick_mode: bool = false
var s_pick_map: dict<number> = {}   # digit -> bufnr
var s_last_visible: list<number> = []

# MRU 与索引分配
var s_mru: list<number> = []               # 最近使用的 bufnr（0 位最最近）
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
  sort(res, (a, b) => a.bufnr - b.bufnr)
  return res
enddef

# 生成缓冲区显示名称（尾名；无名时标记）
def BufDisplayName(b: dict<any>): string
  var n = bufname(b.bufnr)
  if n ==# ''
    return '[No Name]'
  endif
  return fnamemodify(n, ':t')
enddef

# 计算单项标签的“可见文字宽度”（不含高亮控制符）
def LabelText(b: dict<any>, key: string): string
  var name = BufDisplayName(b)
  var sep = Conf('simpletabline_key_sep', ' ')
  var show_mod = Conf('simpletabline_show_modified', 1) != 0
  var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
  return (key !=# '' ? key .. sep : '') .. name .. mod_mark
enddef

# 构建当前可见窗口的缓冲区序列，保证当前缓冲区可见，左右均衡填充；不足时两端省略
# buf_keys 的键为字符串化的 bufnr
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

  # 预生成 label 宽度（使用已分配的 key；未分配为空）
  var widths: list<number> = []
  var i = 0
  while i < len(all)
    var key = get(buf_keys, string(all[i].bufnr), '')
    var txt = LabelText(all[i], key)
    widths->add(strdisplaywidth(txt))
    i += 1
  endwhile

  # 留出一些边缘空间，避免溢出
  var budget = cols - 2
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

def ReassignIndices()
  s_idx_to_buf = {}
  s_buf_to_idx = {}
  # 数字键顺序：1..9, 0
  var digits: list<number> = []
  for d in range(1, 9)
    digits->add(d)
  endfor
  digits->add(0)
  var maxk = min([len(digits), 10])
  var i = 0
  var assigned = 0
  while i < len(s_mru) && assigned < maxk
    var bn = s_mru[i]
    if IsEligibleBuffer(bn)
      var dg = digits[assigned]
      s_idx_to_buf[dg] = bn
      s_buf_to_idx[bn] = dg
      assigned += 1
    endif
    i += 1
  endwhile
enddef

export def OnBufEnter()
  var bn = bufnr('%')
  if !IsEligibleBuffer(bn)
    return
  endif
  var i = index(s_mru, bn)
  if i >= 0
    s_mru->remove(i)
  endif
  s_mru->insert(bn, 0)
  ReassignIndices()
enddef

export def OnBufAdd(bn: number)
  if !IsEligibleBuffer(bn)
    return
  endif
  var i = index(s_mru, bn)
  if i >= 0
    s_mru->remove(i)
  endif
  s_mru->insert(bn, 0)
  ReassignIndices()
enddef

export def OnBufDelete(bn: number)
  var i = index(s_mru, bn)
  if i >= 0
    s_mru->remove(i)
  endif
  ReassignIndices()
enddef

# 根据 MRU 分配的键生成 tabline 字符串
export def Tabline(): string
  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var sep = Conf('simpletabline_item_sep', ' | ')
  var ellipsis = Conf('simpletabline_ellipsis', ' … ')
  var show_keys = 1

  # bufnr -> key 字符串映射（键用字符串化的 bufnr）
  var buf_keys: dict<string> = {}
  for binfo in all
    var dg = get(s_buf_to_idx, binfo.bufnr, -1)
    buf_keys[string(binfo.bufnr)] = dg < 0 ? '' : (dg == 0 ? '0' : string(dg))
  endfor

  var visible = ComputeVisible(all, buf_keys)

  # bufnr -> bufinfo 索引表（键为字符串）
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

  # Pick 映射取全局 MRU 分配
  s_pick_map = copy(s_idx_to_buf)

  for vbn in visible
    var k = string(vbn)
    if !has_key(bynr, k)
      continue
    endif
    var b = bynr[k]

    var is_cur = (b.bufnr == curbn)
    var grp = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'

    var key = get(buf_keys, string(b.bufnr), '')
    var key_part = ''
    if show_keys && key !=# ''
      var kgrp = s_pick_mode ? '%#SimpleTablinePickDigit#' : grp
      key_part = kgrp .. key .. '%#None#' .. Conf('simpletabline_key_sep', ' ')
    endif

    var name = BufDisplayName(b)
    var show_mod = Conf('simpletabline_show_modified', 1) != 0
    var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

    var item = grp .. key_part .. name .. mod_mark .. '%#None#'

    if s ==# ''
      s = item
    else
      s ..= '%#SimpleTablineFill#' .. sep .. '%#None#' .. item
    endif
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
