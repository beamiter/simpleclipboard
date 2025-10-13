use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Write};
use tree_sitter::StreamingIterator;

mod queries;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "highlight")]
    Highlight {
        buf: i64,
        lang: String,
        text: String,
    },
    #[serde(rename = "symbols")]
    Symbols {
        buf: i64,
        lang: String,
        text: String,
    },
    #[serde(rename = "dump_ast")]
    DumpAst {
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
    #[serde(rename = "symbols")]
    Symbols { buf: i64, symbols: Vec<Symbol> },
    #[serde(rename = "ast")]
    Ast { buf: i64, lines: Vec<String> },
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
    // 新增：符号归属的容器（可选）
    container_kind: Option<String>,
    container_name: Option<String>,
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
            Request::Symbols { buf, lang, text } => match run_symbols(&lang, &text) {
                Ok(symbols) => send(&mut out, &Event::Symbols { buf, symbols })?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                    },
                )?,
            },
            Request::DumpAst { buf, lang, text } => {
                let lines = dump_ast(&lang, &text)?;
                send(&mut out, &Event::Ast { buf, lines })?;
            }
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
    if lang == "vim" {
        if let Ok(spans) = run_ts_query_highlight(text) {
            return Ok(spans);
        } else {
            return Ok(highlight_vim_naive(text));
        }
    }

    let mut parser = tree_sitter::Parser::new();
    let (language, query_src) = match lang {
        "rust" => (tree_sitter_rust::LANGUAGE, queries::RUST_QUERY),
        "javascript" => (tree_sitter_javascript::LANGUAGE, queries::JS_QUERY),
        "c" => (tree_sitter_c::LANGUAGE, queries::C_QUERY),
        "cpp" => (tree_sitter_cpp::LANGUAGE, queries::CPP_QUERY),
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
    if lang == "vim" {
        let mut symbols = run_ts_query_symbols(text).unwrap_or_default();
        let fallback = symbols_vim_naive(text);
        for s in fallback.into_iter().filter(|x| x.kind == "function") {
            let dup = symbols.iter().any(|x| {
                x.kind == s.kind && x.name == s.name && x.lnum == s.lnum && x.col == s.col
            });
            if !dup {
                symbols.push(s);
            }
        }
        symbols.sort_by_key(|s| (s.lnum, s.col));
        return Ok(symbols);
    }

    let mut parser = tree_sitter::Parser::new();
    let (language, query_src) = match lang {
        "rust" => (tree_sitter_rust::LANGUAGE, queries::RUST_SYM_QUERY),
        "javascript" => (tree_sitter_javascript::LANGUAGE, queries::JS_SYM_QUERY),
        "c" => (tree_sitter_c::LANGUAGE, queries::C_SYM_QUERY),
        "cpp" => (tree_sitter_cpp::LANGUAGE, queries::CPP_SYM_QUERY),
        _ => return Err(anyhow!("unsupported language: {lang}")),
    };
    parser.set_language(&language.into())?;

    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();

    let query = tree_sitter::Query::new(&language.into(), query_src)?;
    let mut cursor = tree_sitter::QueryCursor::new();

    let mut symbols = Vec::with_capacity(256);
    let bytes = text.as_bytes();
    let mut seen_at = std::collections::HashMap::<(u32, u32), String>::new();

    let mut it = cursor.captures(&query, root, bytes);
    while let Some((m, cap_ix)) = it.next() {
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let cname = query.capture_names()[cap.index as usize];

        let kind = map_symbol_capture(cname);
        if kind.is_empty() {
            continue;
        }

        let name = node_text(node, bytes);
        let sp = node.start_position();
        let lnum = sp.row as u32 + 1;
        let col = sp.column as u32 + 1;

        // 归属容器（Rust）
        let (mut container_kind, mut container_name) = (None, None);
        if lang == "rust" {
            match kind {
                "field" => {
                    let (ck, cn) = ancestor_struct_name(node, bytes);
                    container_kind = ck;
                    container_name = cn;
                }
                "method" => {
                    let (ck, cn) = ancestor_impl_type_name(node, bytes);
                    container_kind = ck;
                    container_name = cn;
                }
                "variant" => {
                    let (ck, cn) = ancestor_enum_name(node, bytes);
                    container_kind = ck;
                    container_name = cn;
                }
                "function" => {
                    // 内嵌函数归属到外层函数；否则归属到最近的 mod
                    if let Some((ck, cn)) = ancestor_outer_fn_name(node, bytes) {
                        container_kind = Some(ck);
                        container_name = Some(cn);
                    } else {
                        let (ck, cn) = ancestor_mod_name(node, bytes);
                        container_kind = ck;
                        container_name = cn;
                    }
                }
                "const" => {
                    let (ck, cn) = ancestor_mod_name(node, bytes);
                    container_kind = ck;
                    container_name = cn;
                }
                _ => {}
            }
        }

        // function vs method 去重：同起点优先保留 method
        if let Some(prev) = seen_at.get(&(lnum, col)) {
            if prev == "method" && kind == "function" {
                continue;
            }
            if prev == "function" && kind == "method" {
                if let Some(pos) = symbols.iter().position(|s: &Symbol| {
                    s.lnum == lnum && s.col == col && s.kind == "function" && s.name == name
                }) {
                    symbols.remove(pos);
                }
                seen_at.insert((lnum, col), "method".to_string());
            }
        } else {
            seen_at.insert((lnum, col), kind.to_string());
        }

        symbols.push(Symbol {
            name,
            kind: kind.to_string(),
            lnum,
            col,
            container_kind,
            container_name,
        });
    }

    symbols.sort_by_key(|s| (s.lnum, s.col));
    Ok(symbols)
}

fn run_ts_query_highlight(text: &str) -> Result<Vec<Span>> {
    let (language, query_src) = (tree_sitter_vim::language(), queries::VIM_QUERY);
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&language)?;
    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();
    let query = match tree_sitter::Query::new(&language, query_src) {
        Ok(q) => q,
        Err(_) => return Ok(Vec::new()),
    };
    let mut cursor = tree_sitter::QueryCursor::new();

    let mut spans = Vec::new();
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

fn run_ts_query_symbols(text: &str) -> Result<Vec<Symbol>> {
    let (language, query_src) = (tree_sitter_vim::language(), queries::VIM_SYM_QUERY);
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&language)?;
    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();
    let query = match tree_sitter::Query::new(&language, query_src) {
        Ok(q) => q,
        Err(_) => return Ok(Vec::new()),
    };
    let mut cursor = tree_sitter::QueryCursor::new();

    let mut symbols = Vec::new();
    let bytes = text.as_bytes();
    let mut it = cursor.captures(&query, root, bytes);
    while let Some((m, cap_ix)) = it.next() {
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let cname = query.capture_names()[cap.index as usize];
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
            container_kind: None,
            container_name: None,
        });
    }
    symbols.sort_by_key(|s| (s.lnum, s.col));
    Ok(symbols)
}

// ===== Vim 的回退解析（不依赖 tree-sitter），保证可用 =====
fn highlight_vim_naive(text: &str) -> Vec<Span> {
    let mut spans = Vec::with_capacity(512);
    for (i, line) in text.lines().enumerate() {
        let lnum = i as u32 + 1;
        let bytes = line.as_bytes();

        if let Some(non_ws_ix) = line.find(|c: char| !c.is_whitespace()) {
            if line[non_ws_ix..].starts_with('"') {
                spans.push(Span {
                    lnum,
                    col: (non_ws_ix as u32) + 1,
                    end_lnum: lnum,
                    end_col: (line.len() as u32) + 1,
                    group: "TSComment".to_string(),
                });
                continue;
            }
        }

        for quote in ['\'', '"'] {
            let mut idx = 0usize;
            while let Some(s) = line[idx..].find(quote) {
                let start = idx + s;
                if let Some(e) = line[start + 1..].find(quote) {
                    let end = start + 1 + e + 1;
                    spans.push(Span {
                        lnum,
                        col: (start as u32) + 1,
                        end_lnum: lnum,
                        end_col: (end as u32) + 1,
                        group: "TSString".to_string(),
                    });
                    idx = end;
                } else {
                    break;
                }
            }
        }

        let keywords = [
            "function",
            "endfunction",
            "return",
            "if",
            "endif",
            "elseif",
            "else",
            "for",
            "endfor",
            "while",
            "endwhile",
            "try",
            "catch",
            "finally",
            "endtry",
            "set",
            "autocmd",
            "augroup",
            "end",
            "command",
            "lua",
            "map",
            "noremap",
            "nnoremap",
            "inoremap",
            "vnoremap",
            "tnoremap",
            "vim9script",
            "def",
            "enddef",
            "var",
            "const",
            "import",
            "export",
        ];
        for kw in keywords.iter() {
            let mut pos = 0usize;
            while let Some(p) = line[pos..].find(kw) {
                let s = pos + p;
                let b1 = s.checked_sub(1).map(|i| bytes[i]).unwrap_or(b' ');
                let b2 = bytes.get(s + kw.len()).copied().unwrap_or(b' ');
                let is_boundary = !is_ident_char(b1) && !is_ident_char(b2);
                if is_boundary {
                    spans.push(Span {
                        lnum,
                        col: (s as u32) + 1,
                        end_lnum: lnum,
                        end_col: (s as u32) + (kw.len() as u32) + 1,
                        group: "TSKeyword".to_string(),
                    });
                }
                pos = s + kw.len();
            }
        }

        let mut j = 0usize;
        while j < bytes.len() {
            if bytes[j].is_ascii_digit() {
                let k = j
                    + 1
                    + line[j + 1..]
                        .find(|c: char| !c.is_ascii_digit())
                        .unwrap_or(0);
                spans.push(Span {
                    lnum,
                    col: (j as u32) + 1,
                    end_lnum: lnum,
                    end_col: (k as u32) + 1,
                    group: "TSNumber".to_string(),
                });
                j = k;
            } else {
                j += 1;
            }
        }

        let puncts = [
            '(', ')', '{', '}', '[', ']', ',', ';', '.', '=', '+', '-', '*', '/',
        ];
        for (ci, ch) in line.chars().enumerate() {
            if puncts.contains(&ch) {
                let grp = match ch {
                    '(' | ')' | '{' | '}' | '[' | ']' => "TSPunctBracket",
                    ',' | ';' | '.' => "TSPunctDelimiter",
                    '=' | '+' | '-' | '*' | '/' => "TSOperator",
                    _ => "TSOperator",
                };
                spans.push(Span {
                    lnum,
                    col: (ci as u32) + 1,
                    end_lnum: lnum,
                    end_col: (ci as u32) + 2,
                    group: grp.to_string(),
                });
            }
        }

        for decl_kw in ["var", "const"] {
            if let Some(pos) = line.find(decl_kw) {
                let after = &line[pos + decl_kw.len()..];
                if let Some(name_start_rel) = after.find(|c: char| !c.is_whitespace()) {
                    let name_start = pos + decl_kw.len() + name_start_rel;
                    let name_end = name_start
                        + after[name_start_rel..]
                            .find(|c: char| c.is_whitespace() || c == '=')
                            .unwrap_or(after.len() - name_start_rel);
                    if name_end > name_start {
                        spans.push(Span {
                            lnum,
                            col: (name_start as u32) + 1,
                            end_lnum: lnum,
                            end_col: (name_end as u32) + 1,
                            group: "TSVariable".to_string(),
                        });
                    }
                }
            }
        }

        let mut def_pos = None;
        if let Some(p) = line.find("def") {
            def_pos = Some(p);
        }
        if let Some(p) = line.find("export def") {
            def_pos = Some(p + "export ".len());
        }
        if let Some(dp) = def_pos {
            let mut s = dp + "def".len();
            let bytes = line.as_bytes();
            while s < line.len() && bytes[s].is_ascii_whitespace() {
                s += 1;
            }
            let name_start = s;
            while s < line.len() {
                let b = bytes[s];
                if b.is_ascii_whitespace() || b == b'(' {
                    break;
                }
                s += 1;
            }
            if s > name_start {
                spans.push(Span {
                    lnum,
                    col: (name_start as u32) + 1,
                    end_lnum: lnum,
                    end_col: (s as u32) + 1,
                    group: "TSFunction".to_string(),
                });
            }
        }
    }
    spans
}

fn symbols_vim_naive(text: &str) -> Vec<Symbol> {
    let mut syms = Vec::with_capacity(128);
    for (i, line) in text.lines().enumerate() {
        let lnum = i as u32 + 1;
        let trimmed = line.trim_start();
        let base_col = (line.len() - trimmed.len()) as u32 + 1;
        let b = trimmed.as_bytes();

        if trimmed.starts_with("def") || trimmed.starts_with("export def") {
            let mut s: usize;
            if trimmed.starts_with("export def") {
                s = "export def".len();
            } else {
                s = "def".len();
            }
            while s < trimmed.len() && b[s].is_ascii_whitespace() {
                s += 1;
            }
            let name_start = s;
            while s < trimmed.len() {
                let ch = b[s];
                if ch.is_ascii_whitespace() || ch == b'(' {
                    break;
                }
                s += 1;
            }
            if s > name_start {
                let name = &trimmed[name_start..s];
                syms.push(Symbol {
                    name: name.to_string(),
                    kind: "function".to_string(),
                    lnum,
                    col: base_col + (name_start as u32),
                    container_kind: None,
                    container_name: None,
                });
            }
        } else if trimmed.starts_with("function") {
            let mut s = "function".len();
            if s < trimmed.len() && b[s] == b'!' {
                s += 1;
            }
            while s < trimmed.len() && b[s].is_ascii_whitespace() {
                s += 1;
            }
            let name_start = s;
            while s < trimmed.len() {
                let ch = b[s];
                if ch.is_ascii_whitespace() || ch == b'(' {
                    break;
                }
                s += 1;
            }
            if s > name_start {
                let name = &trimmed[name_start..s];
                syms.push(Symbol {
                    name: name.to_string(),
                    kind: "function".to_string(),
                    lnum,
                    col: base_col + (name_start as u32),
                    container_kind: None,
                    container_name: None,
                });
            }
        } else if trimmed.starts_with("augroup") {
            let rest = &trimmed["augroup".len()..].trim_start();
            if !rest.is_empty() {
                let end = rest.find(char::is_whitespace).unwrap_or(rest.len());
                let name = &rest[..end];
                let offset_ws = trimmed["augroup".len()..].len() - rest.len();
                syms.push(Symbol {
                    name: name.to_string(),
                    kind: "namespace".to_string(),
                    lnum,
                    col: base_col + "augroup".len() as u32 + offset_ws as u32,
                    container_kind: None,
                    container_name: None,
                });
            }
        } else if trimmed.starts_with("command") {
            let mut s = "command".len();
            if s < trimmed.len() && b[s] == b'!' {
                s += 1;
            }
            while s < trimmed.len() && b[s].is_ascii_whitespace() {
                s += 1;
            }
            let name_start = s;
            while s < trimmed.len() {
                let ch = b[s];
                if ch.is_ascii_whitespace() {
                    break;
                }
                s += 1;
            }
            if s > name_start {
                let name = &trimmed[name_start..s];
                syms.push(Symbol {
                    name: name.to_string(),
                    kind: "macro".to_string(),
                    lnum,
                    col: base_col + (name_start as u32),
                    container_kind: None,
                    container_name: None,
                });
            }
        }
    }
    syms.sort_by_key(|s| (s.lnum, s.col));
    syms
}

fn is_ident_char(b: u8) -> bool {
    (b as char).is_ascii_alphanumeric() || b == b'_'
}

fn node_text(node: tree_sitter::Node, bytes: &[u8]) -> String {
    let s = &bytes[node.start_byte() as usize..node.end_byte() as usize];
    String::from_utf8_lossy(s).to_string()
}

fn dump_ast(lang: &str, text: &str) -> Result<Vec<String>> {
    let mut parser = tree_sitter::Parser::new();
    let language = match lang {
        "vim" => tree_sitter_vim::language(),
        "rust" => tree_sitter_rust::LANGUAGE.into(),
        "javascript" => tree_sitter_javascript::LANGUAGE.into(),
        "c" => tree_sitter_c::LANGUAGE.into(),
        "cpp" => tree_sitter_cpp::LANGUAGE.into(),
        _ => return Err(anyhow!("unsupported language: {lang}")),
    };
    parser.set_language(&language)?;
    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();

    let mut lines = Vec::new();
    fn walk(node: tree_sitter::Node, depth: usize, out: &mut Vec<String>) {
        let sp = node.start_position();
        let ep = node.end_position();
        out.push(format!(
            "{:indent$}{} [{}:{} - {}:{}]",
            "",
            node.kind(),
            sp.row + 1,
            sp.column + 1,
            ep.row + 1,
            ep.column + 1,
            indent = depth * 2
        ));
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            walk(child, depth + 1, out);
        }
    }
    walk(root, 0, &mut lines);
    Ok(lines)
}

fn map_capture_to_group(name: &str) -> &'static str {
    match name {
        "comment" => "TSComment",
        "string" => "TSString",
        "string.regex" => "TStringRegex",
        "string.escape" => "TStringEscape",
        "string.special" => "TStringSpecial",
        "number" => "TSNumber",
        "boolean" => "TSBoolean",
        "null" => "TSConstant",

        "keyword" => "TSKeyword",
        "keyword.operator" => "TSKeywordOperator",
        "operator" => "TSOperator",
        "punctuation.delimiter" => "TSPunctDelimiter",
        "punctuation.bracket" => "TSPunctBracket",

        "variable" => "TSVariable",
        "variable.parameter" => "TSVariableParameter",
        "variable.builtin" => "TSVariableBuiltin",
        "constant" => "TSConstant",
        "constant.builtin" => "TSConstBuiltin",

        "property" => "TSProperty",
        "field" => "TSField",

        "function" => "TSFunction",
        "method" => "TSMethod",
        "function.builtin" => "TSFunctionBuiltin",

        "type" => "TSType",
        "type.builtin" => "TSTypeBuiltin",
        "namespace" => "TSNamespace",
        "macro" => "TSMacro",
        "attribute" => "TSAttribute",

        _ => "TSVariable",
    }
}

fn map_symbol_capture(name: &str) -> &'static str {
    match name {
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
        "symbol.variant" => "variant",
        _ => "",
    }
}

fn ancestor_kind<'a>(mut node: tree_sitter::Node<'a>, want: &str) -> Option<tree_sitter::Node<'a>> {
    while let Some(parent) = node.parent() {
        if parent.kind() == want {
            return Some(parent);
        }
        node = parent;
    }
    None
}

fn child_text_by_kind(node: tree_sitter::Node, child_kind: &str, bytes: &[u8]) -> Option<String> {
    let mut cursor = node.walk();
    for ch in node.children(&mut cursor) {
        if ch.kind() == child_kind {
            return Some(node_text(ch, bytes));
        }
    }
    None
}

fn ancestor_struct_name(node: tree_sitter::Node, bytes: &[u8]) -> (Option<String>, Option<String>) {
    if let Some(st) = ancestor_kind(node, "struct_item") {
        return (
            Some("struct".to_string()),
            child_text_by_kind(st, "type_identifier", bytes),
        );
    }
    (None, None)
}

fn ancestor_enum_name(node: tree_sitter::Node, bytes: &[u8]) -> (Option<String>, Option<String>) {
    if let Some(en) = ancestor_kind(node, "enum_item") {
        return (
            Some("enum".to_string()),
            child_text_by_kind(en, "type_identifier", bytes),
        );
    }
    (None, None)
}

fn ancestor_impl_type_name(
    node: tree_sitter::Node,
    bytes: &[u8],
) -> (Option<String>, Option<String>) {
    if let Some(im) = ancestor_kind(node, "impl_item") {
        let mut last: Option<String> = None;
        let mut cursor = im.walk();
        for ch in im.children(&mut cursor) {
            if ch.kind() == "type_identifier" || ch.kind() == "identifier" {
                last = Some(node_text(ch, bytes));
            }
        }
        if last.is_some() {
            return (Some("type".to_string()), last);
        }
    }
    (None, None)
}

fn ancestor_mod_name(node: tree_sitter::Node, bytes: &[u8]) -> (Option<String>, Option<String>) {
    if let Some(md) = ancestor_kind(node, "mod_item") {
        return (
            Some("namespace".to_string()),
            child_text_by_kind(md, "identifier", bytes),
        );
    }
    (None, None)
}

fn ancestor_outer_fn_name(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, String)> {
    // 找到最近的外层函数（不包含当前节点自己）
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "function_item" {
            // 获取该外层函数的名字
            if let Some(name) = child_text_by_kind(parent, "identifier", bytes) {
                return Some(("function".to_string(), name));
            }
        }
        cur = parent;
    }
    None
}
