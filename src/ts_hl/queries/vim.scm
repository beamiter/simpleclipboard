; vim.scm — highlight queries for your custom Vim9 grammar (grammar.js)

; 基本字面量/注释
(comment) @comment
(string)  @string
(number)  @number
(float)   @number
(boolean) @boolean

; 标识符与变量
(identifier)   @variable
(scope_var)    @variable
(option_var)   @variable.builtin

; 通用 Ex 命令名（你语法里是命名节点）
(command_name) @keyword

; Vim9 指令（你的语法把 'vim9script' 定义为命名节点）
(vim9script)   @keyword

; 函数声明与调用
(def_function (identifier)      @function)
(call_expression (function_name) @function)
(method_call (identifier)        @method)

; 类型（内建与自定义）
(type (identifier) @type)
(type [
  "bool" "number" "float" "string" "any"
] @type.builtin)

; 字典键/属性
(dict_key (identifier) @property)
(dict_key (string)     @property)

; 特殊按键与管道（均为命名节点）
(special_key) @string.special
(pipe)        @operator

; 括号
[
  "(" ")" "[" "]" "{" "}"
] @punctuation.bracket

; 分隔符
[
  "," ":"
] @punctuation.delimiter

; 运算符（与 grammar.js 中的定义一致）
[
  "->" "=>"
  "!"
  "+" "-" "*" "/"
  "==" "!=" "==#" "!=#" "==?" "!=?"
  "=~" "!~" "=~#" "!~#"
  ">=" "<=" ">" "<"
  ".."
  "&&" "||"
  "="
  "?"
] @operator
