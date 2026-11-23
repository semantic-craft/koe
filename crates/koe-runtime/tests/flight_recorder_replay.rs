#![allow(clippy::unwrap_used, clippy::expect_used)]

use koe_engine::{
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    frame::{ProtocolFrame, RX_MAGIC},
    session::REAL_OPUS_20MS_440HZ_PACKET,
    transport::OPUS_FRAME_BYTES,
};
use koe_runtime::{
    credentials::{CredentialStore, IsolatedCredentials},
    DiagnosticsBundle, KoeRuntime, MicrophonePcmChunk, PcmIngestStatus, RuntimeEnv,
    MAX_FLIGHT_RECORDER_ENTRIES,
};
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

struct TempWorkspace(PathBuf);

impl TempWorkspace {
    fn new(prefix: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-replay-{prefix}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempWorkspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn dispatch(runtime: &mut KoeRuntime, cmd: Value, now: u64) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&cmd.to_string(), now)).unwrap()
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
    pkt.extend_from_slice(b"D3200REPLAY00001");
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

fn connect_deterministic_bean(runtime: &mut KoeRuntime, connection_id: &str, now: u64) -> [u8; 32] {
    let connecting = dispatch(
        runtime,
        json!({
            "type": "device_event",
            "event": "connecting",
            "connectionId": connection_id,
            "deviceName": "Soundcore Work"
        }),
        now,
    );
    assert!(connecting["error"].is_null(), "{connecting}");

    let ready = dispatch(
        runtime,
        json!({
            "type": "device_event",
            "event": "ready",
            "connectionId": connection_id,
            "deviceName": "Soundcore Work"
        }),
        now,
    );
    assert!(ready["error"].is_null(), "{ready}");

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
    runtime.ingest_ble_chunk(&build_rx_frame(0x1B, 0x0E, &[0, 0]), now);
    session_key
}

fn build_file_head_rx(
    session_key: &[u8; 32],
    file_id: u32,
    file_size: u32,
    file_key: &[u8; 32],
    file_nonce: &[u8; 16],
) -> Vec<u8> {
    let mut key_material = b"soundcored3200".to_vec();
    key_material.extend_from_slice(file_key);
    let session_nonce = [0x33u8; 16];
    let wrapped_key =
        DeviceCrypto::aes_ctr_decrypt(&key_material, session_key, &session_nonce).unwrap();
    let mut payload = file_id.to_le_bytes().to_vec();
    payload.extend_from_slice(&file_size.to_le_bytes());
    payload.extend_from_slice(file_nonce);
    payload.extend_from_slice(&wrapped_key);
    payload.extend_from_slice(&session_nonce);
    payload.push(0);
    build_rx_frame(0x1A, 0x07, &payload)
}

fn build_encrypted_audio_rx(
    sequence: u32,
    file_key: &[u8; 32],
    file_nonce: &[u8; 16],
) -> Vec<u8> {
    let mut payload = sequence.to_le_bytes().to_vec();
    payload.push(0);
    let mut opus = [0u8; OPUS_FRAME_BYTES];
    opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
    AesCtrStreamDecrypt::new(file_key, file_nonce)
        .unwrap()
        .decrypt_contiguous_in_place(&mut opus, sequence);
    payload.extend_from_slice(&opus);
    payload.push(0);
    build_rx_frame(0x1A, 0x08, &payload)
}

#[test]
fn runtime_env_eliminates_ambient_nondeterminism_for_nonces_ecdh_credentials_and_timezone() {
    let seed = 0xDEAD_BEEF_CAFE_BABEu64;
    let now = 1_767_225_600u64; // 2026-01-01 00:00:00 UTC

    let ws_a = TempWorkspace::new("det-a");
    let ws_b = TempWorkspace::new("det-b");
    let mut rt_a = KoeRuntime::open_with_env(
        &ws_a.0,
        Box::new(IsolatedCredentials::deterministic(seed)),
        RuntimeEnv::deterministic(now, seed, Some(8 * 3600)),
    )
    .unwrap();
    let mut rt_b = KoeRuntime::open_with_env(
        &ws_b.0,
        Box::new(IsolatedCredentials::deterministic(seed)),
        RuntimeEnv::deterministic(now, seed, Some(8 * 3600)),
    )
    .unwrap();

    let mic_a = dispatch(
        &mut rt_a,
        json!({"type": "start_microphone", "inputId": "built-in"}),
        now,
    );
    let mic_b = dispatch(
        &mut rt_b,
        json!({"type": "start_microphone", "inputId": "built-in"}),
        now,
    );
    assert_eq!(mic_a["microphone"]["recordId"], mic_b["microphone"]["recordId"]);
    assert_eq!(mic_a["microphone"]["sessionId"], mic_b["microphone"]["sessionId"]);

    let key_a = connect_deterministic_bean(&mut rt_a, "conn-1", now);
    let key_b = connect_deterministic_bean(&mut rt_b, "conn-1", now);
    assert_eq!(key_a, key_b, "seeded ECDH handshake must derive identical session key");

    let mut creds_a = IsolatedCredentials::deterministic(seed);
    let mut creds_b = IsolatedCredentials::deterministic(seed);
    assert_eq!(
        creds_a.prepare("secret").unwrap(),
        creds_b.prepare("secret").unwrap(),
        "deterministic IsolatedCredentials must generate identical references"
    );

    // 2026-01-01 00:30:00 UTC is 2026-01-01 in UTC+8 and 2025-12-31 in UTC-5.
    let rollover_epoch = 1_767_227_400u64;
    let ws_east = TempWorkspace::new("tz-east");
    let ws_west = TempWorkspace::new("tz-west");
    let rt_east = KoeRuntime::open_with_env(
        &ws_east.0,
        Box::new(IsolatedCredentials::deterministic(1)),
        RuntimeEnv::deterministic(rollover_epoch, 1, Some(8 * 3600)),
    )
    .unwrap();
    let rt_west = KoeRuntime::open_with_env(
        &ws_west.0,
        Box::new(IsolatedCredentials::deterministic(1)),
        RuntimeEnv::deterministic(rollover_epoch, 1, Some(-5 * 3600)),
    )
    .unwrap();
    let snap_east = rt_east.snapshot(rollover_epoch);
    let snap_west = rt_west.snapshot(rollover_epoch);
    assert_eq!(snap_east["workspaces"]["allDay"]["selectedDate"], "2026-01-01");
    assert_eq!(snap_west["workspaces"]["allDay"]["selectedDate"], "2025-12-31");
}

#[test]
fn flight_recorder_bounds_entries_at_2048_and_tracks_dropped_count() {
    let ws = TempWorkspace::new("bounded");
    let now = 1_800_000_000u64;
    let mut rt = KoeRuntime::open_with_env(
        &ws.0,
        Box::new(IsolatedCredentials::deterministic(7)),
        RuntimeEnv::deterministic(now, 7, Some(0)),
    )
    .unwrap();

    for i in 0..(MAX_FLIGHT_RECORDER_ENTRIES + 25) {
        let page = if i % 2 == 0 { "records" } else { "today" };
        let _ = dispatch(&mut rt, json!({"type": "navigate", "page": page}), now + i as u64);
    }

    let bundle = rt.export_diagnostics_bundle(now + 3000);
    assert_eq!(bundle.bundle_version, 1);
    assert_eq!(bundle.flight_recorder.entries.len(), MAX_FLIGHT_RECORDER_ENTRIES);
    assert_eq!(bundle.flight_recorder.dropped_count, 25);
    assert_eq!(
        bundle.doctor["runtimeState"]["flightRecorderEntries"].as_u64(),
        Some(MAX_FLIGHT_RECORDER_ENTRIES as u64)
    );
    assert_eq!(
        bundle.doctor["runtimeState"]["flightRecorderDropped"].as_u64(),
        Some(25)
    );
    assert!(bundle
        .flight_recorder
        .entries
        .windows(2)
        .all(|w| w[1].seq == w[0].seq + 1));
}

#[test]
fn replay_ble_dropped_stop_ack_reproduces_identical_runtime_and_device_state() {
    let seed = 0x1122_3344_5566_7788u64;
    let now = 1_800_050_000u64;
    let file_key = [0x42u8; 32];
    let file_nonce = [0x19u8; 16];

    let ws_live = TempWorkspace::new("ble-live");
    let mut runtime = KoeRuntime::open_with_env(
        &ws_live.0,
        Box::new(IsolatedCredentials::deterministic(seed)),
        RuntimeEnv::deterministic(now, seed, Some(8 * 3600)),
    )
    .unwrap();

    let session_key = connect_deterministic_bean(&mut runtime, "ble-drop-stop", now);
    let started = dispatch(&mut runtime, json!({"type": "device_start"}), now + 1);
    assert!(started["error"].is_null(), "{started}");
    let _ = runtime.drain_outbound_ble_frames();

    runtime.ingest_ble_chunk(
        &build_file_head_rx(&session_key, 901, 0, &file_key, &file_nonce),
        now + 2,
    );
    runtime.ingest_ble_chunk(&build_encrypted_audio_rx(0, &file_key, &file_nonce), now + 2);
    runtime.ingest_ble_chunk(&build_encrypted_audio_rx(1, &file_key, &file_nonce), now + 3);

    let stopping = dispatch(&mut runtime, json!({"type": "device_stop"}), now + 4);
    assert!(stopping["error"].is_null(), "{stopping}");
    assert_eq!(stopping["device"]["stopping"], true);

    // Stop ACK is dropped; advance timers and dispatch a retry stop.
    runtime.poll_timers(2_000, now + 6);
    let retry_stop = dispatch(&mut runtime, json!({"type": "device_stop"}), now + 7);
    assert!(retry_stop["error"].is_null(), "{retry_stop}");
    runtime.poll_timers(3_000, now + 10);

    let bundle_json = runtime.export_diagnostics_json(now + 10);
    let bundle: DiagnosticsBundle = serde_json::from_str(&bundle_json).unwrap();
    assert_eq!(bundle.doctor["runtimeState"]["devicePhase"], "connected");
    assert_eq!(bundle.doctor["runtimeState"]["deviceBusy"], true);
    assert_eq!(bundle.doctor["device"]["stopping"], true);

    let ws_replay = TempWorkspace::new("ble-replay");
    let report = KoeRuntime::replay_bundle(&ws_replay.0, &bundle).unwrap();
    assert_eq!(report.entries_replayed, bundle.flight_recorder.entries.len());
    assert_eq!(
        report.final_generation,
        bundle.doctor["generation"].as_u64().unwrap()
    );
    assert_eq!(report.doctor["runtimeState"], bundle.doctor["runtimeState"]);
    assert_eq!(report.doctor["device"], bundle.doctor["device"]);
    assert_eq!(report.snapshot_summary.device_phase, "connected");
    assert!(report.snapshot_summary.device_busy);
    assert!(report.snapshot_summary.device_stopping);
}

#[test]
fn replay_dual_lane_microphone_fault_and_pause_recovery_reproduces_identically_without_pcm_leaks() {
    let seed = 0xA1B2_C3D4_E5F6_0718u64;
    let now = 1_800_060_000u64;

    let ws_live = TempWorkspace::new("mic-live");
    let mut runtime = KoeRuntime::open_with_env(
        &ws_live.0,
        Box::new(IsolatedCredentials::deterministic(seed)),
        RuntimeEnv::deterministic(now, seed, Some(8 * 3600)),
    )
    .unwrap();

    let started = dispatch(
        &mut runtime,
        json!({
            "type": "start_microphone",
            "inputId": "studio-mic",
            "includeSystem": true,
            "clockNs": 1_000_000_000u64
        }),
        now,
    );
    let mic = started["microphone"].clone();
    let record_id = mic["recordId"].as_str().unwrap().to_owned();
    let session_id = mic["sessionId"].as_str().unwrap().to_owned();

    for lane in ["microphone", "system"] {
        let s = dispatch(
            &mut runtime,
            json!({
                "type": "microphone_started",
                "recordId": record_id,
                "sessionId": session_id,
                "lane": lane,
                "sampleRate": 16000
            }),
            now,
        );
        assert!(s["error"].is_null(), "{s}");
    }

    let distinctive_samples: Vec<i16> = (0..160).map(|i| 13_579 - i * 31).collect();
    for lane in ["microphone", "system"] {
        let ok = runtime.ingest_microphone_pcm(MicrophonePcmChunk {
            record_id: &record_id,
            session_id: &session_id,
            lane,
            sequence: 0,
            samples: &distinctive_samples,
            timing: Some((0, 1_000_000_000)),
            now,
        });
        assert_eq!(ok.status, PcmIngestStatus::Accepted);
    }

    // Inject out-of-order sequence gap fault on microphone lane, then recover cleanly.
    let gap = runtime.ingest_microphone_pcm(MicrophonePcmChunk {
        record_id: &record_id,
        session_id: &session_id,
        lane: "microphone",
        sequence: 5,
        samples: &distinctive_samples,
        timing: Some((0, 1_010_000_000)),
        now,
    });
    assert_eq!(gap.status, PcmIngestStatus::Rejected);

    assert!(dispatch(&mut runtime, json!({"type": "pause_microphone"}), now + 1)["error"].is_null());
    for lane in ["microphone", "system"] {
        let paused = dispatch(
            &mut runtime,
            json!({
                "type": "microphone_paused",
                "recordId": record_id,
                "sessionId": session_id,
                "lane": lane,
                "sequence": 1,
                "epoch": 0
            }),
            now + 1,
        );
        assert!(paused["error"].is_null(), "{paused}");
    }
    assert!(
        dispatch(
            &mut runtime,
            json!({"type": "resume_microphone", "clockNs": 2_000_000_000u64}),
            now + 2,
        )["error"]
            .is_null()
    );

    for lane in ["microphone", "system"] {
        let resumed = runtime.ingest_microphone_pcm(MicrophonePcmChunk {
            record_id: &record_id,
            session_id: &session_id,
            lane,
            sequence: 1,
            samples: &distinctive_samples,
            timing: Some((1, 2_000_000_000)),
            now: now + 2,
        });
        assert_eq!(resumed.status, PcmIngestStatus::Accepted);
    }

    assert!(dispatch(&mut runtime, json!({"type": "stop_microphone"}), now + 3)["error"].is_null());
    for lane in ["microphone", "system"] {
        let stopped = dispatch(
            &mut runtime,
            json!({
                "type": "microphone_stopped",
                "recordId": record_id,
                "sessionId": session_id,
                "lane": lane,
                "sequence": 2,
                "epoch": 1
            }),
            now + 3,
        );
        assert!(stopped["error"].is_null(), "{stopped}");
    }

    let bundle_json = runtime.export_diagnostics_json(now + 4);
    assert!(
        !bundle_json.contains("13579"),
        "raw PCM sample values must never appear in exported diagnostics bundle"
    );
    let bundle: DiagnosticsBundle = serde_json::from_str(&bundle_json).unwrap();

    let ws_replay = TempWorkspace::new("mic-replay");
    let report = KoeRuntime::replay_bundle(&ws_replay.0, &bundle).unwrap();
    assert_eq!(
        report.final_generation,
        bundle.doctor["generation"].as_u64().unwrap()
    );
    assert_eq!(report.doctor["runtimeState"], bundle.doctor["runtimeState"]);
    assert_eq!(report.snapshot_summary.record_count, 1);
    assert_eq!(report.doctor["runtimeState"]["activeCaptureTag"], "idle");
}

#[test]
fn replay_redacts_secrets_and_private_text_while_preserving_quit_blocker_lifecycle() {
    let seed = 0x55AA_66BB_77CC_88DDu64;
    let now = 1_800_070_000u64;

    let ws_live = TempWorkspace::new("secret-live");
    let mut runtime = KoeRuntime::open_with_env(
        &ws_live.0,
        Box::new(IsolatedCredentials::deterministic(seed)),
        RuntimeEnv::deterministic(now, seed, Some(8 * 3600)),
    )
    .unwrap();

    let cfg = dispatch(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": "sk-live-super-secret-99999",
            "deepseekApiKey": "Bearer top-secret-deepseek-token-777",
            "model": "deepseek-flash"
        }),
        now,
    );
    assert!(cfg["error"].is_null(), "{cfg}");

    let note = dispatch(
        &mut runtime,
        json!({
            "type": "create_note",
            "title": "绝密财报标题",
            "text": "高度机密财务数据"
        }),
        now + 1,
    );
    assert!(note["error"].is_null(), "{note}");

    let started = dispatch(
        &mut runtime,
        json!({"type": "start_microphone", "inputId": "built-in"}),
        now + 2,
    );
    assert!(started["error"].is_null(), "{started}");

    let quitting = dispatch(&mut runtime, json!({"type": "request_quit"}), now + 3);
    assert_eq!(quitting["lifecycle"]["quitPhase"], "draining");
    let doctor_quitting = runtime.doctor_snapshot(now + 3);
    assert_eq!(doctor_quitting["runtimeState"]["quitting"], true);
    assert!(
        !doctor_quitting["runtimeState"]["quitBlockers"]
            .as_array()
            .unwrap()
            .is_empty(),
        "active microphone session must surface in quitBlockers"
    );

    let cancelled = dispatch(&mut runtime, json!({"type": "cancel_quit"}), now + 4);
    assert_eq!(cancelled["lifecycle"]["quitPhase"], "running");

    let bundle_json = runtime.export_diagnostics_json(now + 4);
    for forbidden in [
        "sk-live-super-secret-99999",
        "top-secret-deepseek-token-777",
        "绝密财报标题",
        "高度机密财务数据",
    ] {
        assert!(
            !bundle_json.contains(forbidden),
            "sensitive string `{forbidden}` leaked into diagnostics bundle!"
        );
    }
    assert!(bundle_json.contains("[REDACTED]"));
    assert!(bundle_json.contains("[REDACTED_TEXT_"));

    let bundle: DiagnosticsBundle = serde_json::from_str(&bundle_json).unwrap();
    let ws_replay = TempWorkspace::new("secret-replay");
    let report = KoeRuntime::replay_bundle(&ws_replay.0, &bundle).unwrap();
    assert_eq!(
        report.final_generation,
        bundle.doctor["generation"].as_u64().unwrap()
    );
    assert_eq!(report.doctor["runtimeState"], bundle.doctor["runtimeState"]);
    assert_eq!(report.doctor["runtimeState"]["quitting"], false);
    assert_eq!(report.snapshot_summary.record_count, 1);
    assert!(!report.truncated);
    assert_eq!(report.dropped_count, 0);
    assert!(!report.non_deterministic_ble_crypto);
    assert!(report.warnings.is_empty());
}

#[test]
fn replay_bundle_rejects_untrusted_oversized_entries_pcm_ble_and_invalid_tz_offset() {
    let ws = TempWorkspace::new("untrusted-source");
    let now = 1_800_080_000u64;
    let runtime = KoeRuntime::open_with_env(
        &ws.0,
        Box::new(IsolatedCredentials::deterministic(1)),
        RuntimeEnv::deterministic(now, 1, Some(0)),
    )
    .unwrap();
    let base_bundle = runtime.export_diagnostics_bundle(now);

    let ws_replay = TempWorkspace::new("untrusted-replay");

    let mut huge_pcm = base_bundle.clone();
    huge_pcm.flight_recorder.entries.push(koe_runtime::FlightRecorderEntry {
        seq: 1,
        generation_after: 2,
        input: koe_runtime::RuntimeInput::IngestMicrophonePcm {
            record_id: "rec-1".into(),
            session_id: "sess-1".into(),
            lane: "microphone".into(),
            sequence: 0,
            sample_count: usize::MAX,
            timing: None,
            now,
        },
    });
    assert!(
        KoeRuntime::replay_bundle(&ws_replay.0, &huge_pcm).is_err(),
        "oversized sample_count must be rejected before allocation"
    );

    let mut huge_entries = base_bundle.clone();
    for seq in 1..=(MAX_FLIGHT_RECORDER_ENTRIES as u64 + 1) {
        huge_entries.flight_recorder.entries.push(koe_runtime::FlightRecorderEntry {
            seq,
            generation_after: seq + 1,
            input: koe_runtime::RuntimeInput::PollTimers { elapsed_ms: 10, now },
        });
    }
    assert!(
        KoeRuntime::replay_bundle(&ws_replay.0, &huge_entries).is_err(),
        "entries exceeding MAX_FLIGHT_RECORDER_ENTRIES must be rejected"
    );

    let mut huge_ble = base_bundle.clone();
    huge_ble.flight_recorder.entries.push(koe_runtime::FlightRecorderEntry {
        seq: 1,
        generation_after: 2,
        input: koe_runtime::RuntimeInput::IngestBleChunk {
            bytes_hex: "aa".repeat(1_048_577),
            now,
        },
    });
    assert!(
        KoeRuntime::replay_bundle(&ws_replay.0, &huge_ble).is_err(),
        "oversized BLE hex chunk must be rejected before decoding"
    );

    let mut bad_tz = base_bundle;
    bad_tz.env.tz_offset_secs = Some(90_000);
    assert!(
        KoeRuntime::replay_bundle(&ws_replay.0, &bad_tz).is_err(),
        "out-of-range timezone offset must be rejected"
    );
}

#[test]
fn export_diagnostics_redacts_speakers_paths_messages_and_url_credentials() {
    let ws = TempWorkspace::new("privacy-redaction");
    let now = 1_800_090_000u64;
    let mut rt = KoeRuntime::open_with_env(
        &ws.0,
        Box::new(IsolatedCredentials::deterministic(2)),
        RuntimeEnv::deterministic(now, 2, Some(0)),
    )
    .unwrap();

    let note = dispatch(
        &mut rt,
        json!({"type": "create_note", "title": "会议纪要", "text": "第一句话"}),
        now,
    );
    let rec_id = note["records"][0]["id"].as_str().unwrap().to_owned();
    let _ = dispatch(
        &mut rt,
        json!({
            "type": "set_segment_speaker",
            "recordId": rec_id,
            "segmentId": "S1",
            "speaker": "张总-董事会主席"
        }),
        now + 1,
    );
    let _ = dispatch(
        &mut rt,
        json!({
            "type": "rename_speaker",
            "recordId": rec_id,
            "fromSpeaker": "张总-董事会主席",
            "toSpeaker": "李明-财务总监"
        }),
        now + 2,
    );
    let _ = dispatch(
        &mut rt,
        json!({
            "type": "import_file",
            "path": "/Users/alice/Documents/SecretBoardDeck.wav"
        }),
        now + 3,
    );
    let _ = dispatch(
        &mut rt,
        json!({
            "type": "configure_provider",
            "asrEndpoint": "https://asruser:asrpass@example.com/v1/asr?key=topsecret_asr#frag",
            "chatEndpoint": "https://chatuser:chatpass@example.com/v1/chat?api_key=topsecret_chat",
            "model": "deepseek-flash"
        }),
        now + 4,
    );
    let _ = dispatch(
        &mut rt,
        json!({
            "type": "adapter_event",
            "event": {
                "type": "local_asr_failed",
                "sessionId": "s1",
                "recordId": rec_id,
                "message": "failed reading /Users/alice/private.wav with detail"
            }
        }),
        now + 5,
    );
    let _ = dispatch(
        &mut rt,
        json!({
            "type": "adapter_event",
            "event": {
                "type": "device_connected",
                "connectionId": "conn-p",
                "deviceName": "Alice Private Bean"
            }
        }),
        now + 6,
    );
    let _ = dispatch(
        &mut rt,
        json!({
            "type": "set_record_project",
            "recordId": rec_id,
            "project": "Project-Phoenix-Confidential"
        }),
        now + 7,
    );

    let exported = rt.export_diagnostics_json(now + 8);
    for forbidden in [
        "张总-董事会主席",
        "李明-财务总监",
        "SecretBoardDeck.wav",
        "/Users/alice",
        "asruser",
        "asrpass",
        "topsecret_asr",
        "chatuser",
        "chatpass",
        "topsecret_chat",
        "Alice Private Bean",
        "Project-Phoenix-Confidential",
        "private.wav",
    ] {
        assert!(
            !exported.contains(forbidden),
            "private or credential fragment `{forbidden}` leaked into diagnostics JSON"
        );
    }
    assert!(exported.contains("https://example.com/v1/asr"));
    assert!(exported.contains("https://example.com/v1/chat"));
}

#[test]
fn export_diagnostics_is_side_effect_free_skips_noop_polls_and_reports_replay_caveats() {
    let ws = TempWorkspace::new("side-effect-free");
    let now = 1_800_095_000u64;
    let mut rt = KoeRuntime::open_with_env(
        &ws.0,
        Box::new(IsolatedCredentials::deterministic(3)),
        RuntimeEnv::deterministic(now, 3, Some(0)),
    )
    .unwrap();

    let _ = dispatch(&mut rt, json!({"type": "navigate", "page": "records"}), now);
    let gen_before = rt.generation();

    for i in 1..=50 {
        rt.poll_timers(100, now + i);
        let receipt = rt.report_playback_progress("missing", 1, 0, false, now + i, now + i);
        assert!(!receipt.applied && !receipt.needs_full_snapshot);
    }

    let bundle1 = rt.export_diagnostics_bundle(now + 100);
    let bundle2 = rt.export_diagnostics_bundle(now + 101);
    assert_eq!(rt.generation(), gen_before);
    assert_eq!(bundle1.flight_recorder.entries.len(), 1);
    assert_eq!(bundle2.flight_recorder.entries.len(), 1);
    assert_eq!(bundle1.flight_recorder.dropped_count, 0);

    let mut caveats_bundle = bundle1;
    caveats_bundle.flight_recorder.dropped_count = 7;
    caveats_bundle.env.rng_seed = None;
    caveats_bundle.flight_recorder.entries.push(koe_runtime::FlightRecorderEntry {
        seq: 2,
        generation_after: gen_before,
        input: koe_runtime::RuntimeInput::IngestBleChunk {
            bytes_hex: "00112233".into(),
            now: now + 2,
        },
    });
    let ws_caveats = TempWorkspace::new("caveats-replay");
    let report = KoeRuntime::replay_bundle(&ws_caveats.0, &caveats_bundle).unwrap();
    assert!(report.truncated);
    assert_eq!(report.dropped_count, 7);
    assert!(report.non_deterministic_ble_crypto);
    assert!(report.warnings.len() >= 2);
}
