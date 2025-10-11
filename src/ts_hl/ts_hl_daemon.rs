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
        // 优先尝试 tree-sitter-vim 查询；失败则回退到简单解析
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
        if let Ok(symbols) =
            run_ts_query_symbols(tree_sitter_vim::language(), queries::VIM_SYM_QUERY, text)
        {
            return Ok(symbols);
        } else {
            return Ok(symbols_vim_naive(text));
        }
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

fn run_ts_query_highlight(text: &str) -> Result<Vec<Span>> {
    let mut parser = tree_sitter::Parser::new();
    let (language, query_src) = (tree_sitter_vim::language(), queries::VIM_QUERY);
    parser.set_language(&language)?;
    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();
    let query = tree_sitter::Query::new(&language, query_src)?;
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

fn run_ts_query_symbols(
    language: tree_sitter::Language,
    query_src: &str,
    text: &str,
) -> Result<Vec<Symbol>> {
    let mut parser = tree_sitter::Parser::new();
    parser.set_language(&language.clone().into())?;
    let tree = parser
        .parse(text, None)
        .ok_or_else(|| anyhow!("parse failed"))?;
    let root = tree.root_node();
    let query = tree_sitter::Query::new(&language.into(), query_src)?;
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

        // 1) 注释：行首可选空白后紧跟 "
        if let Some(non_ws_ix) = line.find(|c: char| !c.is_whitespace()) {
            if line[non_ws_ix..].starts_with('"') {
                spans.push(Span {
                    lnum,
                    col: (non_ws_ix as u32) + 1,
                    end_lnum: lnum,
                    end_col: (line.len() as u32) + 1,
                    group: "TSComment".to_string(),
                });
                continue; // 整行注释；后续忽略
            }
        }

        // 2) 字符串：同时处理单引号与双引号（不做转义复杂处理）
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

        // 3) 关键字（Vimscript + Vim9script）
        let keywords = [
            // 传统
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
            // Vim9
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

        // 4) 数字：连续数字
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

        // 5) 括号/分隔符/简单运算符
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

        // 6) Vim9 变量：var/const 名称（粗略）
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

        // 7) Vim9 函数名：def 或 export def 后紧跟名字，直到 '('
        let mut def_pos = None;
        if let Some(p) = line.find("def") {
            def_pos = Some(p);
        }
        if let Some(p) = line.find("export def") {
            // 如果同时有 "export def"，以它为准（更靠前的）
            def_pos = Some(p + "export ".len());
        }
        if let Some(dp) = def_pos {
            let mut s = dp + "def".len();
            // 跳过空白
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

        // Vim9: def / export def
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
                });
            }
        }
        // 传统：function / function!
        else if trimmed.starts_with("function") {
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
                });
            }
        }
        // augroup 名字
        else if trimmed.starts_with("augroup") {
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
                });
            }
        }
        // command 名字
        else if trimmed.starts_with("command") {
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
