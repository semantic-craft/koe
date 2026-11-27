use crate::*;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        Self(std::env::temp_dir().join(format!(
            "koe-projection-contract-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )))
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn dispatch(runtime: &mut KoeRuntime, cmd: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&cmd.to_string(), 1_800_000_000)).unwrap()
}

fn find_row<'a>(snapshot: &'a Value, id: &str) -> &'a Value {
    snapshot["records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["id"].as_str() == Some(id))
        .unwrap()
}

#[test]
fn record_can_trash_and_is_transcribing_reflect_domain_state_and_trash_guard() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let created = dispatch(
        &mut runtime,
        json!({"type": "create_note", "title": "Idle Note", "text": "Domain text"}),
    );
    let note_id = created["selectedRecordId"].as_str().unwrap().to_string();
    assert_eq!(find_row(&created, &note_id)["canTrash"], json!(true));
    assert_eq!(find_row(&created, &note_id)["isTranscribing"], json!(false));
    assert_eq!(created["detail"]["canTrash"], json!(true));

    let archived = dispatch(
        &mut runtime,
        json!({"type": "set_record_archived", "recordId": note_id, "archived": true}),
    );
    assert_eq!(find_row(&archived, &note_id)["canTrash"], json!(false));
    assert_eq!(archived["detail"]["canTrash"], json!(false));

    let unarchived = dispatch(
        &mut runtime,
        json!({"type": "set_record_archived", "recordId": note_id, "archived": false}),
    );
    assert_eq!(find_row(&unarchived, &note_id)["canTrash"], json!(true));
    assert_eq!(unarchived["detail"]["canTrash"], json!(true));

    runtime
        .commit(|w| {
            w.insert_record(
                "rec-empty".into(),
                "Awaiting ASR".into(),
                RecordOrigin::Microphone,
                0,
                1_800_000_001,
                5_000,
            )?;
            w.insert_record(
                "rec-interrupted-lane".into(),
                "Partial Lane".into(),
                RecordOrigin::Microphone,
                0,
                1_800_000_002,
                5_000,
            )?;
            w.set_capture_lanes(
                "rec-interrupted-lane",
                vec![CaptureLaneRecord {
                    lane: "microphone".into(),
                    asset_id: None,
                    sample_rate: None,
                    duration_ms: 0,
                    interruption: Some("设备断开".into()),
                    timeline: Vec::new(),
                }],
            )?;
            w.insert_record(
                "rec-transcribing".into(),
                "Transcribing".into(),
                RecordOrigin::Microphone,
                0,
                1_800_000_003,
                5_000,
            )?;
            w.begin_analysis("rec-transcribing", AnalysisStage::Transcribing)?;
            w.insert_record(
                "rec-summarizing".into(),
                "Summarizing".into(),
                RecordOrigin::Note,
                0,
                1_800_000_004,
                0,
            )?;
            w.append_transcript("rec-summarizing", "Need summary", 0, 0, "fixture")?;
            w.begin_analysis("rec-summarizing", AnalysisStage::Summarizing)?;
            w.insert_record(
                "rec-failed".into(),
                "Failed".into(),
                RecordOrigin::Microphone,
                0,
                1_800_000_005,
                5_000,
            )?;
            let failed_key = w.begin_analysis("rec-failed", AnalysisStage::Transcribing)?;
            w.fail_analysis(&failed_key, "provider timeout")?;
            w.insert_record(
                "rec-interrupted".into(),
                "Interrupted".into(),
                RecordOrigin::Microphone,
                0,
                1_800_000_006,
                5_000,
            )?;
            w.begin_analysis("rec-interrupted", AnalysisStage::Transcribing)?;
            w.interrupt_pending();
            w.begin_analysis("rec-transcribing", AnalysisStage::Transcribing)?;
            w.begin_analysis("rec-summarizing", AnalysisStage::Summarizing)?;
            Ok(())
        })
        .unwrap();

    let snap = runtime.snapshot(1_800_000_010);
    assert_eq!(find_row(&snap, "rec-empty")["isTranscribing"], json!(true));
    assert_eq!(find_row(&snap, "rec-empty")["canTrash"], json!(true));

    assert_eq!(
        find_row(&snap, "rec-interrupted-lane")["isTranscribing"],
        json!(false)
    );
    assert_eq!(
        find_row(&snap, "rec-interrupted-lane")["canTrash"],
        json!(true)
    );

    assert_eq!(
        find_row(&snap, "rec-transcribing")["isTranscribing"],
        json!(true)
    );
    assert_eq!(find_row(&snap, "rec-transcribing")["canTrash"], json!(false));

    assert_eq!(
        find_row(&snap, "rec-summarizing")["isTranscribing"],
        json!(false)
    );
    assert_eq!(find_row(&snap, "rec-summarizing")["canTrash"], json!(false));

    assert_eq!(find_row(&snap, "rec-failed")["isTranscribing"], json!(false));
    assert_eq!(find_row(&snap, "rec-failed")["canTrash"], json!(true));

    assert_eq!(
        find_row(&snap, "rec-interrupted")["isTranscribing"],
        json!(false)
    );
    assert_eq!(find_row(&snap, "rec-interrupted")["canTrash"], json!(true));

    let summarizing_detail = dispatch(
        &mut runtime,
        json!({"type": "select_record", "recordId": "rec-summarizing"}),
    );
    assert_eq!(summarizing_detail["detail"]["canTrash"], json!(false));

    runtime
        .commit(|w| {
            let ask_req = w.begin_ask(
                SearchScope::Record(note_id.clone()),
                "Domain text",
                1_800_000_011,
            )?;
            assert!(ask_req.is_some());
            Ok(())
        })
        .unwrap();
    let during_ask = dispatch(
        &mut runtime,
        json!({"type": "select_record", "recordId": note_id}),
    );
    assert_eq!(find_row(&during_ask, &note_id)["canTrash"], json!(false));
    assert_eq!(during_ask["detail"]["canTrash"], json!(false));

    let capturing = dispatch(
        &mut runtime,
        json!({"type": "start_capture_mode", "mode": "quick_note", "stayOnPage": true}),
    );
    let active_rec_id = capturing["microphone"]["recordId"]
        .as_str()
        .unwrap()
        .to_string();
    let active_ses_id = capturing["microphone"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    dispatch(
        &mut runtime,
        json!({
            "type": "microphone_prepared",
            "recordId": active_rec_id,
            "sessionId": active_ses_id,
            "epoch": 0,
            "clockNs": 1_000_000_000u64
        }),
    );
    dispatch(
        &mut runtime,
        json!({
            "type": "microphone_started",
            "recordId": active_rec_id,
            "sessionId": active_ses_id,
            "lane": "microphone",
            "sampleRate": 16000
        }),
    );
    let receipt = runtime.ingest_microphone_pcm(MicrophonePcmChunk {
        record_id: &active_rec_id,
        session_id: &active_ses_id,
        lane: "microphone",
        sequence: 0,
        samples: &[120i16; 320],
        timing: Some((0, 1_000_000_000)),
        now: 1_800_000_012,
    });
    assert_eq!(receipt.status, PcmIngestStatus::Accepted);
    let active_selected = dispatch(
        &mut runtime,
        json!({"type": "select_record", "recordId": active_rec_id}),
    );
    assert_eq!(
        find_row(&active_selected, &active_rec_id)["canTrash"],
        json!(false)
    );
    assert_eq!(active_selected["detail"]["canTrash"], json!(false));
    let rejected_trash = dispatch(
        &mut runtime,
        json!({"type": "trash_record", "recordId": active_rec_id}),
    );
    assert!(rejected_trash["error"].is_string());
}

#[test]
fn review_counts_project_proposed_tasks_memories_actions_and_active_memories() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let created = dispatch(
        &mut runtime,
        json!({"type": "create_note", "title": "Counts", "text": "Line one\nLine two"}),
    );
    let record_id = created["selectedRecordId"].as_str().unwrap().to_string();
    let segments = created["detail"]["segments"].as_array().unwrap();
    let seg1 = segments[0]["id"].as_str().unwrap().to_string();
    let seg2 = segments[1]["id"].as_str().unwrap().to_string();

    dispatch(
        &mut runtime,
        json!({"type": "create_task", "recordId": record_id, "segmentId": seg1}),
    );
    dispatch(
        &mut runtime,
        json!({"type": "create_task", "recordId": record_id, "segmentId": seg2}),
    );
    dispatch(
        &mut runtime,
        json!({"type": "save_memory", "recordId": record_id, "segmentId": seg1}),
    );
    let snap = dispatch(
        &mut runtime,
        json!({"type": "save_memory", "recordId": record_id, "segmentId": seg2}),
    );
    let task_ids: Vec<String> = snap["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["id"].as_str().unwrap().to_string())
        .collect();
    let mem_ids: Vec<String> = snap["memories"]
        .as_array()
        .unwrap()
        .iter()
        .map(|m| m["id"].as_str().unwrap().to_string())
        .collect();
    for id in task_ids.iter().chain(mem_ids.iter()) {
        dispatch(
            &mut runtime,
            json!({"type": "review_item", "itemId": id, "decision": "reset"}),
        );
    }
    let proposed = runtime.snapshot(1_800_000_000);
    assert_eq!(
        proposed["reviewCounts"],
        json!({
            "proposedTaskCount": 2,
            "proposedMemoryCount": 2,
            "proposedActionCount": 4,
            "activeMemoryCount": 2,
        })
    );

    dispatch(
        &mut runtime,
        json!({"type": "review_item", "itemId": task_ids[0], "decision": "accept"}),
    );
    dispatch(
        &mut runtime,
        json!({"type": "review_item", "itemId": mem_ids[0], "decision": "accept"}),
    );
    let reviewed = dispatch(
        &mut runtime,
        json!({"type": "review_item", "itemId": mem_ids[1], "decision": "dismiss"}),
    );
    assert_eq!(
        reviewed["reviewCounts"],
        json!({
            "proposedTaskCount": 1,
            "proposedMemoryCount": 0,
            "proposedActionCount": 1,
            "activeMemoryCount": 1,
        })
    );
}

#[test]
fn provider_snapshot_projects_authoritative_catalog_and_resolved_default_endpoints() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let initial = runtime.snapshot(1_800_000_000);
    let provider = &initial["provider"];
    assert_eq!(provider["defaultAsrEndpoint"], json!(DEFAULT_DASHSCOPE_WS_URL));
    assert_eq!(
        provider["defaultChatEndpoint"],
        json!(DEFAULT_DEEPSEEK_CHAT_URL)
    );

    let catalog = &provider["catalog"];
    assert_eq!(catalog["qwenAsrModels"].as_array().unwrap().len(), 4);
    assert_eq!(catalog["deepseekLlmModels"].as_array().unwrap().len(), 2);
    assert_eq!(catalog["defaultQwenHost"], json!("dashscope.aliyuncs.com"));
    assert_eq!(
        catalog["qwenWorkspaceHostSuffix"],
        json!(".cn-beijing.maas.aliyuncs.com")
    );
    assert_eq!(
        catalog["defaultDeepseekAsrEndpoint"],
        json!(DEFAULT_DEEPSEEK_ASR_URL)
    );
    assert_eq!(
        catalog["defaultDeepseekChatEndpoint"],
        json!(DEFAULT_DEEPSEEK_CHAT_URL)
    );
    assert_eq!(catalog["defaultQwenAsrModel"], json!(DEFAULT_ASR_MODEL));
    assert_eq!(
        catalog["defaultDeepseekLlmModel"],
        json!(DEFAULT_DEEPSEEK_TEXT_MODEL)
    );

    let configured_qwen = dispatch(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "asrProvider": "qwen",
            "asrModel": QWEN_FILETRANS_ASR_MODEL,
            "llmProvider": "deepseek",
            "model": DEFAULT_DEEPSEEK_TEXT_MODEL,
            "qwenWorkspaceId": "ws-bj-42",
            "asrEndpoint": "",
            "chatEndpoint": ""
        }),
    );
    let expected_ws_ep =
        "https://ws-bj-42.cn-beijing.maas.aliyuncs.com/api/v1/services/audio/asr/transcription";
    assert_eq!(
        configured_qwen["provider"]["asrEndpoint"],
        json!(expected_ws_ep)
    );
    assert_eq!(
        configured_qwen["provider"]["defaultAsrEndpoint"],
        json!(expected_ws_ep)
    );
    assert_eq!(
        configured_qwen["provider"]["defaultChatEndpoint"],
        json!(DEFAULT_DEEPSEEK_CHAT_URL)
    );

    let configured_ds_custom = dispatch(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "asrProvider": "deepseek",
            "asrModel": "",
            "llmProvider": "deepseek",
            "model": "deepseek-v4-pro",
            "asrEndpoint": "https://proxy.example.com/v1/tools/asr",
            "chatEndpoint": "https://proxy.example.com/chat/completions"
        }),
    );
    assert_eq!(
        configured_ds_custom["provider"]["asrEndpoint"],
        json!("https://proxy.example.com/v1/tools/asr")
    );
    assert_eq!(
        configured_ds_custom["provider"]["defaultAsrEndpoint"],
        json!(DEFAULT_DEEPSEEK_ASR_URL)
    );
    assert_eq!(
        configured_ds_custom["provider"]["chatEndpoint"],
        json!("https://proxy.example.com/chat/completions")
    );
    assert_eq!(
        configured_ds_custom["provider"]["defaultChatEndpoint"],
        json!(DEFAULT_DEEPSEEK_CHAT_URL)
    );
}

#[test]
fn record_can_trash_flips_false_while_quitting_and_recovers_on_cancel_quit() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let created = dispatch(
        &mut runtime,
        json!({"type": "create_note", "title": "Quit Guard", "text": "Protected while quitting"}),
    );
    let note_id = created["selectedRecordId"].as_str().unwrap().to_string();
    assert_eq!(find_row(&created, &note_id)["canTrash"], json!(true));
    assert_eq!(created["detail"]["canTrash"], json!(true));

    let quitting = dispatch(&mut runtime, json!({"type": "request_quit"}));
    assert_eq!(find_row(&quitting, &note_id)["canTrash"], json!(false));
    assert_eq!(quitting["detail"]["canTrash"], json!(false));

    let rejected = dispatch(
        &mut runtime,
        json!({"type": "trash_record", "recordId": note_id}),
    );
    assert!(rejected["error"].is_string());

    let resumed = dispatch(&mut runtime, json!({"type": "cancel_quit"}));
    assert_eq!(find_row(&resumed, &note_id)["canTrash"], json!(true));
    assert_eq!(resumed["detail"]["canTrash"], json!(true));
}

#[test]
fn dispatch_json_rejects_payload_exceeding_max_command_json_bytes() {
    assert_eq!(MAX_COMMAND_JSON_BYTES, 2 * 1024 * 1024);
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let oversized = " ".repeat(MAX_COMMAND_JSON_BYTES + 1);
    let snap: Value =
        serde_json::from_str(&runtime.dispatch_json(&oversized, 1_800_000_000)).unwrap();
    assert_eq!(snap["error"], json!("操作内容过大"));
}

#[test]
fn device_snapshot_explicit_disconnect_count_tracks_explicit_disconnects_and_ignores_link_drops() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let initial = runtime.snapshot(1_800_000_000);
    assert_eq!(initial["device"]["phase"], json!("disconnected"));
    assert_eq!(initial["device"]["explicitDisconnectCount"], json!(0));

    dispatch(
        &mut runtime,
        json!({"type": "device_event", "event": "scanning", "connectionId": "conn-1"}),
    );
    dispatch(
        &mut runtime,
        json!({"type": "device_event", "event": "connecting", "connectionId": "conn-1", "deviceName": "Soundcore Work"}),
    );
    let dropped = dispatch(
        &mut runtime,
        json!({"type": "device_event", "event": "disconnected", "connectionId": "conn-1"}),
    );
    assert_eq!(dropped["device"]["phase"], json!("disconnected"));
    assert_eq!(dropped["device"]["explicitDisconnectCount"], json!(0));

    let mcp_disconnect = match runtime
        .call_mcp_tool_step(
            "device_control",
            &json!({"action": "disconnect"}),
            1_800_000_001,
        )
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("unexpected MCP device_control result: {other:?}"),
    };
    assert_eq!(mcp_disconnect["device"]["phase"], json!("disconnected"));
    assert_eq!(
        mcp_disconnect["device"]["explicitDisconnectCount"],
        json!(1)
    );
    assert_eq!(
        runtime.snapshot(1_800_000_001)["device"]["explicitDisconnectCount"],
        json!(1)
    );

    let direct_disconnect = dispatch(&mut runtime, json!({"type": "device_disconnect"}));
    assert_eq!(
        direct_disconnect["device"]["explicitDisconnectCount"],
        json!(2)
    );

    let released = dispatch(&mut runtime, json!({"type": "device_release"}));
    assert_eq!(released["device"]["autoConnect"], json!(false));
    assert_eq!(released["device"]["explicitDisconnectCount"], json!(3));

    dispatch(&mut runtime, json!({"type": "request_quit"}));
    let rejected = dispatch(&mut runtime, json!({"type": "device_disconnect"}));
    assert!(rejected["error"].is_string());
    assert_eq!(rejected["device"]["explicitDisconnectCount"], json!(3));

    dispatch(&mut runtime, json!({"type": "cancel_quit"}));
    dispatch(
        &mut runtime,
        json!({"type": "device_event", "event": "scanning", "connectionId": "conn-2"}),
    );
    let dropped_again = dispatch(
        &mut runtime,
        json!({"type": "device_event", "event": "disconnected", "connectionId": "conn-2"}),
    );
    assert_eq!(dropped_again["device"]["explicitDisconnectCount"], json!(3));
}
