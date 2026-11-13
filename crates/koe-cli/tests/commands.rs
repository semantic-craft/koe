use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use koe_engine::{
    commands::DeviceCommands,
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    frame::{ProtocolFrame, RX_MAGIC},
    session::REAL_OPUS_20MS_440HZ_PACKET,
    transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES, UNFINISHED_FILE_SIZE},
};
use koe_host_api::HostSessionGuard;
use koe_runtime::{decode_pcm16_le_b64, resolve_bridge_socket_path, KoeRuntime};
use serde_json::{json, Value};

const EXPECTED_MCP_TOOLS: [&str; 16] = [
    "search",
    "get_today_brief",
    "list_records",
    "get_record",
    "ask",
    "list_review_items",
    "review_item",
    "complete_task",
    "edit_item",
    "create_note",
    "annotate_segment",
    "edit_transcript",
    "manage_record",
    "device_status",
    "device_control",
    "poll_updates",
];

struct Workspace(PathBuf);
impl Workspace {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Self(std::env::temp_dir().join(format!(
            "koe-cli-process-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )))
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cli(path: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(args)
        .arg("--workspace")
        .arg(path)
        .output()
        .unwrap()
}

fn note_fixture(path: &Path) -> String {
    let mut runtime = KoeRuntime::open(path).unwrap();
    let result: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type":"create_note", "title":"周五交付", "text":"周五交付原生界面，保留录音来源。"
            })
            .to_string(),
            1_775_000_000,
        ),
    )
    .unwrap();
    assert!(result["error"].is_null(), "{result}");
    result["detail"]["id"].as_str().unwrap().into()
}

#[test]
fn cli_reads_native_store_and_returns_navigable_sources() {
    let workspace = Workspace::new();
    let id = note_fixture(&workspace.0);
    let status = cli(&workspace.0, &["status"]);
    assert!(
        status.status.success(),
        "{}",
        String::from_utf8_lossy(&status.stderr)
    );
    let status: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["records"][0]["id"], id);
    let search = cli(&workspace.0, &["search", "原生界面"]);
    assert!(search.status.success());
    let search: Value = serde_json::from_slice(&search.stdout).unwrap();
    assert_eq!(search["sources"][0]["recordId"], id);
    assert_eq!(search["sources"][0]["segmentId"], "S1");
    let ask = cli(&workspace.0, &["ask", "原生界面"]);
    assert!(
        ask.status.success(),
        "{}",
        String::from_utf8_lossy(&ask.stderr)
    );
    let ask: Value = serde_json::from_slice(&ask.stdout).unwrap();
    assert_eq!(ask["phase"], "ready");
    assert_eq!(
        ask["messages"].as_array().unwrap().last().unwrap()["mode"],
        "retrieval"
    );
    let reopened = KoeRuntime::open(&workspace.0).unwrap();
    assert!(!reopened.workspace().ask_session().messages.is_empty());
}

#[test]
fn occupied_store_fails_without_inventing_an_empty_library() {
    let workspace = Workspace::new();
    let _owner = KoeRuntime::open(&workspace.0).unwrap();
    let output = cli(&workspace.0, &["status"]);
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let error: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert!(error["error"].as_str().unwrap().contains("占用"));
}

#[test]
fn mcp_exposes_only_connected_tools_and_reads_the_same_record() {
    let workspace = Workspace::new();
    let id = note_fixture(&workspace.0);
    let mut process = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = process.stdin.take().unwrap();
    for request in [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_record","arguments":{"record_id":id}}}),
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"google_tasks_sync","arguments":{}}}),
    ] {
        writeln!(input, "{request}").unwrap();
    }
    drop(input);
    let output = process.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let responses: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(responses.len(), 4);
    let names: Vec<_> = responses[1]["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, EXPECTED_MCP_TOOLS);
    let record: Value = serde_json::from_str(
        responses[2]["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(record["id"], id);
    assert_eq!(
        record["segments"][0]["text"],
        "周五交付原生界面，保留录音来源。"
    );
    assert!(responses[3]["error"].is_object());
}

#[test]
fn protocol_verification_does_not_create_workspace_data() {
    let workspace = Workspace::new();
    let output = cli(&workspace.0, &["verify-protocol"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let receipt: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(receipt["status"], "ok");
    assert_eq!(receipt["hardwareVerified"], false);
    assert!(!workspace.0.exists());
}

#[test]
fn cli_and_mcp_exclude_trashed_records_and_expire_30_day_trash_on_open() {
    let workspace = Workspace::new();
    let now_sec = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    let expired_sec = now_sec - 31 * 86_400;

    let (live_id, trashed_id, expired_wav) = {
        let mut runtime = KoeRuntime::open(&workspace.0).unwrap();
        let live: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({"type": "create_note", "title": "保留纪要", "text": "独特词条保留内容。"})
                    .to_string(),
                now_sec,
            ),
        )
        .unwrap();
        let live_id = live["detail"]["id"].as_str().unwrap().to_owned();

        let trashed: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({"type": "create_note", "title": "回收站纪要", "text": "独特词条已删内容。"})
                    .to_string(),
                now_sec,
            ),
        )
        .unwrap();
        let trashed_id = trashed["detail"]["id"].as_str().unwrap().to_owned();

        let src_wav = workspace.0.join("expired_input.wav");
        let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(3200, 16000).to_vec();
        wav.extend(vec![0u8; 3200]);
        std::fs::write(&src_wav, &wav).unwrap();
        let expired: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({"type": "import_file", "path": src_wav}).to_string(),
                expired_sec,
            ),
        )
        .unwrap();
        let _ = std::fs::remove_file(&src_wav);
        let expired_id = expired["detail"]["id"].as_str().unwrap().to_owned();
        let expired_wav = std::path::PathBuf::from(expired["detail"]["audioPath"].as_str().unwrap());

        let trash_res: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({"type": "trash_record", "recordId": trashed_id}).to_string(),
                now_sec,
            ),
        )
        .unwrap();
        assert!(trash_res["error"].is_null(), "{trash_res}");

        let exp_res: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({"type": "trash_record", "recordId": expired_id}).to_string(),
                expired_sec,
            ),
        )
        .unwrap();
        assert!(exp_res["error"].is_null(), "{exp_res}");
        assert!(expired_wav.exists());
        (live_id, trashed_id, expired_wav)
    };

    let status = cli(&workspace.0, &["status"]);
    assert!(
        status.status.success(),
        "{}",
        String::from_utf8_lossy(&status.stderr)
    );
    let status: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert!(!expired_wav.exists());
    assert_eq!(status["records"].as_array().unwrap().len(), 1);
    assert_eq!(status["records"][0]["id"], live_id);
    assert_eq!(status["trashRecords"].as_array().unwrap().len(), 1);
    assert_eq!(status["trashRecords"][0]["id"], trashed_id);

    let search = cli(&workspace.0, &["search", "独特词条"]);
    assert!(search.status.success());
    let search: Value = serde_json::from_slice(&search.stdout).unwrap();
    let found_ids: Vec<_> = search["sources"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| s["recordId"].as_str().unwrap())
        .collect();
    assert_eq!(found_ids, [live_id.as_str()]);

    let scoped_search = cli(&workspace.0, &["search", "已删内容", "--record", &trashed_id]);
    assert!(!scoped_search.status.success());

    let scoped_ask = cli(&workspace.0, &["ask", "已删内容", "--record", &trashed_id]);
    assert!(!scoped_ask.status.success());

    let mut process = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = process.stdin.take().unwrap();
    for request in [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_record","arguments":{"record_id":trashed_id}}}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"独特词条"}}}),
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"ask","arguments":{"question":"已删内容","record_id":trashed_id}}}),
    ] {
        writeln!(input, "{request}").unwrap();
    }
    drop(input);
    let output = process.wait_with_output().unwrap();
    assert!(output.status.success());
    let responses: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(responses[1]["result"]["isError"], true);
    let mcp_search: Value = serde_json::from_str(
        responses[2]["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(mcp_search["sources"].as_array().unwrap().len(), 1);
    assert_eq!(mcp_search["sources"][0]["recordId"], live_id);
    assert_eq!(responses[3]["result"]["isError"], true);
}

#[test]
fn cli_transcript_and_speaker_commands_align_with_mcp_search_and_get_record() {
    let workspace = Workspace::new();
    let now_sec = 1_780_000_000u64;
    let id = {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let chat_url = format!("http://{}/chat/completions", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            use std::io::Read;
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf);
            let answer = json!({
                "schemaVersion": 2,
                "title": "架构评审",
                "overview": "按70%灰度推进。",
                "topics": [{"text": "灰度方案", "summary": "按70%灰度推进", "sources": ["S1"]}],
                "decisions": [],
                "actions": [],
                "questions": [],
                "terms": [],
                "reviewItems": []
            })
            .to_string();
            let body = json!({"choices": [{"message": {"content": answer}}]}).to_string();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        });

        let mut runtime = KoeRuntime::open(&workspace.0).unwrap();
        let created: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({
                    "type": "create_note",
                    "title": "架构评审",
                    "text": "西卡达模块按70%灰度推进。\n周五前完成压测验收。"
                })
                .to_string(),
                now_sec,
            ),
        )
        .unwrap();
        assert!(created["error"].is_null(), "{created}");
        let id = created["detail"]["id"].as_str().unwrap().to_owned();
        runtime.dispatch_json(
            &json!({
                "type": "configure_provider",
                "apiKey": "cli-test-key",
                "model": "qwen-plus",
                "chatEndpoint": chat_url
            })
            .to_string(),
            now_sec,
        );
        runtime.dispatch_json(
            &json!({"type": "summarize", "recordId": id}).to_string(),
            now_sec,
        );
        for _ in 0..200 {
            runtime.poll_timers(10, now_sec);
            if runtime.snapshot(now_sec)["detail"]["status"] == "已整理" {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        server.join().unwrap();
        assert_eq!(runtime.snapshot(now_sec)["detail"]["status"], "已整理");
        id
    };

    let dash_edited = Command::new(env!("CARGO_BIN_EXE_koe"))
        .arg("--workspace")
        .arg(&workspace.0)
        .args([
            "edit-segment",
            "--record",
            &id,
            "--",
            "S1",
            "- 列表项：Cicada 模块按 85% 灰度推进。",
        ])
        .output()
        .unwrap();
    assert!(
        dash_edited.status.success(),
        "{}",
        String::from_utf8_lossy(&dash_edited.stderr)
    );
    let dash_detail: Value = serde_json::from_slice(&dash_edited.stdout).unwrap();
    assert_eq!(
        dash_detail["segments"][0]["text"],
        "- 列表项：Cicada 模块按 85% 灰度推进。"
    );

    let bad_rename = cli(
        &workspace.0,
        &["rename-speaker", "--record", &id, "发言人", "1", "张工"],
    );
    assert!(!bad_rename.status.success());
    let bad_rename_err: Value = serde_json::from_slice(&bad_rename.stderr).unwrap();
    assert_eq!(
        bad_rename_err["error"],
        "用法：koe rename-speaker --record <ID> \"<原说话人>\" \"<新说话人>\""
    );

    let edited = cli(
        &workspace.0,
        &[
            "edit-segment",
            "--record",
            &id,
            "S1",
            "Cicada",
            "模块按",
            "85%",
            "灰度推进。",
        ],
    );
    assert!(
        edited.status.success(),
        "{}",
        String::from_utf8_lossy(&edited.stderr)
    );
    let edited_detail: Value = serde_json::from_slice(&edited.stdout).unwrap();
    assert_eq!(
        edited_detail["segments"][0]["text"],
        "Cicada 模块按 85% 灰度推进。"
    );
    assert_eq!(
        edited_detail["segments"][0]["originalText"],
        "西卡达模块按70%灰度推进。"
    );
    assert_eq!(edited_detail["segments"][0]["isEdited"], true);

    let set_sp1 = cli(
        &workspace.0,
        &["set-speaker", "--record", &id, "S1", "发言人", "1："],
    );
    assert!(
        set_sp1.status.success(),
        "{}",
        String::from_utf8_lossy(&set_sp1.stderr)
    );
    let sp1_detail: Value = serde_json::from_slice(&set_sp1.stdout).unwrap();
    assert_eq!(sp1_detail["segments"][0]["speaker"], "发言人 1");

    let set_sp2 = cli(
        &workspace.0,
        &["set-speaker", "--record", &id, "S2", "发言人", "2"],
    );
    assert!(set_sp2.status.success());

    let clear_sp2 = cli(&workspace.0, &["set-speaker", "--record", &id, "S2"]);
    assert!(clear_sp2.status.success());
    let cleared_detail: Value = serde_json::from_slice(&clear_sp2.stdout).unwrap();
    assert_eq!(cleared_detail["segments"][1]["speaker"], Value::Null);

    assert!(cli(&workspace.0, &["set-speaker", "--record", &id, "S2", "李工"])
        .status
        .success());
    let clear_empty = cli(&workspace.0, &["set-speaker", "--record", &id, "S2", ""]);
    assert!(clear_empty.status.success());
    let cleared_empty_detail: Value = serde_json::from_slice(&clear_empty.stdout).unwrap();
    assert_eq!(cleared_empty_detail["segments"][1]["speaker"], Value::Null);

    assert!(cli(
        &workspace.0,
        &["set-speaker", "--record", &id, "S2", "发言人 2"]
    )
    .status
    .success());

    assert!(cli(
        &workspace.0,
        &["rename-speaker", "--record", &id, "发言人 1", "张工："]
    )
    .status
    .success());
    let merged = cli(
        &workspace.0,
        &["rename-speaker", "--record", &id, "发言人 2", "张工"],
    );
    assert!(
        merged.status.success(),
        "{}",
        String::from_utf8_lossy(&merged.stderr)
    );
    let merged_detail: Value = serde_json::from_slice(&merged.stdout).unwrap();
    assert_eq!(
        merged_detail["speakers"],
        json!([{"name": "张工", "segmentCount": 2, "firstSegmentId": "S1"}])
    );

    {
        let mut runtime = KoeRuntime::open(&workspace.0).unwrap();
        let archived: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({"type": "set_record_archived", "recordId": id, "archived": true})
                    .to_string(),
                now_sec,
            ),
        )
        .unwrap();
        assert!(archived["error"].is_null(), "{archived}");
    }

    let blocked = cli(
        &workspace.0,
        &["edit-segment", "--record", &id, "S1", "归档状态下不可改"],
    );
    assert!(!blocked.status.success());
    assert!(blocked.stdout.is_empty());
    let blocked_err: Value = serde_json::from_slice(&blocked.stderr).unwrap();
    assert!(blocked_err["error"].as_str().unwrap().contains("归档保护"));

    {
        let mut runtime = KoeRuntime::open(&workspace.0).unwrap();
        let unarchived: Value = serde_json::from_str(
            &runtime.dispatch_json(
                &json!({"type": "set_record_archived", "recordId": id, "archived": false})
                    .to_string(),
                now_sec,
            ),
        )
        .unwrap();
        assert!(unarchived["error"].is_null(), "{unarchived}");
    }

    let mut process = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = process.stdin.take().unwrap();
    for request in [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search","arguments":{"query":"张工 Cicada"}}}),
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_record","arguments":{"record_id":id}}}),
    ] {
        writeln!(input, "{request}").unwrap();
    }
    drop(input);
    let output = process.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let responses: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    let tool_names: Vec<_> = responses[1]["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(tool_names, EXPECTED_MCP_TOOLS);

    let search_payload: Value = serde_json::from_str(
        responses[2]["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(search_payload["sources"][0]["recordId"], id);
    assert_eq!(search_payload["sources"][0]["segmentId"], "S1");
    assert_eq!(
        search_payload["sources"][0]["quote"],
        "Cicada 模块按 85% 灰度推进。"
    );

    let detail_payload: Value = serde_json::from_str(
        responses[3]["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(detail_payload["canEditTranscript"], true);
    assert_eq!(detail_payload["minutesStale"], true);
    assert_eq!(detail_payload["status"], "原文已变更待重算");
    assert_eq!(
        detail_payload["speakers"],
        json!([{"name": "张工", "segmentCount": 2, "firstSegmentId": "S1"}])
    );
    assert_eq!(
        detail_payload["segments"][0]["originalText"],
        "西卡达模块按70%灰度推进。"
    );
    assert_eq!(detail_payload["segments"][0]["isEdited"], true);
}

fn build_rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = Vec::from(RX_MAGIC);
    frame.extend_from_slice(&[0x01, cmd_type, cmd_id]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(ProtocolFrame::checksum(&frame));
    frame
}

fn build_telemetry_rx(recording_status: u8, battery_level: u8) -> Vec<u8> {
    let mut pkt = Vec::from(RX_MAGIC);
    pkt.extend_from_slice(&[0x01, 0x01, 0x01, 0x00, 0x00]);
    pkt.push(recording_status);
    pkt.push(battery_level);
    pkt.push(0);
    pkt.extend_from_slice(b"04.92");
    pkt.extend_from_slice(b"D3200COLLAR00001");
    pkt.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
    pkt.extend_from_slice(&(60u32 * 1024 * 1024).to_le_bytes());
    pkt.push(0);
    pkt.extend_from_slice(b"2.1.0");
    pkt.push(9);
    pkt.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
    let total_len = (pkt.len() + 1) as u16;
    pkt[7] = (total_len & 0xFF) as u8;
    pkt[8] = ((total_len >> 8) & 0xFF) as u8;
    let csum = ProtocolFrame::checksum(&pkt);
    pkt.push(csum);
    pkt
}

fn connect_simulated_bean_on_host(
    session: &HostSessionGuard,
    connection_id: &str,
    now: u64,
) -> [u8; 32] {
    let _ = session
        .dispatch_json(
            &json!({
                "type": "device_event",
                "event": "connecting",
                "connectionId": connection_id,
                "deviceName": "Soundcore Work"
            })
            .to_string(),
            now,
        )
        .unwrap();
    let _ = session
        .dispatch_json(
            &json!({
                "type": "device_event",
                "event": "ready",
                "connectionId": connection_id,
                "deviceName": "Soundcore Work"
            })
            .to_string(),
            now,
        )
        .unwrap();
    let outbound = session.drain_ble_tx();
    let ecdh_tx = outbound
        .iter()
        .find(|f| f.len() >= 75 && f[5] == 0x2E && f[6] == 0x01)
        .expect("ready event must emit 2E/01 public key frame");
    let client_pub = &ecdh_tx[9..74];
    let bean_priv = [0x24u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, client_pub).unwrap();
    let mut ecdh_payload = Vec::with_capacity(97);
    ecdh_payload.extend_from_slice(&bean_pub);
    ecdh_payload.extend_from_slice(&shared);
    let ecdh_rx = build_rx_frame(0x2E, 0x01, &ecdh_payload);
    let derived = DeviceCrypto::hkdf_sha256(&shared, &[1, 2, 3], &[1, 2, 3], 32);
    let mut session_key = [0u8; 32];
    session_key.copy_from_slice(&derived);

    let _ = session.ingest_ble(&ecdh_rx, now);
    let _ = session.ingest_ble(&build_telemetry_rx(0, 8), now);
    let _ = session.ingest_ble(&build_rx_frame(0x1B, 0x0E, &[0, 0]), now);
    session_key
}

fn activate_realtime_file_on_host(
    session: &HostSessionGuard,
    session_key: &[u8; 32],
    file_id: u32,
    now: u64,
) -> ([u8; 32], [u8; 16]) {
    let mut list_payload = Vec::new();
    list_payload.extend_from_slice(&1u16.to_le_bytes());
    list_payload.extend_from_slice(&file_id.to_le_bytes());
    list_payload.extend_from_slice(&0u32.to_le_bytes());
    list_payload.extend_from_slice(&1_000u32.to_le_bytes());
    let _ = session.ingest_ble(&build_rx_frame(0x1B, 0x0E, &list_payload), now);

    let outbound = session.drain_ble_tx();
    assert!(
        outbound
            .iter()
            .any(|f| f == &DeviceCommands::start_transport_audio_file(file_id, 0, 1))
    );

    let file_key = [0x5Au8; 32];
    let file_nonce = [0x6Bu8; 16];
    let mut plain_key_mat = Vec::with_capacity(46);
    plain_key_mat.extend_from_slice(b"soundcored3200");
    plain_key_mat.extend_from_slice(&file_key);
    let session_nonce = [0x33u8; 16];
    let enc_file_key =
        DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, session_key, &session_nonce).unwrap();
    let mut head_payload = Vec::with_capacity(87);
    head_payload.extend_from_slice(&file_id.to_le_bytes());
    head_payload.extend_from_slice(&UNFINISHED_FILE_SIZE.to_le_bytes());
    head_payload.extend_from_slice(&file_nonce);
    head_payload.extend_from_slice(&enc_file_key);
    head_payload.extend_from_slice(&session_nonce);
    head_payload.push(0);
    let _ = session.ingest_ble(&build_rx_frame(0x1A, 0x07, &head_payload), now);
    (file_key, file_nonce)
}

fn build_encrypted_slices_rx(
    file_key: &[u8; 32],
    file_nonce: &[u8; 16],
    slices: &[(u32, u8)],
) -> Vec<u8> {
    let decryptor = AesCtrStreamDecrypt::new(file_key, file_nonce).unwrap();
    let mut payload = Vec::with_capacity(slices.len() * SLICE_RECORD_BYTES);
    for &(seq, flags) in slices {
        payload.extend_from_slice(&seq.to_le_bytes());
        payload.push(flags);
        let mut opus = [0u8; OPUS_FRAME_BYTES];
        opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        decryptor.decrypt_contiguous_in_place(&mut opus, seq);
        payload.extend_from_slice(&opus);
        payload.push(0);
    }
    build_rx_frame(0x1A, 0x08, &payload)
}

#[test]
fn live_host_session_serves_cli_and_full_mcp_stdio_over_bridge_without_lock_conflict() {
    let workspace = Workspace::new();
    let now_sec = 1_810_000_000u64;
    let host = HostSessionGuard::open(&workspace.0).expect("host session must open");
    assert!(
        KoeRuntime::open(&workspace.0).is_err(),
        "direct KoeRuntime::open must fail while HostSessionGuard holds the store lock"
    );

    let seed: Value = serde_json::from_str(
        &host
            .dispatch_json(
                &json!({
                    "type": "create_note",
                    "title": "在线桥接纪要",
                    "text": "领夹待命保持单写者一致性。\n双击正面零延迟收音。"
                })
                .to_string(),
                now_sec,
            )
            .unwrap(),
    )
    .unwrap();
    let seed_id = seed["detail"]["id"].as_str().unwrap().to_string();
    let _ = host
        .dispatch_json(&json!({"type": "navigate", "section": "today"}).to_string(), now_sec)
        .unwrap();

    let status_out = cli(&workspace.0, &["status"]);
    assert!(
        status_out.status.success(),
        "{}",
        String::from_utf8_lossy(&status_out.stderr)
    );
    let status_json: Value = serde_json::from_slice(&status_out.stdout).unwrap();
    assert_eq!(status_json["records"][0]["id"], seed_id);

    let doctor_out = cli(&workspace.0, &["doctor"]);
    assert!(doctor_out.status.success());
    let doctor_json: Value = serde_json::from_slice(&doctor_out.stdout).unwrap();
    assert_eq!(doctor_json["workspaceReadable"], true);

    let search_out = cli(&workspace.0, &["search", "单写者一致性"]);
    assert!(search_out.status.success());
    let search_json: Value = serde_json::from_slice(&search_out.stdout).unwrap();
    assert_eq!(search_json["sources"][0]["recordId"], seed_id);

    let ask_out = cli(&workspace.0, &["ask", "单写者一致性"]);
    assert!(
        ask_out.status.success(),
        "{}",
        String::from_utf8_lossy(&ask_out.stderr)
    );
    let ask_json: Value = serde_json::from_slice(&ask_out.stdout).unwrap();
    assert_eq!(ask_json["phase"], "ready");
    assert_eq!(
        ask_json["messages"].as_array().unwrap().last().unwrap()["mode"],
        "retrieval"
    );

    let edited_out = cli(
        &workspace.0,
        &[
            "edit-segment",
            "--record",
            &seed_id,
            "S1",
            "领夹待命通过本地桥保持单写者一致性。",
        ],
    );
    assert!(
        edited_out.status.success(),
        "{}",
        String::from_utf8_lossy(&edited_out.stderr)
    );
    let edited_json: Value = serde_json::from_slice(&edited_out.stdout).unwrap();
    assert_eq!(
        edited_json["segments"][0]["text"],
        "领夹待命通过本地桥保持单写者一致性。"
    );

    let host_snap_after_cli: Value =
        serde_json::from_str(&host.snapshot_json(now_sec).unwrap()).unwrap();
    assert_eq!(
        host_snap_after_cli["section"], "today",
        "online CLI commands must not hijack Koe.app active navigation page"
    );

    let mut mcp_proc = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = mcp_proc.stdin.take().unwrap();
    let requests = [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"live-test","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_note","arguments":{"title":"MCP 新建速记","text":"外部 Agent 在线写入速记。"}}}),
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"annotate_segment","arguments":{"record_id":seed_id,"segment_id":"S2","kind":"task"}}}),
        json!({"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_today_brief","arguments":{}}}),
        json!({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"device_control","arguments":{"action":"set_companion_mode","mode":"collar_standby"}}}),
        json!({"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"device_status","arguments":{}}}),
        json!({"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"manage_record","arguments":{"record_id":seed_id,"action":"purge"}}}),
        json!({"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"poll_updates","arguments":{"since_generation":1}}}),
    ];
    let writer = std::thread::spawn(move || {
        for req in requests {
            writeln!(stdin, "{req}").unwrap();
        }
    });
    let mcp_out = mcp_proc.wait_with_output().unwrap();
    writer.join().unwrap();
    assert!(
        mcp_out.status.success(),
        "{}",
        String::from_utf8_lossy(&mcp_out.stderr)
    );
    let responses: Vec<Value> = String::from_utf8(mcp_out.stdout)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(responses.len(), 9);
    let listed: Vec<_> = responses[1]["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(listed, EXPECTED_MCP_TOOLS);
    assert_eq!(responses[2]["result"]["isError"], false);
    assert_eq!(responses[3]["result"]["isError"], false);
    let brief: Value =
        serde_json::from_str(responses[4]["result"]["content"][0]["text"].as_str().unwrap())
            .unwrap();
    assert_eq!(brief["counts"]["liveRecords"], 2);
    assert_eq!(brief["counts"]["openTasks"], 1);
    let dev_status: Value =
        serde_json::from_str(responses[6]["result"]["content"][0]["text"].as_str().unwrap())
            .unwrap();
    assert_eq!(dev_status["companionMode"], "collar_standby");
    assert_eq!(responses[7]["error"]["code"], -32602);
    let poll_val: Value =
        serde_json::from_str(responses[8]["result"]["content"][0]["text"].as_str().unwrap())
            .unwrap();
    assert_eq!(poll_val["hasUpdates"], true);

    drop(host);
    let offline_status = cli(&workspace.0, &["status"]);
    assert!(offline_status.status.success());
    let offline_json: Value = serde_json::from_slice(&offline_status.stdout).unwrap();
    assert_eq!(offline_json["records"].as_array().unwrap().len(), 2);
    assert_eq!(offline_json["device"]["companionMode"], "collar_standby");
}

#[test]
fn live_host_companion_listen_streams_thump_gated_pcm_and_flushes_shortcut_holdback() {
    let workspace = Workspace::new();
    let now_sec = 1_820_000_000u64;
    let host = HostSessionGuard::open(&workspace.0).expect("host session must open");
    let _ = host
        .dispatch_json(
            &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
            now_sec,
        )
        .unwrap();
    let session_key = connect_simulated_bean_on_host(&host, "ble-live-sub", now_sec);
    let _ = host.drain_ble_tx();
    let (file_key, file_nonce) =
        activate_realtime_file_on_host(&host, &session_key, 9001, now_sec + 1);

    let mut listener_proc = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args([
            "companion-listen",
            "--workspace",
            workspace.0.to_str().unwrap(),
            "--max-events",
            "11",
            "--timeout-ms",
            "5000",
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stdout = listener_proc.stdout.take().unwrap();
    let mut stdout_reader = BufReader::new(stdout);

    let mut hello_line = String::new();
    stdout_reader.read_line(&mut hello_line).unwrap();
    let hello: Value = serde_json::from_str(&hello_line).unwrap();
    assert_eq!(hello["event"], "hello");
    assert_eq!(hello["online"], true);
    assert_eq!(hello["standbyReady"], true);
    assert_eq!(hello["routingMode"], "collar_standby");

    let mut tap_slices = vec![(0u32, 0x01u8)];
    for seq in 1..21 {
        tap_slices.push((seq, 0x00));
    }
    tap_slices.push((21, 0x01));
    let _ = host.ingest_ble(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &tap_slices),
        now_sec + 2,
    );

    let mut rest_events = Vec::new();
    for _ in 0..10 {
        let mut line = String::new();
        let n = stdout_reader.read_line(&mut line).unwrap();
        assert!(n > 0, "expected 10 companion events after hello");
        rest_events.push(serde_json::from_str::<Value>(&line).unwrap());
    }
    let exit_status = listener_proc.wait().unwrap();
    assert!(exit_status.success());

    assert_eq!(rest_events[0]["event"], "control_edge");
    assert_eq!(rest_events[0]["down"], true);
    assert_eq!(rest_events[1]["event"], "control_edge");
    assert_eq!(rest_events[1]["down"], false);
    for pcm_ev in &rest_events[2..8] {
        assert_eq!(pcm_ev["event"], "audio_pcm16");
        assert_eq!(pcm_ev["sampleRateHz"], 16_000);
        let decoded = decode_pcm16_le_b64(pcm_ev["samplesLeB64"].as_str().unwrap()).unwrap();
        assert_eq!(decoded.len(), 320);
        assert!(decoded.iter().any(|&s| s != 0));
    }
    assert_eq!(rest_events[8]["event"], "control_edge");
    assert_eq!(rest_events[8]["down"], true);
    assert_eq!(rest_events[9]["event"], "control_edge");
    assert_eq!(rest_events[9]["down"], false);

    let sock_path = resolve_bridge_socket_path(&workspace.0).unwrap();
    let mut raw_sub = UnixStream::connect(&sock_path).unwrap();
    raw_sub
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    writeln!(
        raw_sub,
        "{}",
        json!({"method": "subscribe", "autoGate": false})
    )
    .unwrap();
    raw_sub.flush().unwrap();
    let mut sub_reader = BufReader::new(raw_sub.try_clone().unwrap());
    let mut sub_hello_line = String::new();
    sub_reader.read_line(&mut sub_hello_line).unwrap();
    let sub_hello: Value = serde_json::from_str(&sub_hello_line).unwrap();
    assert_eq!(sub_hello["event"], "hello");

    writeln!(
        raw_sub,
        "{}",
        json!({"method": "set_capture_active", "active": true, "reason": "shortcut_dictate"})
    )
    .unwrap();
    raw_sub.flush().unwrap();
    std::thread::sleep(Duration::from_millis(20));

    let short_speech: Vec<(u32, u8)> = (22..32).map(|seq| (seq, 0x00)).collect();
    let _ = host.ingest_ble(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &short_speech),
        now_sec + 3,
    );

    writeln!(
        raw_sub,
        "{}",
        json!({"method": "set_capture_active", "active": false, "reason": "shortcut_dictate"})
    )
    .unwrap();
    raw_sub.flush().unwrap();

    for _ in 0..10 {
        let mut line = String::new();
        let n = sub_reader.read_line(&mut line).unwrap();
        assert!(n > 0, "shortcut stop must flush all 10 held-back PCM frames");
        let ev: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(ev["event"], "audio_pcm16");
        let decoded = decode_pcm16_le_b64(ev["samplesLeB64"].as_str().unwrap()).unwrap();
        assert_eq!(decoded.len(), 320);
    }
}

#[test]
fn mcp_stdio_online_reconnects_automatically_after_host_session_restart() {
    let workspace = Workspace::new();
    let host1 = HostSessionGuard::open(&workspace.0).expect("first host session must open");

    let mut mcp_proc = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = mcp_proc.stdin.take().unwrap();
    let mut stdout = BufReader::new(mcp_proc.stdout.take().unwrap());

    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"reconnect-test","version":"1"}}})
    )
    .unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc":"2.0","method":"notifications/initialized"})
    )
    .unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_note","arguments":{"title":"重启前速记","text":"跨宿主会话保留并自动重连。"}}})
    )
    .unwrap();
    stdin.flush().unwrap();

    let mut line1 = String::new();
    stdout.read_line(&mut line1).unwrap();
    let mut line2 = String::new();
    stdout.read_line(&mut line2).unwrap();
    let created_resp: Value = serde_json::from_str(&line2).unwrap();
    assert_eq!(created_resp["result"]["isError"], false);

    drop(host1);
    let _host2 = HostSessionGuard::open(&workspace.0).expect("restarted host session must open");

    writeln!(stdin, "{}", json!({"jsonrpc":"2.0","id":3,"method":"tools/list"})).unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_records","arguments":{"limit":10,"offset":0}}})
    )
    .unwrap();
    stdin.flush().unwrap();

    let mut line3 = String::new();
    stdout.read_line(&mut line3).unwrap();
    let tools_resp: Value = serde_json::from_str(&line3).unwrap();
    assert_eq!(
        tools_resp["result"]["tools"].as_array().unwrap().len(),
        EXPECTED_MCP_TOOLS.len()
    );

    let mut line4 = String::new();
    stdout.read_line(&mut line4).unwrap();
    let records_resp: Value = serde_json::from_str(&line4).unwrap();
    assert_eq!(records_resp["result"]["isError"], false);
    let payload: Value =
        serde_json::from_str(records_resp["result"]["content"][0]["text"].as_str().unwrap())
            .unwrap();
    assert_eq!(payload["total"], 1);
    assert_eq!(payload["records"][0]["title"], "重启前速记");

    drop(stdin);
    let status = mcp_proc.wait().unwrap();
    assert!(status.success());
}
