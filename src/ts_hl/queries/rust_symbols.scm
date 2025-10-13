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

; 仅显示“自己定义的宏”（macro_rules!），不显示调用站点
(macro_definition name: (identifier) @symbol.macro)

; fields (struct fields)
(field_declaration name: (field_identifier) @symbol.field)

; enum variants（注意此处为 enum_variant_list，而非 enum_body）
(enum_item
  (enum_variant_list
    (enum_variant name: (identifier) @symbol.variant)))

; enum variant named fields（结构式变体里的具名字段）
(enum_item
  (enum_variant_list
    (enum_variant
      (field_declaration_list
        (field_declaration name: (field_identifier) @symbol.field)))))
