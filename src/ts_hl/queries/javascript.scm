; ----- comments -----
(comment) @comment

; ----- strings / regex / escapes -----
(string) @string
(template_string) @string
(escape_sequence) @string.escape
(regex) @string.regex
(template_substitution) @string.special

; ----- numbers / booleans / null -----
(number) @number
(true) @boolean
(false) @boolean
(null) @constant
(undefined) @constant

; ----- this 表达式 -----
(this) @variable.builtin

; ----- keywords -----
"var" @keyword
"let" @keyword
"const" @keyword
"function" @keyword
"return" @keyword
"if" @keyword
"else" @keyword
"for" @keyword
"while" @keyword
"do" @keyword
"switch" @keyword
"case" @keyword
"break" @keyword
"continue" @keyword
"new" @keyword
"try" @keyword
"catch" @keyword
"finally" @keyword
"throw" @keyword
"class" @keyword
"extends" @keyword
"super" @keyword
"import" @keyword
"from" @keyword
"export" @keyword
"default" @keyword
"in" @keyword
"of" @keyword
"instanceof" @keyword
"typeof" @keyword
"void" @keyword
"delete" @keyword
"yield" @keyword
"await" @keyword
"async" @keyword
"static" @keyword
"get" @keyword
"set" @keyword
"debugger" @keyword
"with" @keyword

; ----- operators -----
"=" @keyword.operator
"+=" @keyword.operator
"-=" @keyword.operator
"*=" @keyword.operator
"/=" @keyword.operator
"%=" @keyword.operator
"**=" @keyword.operator
"==" @operator
"===" @operator
"!=" @operator
"!==" @operator
"<" @operator
"<=" @operator
">" @operator
">=" @operator
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"**" @operator
"&&" @operator
"||" @operator
"!" @operator
"??" @operator
"??=" @keyword.operator
"&&=" @keyword.operator
"||=" @keyword.operator
"=>" @operator

; ----- punctuation -----
"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket

"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter
":" @punctuation.delimiter
"?" @punctuation.delimiter

; ----- functions / methods / classes -----
(function_declaration name: (identifier) @function)
(function name: (identifier) @function)
(method_definition name: (property_identifier) @method)
(class_declaration name: (identifier) @type)

; 箭头函数赋值给变量
(lexical_declaration
  (variable_declarator
    name: (identifier) @function
    value: (arrow_function)))

(variable_declaration
  (variable_declarator
    name: (identifier) @function
    value: (arrow_function)))

; 函数调用
(call_expression function: (identifier) @function)
(call_expression function: (member_expression property: (property_identifier) @method))

; ----- parameters -----
(formal_parameters (identifier) @variable.parameter)
(formal_parameters (rest_pattern (identifier) @variable.parameter))
(arrow_function parameters: (identifier) @variable.parameter)

; ----- properties / fields -----
(pair key: (property_identifier) @property)
(pair key: (string (string_fragment) @property))
(member_expression property: (property_identifier) @property)

; ----- builtins -----
((identifier) @variable.builtin
  (#match? @variable.builtin "^(undefined|arguments|NaN|Infinity)$"))

((identifier) @constant.builtin
  (#match? @constant.builtin "^(console|JSON|Math|Date|Number|String|Boolean|Array|Object|RegExp|Error|Promise|Symbol|BigInt|Map|Set|WeakMap|WeakSet|Proxy|Reflect|globalThis|window|document)$"))

; ----- fallback -----
(identifier) @variable
