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

; only macro definitions (macro_rules!), not call sites
(macro_definition name: (identifier) @symbol.macro)

; struct fields: 仅匹配出现在 struct_item 里的具名字段，避免与枚举变体字段重叠
(struct_item
  (field_declaration_list
    (field_declaration name: (field_identifier) @symbol.field)))

; enum variants
(enum_item
  (enum_variant_list
    (enum_variant name: (identifier) @symbol.variant)))

; enum variant named fields（结构式变体里的具名字段）
(enum_item
  (enum_variant_list
    (enum_variant
      (field_declaration_list
        (field_declaration name: (field_identifier) @symbol.field)))))

(vim9_assignment_statement
  (scoped_identifier) @symbol.variable)
