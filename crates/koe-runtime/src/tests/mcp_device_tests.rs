use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_providers::{ProviderEvent, ProviderOutput};
use koe_engine::{
    commands::DeviceCommands,
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    frame::{ProtocolFrame, RX_MAGIC},
    session::REAL_OPUS_20MS_440HZ_PACKET,
    transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES},
};
use serde_json::{json, Value};

use crate::*;

const NOW: u64 = 1_800_000_000;

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-mcp-device-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
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
    pkt.push(1);
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
    pkt.extend_from_slice(&[0, 0, 0, 0, 0]);
    pkt.push(recording_status);
    pkt.extend_from_slice(b"1.0.0");
    let total_len = (pkt.len() + 1) as u16;
    pkt[7] = (total_len & 0xFF) as u8;
    pkt[8] = ((total_len >> 8) & 0xFF) as u8;
    let csum = ProtocolFrame::checksum(&pkt);
    pkt.push(csum);
    pkt
}

fn connect_simulated_bean(runtime: &mut KoeRuntime, connection_id: &str, now: u64) -> [u8; 32] {
    connect_simulated_bean_with_status(runtime, connection_id, now, 0)
}

fn connect_simulated_bean_raw(
    runtime: &mut KoeRuntime,
    connection_id: &str,
    now: u64,
    recording_status: u8,
) -> [u8; 32] {
    let connecting = runtime.dispatch_json(
        &json!({
            "type": "device_event",
            "event": "connecting",
            "connectionId": connection_id,
            "deviceName": "Soundcore Work"
        })
        .to_string(),
        now,
    );
    let snap: Value = serde_json::from_str(&connecting).unwrap();
    assert!(snap["error"].is_null(), "{snap}");

    let ready = runtime.dispatch_json(
        &json!({
            "type": "device_event",
            "event": "ready",
            "connectionId": connection_id,
            "deviceName": "Soundcore Work"
        })
        .to_string(),
        now,
    );
    let snap: Value = serde_json::from_str(&ready).unwrap();
    assert!(snap["error"].is_null(), "{snap}");

    let outbound = runtime.drain_outbound_ble_frames();
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

    runtime.ingest_ble_chunk(&ecdh_rx, now);
    runtime.ingest_ble_chunk(&build_telemetry_rx(recording_status, 8), now);
    session_key
}

fn connect_simulated_bean_with_status(
    runtime: &mut KoeRuntime,
    connection_id: &str,
    now: u64,
    recording_status: u8,
) -> [u8; 32] {
    let key = connect_simulated_bean_raw(runtime, connection_id, now, recording_status);
    if recording_status == 0 {
        runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &[0, 0]), now);
    }
    key
}

fn build_head_rx(
    session_key: &[u8; 32],
    file_id: u32,
    file_size: u32,
    file_key: &[u8; 32],
    file_nonce: &[u8; 16],
) -> Vec<u8> {
    let mut plain_key_mat = Vec::with_capacity(46);
    plain_key_mat.extend_from_slice(b"soundcored3200");
    plain_key_mat.extend_from_slice(file_key);
    let session_nonce = [0x33u8; 16];
    let enc_file_key =
        DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, session_key, &session_nonce).unwrap();
    let mut payload = Vec::with_capacity(87);
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&file_size.to_le_bytes());
    payload.extend_from_slice(file_nonce);
    payload.extend_from_slice(&enc_file_key);
    payload.extend_from_slice(&session_nonce);
    payload.push(0);
    build_rx_frame(0x1A, 0x07, &payload)
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
fn mcp_sixteen_tools_cover_full_workspace_and_reject_unknown_or_destructive_actions() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let tools_list = KoeRuntime::mcp_tools_list();
    let names: Vec<&str> = tools_list["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap())
        .collect();
    assert_eq!(
        names,
        vec![
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
        ]
    );
    assert!(!names.contains(&"purge_record"));
    assert!(!names.contains(&"empty_trash"));

    let unknown = runtime
        .call_mcp_tool_step("google_tasks_sync", &json!({}), NOW)
        .unwrap_err();
    assert_eq!(unknown.code, -32602);
    assert_eq!(
        runtime
            .call_mcp_tool_step("search", &json!(["not-an-object"]), NOW)
            .unwrap_err()
            .code,
        -32602
    );
    assert_eq!(
        runtime
            .call_mcp_tool_step("search", &json!({"query": "x", "extra": 1}), NOW)
            .unwrap_err()
            .code,
        -32602
    );

    let call_ok = |rt: &mut KoeRuntime, name: &str, args: Value, now: u64| -> Value {
        match rt.call_mcp_tool_step(name, &args, now).unwrap() {
            McpToolCallState::Completed(Ok(v)) => v,
            other => panic!("{name} expected Completed(Ok), got {other:?}"),
        }
    };

    let created = call_ok(
        &mut runtime,
        "create_note",
        json!({
            "title": "架构评审记录",
            "text": "周三前完成本地桥与领夹麦联调。\n保留十六千赫兹原始采样。"
        }),
        NOW,
    );
    let record_id = created["id"].as_str().unwrap().to_string();
    assert_eq!(runtime.snapshot(NOW)["section"], "today");

    let edited = call_ok(
        &mut runtime,
        "edit_transcript",
        json!({
            "record_id": record_id,
            "action": "edit_segment",
            "segment_id": "S1",
            "text": "周五前完成本地桥与领夹麦联调。"
        }),
        NOW + 1,
    );
    assert_eq!(edited["ok"], true);
    let _ = call_ok(
        &mut runtime,
        "edit_transcript",
        json!({
            "record_id": record_id,
            "action": "set_speaker",
            "segment_id": "S1",
            "speaker": "Speaker A"
        }),
        NOW + 2,
    );
    let renamed_spk = call_ok(
        &mut runtime,
        "edit_transcript",
        json!({
            "record_id": record_id,
            "action": "rename_speaker",
            "from_speaker": "Speaker A",
            "to_speaker": "Xianwei"
        }),
        NOW + 3,
    );
    assert_eq!(renamed_spk["updatedSegments"], 1);

    let detail = call_ok(
        &mut runtime,
        "get_record",
        json!({"record_id": record_id}),
        NOW + 3,
    );
    assert_eq!(detail["segments"][0]["text"], "周五前完成本地桥与领夹麦联调。");
    assert_eq!(
        detail["segments"][0]["originalText"],
        "周三前完成本地桥与领夹麦联调。"
    );
    assert_eq!(detail["segments"][0]["isEdited"], true);
    assert_eq!(detail["segments"][0]["speaker"], "Xianwei");
    assert_eq!(detail["speakers"][0]["name"], "Xianwei");
    assert_eq!(runtime.snapshot(NOW + 3)["section"], "today");

    let search = call_ok(
        &mut runtime,
        "search",
        json!({"query": "周五前完成本地桥", "limit": 5}),
        NOW + 3,
    );
    assert_eq!(search["sources"][0]["recordId"], record_id);
    assert_eq!(search["sources"][0]["segmentId"], "S1");

    let hl = call_ok(
        &mut runtime,
        "annotate_segment",
        json!({"record_id": record_id, "segment_id": "S2", "kind": "highlight"}),
        NOW + 4,
    );
    assert_eq!(hl["ok"], true);
    let task_ann = call_ok(
        &mut runtime,
        "annotate_segment",
        json!({"record_id": record_id, "segment_id": "S1", "kind": "task"}),
        NOW + 4,
    );
    let task_id = task_ann["itemId"].as_str().unwrap().to_string();
    let mem_ann = call_ok(
        &mut runtime,
        "annotate_segment",
        json!({"record_id": record_id, "segment_id": "S2", "kind": "memory"}),
        NOW + 4,
    );
    assert!(mem_ann["itemId"].is_string());

    let items = call_ok(
        &mut runtime,
        "list_review_items",
        json!({"kind": "task", "state": "accepted"}),
        NOW + 4,
    );
    assert_eq!(items["items"].as_array().unwrap().len(), 1);

    let _ = call_ok(
        &mut runtime,
        "review_item",
        json!({"item_id": task_id, "decision": "reset"}),
        NOW + 5,
    );
    let _ = call_ok(
        &mut runtime,
        "review_item",
        json!({"item_id": task_id, "decision": "accept"}),
        NOW + 5,
    );
    let _ = call_ok(
        &mut runtime,
        "edit_item",
        json!({"item_id": task_id, "text": "周五前交付本地桥与领夹麦", "due": "2026-11-13"}),
        NOW + 5,
    );
    let _ = call_ok(
        &mut runtime,
        "complete_task",
        json!({"item_id": task_id, "completed": true}),
        NOW + 5,
    );

    let brief = call_ok(&mut runtime, "get_today_brief", json!({}), NOW + 5);
    assert_eq!(brief["counts"]["liveRecords"], 1);
    assert_eq!(brief["counts"]["acceptedMemories"], 1);

    let listed = call_ok(
        &mut runtime,
        "list_records",
        json!({"origin": "note", "limit": 10, "offset": 0}),
        NOW + 5,
    );
    assert_eq!(listed["total"], 1);
    assert_eq!(listed["records"][0]["id"], record_id);

    let retrieval_ask = call_ok(
        &mut runtime,
        "ask",
        json!({"question": "周五前完成本地桥", "record_id": record_id}),
        NOW + 6,
    );
    assert_eq!(retrieval_ask["phase"], "ready");

    let ask_op = runtime
        .commit(|w| {
            let req = w
                .begin_ask(
                    SearchScope::Record(record_id.clone()),
                    "十六千赫兹原始采样",
                    NOW + 7,
                )?
                .unwrap();
            Ok(req.operation)
        })
        .unwrap();
    let job_id = runtime.next_job;
    runtime.next_job += 1;
    runtime.pending.insert(job_id, PendingWork::Ask(ask_op));
    assert!(runtime.poll_mcp_ask(10, NOW + 7).is_none());
    runtime.completed.push_back(ProviderEvent {
        operation_id: job_id,
        record_id: "ask".into(),
        result: Ok(ProviderOutput::Chat {
            text: "保留十六千赫兹原始采样 [S1]".into(),
        }),
    });
    let polled_ask = runtime
        .poll_mcp_ask(10, NOW + 8)
        .expect("completed ask must settle on poll_mcp_ask")
        .unwrap();
    assert_eq!(polled_ask["phase"], "ready");

    for forbidden in ["purge", "empty_trash", "destroy"] {
        let err = runtime
            .call_mcp_tool_step(
                "manage_record",
                &json!({"record_id": record_id, "action": forbidden}),
                NOW + 9,
            )
            .unwrap_err();
        assert_eq!(err.code, -32602, "action {forbidden} must fail with -32602");
    }

    let _ = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "rename", "title": "终版评审记录"}),
        NOW + 9,
    );
    let _ = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "archive"}),
        NOW + 9,
    );
    let _ = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "unarchive"}),
        NOW + 9,
    );
    let _ = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "trash"}),
        NOW + 9,
    );
    match runtime
        .call_mcp_tool_step("get_record", &json!({"record_id": record_id}), NOW + 9)
        .unwrap()
    {
        McpToolCallState::Completed(Err(_)) => {}
        other => panic!("trashed get_record must return domain error, got {other:?}"),
    }
    match runtime
        .call_mcp_tool_step(
            "ask",
            &json!({"question": "终版", "record_id": record_id}),
            NOW + 9,
        )
        .unwrap()
    {
        McpToolCallState::Completed(Err(_)) => {}
        other => panic!("trashed ask must return domain error, got {other:?}"),
    }
    let _ = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "restore"}),
        NOW + 10,
    );

    let _ = call_ok(
        &mut runtime,
        "device_control",
        json!({"action": "release_ble"}),
        NOW + 10,
    );
    let dev_status = call_ok(&mut runtime, "device_status", json!({}), NOW + 10);
    assert_eq!(dev_status["autoConnect"], false);

    let updates_initial = call_ok(
        &mut runtime,
        "poll_updates",
        json!({"since_generation": 1}),
        NOW + 10,
    );
    assert_eq!(updates_initial["hasUpdates"], true);
    let current_gen = updates_initial["generation"].as_u64().unwrap();
    let current_rev = updates_initial["revision"].as_u64().unwrap();
    let updates_caught_up = call_ok(
        &mut runtime,
        "poll_updates",
        json!({"since_generation": current_gen, "since_revision": current_rev}),
        NOW + 10,
    );
    assert_eq!(updates_caught_up["hasUpdates"], false);
}

#[test]
fn resolve_bridge_socket_path_maps_sandbox_container_env_overrides_and_length_cap() {
    use std::ffi::OsStr;

    let prod_ws = Path::new(
        "/Users/alice/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace",
    );
    let prod_sock = resolve_bridge_socket_path_with_env(prod_ws, None).unwrap();
    assert_eq!(
        prod_sock,
        PathBuf::from("/Users/alice/Library/Containers/com.anker.ankerRecorder/Data/.koe/koe.sock")
    );
    assert!(prod_sock.as_os_str().as_encoded_bytes().len() < 103);

    let dev_ws = Path::new(
        "/Users/alice/Library/Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspaceDevelopment",
    );
    assert_eq!(
        resolve_bridge_socket_path_with_env(dev_ws, None).unwrap(),
        PathBuf::from(
            "/Users/alice/Library/Containers/com.anker.ankerRecorder/Data/.koe/koe-dev.sock"
        )
    );

    let custom_ws = Path::new("/tmp/koe-ws");
    assert_eq!(
        resolve_bridge_socket_path_with_env(custom_ws, None).unwrap(),
        PathBuf::from("/tmp/koe-ws/koe.sock")
    );

    assert!(resolve_bridge_socket_path_with_env(custom_ws, Some(OsStr::new(""))).is_none());
    assert!(resolve_bridge_socket_path_with_env(custom_ws, Some(OsStr::new("  "))).is_none());
    assert!(resolve_bridge_socket_path_with_env(custom_ws, Some(OsStr::new("0"))).is_none());
    assert!(resolve_bridge_socket_path_with_env(custom_ws, Some(OsStr::new("off"))).is_none());
    assert!(resolve_bridge_socket_path_with_env(custom_ws, Some(OsStr::new("OFF"))).is_none());
    assert_eq!(
        resolve_bridge_socket_path_with_env(custom_ws, Some(OsStr::new("/tmp/custom.sock")))
            .unwrap(),
        PathBuf::from("/tmp/custom.sock")
    );

    let overlong_ws = PathBuf::from(format!("/tmp/{}", "a".repeat(98)));
    assert!(resolve_bridge_socket_path_with_env(&overlong_ws, None).is_none());
    let exact_103 = format!("/tmp/{}.sock", "b".repeat(93));
    assert_eq!(exact_103.len(), 103);
    assert!(resolve_bridge_socket_path_with_env(custom_ws, Some(OsStr::new(&exact_103))).is_none());
}

#[test]
fn isolated_sandbox_workspaces_do_not_share_the_canonical_bridge_socket() {
    let data = Path::new("/tmp/Containers/com.anker.ankerRecorder/Data");
    let canonical = data.join("Library/Application Support/KoeWorkspace");
    let canonical_socket = resolve_bridge_socket_path_with_env(&canonical, None).unwrap();
    for workspace in [
        data.join("verify-self-123"),
        data.join("Library/Application Support/KoeWorkspace/verify-self"),
        data.join("qa/KoeWorkspaceDevelopment"),
    ] {
        let socket = resolve_bridge_socket_path_with_env(&workspace, None);
        assert_ne!(socket.as_ref(), Some(&canonical_socket));
        if let Some(socket) = socket {
            assert_eq!(socket, workspace.join("koe.sock"));
        }
    }
}

#[test]
fn poll_mcp_ask_ignores_unrelated_runtime_error_and_create_note_increments_generation_once() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let gen_before = runtime.generation();
    let created = match runtime
        .call_mcp_tool_step(
            "create_note",
            &json!({"title": "代次校验", "text": "单次提交只递增一代快照。"}),
            NOW,
        )
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("expected completed create_note, got {other:?}"),
    };
    assert_eq!(
        runtime.generation(),
        gen_before + 1,
        "create_note must advance snapshot generation by exactly 1"
    );
    let record_id = created["id"].as_str().unwrap().to_string();

    let ask_op = runtime
        .commit(|w| {
            let req = w
                .begin_ask(
                    SearchScope::Record(record_id.clone()),
                    "单次提交",
                    NOW + 1,
                )?
                .unwrap();
            Ok(req.operation)
        })
        .unwrap();
    let job_id = runtime.next_job;
    runtime.next_job += 1;
    runtime.pending.insert(job_id, PendingWork::Ask(ask_op));
    runtime.set_error("无关并发操作错误");
    runtime.completed.push_back(ProviderEvent {
        operation_id: job_id,
        record_id: "ask".into(),
        result: Ok(ProviderOutput::Chat {
            text: "单次提交只递增一代快照 [S1]".into(),
        }),
    });
    let settled = runtime
        .poll_mcp_ask(0, NOW + 2)
        .expect("completed ask must settle")
        .expect("unrelated runtime.error must not fail settled ask");
    assert_eq!(settled["phase"], "ready");

    let fail_op = runtime
        .commit(|w| {
            let req = w
                .begin_ask(SearchScope::Record(record_id), "单次提交", NOW + 3)?
                .unwrap();
            Ok(req.operation)
        })
        .unwrap();
    let fail_job = runtime.next_job;
    runtime.next_job += 1;
    runtime.pending.insert(fail_job, PendingWork::Ask(fail_op));
    runtime.clear_error();
    runtime.completed.push_back(ProviderEvent {
        operation_id: fail_job,
        record_id: "ask".into(),
        result: Err("模型服务暂时不可用".into()),
    });
    let failed_err = runtime
        .poll_mcp_ask(0, NOW + 4)
        .expect("failed ask must settle")
        .unwrap_err();
    assert!(failed_err.contains("模型服务暂时不可用"), "{failed_err}");
}

#[test]
fn failed_offline_pull_recovers_via_device_refresh_or_manual_download() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let _ = connect_simulated_bean(&mut runtime, "ble-failed-rec", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    runtime.device.session.transfer.phase = koe_engine::session::TransferPhaseTag::Failed;
    runtime.device.session.transfer.file_id = 8501;
    runtime.device.session.transfer.error_code = 1;

    let _ = runtime.dispatch_json(
        &json!({"type": "device_refresh"}).to_string(),
        NOW + 1,
    );
    assert_eq!(
        runtime.device.session.transfer.phase,
        koe_engine::session::TransferPhaseTag::Idle
    );
    let refresh_tx = runtime.drain_outbound_ble_frames();
    assert!(refresh_tx.contains(&DeviceCommands::get_device_info()));
    assert!(refresh_tx.contains(&DeviceCommands::list_files_with_end_time(0)));

    let mut cat_bytes = Vec::new();
    cat_bytes.extend_from_slice(&1u16.to_le_bytes());
    cat_bytes.extend_from_slice(&8502u32.to_le_bytes());
    cat_bytes.extend_from_slice(&(NOW as u32).to_le_bytes());
    cat_bytes.extend_from_slice(&1_000u32.to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &cat_bytes), NOW + 3);
    let _ = runtime.drain_outbound_ble_frames();

    runtime.device.session.transfer.phase = koe_engine::session::TransferPhaseTag::Failed;
    runtime.device.session.transfer.file_id = 8502;
    let res = runtime.dispatch_json(
        &json!({"type": "device_download", "fileId": 8502}).to_string(),
        NOW + 4,
    );
    let snap: Value = serde_json::from_str(&res).unwrap();
    assert!(snap["error"].is_null(), "{snap}");
    assert_eq!(
        runtime.device.session.transfer.phase,
        koe_engine::session::TransferPhaseTag::PullingOffline
    );
    let dl_tx = runtime.drain_outbound_ble_frames();
    assert!(
        dl_tx.contains(&DeviceCommands::start_transport_audio_file(8502, 0, 0)),
        "manual download must recover from Failed phase and initiate 1A/07 offline pull"
    );
}

#[test]
fn failed_phase_survives_5s_poll_blocks_quit_and_clears_on_cancel_quit() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = connect_simulated_bean(&mut runtime, "ble-failed-survive", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    runtime.device.session.transfer.phase = koe_engine::session::TransferPhaseTag::Failed;
    runtime.device.session.transfer.file_id = 9901;
    runtime.device.session.transfer.error_code = 1;

    runtime.poll_timers(5_500, NOW + 6);
    assert_eq!(
        runtime.device.session.transfer.phase,
        koe_engine::session::TransferPhaseTag::Failed,
        "Failed phase must survive 5-second poll timer"
    );

    let empty_cat = build_rx_frame(0x1B, 0x0E, &[0, 0]);
    runtime.ingest_ble_chunk(&empty_cat, NOW + 6);
    assert_eq!(
        runtime.device.session.transfer.phase,
        koe_engine::session::TransferPhaseTag::Failed,
        "Failed phase must survive catalog completion in finalize_staged_catalog"
    );

    let _ = runtime.dispatch_json(&json!({"type": "request_quit"}).to_string(), NOW + 7);
    let snap = runtime.snapshot(NOW + 7);
    assert_eq!(snap["lifecycle"]["quitPhase"], "blocked");
    assert_eq!(snap["lifecycle"]["keepAwake"], true);

    let _ = runtime.dispatch_json(&json!({"type": "cancel_quit"}).to_string(), NOW + 8);
    assert_eq!(
        runtime.device.session.transfer.phase,
        koe_engine::session::TransferPhaseTag::Idle,
        "CancelQuit must clear Failed phase to Idle"
    );
    let snap_after = runtime.snapshot(NOW + 8);
    assert_eq!(snap_after["lifecycle"]["quitPhase"], "running");
}

#[test]
fn release_ble_ignores_late_queued_ble_slices_and_allows_immediate_quit() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let session_key = connect_simulated_bean(&mut runtime, "ble-release-stray", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    let file_key = [0x5Au8; 32];
    let file_nonce = [0x6Bu8; 16];

    let _ = runtime
        .call_mcp_tool_step(
            "device_control",
            &json!({"action": "release_ble"}),
            NOW + 2,
        )
        .unwrap();
    let after_release = runtime.snapshot(NOW + 2);
    assert_eq!(after_release["device"]["connected"], false);
    assert_eq!(after_release["device"]["autoConnect"], false);

    let stray_head = build_head_rx(&session_key, 7002, 1_000, &file_key, &file_nonce);
    runtime.ingest_ble_chunk(&stray_head, NOW + 3);
    let stray_slice = build_encrypted_slices_rx(&file_key, &file_nonce, &[(1, 0x01)]);
    runtime.ingest_ble_chunk(&stray_slice, NOW + 3);

    runtime.poll_timers(20_000, NOW + 23);

    let snap = runtime.snapshot(NOW + 23);
    assert_eq!(snap["device"]["transferPhase"], "idle");
    assert_eq!(snap["device"]["liveBytes"], 0);

    let _ = runtime.dispatch_json(&json!({"type": "request_quit"}).to_string(), NOW + 24);
    let quit_snap = runtime.snapshot(NOW + 24);
    assert_eq!(quit_snap["lifecycle"]["quitPhase"], "ready");
    assert_eq!(quit_snap["lifecycle"]["keepAwake"], false);
}

#[test]
fn teardown_stop_frames_projected_for_recording() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let expected_pause_hex = koe_engine::prng::to_hex_upper(&DeviceCommands::pause_record());
    assert_eq!(expected_pause_hex, "08EE00000018820B00029D");

    assert_eq!(
        runtime.snapshot(NOW)["device"]["teardownStopFramesHex"],
        json!([])
    );

    let _ = connect_simulated_bean(&mut runtime, "ble-teardown", NOW);
    assert_eq!(
        runtime.snapshot(NOW)["device"]["teardownStopFramesHex"],
        json!([])
    );

    let recording_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(&json!({"type": "device_start"}).to_string(), NOW + 1),
    )
    .unwrap();
    assert!(recording_snap["error"].is_null(), "{recording_snap}");
    assert_eq!(recording_snap["device"]["recording"], true);
    assert_eq!(
        recording_snap["device"]["teardownStopFramesHex"],
        json!([expected_pause_hex])
    );

    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x82, &[2]), NOW + 2);
    runtime.poll_timers(2_100, NOW + 5);
    let stopped_snap = runtime.snapshot(NOW + 5);
    assert_eq!(stopped_snap["device"]["recording"], false);
    assert_eq!(stopped_snap["device"]["teardownStopFramesHex"], json!([]));
}

#[test]
fn mcp_create_note_preserves_foreground_quick_note_selection() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let first_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "create_note",
                "title": "第一条闪记",
                "text": "初始闪记正文",
                "stayOnPage": true
            })
            .to_string(),
            NOW,
        ),
    )
    .unwrap();
    assert!(first_snap["error"].is_null(), "{first_snap}");
    let note_1_id = first_snap["workspaces"]["quickNote"]["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(!note_1_id.is_empty());

    let mcp_created = match runtime
        .call_mcp_tool_step(
            "create_note",
            &json!({
                "title": "MCP闪记",
                "text": "通过MCP写入的新闪记"
            }),
            NOW + 1,
        )
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("create_note expected Completed(Ok), got {other:?}"),
    };
    let note_2_id = mcp_created["id"].as_str().unwrap().to_owned();
    assert_ne!(note_2_id, note_1_id);
    assert_eq!(
        runtime.workspace().record(&note_2_id).unwrap().mode,
        koe_engine::product::RecordMode::QuickNote
    );

    let after_mcp = runtime.snapshot(NOW + 1);
    let card_ids: Vec<&str> = after_mcp["workspaces"]["quickNote"]["cards"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|c| c["id"].as_str())
        .collect();
    assert!(
        card_ids.contains(&note_2_id.as_str()),
        "MCP create_note must project into QuickNote cards: {card_ids:?}"
    );
    assert_eq!(
        after_mcp["workspaces"]["quickNote"]["selectedRecordId"],
        json!(note_1_id),
        "MCP create_note must preserve foreground Quick Note selection"
    );
}

#[test]
fn mcp_get_today_brief_counts_archived_live_records_today_while_excluding_from_recent() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let created: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "create_note",
                "title": "归档今日记录",
                "text": "归档保护仍是今日有效记录",
                "stayOnPage": true
            })
            .to_string(),
            NOW,
        ),
    )
    .unwrap();
    assert!(created["error"].is_null(), "{created}");
    let note_id = created["records"][0]["id"].as_str().unwrap().to_owned();

    let archived: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "set_record_archived",
                "recordId": note_id,
                "archived": true
            })
            .to_string(),
            NOW,
        ),
    )
    .unwrap();
    assert!(archived["error"].is_null(), "{archived}");

    let brief = match runtime
        .call_mcp_tool_step("get_today_brief", &json!({}), NOW)
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("get_today_brief expected Completed(Ok), got {other:?}"),
    };
    assert_eq!(brief["todayRecordIds"], json!([note_id]));
    assert_eq!(brief["counts"]["todayRecords"], 1);
    assert_eq!(brief["counts"]["liveRecords"], 1);
    assert_eq!(brief["recentRecords"], json!([]));
}

#[test]
fn mcp_device_start_respects_all_day_and_bean_mode_guards() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _session_key = connect_simulated_bean(&mut runtime, "c-mcp-guard", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    let started = serde_json::from_str::<Value>(
        &runtime.dispatch_json(&json!({"type": "start_all_day", "source": "bean"}).to_string(), NOW),
    )
    .unwrap();
    assert!(started["error"].is_null(), "{started}");
    let _ = runtime.drain_outbound_ble_frames();

    match runtime
        .call_mcp_tool_step("device_control", &json!({"action": "start_recording"}), NOW + 1)
        .unwrap()
    {
        McpToolCallState::Completed(Err(err)) => {
            assert!(err.contains("结束当前记录") || err.contains("无法开始"), "{err}");
        }
        other => panic!("MCP start_recording during active all-day must reject, got {other:?}"),
    }
    assert!(runtime.drain_outbound_ble_frames().is_empty());
}

#[test]
fn bean_notification_pause_resume_keeps_device_file_and_audio_offset() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let key = connect_simulated_bean(&mut runtime, "notification", NOW);
    let fid = 7331u32;
    runtime.ingest_ble_chunk(&build_rx_frame(0x1A, 0x06, &fid.to_le_bytes()), NOW);
    runtime.ingest_ble_chunk(&build_head_rx(&key, fid, u32::MAX, &[3; 32], &[1; 16]), NOW);
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&[3; 32], &[1; 16], &[(0, 0)]),
        NOW,
    );
    assert_eq!(runtime.snapshot(NOW)["activeCapture"]["phase"], "recording");
    runtime.drain_outbound_ble_frames();
    let pause: Value = serde_json::from_str(
        &runtime.dispatch_json(r#"{"type":"capture_action","action":"pause"}"#, NOW),
    )
    .unwrap();
    assert!(pause["error"].is_null(), "{}", pause["error"]);
    assert!(runtime
        .drain_outbound_ble_frames()
        .contains(&DeviceCommands::pause_record()));
    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x82, &[2]), NOW);
    runtime.ingest_ble_chunk(&build_telemetry_rx(2, 8), NOW);
    runtime.poll_timers(5_000, NOW + 5);
    assert_eq!(
        runtime.snapshot(NOW + 5)["activeCapture"]["phase"],
        "paused"
    );
    let resume: Value = serde_json::from_str(
        &runtime.dispatch_json(r#"{"type":"capture_action","action":"resume"}"#, NOW + 5),
    )
    .unwrap();
    assert!(resume["error"].is_null(), "{}", resume["error"]);
    assert!(runtime
        .drain_outbound_ble_frames()
        .contains(&DeviceCommands::start_app_recording()));
    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x82, &[1]), NOW + 5);
    assert_eq!(
        runtime.snapshot(NOW + 5)["activeCapture"]["phase"],
        "recording"
    );
    assert!(runtime.drain_outbound_ble_frames().contains(
        &DeviceCommands::start_transport_audio_file(fid, SLICE_RECORD_BYTES as u32, 1)
    ));
}

#[test]
fn device_refresh_during_catalog_loading_emits_no_empty_ble_frames() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = connect_simulated_bean(&mut runtime, "ble-refresh-loading", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    let first_tx = runtime.device.session.request_full_catalog();
    assert!(!first_tx.is_empty());
    assert!(runtime.device.session.is_catalog_loading());

    let _ = runtime.dispatch_json(&json!({"type": "device_refresh"}).to_string(), NOW + 1);
    let frames = runtime.drain_outbound_ble_frames();
    assert!(
        frames.iter().all(|f| !f.is_empty()),
        "device_refresh during catalog loading emitted empty BLE TX frame: {frames:?}"
    );
    assert!(frames.contains(&DeviceCommands::get_device_info()));
}

#[test]
fn poll_updates_detects_generation_reset_and_surfaces_active_local_speech_jobs() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    assert_eq!(runtime.generation(), 1);

    let reset_poll = match runtime
        .call_mcp_tool_step(
            "poll_updates",
            &json!({"since_generation": 50, "since_revision": 0}),
            NOW,
        )
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("poll_updates failed: {other:?}"),
    };
    assert_eq!(reset_poll["hasUpdates"], true);
    assert_eq!(reset_poll["generationReset"], true);

    let current_rev = reset_poll["revision"].as_u64().unwrap();
    let steady_poll = match runtime
        .call_mcp_tool_step(
            "poll_updates",
            &json!({"since_generation": 1, "since_revision": current_rev}),
            NOW,
        )
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("steady poll_updates failed: {other:?}"),
    };
    assert_eq!(steady_poll["hasUpdates"], false);
    assert_eq!(steady_poll["generationReset"], false);

    let _ = runtime.dispatch_json(
        &json!({"type": "configure_speech", "engine": "apple_speech"}).to_string(),
        NOW,
    );
    let _ = runtime.dispatch_json(
        &json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}).to_string(),
        NOW,
    );
    let rec_id = "bean-local-poll";
    runtime
        .commit(|w| {
            w.insert_record(
                rec_id.into(),
                "Local Poll".into(),
                RecordOrigin::Bean,
                77,
                NOW,
                1_000,
            )
        })
        .unwrap();
    let wav = {
        let mut bytes = koe_engine::wav::OpusWave::wav_header_with_rate(3_200, 16_000).to_vec();
        bytes.extend(std::iter::repeat_n(0u8, 3_200));
        bytes
    };
    recording_assets::save_audio(&sandbox.0, rec_id, &wav).unwrap();
    runtime.auto_transcribe.insert(rec_id.into());
    runtime.poll_timers(0, NOW);
    runtime.poll_timers(0, NOW);

    let active_jobs = runtime.active_local_speech_jobs();
    assert_eq!(active_jobs.len(), 1);
    let expected_op = active_jobs[0].operation_id;

    let active_poll = match runtime
        .call_mcp_tool_step("poll_updates", &json!({}), NOW)
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("active poll_updates failed: {other:?}"),
    };
    let pending_jobs = active_poll["pendingJobs"].as_array().unwrap();
    assert!(
        pending_jobs.iter().any(|job| {
            job["kind"] == "local_transcription"
                && job["recordId"] == rec_id
                && job["engine"] == "apple_speech"
                && job["operationId"] == expected_op
        }),
        "expected local_transcription job in pendingJobs, got {pending_jobs:?}"
    );
}

#[test]
fn manage_record_if_idle_prevents_duplication_and_supports_set_project_and_device_download_all() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let call_ok = |rt: &mut KoeRuntime, name: &str, args: Value, now: u64| -> Value {
        match rt.call_mcp_tool_step(name, &args, now).unwrap() {
            McpToolCallState::Completed(Ok(v)) => v,
            other => panic!("{name} expected Completed(Ok), got {other:?}"),
        }
    };

    let created = call_ok(
        &mut runtime,
        "create_note",
        json!({"title": "Ops Sync", "text": "部署完成。\n保留审计日志。"}),
        NOW,
    );
    let record_id = created["id"].as_str().unwrap().to_string();
    let count_before = runtime.workspace().records().len();

    let skip_transcribe = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "transcribe", "if_idle": true}),
        NOW + 1,
    );
    assert_eq!(skip_transcribe["ok"], true);
    assert_eq!(skip_transcribe["skipped"], true);
    assert_eq!(skip_transcribe["recordId"], record_id);
    assert_eq!(skip_transcribe["action"], "transcribe");
    assert!(skip_transcribe["reason"].as_str().is_some_and(|r| !r.is_empty()));
    assert_eq!(
        runtime.workspace().records().len(),
        count_before,
        "if_idle transcribe must not create duplicate retry record"
    );

    runtime
        .commit(|w| {
            let key = w.begin_analysis(&record_id, AnalysisStage::Summarizing)?;
            let minutes = koe_engine::minutes::parse_meeting_minutes_json(
                r#"{"schemaVersion":2,"title":"Ops Sync","overview":"完成部署","topics":[],"decisions":[{"text":"保留审计日志","sources":["S2"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                &w.record(&record_id).unwrap().aggregate.spine,
            )
            .unwrap();
            w.complete_summary(&key, minutes)
        })
        .unwrap();

    let skip_summary = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "summarize", "if_idle": true}),
        NOW + 2,
    );
    assert_eq!(skip_summary["ok"], true);
    assert_eq!(skip_summary["skipped"], true);
    assert_eq!(skip_summary["action"], "summarize");

    let empty_id = "bean-queued-idle";
    runtime
        .commit(|w| {
            w.insert_record(
                empty_id.into(),
                "Queued Bean".into(),
                RecordOrigin::Bean,
                91,
                NOW + 3,
                1_000,
            )
        })
        .unwrap();
    runtime.auto_transcribe.insert(empty_id.into());
    let skip_queued = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": empty_id, "action": "transcribe", "if_idle": true}),
        NOW + 3,
    );
    assert_eq!(skip_queued["ok"], true);
    assert_eq!(skip_queued["skipped"], true);

    runtime.auto_summarize.insert(empty_id.into());
    let skip_queued_sum = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": empty_id, "action": "summarize", "if_idle": true}),
        NOW + 3,
    );
    assert_eq!(skip_queued_sum["ok"], true);
    assert_eq!(skip_queued_sum["skipped"], true);

    let set_proj = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "set_project", "project": "koe-ops"}),
        NOW + 4,
    );
    assert_eq!(set_proj["ok"], true);
    assert_eq!(set_proj["action"], "set_project");
    let detail = call_ok(
        &mut runtime,
        "get_record",
        json!({"record_id": record_id, "include_segments": false}),
        NOW + 4,
    );
    assert_eq!(detail["project"], "koe-ops");
    assert_eq!(detail["segments"], json!([]));
    assert_eq!(detail["totalSegments"], 2);
    assert_eq!(detail["segmentOffset"], 0);
    assert_eq!(detail["segmentsTruncated"], true);
    assert_eq!(detail["nextSegmentOffset"], 0);
    assert!(!detail["summary"].as_array().unwrap().is_empty());

    let _ = call_ok(
        &mut runtime,
        "manage_record",
        json!({"record_id": record_id, "action": "set_project", "project": null}),
        NOW + 5,
    );
    let cleared = call_ok(
        &mut runtime,
        "get_record",
        json!({"record_id": record_id, "include_segments": false}),
        NOW + 5,
    );
    assert!(cleared["project"].is_null());

    for forbidden in ["purge", "empty_trash"] {
        let err = runtime
            .call_mcp_tool_step(
                "manage_record",
                &json!({"record_id": record_id, "action": forbidden, "if_idle": true}),
                NOW + 6,
            )
            .unwrap_err();
        assert_eq!(err.code, -32602);
    }

    let _ = connect_simulated_bean(&mut runtime, "ble-dl-all", NOW + 7);
    let _ = runtime.drain_outbound_ble_frames();
    let mut cat_bytes = Vec::new();
    cat_bytes.extend_from_slice(&1u16.to_le_bytes());
    cat_bytes.extend_from_slice(&8801u32.to_le_bytes());
    cat_bytes.extend_from_slice(&((NOW + 7) as u32).to_le_bytes());
    cat_bytes.extend_from_slice(&1_000u32.to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &cat_bytes), NOW + 8);
    let _ = runtime.drain_outbound_ble_frames();
    runtime.device.session.transfer.phase = koe_engine::session::TransferPhaseTag::Failed;
    runtime.device.session.transfer.file_id = 8801;

    let dl_all = call_ok(
        &mut runtime,
        "device_control",
        json!({"action": "download_all"}),
        NOW + 9,
    );
    assert_eq!(dl_all["ok"], true);
    assert_eq!(dl_all["action"], "download_all");
    let tx = runtime.drain_outbound_ble_frames();
    assert!(
        tx.contains(&DeviceCommands::start_transport_audio_file(8801, 0, 0)),
        "download_all must dispatch HostIntent::DeviceDownloadAll and emit 1A/07 pull"
    );
}

#[test]
fn get_record_rejects_zero_limit_and_caps_oversized_single_segment() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let giant_text = "中".repeat(550_000);
    let rec_id = "giant-seg";
    runtime
        .commit(|w| {
            w.insert_record(rec_id.into(), "Giant".into(), RecordOrigin::Note, 0, NOW, 0)?;
            w.append_transcript(rec_id, &giant_text, 0, 1000, "manual")?;
            w.append_transcript(rec_id, "second short segment", 1000, 2000, "manual")?;
            Ok(())
        })
        .unwrap();

    let bad_limit = runtime
        .call_mcp_tool_step(
            "get_record",
            &json!({"record_id": rec_id, "segment_limit": 0}),
            NOW,
        )
        .unwrap_err();
    assert_eq!(bad_limit.code, -32602);

    let first = match runtime
        .call_mcp_tool_step("get_record", &json!({"record_id": rec_id}), NOW)
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("get_record giant segment failed: {other:?}"),
    };
    let encoded_len = serde_json::to_vec(&first).unwrap().len();
    assert!(
        encoded_len <= 1_500_000,
        "capped single-segment response exceeded 1.5MB budget: {encoded_len}"
    );
    assert_eq!(first["totalSegments"], 2);
    assert_eq!(first["segmentOffset"], 0);
    assert_eq!(first["segmentsTruncated"], true);
    assert_eq!(first["nextSegmentOffset"], 1);
    assert_eq!(first["segments"].as_array().unwrap().len(), 1);
    assert_eq!(first["segments"][0]["id"], "S1");

    let second = match runtime
        .call_mcp_tool_step(
            "get_record",
            &json!({"record_id": rec_id, "segment_offset": 1}),
            NOW,
        )
        .unwrap()
    {
        McpToolCallState::Completed(Ok(value)) => value,
        other => panic!("get_record second page failed: {other:?}"),
    };
    assert_eq!(second["segments"].as_array().unwrap().len(), 1);
    assert_eq!(second["segments"][0]["id"], "S2");
    assert_eq!(second["segments"][0]["text"], "second short segment");
    assert_eq!(second["segmentsTruncated"], false);
    assert!(second["nextSegmentOffset"].is_null());
}
