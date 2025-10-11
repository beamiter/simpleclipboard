; comments: 行内以 " 开头（grammar 通常有 comment 节点）
(comment) @comment

; strings / numbers
(string) @string
(number) @number

; keywords：用 identifier 匹配已知关键字
((identifier) @keyword
  (#match? @keyword "^(let|function|endfunction|return|if|endif|elseif|else|for|endfor|while|endwhile|try|catch|finally|endtry|set|autocmd|augroup|end|command|lua|map|noremap|nnoremap|inoremap|vnoremap|tnoremap)$"))

; 括号/分隔符/运算符
"(" @punctuation.bracket
")" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket

"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter

"=" @operator
"==" @operator
"=~" @operator
"!~" @operator
"!=" @operator
