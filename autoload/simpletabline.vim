vim9script

# 内部状态
var s_pick_mode: bool = false
var s_pick_map: dict<number> = {}   # digit -> bufnr
var s_last_visible: list<number> = []

# 配置获取（带默认）
def Conf(name: string, default: any): any
  return get(g:, name, default)
enddef

def ListedNormalBuffers(): list<dict<any>>
  var use_listed = !!Conf('simpletabline_listed_only', 1)
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
  var show_mod = !!Conf('simpletabline_show_modified', 1)
  var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''
  return key .. sep .. name .. mod_mark
enddef

# 构建当前可见窗口的缓冲区序列，保证当前缓冲区可见，左右均衡填充；不足时两端省略
def ComputeVisible(all: list<dict<any>>): list<number>
  var cols = max([&columns, 20])
  var sep = Conf('simpletabline_item_sep', ' | ')
  var ellipsis = Conf('simpletabline_ellipsis', ' … ')
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

  # 先为所有项预生成 label 宽度（假设 key 采用 1..9/0，实际分配只给可见项）
  var widths: list<number> = []
  var keys_sim: list<string> = []
  var i = 0
  while i < len(all)
    var key = ''
    if i < 9
      key = string(i + 1)
    elseif i == 9
      key = '0'
    else
      key = ''  # 超出 10 项时，非可见项不分配 key；可见时再重新测量
    endif
    keys_sim->add(key)
    var txt = LabelText(all[i], key)
    widths->add(strdisplaywidth(txt))
    i += 1
  endwhile

  # 留出一些边缘空间，避免溢出（你也可以配一个固定边距）
  var budget = cols - 2
  # 当前项占用 + 分隔符（如果还有其它项）
  var visible_idx: list<number> = [cur_idx]
  var used = widths[cur_idx]
  var left = cur_idx - 1
  var right = cur_idx + 1

  # 向两侧扩展，优先右侧，再左侧，保持尽可能多
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

  # 记录可见，用于 pick 映射
  s_last_visible = []
  for j in range(len(visible_idx))
    s_last_visible->add(all[visible_idx[j]].bufnr)
  endfor

  return s_last_visible
enddef

# 根据可见列表分配 1..9/0 的 pick 键，并生成 tabline 字符串
export def Tabline(): string
  var all = ListedNormalBuffers()
  if len(all) == 0
    return ''
  endif

  var sep = Conf('simpletabline_item_sep', ' | ')
  var ellipsis = Conf('simpletabline_ellipsis', ' … ')
  var show_keys = 1

  var visible = ComputeVisible(all)

  # 建 bufnr -> bufinfo 索引表（把键统一转成字符串，避免类型混淆）
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

  s_pick_map = {}
  var count_assigned = 0

  for vbn in visible
    var k = string(vbn)
    if !has_key(bynr, k)
      continue
    endif
    var b = bynr[k]

    var is_cur = (b.bufnr == curbn)
    var grp = is_cur ? '%#SimpleTablineActive#' : '%#SimpleTablineInactive#'

    var key = ''
    if count_assigned < 9
      key = string(count_assigned + 1)
    elseif count_assigned == 9
      key = '0'
    endif
    if key !=# ''
      s_pick_map[str2nr(key)] = b.bufnr
    endif

    var key_part = ''
    if show_keys && key !=# ''
      var kgrp = s_pick_mode ? '%#SimpleTablinePickDigit#' : grp
      key_part = kgrp .. key .. '%#None#'
    endif

    var name = BufDisplayName(b)
    var show_mod = !!Conf('simpletabline_show_modified', 1)
    var mod_mark = (show_mod && get(b, 'changed', 0) == 1) ? ' +' : ''

    var item = grp .. (key_part !=# '' ? key_part .. Conf('simpletabline_key_sep', ' ') : '') .. name .. mod_mark .. '%#None#'

    if s ==# ''
      s = item
    else
      s ..= '%#SimpleTablineFill#' .. sep .. '%#None#' .. item
    endif

    count_assigned += 1
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
    # 已经是 pick 模式 -> 取消
    call CancelPick()
    return
  endif
  s_pick_mode = true
  for n in range(1, 9)
    MapDigit(n)
  endfor
  MapDigit(0)
  # Esc 退出
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
