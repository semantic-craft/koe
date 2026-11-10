use std::io::{self, BufRead, Read, Write};

use koe_engine::product::SearchScope;
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

const PROTOCOL_VERSION: &str = "2025-11-25";
const MAX_LINE_BYTES: u64 = 2 * 1024 * 1024;

pub(crate) fn serve(runtime: &mut KoeRuntime) -> Result<(), String> {
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
        let Some(response) = handle(runtime, request, &mut initialized, &mut ready) else {
            continue;
        };
        writeln!(output, "{response}").map_err(|e| e.to_string())?;
        output.flush().map_err(|e| e.to_string())?;
    }
}

fn handle(
    runtime: &mut KoeRuntime,
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
            json!({"protocolVersion":PROTOCOL_VERSION,"capabilities":{"tools":{"listChanged":false}},
                "serverInfo":{"name":"koe","version":env!("CARGO_PKG_VERSION")}})
        }
        "ping" => json!({}),
        _ if !*ready => return Some(error(id, -32600, "请先完成 MCP 初始化")),
        "tools/list" => json!({"tools":tool_definitions()}),
        "tools/call" => {
            let Some(name) = request["params"]["name"].as_str() else {
                return Some(error(id, -32602, "缺少工具名称"));
            };
            if !matches!(name, "search" | "get_record" | "ask") {
                return Some(error(id, -32602, "未知工具"));
            }
            let args = request["params"]
                .get("arguments")
                .cloned()
                .unwrap_or_else(|| json!({}));
            if !args.is_object() {
                return Some(error(id, -32602, "工具参数必须是对象"));
            }
            match call(runtime, name, &args) {
                Ok(value) => {
                    json!({"content":[{"type":"text","text":value.to_string()}],"isError":false})
                }
                Err(message) => json!({"content":[{"type":"text","text":message}],"isError":true}),
            }
        }
        _ => return Some(error(id, -32601, "未知方法")),
    };
    Some(json!({"jsonrpc":"2.0","id":id,"result":result}))
}

fn error(id: Value, code: i64, message: &str) -> Value {
    json!({"jsonrpc":"2.0","id":id,"error":{"code":code,"message":message}})
}

fn tool_definitions() -> Vec<Value> {
    vec![
        json!({"name":"search","description":"搜索已保存记录，返回原文和 recordId/segmentId 来源。",
            "inputSchema":{"type":"object","properties":{"query":{"type":"string"},"record_id":{"type":"string"},"limit":{"type":"integer","minimum":1,"maximum":100}},"required":["query"],"additionalProperties":false},
            "annotations":{"readOnlyHint":true,"openWorldHint":false}}),
        json!({"name":"get_record","description":"读取指定记录的原文、纪要与重点。",
            "inputSchema":{"type":"object","properties":{"record_id":{"type":"string"}},"required":["record_id"],"additionalProperties":false},
            "annotations":{"readOnlyHint":true,"openWorldHint":false}}),
        json!({"name":"ask","description":"基于保存记录提问并保留问答历史；未配置模型时返回本地检索来源。",
            "inputSchema":{"type":"object","properties":{"question":{"type":"string"},"record_id":{"type":"string"}},"required":["question"],"additionalProperties":false},
            "annotations":{"readOnlyHint":false,"destructiveHint":false,"openWorldHint":false}}),
    ]
}

fn call(runtime: &mut KoeRuntime, name: &str, args: &Value) -> Result<Value, String> {
    let allowed: &[&str] = match name {
        "search" => &["query", "record_id", "limit"],
        "get_record" => &["record_id"],
        "ask" => &["question", "record_id"],
        _ => return Err("未知工具".into()),
    };
    if args
        .as_object()
        .is_some_and(|values| values.keys().any(|key| !allowed.contains(&key.as_str())))
    {
        return Err("工具参数包含未知字段".into());
    }
    let scope = match args.get("record_id") {
        None => SearchScope::All,
        Some(Value::String(id)) => SearchScope::Record(id.clone()),
        Some(_) => return Err("record_id 必须是字符串".into()),
    };
    match name {
        "search" => {
            let query = args["query"].as_str().ok_or("query 必须是字符串")?;
            let limit = match args.get("limit") {
                None => 10,
                Some(value) => value
                    .as_u64()
                    .filter(|n| (1..=100).contains(n))
                    .ok_or("limit 必须在 1 到 100 之间")? as usize,
            };
            super::search(runtime, query, &scope, limit)
        }
        "get_record" => {
            super::get_record(runtime, args["record_id"].as_str().ok_or("缺少 record_id")?)
        }
        "ask" => super::ask(
            runtime,
            args["question"].as_str().ok_or("question 必须是字符串")?,
            &scope,
        ),
        _ => unreachable!(),
    }
}
