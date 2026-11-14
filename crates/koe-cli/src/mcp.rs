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
        |rt, question, elapsed_ms| Ok(rt.poll_mcp_ask(question, elapsed_ms, super::now())),
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

fn online_tools_list(client: &mut BridgeClient, workspace: &Path) -> Result<Value, McpToolError> {
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
    match client.mcp_tool_call(name, args) {
        Ok(res) => Ok(res),
        Err(first_err) if client.is_disconnected() => {
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
