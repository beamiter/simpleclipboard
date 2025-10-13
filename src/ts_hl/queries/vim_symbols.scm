; functions (free functions)
(function_item name: (identifier) @symbol.function)

; methods: any function_item that has an impl ancestor
((function_item name: (identifier) @symbol.method)
  (#has-ancestor? @symbol.method impl_item))

; struct / enum / trait / type alias
(struct_item name: (type_identifier) @symbol.struct)
(enum_item   name: (type_identifier) @symbol.enum)
(trait_item  name: (type_identifier) @symbol.type)
(type_item   name: (type_identifier) @symbol.type)

; const / static (top-level)
(const_item  name: (identifier) @symbol.const)
(static_item name: (identifier) @symbol.const)

; module
(mod_item name: (identifier) @symbol.namespace)

; macros (invocation site name)
(macro_invocation macro: (identifier) @symbol.macro)

; fields (struct fields)
(field_declaration name: (field_identifier) @symbol.field)

; enum variants
(enum_item
  (enum_body
    (enum_variant name: (identifier) @symbol.variant)))
