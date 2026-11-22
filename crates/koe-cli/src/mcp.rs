use std::{
    io::{self, BufRead, Read, Write},
    path::Path,
};

use koe_runtime::{drive_mcp_tool_blocking, KoeRuntime, McpToolError};
use serde_json::{json, Value};

use crate::bridge_client::BridgeClient;

const PROTOCOL_VERSION: &str = "2025-11-25";
const MAX_LINE_BYTES: u64 = 2 * 1024 * 1024;

pub(crate) enum McpBackend<'a> {
    Offline(&'a mut KoeRuntime),
    Online {
        client: &'a mut BridgeClient,
        workspace: &'a Path,
    },
}

pub(crate) fn serve(mut backend: McpBackend<'_>) -> Result<(), String> {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut initialized = false;
    let mut ready = false;
    loop {
        let mut line = String::new();
        let read = input
            .by_ref()
            .take(MAX_LINE_BYTES + 1)
            .read_line(&mut line)
            .map_err(|e| e.to_string())?;
        if read == 0 {
            return Ok(());
        }
        if read as u64 > MAX_LINE_BYTES {
            writeln!(
                output,
                "{}",
                error(Value::Null, -32600, "请求超过 2 MiB 限制")
            )
            .map_err(|e| e.to_string())?;
            output.flush().map_err(|e| e.to_string())?;
            return Err("MCP 请求过长，连接已结束".into());
        }
        if line.trim().is_empty() {
            continue;
        }
        let request: Value = match serde_json::from_str(&line) {
            Ok(request) => request,
            Err(_) => {
                writeln!(output, "{}", error(Value::Null, -32700, "无效 JSON"))
                    .map_err(|e| e.to_string())?;
                output.flush().map_err(|e| e.to_string())?;
                continue;
            }
        };
        let Some(response) = handle(&mut backend, request, &mut initialized, &mut ready) else {
            continue;
        };
        writeln!(output, "{response}").map_err(|e| e.to_string())?;
        output.flush().map_err(|e| e.to_string())?;
    }
}

pub(crate) fn call_offline_tool(
    runtime: &mut KoeRuntime,
    name: &str,
    args: &Value,
) -> Result<Result<Value, String>, McpToolError> {
    drive_mcp_tool_blocking(
        runtime,
        |rt| rt.call_mcp_tool_step(name, args, super::now()),
        |rt, elapsed_ms| Ok(rt.poll_mcp_ask(elapsed_ms, super::now())),
    )
}

fn handle(
    backend: &mut McpBackend<'_>,
    request: Value,
    initialized: &mut bool,
    ready: &mut bool,
) -> Option<Value> {
    let id = request.get("id").cloned();
    if request["jsonrpc"] != "2.0" || !request["method"].is_string() {
        return Some(error(
            id.unwrap_or(Value::Null),
            -32600,
            "无效 JSON-RPC 请求",
        ));
    }
    let method = request["method"].as_str().unwrap_or_default();
    if id.is_none() {
        if method == "notifications/initialized" && *initialized {
            *ready = true;
        }
        return None;
    }
    let id = id.unwrap_or(Value::Null);
    let result = match method {
        "initialize" => {
            if !request["params"]["protocolVersion"].is_string() {
                return Some(error(id, -32602, "缺少协议版本"));
            }
            *initialized = true;
            *ready = false;
            json!({
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": { "tools": { "listChanged": false } },
                "serverInfo": { "name": "koe", "version": env!("CARGO_PKG_VERSION") }
            })
        }
        "ping" => json!({}),
        _ if !*ready => return Some(error(id, -32600, "请先完成 MCP 初始化")),
        "tools/list" => match backend {
            McpBackend::Offline(_) => KoeRuntime::mcp_tools_list(),
            McpBackend::Online { client, workspace } => {
                match online_tools_list(client, workspace) {
                    Ok(list) => list,
                    Err(err) => return Some(error(id, err.code, &err.message)),
                }
            }
        },
        "tools/call" => {
            let Some(name) = request["params"]["name"].as_str() else {
                return Some(error(id, -32602, "缺少工具名称"));
            };
            let args = request["params"]
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            let outcome = match backend {
                McpBackend::Offline(runtime) => call_offline_tool(runtime, name, &args),
                McpBackend::Online { client, workspace } => {
                    online_tool_call(client, workspace, name, &args)
                }
            };
            match outcome {
                Err(McpToolError { code, message }) => return Some(error(id, code, &message)),
                Ok(Ok(value)) => {
                    json!({"content": [{"type": "text", "text": value.to_string()}], "isError": false})
                }
                Ok(Err(message)) => {
                    json!({"content": [{"type": "text", "text": message}], "isError": true})
                }
            }
        }
        _ => return Some(error(id, -32601, "未知方法")),
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

fn is_retryable_read_tool(name: &str) -> bool {
    matches!(
        name,
        "search"
            | "get_today_brief"
            | "list_records"
            | "get_record"
            | "list_review_items"
            | "device_status"
            | "poll_updates"
    )
}

fn ensure_connected(client: &mut BridgeClient, workspace: &Path) -> Result<(), McpToolError> {
    if client.is_connected() {
        return Ok(());
    }
    match BridgeClient::try_connect(workspace) {
        Ok(Some(reconnected)) => {
            *client = reconnected;
            Ok(())
        }
        Ok(None) => Err(McpToolError {
            code: -32603,
            message: "本地桥连接已断开，且未能重新连接".into(),
        }),
        Err(message) => Err(McpToolError {
            code: -32603,
            message,
        }),
    }
}

fn online_tools_list(client: &mut BridgeClient, workspace: &Path) -> Result<Value, McpToolError> {
    ensure_connected(client, workspace)?;
    match client.mcp_tools_list() {
        Ok(list) => Ok(list),
        Err(first_err) if client.is_disconnected() => {
            if let Ok(Some(reconnected)) = BridgeClient::try_connect(workspace) {
                *client = reconnected;
                return client.mcp_tools_list();
            }
            Err(first_err)
        }
        Err(err) => Err(err),
    }
}

fn online_tool_call(
    client: &mut BridgeClient,
    workspace: &Path,
    name: &str,
    args: &Value,
) -> Result<Result<Value, String>, McpToolError> {
    ensure_connected(client, workspace)?;
    match client.mcp_tool_call(name, args) {
        Ok(res) => Ok(res),
        Err(first_err) if client.is_disconnected() => {
            if !is_retryable_read_tool(name) {
                return Err(McpToolError {
                    code: first_err.code,
                    message: format!(
                        "{}；写入工具 {name} 未自动重试以避免重复操作",
                        first_err.message
                    ),
                });
            }
            if let Ok(Some(reconnected)) = BridgeClient::try_connect(workspace) {
                *client = reconnected;
                return client.mcp_tool_call(name, args);
            }
            Err(first_err)
        }
        Err(err) => Err(err),
    }
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::io::BufReader;
    use std::os::unix::{fs::PermissionsExt, net::UnixListener};
    use std::path::PathBuf;
    use std::sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc,
    };

    use koe_runtime::resolve_bridge_socket_path;

    struct TempMcpWorkspace(PathBuf);

    impl TempMcpWorkspace {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(1);
            let dir = std::env::temp_dir().join(format!(
                "kmcp-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }

        fn bind_listener(&self) -> UnixListener {
            let sock = resolve_bridge_socket_path(&self.0).unwrap();
            let listener = UnixListener::bind(&sock).unwrap();
            fs::set_permissions(&sock, fs::Permissions::from_mode(0o600)).unwrap();
            listener
        }
    }

    impl Drop for TempMcpWorkspace {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn retryable_read_tool_classification_matches_runtime_read_only_hints() {
        let defs = KoeRuntime::mcp_tool_definitions();
        assert_eq!(defs.len(), 16);
        for def in defs {
            let name = def["name"].as_str().unwrap();
            let read_only = def["annotations"]["readOnlyHint"].as_bool().unwrap_or(false);
            assert_eq!(
                is_retryable_read_tool(name),
                read_only,
                "retry policy drifted from readOnlyHint for tool {name}"
            );
        }
        assert!(!is_retryable_read_tool("unknown_tool"));
    }

    #[test]
    fn online_read_only_tool_retries_once_on_bridge_disconnect() {
        let ws = TempMcpWorkspace::new();
        let listener = ws.bind_listener();
        let seen_calls = Arc::new(AtomicUsize::new(0));
        let seen_server = Arc::clone(&seen_calls);

        let server = std::thread::spawn(move || {
            let (stream1, _) = listener.accept().unwrap();
            let mut reader1 = BufReader::new(stream1);
            let mut line1 = String::new();
            assert!(reader1.read_line(&mut line1).unwrap() > 0);
            seen_server.fetch_add(1, Ordering::SeqCst);
            drop(reader1);

            let (stream2, _) = listener.accept().unwrap();
            let mut reader2 = BufReader::new(stream2.try_clone().unwrap());
            let mut writer2 = stream2;
            let mut line2 = String::new();
            assert!(reader2.read_line(&mut line2).unwrap() > 0);
            let req: Value = serde_json::from_str(&line2).unwrap();
            assert_eq!(req["params"]["name"], "list_records");
            seen_server.fetch_add(1, Ordering::SeqCst);
            writeln!(
                writer2,
                "{}",
                json!({
                    "jsonrpc": "2.0",
                    "id": req["id"],
                    "result": { "isError": false, "value": { "total": 1 } }
                })
            )
            .unwrap();
            writer2.flush().unwrap();
        });

        let mut client = BridgeClient::try_connect(&ws.0).unwrap().unwrap();
        let result = online_tool_call(&mut client, &ws.0, "list_records", &json!({}))
            .expect("read-only tool must retry once after disconnect")
            .expect("tool value must be Ok");
        assert_eq!(result, json!({ "total": 1 }));
        assert_eq!(seen_calls.load(Ordering::SeqCst), 2);
        server.join().unwrap();
    }

    #[test]
    fn online_mutating_tools_never_auto_retry_on_bridge_disconnect() {
        for mutating_tool in ["create_note", "ask", "edit_transcript", "manage_record"] {
            let ws = TempMcpWorkspace::new();
            let listener = ws.bind_listener();
            let mutating_calls = Arc::new(AtomicUsize::new(0));
            let mutating_server = Arc::clone(&mutating_calls);
            let expected_name = mutating_tool.to_string();

            let server = std::thread::spawn(move || {
                let (stream1, _) = listener.accept().unwrap();
                let mut reader1 = BufReader::new(stream1);
                let mut line1 = String::new();
                assert!(reader1.read_line(&mut line1).unwrap() > 0);
                let req1: Value = serde_json::from_str(&line1).unwrap();
                if req1["params"]["name"] == expected_name {
                    mutating_server.fetch_add(1, Ordering::SeqCst);
                }
                drop(reader1);

                let (stream2, _) = listener.accept().unwrap();
                let mut reader2 = BufReader::new(stream2.try_clone().unwrap());
                let mut writer2 = stream2;
                let mut line2 = String::new();
                assert!(reader2.read_line(&mut line2).unwrap() > 0);
                let req2: Value = serde_json::from_str(&line2).unwrap();
                if req2["params"]["name"] == expected_name {
                    mutating_server.fetch_add(1, Ordering::SeqCst);
                }
                writeln!(
                    writer2,
                    "{}",
                    json!({
                        "jsonrpc": "2.0",
                        "id": req2["id"],
                        "result": { "isError": false, "value": { "recovered": true } }
                    })
                )
                .unwrap();
                writer2.flush().unwrap();
            });

            let mut client = BridgeClient::try_connect(&ws.0).unwrap().unwrap();
            let outcome = online_tool_call(&mut client, &ws.0, mutating_tool, &json!({}));
            assert!(
                outcome.is_err(),
                "mutating tool {mutating_tool} must surface an error rather than auto-retrying"
            );
            assert_eq!(
                mutating_calls.load(Ordering::SeqCst),
                1,
                "mutating tool {mutating_tool} must execute at most once on disconnect"
            );

            let recovered = online_tool_call(&mut client, &ws.0, "device_status", &json!({}))
                .expect("subsequent read-only call should reconnect cleanly")
                .expect("recovered value must be Ok");
            assert_eq!(recovered, json!({ "recovered": true }));
            server.join().unwrap();
        }
    }

    #[test]
    fn online_oversized_utf8_read_tool_does_not_retry_and_next_call_reconnects() {
        let ws = TempMcpWorkspace::new();
        let listener = ws.bind_listener();
        let seen_list_calls = Arc::new(AtomicUsize::new(0));
        let seen_server = Arc::clone(&seen_list_calls);

        let server = std::thread::spawn(move || {
            let (stream1, _) = listener.accept().unwrap();
            let mut reader1 = BufReader::new(stream1.try_clone().unwrap());
            let mut writer1 = stream1;
            let mut line1 = String::new();
            assert!(reader1.read_line(&mut line1).unwrap() > 0);
            let req1: Value = serde_json::from_str(&line1).unwrap();
            if req1["params"]["name"] == "list_records" {
                seen_server.fetch_add(1, Ordering::SeqCst);
            }
            let body = "中".repeat(MAX_LINE_BYTES as usize / 3 + 1000);
            let oversized = format!(
                "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"val\":\"{body}\"}}}}\n"
            );
            let _ = writer1.write_all(oversized.as_bytes());
            let _ = writer1.flush();

            let (stream2, _) = listener.accept().unwrap();
            let mut reader2 = BufReader::new(stream2.try_clone().unwrap());
            let mut writer2 = stream2;
            let mut line2 = String::new();
            assert!(reader2.read_line(&mut line2).unwrap() > 0);
            let req2: Value = serde_json::from_str(&line2).unwrap();
            if req2["params"]["name"] == "list_records" {
                seen_server.fetch_add(1, Ordering::SeqCst);
            }
            writeln!(
                writer2,
                "{}",
                json!({
                    "jsonrpc": "2.0",
                    "id": req2["id"],
                    "result": { "isError": false, "value": { "connected": true } }
                })
            )
            .unwrap();
            writer2.flush().unwrap();
        });

        let mut client = BridgeClient::try_connect(&ws.0).unwrap().unwrap();
        let err = online_tool_call(&mut client, &ws.0, "list_records", &json!({}))
            .expect_err("oversized UTF-8 response must fail without retrying");
        assert_eq!(err.code, -32600, "unexpected error: {err:?}");
        assert!(err.message.contains("超过 2 MiB 限制"));
        assert_eq!(
            seen_list_calls.load(Ordering::SeqCst),
            1,
            "oversized read-only response must not trigger a retry"
        );

        let next = online_tool_call(&mut client, &ws.0, "device_status", &json!({}))
            .expect("next call after poisoned oversized response must reconnect cleanly")
            .expect("next call value must be Ok");
        assert_eq!(next, json!({ "connected": true }));
        server.join().unwrap();
    }
}
