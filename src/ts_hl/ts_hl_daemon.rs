use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::{
    io::{BufRead, BufReader, Write},
    ops,
};
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
        #[serde(default)]
        lstart: Option<u32>, // 可选：可见范围开始行(1-based)
        #[serde(default)]
        lend: Option<u32>, // 可选：可见范围结束行(1-based)
    },
    #[serde(rename = "symbols")]
    Symbols {
        buf: i64,
        lang: String,
        text: String,
        #[serde(default)]
        lstart: Option<u32>, // 新增：可见范围开始行(1-based)
        #[serde(default)]
        lend: Option<u32>, // 新增：可见范围结束行(1-based)
        #[serde(default)]
        max_items: Option<usize>, // 新增：最多返回条数
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
    container_kind: Option<String>,
    container_name: Option<String>,
    container_lnum: Option<u32>,
    container_col: Option<u32>,
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
            Request::Highlight {
                buf,
                lang,
                text,
                lstart,
                lend,
            } => {
                let lrange = lstart.zip(lend);
                match run_highlight(&lang, &text, lrange) {
                    Ok(spans) => send(&mut out, &Event::Highlights { buf, spans })?,
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                        },
                    )?,
                }
            }
            Request::Symbols {
                buf,
                lang,
                text,
                lstart,
                lend,
                max_items,
            } => {
                let lrange = lstart.zip(lend);
                match run_symbols(&lang, &text, lrange, max_items) {
                    Ok(symbols) => send(&mut out, &Event::Symbols { buf, symbols })?,
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                        },
                    )?,
                }
            }
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

// 将行号范围转为字节范围（用于 QueryCursor 限制扫描区间）
fn line_range_to_byte_range(text: &str, ls: u32, le: u32) -> ops::Range<usize> {
    // ls/le 为 1-based
    let mut start: usize = 0;
    let mut end: usize = text.len();
    let mut cur_line: u32 = 1;
    let mut offset: usize = 0;

    for line in text.lines() {
        if cur_line == ls {
            start = offset;
        }
        offset += line.len() + 1; // 包含 '\n'
        if cur_line == le {
            end = offset;
            break;
        }
        cur_line += 1;
    }
    if start > end {
        start = 0;
    }
    ops::Range { start, end }
}

// 支持按可选的行范围过滤（有重叠的才返回）
fn run_highlight(lang: &str, text: &str, lrange: Option<(u32, u32)>) -> Result<Vec<Span>> {
    if lang == "vim" {
        if let Ok(mut spans) = run_ts_query_highlight(text) {
            if let Some((ls, le)) = lrange {
                spans.retain(|sp| !(sp.end_lnum < ls || sp.lnum > le));
            }
            return Ok(spans);
        } else {
            let mut spans = highlight_vim_naive(text);
            if let Some((ls, le)) = lrange {
                spans.retain(|sp| !(sp.end_lnum < ls || sp.lnum > le));
            }
            return Ok(spans);
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

    if let Some((ls, le)) = lrange {
        let b_range = line_range_to_byte_range(text, ls, le);
        cursor.set_byte_range(b_range);
    }

    let mut spans = Vec::with_capacity(4096);
    let mut it = cursor.captures(&query, root, text.as_bytes());
    while let Some((m, cap_ix)) = it.next() {
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let sp = node.start_position();
        let ep = node.end_position();

        if let Some((ls, le)) = lrange {
            let nl1 = sp.row as u32 + 1;
            let nl2 = ep.row as u32 + 1;
            if nl2 < ls || nl1 > le {
                continue;
            }
        }

        let cname = query.capture_names()[cap.index as usize];
        let group = map_capture_to_group(cname).to_string();
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

fn run_symbols(
    lang: &str,
    text: &str,
    lrange: Option<(u32, u32)>,
    max_items: Option<usize>,
) -> Result<Vec<Symbol>> {
    if lang == "vim" {
        let mut symbols = run_ts_query_symbols(text, lrange, max_items).unwrap_or_default();
        let fallback = symbols_vim_naive(text, lrange, max_items);
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

    if let Some((ls, le)) = lrange {
        let b_range = line_range_to_byte_range(text, ls, le);
        cursor.set_byte_range(b_range);
    }

    let limit = max_items.unwrap_or(usize::MAX);
    use std::collections::{HashMap, HashSet};
    let mut seen = HashSet::<(
        String,
        String,
        u32,
        u32,
        Option<String>,
        Option<String>,
        Option<u32>,
        Option<u32>,
    )>::new();
    let mut seen_at = HashMap::<(u32, u32), String>::new();

    let mut symbols = Vec::with_capacity(limit.min(4096));
    let bytes = text.as_bytes();

    let mut it = cursor.captures(&query, root, bytes);
    while let Some((m, cap_ix)) = it.next() {
        if symbols.len() >= limit {
            break;
        }
        let cap = m.captures[*cap_ix];
        let node = cap.node;
        if node.start_byte() >= node.end_byte() {
            continue;
        }
        let cname = query.capture_names()[cap.index as usize];
        let kind = map_symbol_capture(cname).to_string();
        if kind.is_empty() {
            continue;
        }

        let name = node_text(node, bytes);
        let sp = node.start_position();
        let lnum = sp.row as u32 + 1;
        let col = sp.column as u32 + 1;

        if let Some((ls, le)) = lrange {
            if lnum < ls || lnum > le {
                continue;
            }
        }

        let (mut ckind, mut cname_opt, mut clnum, mut ccol) = (None, None, None, None);
        if lang == "rust" {
            match kind.as_str() {
                "field" => {
                    if let Some(vinfo) = variant_info(node, bytes) {
                        ckind = Some("variant".to_string());
                        cname_opt = Some(vinfo.0);
                        clnum = Some(vinfo.1);
                        ccol = Some(vinfo.2);
                    } else if let Some(sinfo) = struct_info(node, bytes) {
                        ckind = Some("struct".to_string());
                        cname_opt = Some(sinfo.0);
                        clnum = Some(sinfo.1);
                        ccol = Some(sinfo.2);
                    } else if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace".to_string());
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                "variant" => {
                    if let Some(einfo) = enum_info(node, bytes) {
                        ckind = Some("enum".to_string());
                        cname_opt = Some(einfo.0);
                        clnum = Some(einfo.1);
                        ccol = Some(einfo.2);
                    }
                }
                "method" => {
                    if let Some(tinfo) = impl_type_info(node, bytes) {
                        ckind = Some("type".to_string());
                        cname_opt = Some(tinfo.0);
                        clnum = Some(tinfo.1);
                        ccol = Some(tinfo.2);
                    }
                }
                "function" => {
                    if let Some(finfo) = outer_fn_info(node, bytes) {
                        ckind = Some("function".to_string());
                        cname_opt = Some(finfo.0);
                        clnum = Some(finfo.1);
                        ccol = Some(finfo.2);
                    } else if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace".to_string());
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                "const" => {
                    if let Some(minfo) = mod_info(node, bytes) {
                        ckind = Some("namespace".to_string());
                        cname_opt = Some(minfo.0);
                        clnum = Some(minfo.1);
                        ccol = Some(minfo.2);
                    }
                }
                _ => {}
            }
        }

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
            seen_at.insert((lnum, col), kind.clone());
        }

        let key = (
            kind.clone(),
            name.clone(),
            lnum,
            col,
            ckind.clone(),
            cname_opt.clone(),
            clnum,
            ccol,
        );
        if seen.contains(&key) {
            continue;
        }
        seen.insert(key);

        symbols.push(Symbol {
            name,
            kind,
            lnum,
            col,
            container_kind: ckind,
            container_name: cname_opt,
            container_lnum: clnum,
            container_col: ccol,
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

fn run_ts_query_symbols(
    text: &str,
    lrange: Option<(u32, u32)>,
    max_items: Option<usize>,
) -> Result<Vec<Symbol>> {
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
    if let Some((ls, le)) = lrange {
        let b_range = line_range_to_byte_range(text, ls, le);
        cursor.set_byte_range(b_range);
    }

    let limit = max_items.unwrap_or(usize::MAX);
    let mut symbols = Vec::with_capacity(limit.min(256));
    let bytes = text.as_bytes();
    let mut it = cursor.captures(&query, root, bytes);

    while let Some((m, cap_ix)) = it.next() {
        if symbols.len() >= limit {
            break;
        }
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

        if let Some((ls, le)) = lrange {
            if lnum < ls || lnum > le {
                continue;
            }
        }

        symbols.push(Symbol {
            name,
            kind: kind.to_string(),
            lnum,
            col,
            container_kind: None,
            container_name: None,
            container_lnum: None,
            container_col: None,
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

fn symbols_vim_naive(
    text: &str,
    lrange: Option<(u32, u32)>,
    max_items: Option<usize>,
) -> Vec<Symbol> {
    let limit = max_items.unwrap_or(usize::MAX);
    let mut syms = Vec::with_capacity(limit.min(128));
    for (i, line) in text.lines().enumerate() {
        let lnum = i as u32 + 1;
        if let Some((ls, le)) = lrange {
            if lnum < ls || lnum > le {
                continue;
            }
        }
        if syms.len() >= limit {
            break;
        }

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
                    container_lnum: None,
                    container_col: None,
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
                    container_lnum: None,
                    container_col: None,
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
                    container_lnum: None,
                    container_col: None,
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
                    container_lnum: None,
                    container_col: None,
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

fn child_pos_by_kind(node: tree_sitter::Node, child_kind: &str) -> Option<(u32, u32)> {
    let mut cursor = node.walk();
    for ch in node.children(&mut cursor) {
        if ch.kind() == child_kind {
            let sp = ch.start_position();
            return Some((sp.row as u32 + 1, sp.column as u32 + 1));
        }
    }
    None
}

fn struct_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(st) = ancestor_kind(node, "struct_item") {
        if let Some(name) = child_text_by_kind(st, "type_identifier", bytes) {
            if let Some((ln, co)) = child_pos_by_kind(st, "type_identifier") {
                return Some((name, ln, co));
            }
        }
    }
    None
}

fn enum_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(en) = ancestor_kind(node, "enum_item") {
        if let Some(name) = child_text_by_kind(en, "type_identifier", bytes) {
            if let Some((ln, co)) = child_pos_by_kind(en, "type_identifier") {
                return Some((name, ln, co));
            }
        }
    }
    None
}

fn variant_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "enum_variant" {
            if let Some(name) = child_text_by_kind(parent, "identifier", bytes) {
                if let Some((ln, co)) = child_pos_by_kind(parent, "identifier") {
                    return Some((name, ln, co));
                }
            }
        }
        cur = parent;
    }
    None
}

fn impl_type_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(im) = ancestor_kind(node, "impl_item") {
        let mut last: Option<(String, u32, u32)> = None;
        let mut cursor = im.walk();
        for ch in im.children(&mut cursor) {
            if ch.kind() == "type_identifier" || ch.kind() == "identifier" {
                let name = node_text(ch, bytes);
                let sp = ch.start_position();
                last = Some((name, sp.row as u32 + 1, sp.column as u32 + 1));
            }
        }
        if let Some(x) = last {
            return Some(x);
        }
    }
    None
}

fn mod_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    if let Some(md) = ancestor_kind(node, "mod_item") {
        if let Some(name) = child_text_by_kind(md, "identifier", bytes) {
            if let Some((ln, co)) = child_pos_by_kind(md, "identifier") {
                return Some((name, ln, co));
            }
        }
    }
    None
}

fn outer_fn_info(node: tree_sitter::Node, bytes: &[u8]) -> Option<(String, u32, u32)> {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "function_item" {
            if let Some(name) = child_text_by_kind(parent, "identifier", bytes) {
                if let Some((ln, co)) = child_pos_by_kind(parent, "identifier") {
                    return Some((name, ln, co));
                }
            }
        }
        cur = parent;
    }
    None
}
