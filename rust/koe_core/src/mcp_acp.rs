//! Native JSON-RPC 2.0 MCP tool registry and ACP (Agent Communication Protocol)
//! reducer scaffold for Slice N.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use crate::domain::UtteranceSpine;

/// Canonical MCP tools exposed by Koe's local agent bridge (`Slice N`).
pub const KOE_MCP_TOOLS: [&str; 6] = [
    "list_recordings",
    "get_transcript",
    "get_minutes",
    "search_context",
    "sync_qwennote_hotwords",
    "export_koepack_v2",
];

/// Returns `true` if `tool_name` is a registered Koe MCP tool.
#[must_use]
pub fn is_supported_mcp_tool(tool_name: &str) -> bool {
    KOE_MCP_TOOLS.contains(&tool_name.trim())
}

/// Pure state for the MCP + ACP protocol subsystem (Slice N).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct McpAcpState {
    /// Total JSON-RPC 2.0 tool invocations handled.
    pub handled_calls: u64,
    /// Last invoked tool name, if any.
    pub last_tool: Option<String>,
}

/// Input events for [`McpAcpReducer`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpAcpEvent {
    /// Invoke a named MCP tool against the current [`UtteranceSpine`].
    InvokeTool {
        /// JSON-RPC request identifier.
        request_id: u64,
        /// MCP tool name.
        tool_name: String,
    },
}

/// Pure output from [`McpAcpReducer::reduce`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpAcpOutcome {
    /// Echoed JSON-RPC request identifier.
    pub request_id: u64,
    /// Whether the tool is supported and succeeded.
    pub supported: bool,
    /// Human-readable or JSON payload summary.
    pub payload_summary: String,
}

/// Pure reducer contract for the MCP/ACP server subsystem.
pub trait McpAcpReducer {
    /// Applies `event` to `state` against `spine` without side effects.
    fn reduce(
        state: &mut McpAcpState,
        spine: &UtteranceSpine,
        event: McpAcpEvent,
    ) -> McpAcpOutcome;
}

impl McpAcpReducer for McpAcpState {
    fn reduce(
        state: &mut McpAcpState,
        spine: &UtteranceSpine,
        event: McpAcpEvent,
    ) -> McpAcpOutcome {
        match event {
            McpAcpEvent::InvokeTool {
                request_id,
                tool_name,
            } => {
                let clean = tool_name.trim().to_string();
                let supported = is_supported_mcp_tool(&clean);
                if supported {
                    state.handled_calls = state.handled_calls.saturating_add(1);
                    state.last_tool = Some(clean.clone());
                }
                let payload_summary = if clean == "get_transcript" {
                    spine.format_cited_sources().join("\n")
                } else if supported {
                    format!("ok:{clean}:rev={}", spine.revision())
                } else {
                    format!("error:unsupported_tool:{clean}")
                };
                McpAcpOutcome {
                    request_id,
                    supported,
                    payload_summary,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mcp_registry_recognizes_canonical_tools_and_formats_transcript() {
        assert!(is_supported_mcp_tool("get_transcript"));
        assert!(is_supported_mcp_tool("export_koepack_v2"));
        assert!(!is_supported_mcp_tool("drop_database"));

        let mut spine = UtteranceSpine::new("mcp-session");
        spine.append_segment("第一条记录。", 0, 1_000, "zh", "qwen");
        let mut state = McpAcpState::default();
        let out = McpAcpState::reduce(
            &mut state,
            &spine,
            McpAcpEvent::InvokeTool {
                request_id: 7,
                tool_name: "get_transcript".to_string(),
            },
        );
        assert!(out.supported);
        assert_eq!(out.payload_summary, "[S1] 第一条记录。");
        assert_eq!(state.handled_calls, 1);
    }
}
