; vim_symbols.scm — symbols for your custom Vim9 grammar (grammar.js)

; 函数（Vim9: def ... enddef）
(def_function (identifier) @symbol.function)

; 变量/常量声明
(let_statement   (identifier) @symbol.variable)
(const_statement (identifier) @symbol.const)

; 作用域/选项变量（如 g:foo / &opt）按变量记
(scope_var)  @symbol.variable
(option_var) @symbol.variable
<<<<<<< HEAD

; 如需把顶层命令名也作为“命名空间/宏”等，可按需扩展：
; (command_name) @symbol.namespace
