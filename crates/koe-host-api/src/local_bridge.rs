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
        mpsc,
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use koe_runtime::{
    CompanionClientCommand, CompanionStreamEvent, KoeRuntime, McpToolCallState, McpToolError,
    resolve_bridge_socket_path,
};
use serde_json::{Value, json};

use crate::{now, sessions};

const MAX_LINE_BYTES: u64 = 2 * 1024 * 1024;
const ASK_TIMEOUT: Duration = Duration::from_secs(190);
const ASK_POLL_SLEEP: Duration = Duration::from_millis(25);
const SUBSCRIBER_CHANNEL_CAPACITY: usize = 512;
const ACCEPT_POLL_SLEEP: Duration = Duration::from_millis(25);

struct SubscriberEntry {
    id: u64,
    tx: mpsc::SyncSender<String>,
    socket: Option<UnixStream>,
}

#[derive(Clone, Default)]
pub(crate) struct SubscriberHub {
    subscribers: Arc<Mutex<Vec<SubscriberEntry>>>,
}

impl SubscriberHub {
    pub(crate) fn broadcast(&self, events: &[CompanionStreamEvent]) {
        if events.is_empty() {
            return;
        }
        let lines: Vec<String> = events
            .iter()
            .filter_map(|ev| serde_json::to_string(ev).ok())
            .filter(|line| !line.is_empty())
            .collect();
        if lines.is_empty() {
            return;
        }
        if let Ok(mut list) = self.subscribers.lock() {
            list.retain(|entry| {
                let ok = lines
                    .iter()
                    .all(|line| entry.tx.try_send(line.clone()).is_ok());
                if !ok {
                    if let Some(sock) = &entry.socket {
                        let _ = sock.shutdown(Shutdown::Both);
                    }
                }
                ok
            });
        }
    }

    fn subscribe(
        &self,
        hello_line: String,
        socket: Option<UnixStream>,
    ) -> (u64, mpsc::Receiver<String>) {
        static NEXT_SUB: AtomicU64 = AtomicU64::new(1);
        let id = NEXT_SUB.fetch_add(1, Ordering::Relaxed);
        let (tx, rx) = mpsc::sync_channel(SUBSCRIBER_CHANNEL_CAPACITY);
        let _ = tx.try_send(hello_line);
        if let Ok(mut list) = self.subscribers.lock() {
            list.push(SubscriberEntry { id, tx, socket });
        }
        (id, rx)
    }

    fn unsubscribe(&self, id: u64) {
        if let Ok(mut list) = self.subscribers.lock() {
            list.retain(|entry| entry.id != id);
        }
    }

    fn close_all(&self) {
        if let Ok(mut list) = self.subscribers.lock() {
            for entry in list.drain(..) {
                if let Some(sock) = &entry.socket {
                    let _ = sock.shutdown(Shutdown::Both);
                }
            }
        }
    }
}

struct ManualGateGuard {
    handle: u64,
    active: bool,
}

impl ManualGateGuard {
    fn new(handle: u64, active: bool) -> Self {
        Self { handle, active }
    }
}

impl Drop for ManualGateGuard {
    fn drop(&mut self) {
        if !self.active {
            return;
        }
        if let Ok(mut table) = sessions().lock() {
            if let Some(entry) = table.entries.get_mut(&self.handle) {
                entry.runtime.release_companion_manual_gate();
            }
        }
    }
}

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
    conn_id: Option<u64>,
    active_streams: Arc<Mutex<BTreeMap<u64, UnixStream>>>,
    worker_state: Arc<WorkerState>,
}

impl WorkerGuard {
    fn acquire(
        conn_id: Option<u64>,
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
        if let Some(id) = self.conn_id {
            if let Ok(mut streams) = self.active_streams.lock() {
                streams.remove(&id);
            }
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
    subscribers: SubscriberHub,
    active_streams: Arc<Mutex<BTreeMap<u64, UnixStream>>>,
    worker_state: Arc<WorkerState>,
    accept_thread: Option<JoinHandle<()>>,
}

impl BridgeServer {
    pub(crate) fn start(handle: u64, workspace: &Path, subscribers: SubscriberHub) -> Option<Self> {
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
                    Some(conn_id),
                    Arc::clone(&accept_streams),
                    Arc::clone(&accept_workers),
                );
                let conn_shutdown = Arc::clone(&accept_shutdown);
                let conn_streams = Arc::clone(&accept_streams);
                let conn_workers = Arc::clone(&accept_workers);
                thread::spawn(move || {
                    let _guard = guard;
                    serve_client(handle, stream, conn_shutdown, conn_streams, conn_workers);
                });
            }
        });

        Some(Self {
            sock_path,
            sock_ino,
            shutdown,
            subscribers,
            active_streams,
            worker_state,
            accept_thread: Some(accept_thread),
        })
    }
}

impl Drop for BridgeServer {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::SeqCst);
        self.subscribers.close_all();
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
    unsafe {
        let rc = libc::getpeereid(stream.as_raw_fd(), &mut euid, &mut egid);
        rc == 0 && euid == libc::getuid()
    }
}

fn serve_client(
    handle: u64,
    stream: UnixStream,
    shutdown: Arc<AtomicBool>,
    active_streams: Arc<Mutex<BTreeMap<u64, UnixStream>>>,
    worker_state: Arc<WorkerState>,
) {
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

        if matches!(method, "companion/subscribe" | "subscribe") {
            let auto_gate = extract_auto_gate(&request);
            serve_companion_subscription(
                handle,
                auto_gate,
                &mut reader,
                writer,
                shutdown,
                active_streams,
                worker_state,
            );
            return;
        }

        if matches!(
            method,
            "companion/set_capture_active" | "set_capture_active"
        ) {
            if let Some((active, reason)) = extract_capture_active(&request) {
                apply_capture_active(handle, active, reason);
                if let Some(id) = request.get("id").cloned() {
                    let resp = jsonrpc_result(id, json!({"ok": true}));
                    if writeln!(writer, "{resp}").is_err() || writer.flush().is_err() {
                        break;
                    }
                }
            } else if let Some(id) = request.get("id").cloned() {
                let resp = jsonrpc_error(id, -32602, "缺少 active 布尔字段");
                if writeln!(writer, "{resp}").is_err() || writer.flush().is_err() {
                    break;
                }
            }
            continue;
        }

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
        "koe/status" => {
            let (snap, subs, events) = {
                let mut table = sessions()
                    .lock()
                    .map_err(|_| (-32603, "会话锁不可用".to_string()))?;
                let entry = table
                    .entries
                    .get_mut(&handle)
                    .ok_or_else(|| (-32000, "Koe 会话已关闭".to_string()))?;
                let t = now(0);
                entry.runtime.poll_timers(0, t);
                let snap = entry.runtime.snapshot(t);
                let events = entry.runtime.drain_companion_events();
                (snap, entry.subscribers.clone(), events)
            };
            subs.broadcast(&events);
            Ok(snap)
        }
        "koe/doctor" => {
            let (doctor, subs, events) = {
                let mut table = sessions()
                    .lock()
                    .map_err(|_| (-32603, "会话锁不可用".to_string()))?;
                let entry = table
                    .entries
                    .get_mut(&handle)
                    .ok_or_else(|| (-32000, "Koe 会话已关闭".to_string()))?;
                let t = now(0);
                entry.runtime.poll_timers(0, t);
                let snap = entry.runtime.snapshot(t);
                let events = entry.runtime.drain_companion_events();
                let payload = json!({
                    "workspaceReadable": true,
                    "generation": snap["generation"],
                    "device": snap["device"],
                    "provider": snap["provider"],
                    "error": snap["error"]
                });
                (payload, entry.subscribers.clone(), events)
            };
            subs.broadcast(&events);
            Ok(doctor)
        }
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

    let (step_res, subs, events) = {
        let mut table = sessions()
            .lock()
            .map_err(|_| (-32603, "会话锁不可用".to_string()))?;
        let entry = table
            .entries
            .get_mut(&handle)
            .ok_or_else(|| (-32000, "Koe 会话已关闭".to_string()))?;
        let res = entry.runtime.call_mcp_tool_step(name, &arguments, now(0));
        let events = entry.runtime.drain_companion_events();
        (res, entry.subscribers.clone(), events)
    };
    subs.broadcast(&events);

    match step_res {
        Err(McpToolError { code, message }) => Err((code, message)),
        Ok(McpToolCallState::Completed(Ok(value))) => Ok(json!({
            "isError": false,
            "value": value
        })),
        Ok(McpToolCallState::Completed(Err(error))) => Ok(json!({
            "isError": true,
            "error": error
        })),
        Ok(McpToolCallState::PendingAsk { question }) => {
            let deadline = Instant::now() + ASK_TIMEOUT;
            loop {
                if shutdown.load(Ordering::Acquire) {
                    return Ok(json!({"isError": true, "error": "Koe 会话正在关闭"}));
                }
                if Instant::now() >= deadline {
                    return Ok(json!({"isError": true, "error": "问答未在期限内完成"}));
                }
                thread::sleep(ASK_POLL_SLEEP);
                let (poll_res, poll_subs, poll_events) = {
                    let mut table = sessions()
                        .lock()
                        .map_err(|_| (-32603, "会话锁不可用".to_string()))?;
                    let Some(entry) = table.entries.get_mut(&handle) else {
                        return Ok(json!({"isError": true, "error": "Koe 会话已关闭"}));
                    };
                    let res = entry.runtime.poll_mcp_ask(&question, 0, now(0));
                    let evs = entry.runtime.drain_companion_events();
                    (res, entry.subscribers.clone(), evs)
                };
                poll_subs.broadcast(&poll_events);
                if let Some(done) = poll_res {
                    return Ok(match done {
                        Ok(value) => json!({"isError": false, "value": value}),
                        Err(error) => json!({"isError": true, "error": error}),
                    });
                }
            }
        }
    }
}

fn serve_companion_subscription(
    handle: u64,
    auto_gate: Option<bool>,
    reader: &mut BufReader<UnixStream>,
    mut writer: UnixStream,
    shutdown: Arc<AtomicBool>,
    active_streams: Arc<Mutex<BTreeMap<u64, UnixStream>>>,
    worker_state: Arc<WorkerState>,
) {
    let manual_gate = auto_gate == Some(false);
    let evict_socket = writer.try_clone().ok();
    let setup = {
        sessions().lock().ok().and_then(|mut table| {
            let entry = table.entries.get_mut(&handle)?;
            if manual_gate {
                entry.runtime.acquire_companion_manual_gate();
            }
            let drained = entry.runtime.drain_companion_events();
            entry.subscribers.broadcast(&drained);
            let hello = entry.runtime.companion_hello();
            let hello_line = serde_json::to_string(&hello).ok()?;
            let subs = entry.subscribers.clone();
            let (sub_id, rx) = subs.subscribe(hello_line, evict_socket);
            Some((subs, sub_id, rx))
        })
    };
    let Some((subs, sub_id, rx)) = setup else {
        let _ = writer.shutdown(Shutdown::Both);
        return;
    };
    let _manual_gate_guard = ManualGateGuard::new(handle, manual_gate);

    let _ = writer.set_write_timeout(Some(Duration::from_secs(2)));
    let writer_shutdown = Arc::clone(&shutdown);
    let writer_guard = WorkerGuard::acquire(None, active_streams, worker_state);
    let writer_thread = thread::spawn(move || {
        let _guard = writer_guard;
        while !writer_shutdown.load(Ordering::Acquire) {
            let Ok(line) = rx.recv() else {
                break;
            };
            if line.is_empty() {
                break;
            }
            if writeln!(writer, "{line}").is_err() || writer.flush().is_err() {
                break;
            }
        }
        let _ = writer.shutdown(Shutdown::Both);
    });

    while !shutdown.load(Ordering::Acquire) {
        let mut line = String::new();
        let Ok(read) = reader
            .by_ref()
            .take(MAX_LINE_BYTES + 1)
            .read_line(&mut line)
        else {
            break;
        };
        if read == 0 || read as u64 > MAX_LINE_BYTES {
            break;
        }
        if line.trim().is_empty() {
            continue;
        }
        let Ok(cmd_val) = serde_json::from_str::<Value>(&line) else {
            continue;
        };
        if let Ok(CompanionClientCommand::SetDictationActive { active }) =
            serde_json::from_value::<CompanionClientCommand>(cmd_val.clone())
        {
            if let Ok(mut table) = sessions().lock() {
                if let Some(entry) = table.entries.get_mut(&handle) {
                    entry.runtime.dispatch_json(
                        &serde_json::json!({"type":"set_dictation_active","active":active})
                            .to_string(),
                        0,
                    );
                }
            }
            continue;
        }
        if let Ok(CompanionClientCommand::SetCaptureActive { active, reason }) =
            serde_json::from_value::<CompanionClientCommand>(cmd_val.clone())
        {
            apply_capture_active(handle, active, reason);
            continue;
        }
        if let Some((active, reason)) = extract_capture_active(&cmd_val) {
            apply_capture_active(handle, active, reason);
        }
    }

    subs.unsubscribe(sub_id);
    let _ = writer_thread.join();
}

fn apply_capture_active(handle: u64, active: bool, reason: Option<String>) {
    let maybe_events = sessions().lock().ok().and_then(|mut table| {
        let entry = table.entries.get_mut(&handle)?;
        entry.runtime.set_companion_capture_active(active, reason);
        let events = entry.runtime.drain_companion_events();
        Some((entry.subscribers.clone(), events))
    });
    if let Some((subs, events)) = maybe_events {
        subs.broadcast(&events);
    }
}

fn extract_auto_gate(request: &Value) -> Option<bool> {
    request
        .get("params")
        .and_then(|p| p.get("autoGate"))
        .and_then(Value::as_bool)
        .or_else(|| request.get("autoGate").and_then(Value::as_bool))
}

fn extract_capture_active(request: &Value) -> Option<(bool, Option<String>)> {
    let method = request.get("method").and_then(Value::as_str)?;
    if !matches!(
        method,
        "set_capture_active" | "companion/set_capture_active"
    ) {
        return None;
    }
    let container = request
        .get("params")
        .filter(|v| v.is_object())
        .unwrap_or(request);
    let active = container.get("active").and_then(Value::as_bool)?;
    let reason = container
        .get("reason")
        .and_then(Value::as_str)
        .map(str::to_string);
    Some((active, reason))
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
mod tests {
    use std::sync::atomic::AtomicU64;

    use crate::HostSessionGuard;

    use super::*;

    fn temp_workspace() -> PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        std::env::temp_dir().join(format!(
            "koe-bridge-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn host_session_binds_0600_socket_serves_rpc_and_unlinks_on_destroy() {
        let ws = temp_workspace();
        let _ = fs::remove_dir_all(&ws);
        let sock_path = resolve_bridge_socket_path(&ws).unwrap();

        fs::create_dir_all(&ws).unwrap();
        drop(UnixListener::bind(&sock_path).unwrap());

        let session = HostSessionGuard::open(&ws).expect("host session should open");
        let meta = fs::symlink_metadata(&sock_path).unwrap();
        assert!(meta.file_type().is_socket());
        assert_eq!(meta.mode() & 0o777, 0o600);

        let mut client = UnixStream::connect(&sock_path).unwrap();
        writeln!(
            client,
            "{}",
            json!({"jsonrpc": "2.0", "id": 1, "method": "koe/mcp_tools_list"})
        )
        .unwrap();
        client.flush().unwrap();
        let mut reader = BufReader::new(client.try_clone().unwrap());
        let mut resp_line = String::new();
        reader.read_line(&mut resp_line).unwrap();
        let resp: Value = serde_json::from_str(&resp_line).unwrap();
        assert_eq!(resp["result"]["tools"].as_array().unwrap().len(), 16);

        drop(client);
        drop(reader);
        drop(session);
        assert!(!sock_path.exists());
        let _ = fs::remove_dir_all(&ws);
    }

    #[test]
    fn host_session_destroy_finishes_after_socket_path_is_removed() {
        const CHILD_WORKSPACE: &str = "KOE_BRIDGE_DROP_TEST_WORKSPACE";
        if let Some(ws) = std::env::var_os(CHILD_WORKSPACE) {
            let ws = PathBuf::from(ws);
            let session = HostSessionGuard::open(&ws).unwrap();
            fs::remove_file(resolve_bridge_socket_path(&ws).unwrap()).unwrap();
            drop(session);
            return;
        }

        let ws = temp_workspace();
        let mut child = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "local_bridge::tests::host_session_destroy_finishes_after_socket_path_is_removed",
                "--nocapture",
            ])
            .env(CHILD_WORKSPACE, &ws)
            .spawn()
            .unwrap();
        let deadline = Instant::now() + Duration::from_secs(3);
        let status = loop {
            if let Some(status) = child.try_wait().unwrap() {
                break Some(status);
            }
            if Instant::now() >= deadline {
                child.kill().unwrap();
                child.wait().unwrap();
                break None;
            }
            thread::sleep(Duration::from_millis(10));
        };
        let _ = fs::remove_dir_all(&ws);
        assert!(
            status.is_some_and(|status| status.success()),
            "destroy did not finish after its socket path was removed"
        );
    }

    #[test]
    fn local_bridge_start_preserves_non_socket_files() {
        let ws = temp_workspace();
        fs::create_dir_all(&ws).unwrap();
        let path = resolve_bridge_socket_path(&ws).unwrap();
        fs::write(&path, b"unrelated file").unwrap();
        let bridge = BridgeServer::start(0, &ws, SubscriberHub::default());
        let rejected = bridge.is_none();
        drop(bridge);
        let contents = fs::read(&path).ok();
        let _ = fs::remove_dir_all(&ws);
        assert!(rejected, "bridge replaced a non-socket file");
        assert_eq!(contents.as_deref(), Some(b"unrelated file".as_slice()));
    }

    #[test]
    fn local_bridge_rejects_raw_dispatch_evicts_stalled_subscriber_and_scopes_manual_gate() {
        let base = PathBuf::from(format!("/tmp/kb-{}", std::process::id()));
        let container_ws = base.join(
            "Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace",
        );
        let _ = fs::remove_dir_all(&base);
        let sock_path = resolve_bridge_socket_path(&container_ws).unwrap();
        let dot_koe = sock_path.parent().unwrap();

        let session = HostSessionGuard::open(&container_ws).expect("host session should open");
        let dir_meta = fs::metadata(dot_koe).unwrap();
        assert_eq!(dir_meta.mode() & 0o777, 0o700);

        let mut rpc_client = UnixStream::connect(&sock_path).unwrap();
        writeln!(
            rpc_client,
            "{}",
            json!({
                "jsonrpc": "2.0",
                "id": 99,
                "method": "koe/dispatch",
                "params": {"command": {"type": "empty_trash"}}
            })
        )
        .unwrap();
        rpc_client.flush().unwrap();
        let mut rpc_reader = BufReader::new(rpc_client.try_clone().unwrap());
        let mut dispatch_resp_line = String::new();
        rpc_reader.read_line(&mut dispatch_resp_line).unwrap();
        let dispatch_resp: Value = serde_json::from_str(&dispatch_resp_line).unwrap();
        assert_eq!(dispatch_resp["error"]["code"], -32601);

        let mut manual_sub = UnixStream::connect(&sock_path).unwrap();
        manual_sub
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        writeln!(
            manual_sub,
            "{}",
            json!({"method": "companion/subscribe", "params": {"autoGate": false}})
        )
        .unwrap();
        manual_sub.flush().unwrap();
        let mut manual_reader = BufReader::new(manual_sub.try_clone().unwrap());
        let mut hello1 = String::new();
        manual_reader.read_line(&mut hello1).unwrap();
        assert!(hello1.contains("\"hello\""));

        let mut auto_sub = UnixStream::connect(&sock_path).unwrap();
        auto_sub
            .set_read_timeout(Some(Duration::from_secs(2)))
            .unwrap();
        writeln!(
            auto_sub,
            "{}",
            json!({"method": "companion/subscribe", "params": {"autoGate": true}})
        )
        .unwrap();
        auto_sub.flush().unwrap();
        let mut auto_reader = BufReader::new(auto_sub.try_clone().unwrap());
        let mut hello2 = String::new();
        auto_reader.read_line(&mut hello2).unwrap();
        assert!(hello2.contains("\"hello\""));

        {
            let table = sessions().lock().unwrap();
            let entry = table.entries.get(&session.handle()).unwrap();
            assert_eq!(entry.subscribers.subscribers.lock().unwrap().len(), 2);
        }

        let big_b64 = "A".repeat(1024);
        let flood_events: Vec<CompanionStreamEvent> = (1..=2_500)
            .map(|seq| CompanionStreamEvent::AudioPcm16 {
                device_id: "d3200".into(),
                epoch: "00000000-0000-4000-8000-000000000001".into(),
                sequence: seq,
                sample_rate_hz: 16_000,
                samples_le_b64: big_b64.clone(),
            })
            .collect();

        let subs = {
            let table = sessions().lock().unwrap();
            table
                .entries
                .get(&session.handle())
                .unwrap()
                .subscribers
                .clone()
        };

        let drain_auto = thread::spawn(move || {
            let mut count = 0usize;
            for _ in 0..2_500 {
                let mut line = String::new();
                if auto_reader.read_line(&mut line).unwrap_or(0) == 0 {
                    break;
                }
                count += 1;
            }
            count
        });

        for chunk in flood_events.chunks(25) {
            subs.broadcast(chunk);
        }

        let received_healthy = drain_auto.join().unwrap();
        assert_eq!(received_healthy, 2_500);
        assert_eq!(subs.subscribers.lock().unwrap().len(), 1);

        drop(manual_reader);
        drop(manual_sub);
        drop(auto_sub);
        drop(rpc_reader);
        drop(rpc_client);
        drop(session);
        let _ = fs::remove_dir_all(&base);
    }
}
