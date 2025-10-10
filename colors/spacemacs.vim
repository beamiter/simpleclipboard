vim9script

if exists('g:colors_name')
  highlight clear
endif
g:colors_name = 'spacemacs'

# 读取模式：优先 g:spacemacs_theme_mode，否则取 &background
var mode = get(g:, 'spacemacs_theme_mode', &background)
if mode !=# 'dark' && mode !=# 'light'
  mode = &background
endif
&background = mode

# 用户选项
const OPT_BOLD: bool = get(g:, 'spacemacs_theme_bold', true)
const OPT_ITALIC: bool = get(g:, 'spacemacs_theme_italic', true)
const OPT_TRANSPARENT: bool = get(g:, 'spacemacs_theme_transparent', false)

# Spacemacs 仿色板（dark / light）
const PDark = {
  bg: '#292b2e',      ct_bg: 235,
  bg_alt: '#212026',  ct_bg_alt: 234,
  fg: '#b2b2b2',      ct_fg: 249,
  fg_alt: '#dfdfdf',  ct_fg_alt: 252,
  sel: '#444155',     ct_sel: 238,
  comment: '#5b6268', ct_comment: 241,
  red: '#ff6c6b',     ct_red: 203,
  orange: '#da8548',  ct_orange: 173,
  yellow: '#ecbe7b',  ct_yellow: 179,
  green: '#98be65',   ct_green: 107,
  cyan: '#46d9ff',    ct_cyan: 81,
  blue: '#51afef',    ct_blue: 111,
  violet: '#c678dd',  ct_violet: 176,
  magenta: '#a9a1e1', ct_magenta: 146,
  border: '#3f444a',  ct_border: 238,
  shadow: '#1c1f24',  ct_shadow: 234,
}

const PLight = {
  bg: '#fbf8ef',      ct_bg: 230,
  bg_alt: '#f2efe9',  ct_bg_alt: 224,
  fg: '#655370',      ct_fg: 60,
  fg_alt: '#4a4a4a',  ct_fg_alt: 242,
  sel: '#d3d3d3',     ct_sel: 188,
  comment: '#85678f', ct_comment: 96,
  red: '#f2241f',     ct_red: 160,
  orange: '#d75f00',  ct_orange: 208,
  yellow: '#b1951e',  ct_yellow: 136,
  green: '#67b11d',   ct_green: 70,
  cyan: '#2aa1ae',    ct_cyan: 37,
  blue: '#4f97d7',    ct_blue: 74,
  violet: '#a45bad',  ct_violet: 171,
  magenta: '#a0a1c2', ct_magenta: 146,
  border: '#e8e4df',  ct_border: 188,
  shadow: '#e6e3dc',  ct_shadow: 188,
}

const P = mode ==# 'dark' ? PDark : PLight

def HL(group: string, fg: string, bg: string, opts: dict<any>)
  var cmd = 'highlight ' .. group
  if fg != ''     | cmd ..= ' guifg=' .. fg            | endif
  if bg != ''     | cmd ..= ' guibg=' .. bg            | endif
  if has_key(opts, 'ctermfg') | cmd ..= ' ctermfg=' .. string(opts.ctermfg) | endif
  if has_key(opts, 'ctermbg') | cmd ..= ' ctermbg=' .. string(opts.ctermbg) | endif

  var attrs = []
  if get(opts, 'bold', false)      | add(attrs, 'bold')      | endif
  if get(opts, 'italic', false)    | add(attrs, 'italic')    | endif
  if get(opts, 'underline', false) | add(attrs, 'underline') | endif
  if get(opts, 'undercurl', false) | add(attrs, 'undercurl') | endif
  if len(attrs) > 0
    var astr = join(attrs, ',')
    cmd ..= ' gui=' .. astr .. ' cterm=' .. astr
  endif
  if has_key(opts, 'sp')           | cmd ..= ' guisp=' .. opts.sp | endif
  execute cmd
enddef

def Link(from: string, to: string)
  execute 'highlight! link ' .. from .. ' ' .. to
enddef

# 基础组
if OPT_TRANSPARENT
  HL('Normal', P.fg, 'NONE', {ctermfg: P.ct_fg, ctermbg: 'NONE'})
else
  HL('Normal', P.fg, P.bg, {ctermfg: P.ct_fg, ctermbg: P.ct_bg})
endif
HL('NonText', P.comment, 'NONE', {ctermfg: P.ct_comment})
HL('SpecialKey', P.comment, 'NONE', {ctermfg: P.ct_comment})
HL('Conceal', P.comment, 'NONE', {ctermfg: P.ct_comment})
HL('Whitespace', P.border, 'NONE', {ctermfg: P.ct_border})

HL('Comment', P.comment, 'NONE', {ctermfg: P.ct_comment, italic: OPT_ITALIC})
HL('Constant', P.orange, 'NONE', {ctermfg: P.ct_orange})
HL('String', P.green, 'NONE', {ctermfg: P.ct_green})
HL('Character', P.green, 'NONE', {ctermfg: P.ct_green})
HL('Number', P.yellow, 'NONE', {ctermfg: P.ct_yellow})
HL('Boolean', P.yellow, 'NONE', {ctermfg: P.ct_yellow})
HL('Float', P.yellow, 'NONE', {ctermfg: P.ct_yellow})

HL('Identifier', P.cyan, 'NONE', {ctermfg: P.ct_cyan})
HL('Function', P.blue, 'NONE', {ctermfg: P.ct_blue, bold: OPT_BOLD})

HL('Statement', P.violet, 'NONE', {ctermfg: P.ct_violet})
HL('Conditional', P.violet, 'NONE', {ctermfg: P.ct_violet})
HL('Repeat', P.violet, 'NONE', {ctermfg: P.ct_violet})
HL('Label', P.violet, 'NONE', {ctermfg: P.ct_violet})
HL('Operator', P.fg, 'NONE', {ctermfg: P.ct_fg})
HL('Keyword', P.violet, 'NONE', {ctermfg: P.ct_violet, bold: OPT_BOLD})
HL('Exception', P.red, 'NONE', {ctermfg: P.ct_red})

HL('PreProc', P.orange, 'NONE', {ctermfg: P.ct_orange})
HL('Include', P.orange, 'NONE', {ctermfg: P.ct_orange})
HL('Define', P.orange, 'NONE', {ctermfg: P.ct_orange})
HL('Macro', P.orange, 'NONE', {ctermfg: P.ct_orange})
HL('PreCondit', P.orange, 'NONE', {ctermfg: P.ct_orange})

HL('Type', P.green, 'NONE', {ctermfg: P.ct_green})
HL('StorageClass', P.green, 'NONE', {ctermfg: P.ct_green})
HL('Structure', P.green, 'NONE', {ctermfg: P.ct_green})
HL('Typedef', P.green, 'NONE', {ctermfg: P.ct_green})

HL('Special', P.cyan, 'NONE', {ctermfg: P.ct_cyan})
HL('Delimiter', P.fg_alt, 'NONE', {ctermfg: P.ct_fg_alt})
HL('Underlined', P.blue, 'NONE', {ctermfg: P.ct_blue, underline: true})
HL('Ignore', P.border, 'NONE', {ctermfg: P.ct_border})
HL('Error', P.bg, P.red, {ctermfg: P.ct_bg, ctermbg: P.ct_red, bold: OPT_BOLD})
HL('Todo', P.yellow, 'NONE', {ctermfg: P.ct_yellow, bold: OPT_BOLD})

# UI
HL('CursorLine', 'NONE', P.bg_alt, {ctermbg: P.ct_bg_alt})
HL('CursorColumn', 'NONE', P.bg_alt, {ctermbg: P.ct_bg_alt})
HL('ColorColumn', 'NONE', P.bg_alt, {ctermbg: P.ct_bg_alt})

HL('LineNr', P.border, 'NONE', {ctermfg: P.ct_border})
HL('CursorLineNr', P.blue, 'NONE', {ctermfg: P.ct_blue, bold: OPT_BOLD})
HL('SignColumn', P.fg, 'NONE', {ctermfg: P.ct_fg})
HL('FoldColumn', P.blue, 'NONE', {ctermfg: P.ct_blue})
HL('Folded', P.comment, P.bg_alt, {ctermfg: P.ct_comment, ctermbg: P.ct_bg_alt})

# 分割线：Neovim 用 WinSeparator，否则 VertSplit
if has('nvim')
  HL('WinSeparator', P.border, 'NONE', {ctermfg: P.ct_border})
else
  HL('VertSplit', P.border, 'NONE', {ctermfg: P.ct_border})
endif

HL('StatusLine', P.fg, P.bg_alt, {ctermfg: P.ct_fg, ctermbg: P.ct_bg_alt, bold: OPT_BOLD})
HL('StatusLineNC', P.comment, P.bg_alt, {ctermfg: P.ct_comment, ctermbg: P.ct_bg_alt})

HL('Visual', 'NONE', P.sel, {ctermbg: P.ct_sel})
HL('MatchParen', P.yellow, P.bg_alt, {ctermfg: P.ct_yellow, ctermbg: P.ct_bg_alt, bold: OPT_BOLD})

HL('Pmenu', P.fg, P.bg_alt, {ctermfg: P.ct_fg, ctermbg: P.ct_bg_alt})
HL('PmenuSel', P.bg, P.blue, {ctermfg: P.ct_bg, ctermbg: P.ct_blue, bold: OPT_BOLD})
HL('PmenuSbar', 'NONE', P.border, {ctermbg: P.ct_border})
HL('PmenuThumb', 'NONE', P.sel, {ctermbg: P.ct_sel})

HL('Search', P.bg, P.yellow, {ctermfg: P.ct_bg, ctermbg: P.ct_yellow, bold: OPT_BOLD})
HL('IncSearch', P.bg, P.orange, {ctermfg: P.ct_bg, ctermbg: P.ct_orange, bold: OPT_BOLD})

HL('Directory', P.blue, 'NONE', {ctermfg: P.ct_blue})
HL('Title', P.blue, 'NONE', {ctermfg: P.ct_blue, bold: OPT_BOLD})
HL('ErrorMsg', P.bg, P.red, {ctermfg: P.ct_bg, ctermbg: P.ct_red, bold: OPT_BOLD})
HL('WarningMsg', P.orange, 'NONE', {ctermfg: P.ct_orange})
HL('MoreMsg', P.green, 'NONE', {ctermfg: P.ct_green})
HL('ModeMsg', P.fg, 'NONE', {ctermfg: P.ct_fg})
HL('Question', P.green, 'NONE', {ctermfg: P.ct_green})

# Float
HL('NormalFloat', P.fg, P.bg_alt, {ctermfg: P.ct_fg, ctermbg: P.ct_bg_alt})
HL('FloatBorder', P.border, P.bg_alt, {ctermfg: P.ct_border, ctermbg: P.ct_bg_alt})

# Diff
HL('DiffAdd', P.green, P.bg_alt, {ctermfg: P.ct_green, ctermbg: P.ct_bg_alt})
HL('DiffChange', P.blue, P.bg_alt, {ctermfg: P.ct_blue, ctermbg: P.ct_bg_alt})
HL('DiffDelete', P.red, P.bg_alt, {ctermfg: P.ct_red, ctermbg: P.ct_bg_alt})
HL('DiffText', P.orange, P.bg_alt, {ctermfg: P.ct_orange, ctermbg: P.ct_bg_alt, bold: OPT_BOLD})

# Diagnostics / LSP（Neovim）
HL('DiagnosticError', P.red, 'NONE', {ctermfg: P.ct_red, undercurl: true, sp: P.red})
HL('DiagnosticWarn', P.orange, 'NONE', {ctermfg: P.ct_orange, undercurl: true, sp: P.orange})
HL('DiagnosticInfo', P.blue, 'NONE', {ctermfg: P.ct_blue, undercurl: true, sp: P.blue})
HL('DiagnosticHint', P.cyan, 'NONE', {ctermfg: P.ct_cyan, undercurl: true, sp: P.cyan})
HL('DiagnosticOk', P.green, 'NONE', {ctermfg: P.ct_green})

HL('DiagnosticUnderlineError', 'NONE', 'NONE', {undercurl: true, sp: P.red})
HL('DiagnosticUnderlineWarn', 'NONE', 'NONE', {undercurl: true, sp: P.orange})
HL('DiagnosticUnderlineInfo', 'NONE', 'NONE', {undercurl: true, sp: P.blue})
HL('DiagnosticUnderlineHint', 'NONE', 'NONE', {undercurl: true, sp: P.cyan})

# GitSigns（如安装 gitsigns）
HL('GitSignsAdd', P.green, 'NONE', {ctermfg: P.ct_green})
HL('GitSignsChange', P.blue, 'NONE', {ctermfg: P.ct_blue})
HL('GitSignsDelete', P.red, 'NONE', {ctermfg: P.ct_red})

# Tabline
HL('TabLine', P.comment, P.bg_alt, {ctermfg: P.ct_comment, ctermbg: P.ct_bg_alt})
HL('TabLineSel', P.fg, P.bg_alt, {ctermfg: P.ct_fg, ctermbg: P.ct_bg_alt, bold: OPT_BOLD})
HL('TabLineFill', P.comment, P.bg_alt, {ctermfg: P.ct_comment, ctermbg: P.ct_bg_alt})

# Treesitter（Neovim）
if has('nvim')
  Link('@comment', 'Comment')
  Link('@constant', 'Constant')
  Link('@string', 'String')
  Link('@character', 'Character')
  Link('@number', 'Number')
  Link('@boolean', 'Boolean')
  Link('@float', 'Float')
  Link('@variable', 'Identifier')
  Link('@field', 'Identifier')
  Link('@function', 'Function')
  Link('@method', 'Function')
  Link('@keyword', 'Keyword')
  Link('@operator', 'Operator')
  Link('@type', 'Type')
  Link('@type.builtin', 'Type')
  Link('@punctuation.delimiter', 'Delimiter')
  Link('@punctuation.bracket', 'Delimiter')
  Link('@tag', 'Special')
endif
