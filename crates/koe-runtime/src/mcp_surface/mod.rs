mod blocking;
mod definitions;
mod read_tools;
#[cfg(test)]
mod tests;
mod write_tools;

pub use blocking::drive_mcp_tool_blocking;

use serde_json::Value;

use crate::KoeRuntime;

/// JSON-RPC parameter or tool-routing error returned before domain execution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpToolError {
    /// Standard JSON-RPC error code (such as `-32602` for invalid params).
    pub code: i64,
    /// Human-readable error message.
    pub message: String,
}

impl McpToolError {
    pub(super) fn invalid_params(message: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: message.into(),
        }
    }
}

/// Step result returned by [`KoeRuntime::call_mcp_tool_step`].
#[derive(Debug, Clone)]
pub enum McpToolCallState {
    /// Synchronous tool completion (`Ok(payload)` or `Err(domain_error)` mapped to `isError: true`).
    Completed(Result<Value, String>),
    /// Asynchronous `ask` job submitted; poll with [`KoeRuntime::poll_mcp_ask`] until `Some`.
    PendingAsk,
}


impl KoeRuntime {
    /// Validates and executes a single MCP tool call step without blocking on network I/O.
    pub fn call_mcp_tool_step(
        &mut self,
        name: &str,
        args: &Value,
        now: u64,
    ) -> Result<McpToolCallState, McpToolError> {
        let obj = args
            .as_object()
            .ok_or_else(|| McpToolError::invalid_params("工具参数必须是对象"))?;
        self.poll_timers(0, now);

        if Self::is_mcp_read_tool(name) {
            self.call_mcp_read_tool(name, obj, now)
        } else {
            self.call_mcp_write_tool(name, obj, now)
        }
    }
}
