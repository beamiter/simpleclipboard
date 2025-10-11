; 字符串/数字/标识符
(string_literal) @string
(integer_literal) @number
(identifier) @variable

; 关键词（按 AST 中出现的字面量 token）
"if" @keyword
"else" @keyword
"endif" @keyword
"for" @keyword
"endfor" @keyword
"return" @keyword
"set" @keyword
"setlocal" @keyword
"execute" @keyword
"source" @keyword
"colorscheme" @keyword
"autocmd" @keyword
"augroup" @keyword
"command" @keyword
"silent" @keyword
"call" @keyword
"map" @keyword
"nmap" @keyword
"vmap" @keyword
"xmap" @keyword
"nnoremap" @keyword
"inoremap" @keyword
"vnoremap" @keyword
"tnoremap" @keyword
"noremap" @keyword

; 括号/分隔符/运算符（按 AST 中出现的）
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket

","  @punctuation.delimiter
"."  @punctuation.delimiter

"="  @operator
"==" @operator
"!=" @operator
">"  @operator
"<"  @operator
">=" @operator
"<=" @operator
"||" @operator
