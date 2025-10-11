; functions
(function_declaration name: (identifier) @symbol.function)

; class
(class_declaration name: (identifier) @symbol.class)

; methods in class
(method_definition name: (property_identifier) @symbol.method)

; top-level variables (const/let/var) - optional, can be noisy
(program
  (variable_declaration
    (variable_declarator name: (identifier) @symbol.variable)))
