" Force-compile every def in a plugin's autoload scripts.
"
" VENDORED FILE — DO NOT EDIT IN PLACE.  Canonical copy: .simplecore/.
"
" Vim9 compiles def bodies lazily, so a syntax or type error in a rarely-taken
" branch stays invisible until a user happens to reach it.  :defcompile forces
" the whole script through the compiler at test time instead.  This is how the
" E723 that made simplecc's WsSymbolFilter permanently uncompilable was found.
"
" Run:  vim -Nu NONE -n -i NONE -es -S tests/defcompile.vim
"
" Scripts that are not meant to compile standalone (colour-scheme helpers with
" deliberately lowercase function names, for instance) can be excluded by
" listing basename globs, one per line, in tests/defcompile-skip, or via
" $SIMPLECORE_SKIP as a comma-separated list.

set nocompatible
set nomore

let s:root = $SIMPLECORE_ROOT
if s:root ==# ''
  " Default to the repository this file was vendored into, so the check works
  " in a lone clone with no sibling checkouts present.
  let s:root = fnamemodify(expand('<sfile>:p'), ':h:h')
endif
execute 'set runtimepath^=' .. fnameescape(s:root)
call delete(s:root .. '/tests/defcompile-errors.log')

let s:skip = filter(split($SIMPLECORE_SKIP, ','), {_, v -> v !=# ''})
let s:skipfile = s:root .. '/tests/defcompile-skip'
if filereadable(s:skipfile)
  " Comments and blank lines are ignored so the file can explain itself.
  call extend(s:skip, filter(map(readfile(s:skipfile), {_, v -> trim(v)}),
        \ {_, v -> v !=# '' && v[0] !=# '#'}))
endif

" The autoload scripts read configuration whose defaults the plugin file
" installs, so load that first — otherwise every g: lookup is undefined.
for s:p in glob(s:root .. '/plugin/**/*.vim', 0, 1)
  try
    execute 'source ' .. fnameescape(s:p)
  catch
    " A plugin file that refuses to load is the smoke test's problem, not this
    " one's; keep going so the compile results still get reported.
  endtry
endfor

let s:errors = []
for s:f in glob(s:root .. '/autoload/**/*.vim', 0, 1)
  let s:base = fnamemodify(s:f, ':t')
  let s:skipped = 0
  for s:pat in s:skip
    if s:base =~# glob2regpat(s:pat)
      let s:skipped = 1
      break
    endif
  endfor
  if s:skipped
    continue
  endif

  " Source a copy with a trailing :defcompile — the original may already be
  " loaded, and re-sourcing it under its own name is a no-op for scripts that
  " guard against reloading.
  let s:tmp = tempname() .. '.vim'
  call writefile(readfile(s:f) + ['defcompile'], s:tmp)
  try
    execute 'source ' .. fnameescape(s:tmp)
  catch
    call add(s:errors, s:base .. ': ' .. v:exception)
  endtry
  call delete(s:tmp)
endfor

if len(s:errors)
  for s:e in s:errors
    echomsg s:e
  endfor
  call writefile(s:errors, s:root .. '/tests/defcompile-errors.log')
  cquit
endif
qall!
