#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use koe_host_api::HostSessionGuard;
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

const EXPECTED_MCP_TOOLS: [&str; 17] = [
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
    "manage_vocabulary",
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
        json!({"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"device_control","arguments":{"action":"set_auto_connect","enabled":false}}}),
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
    assert_eq!(dev_status["autoConnect"], false);
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
    assert_eq!(offline_json["device"]["autoConnect"], false);
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

#[test]
fn cli_version_flags_run_without_workspace_and_doctor_exposes_version_build_and_update_state() {
    use koe_engine::{KOE_APP_BUILD, KOE_APP_VERSION, KOE_GITHUB_RELEASES_URL};
    use std::io::Read;
    use std::net::TcpListener;
    use std::time::{Duration, Instant};

    for flag in ["version", "--version", "-V"] {
        let out = Command::new(env!("CARGO_BIN_EXE_koe"))
            .arg(flag)
            .env_remove("HOME")
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "flag {flag} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let parsed: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(parsed["name"], "koe", "flag {flag}");
        assert_eq!(parsed["version"], KOE_APP_VERSION, "flag {flag}");
        assert_eq!(parsed["build"], KOE_APP_BUILD, "flag {flag}");
    }

    let untouched = Workspace::new();
    let version_with_workspace = cli(&untouched.0, &["version"]);
    assert!(version_with_workspace.status.success());
    assert!(
        !untouched.0.exists(),
        "koe version must not create workspace directories"
    );

    let workspace = Workspace::new();
    let offline_doctor = cli(&workspace.0, &["doctor"]);
    assert!(
        offline_doctor.status.success(),
        "{}",
        String::from_utf8_lossy(&offline_doctor.stderr)
    );
    let offline_json: Value = serde_json::from_slice(&offline_doctor.stdout).unwrap();
    assert_eq!(offline_json["workspaceReadable"], true);
    assert_eq!(offline_json["version"], KOE_APP_VERSION);
    assert_eq!(offline_json["build"], KOE_APP_BUILD);
    assert_eq!(offline_json["appUpdate"]["currentVersion"], KOE_APP_VERSION);
    assert_eq!(offline_json["appUpdate"]["currentBuild"], KOE_APP_BUILD);
    assert_eq!(offline_json["appUpdate"]["phase"], "idle");
    assert_eq!(
        offline_json["appUpdate"]["releaseUrl"],
        KOE_GITHUB_RELEASES_URL
    );

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!(
        "http://{}/repos/semantic-craft/koe/releases/latest",
        listener.local_addr().unwrap()
    );
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match listener.accept() {
                Ok((s, _)) => break s,
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "update request accept timeout");
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(err) => panic!("accept failed: {err}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut req_bytes = Vec::new();
        let mut buf = [0u8; 2048];
        loop {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0, "unexpected EOF before HTTP headers");
            req_bytes.extend_from_slice(&buf[..n]);
            if req_bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
        }
        let body = json!({
            "tag_name": "v2.11.0",
            "name": "Koe 2.11.0 (21)",
            "draft": false,
            "prerelease": false,
            "html_url": "https://github.com/semantic-craft/koe/releases/tag/v2.11.0",
            "body": "CLI doctor live bridge check",
            "assets": []
        })
        .to_string();
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
    });

    let now_sec = 1_815_000_000u64;
    let host = HostSessionGuard::open(&workspace.0).expect("host session must open");
    let _ = host
        .dispatch_json(
            &json!({
                "type": "sync_app_metadata",
                "version": "2.10.0",
                "build": "20",
                "updateEndpoint": endpoint,
            })
            .to_string(),
            now_sec,
        )
        .unwrap();
    let _ = host
        .dispatch_json(r#"{"type":"check_app_update"}"#, now_sec + 1)
        .unwrap();

    let poll_deadline = Instant::now() + Duration::from_secs(5);
    let online_json = loop {
        let _ = host.poll_timers(50, now_sec + 2);
        let out = cli(&workspace.0, &["doctor"]);
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let doc: Value = serde_json::from_slice(&out.stdout).unwrap();
        if doc["appUpdate"]["phase"] != "checking" {
            break doc;
        }
        assert!(
            Instant::now() < poll_deadline,
            "online doctor stayed checking"
        );
        std::thread::sleep(Duration::from_millis(10));
    };
    server.join().unwrap();

    assert_eq!(online_json["workspaceReadable"], true);
    assert_eq!(online_json["version"], "2.10.0");
    assert_eq!(online_json["build"], "20");
    assert_eq!(online_json["appUpdate"]["currentVersion"], "2.10.0");
    assert_eq!(online_json["appUpdate"]["currentBuild"], "20");
    assert_eq!(online_json["appUpdate"]["phase"], "available");
    assert_eq!(online_json["appUpdate"]["latestVersion"], "2.11.0");
}

#[test]
fn cli_parity_and_benchmark_safe_succeed_without_touching_workspace() {
    let workspace = Workspace::new();

    let first_parity = cli(&workspace.0, &["parity"]);
    assert!(
        first_parity.status.success(),
        "{}",
        String::from_utf8_lossy(&first_parity.stderr)
    );
    let second_parity = cli(&workspace.0, &["parity"]);
    assert!(
        second_parity.status.success(),
        "{}",
        String::from_utf8_lossy(&second_parity.stderr)
    );
    assert_eq!(first_parity.stdout, second_parity.stdout);

    let vectors: Vec<Value> = serde_json::from_slice(&first_parity.stdout).unwrap();
    assert_eq!(vectors.len(), 20);
    for (idx, vector) in vectors.iter().enumerate() {
        assert_eq!(vector["seed"].as_u64(), Some(idx as u64));
        assert_eq!(vector["rx_count"].as_u64(), Some(2));
        let tx_hex = vector["tx_hex"].as_str().unwrap();
        assert!(!tx_hex.is_empty());
        assert!(tx_hex
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b)));
        let ogg_fnv = vector["ogg_fnv"].as_str().unwrap();
        assert_eq!(ogg_fnv.len(), 16);
        assert!(ogg_fnv
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b)));
    }
    assert!(!workspace.0.exists());

    let bench = cli(&workspace.0, &["benchmark", "--safe"]);
    assert!(
        bench.status.success(),
        "{}",
        String::from_utf8_lossy(&bench.stderr)
    );
    let bench_json: Value = serde_json::from_slice(&bench.stdout).unwrap();
    assert_eq!(bench_json["decoded_packets"].as_u64(), Some(10_000));
    assert_eq!(bench_json["decrypted_bytes"].as_u64(), Some(14_400_000));
    assert_eq!(bench_json["wav_hdr_len"].as_u64(), Some(44));
    assert_eq!(bench_json["ogg_fnv"].as_str().unwrap().len(), 16);
    assert!(!workspace.0.exists());
}

#[cfg(unix)]
struct ShortSocketWorkspace(PathBuf);

#[cfg(unix)]
impl ShortSocketWorkspace {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = PathBuf::from("/tmp").join(format!(
            "koe-b-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&path);
        std::fs::create_dir_all(&path).unwrap();
        assert!(
            path.join("koe.sock").as_os_str().as_encoded_bytes().len() < 103,
            "short socket workspace path exceeded sun_path cap: {}",
            path.display()
        );
        Self(path)
    }
}

#[cfg(unix)]
impl Drop for ShortSocketWorkspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[cfg(unix)]
#[test]
fn bridge_client_rejects_non_socket_permissive_mode_and_oversized_response() {
    use std::os::unix::{fs::PermissionsExt, net::UnixListener};
    use std::sync::{
        atomic::AtomicBool,
        Arc,
    };
    use std::time::{Duration, Instant};

    let run_status = |ws: &Path| {
        Command::new(env!("CARGO_BIN_EXE_koe"))
            .env_remove("KOE_BRIDGE_SOCKET")
            .args(["status", "--workspace"])
            .arg(ws)
            .output()
            .unwrap()
    };

    let ws_file = ShortSocketWorkspace::new();
    let regular_sock = ws_file.0.join("koe.sock");
    std::fs::write(&regular_sock, b"regular-file-sentinel").unwrap();
    let file_out = run_status(&ws_file.0);
    assert!(!file_out.status.success());
    assert!(file_out.stdout.is_empty());
    let file_err: Value = serde_json::from_slice(&file_out.stderr).unwrap();
    assert!(
        file_err["error"].as_str().unwrap().contains("不是 Unix 套接字"),
        "{file_err}"
    );
    assert_eq!(
        std::fs::read(&regular_sock).unwrap(),
        b"regular-file-sentinel"
    );

    let ws_perm = ShortSocketWorkspace::new();
    let perm_sock = ws_perm.0.join("koe.sock");
    let perm_listener = UnixListener::bind(&perm_sock).unwrap();
    perm_listener.set_nonblocking(true).unwrap();
    std::fs::set_permissions(&perm_sock, std::fs::Permissions::from_mode(0o644)).unwrap();
    let stop_perm = Arc::new(AtomicBool::new(false));
    let stop_perm_worker = Arc::clone(&stop_perm);
    let perm_server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut accepted = 0usize;
        while !stop_perm_worker.load(Ordering::Acquire) && Instant::now() < deadline {
            match perm_listener.accept() {
                Ok((mut stream, _)) => {
                    accepted += 1;
                    let _ = stream.set_nonblocking(false);
                    let _ = stream.write_all(
                        b"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"bypassed\":true}}\n",
                    );
                    let _ = stream.flush();
                }
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(_) => break,
            }
        }
        accepted
    });
    let perm_out = run_status(&ws_perm.0);
    stop_perm.store(true, Ordering::Release);
    let perm_accepted = perm_server.join().unwrap();
    assert_eq!(
        perm_accepted, 0,
        "permissive 0644 socket must never be connected"
    );
    assert!(!perm_out.status.success());
    assert!(perm_out.stdout.is_empty());
    let perm_err: Value = serde_json::from_slice(&perm_out.stderr).unwrap();
    assert!(
        perm_err["error"].as_str().unwrap().contains("权限不安全"),
        "{perm_err}"
    );

    let ws_big = ShortSocketWorkspace::new();
    let big_sock = ws_big.0.join("koe.sock");
    let big_listener = UnixListener::bind(&big_sock).unwrap();
    big_listener.set_nonblocking(true).unwrap();
    std::fs::set_permissions(&big_sock, std::fs::Permissions::from_mode(0o600)).unwrap();
    let stop_big = Arc::new(AtomicBool::new(false));
    let stop_big_worker = Arc::clone(&stop_big);
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match big_listener.accept() {
                Ok((stream, _)) => break Some(stream),
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    if stop_big_worker.load(Ordering::Acquire) || Instant::now() >= deadline {
                        break None;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(err) => panic!("unix accept failed: {err}"),
            }
        };
        let Some(stream) = stream else {
            return false;
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        let mut req_line = String::new();
        let _ = reader.read_line(&mut req_line);
        let mut writer = stream;
        let payload = format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\"{}\"}}\n",
            "a".repeat(2 * 1024 * 1024 + 64)
        );
        let _ = writer.write_all(payload.as_bytes());
        let _ = writer.flush();
        true
    });
    let big_out = run_status(&ws_big.0);
    stop_big.store(true, Ordering::Release);
    assert!(server.join().unwrap(), "bridge client did not connect to 0600 socket");
    assert!(!big_out.status.success());
    assert!(big_out.stdout.is_empty());
    let big_err: Value = serde_json::from_slice(&big_out.stderr).unwrap();
    assert!(
        big_err["error"].as_str().unwrap().contains("2 MiB"),
        "{big_err}"
    );
}

#[test]
fn mcp_stdio_rejects_malformed_json_uninitialized_tools_list_and_oversized_request() {
    let workspace = Workspace::new();
    let mut process = Command::new(env!("CARGO_BIN_EXE_koe"))
        .env_remove("KOE_BRIDGE_SOCKET")
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = process.stdin.take().unwrap();
    let writer = std::thread::spawn(move || {
        let _ = writeln!(stdin, "{{not-valid-json");
        let _ = writeln!(
            stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        );
        let oversized = format!(
            "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"ping\",\"params\":\"{}\"}}\n",
            "z".repeat(2 * 1024 * 1024 + 64)
        );
        let _ = stdin.write_all(oversized.as_bytes());
        let _ = stdin.flush();
    });
    let output = process.wait_with_output().unwrap();
    writer.join().unwrap();

    assert!(!output.status.success());
    let responses: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(responses.len(), 3, "{responses:?}");
    assert_eq!(responses[0]["error"]["code"], -32700);
    assert_eq!(responses[1]["id"], 1);
    assert_eq!(responses[1]["error"]["code"], -32600);
    assert_eq!(responses[2]["error"]["code"], -32600);
    assert!(responses[2]["error"]["message"]
        .as_str()
        .unwrap()
        .contains("2 MiB"));
    let stderr_json: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert!(stderr_json["error"].as_str().unwrap().contains("过长"));
}

#[cfg(unix)]
#[test]
fn mcp_stdio_online_ask_polls_live_host_session_over_unix_socket() {
    use std::io::Read;
    use std::net::TcpListener;
    use std::sync::{atomic::AtomicBool, Arc};
    use std::time::{Duration, Instant};

    let workspace = ShortSocketWorkspace::new();
    let Some(sock_path) = koe_runtime::resolve_bridge_socket_path(&workspace.0) else {
        return;
    };

    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let chat_url = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let stop_http = Arc::new(AtomicBool::new(false));
    let stop_http_worker = Arc::clone(&stop_http);

    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break Some(stream),
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    if stop_http_worker.load(Ordering::Acquire) || Instant::now() >= deadline {
                        break None;
                    }
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(err) => panic!("chat accept failed: {err}"),
            }
        };
        let Some(mut stream) = stream else {
            return false;
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut req_bytes = Vec::new();
        let mut buf = [0u8; 4096];
        let header_end = loop {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0, "unexpected EOF reading chat request headers");
            req_bytes.extend_from_slice(&buf[..n]);
            if let Some(pos) = req_bytes.windows(4).position(|w| w == b"\r\n\r\n") {
                break pos + 4;
            }
        };
        let headers = String::from_utf8_lossy(&req_bytes[..header_end]);
        let content_len = headers
            .lines()
            .find_map(|line| {
                let (k, v) = line.split_once(':')?;
                k.eq_ignore_ascii_case("content-length")
                    .then(|| v.trim().parse::<usize>().ok())
                    .flatten()
            })
            .unwrap_or(0);
        while req_bytes.len() < header_end + content_len {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0, "unexpected EOF reading chat request body");
            req_bytes.extend_from_slice(&buf[..n]);
        }
        let body_text = String::from_utf8_lossy(&req_bytes[header_end..header_end + content_len]);
        assert!(body_text.contains("何时交付原生界面"), "{body_text}");

        std::thread::sleep(Duration::from_millis(60));

        let body = json!({
            "choices": [{
                "message": {
                    "content": "周五前交付原生界面，并保留录音来源 [S1]。"
                }
            }]
        })
        .to_string();
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
        stream.flush().unwrap();
        true
    });

    let now_sec = 1_820_000_000u64;
    let host = HostSessionGuard::open(&workspace.0).expect("host session must open");
    assert!(
        sock_path.exists(),
        "HostSessionGuard did not bind expected bridge socket at {}",
        sock_path.display()
    );
    let created: Value = serde_json::from_str(
        &host
            .dispatch_json(
                &json!({
                    "type": "create_note",
                    "title": "在线问答交付计划",
                    "text": "周五前交付原生界面，并保留录音来源。"
                })
                .to_string(),
                now_sec,
            )
            .unwrap(),
    )
    .unwrap();
    assert!(created["error"].is_null(), "{created}");
    let seed_id = created["detail"]["id"].as_str().unwrap().to_owned();

    let configured: Value = serde_json::from_str(
        &host
            .dispatch_json(
                &json!({
                    "type": "configure_provider",
                    "apiKey": "online-ask-key",
                    "model": "deepseek-chat",
                    "chatEndpoint": chat_url
                })
                .to_string(),
                now_sec,
            )
            .unwrap(),
    )
    .unwrap();
    assert!(configured["error"].is_null(), "{configured}");
    assert_eq!(configured["provider"]["configured"], true);

    let mut process = Command::new(env!("CARGO_BIN_EXE_koe"))
        .env("KOE_BRIDGE_SOCKET", &sock_path)
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = process.stdin.take().unwrap();
    let requests = [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"online-ask-test","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"ask","arguments":{"question":"何时交付原生界面？","record_id":seed_id}}}),
    ];
    let writer = std::thread::spawn(move || {
        for req in requests {
            writeln!(stdin, "{req}").unwrap();
        }
    });
    let output = process.wait_with_output().unwrap();
    writer.join().unwrap();
    stop_http.store(true, Ordering::Release);
    assert!(
        server.join().unwrap(),
        "online ask did not hit loopback chat server"
    );

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
    assert_eq!(responses.len(), 2, "{responses:?}");
    assert_eq!(responses[1]["id"], 2);
    assert_eq!(responses[1]["result"]["isError"], false, "{}", responses[1]);

    let ask_payload: Value =
        serde_json::from_str(responses[1]["result"]["content"][0]["text"].as_str().unwrap())
            .unwrap();
    assert_eq!(ask_payload["phase"], "ready");
    assert_eq!(ask_payload["recordId"], seed_id);
    let last_msg = ask_payload["messages"].as_array().unwrap().last().unwrap();
    assert_eq!(last_msg["role"], "assistant");
    assert_eq!(last_msg["mode"], "answer");
    assert!(last_msg["text"]
        .as_str()
        .unwrap()
        .contains("周五前交付原生界面"));
    assert_eq!(last_msg["sources"][0]["recordId"], seed_id);
    assert_eq!(last_msg["sources"][0]["segmentId"], "S1");

    drop(host);
    let reopened = KoeRuntime::open(&workspace.0).unwrap();
    let persisted = reopened
        .workspace()
        .ask_session()
        .messages
        .last()
        .expect("grounded ask answer must persist across reopen");
    assert!(persisted.grounded);
    assert!(!persisted.notice);
    assert!(persisted.text.contains("周五前交付原生界面"));
    assert_eq!(persisted.sources[0].source.recording_key, seed_id);
}

#[test]
fn cli_doctor_bundle_and_replay_roundtrip_online_and_offline_without_leaking_secrets() {
    let workspace = Workspace::new();
    let now_sec = 1_820_000_000u64;
    let bundle_path = workspace.0.join("exported-bundle.json");

    let host = HostSessionGuard::open(&workspace.0).expect("live host session must open");
    let _ = host
        .dispatch_json(
            &json!({
                "type": "configure_provider",
                "apiKey": "sk-cli-secret-88888",
                "model": "deepseek-flash"
            })
            .to_string(),
            now_sec,
        )
        .unwrap();
    let _ = host
        .dispatch_json(
            &json!({
                "type": "create_note",
                "title": "CLI私密标题",
                "text": "CLI私密正文"
            })
            .to_string(),
            now_sec + 1,
        )
        .unwrap();

    // Online bundle export to stdout via local bridge.
    let stdout_out = cli(&workspace.0, &["doctor", "--bundle"]);
    assert!(
        stdout_out.status.success(),
        "{}",
        String::from_utf8_lossy(&stdout_out.stderr)
    );
    let stdout_text = String::from_utf8(stdout_out.stdout).unwrap();
    assert!(!stdout_text.contains("sk-cli-secret-88888"));
    assert!(!stdout_text.contains("CLI私密标题"));
    assert!(!stdout_text.contains("CLI私密正文"));
    let online_bundle: Value = serde_json::from_str(&stdout_text).unwrap();
    assert_eq!(online_bundle["bundleVersion"], 1);
    assert!(online_bundle["doctor"]["runtimeState"].is_object());
    assert!(online_bundle["flightRecorder"]["entries"].as_array().unwrap().len() >= 2);

    // Online bundle export to explicit path.
    let file_out = cli(
        &workspace.0,
        &["doctor", "--bundle", bundle_path.to_str().unwrap()],
    );
    assert!(
        file_out.status.success(),
        "{}",
        String::from_utf8_lossy(&file_out.stderr)
    );
    let file_raw = std::fs::read_to_string(&bundle_path).unwrap();
    assert!(!file_raw.contains("sk-cli-secret-88888"));
    let file_bundle: Value = serde_json::from_str(&file_raw).unwrap();
    assert_eq!(file_bundle["bundleVersion"], 1);

    // Replay must succeed WITHOUT requiring or locking the live workspace!
    let replay_out = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["doctor", "--replay", bundle_path.to_str().unwrap()])
        .output()
        .unwrap();
    assert!(
        replay_out.status.success(),
        "{}",
        String::from_utf8_lossy(&replay_out.stderr)
    );
    let report: Value = serde_json::from_slice(&replay_out.stdout).unwrap();
    assert_eq!(
        report["finalGeneration"],
        file_bundle["doctor"]["generation"]
    );
    assert_eq!(
        report["doctor"]["runtimeState"],
        file_bundle["doctor"]["runtimeState"]
    );
    assert_eq!(report["snapshotSummary"]["recordCount"], 1);

    // Offline bundle export after closing live host.
    drop(host);
    let offline_out = cli(&workspace.0, &["doctor", "--bundle"]);
    assert!(
        offline_out.status.success(),
        "{}",
        String::from_utf8_lossy(&offline_out.stderr)
    );
    let offline_bundle: Value = serde_json::from_slice(&offline_out.stdout).unwrap();
    assert_eq!(offline_bundle["bundleVersion"], 1);
    assert!(offline_bundle["doctor"]["runtimeState"].is_object());

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&bundle_path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "exported diagnostics bundle must have 0600 permissions");
    }

    // `koe --bundle doctor --workspace <ws>` must not swallow `doctor` as bundle path.
    let prefix_flag_out = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["--bundle", "doctor", "--workspace"])
        .arg(&workspace.0)
        .output()
        .unwrap();
    assert!(
        prefix_flag_out.status.success(),
        "{}",
        String::from_utf8_lossy(&prefix_flag_out.stderr)
    );
    let prefix_bundle: Value = serde_json::from_slice(&prefix_flag_out.stdout).unwrap();
    assert_eq!(prefix_bundle["bundleVersion"], 1);
    assert!(!workspace.0.join("doctor").exists());
}

#[test]
fn online_bridge_diagnostics_succeeds_after_2048_large_ble_chunks() {
    let workspace = Workspace::new();
    let now_sec = 1_820_100_000u64;
    let host = HostSessionGuard::open(&workspace.0).expect("live host session must open");

    let chunk = vec![0xABu8; 512];
    for i in 0..2048u64 {
        let _ = host.ingest_ble(&chunk, now_sec + i);
    }

    let out = cli(&workspace.0, &["doctor", "--bundle"]);
    assert!(
        out.status.success(),
        "online bridge diagnostics must stay under 2 MiB IPC limit: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        out.stdout.len() < 2 * 1024 * 1024,
        "diagnostics payload {} bytes exceeded 2 MiB",
        out.stdout.len()
    );
    let bundle: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(bundle["bundleVersion"], 1);
    assert!(bundle["flightRecorder"]["droppedCount"].as_u64().unwrap() > 0);
}
