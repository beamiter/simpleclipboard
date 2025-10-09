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
        _ => return Err(anyhow!("unsupported language: {lang}")),
    };
    parser.set_language(&language.into())?;

    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();

    let query = tree_sitter::Query::new(&language.into(), query_src)?;
    let mut cursor = tree_sitter::QueryCursor::new();

    let mut it = cursor.captures(&query, root, text.as_bytes());

    let mut spans = Vec::with_capacity(2048);
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
        "comment" => "TSComment",
        "string" => "TSString",
        "number" => "TSNumber",
        "boolean" => "TSBoolean",
        "keyword" => "TSKeyword",
        "function" => "TSFunction",
        "type" => "TSType",
        "namespace" => "TSNamespace",
        "variable" => "TSVariable",
        _ => "TSVariable",
    }
}

static RUST_QUERY: &str = r#"
; comments
(line_comment) @comment
(block_comment) @comment

; strings
(string_literal) @string
(char_literal) @string
(raw_string_literal) @string

; numbers, bool
(integer_literal) @number
(float_literal) @number
(boolean_literal) @boolean

; keywords via identifier regex (more robust across grammar versions)
((identifier) @keyword
  (#match? @keyword "^(let|fn|mod|struct|enum|impl|trait|for|while|loop|if|else|match|return|use|pub|const|static|mut|ref|as|where|in|move|unsafe|async|await)$"))

; functions and types
(function_item name: (identifier) @function)
(call_expression function: (identifier) @function)
(type_identifier) @type
(primitive_type) @type

; fallback variables (keep after keyword rule to avoid override)
(identifier) @variable
"#;

static JS_QUERY: &str = r#"
(comment) @comment

(string) @string
(template_string) @string

(number) @number

(true) @boolean
(false) @boolean
(null) @constant

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

(function_declaration name: (identifier) @function)
(method_definition name: (property_identifier) @function)

; 变量声明的箭头函数：把变量名当作函数名高亮
(lexical_declaration
  (variable_declarator
    name: (identifier) @function
    value: (arrow_function)))

; 调用处：简单把被调用的标识符当作函数
(call_expression function: (identifier) @function)

(class_declaration name: (identifier) @type)

(identifier) @variable
"#;
