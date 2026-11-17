use std::{
    fs,
    io::{self, BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        net::UnixStream,
    },
    path::Path,
    time::Duration,
};

use koe_runtime::{resolve_bridge_socket_path, McpToolError};
use serde_json::{json, Value};

const MAX_LINE_BYTES: u64 = 2 * 1024 * 1024;

pub(crate) struct BridgeClient {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
    next_id: u64,
    disconnected: bool,
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
            reader: BufReader::new(stream),
            writer,
            next_id: 0,
            disconnected: false,
        }))
    }

    pub(crate) fn is_disconnected(&self) -> bool {
        self.disconnected
    }

    pub(crate) fn status(&mut self) -> Result<Value, String> {
        self.rpc("koe/status", json!({})).map_err(|e| e.message)
    }

    pub(crate) fn doctor(&mut self) -> Result<Value, String> {
        self.rpc("koe/doctor", json!({})).map_err(|e| e.message)
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
        self.next_id = self.next_id.saturating_add(1);
        let request = json!({
            "jsonrpc": "2.0",
            "id": self.next_id,
            "method": method,
            "params": params,
        });
        writeln!(self.writer, "{request}").map_err(|e| {
            self.disconnected = true;
            McpToolError {
                code: -32603,
                message: format!("本地桥写入失败：{e}"),
            }
        })?;
        self.writer.flush().map_err(|e| {
            self.disconnected = true;
            McpToolError {
                code: -32603,
                message: format!("本地桥刷新失败：{e}"),
            }
        })?;

        let mut line = String::new();
        let read = self
            .reader
            .by_ref()
            .take(MAX_LINE_BYTES + 1)
            .read_line(&mut line)
            .map_err(|e| {
                self.disconnected = true;
                McpToolError {
                    code: -32603,
                    message: format!("本地桥读取失败：{e}"),
                }
            })?;
        if read == 0 {
            self.disconnected = true;
            return Err(McpToolError {
                code: -32603,
                message: "本地桥连接已提前关闭".into(),
            });
        }
        if read as u64 > MAX_LINE_BYTES {
            return Err(McpToolError {
                code: -32600,
                message: "本地桥响应超过 2 MiB 限制".into(),
            });
        }
        let response: Value = serde_json::from_str(&line).map_err(|_| McpToolError {
            code: -32700,
            message: "本地桥返回了无效 JSON".into(),
        })?;
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
