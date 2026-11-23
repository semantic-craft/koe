use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use super::{McpToolCallState, McpToolError};
use crate::SearchScope;
use koe_engine::product::Evidence;

pub(super) const MCP_ASK_TIMEOUT: Duration = Duration::from_secs(190);
pub(super) const MCP_ASK_POLL_INTERVAL: Duration = Duration::from_millis(25);
pub(super) const MCP_ASK_TIMEOUT_MESSAGE: &str = "问答未在期限内完成";

pub(super) fn ensure_allowed_keys(obj: &Map<String, Value>, allowed: &[&str]) -> Result<(), McpToolError> {
    if obj.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(McpToolError::invalid_params("工具参数包含未知字段"));
    }
    Ok(())
}

pub(super) fn required_str<'a>(obj: &'a Map<String, Value>, key: &str) -> Result<&'a str, McpToolError> {
    obj.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| McpToolError::invalid_params(format!("{key} 必须是字符串")))
}

pub(super) fn optional_str<'a>(
    obj: &'a Map<String, Value>,
    key: &str,
) -> Result<Option<&'a str>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.as_str())),
        Some(_) => Err(McpToolError::invalid_params(format!("{key} 必须是字符串"))),
    }
}

pub(super) fn optional_nullable_string(
    obj: &Map<String, Value>,
    key: &str,
) -> Result<Option<String>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(McpToolError::invalid_params(format!(
            "{key} 必须是字符串或 null"
        ))),
    }
}

pub(super) fn required_bool(obj: &Map<String, Value>, key: &str) -> Result<bool, McpToolError> {
    obj.get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| McpToolError::invalid_params(format!("{key} 必须是布尔值")))
}

pub(super) fn optional_bool(obj: &Map<String, Value>, key: &str) -> Result<Option<bool>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(McpToolError::invalid_params(format!("{key} 必须是布尔值"))),
    }
}

pub(super) fn optional_u64(obj: &Map<String, Value>, key: &str) -> Result<Option<u64>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| McpToolError::invalid_params(format!("{key} 必须是非负整数"))),
    }
}

pub(super) fn optional_limit(obj: &Map<String, Value>, default_limit: usize) -> Result<usize, McpToolError> {
    match optional_u64(obj, "limit")? {
        None => Ok(default_limit),
        Some(n) if (1..=100).contains(&n) => Ok(n as usize),
        Some(_) => Err(McpToolError::invalid_params("limit 必须在 1 到 100 之间")),
    }
}

pub(super) fn optional_scope(obj: &Map<String, Value>) -> Result<SearchScope, McpToolError> {
    match obj.get("record_id") {
        None | Some(Value::Null) => Ok(SearchScope::All),
        Some(Value::String(id)) => Ok(SearchScope::Record(id.clone())),
        Some(_) => Err(McpToolError::invalid_params("record_id 必须是字符串")),
    }
}

/// Drives a blocking MCP tool invocation, polling asynchronous `ask` jobs until settled or timed out.
pub fn drive_mcp_tool_blocking<Ctx, StepFn, PollFn>(
    ctx: Ctx,
    step: StepFn,
    poll: PollFn,
) -> Result<Result<Value, String>, McpToolError>
where
    StepFn: FnOnce(&mut Ctx) -> Result<McpToolCallState, McpToolError>,
    PollFn: FnMut(&mut Ctx, u64) -> Result<Option<Result<Value, String>>, McpToolError>,
{
    drive_mcp_tool_blocking_with_limits(ctx, MCP_ASK_TIMEOUT, MCP_ASK_POLL_INTERVAL, step, poll)
}

pub(super) fn drive_mcp_tool_blocking_with_limits<Ctx, StepFn, PollFn>(
    mut ctx: Ctx,
    timeout: Duration,
    poll_interval: Duration,
    step: StepFn,
    mut poll: PollFn,
) -> Result<Result<Value, String>, McpToolError>
where
    StepFn: FnOnce(&mut Ctx) -> Result<McpToolCallState, McpToolError>,
    PollFn: FnMut(&mut Ctx, u64) -> Result<Option<Result<Value, String>>, McpToolError>,
{
    match step(&mut ctx)? {
        McpToolCallState::Completed(res) => Ok(res),
        McpToolCallState::PendingAsk => {
            let deadline = Instant::now() + timeout;
            let mut previous = Instant::now();
            loop {
                if Instant::now() >= deadline {
                    return Ok(Err(MCP_ASK_TIMEOUT_MESSAGE.into()));
                }
                std::thread::sleep(poll_interval);
                let current = Instant::now();
                let elapsed_ms = current.duration_since(previous).as_millis() as u64;
                previous = current;
                if let Some(done) = poll(&mut ctx, elapsed_ms)? {
                    return Ok(done);
                }
            }
        }
    }
}

pub(super) fn evidence_json(evidence: &Evidence) -> Value {
    json!({
        "recordId": evidence.source.record_id,
        "segmentId": evidence.source.segment_id.to_string(),
        "title": evidence.title,
        "quote": evidence.quote,
        "startMs": evidence.start_ms
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn drive_mcp_tool_blocking_returns_timeout_message_when_ask_never_settles() {
        let mut polls = 0usize;
        let result = drive_mcp_tool_blocking_with_limits(
            &mut polls,
            Duration::from_millis(15),
            Duration::from_millis(2),
            |_| Ok(McpToolCallState::PendingAsk),
            |count, _| {
                **count += 1;
                Ok(None)
            },
        );
        assert_eq!(result, Ok(Err(MCP_ASK_TIMEOUT_MESSAGE.to_string())));
        assert!(polls >= 1);
    }

    #[test]
    fn drive_mcp_tool_blocking_propagates_internal_poll_error() {
        let expected = McpToolError {
            code: -32603,
            message: "bridge poll failed".into(),
        };
        let result = drive_mcp_tool_blocking_with_limits(
            (),
            Duration::from_secs(1),
            Duration::from_millis(1),
            |_| Ok(McpToolCallState::PendingAsk),
            |_, _| Err(expected.clone()),
        );
        assert_eq!(result, Err(expected));
    }
}
