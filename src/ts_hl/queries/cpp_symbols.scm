; functions
(function_definition
  declarator: (function_declarator
                declarator: (identifier) @symbol.function))

; class/struct
(class_specifier name: (type_identifier) @symbol.class)
(struct_specifier name: (type_identifier) @symbol.struct)

; namespace
(namespace_definition name: (namespace_identifier) @symbol.namespace)

; methods inside class
(field_declaration (function_declarator declarator: (field_identifier) @symbol.method))
; Note: depending on grammar, methods can also appear as function_definition under class body
(method_definition name: (field_identifier) @symbol.method)
