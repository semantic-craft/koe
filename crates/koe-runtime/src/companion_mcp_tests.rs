use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_providers::{ProviderEvent, ProviderOutput};
use koe_engine::{
    commands::DeviceCommands,
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    frame::{ProtocolFrame, RX_MAGIC},
    library::RecordingEntry,
    session::{FinalizedRecording, REAL_OPUS_20MS_440HZ_PACKET},
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

fn connect_simulated_bean_with_catalog(
    runtime: &mut KoeRuntime,
    connection_id: &str,
    now: u64,
    recording_status: u8,
    catalog_payload: &[u8],
) -> [u8; 32] {
    let key = connect_simulated_bean_raw(runtime, connection_id, now, recording_status);
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, catalog_payload), now);
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

#[test]
fn resolve_bridge_socket_path_maps_sandbox_container_env_overrides_and_length_cap() {
    use companion::resolve_bridge_socket_path_with_env;
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
    use companion::resolve_bridge_socket_path_with_env;

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
fn collar_standby_preserves_manual_side_button_recordings_and_inflight_offline_pulls() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let session_key = connect_simulated_bean(&mut runtime, "ble-preserve", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    let mut offline_cat = Vec::new();
    offline_cat.extend_from_slice(&1u16.to_le_bytes());
    offline_cat.extend_from_slice(&6101u32.to_le_bytes());
    offline_cat.extend_from_slice(&40u32.to_le_bytes());
    offline_cat.extend_from_slice(&(NOW as u32).to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &offline_cat), NOW + 1);
    let pull_tx = runtime.drain_outbound_ble_frames();
    assert!(
        pull_tx
            .iter()
            .any(|f| f == &DeviceCommands::start_transport_audio_file(6101, 0, 0)),
        "idle disabled mode must start offline pull for 6101"
    );

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW + 2,
    );
    let file_key_pull = [0x41u8; 32];
    let file_nonce_pull = [0x51u8; 16];
    runtime.ingest_ble_chunk(
        &build_head_rx(&session_key, 6101, 332, &file_key_pull, &file_nonce_pull),
        NOW + 2,
    );
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key_pull, &file_nonce_pull, &[(0, 0), (1, 0)]),
        NOW + 2,
    );
    runtime.ingest_ble_chunk(&build_rx_frame(0x1A, 0x0A, &6101u32.to_le_bytes()), NOW + 3);
    let post_pull_tx = runtime.drain_outbound_ble_frames();
    assert!(
        !post_pull_tx.contains(&DeviceCommands::delete_file(6101)),
        "in-flight offline pull finalized after switching to collar_standby must never be deleted"
    );
    assert!(
        runtime
            .workspace()
            .records()
            .values()
            .any(|r| r.origin == RecordOrigin::Bean && r.aggregate.file_id == 6101),
        "in-flight offline pull 6101 must be saved as a Bean ProductRecord"
    );

    let (sb_key, sb_nonce) = activate_realtime_file(&mut runtime, &session_key, 6102, NOW + 4);
    assert!(runtime.is_standby_ready());
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&sb_key, &sb_nonce, &[(0, 0), (1, 0)]),
        NOW + 4,
    );
    let mut sb_stop = Vec::from(6102u32.to_le_bytes());
    sb_stop.push(0);
    runtime.ingest_ble_chunk(&build_rx_frame(0x1A, 0x06, &sb_stop), NOW + 5);
    runtime.poll_timers(2_100, NOW + 8);
    let sb_cleanup_tx = runtime.drain_outbound_ble_frames();
    assert!(
        sb_cleanup_tx.contains(&DeviceCommands::delete_file(6102)),
        "side-button stop of owned standby file 6102 must reclaim scratch file"
    );
    assert!(
        !runtime
            .workspace()
            .records()
            .values()
            .any(|r| r.aggregate.file_id == 6102)
    );

    let mut manual_start = Vec::from(6103u32.to_le_bytes());
    manual_start.push(1);
    runtime.ingest_ble_chunk(&build_rx_frame(0x1A, 0x06, &manual_start), NOW + 9);
    let manual_sub_tx = runtime.drain_outbound_ble_frames();
    assert!(
        manual_sub_tx.contains(&DeviceCommands::start_transport_audio_file(6103, 0, 1)),
        "manual side-button recording 6103 must subscribe realtime stream"
    );
    let manual_key = [0x43u8; 32];
    let manual_nonce = [0x53u8; 16];
    runtime.ingest_ble_chunk(
        &build_head_rx(
            &session_key,
            6103,
            UNFINISHED_FILE_SIZE,
            &manual_key,
            &manual_nonce,
        ),
        NOW + 9,
    );
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&manual_key, &manual_nonce, &[(0, 0), (1, 0), (2, 0)]),
        NOW + 10,
    );
    let mut manual_stop = Vec::from(6103u32.to_le_bytes());
    manual_stop.push(0);
    runtime.ingest_ble_chunk(&build_rx_frame(0x1A, 0x06, &manual_stop), NOW + 11);
    runtime.poll_timers(2_100, NOW + 14);
    let manual_finish_tx = runtime.drain_outbound_ble_frames();
    assert!(
        !manual_finish_tx.contains(&DeviceCommands::delete_file(6103)),
        "manual side-button recording 6103 must never be wiped via 0x1A 0x10"
    );
    assert!(
        runtime
            .workspace()
            .records()
            .values()
            .any(|r| r.origin == RecordOrigin::Bean && r.aggregate.file_id == 6103),
        "manual side-button recording 6103 must be saved as a Bean ProductRecord"
    );
}

#[test]
fn pre_catalog_mode_switch_and_crash_before_flash_delete_reclaim_standby_idempotently() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let _ = connect_simulated_bean(&mut runtime, "ble-pre-cat", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "disabled"}).to_string(),
        NOW + 1,
    );
    let pre_switch_tx = runtime.drain_outbound_ble_frames();
    assert!(pre_switch_tx.contains(&DeviceCommands::pause_record()));

    let mut late_cat = Vec::new();
    late_cat.extend_from_slice(&1u16.to_le_bytes());
    late_cat.extend_from_slice(&7201u32.to_le_bytes());
    late_cat.extend_from_slice(&0u32.to_le_bytes());
    late_cat.extend_from_slice(&200u32.to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &late_cat), NOW + 2);
    let late_tx = runtime.drain_outbound_ble_frames();
    assert!(
        late_tx.contains(&DeviceCommands::pause_record()),
        "arriving open standby file 7201 after mode switch must be stopped"
    );
    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x82, &[2]), NOW + 2);
    runtime.poll_timers(250, NOW + 3);
    let deferred_tx = runtime.drain_outbound_ble_frames();
    assert!(
        !deferred_tx.contains(&DeviceCommands::delete_file(7201)),
        "deletion of 7201 must be deferred while state == 2"
    );
    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x82, &[0]), NOW + 3);
    runtime.poll_timers(250, NOW + 4);
    let reclaim_tx = runtime.drain_outbound_ble_frames();
    assert!(
        reclaim_tx.contains(&DeviceCommands::delete_file(7201)),
        "dying pre-catalog standby file 7201 must be deleted on idle"
    );
    assert!(runtime.workspace().records().is_empty());
    assert!(runtime.workspace().is_bean_file_purged(7201));
    assert!(runtime.workspace().is_reclaimed_standby_file(7201));
    drop(runtime);

    let mut reopened = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = connect_simulated_bean(&mut reopened, "ble-crash-recover", NOW + 10);
    let _ = reopened.drain_outbound_ble_frames();

    let mut survivor_cat = Vec::new();
    survivor_cat.extend_from_slice(&2u16.to_le_bytes());
    survivor_cat.extend_from_slice(&7201u32.to_le_bytes());
    survivor_cat.extend_from_slice(&(NOW as u32).to_le_bytes());
    survivor_cat.extend_from_slice(&200u32.to_le_bytes());
    survivor_cat.extend_from_slice(&7202u32.to_le_bytes());
    survivor_cat.extend_from_slice(&0u32.to_le_bytes());
    survivor_cat.extend_from_slice(&400u32.to_le_bytes());
    reopened.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &survivor_cat), NOW + 11);

    let snap = reopened.snapshot(NOW + 11);
    let visible_ids: Vec<u64> = snap["device"]["files"]
        .as_array()
        .unwrap()
        .iter()
        .map(|f| f["id"].as_u64().unwrap())
        .collect();
    assert_eq!(
        visible_ids,
        vec![7202],
        "unwiped standby tombstone 7201 must stay hidden from device.files"
    );

    let retry_tx = reopened.drain_outbound_ble_frames();
    assert_eq!(
        retry_tx
            .iter()
            .filter(|&f| f == &DeviceCommands::delete_file(7201))
            .count(),
        1,
        "reconnect with 7201 still in catalog must re-issue 0x1A 0x10 once"
    );
    reopened.poll_timers(250, NOW + 12);
    assert!(
        !reopened
            .drain_outbound_ble_frames()
            .contains(&DeviceCommands::delete_file(7201)),
        "deleted_in_connection must suppress duplicate 0x1A 0x10 within the same connection"
    );
}

#[test]
fn manual_gate_preserves_speech_across_double_tap_and_restores_auto_gate_on_release() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let session_key = connect_simulated_bean(&mut runtime, "ble-manual-gate", NOW);
    let _ = runtime.drain_outbound_ble_frames();
    let (file_key, file_nonce) = activate_realtime_file(&mut runtime, &session_key, 7301, NOW + 1);
    let _ = runtime.drain_companion_events();

    runtime.acquire_companion_manual_gate();
    runtime.set_companion_capture_active(true, Some("shortcut_dictate".into()));

    let mut slices = Vec::new();
    for seq in 0..10 {
        slices.push((seq, 0x00));
    }
    slices.push((10, 0x01));
    for seq in 11..21 {
        slices.push((seq, 0x00));
    }
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &slices),
        NOW + 2,
    );
    runtime.set_companion_capture_active(false, Some("shortcut_dictate".into()));

    let events = runtime.drain_companion_events();
    let edge_count = events
        .iter()
        .filter(|ev| matches!(ev, CompanionStreamEvent::ControlEdge { .. }))
        .count();
    let pcm_count = events
        .iter()
        .filter(|ev| matches!(ev, CompanionStreamEvent::AudioPcm16 { .. }))
        .count();
    assert_eq!(edge_count, 2);
    assert_eq!(
        pcm_count, 21,
        "manual gate must drop zero slices when double-tap fires during active shortcut capture"
    );

    runtime.release_companion_manual_gate();
    let mut resume_slices = vec![(21, 0x01)];
    for seq in 22..40 {
        resume_slices.push((seq, 0x00));
    }
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &resume_slices),
        NOW + 3,
    );
    let resumed_events = runtime.drain_companion_events();
    assert_eq!(
        resumed_events
            .iter()
            .filter(|ev| matches!(ev, CompanionStreamEvent::AudioPcm16 { .. }))
            .count(),
        4,
        "releasing last manual gate must restore double-tap auto-gating with 3-slice start skip and 12-slice holdback"
    );
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
    runtime.error = Some("无关并发操作错误".into());
    runtime.completed.push_back(ProviderEvent {
        operation_id: job_id,
        record_id: "ask".into(),
        result: Ok(ProviderOutput::Chat {
            text: "单次提交只递增一代快照 [S1]".into(),
        }),
    });
    let settled = runtime
        .poll_mcp_ask("单次提交", 0, NOW + 2)
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
    runtime.error = None;
    runtime.completed.push_back(ProviderEvent {
        operation_id: fail_job,
        record_id: "ask".into(),
        result: Err("模型服务暂时不可用".into()),
    });
    let failed_err = runtime
        .poll_mcp_ask("单次提交", 0, NOW + 4)
        .expect("failed ask must settle")
        .unwrap_err();
    assert!(failed_err.contains("模型服务暂时不可用"), "{failed_err}");
}

#[test]
fn collar_standby_disabled_pause_recovery_resumes_open_file_and_protects_pre_existing_files() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let session_key = connect_simulated_bean(&mut runtime, "ble-pause-rec", NOW);
    let initial_outbound = runtime.drain_outbound_ble_frames();
    assert!(
        initial_outbound.contains(&DeviceCommands::start_realtime_record_81()),
        "standby mode must issue 18/81 start_realtime_record_81 on connect"
    );
    assert!(
        initial_outbound.contains(&DeviceCommands::list_files_with_end_time(0)),
        "standby mode must query catalog after 18/81 and 18/82"
    );

    let mut cat_bytes = Vec::new();
    cat_bytes.extend_from_slice(&2u16.to_le_bytes());
    cat_bytes.extend_from_slice(&7501u32.to_le_bytes());
    cat_bytes.extend_from_slice(&(NOW as u32).to_le_bytes());
    cat_bytes.extend_from_slice(&5_000u32.to_le_bytes());
    cat_bytes.extend_from_slice(&7502u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &cat_bytes), NOW + 1);

    let start_sub_tx = runtime.drain_outbound_ble_frames();
    assert!(
        start_sub_tx.contains(&DeviceCommands::start_transport_audio_file(7502, 0, 1)),
        "open standby file 7502 must be subscribed"
    );

    let file_key = [0x5Au8; 32];
    let file_nonce = [0x6Bu8; 16];
    let head_rx = build_head_rx(&session_key, 7502, UNFINISHED_FILE_SIZE, &file_key, &file_nonce);
    runtime.ingest_ble_chunk(&head_rx, NOW + 1);
    assert!(runtime.is_standby_file(7502), "7502 must be owned as standby file");

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "disabled"}).to_string(),
        NOW + 2,
    );
    let pause_tx = runtime.drain_outbound_ble_frames();
    assert!(
        pause_tx.contains(&DeviceCommands::pause_record()),
        "switching from collar_standby to disabled must pause recording"
    );

    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x82, &[2]), NOW + 2);
    assert_eq!(runtime.current_companion_recording_state(), 2);

    runtime.poll_timers(2_000, NOW + 4);
    let auto_tx = runtime.drain_outbound_ble_frames();
    assert!(
        auto_tx
            .iter()
            .all(|f| !(f.len() >= 7 && f[5] == 0x1A && f[6] == 0x07 && f.len() > 10 && f[10] == 0)),
        "paused recording state 2 must suppress auto offline pull"
    );

    let mut resume_cat_bytes = Vec::new();
    resume_cat_bytes.extend_from_slice(&2u16.to_le_bytes());
    resume_cat_bytes.extend_from_slice(&7501u32.to_le_bytes());
    resume_cat_bytes.extend_from_slice(&(NOW as u32).to_le_bytes());
    resume_cat_bytes.extend_from_slice(&5_000u32.to_le_bytes());
    resume_cat_bytes.extend_from_slice(&7502u32.to_le_bytes());
    resume_cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    resume_cat_bytes.extend_from_slice(&2_000u32.to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &resume_cat_bytes), NOW + 4);

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW + 5,
    );
    let resume_start_tx = runtime.drain_outbound_ble_frames();
    assert!(
        resume_start_tx.contains(&DeviceCommands::start_realtime_record_81()),
        "resuming collar_standby must issue 18/81 start_realtime_record_81"
    );

    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &resume_cat_bytes), NOW + 6);
    let resume_sub_tx = runtime.drain_outbound_ble_frames();
    let expected_offset = (2_000 / 20) * 166;
    assert!(
        resume_sub_tx.contains(&DeviceCommands::start_transport_audio_file(7502, expected_offset, 1)),
        "resuming collar_standby with open file 7502 must send slice offset 16600"
    );
    assert!(runtime.is_standby_file(7502), "7502 must still be owned as standby file");

    assert!(
        !runtime.workspace().is_bean_file_purged(7501),
        "pre-existing file 7501 must never be marked purged"
    );
    assert!(
        !runtime.workspace().standby_scratch_file_ids().contains(&7501),
        "pre-existing file 7501 must never be marked as standby scratch"
    );
    assert!(
        !runtime.is_standby_file(7501),
        "pre-existing file 7501 must not be standby file"
    );
}

#[test]
fn collar_standby_connect_in_paused_state_waits_for_initial_catalog_and_protects_pre_existing_open_file() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let session_key = connect_simulated_bean_with_status(&mut runtime, "ble-paused-connect", NOW, 2);
    let connect_outbound = runtime.drain_outbound_ble_frames();
    assert!(
        connect_outbound.contains(&DeviceCommands::list_files_with_end_time(0)),
        "01/01 in paused state must emit initial catalog query"
    );
    assert!(
        !connect_outbound.contains(&DeviceCommands::start_realtime_record_81()),
        "standby mode must wait for initial catalog before sending 18/81 when device is paused"
    );

    let mut cat_bytes = Vec::new();
    cat_bytes.extend_from_slice(&1u16.to_le_bytes());
    cat_bytes.extend_from_slice(&7601u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    cat_bytes.extend_from_slice(&9_480u32.to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &cat_bytes), NOW + 1);

    let cat_ack_tx = runtime.drain_outbound_ble_frames();
    assert!(
        cat_ack_tx.contains(&DeviceCommands::start_realtime_record_81()),
        "after initial catalog completes, standby must send 18/81"
    );
    assert!(
        cat_ack_tx.contains(&DeviceCommands::start_record()),
        "after initial catalog completes, standby must send 18/82 start_record"
    );
    assert!(
        cat_ack_tx.contains(&DeviceCommands::list_files_with_end_time(0)),
        "after initial catalog completes, standby must send 1B/0E(0) after 18/82"
    );

    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &cat_bytes), NOW + 2);
    let sub_tx = runtime.drain_outbound_ble_frames();
    let expected_offset = (9_480 / 20) * 166;
    assert!(
        sub_tx.contains(&DeviceCommands::start_transport_audio_file(7601, expected_offset, 1)),
        "must subscribe to pre-existing open file 7601 with slice offset 78684"
    );

    let file_key = [0x5Au8; 32];
    let file_nonce = [0x6Bu8; 16];
    let head_rx = build_head_rx(&session_key, 7601, UNFINISHED_FILE_SIZE, &file_key, &file_nonce);
    runtime.ingest_ble_chunk(&head_rx, NOW + 2);

    let snap: Value = serde_json::from_str(&runtime.snapshot_json(NOW + 2)).unwrap();
    assert!(runtime.is_standby_ready());
    assert_eq!(snap["device"]["standbyReady"], true);
    assert!(
        !runtime.is_standby_file(7601),
        "pre-existing paused file 7601 must not be marked as standby scratch"
    );

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "disabled"}).to_string(),
        NOW + 3,
    );
    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x82, &[0]), NOW + 3);
    let stop_outbound = runtime.drain_outbound_ble_frames();
    assert!(
        stop_outbound
            .iter()
            .all(|f| !(f.len() >= 7 && f[5] == 0x1A && f[6] == 0x10)),
        "pre-existing file 7601 must never receive 1A/10 delete frame"
    );
    assert!(!runtime.is_standby_file(7601));
    assert!(!runtime.workspace().is_bean_file_purged(7601));
}

#[test]
fn failed_offline_pull_recovers_via_device_refresh_or_mode_switch_or_manual_download() {
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

    runtime.device.session.transfer.phase = koe_engine::session::TransferPhaseTag::Failed;
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "disabled"}).to_string(),
        NOW + 2,
    );
    assert_eq!(
        runtime.device.session.transfer.phase,
        koe_engine::session::TransferPhaseTag::Idle
    );

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
fn repro_connect_mode_switch_never_deletes_closed_user_recording_5002() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );

    let _ = connect_simulated_bean_raw(&mut runtime, "ble-mode-switch-5002", NOW, 0);
    let _ = runtime.drain_outbound_ble_frames();

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "disabled"}).to_string(),
        NOW + 1,
    );
    let switch_tx = runtime.drain_outbound_ble_frames();
    assert!(!switch_tx.iter().any(|f| f.len() >= 7 && f[5] == 0x1A && f[6] == 0x10));

    let mut cat_bytes = Vec::new();
    cat_bytes.extend_from_slice(&1u16.to_le_bytes());
    cat_bytes.extend_from_slice(&5002u32.to_le_bytes());
    cat_bytes.extend_from_slice(&1_700_000_120u32.to_le_bytes());
    cat_bytes.extend_from_slice(&120_000u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &cat_bytes), NOW + 2);
    runtime.poll_timers(500, NOW + 3);

    let late_tx = runtime.drain_outbound_ble_frames();
    assert!(
        !late_tx.contains(&DeviceCommands::delete_file(5002)),
        "closed user recording 5002 must never receive 0x1A 0x10 delete frame"
    );
    assert!(!runtime.is_standby_file(5002));
    assert!(!runtime.workspace().is_bean_file_purged(5002));

    let sandbox2 = Sandbox::new();
    let mut runtime2 = KoeRuntime::open(&sandbox2.0).unwrap();
    let _ = runtime2.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let _session_key2 = connect_simulated_bean_with_catalog(
        &mut runtime2,
        "ble-normal-5002",
        NOW,
        0,
        &cat_bytes,
    );
    assert!(runtime2.device.session.has_complete_catalog());
    assert!(runtime2.companion.pre_standby_catalog_ids.contains(&5002));
    assert!(!runtime2.can_own_as_standby_scratch(5002));

    let connect_outbound = runtime2.drain_outbound_ble_frames();
    assert!(
        !connect_outbound.contains(&DeviceCommands::delete_file(5002)),
        "5002 must not be deleted on connect"
    );

    let _ = runtime2.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "disabled"}).to_string(),
        NOW + 2,
    );
    runtime2.poll_timers(250, NOW + 3);
    let stop_outbound = runtime2.drain_outbound_ble_frames();
    assert!(
        !stop_outbound.contains(&DeviceCommands::delete_file(5002)),
        "5002 must not be deleted on stop"
    );
    assert!(!runtime2.is_standby_file(5002));
    assert!(!runtime2.workspace().is_bean_file_purged(5002));
}

#[test]
fn packet_order_1881_before_1b0e_preserves_paused_base_slices() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );

    let mut cat_bytes = Vec::new();
    cat_bytes.extend_from_slice(&1u16.to_le_bytes());
    cat_bytes.extend_from_slice(&1794015297u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    cat_bytes.extend_from_slice(&9_480u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());
    cat_bytes.extend_from_slice(&0u32.to_le_bytes());

    let session_key = connect_simulated_bean_with_catalog(
        &mut runtime,
        "ble-paused-base",
        NOW,
        2,
        &cat_bytes,
    );
    assert!(runtime.device.session.has_complete_catalog());
    assert_eq!(runtime.device.session.known_base_slices_for(1794015297), 474);

    let mut ack_81 = Vec::from(1794015297u32.to_le_bytes());
    ack_81.push(1);
    runtime.ingest_ble_chunk(&build_rx_frame(0x18, 0x81, &ack_81), NOW + 1);

    let outbound = runtime.drain_outbound_ble_frames();
    assert!(
        outbound.contains(&DeviceCommands::start_transport_audio_file(1794015297, 78_684, 1)),
        "1A/07 must use byte_offset == 474 * 166 == 78_684"
    );

    let file_key = [0x91u8; 32];
    let file_nonce = [0x92u8; 16];
    let head = build_head_rx(&session_key, 1794015297, UNFINISHED_FILE_SIZE, &file_key, &file_nonce);
    runtime.ingest_ble_chunk(&head, NOW + 2);

    assert!(runtime.treats_file_as_standby(1794015297));
    assert!(!runtime.can_own_as_standby_scratch(1794015297));
    assert!(!runtime.is_standby_file(1794015297));
    assert!(runtime.workspace().records().is_empty(), "standby routing must not create ProductRecord");

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "disabled"}).to_string(),
        NOW + 3,
    );
    runtime.poll_timers(250, NOW + 4);
    let stop_tx = runtime.drain_outbound_ble_frames();
    assert!(
        !stop_tx.contains(&DeviceCommands::delete_file(1794015297)),
        "pre-existing paused file 1794015297 must not receive delete frame"
    );
}

#[test]
fn non_standby_finalized_offline_pull_saved_while_standby_active() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let _session_key = connect_simulated_bean(&mut runtime, "ble-offline-standby", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    assert!(runtime.companion.standby_stream_owned);

    runtime.device.finalized.push(FinalizedRecording {
        entry: RecordingEntry {
            id: 5002,
            bean_file_id: 5002,
            created_at_epoch_sec: NOW,
            duration_ms: 2_000,
            byte_count: 5,
            marks_ms: vec![],
        },
        ogg_opus_bytes: vec![0x4F, 0x67, 0x67, 0x53, 0x00],
        preview_wav_bytes: vec![],
        is_realtime: false,
        base_slice_offset: 0,
    });

    runtime.save_device_recordings(NOW).unwrap();

    assert!(
        runtime
            .workspace()
            .records()
            .values()
            .any(|r| r.origin == RecordOrigin::Bean && r.aggregate.file_id == 5002),
        "user file 5002 must be saved to workspace even while standby is active"
    );
    let outbound = runtime.drain_outbound_ble_frames();
    assert!(
        !outbound.contains(&DeviceCommands::delete_file(5002)),
        "user file 5002 must not receive delete frame"
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

    let _ = runtime.dispatch_json(
        &json!({"type": "set_companion_mode", "mode": "collar_standby"}).to_string(),
        NOW,
    );
    let session_key = connect_simulated_bean(&mut runtime, "ble-release-stray", NOW);
    let _ = runtime.drain_outbound_ble_frames();

    let (file_key, file_nonce) = activate_realtime_file(&mut runtime, &session_key, 7001, NOW + 1);
    assert!(runtime.is_standby_ready());

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
fn standby_double_tap_recognizes_the_trimmed_selection_and_keeps_pcm_protocol() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    runtime.dispatch_json(
        r#"{"type":"local_asr_readiness","state":"ready","message":"ready"}"#,
        NOW,
    );
    runtime.dispatch_json(
        r#"{"type":"set_companion_mode","mode":"collar_standby"}"#,
        NOW,
    );
    let session_key = connect_simulated_bean(&mut runtime, "ble-dictation", NOW);
    let (file_key, file_nonce) = activate_realtime_file(&mut runtime, &session_key, 7401, NOW + 1);
    runtime.drain_companion_events();
    let mut slices = vec![(0, 1)];
    slices.extend((1..21).map(|n| (n, 0)));
    slices.push((21, 1));
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &slices),
        NOW + 2,
    );
    assert_eq!(runtime.workspace().records().len(), 1);
    let id = runtime.workspace().records().keys().next().unwrap().clone();
    assert!(!runtime.is_known_bean_record(7401));
    assert!(runtime.workspace().is_standby_scratch_file(7401));
    let effects: Vec<Value> = serde_json::from_str(&runtime.drain_local_asr_json()).unwrap();
    let op = effects.iter().find(|e| e["kind"] == "start").unwrap()["operationId"].clone();
    assert_eq!(
        effects
            .iter()
            .filter_map(|e| e["pcm16"].as_array())
            .map(Vec::len)
            .sum::<usize>(),
        320 * 6
    );
    assert!(effects.iter().any(|e| e["kind"] == "finish"));
    runtime.dispatch_json(&json!({"type":"local_asr_result","operationId":op,"text":"真正的听写文字","startMs":0,"endMs":120,"isFinal":true}).to_string(),NOW+2);
    runtime.dispatch_json(
        &json!({"type":"local_asr_finished","operationId":op}).to_string(),
        NOW + 2,
    );
    let events = runtime.drain_companion_events();
    assert_eq!(
        events
            .iter()
            .filter(|e| matches!(e, CompanionStreamEvent::AudioPcm16 { .. }))
            .count(),
        6
    );
    assert!(events.iter().any(|e|matches!(e,CompanionStreamEvent::TranscriptFinal{record_id,text,dictation:true,..} if record_id==&id&&text=="真正的听写文字")));
    assert_eq!(
        recording_assets::transcription_pcm(&sandbox.0, &id)
            .unwrap()
            .len(),
        120 * 32
    );
    assert_eq!(runtime.snapshot(NOW + 2)["dictation"]["active"], false);
}

#[test]
fn all_day_bean_double_tap_selects_dictation_with_default_companion_mode() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    runtime.dispatch_json(
        r#"{"type":"local_asr_readiness","state":"ready","message":"ready"}"#,
        NOW,
    );
    let session_key = connect_simulated_bean(&mut runtime, "ble-all-day-tap", NOW);
    let start: Value = serde_json::from_str(
        &runtime.dispatch_json(r#"{"type":"start_all_day","source":"bean"}"#, NOW),
    )
    .unwrap();
    assert!(start["error"].is_null(), "{start}");
    let (file_key, file_nonce) = activate_realtime_file(&mut runtime, &session_key, 7501, NOW + 1);
    runtime.drain_companion_events();
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &[(0, 0), (1, 1)]),
        NOW + 2,
    );
    assert_eq!(runtime.snapshot(NOW + 2)["dictation"]["active"], true);
    assert_eq!(
        runtime.workspace().companion_mode(),
        CompanionRoutingMode::Disabled
    );
    let effects: Vec<Value> = serde_json::from_str(&runtime.drain_local_asr_json()).unwrap();
    let first = effects.iter().find(|e| e["kind"] == "start").unwrap()["operationId"].clone();
    runtime.dispatch_json(
        &json!({"type":"local_asr_finished","operationId":first}).to_string(),
        NOW + 2,
    );
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &[(2, 0)]),
        NOW + 2,
    );
    let effects: Vec<Value> = serde_json::from_str(&runtime.drain_local_asr_json()).unwrap();
    let op = effects.iter().find(|e| e["kind"] == "start").unwrap()["operationId"].clone();
    runtime.dispatch_json(&json!({"type":"local_asr_result","operationId":op,"text":"全天中的听写","startMs":0,"endMs":20,"isFinal":true}).to_string(),NOW+2);
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &[(3, 1)]),
        NOW + 2,
    );
    assert_eq!(runtime.snapshot(NOW + 2)["dictation"]["active"], false);
    assert_eq!(runtime.workspace().records().len(), 1);
    let events = runtime.drain_companion_events();
    assert_eq!(
        events
            .iter()
            .filter(|e| matches!(e, CompanionStreamEvent::ControlEdge { down: true, .. }))
            .count(),
        2
    );
    assert!(events.iter().any(
        |e| matches!(e,CompanionStreamEvent::TranscriptFinal{text,..} if text=="全天中的听写")
    ));
    assert_eq!(runtime.snapshot(NOW + 2)["allDay"]["state"], "recording");
    runtime.set_dictation_active(true);
    assert!(!runtime.companion.capture_active);
    runtime.ingest_ble_chunk(
        &build_encrypted_slices_rx(&file_key, &file_nonce, &[(4, 1)]),
        NOW + 2,
    );
    assert_eq!(
        runtime.snapshot(NOW + 2)["dictation"]["active"],
        false,
        "a UI selection must close on the next physical tap even while the PCM gate is already closed"
    );
}

#[test]
fn standby_dictation_reopens_the_checkpoint_without_claiming_device_custody() {
    let sandbox = Sandbox::new();
    let id = "standby-dictation-checkpoint";
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    runtime
        .commit(|w| {
            w.insert_record(
                id.into(),
                "录音豆语音输入".into(),
                RecordOrigin::Bean,
                0,
                NOW,
                0,
            )
        })
        .unwrap();
    let mut asset =
        koe_client_services::capture_asset::CaptureAsset::create(&sandbox.0, id, 16_000).unwrap();
    asset.append(&[42; 320]).unwrap();
    drop(asset);
    drop(runtime);

    let runtime = KoeRuntime::open(&sandbox.0).unwrap();
    assert_eq!(
        runtime
            .workspace()
            .record(id)
            .unwrap()
            .aggregate
            .duration_ms,
        20
    );
    assert_eq!(
        recording_assets::transcription_pcm(&sandbox.0, id)
            .unwrap()
            .len(),
        640
    );
    assert!(!sandbox
        .0
        .join("audio")
        .join(format!("{id}.capture"))
        .exists());
    assert!(!runtime.is_known_bean_record(0));
    assert!(!runtime.is_device_file_synced(0));
}

#[test]
fn quitting_retries_a_standby_dictation_save_without_losing_audio() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    runtime.companion.standby_stream_owned = true;
    runtime.set_dictation_active(true);
    runtime.capture_standby_dictation(&[42; 320]);
    let id = runtime.workspace().records().keys().next().unwrap().clone();
    let product = sandbox.0.join("product-workspace.json");
    let saved = sandbox.0.join("previous.json");
    fs::rename(&product, &saved).unwrap();
    fs::create_dir(&product).unwrap();

    runtime.dispatch_json(r#"{"type":"request_quit"}"#, NOW);
    assert_eq!(runtime.snapshot(NOW)["lifecycle"]["quitPhase"], "blocked");
    assert_eq!(runtime.snapshot(NOW)["dictation"]["active"], false);
    assert!(sandbox
        .0
        .join("audio")
        .join(format!("{id}.capture"))
        .is_file());

    fs::remove_dir(&product).unwrap();
    fs::rename(&saved, &product).unwrap();
    runtime.poll_timers(0, NOW);
    assert_eq!(runtime.snapshot(NOW)["lifecycle"]["quitPhase"], "ready");
    assert_eq!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .duration_ms,
        20
    );
    assert_eq!(
        recording_assets::transcription_pcm(&sandbox.0, &id)
            .unwrap()
            .len(),
        640
    );
}

#[test]
fn microphone_dictation_does_not_capture_or_stop_with_standby_bean() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    runtime.dispatch_json(r#"{"type":"set_companion_mode","mode":"collar_standby"}"#, NOW);
    let session_key = connect_simulated_bean(&mut runtime, "ble-separate-dictation", NOW);
    let (file_key, nonce) = activate_realtime_file(&mut runtime, &session_key, 7601, NOW + 1);
    runtime.drain_companion_events();
    let started: Value = serde_json::from_str(&runtime.dispatch_json(r#"{"type":"start_capture_mode","mode":"dictation"}"#, NOW + 2)).unwrap();
    assert!(started["microphone"]["sessionId"].is_string());
    runtime.ingest_ble_chunk(&build_encrypted_slices_rx(&file_key, &nonce, &(0..21).map(|n| (n, 0)).collect::<Vec<_>>()), NOW + 3);
    assert!(runtime.workspace().records().is_empty());
    assert!(!runtime.drain_companion_events().iter().any(|e| matches!(e, CompanionStreamEvent::AudioPcm16 { .. })));
    let disconnected: Value = serde_json::from_str(&runtime.dispatch_json(r#"{"type":"device_disconnect"}"#, NOW + 4)).unwrap();
    assert_eq!(disconnected["dictation"]["active"], true);
    assert_eq!(disconnected["activeCapture"]["mode"], "dictation");
}
