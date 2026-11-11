use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_providers::{ProviderEvent, ProviderOutput};
use koe_engine::{
    commands::DeviceCommands,
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    frame::{ProtocolFrame, RX_MAGIC},
    session::REAL_OPUS_20MS_440HZ_PACKET,
    transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES, UNFINISHED_FILE_SIZE},
};
use serde_json::{json, Value};

use super::*;

const NOW: u64 = 1_800_000_000;

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-companion-mcp-{}-{}",
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

fn connect_simulated_bean(runtime: &mut KoeRuntime, connection_id: &str, now: u64) -> [u8; 32] {
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
    runtime.ingest_ble_chunk(&build_telemetry_rx(0, 8), now);
    session_key
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

fn activate_realtime_file(
    runtime: &mut KoeRuntime,
    session_key: &[u8; 32],
    file_id: u32,
    now: u64,
) -> ([u8; 32], [u8; 16]) {
    let mut list_payload = Vec::new();
    list_payload.extend_from_slice(&1u16.to_le_bytes());
    list_payload.extend_from_slice(&file_id.to_le_bytes());
    list_payload.extend_from_slice(&0u32.to_le_bytes());
    list_payload.extend_from_slice(&1_000u32.to_le_bytes());
    let list_rx = build_rx_frame(0x1B, 0x0E, &list_payload);
    runtime.ingest_ble_chunk(&list_rx, now);

    let outbound = runtime.drain_outbound_ble_frames();
    assert!(
        outbound
            .iter()
            .any(|f| f == &DeviceCommands::start_transport_audio_file(file_id, 0, 1)),
        "1B/0E active file announcement must trigger 1A/07 realtime subscription"
    );

    let file_key = [0x5Au8; 32];
    let file_nonce = [0x6Bu8; 16];
    let head_rx = build_head_rx(session_key, file_id, UNFINISHED_FILE_SIZE, &file_key, &file_nonce);
    runtime.ingest_ble_chunk(&head_rx, now);
    (file_key, file_nonce)
}

fn is_uuid_v4(value: &str) -> bool {
    let parts: Vec<&str> = value.split('-').collect();
    parts.len() == 5
        && parts[0].len() == 8
        && parts[1].len() == 4
        && parts[2].len() == 4
        && parts[3].len() == 4
        && parts[4].len() == 12
        && parts[2].starts_with('4')
        && matches!(parts[3].as_bytes()[0], b'8' | b'9' | b'a' | b'b')
        && parts
            .iter()
            .all(|part| part.bytes().all(|b| b.is_ascii_hexdigit()))
}

#[test]
fn collar_standby_auto_starts_streams_without_creating_records_and_deletes_scratch_on_reconnect() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let snap: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
            NOW,
        ),
    )
    .unwrap();
    assert!(snap["error"].is_null(), "{snap}");
    assert_eq!(snap["device"]["companionMode"], "collar_standby");
    assert_eq!(snap["device"]["autoConnect"], true);

    let session_key = connect_simulated_bean(&mut runtime, "ble-conn-1", NOW);
    let outbound = runtime.drain_outbound_ble_frames();
    assert!(
        outbound.contains(&DeviceCommands::start_realtime_record_81()),
        "collar_standby must automatically issue 18/81 start_realtime_record_81 on connect"
    );
    assert!(
        outbound.contains(&DeviceCommands::start_record()),
        "collar_standby must automatically issue 18/82 start_record on connect"
    );

    let (file_key, file_nonce) = activate_realtime_file(&mut runtime, &session_key, 7001, NOW + 1);
    assert!(runtime.is_standby_ready());

    let live_snap = runtime.snapshot(NOW + 1);
    assert_eq!(live_snap["device"]["standbyReady"], true);
    assert_eq!(live_snap["device"]["recording"], false);
    assert_eq!(live_snap["device"]["busy"], false);
    assert_eq!(live_snap["device"]["transferPhase"], "collar_standby");
    assert!(live_snap["device"]["files"].as_array().unwrap().is_empty());

    let events = runtime.drain_companion_events();
    let first_epoch = match &events[0] {
        CompanionStreamEvent::Hello {
            protocol_version,
            epoch,
            online,
            routing_mode,
            controls,
            audio_format,
            ..
        } => {
            assert_eq!(*protocol_version, 1);
            assert!(is_uuid_v4(epoch), "invalid UUID v4: {epoch}");
            assert!(*online);
            assert_eq!(routing_mode, "collar_standby");
            assert_eq!(
                controls,
                &vec![DeclaredControlSpec {
                    name: "front_surface".into(),
                    trigger: "double_tap".into()
                }]
            );
            assert_eq!(audio_format, "pcm16/16000/mono");
            epoch.clone()
        }
        other => panic!("expected initial Hello event, got {other:?}"),
    };
    assert!(events.iter().any(|ev| matches!(
        ev,
        CompanionStreamEvent::DeviceStatus {
            online: true,
            standby_ready: true,
            recording_state: 1,
            ..
        }
    )));

    let slice_specs: Vec<(u32, u8)> = (0..20).map(|seq| (seq, 0x00)).collect();
    let audio_rx = build_encrypted_slices_rx(&file_key, &file_nonce, &slice_specs);
    runtime.ingest_ble_chunk(&audio_rx, NOW + 2);
    assert!(runtime.workspace().records().is_empty());
    assert!(runtime.workspace().is_standby_scratch_file(7001));
    assert!(!sandbox.0.join("audio").exists());

    let _ = runtime.dispatch_json(
        &json!({
            "type": "device_event",
            "event": "disconnected",
            "connectionId": "ble-conn-1"
        })
        .to_string(),
        NOW + 3,
    );
    assert!(runtime.workspace().records().is_empty());
    assert!(runtime.workspace().is_standby_scratch_file(7001));
    assert!(!sandbox.0.join("audio").exists());
    drop(runtime);

    let mut reopened = KoeRuntime::open(&sandbox.0).unwrap();
    assert_eq!(
        reopened.workspace().companion_mode(),
        CompanionRoutingMode::CollarStandby
    );
    assert!(reopened.workspace().is_standby_scratch_file(7001));
    assert!(reopened.workspace().records().is_empty());

    let _ = connect_simulated_bean(&mut reopened, "ble-conn-2", NOW + 10);
    let reconnect_tx = reopened.drain_outbound_ble_frames();
    let delete_pos = reconnect_tx
        .iter()
        .position(|f| f == &DeviceCommands::delete_file(7001))
        .expect("next idle connect must delete standby scratch file 7001 from bean flash");
    let start_pos = reconnect_tx
        .iter()
        .position(|f| f == &DeviceCommands::start_record())
        .expect("next connect in collar_standby must restart standby after scratch cleanup");
    assert!(
        delete_pos < start_pos,
        "scratch file deletion must precede starting the next standby recording"
    );
    assert!(!reopened.workspace().is_standby_scratch_file(7001));
    assert!(reopened.workspace().is_bean_file_purged(7001));

    let reconnect_events = reopened.drain_companion_events();
    match &reconnect_events[0] {
        CompanionStreamEvent::Hello { epoch, .. } => {
            assert!(is_uuid_v4(epoch));
            assert_ne!(epoch, &first_epoch, "reconnect must rotate companion epoch");
        }
        other => panic!("expected Hello on reconnect, got {other:?}"),
    }
}

#[test]
fn double_tap_and_shortcut_gating_trim_tap_thumps_and_keep_phase_aligned() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let session_key = connect_simulated_bean(&mut runtime, "ble-tap", NOW);
    let _ = runtime.drain_outbound_ble_frames();
    let (file_key, file_nonce) = activate_realtime_file(&mut runtime, &session_key, 8001, NOW + 1);
    let _ = runtime.drain_companion_events();

    let mut tap_run = Vec::new();
    tap_run.push((0, 0x01));
    for seq in 1..21 {
        tap_run.push((seq, 0x00));
    }
    tap_run.push((21, 0x01));
    for seq in 22..25 {
        tap_run.push((seq, 0x00));
    }
    let rx = build_encrypted_slices_rx(&file_key, &file_nonce, &tap_run);
    runtime.ingest_ble_chunk(&rx, NOW + 2);

    let events = runtime.drain_companion_events();
    let mut sequences = Vec::new();
    let mut edges = Vec::new();
    let mut pcm_frames = Vec::new();
    for event in &events {
        match event {
            CompanionStreamEvent::ControlEdge {
                sequence,
                control,
                down,
                file_id,
                offset_ms,
                ..
            } => {
                sequences.push(*sequence);
                edges.push((control.clone(), *down, *file_id, *offset_ms));
            }
            CompanionStreamEvent::AudioPcm16 {
                sequence,
                sample_rate_hz,
                samples_le_b64,
                ..
            } => {
                sequences.push(*sequence);
                assert_eq!(*sample_rate_hz, 16_000);
                let decoded = decode_pcm16_le_b64(samples_le_b64).unwrap();
                assert_eq!(decoded.len(), 320);
                assert!(decoded.iter().any(|&s| s != 0));
                pcm_frames.push(decoded);
            }
            _ => {}
        }
    }
    assert_eq!(
        edges,
        vec![
            ("front_surface".into(), true, Some(8001), Some(0)),
            ("front_surface".into(), false, Some(8001), Some(0)),
            ("front_surface".into(), true, Some(8001), Some(420)),
            ("front_surface".into(), false, Some(8001), Some(420)),
        ]
    );
    assert_eq!(
        pcm_frames.len(),
        6,
        "21 slices between double-taps minus 3 post-start-tap skip minus 12 pre-stop-tap trim must yield 6 clean slices"
    );
    assert_eq!(sequences, (1..=10).collect::<Vec<u64>>());

    runtime.set_companion_auto_gate(false);
    runtime.set_companion_capture_active(true, Some("shortcut_dictate".into()));
    let shortcut_slices: Vec<(u32, u8)> = (25..40).map(|seq| (seq, 0x00)).collect();
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &shortcut_slices),
        NOW + 3,
    );
    runtime.set_companion_capture_active(false, Some("shortcut_dictate".into()));
    let shortcut_events = runtime.drain_companion_events();
    let shortcut_pcm_count = shortcut_events
        .iter()
        .filter(|ev| matches!(ev, CompanionStreamEvent::AudioPcm16 { .. }))
        .count();
    assert_eq!(
        shortcut_pcm_count, 15,
        "keyboard shortcut start and stop must skip 0 slices and flush all 12 held-back tail slices"
    );

    runtime.set_companion_capture_active(true, Some("shortcut_ask".into()));
    let mut hybrid_slices: Vec<(u32, u8)> = (40..56).map(|seq| (seq, 0x00)).collect();
    hybrid_slices.push((56, 0x01));
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &hybrid_slices),
        NOW + 4,
    );
    runtime.set_companion_capture_active(false, Some("double_tap".into()));
    let hybrid_events = runtime.drain_companion_events();
    let hybrid_pcm_count = hybrid_events
        .iter()
        .filter(|ev| matches!(ev, CompanionStreamEvent::AudioPcm16 { .. }))
        .count();
    let hybrid_edge_count = hybrid_events
        .iter()
        .filter(|ev| matches!(ev, CompanionStreamEvent::ControlEdge { .. }))
        .count();
    assert_eq!(
        hybrid_pcm_count, 4,
        "16 shortcut-started slices ended by front double-tap must trim the 12-slice tap tail"
    );
    assert_eq!(hybrid_edge_count, 2);
}

#[test]
fn meeting_and_collar_retains_record_while_streaming_and_device_release_persists() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "meeting_and_collar"}).to_string(),
        NOW,
    );
    let session_key = connect_simulated_bean(&mut runtime, "ble-dual", NOW);
    assert!(
        !runtime
            .drain_outbound_ble_frames()
            .contains(&DeviceCommands::start_record()),
        "meeting_and_collar must not auto-start recording until explicitly started"
    );

    let start_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(&json!({"type": "device_start"}).to_string(), NOW + 1),
    )
    .unwrap();
    assert!(start_snap["error"].is_null(), "{start_snap}");
    let _ = runtime.drain_outbound_ble_frames();

    let (file_key, file_nonce) = activate_realtime_file(&mut runtime, &session_key, 9001, NOW + 2);
    assert!(runtime.is_standby_ready());
    let _ = runtime.drain_companion_events();

    let mut slices = vec![(0, 0x01)];
    for seq in 1..20 {
        slices.push((seq, 0x00));
    }
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &slices),
        NOW + 3,
    );
    let companion_events = runtime.drain_companion_events();
    assert_eq!(
        companion_events
            .iter()
            .filter(|ev| matches!(ev, CompanionStreamEvent::ControlEdge { .. }))
            .count(),
        2
    );
    assert_eq!(
        companion_events
            .iter()
            .filter(|ev| matches!(ev, CompanionStreamEvent::AudioPcm16 { .. }))
            .count(),
        5
    );

    let _ = runtime.dispatch_json(&json!({"type": "device_stop"}).to_string(), NOW + 4);
    runtime.ingest_ble_chunk(
        &build_rx_frame(0x18, 0x82, &[2]),
        NOW + 4,
    );
    runtime.poll_timers(2_100, NOW + 7);
    assert_eq!(runtime.workspace().records().len(), 1);
    let saved = runtime.workspace().records().values().next().unwrap();
    assert_eq!(saved.origin, RecordOrigin::Bean);
    assert_eq!(saved.aggregate.file_id, 9001);
    assert_eq!(saved.aggregate.bookmarks, vec![0]);

    let release_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(&json!({"type": "device_release"}).to_string(), NOW + 8),
    )
    .unwrap();
    assert!(release_snap["error"].is_null(), "{release_snap}");
    assert_eq!(release_snap["device"]["connected"], false);
    assert_eq!(release_snap["device"]["autoConnect"], false);
    assert_eq!(release_snap["notice"], "已释放录音豆蓝牙控制权");
    drop(runtime);

    let reopened = KoeRuntime::open(&sandbox.0).unwrap();
    assert!(!reopened.workspace().ble_auto_connect());
    assert_eq!(
        reopened.workspace().companion_mode(),
        CompanionRoutingMode::MeetingAndCollar
    );
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
    assert!(runtime
        .poll_mcp_ask("十六千赫兹原始采样", 10, NOW + 7)
        .is_none());
    runtime.completed.push_back(ProviderEvent {
        operation_id: job_id,
        record_id: "ask".into(),
        result: Ok(ProviderOutput::Chat {
            text: "保留十六千赫兹原始采样 [S1]".into(),
        }),
    });
    let polled_ask = runtime
        .poll_mcp_ask("十六千赫兹原始采样", 10, NOW + 8)
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

    let dev_ctrl = call_ok(
        &mut runtime,
        "device_control",
        json!({"action": "set_companion_mode", "mode": "collar_standby"}),
        NOW + 10,
    );
    assert_eq!(dev_ctrl["device"]["companionMode"], "collar_standby");
    let _ = call_ok(
        &mut runtime,
        "device_control",
        json!({"action": "release_ble"}),
        NOW + 10,
    );
    let dev_status = call_ok(&mut runtime, "device_status", json!({}), NOW + 10);
    assert_eq!(dev_status["autoConnect"], false);
    assert_eq!(dev_status["companionMode"], "collar_standby");
    assert_eq!(dev_status["standbyReady"], false);

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
