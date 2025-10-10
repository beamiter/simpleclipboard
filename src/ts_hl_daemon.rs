use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use tree_sitter::StreamingIterator;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "highlight")]
    Highlight {
        buf: i64,
        lang: String,
        text: String,
    },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "highlights")]
    Highlights { buf: i64, spans: Vec<Span> },
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Serialize, Clone)]
struct Span {
    lnum: u32,
    col: u32,
    end_lnum: u32,
    end_col: u32,
    group: String,
}

fn main() -> Result<()> {
    let stdin = std::io::stdin();
    let mut lines = BufReader::new(stdin).lines();
    let mut out = std::io::stdout();

    while let Some(line) = lines.next() {
        let line = match line {
            Ok(s) => s,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let req = match serde_json::from_str::<Request>(&line) {
            Ok(r) => r,
            Err(e) => {
                send(
                    &mut out,
                    &Event::Error {
                        message: format!("invalid request: {e}"),
                    },
                )?;
                continue;
            }
        };
        match req {
            Request::Highlight { buf, lang, text } => match run_highlight(&lang, &text) {
                Ok(spans) => send(&mut out, &Event::Highlights { buf, spans })?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                    },
                )?,
            },
        }
    }

    Ok(())
}

fn send(out: &mut std::io::Stdout, ev: &Event) -> Result<()> {
    let js = serde_json::to_string(ev)?;
    out.write_all(js.as_bytes())?;
    out.write_all(b"\n")?;
    out.flush()?;
    Ok(())
}

fn run_highlight(lang: &str, text: &str) -> Result<Vec<Span>> {
    let mut parser = tree_sitter::Parser::new();

    let (language, query_src) = match lang {
        "rust" => (tree_sitter_rust::LANGUAGE, RUST_QUERY),
        "javascript" => (tree_sitter_javascript::LANGUAGE, JS_QUERY),
        "c" => (tree_sitter_c::LANGUAGE, C_QUERY),
        "cpp" => (tree_sitter_cpp::LANGUAGE, CPP_QUERY),
        _ => return Err(anyhow!("unsupported language: {lang}")),
    };
    parser.set_language(&language.into())?;

    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();

    let query = tree_sitter::Query::new(&language.into(), query_src)?;
    let mut cursor = tree_sitter::QueryCursor::new();

    let mut spans = Vec::with_capacity(2048);

    let mut it = cursor.captures(&query, root, text.as_bytes());
    while let Some((m, cap_ix)) = it.next() {
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let cname = query.capture_names()[cap.index as usize];
        let group = map_capture_to_group(cname).to_string();

        let sp = node.start_position();
        let ep = node.end_position();
        // tree-sitter Point: row/column 0-based, Vim 需要 1-based
        spans.push(Span {
            lnum: sp.row as u32 + 1,
            col: sp.column as u32 + 1,
            end_lnum: ep.row as u32 + 1,
            end_col: ep.column as u32 + 1,
            group,
        });
    }

    Ok(spans)
}

fn map_capture_to_group(name: &str) -> &'static str {
    match name {
        // 基础
        "comment" => "TSComment",
        "string" => "TSString",
        "string.regex" => "TStringRegex",
        "string.escape" => "TStringEscape",
        "string.special" => "TStringSpecial",
        "number" => "TSNumber",
        "boolean" => "TSBoolean",
        "null" => "TSConstant",

        // 关键字/运算符/标点
        "keyword" => "TSKeyword",
        "keyword.operator" => "TSKeywordOperator",
        "operator" => "TSOperator",
        "punctuation.delimiter" => "TSPunctDelimiter",
        "punctuation.bracket" => "TSPunctBracket",

        // 变量/常量/内置
        "variable" => "TSVariable",
        "variable.parameter" => "TSVariableParameter",
        "variable.builtin" => "TSVariableBuiltin",
        "constant" => "TSConstant",
        "constant.builtin" => "TSConstBuiltin",

        // 成员/属性/字段
        "property" => "TSProperty",
        "field" => "TSField",

        // 函数/方法/内置
        "function" => "TSFunction",
        "method" => "TSMethod",
        "function.builtin" => "TSFunctionBuiltin",

        // 类型/命名空间/宏/属性
        "type" => "TSType",
        "type.builtin" => "TSTypeBuiltin",
        "namespace" => "TSNamespace",
        "macro" => "TSMacro",
        "attribute" => "TSAttribute",

        // 默认兜底
        _ => "TSVariable",
    }
}

// =============== Rust Query ===============
static RUST_QUERY: &str = r#"
; ----- comments -----
(line_comment) @comment
(block_comment) @comment

; ----- strings -----
(string_literal) @string
(char_literal) @string
(raw_string_literal) @string

; ----- numbers, bool -----
(integer_literal) @number
(float_literal) @number
(boolean_literal) @boolean

; ----- keywords -----
((identifier) @keyword
  (#match? @keyword "^(let|fn|mod|struct|enum|impl|trait|for|while|loop|if|else|match|return|use|pub|const|static|mut|ref|as|where|in|move|unsafe|async|await)$"))

; ----- functions / methods / types -----
(function_item name: (identifier) @function)
(call_expression function: (identifier) @function)
(call_expression
  function: (field_expression
              field: (field_identifier) @method))
(type_identifier) @type
(primitive_type) @type.builtin

; ----- parameters -----
(parameter (identifier) @variable.parameter)
(closure_parameters (identifier) @variable.parameter)

; ----- fields -----
(field_identifier) @field

; ----- macros / attributes / lifetime -----
(macro_invocation) @macro
(macro_invocation macro: (identifier) @macro)
(attribute) @attribute
(attribute_item) @attribute
(lifetime) @type.builtin

; ----- punctuation / operators -----
"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket

"," @punctuation.delimiter
"." @punctuation.delimiter
";" @punctuation.delimiter
":" @punctuation.delimiter
"->" @operator
"=>" @operator
"=" @operator
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
"&&" @operator
"||" @operator
"!" @operator

; ----- fallback variables -----
(identifier) @variable
"#;

// =============== JavaScript Query ===============
static JS_QUERY: &str = r#"
; ----- comments -----
(comment) @comment

; ----- strings / regex / escapes -----
(string) @string
(template_string) @string
(escape_sequence) @string.escape
(regex) @string.regex
(template_substitution) @string.special

; ----- numbers / booleans / null -----
(number) @number
(true) @boolean
(false) @boolean
(null) @constant

; ----- keywords -----
"var" @keyword
"let" @keyword
"const" @keyword
"function" @keyword
"return" @keyword
"if" @keyword
"else" @keyword
"for" @keyword
"while" @keyword
"do" @keyword
"switch" @keyword
"case" @keyword
"break" @keyword
"continue" @keyword
"new" @keyword
"try" @keyword
"catch" @keyword
"finally" @keyword
"throw" @keyword
"class" @keyword
"extends" @keyword
"super" @keyword
"import" @keyword
"from" @keyword
"export" @keyword
"default" @keyword
"in" @keyword
"of" @keyword
"instanceof" @keyword
"this" @keyword
"typeof" @keyword
"void" @keyword
"delete" @keyword
"yield" @keyword
"await" @keyword

; ----- operators -----
"=" @keyword.operator
"+=" @keyword.operator
"-=" @keyword.operator
"*=" @keyword.operator
"/=" @keyword.operator
"%=" @keyword.operator
"**=" @keyword.operator
"==" @operator
"===" @operator
"!=" @operator
"!==" @operator
"<" @operator
"<=" @operator
">" @operator
">=" @operator
"+" @operator
"-" @operator
"*" @operator
"/" @operator
"%" @operator
"**" @operator
"&&" @operator
"||" @operator
"!" @operator
"??" @operator
"??=" @keyword.operator
"&&=" @keyword.operator
"||=" @keyword.operator
"=>" @operator

; ----- punctuation -----
"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket

"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter
":" @punctuation.delimiter
"?" @punctuation.delimiter

; ----- functions / methods / classes -----
(function_declaration name: (identifier) @function)
(function name: (identifier) @function)
(method_definition name: (property_identifier) @method)
(class_declaration name: (identifier) @type)

(lexical_declaration
  (variable_declarator
    name: (identifier) @function
    value: (arrow_function)))

(call_expression function: (identifier) @function)

; ----- parameters -----
(formal_parameters (identifier) @variable.parameter)
(formal_parameters (rest_pattern (identifier) @variable.parameter))
(arrow_function parameters: (identifier) @variable.parameter)

; ----- properties / fields -----
(pair key: (property_identifier) @property)
(pair key: (identifier) @property)
(member_expression property: (property_identifier) @property)

; ----- builtins -----
((identifier) @variable.builtin
  (#match? @variable.builtin "^(undefined|arguments|NaN|Infinity)$"))

((identifier) @constant.builtin
  (#match? @constant.builtin "^(console|JSON|Math|Date|Number|String|Boolean|Array|Object|RegExp|Error|Promise|Symbol|BigInt)$"))

; ----- fallback -----
(identifier) @variable
"#;

// =============== C Query ===============
static C_QUERY: &str = r#"
; ----- comments -----
(comment) @comment

; ----- preprocessor -----
(preproc_directive) @macro
(preproc_include) @macro
(preproc_def) @macro
(preproc_function_def) @macro

; ----- strings / chars -----
(string_literal) @string
(char_literal) @string
(escape_sequence) @string.escape

; ----- numbers -----
(number_literal) @number

; ----- keywords -----
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
"typedef" @keyword
"struct" @keyword
"union" @keyword
"enum" @keyword
"static" @keyword
"extern" @keyword
"const" @keyword
"volatile" @keyword
"register" @keyword
"auto" @keyword
"inline" @keyword
"restrict" @keyword

; ----- types -----
(primitive_type) @type.builtin
(type_identifier) @type
(sized_type_specifier) @type.builtin

; ----- functions -----
(function_declarator declarator: (identifier) @function)
(function_definition declarator: (function_declarator declarator: (identifier) @function))
(call_expression function: (identifier) @function)

; ----- parameters -----
(parameter_declaration declarator: (identifier) @variable.parameter)
(parameter_declaration declarator: (pointer_declarator declarator: (identifier) @variable.parameter))

; ----- fields / members -----
(field_identifier) @field
(field_expression field: (field_identifier) @field)

; ----- constants -----
((identifier) @constant
  (#match? @constant "^[A-Z_][A-Z0-9_]*$"))

; ----- operators / punctuation -----
"=" @operator
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
"&&" @operator
"||" @operator
"!" @operator
"&" @operator
"|" @operator
"^" @operator
"~" @operator
"<<" @operator
">>" @operator
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
"++" @operator
"--" @operator
"->" @operator

"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter

; ----- fallback -----
(identifier) @variable
"#;

// =============== C++ Query ===============
static CPP_QUERY: &str = r#"
; ----- comments -----
(comment) @comment

; ----- preprocessor -----
(preproc_directive) @macro
(preproc_include) @macro
(preproc_def) @macro

; ----- strings / chars -----
(string_literal) @string
(char_literal) @string
(escape_sequence) @string.escape
(raw_string_literal) @string

; ----- numbers -----
(number_literal) @number

; ----- keywords -----
"class" @keyword
"namespace" @keyword
"using" @keyword
"template" @keyword
"typename" @keyword
"public" @keyword
"private" @keyword
"protected" @keyword
"virtual" @keyword
"override" @keyword
"final" @keyword
"explicit" @keyword
"friend" @keyword
"operator" @keyword
"new" @keyword
"delete" @keyword
"this" @keyword
"nullptr" @constant.builtin
"true" @boolean
"false" @boolean
"try" @keyword
"catch" @keyword
"throw" @keyword
"noexcept" @keyword
"constexpr" @keyword
"static_assert" @keyword
"decltype" @keyword
"auto" @keyword
"concept" @keyword
"requires" @keyword
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
"typedef" @keyword
"struct" @keyword
"union" @keyword
"enum" @keyword
"static" @keyword
"extern" @keyword
"const" @keyword
"volatile" @keyword
"register" @keyword
"inline" @keyword
"restrict" @keyword

; ----- types -----
(primitive_type) @type.builtin
(type_identifier) @type
(sized_type_specifier) @type.builtin
(qualified_identifier) @type

; ----- namespace -----
(namespace_identifier) @namespace

; ----- functions / methods -----
(function_declarator declarator: (identifier) @function)
(function_declarator declarator: (qualified_identifier name: (identifier) @function))
(function_definition declarator: (function_declarator declarator: (identifier) @function))
(call_expression function: (identifier) @function)
(call_expression function: (qualified_identifier name: (identifier) @function))
(call_expression function: (field_expression field: (field_identifier) @method))

; ----- parameters -----
(parameter_declaration declarator: (identifier) @variable.parameter)
(parameter_declaration declarator: (pointer_declarator declarator: (identifier) @variable.parameter))
(parameter_declaration declarator: (reference_declarator value: (identifier) @variable.parameter))

; ----- fields / properties -----
(field_identifier) @field
(field_expression field: (field_identifier) @field)

; ----- operators / punctuation -----
"=" @operator
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
"&&" @operator
"||" @operator
"!" @operator
"&" @operator
"|" @operator
"^" @operator
"~" @operator
"<<" @operator
">>" @operator
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
"++" @operator
"--" @operator
"->" @operator
"::" @operator

"(" @punctuation.bracket
")" @punctuation.bracket
"{" @punctuation.bracket
"}" @punctuation.bracket
"[" @punctuation.bracket
"]" @punctuation.bracket
"," @punctuation.delimiter
";" @punctuation.delimiter
"." @punctuation.delimiter
":" @punctuation.delimiter

; ----- fallback -----
(identifier) @variable
"#;
