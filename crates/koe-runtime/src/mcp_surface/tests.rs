
use super::blocking::{
    drive_mcp_tool_blocking, drive_mcp_tool_blocking_with_limits, MCP_ASK_TIMEOUT_MESSAGE,
};
use super::*;
use serde_json::json;
use std::time::Duration;

    #[test]
    fn drive_mcp_tool_blocking_handles_immediate_polling_and_errors() {
        let immediate = drive_mcp_tool_blocking(
            (),
            |()| Ok(McpToolCallState::Completed(Ok(json!({ "ok": true })))),
            |(), _| unreachable!("poll must not run after immediate completion"),
        )
        .expect("protocol result");
        assert_eq!(immediate.expect("tool value")["ok"], true);

        let domain_err = drive_mcp_tool_blocking(
            (),
            |()| Ok(McpToolCallState::Completed(Err("domain failed".into()))),
            |(), _| unreachable!("poll must not run after immediate domain error"),
        )
        .expect("protocol result");
        assert_eq!(domain_err.unwrap_err(), "domain failed");

        let step_err = drive_mcp_tool_blocking(
            (),
            |()| Err(McpToolError::invalid_params("bad step")),
            |(), _| Ok(None),
        )
        .unwrap_err();
        assert_eq!(
            step_err,
            McpToolError {
                code: -32602,
                message: "bad step".into()
            }
        );

        #[derive(Default)]
        struct PollCtx {
            stepped: bool,
            polls: usize,
        }

        let mut poll_ctx = PollCtx::default();
        let polled = drive_mcp_tool_blocking(
            &mut poll_ctx,
            |ctx| {
                ctx.stepped = true;
                Ok(McpToolCallState::PendingAsk)
            },
            |ctx, elapsed_ms| {
                assert!(ctx.stepped);
                ctx.polls += 1;
                assert!(elapsed_ms >= 1);
                if ctx.polls < 2 {
                    Ok(None)
                } else {
                    Ok(Some(Ok(json!({ "answer": "已完成" }))))
                }
            },
        )
        .expect("protocol result");
        assert!(poll_ctx.stepped);
        assert_eq!(poll_ctx.polls, 2);
        assert_eq!(polled.expect("settled answer")["answer"], "已完成");

        let poll_err = drive_mcp_tool_blocking(
            (),
            |()| Ok(McpToolCallState::PendingAsk),
            |(), _| {
                Err(McpToolError {
                    code: -32603,
                    message: "poll failure".into(),
                })
            },
        )
        .unwrap_err();
        assert_eq!(
            poll_err,
            McpToolError {
                code: -32603,
                message: "poll failure".into()
            }
        );

        let timed_out = drive_mcp_tool_blocking_with_limits(
            0usize,
            Duration::from_millis(5),
            Duration::from_millis(2),
            |_| Ok(McpToolCallState::PendingAsk),
            |polls, _| {
                *polls += 1;
                Ok(None)
            },
        )
        .expect("protocol result");
        assert_eq!(timed_out.unwrap_err(), MCP_ASK_TIMEOUT_MESSAGE);
    }
