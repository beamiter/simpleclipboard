; ============================================
; C++ Tree-sitter Query - Compatible Full Version
; ============================================

; ----- Comments -----
(comment) @comment

; ----- Preprocessor -----
(preproc_include) @macro
(preproc_def) @macro
(preproc_function_def) @macro
(preproc_call) @macro
(preproc_ifdef) @macro
(preproc_directive) @macro

; Preprocessor include paths (不使用 path 字段)
(preproc_include (string_literal) @string)
(preproc_include (system_lib_string) @string)

; ----- Strings & Characters -----
(string_literal) @string
(system_lib_string) @string
(char_literal) @string
(raw_string_literal) @string
(escape_sequence) @string.escape

; ----- Numbers -----
(number_literal) @number

; ----- Booleans -----
(true) @boolean
(false) @boolean

; ----- Builtins -----
(this) @variable.builtin
"nullptr" @constant.builtin

; ----- Type Specifiers -----
(primitive_type) @type.builtin
(type_identifier) @type
(placeholder_type_specifier) @type.builtin

; Qualified identifiers/types（不使用字段标签）
(qualified_identifier (namespace_identifier) @namespace)
(qualified_identifier (type_identifier) @type)
(template_type (type_identifier) @type)

; ----- Namespaces -----
(namespace_identifier) @namespace
; 说明：不同版本的 grammar 中 namespace_definition 的名称子节点常被别名为 namespace_identifier，
; 直接匹配 namespace_identifier 更稳妥，避免 Impossible pattern。

; ----- Keywords (字面匹配更稳妥) -----

"class" @keyword
"struct" @keyword
"union" @keyword
"enum" @keyword

"namespace" @keyword
"using" @keyword
"typedef" @keyword

"template" @keyword
"typename" @keyword

"public" @keyword
"private" @keyword
"protected" @keyword

"virtual" @keyword
"override" @keyword
"final" @keyword
"explicit" @keyword
"inline" @keyword
"static" @keyword
"extern" @keyword
"friend" @keyword

"new" @keyword
"delete" @keyword

"try" @keyword
"catch" @keyword
"throw" @keyword
"noexcept" @keyword

"constexpr" @keyword
"consteval" @keyword
"constinit" @keyword
"decltype" @keyword
"concept" @keyword
"requires" @keyword

"co_await" @keyword
"co_return" @keyword
"co_yield" @keyword

"const" @keyword
"volatile" @keyword
"mutable" @keyword
"register" @keyword
"restrict" @keyword

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
"static_assert" @keyword
"operator" @keyword

; ----- Functions & Methods -----

; Declarations
(function_declarator (identifier) @function)
(function_declarator (qualified_identifier (identifier) @function))
(function_declarator (field_identifier) @function)

; Definitions
(function_definition (function_declarator (identifier) @function))
(function_definition (function_declarator (qualified_identifier (identifier) @function)))
(function_definition (function_declarator (field_identifier) @method))
(function_definition (function_declarator (destructor_name) @function))

; Template functions
(template_declaration
  (function_definition (function_declarator (identifier) @function)))

; Calls
(call_expression (identifier) @function)
(call_expression (qualified_identifier (identifier) @function))
(call_expression (field_expression (field_identifier) @method))

; ----- Parameters -----
(parameter_declaration (identifier) @variable.parameter)
(parameter_declaration (pointer_declarator (identifier) @variable.parameter))
(parameter_declaration (reference_declarator (identifier) @variable.parameter))
(optional_parameter_declaration (identifier) @variable.parameter)

; ----- Fields & Properties -----
(field_identifier) @field

(field_expression
  (field_identifier) @field)

; 成员声明（避免不存在的 field_declarator，覆盖常见形态）
(field_declaration (identifier) @field)
(field_declaration (init_declarator (identifier) @field))
(field_declaration (pointer_declarator (identifier) @field))
(field_declaration (reference_declarator (identifier) @field))
(field_declaration (array_declarator (identifier) @field))

; ----- Variables -----
; 覆盖常见局部变量声明形态
(declaration (identifier) @variable)
(declaration (init_declarator (identifier) @variable))
(declaration (pointer_declarator (identifier) @variable))
(declaration (reference_declarator (identifier) @variable))
(declaration (array_declarator (identifier) @variable))
(init_declarator (identifier) @variable)

; ----- Constants -----
((identifier) @constant
  (#match? @constant "^[A-Z][A-Z0-9_]*$"))

(enumerator (identifier) @constant)

; ----- Operators -----

"=" @operator
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
"++" @operator
"--" @operator

"&&" @operator
"||" @operator
"!" @operator

"&" @operator
"|" @operator
"^" @operator
"~" @operator
"<<" @operator
">>" @operator

"->" @operator
"::" @operator

"?" @operator

; ----- Punctuation -----
"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket

";" @punctuation.delimiter
"," @punctuation.delimiter
"." @punctuation.delimiter
":" @punctuation.delimiter

; ----- Fallback -----
(identifier) @variable
