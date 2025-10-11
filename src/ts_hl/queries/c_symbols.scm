; functions
(function_definition
  declarator: (function_declarator
                declarator: (identifier) @symbol.function))

; structs
(type_definition declarator: (type_declarator (type_identifier) @symbol.struct))
(struct_specifier name: (type_identifier) @symbol.struct)

; enums
(enum_specifier name: (type_identifier) @symbol.enum)
