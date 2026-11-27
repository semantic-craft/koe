use std::{
    fs,
    io::{BufRead, BufReader, Read, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        net::{UnixListener, UnixStream},
    },
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, Instant},
};

use koe_runtime::{KoeRuntime, McpToolCallState, resolve_bridge_socket_path};
use serde_json::{Value, json};

use crate::HostSessionGuard;

use super::BridgeServer;

pub(crate) fn temp_workspace() -> PathBuf {
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
    let bridge = BridgeServer::start(0, &ws);
    let rejected = bridge.is_none();
    drop(bridge);
    let contents = fs::read(&path).ok();
    let _ = fs::remove_dir_all(&ws);
    assert!(rejected, "bridge replaced a non-socket file");
    assert_eq!(contents.as_deref(), Some(b"unrelated file".as_slice()));
}

#[test]
fn local_bridge_rejects_raw_dispatch() {
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

    drop(rpc_reader);
    drop(rpc_client);
    drop(session);
    let _ = fs::remove_dir_all(&base);
}

#[test]
fn get_record_paginates_oversized_record_under_line_budget_over_live_bridge() {
    let ws = temp_workspace();
    let _ = fs::remove_dir_all(&ws);

    const SEGMENT_COUNT: usize = 4_000;
    const MAX_PAGINATED_RESPONSE_BYTES: usize = 1_572_864;
    let record_id = {
        let mut runtime = KoeRuntime::open(&ws).expect("seed runtime should open");
        let pad = "a".repeat(640);
        let mut text = String::with_capacity(SEGMENT_COUNT * 660);
        for i in 1..=SEGMENT_COUNT {
            if i > 1 {
                text.push('\n');
            }
            text.push_str(&format!("seg-{i:04}-{pad}"));
        }
        let created = match runtime
            .call_mcp_tool_step(
                "create_note",
                &json!({"title": "Oversized 4000-segment fixture", "text": text}),
                1_800_000_000,
            )
            .unwrap()
        {
            McpToolCallState::Completed(Ok(value)) => value,
            other => panic!("create_note failed: {other:?}"),
        };
        let id = created["id"].as_str().unwrap().to_string();
        assert!(
            created.to_string().len() > 2_500_000,
            "fixture must exceed 2.5 MiB full JSON"
        );
        let _ = runtime
            .call_mcp_tool_step(
                "edit_transcript",
                &json!({
                    "record_id": id,
                    "action": "set_speaker",
                    "segment_id": "S1",
                    "speaker": "Alice"
                }),
                1_800_000_001,
            )
            .unwrap();
        let _ = runtime
            .call_mcp_tool_step(
                "annotate_segment",
                &json!({
                    "record_id": id,
                    "segment_id": "S1",
                    "kind": "highlight"
                }),
                1_800_000_002,
            )
            .unwrap();
        id
    };

    let sock_path = resolve_bridge_socket_path(&ws).unwrap();
    let session = HostSessionGuard::open(&ws).expect("host session should open");
    let mut client = UnixStream::connect(&sock_path).unwrap();
    let mut reader = BufReader::new(client.try_clone().unwrap());

    let mut rpc = |id: u64, args: Value| -> (usize, Value) {
        writeln!(
            client,
            "{}",
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": "koe/mcp_tool_call",
                "params": {
                    "name": "get_record",
                    "arguments": args
                }
            })
        )
        .unwrap();
        client.flush().unwrap();
        let mut line = String::new();
        let bytes = reader.read_line(&mut line).unwrap();
        assert!(bytes > 0, "bridge closed unexpectedly");
        let parsed: Value = serde_json::from_str(&line).unwrap();
        (bytes, parsed)
    };

    let (summary_bytes, summary_resp) = rpc(
        1,
        json!({"record_id": record_id, "include_segments": false}),
    );
    assert!(
        summary_resp.get("error").is_none(),
        "include_segments=false failed: {summary_resp}"
    );
    assert!(
        summary_bytes < 64 * 1024,
        "include_segments=false payload exceeded 64 KiB: {summary_bytes}"
    );
    let summary_val = &summary_resp["result"]["value"];
    assert_eq!(summary_val["segments"].as_array().unwrap().len(), 0);
    assert_eq!(summary_val["totalSegments"], SEGMENT_COUNT);
    assert_eq!(summary_val["segmentOffset"], 0);
    assert_eq!(summary_val["segmentsTruncated"], true);
    assert_eq!(summary_val["nextSegmentOffset"], 0);
    assert_eq!(summary_val["speakers"][0]["name"], "Alice");
    assert_eq!(summary_val["highlights"].as_array().unwrap().len(), 1);

    let (page_bytes, page_resp) = rpc(
        2,
        json!({"record_id": record_id, "segment_offset": 10, "segment_limit": 100}),
    );
    assert!(
        page_resp.get("error").is_none(),
        "explicit segment_limit page failed: {page_resp}"
    );
    assert!(
        page_bytes <= MAX_PAGINATED_RESPONSE_BYTES,
        "page exceeded 1.5 MiB: {page_bytes}"
    );
    let page_val = &page_resp["result"]["value"];
    let page_segments = page_val["segments"].as_array().unwrap();
    assert_eq!(page_segments.len(), 100);
    assert_eq!(page_val["segmentOffset"], 10);
    assert_eq!(page_val["segmentsTruncated"], true);
    assert_eq!(page_val["nextSegmentOffset"], 110);
    assert_eq!(page_segments.first().unwrap()["id"], "S11");
    assert_eq!(page_segments.last().unwrap()["id"], "S110");

    let mut cursor = 0u64;
    let mut pages = 0usize;
    let mut reconstructed = Vec::with_capacity(SEGMENT_COUNT);
    let mut rpc_id = 10u64;
    loop {
        let (bytes, resp) = rpc(
            rpc_id,
            json!({"record_id": record_id, "segment_offset": cursor}),
        );
        rpc_id += 1;
        assert!(
            resp.get("error").is_none(),
            "budget-sliced page at offset {cursor} failed: {resp}"
        );
        assert!(
            bytes <= MAX_PAGINATED_RESPONSE_BYTES,
            "budget-sliced page at offset {cursor} exceeded 1.5 MiB: {bytes}"
        );
        let val = &resp["result"]["value"];
        assert_eq!(val["totalSegments"], SEGMENT_COUNT);
        assert_eq!(val["segmentOffset"], cursor);
        let segs = val["segments"].as_array().unwrap();
        assert!(!segs.is_empty(), "empty page at offset {cursor}");
        for seg in segs {
            reconstructed.push(seg["id"].as_str().unwrap().to_string());
        }
        pages += 1;
        match val["nextSegmentOffset"].as_u64() {
            Some(next) => {
                assert_eq!(val["segmentsTruncated"], true);
                assert_eq!(next, cursor + segs.len() as u64);
                cursor = next;
            }
            None => {
                assert_eq!(val["segmentsTruncated"], false);
                break;
            }
        }
    }

    assert!(pages >= 2, "expected multiple pages for >2.5 MiB record");
    assert_eq!(reconstructed.len(), SEGMENT_COUNT);
    assert_eq!(reconstructed.first().unwrap(), "S1");
    assert_eq!(reconstructed.last().unwrap(), "S4000");

    drop(reader);
    drop(client);
    drop(session);
    let _ = fs::remove_dir_all(&ws);
}

#[test]
fn get_record_bounds_giant_highlighted_segment_over_live_bridge() {
    const NOW: u64 = 1_800_000_000;
    const MAX_PAGINATED_RESPONSE_BYTES: usize = 1_572_864;
    let ws = temp_workspace();
    let _ = fs::remove_dir_all(&ws);

    let record_id = {
        let mut runtime = KoeRuntime::open(&ws).expect("seed runtime should open");
        let giant_seg = "中".repeat(550_000);
        let text = format!("{giant_seg}\n{giant_seg}\nfollow-up short segment");
        let created = match runtime
            .call_mcp_tool_step(
                "create_note",
                &json!({"title": "Giant Highlighted Fixture", "text": text}),
                NOW,
            )
            .unwrap()
        {
            McpToolCallState::Completed(Ok(value)) => value,
            other => panic!("create_note failed: {other:?}"),
        };
        let id = created["id"].as_str().unwrap().to_string();
        for seg_id in ["S1", "S2"] {
            match runtime
                .call_mcp_tool_step(
                    "annotate_segment",
                    &json!({
                        "record_id": id,
                        "segment_id": seg_id,
                        "kind": "highlight"
                    }),
                    NOW + 1,
                )
                .unwrap()
            {
                McpToolCallState::Completed(Ok(_)) => {}
                other => panic!("annotate_segment({seg_id}) failed: {other:?}"),
            }
        }
        id
    };

    let sock_path = resolve_bridge_socket_path(&ws).unwrap();
    let session = HostSessionGuard::open(&ws).expect("host session should open");
    let mut client = UnixStream::connect(&sock_path).unwrap();
    let mut reader = BufReader::new(client.try_clone().unwrap());

    let mut rpc = |id: u64, args: Value| -> (usize, Value) {
        writeln!(
            client,
            "{}",
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "method": "koe/mcp_tool_call",
                "params": {
                    "name": "get_record",
                    "arguments": args
                }
            })
        )
        .unwrap();
        client.flush().unwrap();
        let mut buf = Vec::new();
        let bytes = reader
            .by_ref()
            .take(super::MAX_LINE_BYTES + 1)
            .read_until(b'\n', &mut buf)
            .unwrap();
        assert!(bytes > 0, "bridge closed unexpectedly");
        assert!(
            bytes as u64 <= super::MAX_LINE_BYTES,
            "koe.sock response exceeded 2 MiB MAX_LINE_BYTES and poisoned connection: {bytes}"
        );
        let parsed: Value = serde_json::from_slice(&buf).unwrap();
        (bytes, parsed)
    };

    let (meta_bytes, meta_resp) = rpc(
        1,
        json!({"record_id": record_id, "include_segments": false}),
    );
    assert!(
        meta_resp.get("error").is_none(),
        "include_segments=false failed: {meta_resp}"
    );
    assert!(
        meta_bytes <= MAX_PAGINATED_RESPONSE_BYTES,
        "include_segments=false exceeded 1.5 MiB: {meta_bytes}"
    );
    let meta_val = &meta_resp["result"]["value"];
    assert_eq!(meta_val["metadataTruncated"], true);
    assert_eq!(meta_val["segments"], json!([]));
    assert_eq!(meta_val["totalSegments"], 3);
    assert_eq!(meta_val["segmentsTruncated"], true);
    assert_eq!(meta_val["nextSegmentOffset"], 0);
    assert_eq!(meta_val["highlights"].as_array().unwrap().len(), 2);
    assert!(
        meta_val["highlights"][0]["quote"]
            .as_str()
            .unwrap()
            .ends_with('…')
    );

    let (page0_bytes, page0_resp) = rpc(
        2,
        json!({"record_id": record_id, "include_segments": true, "segment_offset": 0}),
    );
    assert!(
        page0_resp.get("error").is_none(),
        "page 0 failed: {page0_resp}"
    );
    assert!(
        page0_bytes <= MAX_PAGINATED_RESPONSE_BYTES,
        "page 0 exceeded 1.5 MiB: {page0_bytes}"
    );
    let page0_val = &page0_resp["result"]["value"];
    assert_eq!(page0_val["metadataTruncated"], true);
    let page0_segs = page0_val["segments"].as_array().unwrap();
    assert_eq!(
        page0_segs.len(),
        1,
        "page 0 must return capped S1 instead of empty starved segments"
    );
    assert_eq!(page0_segs[0]["id"], "S1");
    assert!(page0_segs[0]["text"].as_str().unwrap().ends_with('…'));
    assert_eq!(page0_val["segmentsTruncated"], true);
    assert_eq!(page0_val["nextSegmentOffset"], 1);

    let (page2_bytes, page2_resp) = rpc(
        3,
        json!({"record_id": record_id, "include_segments": true, "segment_offset": 2}),
    );
    assert!(
        page2_resp.get("error").is_none(),
        "page 2 failed: {page2_resp}"
    );
    assert!(
        page2_bytes <= MAX_PAGINATED_RESPONSE_BYTES,
        "page 2 exceeded 1.5 MiB: {page2_bytes}"
    );
    let page2_val = &page2_resp["result"]["value"];
    assert_eq!(page2_val["metadataTruncated"], true);
    let page2_segs = page2_val["segments"].as_array().unwrap();
    assert_eq!(page2_segs.len(), 1);
    assert_eq!(page2_segs[0]["id"], "S3");
    assert_eq!(page2_segs[0]["text"], "follow-up short segment");
    assert_eq!(page2_val["segmentsTruncated"], false);
    assert!(page2_val["nextSegmentOffset"].is_null());

    drop(reader);
    drop(client);
    drop(session);
    let _ = fs::remove_dir_all(&ws);
}
