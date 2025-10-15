use anyhow::{Result, anyhow};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::ops;
use tree_sitter::StreamingIterator;

mod queries;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "set_text")]
    SetText {
        buf: i64,
        lang: String,
        text: String,
    },
    #[serde(rename = "highlight")]
    Highlight {
        buf: i64,
        lang: String,
        #[serde(default)]
        lstart: Option<u32>,
        #[serde(default)]
        lend: Option<u32>,
    },
    #[serde(rename = "symbols")]
    Symbols {
        buf: i64,
        lang: String,
        #[serde(default)]
        lstart: Option<u32>,
        #[serde(default)]
        lend: Option<u32>,
        #[serde(default)]
        max_items: Option<usize>,
    },
    #[serde(rename = "dump_ast")]
    DumpAst { buf: i64, lang: String },
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
    #[serde(rename = "ok")]
    Ok { buf: i64, op: String },
    #[serde(rename = "error")]
    Error {
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        buf: Option<i64>,
    },
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

// 缓存：每个 buf 保存 lang/text/tree
struct BufCache {
    lang: String,
    text: String,
    tree: tree_sitter::Tree,
    language: tree_sitter::Language,
}

struct Server {
    // 缓存：buf -> BufCache
    cache: HashMap<i64, BufCache>,
    // 复用 parser（按语言）
    parsers: HashMap<String, tree_sitter::Parser>,
}

impl Server {
    fn new() -> Self {
        Server {
            cache: HashMap::new(),
            parsers: HashMap::new(),
        }
    }

    fn language_and_queries(
        &self,
        lang: &str,
    ) -> Result<(tree_sitter::Language, &'static str, &'static str)> {
        let (language, hl_query, sym_query) = match lang {
            "rust" => (
                tree_sitter_rust::LANGUAGE.into(),
                queries::RUST_QUERY,
                queries::RUST_SYM_QUERY,
            ),
            "javascript" => (
                tree_sitter_javascript::LANGUAGE.into(),
                queries::JS_QUERY,
                queries::JS_SYM_QUERY,
            ),
            "c" => (
                tree_sitter_c::LANGUAGE.into(),
                queries::C_QUERY,
                queries::C_SYM_QUERY,
            ),
            "cpp" => (
                tree_sitter_cpp::LANGUAGE.into(),
                queries::CPP_QUERY,
                queries::CPP_SYM_QUERY,
            ),
            "vim" => (
                tree_sitter_vim9::LANGUAGE.into(),
                queries::VIM_QUERY,
                queries::VIM_SYM_QUERY,
            ),
            _ => return Err(anyhow!("unsupported language: {lang}")),
        };
        Ok((language, hl_query, sym_query))
    }

    fn parser_for(
        &mut self,
        lang: &str,
        language: tree_sitter::Language,
    ) -> Result<&mut tree_sitter::Parser> {
        use std::collections::hash_map::Entry;
        Ok(match self.parsers.entry(lang.to_string()) {
            Entry::Occupied(e) => {
                let p = e.into_mut();
                // 确保语言设置正确
                p.set_language(&language)?;
                p
            }
            Entry::Vacant(v) => {
                let mut p = tree_sitter::Parser::new();
                p.set_language(&language)?;
                v.insert(p)
            }
        })
    }

    fn set_text(&mut self, buf: i64, lang: &str, text: String) -> Result<()> {
        let (language, _, _) = self.language_and_queries(lang)?;
        let p = self.parser_for(lang, language.clone())?;
        // 这里为简单起见不做增量编辑，直接全量 parse
        let tree = p
            .parse(&text, None)
            .ok_or_else(|| anyhow!("parse failed"))?;
        self.cache.insert(
            buf,
            BufCache {
                lang: lang.to_string(),
                text,
                tree,
                language,
            },
        );
        Ok(())
    }

    fn get_cache(&self, buf: i64, lang: &str) -> Result<&BufCache> {
        let c = self
            .cache
            .get(&buf)
            .ok_or_else(|| anyhow!("buffer not cached: {buf}"))?;
        if c.lang != lang {
            return Err(anyhow!(
                "lang mismatch for buf {buf}: cached={}, req={}",
                c.lang,
                lang
            ));
        }
        Ok(c)
    }
}

fn main() -> Result<()> {
    let stdin = std::io::stdin();
    let mut lines = BufReader::new(stdin).lines();
    let mut out = std::io::stdout();
    let mut server = Server::new();

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
                        buf: None,
                    },
                )?;
                continue;
            }
        };
        match req {
            Request::SetText { buf, lang, text } => match server.set_text(buf, &lang, text) {
                Ok(()) => send(
                    &mut out,
                    &Event::Ok {
                        buf,
                        op: "set_text".to_string(),
                    },
                )?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                        buf: Some(buf),
                    },
                )?,
            },
            Request::Highlight {
                buf,
                lang,
                lstart,
                lend,
            } => {
                let lrange = lstart.zip(lend);
                match run_highlight_cached(&mut server, buf, &lang, lrange) {
                    Ok(spans) => send(&mut out, &Event::Highlights { buf, spans })?,
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                            buf: Some(buf),
                        },
                    )?,
                }
            }
            Request::Symbols {
                buf,
                lang,
                lstart,
                lend,
                max_items,
            } => {
                let lrange = lstart.zip(lend);
                match run_symbols_cached(&mut server, buf, &lang, lrange, max_items) {
                    Ok(symbols) => send(&mut out, &Event::Symbols { buf, symbols })?,
                    Err(e) => send(
                        &mut out,
                        &Event::Error {
                            message: e.to_string(),
                            buf: Some(buf),
                        },
                    )?,
                }
            }
            Request::DumpAst { buf, lang } => match dump_ast_cached(&mut server, buf, &lang) {
                Ok(lines) => send(&mut out, &Event::Ast { buf, lines })?,
                Err(e) => send(
                    &mut out,
                    &Event::Error {
                        message: e.to_string(),
                        buf: Some(buf),
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

// 复用缓存的 Tree + bytes 做高亮
fn run_highlight_cached(
    server: &mut Server,
    buf: i64,
    lang: &str,
    lrange: Option<(u32, u32)>,
) -> Result<Vec<Span>> {
    let cache = server.get_cache(buf, lang)?;
    let (_, hl_query_src, _) = server.language_and_queries(&cache.lang)?;
    let bytes = cache.text.as_bytes();
    let root = cache.tree.root_node();
    let query = tree_sitter::Query::new(&cache.language, hl_query_src)?;
    let mut cursor = tree_sitter::QueryCursor::new();

    if let Some((ls, le)) = lrange {
        let b_range = line_range_to_byte_range(&cache.text, ls, le);
        cursor.set_byte_range(b_range);
    }

    let mut spans = Vec::with_capacity(4096);
    let mut it = cursor.captures(&query, root, bytes);
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

// 复用缓存 Tree + bytes 做符号
fn run_symbols_cached(
    server: &mut Server,
    buf: i64,
    lang: &str,
    lrange: Option<(u32, u32)>,
    max_items: Option<usize>,
) -> Result<Vec<Symbol>> {
    let cache = server.get_cache(buf, lang)?;
    let (_, _, sym_query_src) = server.language_and_queries(&cache.lang)?;
    let bytes = cache.text.as_bytes();
    let root = cache.tree.root_node();
    let query = tree_sitter::Query::new(&cache.language, sym_query_src)?;
    let mut cursor = tree_sitter::QueryCursor::new();

    if let Some((ls, le)) = lrange {
        let b_range = line_range_to_byte_range(&cache.text, ls, le);
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

        // 容器信息（可选）
        let mut ckind: Option<String> = None;
        let mut cname_opt: Option<String> = None;
        let mut clnum: Option<u32> = None;
        let mut ccol: Option<u32> = None;

        // Rust 特定容器推断（保持原逻辑）
        if cache.lang == "rust" {
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

        // Vim 语言：隐藏函数体内的局部变量（标注容器为 function）
        if cache.lang == "vim" {
            // 过滤掉 augroup END
            if kind == "namespace" && name == "END" {
                continue;
            }
            if kind == "variable" {
                let mut cur = node;
                let mut in_func = false;
                while let Some(parent) = cur.parent() {
                    let pk = parent.kind();
                    if pk == "function_definition" || pk == "vim9_function_definition" {
                        in_func = true;
                        break;
                    }
                    cur = parent;
                }
                if in_func {
                    ckind = Some("function".to_string());
                    // 如需显示父函数名作为容器，可以解析父声明名字赋值给 cname_opt/clnum/ccol
                    // 这里为最小实现，仅标注容器类型即可被插件过滤
                }
            }
        }

        // 位置同一处的 function/method 优先保留 method（保持原逻辑）
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

fn dump_ast_cached(server: &mut Server, buf: i64, lang: &str) -> Result<Vec<String>> {
    let cache = server.get_cache(buf, lang)?;
    let root = cache.tree.root_node();

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

#[allow(dead_code)]
fn is_ident_char(b: u8) -> bool {
    (b as char).is_ascii_alphanumeric() || b == b'_'
}

fn node_text(node: tree_sitter::Node, bytes: &[u8]) -> String {
    let s = &bytes[node.start_byte() as usize..node.end_byte() as usize];
    String::from_utf8_lossy(s).to_string()
}

// ---- Rust-specific helpers (保持不变) ----
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
#[allow(dead_code)]
fn has_ancestor_of(node: tree_sitter::Node, kinds: &[&str]) -> bool {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        for &k in kinds {
            if parent.kind() == k {
                return true;
            }
        }
        cur = parent;
    }
    false
}

// 如需拿到父函数名，可用这个辅助（可选）
#[allow(dead_code)]
fn vim_func_name(node: tree_sitter::Node, bytes: &[u8]) -> Option<String> {
    let mut cur = node;
    while let Some(parent) = cur.parent() {
        if parent.kind() == "function_definition" || parent.kind() == "vim9_function_definition" {
            // 找到声明节点，取里面的名字（identifier/scoped_identifier/field_expression）
            let mut cursor = parent.walk();
            for ch in parent.children(&mut cursor) {
                if ch.kind() == "function_declaration" || ch.kind() == "vim9_function_declaration" {
                    let mut c2 = ch.walk();
                    for nm in ch.children(&mut c2) {
                        match nm.kind() {
                            "identifier" | "scoped_identifier" | "field_expression" => {
                                return Some(node_text(nm, bytes));
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
        cur = parent;
    }
    None
}
