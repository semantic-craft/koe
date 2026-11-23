use std::{
    collections::BTreeMap,
    ffi::OsStr,
    fs,
    io::{BufRead, BufReader, ErrorKind, Read, Write},
    net::Shutdown,
    os::{
        fd::AsRawFd,
        unix::{
            fs::{FileTypeExt, MetadataExt, PermissionsExt},
            net::{UnixListener, UnixStream},
        },
    },
    path::{Path, PathBuf},
    sync::{
        Arc, Condvar, Mutex,
        atomic::{AtomicBool, AtomicU64, Ordering},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use koe_runtime::{
    KoeRuntime, McpToolError, drive_mcp_tool_blocking, resolve_bridge_socket_path,
};
use serde_json::{Value, json};

use crate::{now, with_session};

const MAX_LINE_BYTES: u64 = 2 * 1024 * 1024;
const ACCEPT_POLL_SLEEP: Duration = Duration::from_millis(25);

struct WorkerState {
    count: Mutex<usize>,
    cvar: Condvar,
}

impl Default for WorkerState {
    fn default() -> Self {
        Self {
            count: Mutex::new(0),
            cvar: Condvar::new(),
        }
    }
}

struct WorkerGuard {
    conn_id: u64,
    active_streams: Arc<Mutex<BTreeMap<u64, UnixStream>>>,
    worker_state: Arc<WorkerState>,
}

impl WorkerGuard {
    fn acquire(
        conn_id: u64,
        active_streams: Arc<Mutex<BTreeMap<u64, UnixStream>>>,
        worker_state: Arc<WorkerState>,
    ) -> Self {
        if let Ok(mut count) = worker_state.count.lock() {
            *count = count.saturating_add(1);
        }
        Self {
            conn_id,
            active_streams,
            worker_state,
        }
    }
}

impl Drop for WorkerGuard {
    fn drop(&mut self) {
        if let Ok(mut streams) = self.active_streams.lock() {
            streams.remove(&self.conn_id);
        }
        if let Ok(mut count) = self.worker_state.count.lock() {
            *count = count.saturating_sub(1);
            if *count == 0 {
                self.worker_state.cvar.notify_all();
            }
        }
    }
}

pub(crate) struct BridgeServer {
    sock_path: PathBuf,
    sock_ino: Option<u64>,
    shutdown: Arc<AtomicBool>,
    active_streams: Arc<Mutex<BTreeMap<u64, UnixStream>>>,
    worker_state: Arc<WorkerState>,
    accept_thread: Option<JoinHandle<()>>,
}

impl BridgeServer {
    pub(crate) fn start(handle: u64, workspace: &Path) -> Option<Self> {
        let sock_path = resolve_bridge_socket_path(workspace)?;
        if let Some(parent) = sock_path.parent().filter(|p| !p.as_os_str().is_empty()) {
            let existed = parent.exists();
            fs::create_dir_all(parent).ok()?;
            if !existed || parent.file_name() == Some(OsStr::new(".koe")) {
                fs::set_permissions(parent, fs::Permissions::from_mode(0o700)).ok()?;
            }
        }
        if let Ok(meta) = fs::symlink_metadata(&sock_path) {
            if !meta.file_type().is_socket() {
                return None;
            }
            unlink_matching_socket(&sock_path, Some(meta.ino()));
        }

        let listener = UnixListener::bind(&sock_path).ok()?;
        let sock_ino = fs::symlink_metadata(&sock_path).ok().map(|m| m.ino());
        if listener.set_nonblocking(true).is_err()
            || fs::set_permissions(&sock_path, fs::Permissions::from_mode(0o600)).is_err()
        {
            unlink_matching_socket(&sock_path, sock_ino);
            return None;
        }

        let shutdown = Arc::new(AtomicBool::new(false));
        let active_streams = Arc::new(Mutex::new(BTreeMap::new()));
        let worker_state = Arc::new(WorkerState::default());

        let accept_shutdown = Arc::clone(&shutdown);
        let accept_streams = Arc::clone(&active_streams);
        let accept_workers = Arc::clone(&worker_state);
        let accept_thread = thread::spawn(move || {
            static NEXT_CONN: AtomicU64 = AtomicU64::new(1);
            while !accept_shutdown.load(Ordering::Acquire) {
                let stream = match listener.accept() {
                    Ok((stream, _)) => stream,
                    Err(error) if error.kind() == ErrorKind::WouldBlock => {
                        thread::park_timeout(ACCEPT_POLL_SLEEP);
                        continue;
                    }
                    Err(error) if error.kind() == ErrorKind::Interrupted => continue,
                    Err(_) => break,
                };
                if stream.set_nonblocking(false).is_err() {
                    continue;
                }
                set_nosigpipe(&stream);
                if accept_shutdown.load(Ordering::Acquire) || !verify_same_uid(&stream) {
                    let _ = stream.shutdown(Shutdown::Both);
                    continue;
                }
                let Ok(ctrl_clone) = stream.try_clone() else {
                    continue;
                };
                let conn_id = NEXT_CONN.fetch_add(1, Ordering::Relaxed);
                if let Ok(mut map) = accept_streams.lock() {
                    map.insert(conn_id, ctrl_clone);
                }
                let guard = WorkerGuard::acquire(
                    conn_id,
                    Arc::clone(&accept_streams),
                    Arc::clone(&accept_workers),
                );
                let conn_shutdown = Arc::clone(&accept_shutdown);
                thread::spawn(move || {
                    let _guard = guard;
                    serve_client(handle, stream, conn_shutdown);
                });
            }
        });

        Some(Self {
            sock_path,
            sock_ino,
            shutdown,
            active_streams,
            worker_state,
            accept_thread: Some(accept_thread),
        })
    }
}

impl Drop for BridgeServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        if let Some(accept_thread) = self.accept_thread.take() {
            accept_thread.thread().unpark();
            let _ = accept_thread.join();
        }
        unlink_matching_socket(&self.sock_path, self.sock_ino);
        if let Ok(mut map) = self.active_streams.lock() {
            for (_, stream) in std::mem::take(&mut *map) {
                let _ = stream.shutdown(Shutdown::Both);
            }
        }
        if let Ok(guard) = self.worker_state.count.lock() {
            let _ = self.worker_state.cvar.wait_timeout_while(
                guard,
                Duration::from_secs(2),
                |&mut count| count > 0,
            );
        }
    }
}

fn unlink_matching_socket(path: &Path, expected_ino: Option<u64>) {
    let Ok(meta) = fs::symlink_metadata(path) else {
        return;
    };
    if meta.file_type().is_socket() && expected_ino.is_some_and(|ino| meta.ino() == ino) {
        let _ = fs::remove_file(path);
    }
}

fn set_nosigpipe(stream: &UnixStream) {
    let one: libc::c_int = 1;
    // SAFETY: `stream` owns a valid AF_UNIX socket file descriptor.
    #[allow(unsafe_code)]
    unsafe {
        let _ = libc::setsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_NOSIGPIPE,
            (&raw const one).cast::<libc::c_void>(),
            std::mem::size_of::<libc::c_int>() as libc::socklen_t,
        );
    }
}

fn verify_same_uid(stream: &UnixStream) -> bool {
    let mut euid: libc::uid_t = u32::MAX;
    let mut egid: libc::gid_t = u32::MAX;
    // SAFETY: `stream` owns an active connected AF_UNIX socket descriptor; `getuid` has no preconditions.
    #[allow(unsafe_code)]
    unsafe {
        let rc = libc::getpeereid(stream.as_raw_fd(), &mut euid, &mut egid);
        rc == 0 && euid == libc::getuid()
    }
}

fn serve_client(handle: u64, stream: UnixStream, shutdown: Arc<AtomicBool>) {
    let Ok(mut writer) = stream.try_clone() else {
        return;
    };
    set_nosigpipe(&writer);
    let mut reader = BufReader::new(stream);

    loop {
        if shutdown.load(Ordering::Acquire) {
            break;
        }
        let mut line = String::new();
        let Ok(read) = reader
            .by_ref()
            .take(MAX_LINE_BYTES + 1)
            .read_line(&mut line)
        else {
            break;
        };
        if read == 0 {
            break;
        }
        if read as u64 > MAX_LINE_BYTES {
            let resp = jsonrpc_error(Value::Null, -32600, "请求超过 2 MiB 限制");
            let _ = writeln!(writer, "{resp}");
            let _ = writer.flush();
            break;
        }
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(val) => val,
            Err(_) => {
                let resp = jsonrpc_error(Value::Null, -32700, "无效 JSON");
                if writeln!(writer, "{resp}").is_err() || writer.flush().is_err() {
                    break;
                }
                continue;
            }
        };

        let Some(method) = request.get("method").and_then(Value::as_str) else {
            let id = request.get("id").cloned().unwrap_or(Value::Null);
            let resp = jsonrpc_error(id, -32600, "无效 JSON-RPC 请求");
            if writeln!(writer, "{resp}").is_err() || writer.flush().is_err() {
                break;
            }
            continue;
        };

        let id = request.get("id").cloned().unwrap_or(Value::Null);
        let response = match handle_rpc_call(handle, method, &request, &shutdown) {
            Ok(result) => jsonrpc_result(id, result),
            Err((code, message)) => jsonrpc_error(id, code, &message),
        };
        if writeln!(writer, "{response}").is_err() || writer.flush().is_err() {
            break;
        }
    }
}

fn handle_rpc_call(
    handle: u64,
    method: &str,
    request: &Value,
    shutdown: &Arc<AtomicBool>,
) -> Result<Value, (i64, String)> {
    match method {
        "koe/status" => with_session(handle, |rt| {
            let t = now(0);
            rt.poll_timers(0, t);
            rt.snapshot(t)
        })
        .ok_or_else(|| (-32000, "Koe 会话已关闭".to_string())),
        "koe/doctor" => with_session(handle, |rt| rt.doctor_snapshot(now(0)))
            .ok_or_else(|| (-32000, "Koe 会话已关闭".to_string())),
        "koe/diagnostics" => with_session(handle, |rt| {
            serde_json::to_value(rt.export_diagnostics_bundle(now(0)))
                .map_err(|e| (-32603, format!("序列化诊断包失败：{e}")))
        })
        .ok_or_else(|| (-32000, "Koe 会话已关闭".to_string()))?,
        "koe/mcp_tools_list" => Ok(KoeRuntime::mcp_tools_list()),
        "koe/mcp_tool_call" => handle_mcp_tool_call(handle, request, shutdown),
        _ => Err((-32601, "未知方法".to_string())),
    }
}

fn handle_mcp_tool_call(
    handle: u64,
    request: &Value,
    shutdown: &Arc<AtomicBool>,
) -> Result<Value, (i64, String)> {
    let params = request.get("params").unwrap_or(&Value::Null);
    let name = params
        .get("name")
        .and_then(Value::as_str)
        .ok_or_else(|| (-32602, "缺少工具名称".to_string()))?;
    let arguments = params
        .get("arguments")
        .cloned()
        .unwrap_or_else(|| json!({}));

    let outcome = drive_mcp_tool_blocking(
        (),
        |()| {
            with_session(handle, |rt| rt.call_mcp_tool_step(name, &arguments, now(0)))
                .ok_or_else(|| McpToolError {
                    code: -32000,
                    message: "Koe 会话已关闭".to_string(),
                })?
        },
        |(), _elapsed_ms| {
            if shutdown.load(Ordering::Acquire) {
                return Ok(Some(Err("Koe 会话正在关闭".into())));
            }
            Ok(with_session(handle, |rt| rt.poll_mcp_ask(0, now(0)))
                .unwrap_or_else(|| Some(Err("Koe 会话已关闭".into()))))
        },
    );

    match outcome {
        Err(McpToolError { code, message }) => Err((code, message)),
        Ok(Ok(value)) => Ok(json!({
            "isError": false,
            "value": value
        })),
        Ok(Err(error)) => Ok(json!({
            "isError": true,
            "error": error
        })),
    }
}

fn jsonrpc_result(id: Value, result: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "result": result
    })
}

fn jsonrpc_error(id: Value, code: i64, message: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": {
            "code": code,
            "message": message
        }
    })
}

#[cfg(test)]
#[path = "local_bridge_tests.rs"]
pub(crate) mod tests;
