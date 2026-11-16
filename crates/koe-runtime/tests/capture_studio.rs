use koe_engine::{
    crypto::{AesCtrStreamDecrypt, DeviceCrypto},
    frame::ProtocolFrame,
    session::REAL_OPUS_20MS_440HZ_PACKET,
    transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES},
};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

const NOW: u64 = 1_800_000_000;

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "koe-capture-studio-{}-{}",
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

fn dispatch(runtime: &mut KoeRuntime, payload: Value, now: u64) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&payload.to_string(), now)).unwrap()
}

fn dispatch_ok(runtime: &mut KoeRuntime, payload: Value, now: u64) -> Value {
    let snap = dispatch(runtime, payload, now);
    assert!(
        snap["error"].is_null(),
        "unexpected error: {}",
        snap["error"]
    );
    snap
}

fn rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = koe_engine::frame::RX_MAGIC.to_vec();
    frame.extend_from_slice(&[1, cmd_type, cmd_id]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(ProtocolFrame::checksum(&frame));
    frame
}

fn catalog_1b0e_rx(file_id: u32, duration_ms: u32, end_time: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(14);
    payload.extend_from_slice(&1u16.to_le_bytes());
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&duration_ms.to_le_bytes());
    payload.extend_from_slice(&end_time.to_le_bytes());
    rx_frame(0x1b, 0x0e, &payload)
}

fn connect_bean(runtime: &mut KoeRuntime, connection_id: &str, name: &str, now: u64) {
    let _ = connect_bean_with_session_key(runtime, connection_id, name, now);
}

fn connect_bean_with_session_key(
    runtime: &mut KoeRuntime,
    connection_id: &str,
    name: &str,
    now: u64,
) -> [u8; 32] {
    dispatch_ok(
        runtime,
        json!({
            "type": "device_event",
            "event": "connecting",
            "connectionId": connection_id,
            "deviceName": name,
        }),
        now,
    );
    dispatch_ok(
        runtime,
        json!({
            "type": "device_event",
            "event": "ready",
            "connectionId": connection_id,
        }),
        now,
    );
    let outbound = runtime.drain_outbound_ble_frames();
    let ecdh_tx = outbound
        .iter()
        .find(|f| f.len() >= 75 && f[5] == 0x2e && f[6] == 0x01)
        .expect("ready event must emit 2E/01 ECDH public key");
    let host_pub = &ecdh_tx[9..74];
    let bean_priv = [0x42u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, host_pub).unwrap();

    let mut telemetry = vec![0u8; 40];
    telemetry[0] = 1;
    telemetry[1] = 8;
    telemetry[2] = 1;
    telemetry[3..8].copy_from_slice(b"4.92.");
    telemetry[8..24].copy_from_slice(b"007f1d04cca30000");
    telemetry[24..28].copy_from_slice(&65536u32.to_le_bytes());
    telemetry[28..32].copy_from_slice(&32768u32.to_le_bytes());
    telemetry[33..38].copy_from_slice(b"1.0.0");
    telemetry[38] = 9;
    runtime.ingest_ble_chunk(&rx_frame(0x01, 0x01, &telemetry), now);

    let mut ecdh_reply = Vec::with_capacity(97);
    ecdh_reply.extend_from_slice(&bean_pub);
    ecdh_reply.extend_from_slice(&shared);
    runtime.ingest_ble_chunk(&rx_frame(0x2e, 0x01, &ecdh_reply), now);
    runtime.drain_outbound_ble_frames();
    assert_eq!(runtime.snapshot(now)["device"]["connected"], true);

    let derived = DeviceCrypto::hkdf_sha256(&shared, &[1, 2, 3], &[1, 2, 3], 32);
    let mut session_key = [0u8; 32];
    session_key.copy_from_slice(&derived);
    session_key
}

fn complete_offline_pull(
    runtime: &mut KoeRuntime,
    session_key: &[u8; 32],
    file_id: u32,
    now: u64,
) {
    let file_key = [0x55u8; 32];
    let file_nonce = [0x66u8; 16];
    let session_nonce = [0x33u8; 16];
    let mut plain_key_mat = Vec::with_capacity(44);
    plain_key_mat.extend_from_slice(b"soundcored3200");
    plain_key_mat.extend_from_slice(&file_key);
    let enc_file_key =
        DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, session_key, &session_nonce).unwrap();

    let mut head_payload = Vec::with_capacity(87);
    head_payload.extend_from_slice(&file_id.to_le_bytes());
    head_payload.extend_from_slice(&(SLICE_RECORD_BYTES as u32).to_le_bytes());
    head_payload.extend_from_slice(&file_nonce);
    head_payload.extend_from_slice(&enc_file_key);
    head_payload.extend_from_slice(&session_nonce);
    head_payload.push(0);
    runtime.ingest_ble_chunk(&rx_frame(0x1a, 0x07, &head_payload), now);

    let dec = AesCtrStreamDecrypt::new(&file_key, &file_nonce).unwrap();
    let mut slice_payload = Vec::with_capacity(SLICE_RECORD_BYTES);
    slice_payload.extend_from_slice(&0u32.to_le_bytes());
    slice_payload.push(0x00);
    let mut opus = [0u8; OPUS_FRAME_BYTES];
    opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
    dec.decrypt_contiguous_in_place(&mut opus, 0);
    slice_payload.extend_from_slice(&opus);
    slice_payload.push(0);
    runtime.ingest_ble_chunk(&rx_frame(0x1a, 0x08, &slice_payload), now);
    runtime.ingest_ble_chunk(&rx_frame(0x1a, 0x0a, &[]), now);
    runtime.drain_outbound_ble_frames();
}

#[test]
fn capture_page_navigation_auto_priority_and_unplug_fallback() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let initial = runtime.snapshot(NOW);
    assert_eq!(initial["section"], "today");
    assert_eq!(initial["capture"]["selectedSource"], "system_default");
    assert_eq!(initial["capture"]["selectedBadge"], "系统默认");
    assert_eq!(initial["capture"]["selectionMode"], "auto");
    assert_eq!(initial["capture"]["canStart"], true);

    let at_capture = dispatch_ok(
        &mut runtime,
        json!({"type": "navigate", "section": "capture"}),
        NOW,
    );
    assert_eq!(at_capture["section"], "capture");
    assert_eq!(at_capture["canGoBack"], true);

    let back = dispatch_ok(&mut runtime, json!({"type": "back"}), NOW);
    assert_eq!(back["section"], "today");

    let with_builtin = dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "usb-rode", "name": "Rode NT-USB", "transport": "usb", "isDefault": false},
                {"id": "macbook-mic", "name": "MacBook Pro 麦克风", "transport": "built_in", "isDefault": true}
            ]
        }),
        NOW,
    );
    assert_eq!(
        with_builtin["capture"]["selectedSource"],
        "input:macbook-mic"
    );
    assert_eq!(with_builtin["capture"]["selectedInputId"], "macbook-mic");
    assert_eq!(with_builtin["capture"]["selectedBadge"], "本机内置");
    assert_eq!(with_builtin["capture"]["selectionMode"], "auto");

    let with_bt = dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "macbook-mic", "name": "MacBook Pro 麦克风", "transport": "built_in", "isDefault": true},
                {"id": "usb-rode", "name": "Rode NT-USB", "transport": "usb", "isDefault": false},
                {"id": "airpods-pro", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": false}
            ]
        }),
        NOW + 1,
    );
    assert_eq!(with_bt["capture"]["inputs"][0]["id"], "airpods-pro");
    assert_eq!(with_bt["capture"]["inputs"][0]["badge"], "Mac 蓝牙");
    assert_eq!(with_bt["capture"]["selectedSource"], "input:airpods-pro");
    assert_eq!(with_bt["capture"]["selectedInputId"], "airpods-pro");
    assert_eq!(with_bt["capture"]["selectedLabel"], "AirPods Pro");
    assert_eq!(with_bt["capture"]["selectedBadge"], "Mac 蓝牙");

    connect_bean(&mut runtime, "c1", "soundcore Work (CC:A3)", NOW + 2);
    let with_bean = runtime.snapshot(NOW + 2);
    assert_eq!(with_bean["capture"]["selectedSource"], "bean");
    assert_eq!(with_bean["capture"]["selectedInputId"], "");
    assert_eq!(
        with_bean["capture"]["selectedLabel"],
        "soundcore Work (CC:A3)"
    );
    assert_eq!(with_bean["capture"]["selectedBadge"], "录音豆");
    assert_eq!(with_bean["capture"]["canStart"], true);

    let manual_usb = dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "input:usb-rode"}),
        NOW + 3,
    );
    assert_eq!(manual_usb["capture"]["selectedSource"], "input:usb-rode");
    assert_eq!(manual_usb["capture"]["selectedInputId"], "usb-rode");
    assert_eq!(manual_usb["capture"]["selectedBadge"], "USB 外接");
    assert_eq!(manual_usb["capture"]["selectionMode"], "manual");

    dispatch_ok(&mut runtime, json!({"type": "device_disconnect"}), NOW + 4);
    let unplugged = dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "macbook-mic", "name": "MacBook Pro 麦克风", "transport": "built_in", "isDefault": true},
                {"id": "airpods-pro", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": false}
            ]
        }),
        NOW + 4,
    );
    assert_eq!(unplugged["capture"]["selectedSource"], "input:airpods-pro");
    assert_eq!(unplugged["capture"]["selectionMode"], "auto");

    let missing_err = dispatch(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "input:ghost-mic"}),
        NOW + 5,
    );
    assert!(missing_err["error"]
        .as_str()
        .unwrap()
        .contains("所选输入设备已不可用"));

    let manual_bean_disconnected = dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "bean"}),
        NOW + 6,
    );
    assert_eq!(
        manual_bean_disconnected["capture"]["selectedSource"],
        "bean"
    );
    assert_eq!(
        manual_bean_disconnected["capture"]["selectionMode"],
        "manual"
    );
    assert_eq!(manual_bean_disconnected["capture"]["canStart"], false);
}

#[test]
fn mutual_exclusion_source_lock_and_microphone_rms_level_reset() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "airpods-pro", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": true}
            ]
        }),
        NOW,
    );
    connect_bean(&mut runtime, "c1", "Soundcore Work", NOW);

    let bean_started = dispatch_ok(&mut runtime, json!({"type": "device_start"}), NOW + 1);
    assert_eq!(bean_started["capture"]["activeSource"], "bean");
    assert_eq!(bean_started["capture"]["selectionMode"], "active");
    assert_eq!(bean_started["capture"]["canStart"], false);

    let switch_during_bean = dispatch(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "input:airpods-pro"}),
        NOW + 1,
    );
    assert_eq!(
        switch_during_bean["error"],
        "正在录音中，请先停止当前录音再切换音源"
    );

    let mic_during_bean = dispatch(
        &mut runtime,
        json!({"type": "start_microphone", "inputId": "airpods-pro"}),
        NOW + 1,
    );
    assert_eq!(
        mic_during_bean["error"],
        "录音豆正在录音中，请先结束当前录音"
    );

    dispatch_ok(&mut runtime, json!({"type": "device_stop"}), NOW + 2);
    let mut stopped_rx = vec![0x09, 0xff, 0, 0, 1, 0x18, 0x82, 11, 0, 0];
    stopped_rx.push(ProtocolFrame::checksum(&stopped_rx));
    runtime.ingest_ble_chunk(&stopped_rx, NOW + 2);
    assert!(runtime.snapshot(NOW + 2)["capture"]["activeSource"].is_null());

    let mic_started = dispatch_ok(
        &mut runtime,
        json!({
            "type": "start_microphone",
            "inputId": "airpods-pro",
            "clockNs": 1_000_000_000u64,
        }),
        NOW + 3,
    );
    assert_eq!(mic_started["capture"]["activeSource"], "input:airpods-pro");
    assert_eq!(
        mic_started["capture"]["selectedSource"],
        "input:airpods-pro"
    );
    assert_eq!(mic_started["capture"]["selectionMode"], "active");
    assert_eq!(mic_started["capture"]["canStart"], false);
    assert_eq!(mic_started["microphone"]["level"], 0.0);

    let bean_during_mic = dispatch(&mut runtime, json!({"type": "device_start"}), NOW + 3);
    assert_eq!(bean_during_mic["error"], "请先结束当前麦克风录音并完成保存");

    let switch_during_mic = dispatch(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "bean"}),
        NOW + 3,
    );
    assert_eq!(
        switch_during_mic["error"],
        "正在录音中，请先停止当前录音再切换音源"
    );

    let rec_id = mic_started["microphone"]["recordId"]
        .as_str()
        .unwrap()
        .to_string();
    let sess_id = mic_started["microphone"]["sessionId"]
        .as_str()
        .unwrap()
        .to_string();
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_started",
            "recordId": rec_id,
            "sessionId": sess_id,
            "lane": "microphone",
            "sampleRate": 16000,
        }),
        NOW + 3,
    );

    let after_speech = dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_chunk",
            "recordId": rec_id,
            "sessionId": sess_id,
            "lane": "microphone",
            "sequence": 0,
            "samples": vec![4096i16; 320],
            "timing": {"epoch": 0, "capturedStartNs": 1_000_000_000u64},
        }),
        NOW + 3,
    );
    let level = after_speech["microphone"]["level"].as_f64().unwrap();
    assert!(
        (0.49..=0.51).contains(&level),
        "expected ~0.50 level, got {level}"
    );

    let pausing = dispatch_ok(&mut runtime, json!({"type": "pause_microphone"}), NOW + 4);
    assert_eq!(pausing["microphone"]["level"], 0.0);
    let paused = dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_paused",
            "recordId": rec_id,
            "sessionId": sess_id,
            "lane": "microphone",
            "sequence": 1,
            "epoch": 0,
        }),
        NOW + 4,
    );
    assert_eq!(paused["microphone"]["phase"], "paused");
    assert_eq!(paused["microphone"]["level"], 0.0);

    dispatch_ok(
        &mut runtime,
        json!({"type": "resume_microphone", "clockNs": 2_000_000_000u64}),
        NOW + 5,
    );
    let resumed_chunk = dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_chunk",
            "recordId": rec_id,
            "sessionId": sess_id,
            "lane": "microphone",
            "sequence": 1,
            "samples": vec![8192i16; 320],
            "timing": {"epoch": 1, "capturedStartNs": 2_000_000_000u64},
        }),
        NOW + 5,
    );
    assert!((resumed_chunk["microphone"]["level"].as_f64().unwrap() - 1.0).abs() < 1e-6);

    let stopping = dispatch_ok(&mut runtime, json!({"type": "stop_microphone"}), NOW + 6);
    assert_eq!(stopping["microphone"]["level"], 0.0);
    let finished = dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_stopped",
            "recordId": rec_id,
            "sessionId": sess_id,
            "lane": "microphone",
            "sequence": 2,
            "epoch": 1,
        }),
        NOW + 6,
    );
    assert!(finished["microphone"].is_null());
}

#[test]
fn edge_cases_quiet_drain_hardware_coexistence_auto_skip_and_unplug_reset() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "usb-rode", "name": "Rode NT-USB", "transport": "usb", "isDefault": false},
                {"id": "airpods", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": true}
            ]
        }),
        NOW,
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "input:usb-rode"}),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "airpods", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": true}
            ]
        }),
        NOW + 1,
    );
    let replugged = dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "usb-rode", "name": "Rode NT-USB", "transport": "usb", "isDefault": false},
                {"id": "airpods", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": true}
            ]
        }),
        NOW + 2,
    );
    assert_eq!(replugged["capture"]["selectedSource"], "input:airpods");
    assert_eq!(replugged["capture"]["selectionMode"], "auto");

    connect_bean(&mut runtime, "c1", "Soundcore Work", NOW + 3);
    assert_eq!(
        runtime.snapshot(NOW + 3)["capture"]["selectedSource"],
        "bean"
    );

    let dir_pull = Sandbox::new();
    let mut pull_rt = KoeRuntime::open(&dir_pull.0).unwrap();
    dispatch_ok(
        &mut pull_rt,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "airpods", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": true}
            ]
        }),
        NOW,
    );
    connect_bean(&mut pull_rt, "cp1", "Soundcore Work", NOW);
    assert_eq!(pull_rt.snapshot(NOW)["capture"]["selectedSource"], "bean");
    pull_rt.ingest_ble_chunk(&catalog_1b0e_rx(901, 40, NOW as u32 + 1), NOW + 1);
    let pulling = pull_rt.snapshot(NOW + 1);
    assert_eq!(pulling["device"]["transferPhase"], "pulling_offline");
    assert_eq!(pulling["capture"]["selectedSource"], "input:airpods");
    assert_eq!(pulling["capture"]["canStart"], true);

    let dir_hw = Sandbox::new();
    let mut hw_rt = KoeRuntime::open(&dir_hw.0).unwrap();
    dispatch_ok(
        &mut hw_rt,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "airpods", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": true}
            ]
        }),
        NOW,
    );
    connect_bean(&mut hw_rt, "ch1", "Soundcore Work", NOW);

    let mut hw_start = Vec::with_capacity(5);
    hw_start.extend_from_slice(&902u32.to_le_bytes());
    hw_start.push(1);
    hw_rt.ingest_ble_chunk(&rx_frame(0x18, 0x81, &hw_start), NOW + 1);
    hw_rt.ingest_ble_chunk(&rx_frame(0x18, 0x82, &[0]), NOW + 2);
    let quiet_drain = hw_rt.snapshot(NOW + 2);
    assert_eq!(quiet_drain["device"]["recording"], false);
    assert_eq!(quiet_drain["device"]["stopping"], false);
    assert_eq!(quiet_drain["device"]["transferPhase"], "streaming_realtime");

    let mic_during_drain = dispatch(
        &mut hw_rt,
        json!({"type": "start_microphone", "inputId": "airpods"}),
        NOW + 2,
    );
    assert_eq!(
        mic_during_drain["error"],
        "录音豆正在录音中，请先结束当前录音"
    );

    hw_rt.poll_timers(2_000, NOW + 4);

    let mic_active = dispatch_ok(
        &mut hw_rt,
        json!({"type": "start_microphone", "inputId": "airpods", "clockNs": 1_000_000_000u64}),
        NOW + 5,
    );
    assert_eq!(mic_active["microphone"]["inputLabel"], "AirPods Pro");
    assert_eq!(mic_active["microphone"]["inputBadge"], "Mac 蓝牙");

    let mut hw_start_coexist = Vec::with_capacity(5);
    hw_start_coexist.extend_from_slice(&903u32.to_le_bytes());
    hw_start_coexist.push(1);
    hw_rt.ingest_ble_chunk(&rx_frame(0x18, 0x81, &hw_start_coexist), NOW + 6);
    let coexist = hw_rt.snapshot(NOW + 6);
    assert_eq!(coexist["capture"]["activeSource"], "bean");
    assert_eq!(coexist["capture"]["selectedLabel"], "Soundcore Work");
    assert_eq!(coexist["microphone"]["inputLabel"], "AirPods Pro");
    assert_eq!(coexist["microphone"]["inputBadge"], "Mac 蓝牙");
}

fn lane_names(snap: &Value) -> Vec<String> {
    let mut names: Vec<String> = snap["microphone"]["lanes"]
        .as_object()
        .unwrap()
        .keys()
        .cloned()
        .collect();
    names.sort();
    names
}

fn finish_microphone(runtime: &mut KoeRuntime, snap: &Value, now: u64) {
    let mic = snap["microphone"].clone();
    for lane in lane_names(snap) {
        dispatch_ok(
            runtime,
            json!({"type":"microphone_stopped","recordId":mic["recordId"],"sessionId":mic["sessionId"],
                "lane":lane,"sequence":0}),
            now,
        );
    }
    assert!(runtime.snapshot(now)["microphone"].is_null());
}

#[test]
fn capture_studio_system_audio_toggle_starts_dual_lanes_for_meeting_and_quick_note_only() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let initial = runtime.snapshot(NOW);
    assert_eq!(initial["capture"]["includeSystemAudio"], false);
    assert_eq!(initial["capture"]["canIncludeSystemAudio"], true);

    let local_only = dispatch_ok(
        &mut runtime,
        json!({"type":"start_capture_mode","mode":"meeting","stayOnPage":true}),
        NOW,
    );
    assert_eq!(lane_names(&local_only), ["microphone"]);
    assert_eq!(local_only["microphone"]["includeSystem"], false);
    dispatch_ok(&mut runtime, json!({"type":"capture_action","action":"cancel"}), NOW);
    finish_microphone(&mut runtime, &local_only, NOW);

    let enabled = dispatch_ok(
        &mut runtime,
        json!({"type":"set_capture_system_audio","enabled":true}),
        NOW + 1,
    );
    assert_eq!(enabled["capture"]["includeSystemAudio"], true);

    for mode in ["meeting", "quick_note"] {
        let dual = dispatch_ok(
            &mut runtime,
            json!({"type":"start_capture_mode","mode":mode,"stayOnPage":true}),
            NOW + 2,
        );
        assert_eq!(lane_names(&dual), ["microphone", "system"], "{mode}");
        assert_eq!(dual["microphone"]["includeSystem"], true);
        let locked = dispatch(
            &mut runtime,
            json!({"type":"set_capture_system_audio","enabled":false}),
            NOW + 2,
        );
        assert!(locked["error"].is_string(), "toggle must be locked while recording");
        assert_eq!(locked["capture"]["includeSystemAudio"], true);
        dispatch_ok(&mut runtime, json!({"type":"capture_action","action":"cancel"}), NOW + 2);
        finish_microphone(&mut runtime, &dual, NOW + 2);
    }

    let all_day = dispatch_ok(
        &mut runtime,
        json!({"type":"start_capture_mode","mode":"all_day","stayOnPage":true}),
        NOW + 4,
    );
    assert_eq!(lane_names(&all_day), ["microphone"]);
    dispatch_ok(&mut runtime, json!({"type":"capture_action","action":"end"}), NOW + 4);
    finish_microphone(&mut runtime, &all_day, NOW + 4);

    let bean = dispatch_ok(
        &mut runtime,
        json!({"type":"select_capture_source","source":"bean"}),
        NOW + 5,
    );
    assert_eq!(bean["capture"]["canIncludeSystemAudio"], false);
}

#[test]
fn mode_picker_projects_bean_badge_guidance_and_one_click_switch() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let initial = runtime.snapshot(NOW);
    assert_eq!(initial["workspaces"]["picker"]["beanBadge"], "录音豆 未连接");
    assert_eq!(initial["workspaces"]["picker"]["canConnectBean"], true);
    assert_eq!(initial["workspaces"]["picker"]["canSwitchToBean"], false);
    assert_eq!(
        initial["workspaces"]["picker"]["guidanceText"],
        "当前使用电脑麦克风，也可将录音豆放入充电仓按键连接后再选模式。"
    );

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "usb-studio", "name": "Studio Display Microphone", "transport": "usb", "isDefault": false}
            ]
        }),
        NOW + 1,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "input:usb-studio"}),
        NOW + 1,
    );
    connect_bean(&mut runtime, "c-guide", "soundcore Work (63:9D)", NOW + 1);
    let with_bean_connected = runtime.snapshot(NOW + 1);
    let picker = &with_bean_connected["workspaces"]["picker"];
    assert_eq!(picker["sourceBadge"], "USB 外接");
    assert_eq!(picker["sourceLabel"], "Studio Display Microphone");
    assert_eq!(picker["beanBadge"], "录音豆 已连接");
    assert_eq!(picker["canSwitchToBean"], true);
    assert_eq!(picker["canConnectBean"], false);
    assert_eq!(
        picker["guidanceText"],
        "当前使用电脑麦克风，如需用录音豆收音可点右侧切换为录音豆。"
    );

    let switched = dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "bean"}),
        NOW + 2,
    );
    let picker = &switched["workspaces"]["picker"];
    assert_eq!(picker["sourceBadge"], "录音豆");
    assert_eq!(picker["sourceLabel"], "soundcore Work (63:9D)");
    assert_eq!(picker["beanBadge"], "录音豆 已连接");
    assert_eq!(picker["canSwitchToBean"], false);
    assert_eq!(picker["canConnectBean"], false);
    assert_eq!(
        picker["guidanceText"],
        "录音豆已就绪，可直接打开下方模式开关，或单按豆子侧键录闪记。"
    );

    let disconnected = dispatch_ok(
        &mut runtime,
        json!({"type": "device_event", "event": "disconnected", "connectionId": "c-guide"}),
        NOW + 3,
    );
    let picker = &disconnected["workspaces"]["picker"];
    assert_eq!(picker["beanBadge"], "录音豆 未连接");
    assert_eq!(picker["canConnectBean"], true);
    assert_eq!(picker["canSwitchToBean"], false);
    assert_eq!(
        picker["guidanceText"],
        "请先将录音豆放入充电仓长按 2 秒连接，或切换为电脑麦克风后再选模式。"
    );
}

#[test]
fn mode_picker_projects_phone_handoff_fallback_and_offline_pull_guard() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let session_key =
        connect_bean_with_session_key(&mut runtime, "c-handoff", "soundcore Work (63:9D)", NOW);
    let selected = dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "bean"}),
        NOW + 1,
    );
    assert_eq!(selected["capture"]["selectedSource"], "bean");
    assert_eq!(selected["workspaces"]["picker"]["beanControlOwner"], "mac");
    assert_eq!(selected["workspaces"]["picker"]["canReleaseToPhone"], true);

    runtime.ingest_ble_chunk(&catalog_1b0e_rx(901, 20, NOW as u32 + 1), NOW + 1);
    let _ = runtime.drain_outbound_ble_frames();
    complete_offline_pull(&mut runtime, &session_key, 901, NOW + 1);

    let pulling = dispatch_ok(
        &mut runtime,
        json!({"type": "device_download", "fileId": 901}),
        NOW + 2,
    );
    assert_eq!(pulling["workspaces"]["picker"]["canReleaseToPhone"], false);
    assert_eq!(
        pulling["workspaces"]["picker"]["guidanceText"],
        "正在从录音豆拉取离线录音，请等待完成后再切回手机，避免传输中断。"
    );

    complete_offline_pull(&mut runtime, &session_key, 901, NOW + 2);
    let after_pull = runtime.snapshot(NOW + 2);
    assert_eq!(after_pull["device"]["transferPhase"], "idle");
    assert_eq!(after_pull["workspaces"]["picker"]["canReleaseToPhone"], true);

    let released = dispatch_ok(&mut runtime, json!({"type": "device_release"}), NOW + 3);
    let picker = &released["workspaces"]["picker"];
    assert_eq!(picker["beanControlOwner"], "phone");
    assert_eq!(picker["beanBadge"], "已让出给手机");
    assert!(
        picker["guidanceText"]
            .as_str()
            .unwrap()
            .contains("iPhone 飞书妙记"),
        "expected guidanceText to mention iPhone 飞书妙记, got: {}",
        picker["guidanceText"]
    );
    assert_ne!(released["capture"]["selectedSource"], "bean");
    assert_eq!(released["capture"]["canStart"], true);

    let reclaimed = dispatch_ok(
        &mut runtime,
        json!({"type": "set_ble_auto_connect", "enabled": true}),
        NOW + 4,
    );
    assert_eq!(reclaimed["workspaces"]["picker"]["beanControlOwner"], "mac");
    assert_eq!(reclaimed["workspaces"]["picker"]["beanBadge"], "录音豆 未连接");
}

#[test]
fn device_release_rejected_during_pull_and_bean_recording_and_auto_connect_syncs_preference() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    assert_eq!(
        runtime.snapshot(NOW)["workspaces"]["picker"]["beanBadgeTone"],
        "muted"
    );
    let scanning = dispatch_ok(
        &mut runtime,
        json!({"type": "device_event", "event": "scanning", "connectionId": "c-tone"}),
        NOW,
    );
    assert_eq!(scanning["workspaces"]["picker"]["beanBadgeTone"], "warning");

    let session_key =
        connect_bean_with_session_key(&mut runtime, "c-guard", "soundcore Work (63:9D)", NOW);
    assert_eq!(
        runtime.snapshot(NOW)["workspaces"]["picker"]["beanBadgeTone"],
        "success"
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "bean"}),
        NOW + 1,
    );
    runtime.ingest_ble_chunk(&catalog_1b0e_rx(902, 20, NOW as u32 + 1), NOW + 1);
    let _ = runtime.drain_outbound_ble_frames();
    complete_offline_pull(&mut runtime, &session_key, 902, NOW + 1);

    let pulling = dispatch_ok(
        &mut runtime,
        json!({"type": "device_download", "fileId": 902}),
        NOW + 2,
    );
    assert_eq!(pulling["workspaces"]["picker"]["canReleaseToPhone"], false);
    let rejected_pull = dispatch(&mut runtime, json!({"type": "device_release"}), NOW + 2);
    assert!(rejected_pull["error"].is_string());
    assert_eq!(rejected_pull["device"]["connected"], true);
    assert_eq!(rejected_pull["device"]["autoConnect"], true);
    assert_eq!(rejected_pull["device"]["transferPhase"], "pulling_offline");
    assert_eq!(rejected_pull["capture"]["selectedSource"], "bean");
    assert_eq!(
        rejected_pull["workspaces"]["picker"]["beanControlOwner"],
        "mac"
    );

    complete_offline_pull(&mut runtime, &session_key, 902, NOW + 2);
    assert_eq!(runtime.snapshot(NOW + 2)["device"]["transferPhase"], "idle");

    let started = dispatch_ok(&mut runtime, json!({"type": "device_start"}), NOW + 3);
    assert_eq!(started["device"]["recording"], true);
    assert_eq!(started["workspaces"]["picker"]["canReleaseToPhone"], false);
    let rejected_rec = dispatch(&mut runtime, json!({"type": "device_release"}), NOW + 3);
    assert!(rejected_rec["error"].is_string());
    assert_eq!(rejected_rec["device"]["connected"], true);
    assert_eq!(rejected_rec["device"]["autoConnect"], true);
    assert_eq!(rejected_rec["device"]["recording"], true);

    dispatch_ok(&mut runtime, json!({"type": "device_stop"}), NOW + 4);
    runtime.ingest_ble_chunk(&rx_frame(0x18, 0x82, &[2]), NOW + 4);
    runtime.poll_timers(2_100, NOW + 7);
    assert_eq!(
        runtime.snapshot(NOW + 7)["workspaces"]["picker"]["canReleaseToPhone"],
        true
    );

    let released = dispatch_ok(&mut runtime, json!({"type": "device_release"}), NOW + 7);
    assert_eq!(released["device"]["connected"], false);
    assert_eq!(released["device"]["autoConnect"], false);
    assert_eq!(
        released["workspaces"]["picker"]["beanControlOwner"],
        "phone"
    );
    assert_eq!(released["workspaces"]["picker"]["beanBadgeTone"], "muted");
    assert_ne!(released["capture"]["selectedSource"], "bean");

    let reopened_guide = dispatch_ok(&mut runtime, json!({"type": "device_open_guide"}), NOW + 8);
    assert_eq!(reopened_guide["device"]["autoConnect"], true);
    assert_eq!(reopened_guide["device"]["guide"]["mode"], "connect_guide");
    assert_eq!(
        reopened_guide["workspaces"]["picker"]["beanControlOwner"],
        "mac"
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "bean"}),
        NOW + 9,
    );
    let disabled_auto = dispatch_ok(
        &mut runtime,
        json!({"type": "set_ble_auto_connect", "enabled": false}),
        NOW + 9,
    );
    assert_eq!(
        disabled_auto["workspaces"]["picker"]["beanControlOwner"],
        "phone"
    );
    assert_ne!(disabled_auto["capture"]["selectedSource"], "bean");
}

#[test]
fn set_ble_auto_connect_false_and_device_release_rejected_during_active_or_suspended_pull_and_bean_recording() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();

    let session_key =
        connect_bean_with_session_key(&mut runtime, "c-guard2", "soundcore Work (63:9D)", NOW);
    dispatch_ok(
        &mut runtime,
        json!({"type": "select_capture_source", "source": "bean"}),
        NOW + 1,
    );
    runtime.ingest_ble_chunk(&catalog_1b0e_rx(903, 20, NOW as u32 + 1), NOW + 1);
    let _ = runtime.drain_outbound_ble_frames();
    complete_offline_pull(&mut runtime, &session_key, 903, NOW + 1);

    dispatch_ok(
        &mut runtime,
        json!({"type": "device_download", "fileId": 903}),
        NOW + 2,
    );
    let rejected_auto_during_pull = dispatch(
        &mut runtime,
        json!({"type": "set_ble_auto_connect", "enabled": false}),
        NOW + 2,
    );
    assert!(rejected_auto_during_pull["error"].is_string());
    assert_eq!(rejected_auto_during_pull["device"]["autoConnect"], true);
    assert_eq!(
        rejected_auto_during_pull["capture"]["selectedSource"],
        "bean"
    );

    let suspended = dispatch_ok(
        &mut runtime,
        json!({"type": "device_event", "event": "disconnected", "connectionId": "c-guard2"}),
        NOW + 3,
    );
    assert_eq!(suspended["device"]["transferPhase"], "suspended");
    assert_eq!(
        suspended["workspaces"]["picker"]["canReleaseToPhone"],
        false
    );

    let rejected_auto_suspended = dispatch(
        &mut runtime,
        json!({"type": "set_ble_auto_connect", "enabled": false}),
        NOW + 3,
    );
    assert!(rejected_auto_suspended["error"].is_string());
    assert_eq!(rejected_auto_suspended["device"]["autoConnect"], true);

    let rejected_release_suspended =
        dispatch(&mut runtime, json!({"type": "device_release"}), NOW + 3);
    assert!(rejected_release_suspended["error"].is_string());
    assert_eq!(rejected_release_suspended["device"]["autoConnect"], true);
    assert_eq!(
        rejected_release_suspended["device"]["transferPhase"],
        "suspended"
    );

    let session_key_2 =
        connect_bean_with_session_key(&mut runtime, "c-guard3", "soundcore Work (63:9D)", NOW + 4);
    complete_offline_pull(&mut runtime, &session_key_2, 903, NOW + 4);
    assert_eq!(runtime.snapshot(NOW + 4)["device"]["transferPhase"], "idle");

    dispatch_ok(&mut runtime, json!({"type": "device_start"}), NOW + 5);
    let rejected_auto_recording = dispatch(
        &mut runtime,
        json!({"type": "set_ble_auto_connect", "enabled": false}),
        NOW + 5,
    );
    assert!(rejected_auto_recording["error"].is_string());
    assert_eq!(rejected_auto_recording["device"]["autoConnect"], true);
    assert_eq!(rejected_auto_recording["device"]["recording"], true);

    dispatch_ok(&mut runtime, json!({"type": "device_stop"}), NOW + 6);
    runtime.ingest_ble_chunk(&rx_frame(0x18, 0x82, &[2]), NOW + 6);
    runtime.poll_timers(2_100, NOW + 9);

    let released = dispatch_ok(&mut runtime, json!({"type": "device_release"}), NOW + 9);
    assert_eq!(released["device"]["autoConnect"], false);
    assert_eq!(released["workspaces"]["picker"]["beanControlOwner"], "phone");
    assert_eq!(released["notice"], "已释放录音豆蓝牙控制权");

    let second_release = dispatch_ok(&mut runtime, json!({"type": "device_release"}), NOW + 10);
    assert!(second_release["error"].is_null());
    assert!(second_release["notice"].is_null());
    assert_eq!(
        second_release["workspaces"]["picker"]["beanControlOwner"],
        "phone"
    );
}
