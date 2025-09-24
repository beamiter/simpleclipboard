vim9script
import autoload 'treexplorer_backend.vim' as Backend

# 配置
g:simpletree_width = get(g:, 'simpletree_width', 30)
g:simpletree_hide_dotfiles = get(g:, 'simpletree_hide_dotfiles', 1)
g:simpletree_page = get(g:, 'simpletree_page', 200)
g:simpletree_keep_focus = get(g:, 'simpletree_keep_focus', 1)

# 脚本状态
var s_bufnr: number = -1
var s_winid: number = 0
var s_root: string = ''
var s_hide_dotfiles: bool = !!g:simpletree_hide_dotfiles

var s_state: dict<any> = {}         # path -> {expanded: bool}
var s_cache: dict<list<dict<any>>> = {}   # path -> entries[]
var s_loading: dict<bool> = {}      # path -> true
var s_pending: dict<number> = {}    # path -> request id
var s_line_index: list<dict<any>> = []   # 渲染行对应的节点

def AbsPath(p: string): string
  if p ==# ''
    return simplify(fnamemodify(getcwd(), ':p'))
  endif
  var ap = fnamemodify(p, ':p')
  if ap ==# ''
    ap = fnamemodify(getcwd() .. '/' .. p, ':p')
  endif
  return simplify(ap)
enddef

def IsDir(p: string): bool
  return isdirectory(p)
enddef

def Join(base: string, name: string): string
  return simplify(fnamemodify(base .. '/' .. name, ':p'))
enddef

def GetNodeState(path: string): dict<any>
  if !has_key(s_state, path)
    s_state[path] = {expanded: false}
  endif
  return s_state[path]
enddef

def ScanDirAsync(path: string)
  if has_key(s_cache, path) || get(s_loading, path, false)
    return
  endif
  s_loading[path] = true

  var acc: list<dict<any>> = []
  var p = path
  var req_id = Backend.List(p, !s_hide_dotfiles, g:simpletree_page,
    (entries) => {
      acc += entries
      s_cache[p] = acc
      Render()
    },
    () => {
      s_loading[p] = false
      s_cache[p] = acc
      if has
