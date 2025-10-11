use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use tree_sitter::StreamingIterator;

mod queries;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "highlight")]
    Highlight { buf: i64, lang: String, text: String },
    #[serde(rename = "symbols")]
    Symbols { buf: i64, lang: String, text: String },
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "highlights")]
    Highlights { buf: i64, spans: Vec<Span> },
    #[serde(rename = "symbols")]
    Symbols { buf: i64, symbols: Vec<Symbol> },
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

#[derive(Debug, Serialize, Clone)]
struct Symbol {
    name: String,
    kind: String,
    lnum: u32,
    col: u32,
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
                send(&mut out, &Event::Error { message: format!("invalid request: {e}") })?;
                continue;
            }
        };
        match req {
            Request::Highlight { buf, lang, text } => match run_highlight(&lang, &text) {
                Ok(spans) => send(&mut out, &Event::Highlights { buf, spans })?,
                Err(e) => send(&mut out, &Event::Error { message: e.to_string() })?,
            },
            Request::Symbols { buf, lang, text } => match run_symbols(&lang, &text) {
                Ok(symbols) => send(&mut out, &Event::Symbols { buf, symbols })?,
                Err(e) => send(&mut out, &Event::Error { message: e.to_string() })?,
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
        "rust" => (tree_sitter_rust::LANGUAGE, queries::RUST_QUERY),
        "javascript" => (tree_sitter_javascript::LANGUAGE, queries::JS_QUERY),
        "c" => (tree_sitter_c::LANGUAGE, queries::C_QUERY),
        "cpp" => (tree_sitter_cpp::LANGUAGE, queries::CPP_QUERY),
        _ => return Err(anyhow!("unsupported language: {lang}")),
    };
    parser.set_language(&language.into())?;

    let tree = parser.parse(text, None).ok_or_else(|| anyhow!("parse failed"))?;
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

fn run_symbols(lang: &str, text: &str) -> Result<Vec<Symbol>> {
    let mut parser = tree_sitter::Parser::new();

    let (language, query_src) = match lang {
        "rust" => (tree_sitter_rust::LANGUAGE, queries::RUST_SYM_QUERY),
        "javascript" => (tree_sitter_javascript::LANGUAGE, queries::JS_SYM_QUERY),
        "c" => (tree_sitter_c::LANGUAGE, queries::C_SYM_QUERY),
        "cpp" => (tree_sitter_cpp::LANGUAGE, queries::CPP_SYM_QUERY),
        _ => return Err(anyhow!("unsupported language: {lang}")),
    };
    parser.set_language(&language.into())?;

    let tree = parser.parse(text, None).ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();

    let query = tree_sitter::Query::new(&language.into(), query_src)?;
    let mut cursor = tree_sitter::QueryCursor::new();

    let mut symbols = Vec::with_capacity(256);
    let bytes = text.as_bytes();

    let mut it = cursor.captures(&query, root, bytes);
    while let Some((m, cap_ix)) = it.next() {
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let cname = query.capture_names()[cap.index as usize];

        // 只处理名字节点的捕获（symbol.*）
        let kind = map_symbol_capture(cname);
        if kind.is_empty() {
            continue;
        }

        let name = node_text(node, bytes);
        let sp = node.start_position();
        symbols.push(Symbol {
            name,
            kind: kind.to_string(),
            lnum: sp.row as u32 + 1,
            col: sp.column as u32 + 1,
        });
    }

    // 按位置排序，便于阅读
    symbols.sort_by_key(|s| (s.lnum, s.col));
    Ok(symbols)
}

fn node_text(node: tree_sitter::Node, bytes: &[u8]) -> String {
    let s = &bytes[node.start_byte() as usize..node.end_byte() as usize];
    String::from_utf8_lossy(s).to_string()
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

fn map_symbol_capture(name: &str) -> &'static str {
    match name {
        // 统一使用 name 节点的捕获类别
        "symbol.function" => "function",
        "symbol.method" => "method",
        "symbol.type" => "type",
        "symbol.struct" => "struct",
        "symbol.enum" => "enum",
        "symbol.class" => "class",
        "symbol.namespace" => "namespace",
        "symbol.variable" => "variable",
        "symbol.const" => "const",
        "symbol.macro" => "macro",
        "symbol.property" => "property",
        "symbol.field" => "field",
        _ => "",
    }
}
