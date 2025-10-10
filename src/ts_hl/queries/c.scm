; ----- comments -----
(comment) @comment

; ----- preprocessor -----
(preproc_directive) @macro
(preproc_include) @macro
(preproc_def) @macro
(preproc_function_def) @macro

; ----- strings / chars -----
(string_literal) @string
(char_literal) @string
(escape_sequence) @string.escape

; ----- numbers -----
(number_literal) @number

; ----- keywords -----
"if" @keyword
"else" @keyword
"switch" @keyword
"case" @keyword
"default" @keyword
"while" @keyword
"do" @keyword
"for" @keyword
"break" @keyword
"continue" @keyword
"return" @keyword
"goto" @keyword
"sizeof" @keyword
"typedef" @keyword
"struct" @keyword
"union" @keyword
"enum" @keyword
"static" @keyword
"extern" @keyword
"const" @keyword
"volatile" @keyword
"register" @keyword
"auto" @keyword
"inline" @keyword
"restrict" @keyword

; ----- types -----
(primitive_type) @type.builtin
(type_identifier) @type
(sized_type_specifier) @type.builtin

; ----- functions -----
(function_declarator declarator: (identifier) @function)
(function_definition declarator: (function_declarator declarator: (identifier) @function))
(call_expression function: (identifier) @function)

; ----- parameters -----
(parameter_declaration declarator: (identifier) @variable.parameter)
(parameter_declaration declarator: (pointer_declarator declarator: (identifier) @variable.parameter))

; ----- fields / members -----
(field_identifier) @field
(field_expression field: (field_identifier) @field)

; ----- constants -----
((identifier) @constant
  (#match? @constant "^[A-Z_][A-Z0-9_]*$"))

; ----- operators / punctuation -----
"=" @operator
"==" @operator
"!=" @operator
"<" @operator
">" @operator
"<=" @operator
">=" @operator
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"&&" @operator
"||" @operator
"!" @operator
"&" @operator
"|" @operator
"^" @operator
"~" @operator
"<<" @operator
">>" @operator
"+=" @keyword.operator
"-=" @keyword.operator
"*=" @keyword.operator
"/=" @keyword.operator
"%=" @keyword.operator
"&=" @keyword.operator
"|=" @keyword.operator
"^=" @keyword.operator
"<<=" @keyword.operator
">>=" @keyword.operator
"++" @operator
"--" @operator
"->" @operator

"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter

; ----- fallback -----
(identifier) @variable
