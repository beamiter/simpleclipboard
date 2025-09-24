use anyhow::Result;
use ignore::WalkBuilder;
use serde::{Deserialize, Serialize};
use std::{collections::HashMap, path::PathBuf, sync::Arc};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    sync::{Mutex, RwLock},
};
use tokio_util::sync::CancellationToken;

#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
enum Request {
    #[serde(rename = "list")]
    List {
        id: u64,
        path: String,
        #[serde(default)]
        show_hidden: bool,
        #[serde(default = "default_page")]
        max: usize,
    },
    #[serde(rename = "expand")]
    Expand {
        id: u64,
        path: String,
        #[serde(default)]
        show_hidden: bool,
        #[serde(default = "default_page")]
        max: usize,
    },
    #[serde(rename = "cancel")]
    Cancel { id: u64 },
}

fn default_page() -> usize {
    200
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
enum Event {
    #[serde(rename = "list_chunk")]
    ListChunk {
        id: u64,
        entries: Vec<Entry>,
        done: bool,
    },
    #[serde(rename = "error")]
    Error { id: u64, message: String },
}

#[derive(Debug, Clone, Serialize)]
struct Entry {
    name: String,
    path: String,
    is_dir: bool,
}

#[tokio::main(flavor = "multi_thread")]
async fn main() -> Result<()> {
    let stdin = BufReader::new(tokio::io::stdin());
    let mut lines = stdin.lines();
    let out = Arc::new(Mutex::new(tokio::io::stdout()));

    // 任务取消表：id -> token
    let cancels: Arc<RwLock<HashMap<u64, CancellationToken>>> =
        Arc::new(RwLock::new(HashMap::new()));

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }
        let req = match serde_json::from_str::<Request>(&line) {
            Ok(r) => r,
            Err(e) => {
                send_event(
                    out.clone(),
                    &Event::Error {
                        id: 0,
                        message: format!("invalid request: {e}"),
                    },
                )
                .await?;
                continue;
            }
        };

        match req {
            Request::List {
                id,
                path,
                show_hidden,
                max,
            }
            | Request::Expand {
                id,
                path,
                show_hidden,
                max,
            } => {
                let path = PathBuf::from(path);
                let out_clone = out.clone();
                let cancels_clone = cancels.clone();

                // 建立取消 token
                let token = CancellationToken::new();
                {
                    let mut map = cancels.write().await;
                    map.insert(id, token.clone());
                }

                tokio::spawn(async move {
                    // 这里只用 out_clone，避免捕获外层 out
                    let res =
                        handle_list(id, path, show_hidden, max, out_clone.clone(), token.clone())
                            .await;
                    if let Err(e) = res {
                        let _ = send_event(
                            out_clone.clone(),
                            &Event::Error {
                                id,
                                message: e.to_string(),
                            },
                        )
                        .await;
                    }
                    // 结束后移除取消 token
                    let mut map = cancels_clone.write().await;
                    map.remove(&id);
                });
            }
            Request::Cancel { id } => {
                let maybe = {
                    let map = cancels.read().await;
                    map.get(&id).cloned()
                };
                if let Some(tok) = maybe {
                    tok.cancel();
                }
            }
        }
    }

    Ok(())
}

async fn handle_list(
    id: u64,
    path: PathBuf,
    show_hidden: bool,
    page: usize,
    out: Arc<Mutex<tokio::io::Stdout>>,
    cancel: CancellationToken,
) -> Result<()> {
    // 在阻塞线程迭代，提高吞吐，同时响应取消
    let (tx, mut rx) = tokio::sync::mpsc::channel::<Entry>(1024);
    let cancel_clone = cancel.clone();
    let scan_path = path.clone();

    let scan = tokio::task::spawn_blocking(move || {
        let mut wb = WalkBuilder::new(&scan_path);
        // ignore::WalkBuilder: hidden(true) -> 忽略隐藏；show_hidden=true 时应包含隐藏 -> hidden(false)
        wb.follow_links(false)
            .hidden(!show_hidden)
            .git_ignore(true)
            .git_global(true)
            .git_exclude(true)
            .parents(true)
            .max_depth(Some(1));
        let walker = wb.build();

        for dent in walker {
            if cancel_clone.is_cancelled() {
                break;
            }
            match dent {
                Ok(d) => {
                    if d.depth() == 0 {
                        continue;
                    }
                    let p = d.path().to_path_buf();
                    if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
                        let is_dir = d
                            .metadata()
                            .map(|m| m.is_dir())
                            .unwrap_or_else(|_| p.is_dir());
                        let _ = tx.blocking_send(Entry {
                            name: name.to_string(),
                            path: p.to_string_lossy().into_owned(),
                            is_dir,
                        });
                    }
                }
                Err(_) => {
                    // 忽略单个条目的错误
                }
            }
        }
    });

    // 收集所有结果
    let mut entries: Vec<Entry> = Vec::with_capacity(512);
    while let Some(e) = rx.recv().await {
        entries.push(e);
    }
    let _ = scan.await;

    // 已取消则静默退出
    if cancel.is_cancelled() {
        return Ok(());
    }

    // 目录优先 + 名称不区分大小写排序
    entries.sort_by(|a, b| match (a.is_dir, b.is_dir) {
        (true, false) => std::cmp::Ordering::Less,
        (false, true) => std::cmp::Ordering::Greater,
        _ => a.name.to_lowercase().cmp(&b.name.to_lowercase()),
    });

    // 分块输出
    if entries.is_empty() {
        send_event(
            out.clone(),
            &Event::ListChunk {
                id,
                entries: vec![],
                done: true,
            },
        )
        .await?;
        return Ok(());
    }

    let mut i = 0usize;
    while i < entries.len() {
        if cancel.is_cancelled() {
            break;
        }
        let end = (i + page).min(entries.len());
        let chunk = entries[i..end].to_vec();
        send_event(
            out.clone(),
            &Event::ListChunk {
                id,
                entries: chunk,
                done: end >= entries.len(),
            },
        )
        .await?;
        i = end;
    }
    Ok(())
}

async fn send_event(out: Arc<Mutex<tokio::io::Stdout>>, evt: &Event) -> std::io::Result<()> {
    let mut guard = out.lock().await;
    let line = serde_json::to_string(evt).unwrap();
    guard.write_all(line.as_bytes()).await?;
    guard.write_all(b"\n").await?;
    guard.flush().await
}
