use super::*;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        Self(std::env::temp_dir().join(format!(
            "koe-navigation-{}-{}",
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
fn command(runtime: &mut KoeRuntime, command: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&command.to_string(), 1800000000)).unwrap()
}

#[test]
fn pending_recording_start_blocks_conflicting_commands_and_times_out() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime.device.session.session_key = Some([1; 32]);
    let first = command(&mut runtime, json!({"type":"device_start"}));
    assert!(first["error"].is_null());
    assert_eq!(first["device"]["busy"], true);
    assert!(command(&mut runtime, json!({"type":"device_start"}))["error"].is_string());
    assert!(
        command(&mut runtime, json!({"type":"device_download","fileId":7}))["error"].is_string()
    );
    runtime.poll_timers(15_000, 1800000015);
    assert_eq!(runtime.snapshot(1800000015)["device"]["busy"], true);
    assert_eq!(runtime.snapshot(1800000015)["device"]["stopping"], true);
    assert!(runtime.snapshot(1800000015)["error"]
        .as_str()
        .unwrap()
        .contains("未确认"));
    let mut stopped = vec![0x09, 0xff, 0, 0, 1, 0x18, 0x82, 11, 0, 0];
    stopped.push(koe_engine::frame::ProtocolFrame::checksum(&stopped));
    runtime.ingest_ble_chunk(&stopped, 1800000015);
    assert_eq!(runtime.snapshot(1800000015)["device"]["busy"], false);
    assert_eq!(runtime.snapshot(1800000015)["device"]["stopping"], false);
}

#[test]
fn back_and_background_playback_keep_navigation_and_errors_consistent() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let mut ids = Vec::new();
    for title in ["First", "Second"] {
        let record = command(
            &mut runtime,
            json!({"type":"create_note","title":title,"text":title}),
        );
        let id = record["selectedRecordId"].as_str().unwrap().to_string();
        let mut audio = koe_engine::wav::OpusWave::wav_header_with_rate(3200, 16000).to_vec();
        audio.extend(vec![0; 3200]);
        recording_assets::save_audio(&dir.0, &id, &audio).unwrap();
        assert!(
            command(&mut runtime, json!({"type":"playback","isPlaying":true}))["error"].is_null()
        );
        ids.push(id);
    }
    let back = command(&mut runtime, json!({"type":"back"}));
    assert_eq!(back["detail"]["id"], ids[0]);
    assert_eq!(back["playback"]["recordId"], ids[0]);
    assert_eq!(back["playback"]["isPlaying"], false);
    let failed = command(&mut runtime, json!({"type":"summarize","recordId":ids[0]}));
    assert!(failed["error"].is_string());
    let tick = command(
        &mut runtime,
        json!({"type":"playback_progress","positionMs":40,"isPlaying":true}),
    );
    assert_eq!(tick["error"], failed["error"]);
}

#[test]
fn analysis_queue_retains_storage_failure_but_consumes_permanent_rejection() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let note = command(
        &mut runtime,
        json!({"type":"create_note","title":"Queue","text":"Keep the original source."}),
    );
    let id = note["selectedRecordId"].as_str().unwrap().to_string();
    runtime.settings.key = "local-test".into();
    let mut configuration = runtime.workspace().provider_configuration().clone();
    configuration.chat_endpoint = "http://remote.invalid/chat".into();
    runtime
        .commit(|w| w.configure_provider(configuration))
        .unwrap();
    runtime.auto_summarize.insert(id.clone());
    let path = dir.0.join("product-workspace.json");
    let saved = dir.0.join("saved.json");
    std::fs::rename(&path, &saved).unwrap();
    std::fs::create_dir(&path).unwrap();
    runtime.poll_timers(250, 1800000000);
    assert!(runtime.auto_summarize.contains(&id));
    std::fs::remove_dir(&path).unwrap();
    std::fs::rename(&saved, &path).unwrap();
    runtime.poll_timers(250, 1800000000);
    runtime.poll_timers(250, 1800000000);
    assert!(runtime.auto_summarize.is_empty());
    assert!(runtime.pending.is_empty());
    assert!(matches!(
        runtime.workspace().record(&id).unwrap().analysis,
        AnalysisState::Failed { .. }
    ));
    let revision = runtime.workspace().revision();
    runtime.poll_timers(250, 1800000000);
    assert_eq!(revision, runtime.workspace().revision());
}

fn rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = koe_engine::frame::RX_MAGIC.to_vec();
    frame.extend_from_slice(&[1, cmd_type, cmd_id]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(koe_engine::frame::ProtocolFrame::checksum(&frame));
    frame
}

#[test]
fn connect_guide_transitions_to_onboarding_when_both_ecdh_and_telemetry_complete() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let opened = command(&mut runtime, json!({"type": "device_open_guide"}));
    assert_eq!(opened["device"]["guide"]["mode"], "connect_guide");
    assert_eq!(opened["device"]["phase"], "disconnected");

    let scanning = command(
        &mut runtime,
        json!({"type": "device_event", "event": "scanning", "connectionId": "c1"}),
    );
    assert_eq!(scanning["device"]["phase"], "scanning");
    assert_eq!(scanning["device"]["state"], "正在查找录音豆");

    let connecting = command(
        &mut runtime,
        json!({"type": "device_event", "event": "connecting", "connectionId": "c1", "deviceName": "soundcore Work (CC:A3)"}),
    );
    assert_eq!(connecting["device"]["phase"], "connecting");
    assert_eq!(connecting["device"]["deviceName"], "soundcore Work (CC:A3)");

    let ready = command(
        &mut runtime,
        json!({"type": "device_event", "event": "ready", "connectionId": "c1"}),
    );
    assert_eq!(ready["device"]["phase"], "handshaking");
    assert_eq!(ready["device"]["connected"], false);
    assert_eq!(runtime.drain_outbound_ble_frames().len(), 2);

    let mut payload = vec![0u8; 40];
    payload[0] = 1;
    payload[1] = 8;
    payload[2] = 1;
    payload[3..8].copy_from_slice(b"4.92.");
    payload[8..24].copy_from_slice(b"007f1d04cca30000");
    payload[24..28].copy_from_slice(&65536u32.to_le_bytes());
    payload[28..32].copy_from_slice(&32768u32.to_le_bytes());
    payload[32] = 0;
    payload[33..38].copy_from_slice(b"1.0.0");
    payload[38] = 9;
    let telemetry_frame = rx_frame(0x01, 0x01, &payload);
    runtime.ingest_ble_chunk(&telemetry_frame, 1800000001);

    let after_telemetry = runtime.snapshot(1800000001);
    assert_eq!(
        after_telemetry["device"]["phase"], "handshaking",
        "01/01 telemetry before 2E/01 ECDH must remain in handshaking"
    );
    assert_eq!(after_telemetry["device"]["connected"], false);
    assert_eq!(after_telemetry["device"]["batteryPercent"], 90);
    assert_eq!(after_telemetry["device"]["boxBatteryPercent"], 100);
    assert_eq!(after_telemetry["device"]["guide"]["mode"], "connect_guide");

    let priv_key = runtime.device.session.ecdh_private_key.unwrap();
    let pub_key = koe_engine::crypto::DeviceCrypto::p256_public_key(&priv_key).unwrap();
    let shared =
        koe_engine::crypto::DeviceCrypto::p256_ecdh_shared_secret(&priv_key, &pub_key).unwrap();
    let mut ecdh_payload = Vec::with_capacity(97);
    ecdh_payload.extend_from_slice(&pub_key);
    ecdh_payload.extend_from_slice(&shared);
    let ecdh_frame = rx_frame(0x2E, 0x01, &ecdh_payload);
    runtime.ingest_ble_chunk(&ecdh_frame, 1800000002);

    let connected = runtime.snapshot(1800000002);
    assert_eq!(connected["device"]["phase"], "connected");
    assert_eq!(connected["device"]["connected"], true);
    assert_eq!(connected["device"]["guide"]["mode"], "onboarding");
    assert_eq!(connected["device"]["guide"]["step"], 0);
    assert_eq!(connected["device"]["guide"]["title"], "连接成功");

    for expected_step in 1..=4 {
        let next = command(&mut runtime, json!({"type": "device_onboarding_next"}));
        assert_eq!(next["device"]["guide"]["mode"], "onboarding");
        assert_eq!(next["device"]["guide"]["step"], expected_step);
    }
    let finished = command(&mut runtime, json!({"type": "device_onboarding_next"}));
    assert!(finished["device"]["guide"].is_null());
}

#[test]
fn scanning_resets_stale_connecting_and_handshake_watchdog_retries() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    command(
        &mut runtime,
        json!({"type": "device_event", "event": "connecting", "connectionId": "stale-conn"}),
    );
    assert_eq!(
        runtime.snapshot(1800000000)["device"]["phase"],
        "connecting"
    );

    let rescan = command(
        &mut runtime,
        json!({"type": "device_event", "event": "scanning", "connectionId": "new-scan"}),
    );
    assert_eq!(rescan["device"]["phase"], "scanning");

    command(
        &mut runtime,
        json!({"type": "device_event", "event": "connecting", "connectionId": "fresh-conn"}),
    );
    command(
        &mut runtime,
        json!({"type": "device_event", "event": "ready", "connectionId": "fresh-conn"}),
    );
    let _ = runtime.drain_outbound_ble_frames();

    runtime.poll_timers(2_500, 1800000003);
    let retry_frames = runtime.drain_outbound_ble_frames();
    assert!(
        !retry_frames.is_empty(),
        "expected handshake watchdog to re-queue outbound handshake frames"
    );
}
