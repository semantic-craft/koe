use std::{
    fs,
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        net::UnixStream,
    },
    path::{Path, PathBuf},
    time::Duration,
};

use koe_runtime::{resolve_bridge_socket_path, McpToolError};
use serde_json::{json, Value};

const MAX_LINE_BYTES: u64 = 2 * 1024 * 1024;
pub(crate) const BRIDGE_OFFLINE_ERROR_CODE: i64 = -32001;
pub(crate) const BRIDGE_OFFLINE_ERROR_MESSAGE: &str =
    "Koe.app is not running; start Koe.app to access live BLE and workspace";

pub(crate) struct BridgeOnlyClient {
    workspace: PathBuf,
    client: Option<BridgeClient>,
}

impl BridgeOnlyClient {
    pub(crate) fn new(workspace: PathBuf) -> Self {
        Self {
            workspace,
            client: None,
        }
    }

    fn connect(&self) -> Result<BridgeClient, McpToolError> {
        match BridgeClient::try_connect(&self.workspace) {
            Ok(Some(connected)) => Ok(connected),
            Ok(None) => Err(McpToolError {
                code: BRIDGE_OFFLINE_ERROR_CODE,
                message: BRIDGE_OFFLINE_ERROR_MESSAGE.into(),
            }),
            Err(message) => Err(McpToolError {
                code: -32603,
                message,
            }),
        }
    }

    pub(crate) fn call_tool(
        &mut self,
        name: &str,
        args: &Value,
        retryable_read: bool,
    ) -> Result<Result<Value, String>, McpToolError> {
        let mut client = match self.client.take() {
            Some(existing) if existing.is_connected() => existing,
            _ => self.connect()?,
        };
        match client.mcp_tool_call(name, args) {
            Ok(res) => {
                self.client = Some(client);
                Ok(res)
            }
            Err(first_err) if client.is_disconnected() => {
                if !retryable_read {
                    return Err(McpToolError {
                        code: first_err.code,
                        message: format!(
                            "{}；写入工具 {name} 未自动重试以避免重复操作",
                            first_err.message
                        ),
                    });
                }
                let mut reconnected = self.connect()?;
                let retry_res = reconnected.mcp_tool_call(name, args);
                if reconnected.is_connected() {
                    self.client = Some(reconnected);
                }
                retry_res
            }
            Err(err) => {
                if client.is_connected() {
                    self.client = Some(client);
                }
                Err(err)
            }
        }
    }
}

enum BridgeConnectionState {
    Connected {
        reader: BufReader<UnixStream>,
        writer: UnixStream,
    },
    Disconnected,
    Poisoned,
}

pub(crate) struct BridgeClient {
    state: BridgeConnectionState,
    next_id: u64,
}

impl BridgeClient {
    pub(crate) fn try_connect(workspace: &Path) -> Result<Option<Self>, String> {
        let Some(sock_path) = resolve_bridge_socket_path(workspace) else {
            return Ok(None);
        };
        let mut meta = match fs::symlink_metadata(&sock_path) {
            Ok(meta) => meta,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
            Err(err) => return Err(format!("无法检查本地桥套接字：{err}")),
        };
        if !meta.file_type().is_socket() {
            return Err("本地桥路径不是 Unix 套接字，已拒绝连接".into());
        }
        if (meta.mode() & 0o077) != 0 {
            std::thread::sleep(Duration::from_millis(15));
            meta = match fs::symlink_metadata(&sock_path) {
                Ok(rechecked) => rechecked,
                Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(None),
                Err(err) => return Err(format!("无法检查本地桥套接字：{err}")),
            };
            if !meta.file_type().is_socket() {
                return Err("本地桥路径不是 Unix 套接字，已拒绝连接".into());
            }
            if (meta.mode() & 0o077) != 0 {
                return Err("本地桥套接字权限不安全，已拒绝连接".into());
            }
        }
        if workspace.exists() {
            let ws_meta =
                fs::metadata(workspace).map_err(|e| format!("无法检查工作区所有者：{e}"))?;
            if meta.uid() != ws_meta.uid() {
                return Err("本地桥套接字所有者与工作区不一致，已拒绝连接".into());
            }
        }

        let stream = match UnixStream::connect(&sock_path) {
            Ok(stream) => stream,
            Err(err)
                if matches!(
                    err.kind(),
                    io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
                ) =>
            {
                return Ok(None);
            }
            Err(err) => return Err(format!("连接本地桥失败：{err}")),
        };
        let writer = stream
            .try_clone()
            .map_err(|e| format!("初始化本地桥通道失败：{e}"))?;
        Ok(Some(Self {
            state: BridgeConnectionState::Connected {
                reader: BufReader::new(stream),
                writer,
            },
            next_id: 0,
        }))
    }

    pub(crate) fn is_connected(&self) -> bool {
        matches!(self.state, BridgeConnectionState::Connected { .. })
    }

    pub(crate) fn is_disconnected(&self) -> bool {
        matches!(self.state, BridgeConnectionState::Disconnected)
    }

    pub(crate) fn status(&mut self) -> Result<Value, String> {
        self.rpc("koe/status", json!({})).map_err(|e| e.message)
    }

    pub(crate) fn doctor(&mut self) -> Result<Value, String> {
        self.rpc("koe/doctor", json!({})).map_err(|e| e.message)
    }

    pub(crate) fn diagnostics(&mut self) -> Result<Value, String> {
        self.rpc("koe/diagnostics", json!({})).map_err(|e| e.message)
    }

    pub(crate) fn mcp_tools_list(&mut self) -> Result<Value, McpToolError> {
        self.rpc("koe/mcp_tools_list", json!({}))
    }

    pub(crate) fn mcp_tool_call(
        &mut self,
        name: &str,
        arguments: &Value,
    ) -> Result<Result<Value, String>, McpToolError> {
        let result = self.rpc(
            "koe/mcp_tool_call",
            json!({
                "name": name,
                "arguments": arguments,
            }),
        )?;
        if result["isError"] == Value::Bool(true) {
            let msg = result["error"].as_str().unwrap_or("操作失败").to_string();
            Ok(Err(msg))
        } else {
            Ok(Ok(result.get("value").cloned().unwrap_or(Value::Null)))
        }
    }

    pub(crate) fn call_tool_value(
        &mut self,
        name: &str,
        arguments: Value,
    ) -> Result<Value, String> {
        match self.mcp_tool_call(name, &arguments) {
            Ok(inner) => inner,
            Err(err) => Err(err.message),
        }
    }

    fn rpc(&mut self, method: &str, params: Value) -> Result<Value, McpToolError> {
        let (reader, writer) = match &mut self.state {
            BridgeConnectionState::Connected { reader, writer } => (reader, writer),
            BridgeConnectionState::Disconnected => {
                return Err(McpToolError {
                    code: -32603,
                    message: "本地桥连接已断开".into(),
                });
            }
            BridgeConnectionState::Poisoned => {
                return Err(McpToolError {
                    code: -32600,
                    message: "本地桥连接已失效，请重新连接".into(),
                });
            }
        };
        self.next_id = self.next_id.saturating_add(1);
        let request = json!({
            "jsonrpc": "2.0",
            "id": self.next_id,
            "method": method,
            "params": params,
        });
        if let Err(e) = writeln!(writer, "{request}") {
            self.state = BridgeConnectionState::Disconnected;
            return Err(McpToolError {
                code: -32603,
                message: format!("本地桥写入失败：{e}"),
            });
        }
        if let Err(e) = writer.flush() {
            self.state = BridgeConnectionState::Disconnected;
            return Err(McpToolError {
                code: -32603,
                message: format!("本地桥刷新失败：{e}"),
            });
        }

        let mut buf = Vec::new();
        let read = match reader
            .by_ref()
            .take(MAX_LINE_BYTES + 1)
            .read_until(b'\n', &mut buf)
        {
            Ok(n) => n,
            Err(e) => {
                self.state = BridgeConnectionState::Disconnected;
                return Err(McpToolError {
                    code: -32603,
                    message: format!("本地桥读取失败：{e}"),
                });
            }
        };
        if read == 0 {
            self.state = BridgeConnectionState::Disconnected;
            return Err(McpToolError {
                code: -32603,
                message: "本地桥连接已提前关闭".into(),
            });
        }
        if read as u64 > MAX_LINE_BYTES {
            self.state = BridgeConnectionState::Poisoned;
            return Err(McpToolError {
                code: -32600,
                message: "本地桥响应超过 2 MiB 限制".into(),
            });
        }
        let response: Value = match serde_json::from_slice(&buf) {
            Ok(val) => val,
            Err(_) if !buf.ends_with(b"\n") => {
                self.state = BridgeConnectionState::Disconnected;
                return Err(McpToolError {
                    code: -32603,
                    message: "本地桥连接在响应未完成时关闭".into(),
                });
            }
            Err(_) => {
                self.state = BridgeConnectionState::Poisoned;
                return Err(McpToolError {
                    code: -32700,
                    message: "本地桥返回了无效 JSON".into(),
                });
            }
        };
        if let Some(err_obj) = response.get("error").and_then(Value::as_object) {
            let code = err_obj.get("code").and_then(Value::as_i64).unwrap_or(-32603);
            let message = err_obj
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("本地桥请求失败")
                .to_string();
            return Err(McpToolError { code, message });
        }
        Ok(response.get("result").cloned().unwrap_or(Value::Null))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::{fs::PermissionsExt, net::UnixListener};
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct TempSocketWorkspace(PathBuf);

    impl TempSocketWorkspace {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(1);
            let dir = std::env::temp_dir().join(format!(
                "kbc-{}-{}",
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

    impl Drop for TempSocketWorkspace {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn oversized_response_poisons_stream_prevents_mid_frame_desync_and_allows_clean_reconnect() {
        let ws = TempSocketWorkspace::new();
        let listener = ws.bind_listener();

        let server = std::thread::spawn(move || {
            let (stream1, _) = listener.accept().unwrap();
            let mut reader1 = BufReader::new(stream1.try_clone().unwrap());
            let mut writer1 = stream1;
            let mut req1 = String::new();
            assert!(reader1.read_line(&mut req1).unwrap() > 0);
            let pad = "A".repeat(MAX_LINE_BYTES as usize + 4096);
            let oversized = format!(
                "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"pad\":\"{pad}\"}}}}\n"
            );
            let _ = writer1.write_all(oversized.as_bytes());
            let _ = writer1.flush();

            let (stream2, _) = listener.accept().unwrap();
            let mut reader2 = BufReader::new(stream2.try_clone().unwrap());
            let mut writer2 = stream2;
            let mut req2 = String::new();
            assert!(reader2.read_line(&mut req2).unwrap() > 0);
            writeln!(
                writer2,
                "{}",
                json!({"jsonrpc": "2.0", "id": 1, "result": {"fresh": true}})
            )
            .unwrap();
            writer2.flush().unwrap();
        });

        let mut client = BridgeClient::try_connect(&ws.0)
            .unwrap()
            .expect("client must connect");
        let first_err = client.status().expect_err("oversized response must fail");
        assert!(first_err.contains("2 MiB"), "unexpected error: {first_err}");
        assert!(!client.is_connected());
        assert!(!client.is_disconnected());

        let second_err = client
            .status()
            .expect_err("reusing poisoned client must fail without reading leftover bytes");
        assert!(
            !second_err.contains("无效 JSON"),
            "stream was not dropped; second call read mid-frame tail bytes: {second_err}"
        );
        assert!(second_err.contains("失效"), "unexpected reuse error: {second_err}");

        let mut reconnected = BridgeClient::try_connect(&ws.0)
            .unwrap()
            .expect("fresh client must reconnect");
        let fresh = reconnected.status().expect("reconnected client must succeed");
        assert_eq!(fresh, json!({"fresh": true}));
        server.join().unwrap();
    }

    #[test]
    fn malformed_json_response_poisons_stream_so_subsequent_calls_fail_cleanly() {
        let ws = TempSocketWorkspace::new();
        let listener = ws.bind_listener();

        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut writer = stream;
            let mut req = String::new();
            assert!(reader.read_line(&mut req).unwrap() > 0);
            let combined = format!(
                "not-valid-json\n{}\n",
                json!({"jsonrpc": "2.0", "id": 2, "result": {"leaked": true}})
            );
            let _ = writer.write_all(combined.as_bytes());
            let _ = writer.flush();
        });

        let mut client = BridgeClient::try_connect(&ws.0)
            .unwrap()
            .expect("client must connect");
        let first_err = client.status().expect_err("invalid JSON must fail");
        assert!(first_err.contains("无效 JSON"), "unexpected error: {first_err}");
        assert!(!client.is_connected());

        let second_err = client
            .status()
            .expect_err("poisoned client must reject reuse rather than reading stale frames");
        assert!(second_err.contains("失效"), "unexpected reuse error: {second_err}");
        server.join().unwrap();
    }

    #[test]
    fn oversized_utf8_chinese_response_cuts_mid_char_and_still_poisons_with_32600() {
        let ws = TempSocketWorkspace::new();
        let listener = ws.bind_listener();

        let server = std::thread::spawn(move || {
            let (stream1, _) = listener.accept().unwrap();
            let mut reader1 = BufReader::new(stream1.try_clone().unwrap());
            let mut writer1 = stream1;
            let mut req1 = String::new();
            assert!(reader1.read_line(&mut req1).unwrap() > 0);
            let body = "中".repeat(MAX_LINE_BYTES as usize / 3 + 1000);
            let oversized = format!(
                "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{{\"val\":\"{body}\"}}}}\n"
            );
            assert!(
                !oversized.is_char_boundary((MAX_LINE_BYTES + 1) as usize),
                "test payload must cut mid UTF-8 character at MAX_LINE_BYTES + 1"
            );
            let _ = writer1.write_all(oversized.as_bytes());
            let _ = writer1.flush();

            let (stream2, _) = listener.accept().unwrap();
            let mut reader2 = BufReader::new(stream2.try_clone().unwrap());
            let mut writer2 = stream2;
            let mut req2 = String::new();
            assert!(reader2.read_line(&mut req2).unwrap() > 0);
            writeln!(
                writer2,
                "{}",
                json!({"jsonrpc": "2.0", "id": 1, "result": {"fresh": true}})
            )
            .unwrap();
            writer2.flush().unwrap();
        });

        let mut client = BridgeClient::try_connect(&ws.0)
            .unwrap()
            .expect("client must connect");
        let err = client
            .mcp_tool_call("list_records", &json!({}))
            .expect_err("oversized Chinese UTF-8 response must fail");
        assert_eq!(err.code, -32600, "unexpected error: {err:?}");
        assert!(
            err.message.contains("超过 2 MiB 限制"),
            "unexpected error message: {}",
            err.message
        );
        assert!(!client.is_connected());
        assert!(
            !client.is_disconnected(),
            "oversized UTF-8 response must transition to Poisoned, not Disconnected"
        );

        let mut reconnected = BridgeClient::try_connect(&ws.0)
            .unwrap()
            .expect("fresh client must reconnect");
        assert_eq!(reconnected.status().unwrap(), json!({"fresh": true}));
        server.join().unwrap();
    }
}
