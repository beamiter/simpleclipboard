; 用户自定义命令
(command_statement
  (command_name) @symbol.macro)

(user_command
  (command_name) @symbol.macro)

; augroup 名称
(augroup_statement
  (augroup_name) @symbol.namespace)

; 可选：colorscheme 的名字（你的 AST 有 name 节点）
(colorscheme_statement
  (name) @symbol.namespace)
