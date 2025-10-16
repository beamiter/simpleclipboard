; Vim9 symbols for your custom grammar (grammar.js)

; 函数（Vim9: def ... enddef）
; grammar.js: def_function 直接包含 (identifier)
(def_function (identifier) @symbol.function)

; 变量/常量声明（顶层或函数内）
(let_statement   (identifier) @symbol.variable)
(const_statement (identifier) @symbol.const)

; 作用域/选项变量（例如 v:true、&opt）
(scope_var)  @symbol.variable
(option_var) @symbol.variable
