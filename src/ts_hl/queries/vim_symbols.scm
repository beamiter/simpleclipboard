; 函数定义（传统与 Vim9）—— 捕获声明的名字（任意子节点作为名字）
(function_definition
  (function_declaration
    name: (_) @symbol.function))

(vim9_function_definition
  (vim9_function_declaration
    name: (_) @symbol.function))

; 用户命令 —— 把命令名当作“函数”符号
(command_statement
  name: (command_name) @symbol.function)

; augroup 名称当作 namespace
(augroup_statement
  (augroup_name) @symbol.namespace)

; 变量声明（Vim9 var）
(var_statement
  (var_declarator
    name: (_) @symbol.variable)+)
