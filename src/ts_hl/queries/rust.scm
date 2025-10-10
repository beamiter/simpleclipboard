; ----- comments -----
(line_comment) @comment
(block_comment) @comment

; ----- strings -----
(string_literal) @string
(char_literal) @string
(raw_string_literal) @string

; ----- numbers, bool -----
(integer_literal) @number
(float_literal) @number
(boolean_literal) @boolean  ; 正确：这是节点类型

; ----- keywords -----
((identifier) @keyword
  (#match? @keyword "^(let|fn|mod|struct|enum|impl|trait|for|while|loop|if|else|match|return|use|pub|const|static|mut|ref|as|where|in|move|unsafe|async|await|dyn|crate|super|self)$"))

; ----- functions / methods / types -----
(function_item name: (identifier) @function)
(call_expression function: (identifier) @function)
(call_expression
  function: (field_expression
              field: (field_identifier) @method))
(type_identifier) @type
(primitive_type) @type.builtin

; ----- parameters -----
(parameter pattern: (identifier) @variable.parameter)
(closure_parameters (identifier) @variable.parameter)

; ----- fields -----
(field_identifier) @field

; ----- macros / attributes / lifetime -----
(macro_invocation macro: (identifier) @macro)
(attribute_item) @attribute
(lifetime) @type.builtin

; ----- punctuation / operators -----
"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket

"," @punctuation.delimiter
"." @punctuation.delimiter
";" @punctuation.delimiter
":" @punctuation.delimiter
"::" @operator
"->" @operator
"=>" @operator
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

; ----- fallback variables -----
(identifier) @variable
