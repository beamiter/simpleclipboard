; ============================================
; C++ Tree-sitter Query - Compatible Fix
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

; Preprocessor paths (避免使用 path 字段，直接匹配子节点)
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

; ----- Null & This -----
(null) @constant.builtin
(this) @variable.builtin

; ----- Type Specifiers -----
(primitive_type) @type.builtin
(type_identifier) @type
(sized_type_specifier) @type.builtin
(placeholder_type_specifier) @type.builtin

; Qualified types (不使用 scope/name 字段，直接匹配子节点)
(qualified_identifier (namespace_identifier) @namespace)
(qualified_identifier (type_identifier) @type)

; Template types（不使用 name 字段）
(template_type (type_identifier) @type)

; ----- Namespaces -----
(namespace_identifier) @namespace

; namespace 定义（不使用 name 字段）
(namespace_definition (identifier) @namespace)

; using 声明中的命名空间（不使用 scope 字段）
(using_declaration
  (qualified_identifier (namespace_identifier) @namespace))

; ----- Keywords -----
; 说明：你的关键词目前用 identifier + #match? 的方式，这在 C++ 中很多关键字有独立的词法，不会被解析成 identifier。
; 如果需要更准确的关键词高亮，建议直接按字面匹配（例如 "class" @keyword）。
; 为保持原文件结构，暂不改动这块，只提醒其可能匹配不到。

((identifier) @keyword
  (#match? @keyword "^(class|struct|union|enum)$"))

((identifier) @keyword
  (#match? @keyword "^(namespace|using)$"))

((identifier) @keyword
  (#match? @keyword "^(template|typename)$"))

((identifier) @keyword
  (#match? @keyword "^(typedef)$"))

((identifier) @keyword
  (#match? @keyword "^(public|private|protected)$"))

((identifier) @keyword
  (#match? @keyword "^(virtual|override|final|explicit|inline|static|extern|friend)$"))

((identifier) @keyword
  (#match? @keyword "^(new|delete)$"))

((identifier) @keyword
  (#match? @keyword "^(try|catch|throw|noexcept)$"))

((identifier) @keyword
  (#match? @keyword "^(constexpr|consteval|constinit|decltype|concept|requires)$"))

((identifier) @keyword
  (#match? @keyword "^(co_await|co_return|co_yield)$"))

((identifier) @keyword
  (#match? @keyword "^(const|volatile|mutable|register|restrict)$"))

((identifier) @keyword
  (#match? @keyword "^(if|else|switch|case|default|while|do|for|break|continue|return|goto)$"))

((identifier) @keyword
  (#match? @keyword "^(sizeof|static_assert|operator)$"))

((identifier) @constant.builtin
  (#eq? @constant.builtin "nullptr"))

; ----- Functions & Methods -----

; Function declarations
(function_declarator (identifier) @function)
(function_declarator (qualified_identifier (identifier) @function))
(function_declarator (field_identifier) @function)

; Function definitions
(function_definition
  (function_declarator (identifier) @function))

(function_definition
  (function_declarator
    (qualified_identifier (identifier) @function)))

; Method definitions
(function_definition
  (function_declarator (field_identifier) @method))

; Constructor/Destructor
(function_definition
  (function_declarator (destructor_name) @function))

; Template functions
(template_declaration
  (function_definition
    (function_declarator (identifier) @function)))

; Function calls
(call_expression
  (identifier) @function)

(call_expression
  (qualified_identifier (identifier) @function))

; Method calls
(call_expression
  (field_expression (field_identifier) @method))

; ----- Parameters -----
(parameter_declaration (identifier) @variable.parameter)
(parameter_declaration (pointer_declarator (identifier) @variable.parameter))
(parameter_declaration (reference_declarator (identifier) @variable.parameter))
(optional_parameter_declaration (identifier) @variable.parameter)

; ----- Fields & Properties -----
(field_identifier) @field
(field_expression (field_identifier) @field)

; 说明：不同版本 grammar 中 field_declaration 的结构可能是
; field_declaration -> (field_declarator -> (field_identifier))
; 因此直接匹配 field_declaration 的 declarator 字段可能不适用，改为更通用的匹配：
(field_declaration (field_declarator (field_identifier) @field))
(field_declaration (field_identifier) @field)

; ----- Variables -----
(declaration (identifier) @variable)
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
