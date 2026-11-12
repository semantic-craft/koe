use koe_engine::{crypto::DeviceCrypto, frame::ProtocolFrame};
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

fn connect_bean(runtime: &mut KoeRuntime, connection_id: &str, name: &str, now: u64) {
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
