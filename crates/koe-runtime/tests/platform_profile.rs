use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

struct TempWorkspace(PathBuf);

impl TempWorkspace {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let dir = std::env::temp_dir().join(format!(
            "koe-platform-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("create temp workspace");
        Self(dir)
    }
}

impl Drop for TempWorkspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn send(runtime: &mut KoeRuntime, command: Value, now: u64) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&command.to_string(), now))
        .expect("parse runtime snapshot json")
}

fn record_short_microphone_clip(runtime: &mut KoeRuntime, input_id: &str, now: u64) -> Value {
    let started = send(
        runtime,
        json!({"type": "start_microphone", "inputId": input_id, "clockNs": 1_000_000_000u64}),
        now,
    );
    assert!(started["error"].is_null(), "start failed: {started}");
    let rec_id = started["microphone"]["recordId"]
        .as_str()
        .expect("recordId")
        .to_owned();
    let ses_id = started["microphone"]["sessionId"]
        .as_str()
        .expect("sessionId")
        .to_owned();
    let ready = send(
        runtime,
        json!({
            "type": "microphone_started",
            "recordId": rec_id,
            "sessionId": ses_id,
            "lane": "microphone",
            "sampleRate": 16_000
        }),
        now,
    );
    assert!(ready["error"].is_null(), "microphone_started failed: {ready}");
    let samples = vec![320i16; 320];
    let receipt = runtime.ingest_microphone_pcm(
        &rec_id,
        &ses_id,
        "microphone",
        0,
        &samples,
        Some((0, 1_000_000_000)),
        now,
    );
    assert_eq!(receipt.status, koe_runtime::PcmIngestStatus::Accepted);
    let _ = send(runtime, json!({"type": "stop_microphone"}), now + 1);
    let saved = send(
        runtime,
        json!({
            "type": "microphone_stopped",
            "recordId": rec_id,
            "sessionId": ses_id,
            "lane": "microphone",
            "sequence": 1,
            "epoch": 0
        }),
        now + 1,
    );
    assert!(saved["error"].is_null(), "save failed: {saved}");
    saved
}

#[test]
fn default_macos_profile_preserves_labels_system_audio_and_bean_control_contract() {
    let ws = TempWorkspace::new("macos-default");
    let mut runtime = KoeRuntime::open(&ws.0).expect("open runtime");
    let now = 1_800_000_000;

    let initial = runtime.snapshot(now);
    assert_eq!(initial["platform"]["id"], "macos");
    assert_eq!(initial["platform"]["hostDisplayName"], "Mac");
    assert_eq!(initial["platform"]["supportsSystemAudio"], true);
    assert_eq!(initial["platform"]["supportsSelfUpdate"], true);
    assert_eq!(initial["platform"]["nativeSpeechLabel"], "Apple 本机");
    assert_eq!(initial["capture"]["canIncludeSystemAudio"], true);
    assert_eq!(initial["workspaces"]["picker"]["beanControlOwner"], "mac");
    assert_eq!(
        initial["workspaces"]["picker"]["beanControlState"],
        "this_device"
    );

    let legacy_sync = send(
        &mut runtime,
        json!({
            "type": "sync_app_metadata",
            "version": "2.9.0",
            "build": "19"
        }),
        now + 1,
    );
    assert!(legacy_sync["error"].is_null());
    assert_eq!(legacy_sync["platform"]["id"], "macos");
    assert_eq!(legacy_sync["capture"]["canIncludeSystemAudio"], true);

    let with_bt = send(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "bt-airpods", "name": "AirPods Pro", "transport": "bluetooth", "isDefault": false}
            ]
        }),
        now + 2,
    );
    assert_eq!(with_bt["capture"]["inputs"][0]["badge"], "Mac 蓝牙");
    assert_eq!(with_bt["capture"]["selectedBadge"], "Mac 蓝牙");

    let saved = record_short_microphone_clip(&mut runtime, "unlisted-mic", now + 3);
    assert_eq!(saved["records"][0]["title"], "Mac 麦克风录音");
    assert_eq!(saved["records"][0]["source"], "Mac 麦克风");

    let released = send(&mut runtime, json!({"type": "device_release"}), now + 5);
    assert_eq!(
        released["workspaces"]["picker"]["beanControlOwner"],
        "phone"
    );
    assert_eq!(
        released["workspaces"]["picker"]["beanControlState"],
        "released"
    );
    assert_eq!(
        released["workspaces"]["picker"]["guidanceText"],
        "已释放 Mac 蓝牙占用，可在 iPhone 飞书妙记连接。若未搜到，将录音豆放入充电仓短按下方按钮。"
    );
}

#[test]
fn android_profile_adapts_labels_blocks_system_audio_and_self_update_and_generalizes_release() {
    let ws = TempWorkspace::new("android");
    let mut runtime = KoeRuntime::open(&ws.0).expect("open runtime");
    let now = 1_800_001_000;

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    listener
        .set_nonblocking(true)
        .expect("set listener nonblocking");
    let endpoint = format!(
        "http://{}/repos/semantic-craft/koe/releases/latest",
        listener.local_addr().expect("listener addr")
    );

    let enabled_before_switch = send(
        &mut runtime,
        json!({"type": "set_capture_system_audio", "enabled": true}),
        now,
    );
    assert_eq!(enabled_before_switch["capture"]["includeSystemAudio"], true);

    let synced = send(
        &mut runtime,
        json!({
            "type": "sync_app_metadata",
            "version": "2.9.0",
            "build": "101",
            "updateEndpoint": endpoint,
            "platform": "android"
        }),
        now + 1,
    );
    assert!(synced["error"].is_null());
    assert_eq!(synced["platform"]["id"], "android");
    assert_eq!(synced["platform"]["hostDisplayName"], "Android");
    assert_eq!(synced["platform"]["supportsSystemAudio"], false);
    assert_eq!(synced["platform"]["supportsSelfUpdate"], false);
    assert_eq!(synced["platform"]["nativeSpeechLabel"], "Android 本机");
    assert_eq!(synced["capture"]["includeSystemAudio"], false);
    assert_eq!(synced["capture"]["canIncludeSystemAudio"], false);

    let with_bt = send(
        &mut runtime,
        json!({
            "type": "sync_audio_inputs",
            "inputs": [
                {"id": "bt-headset", "name": "Pixel Buds", "transport": "bluetooth", "isDefault": false}
            ]
        }),
        now + 2,
    );
    assert_eq!(with_bt["capture"]["inputs"][0]["badge"], "Android 蓝牙");
    assert_eq!(with_bt["capture"]["selectedBadge"], "Android 蓝牙");

    let reject_toggle = send(
        &mut runtime,
        json!({"type": "set_capture_system_audio", "enabled": true}),
        now + 3,
    );
    assert!(reject_toggle["error"]
        .as_str()
        .is_some_and(|e| e.contains("不支持录制系统音频")));
    assert_eq!(reject_toggle["capture"]["includeSystemAudio"], false);

    let reject_start = send(
        &mut runtime,
        json!({"type": "start_microphone", "inputId": "", "includeSystem": true}),
        now + 4,
    );
    assert!(reject_start["error"]
        .as_str()
        .is_some_and(|e| e.contains("不支持录制系统音频")));
    assert!(reject_start["microphone"].is_null());

    let bad_all_day = send(
        &mut runtime,
        json!({"type": "start_all_day", "source": "invalid"}),
        now + 5,
    );
    assert_eq!(bad_all_day["error"], "请选择 Android 麦克风或录音豆");

    let update_snap = send(&mut runtime, json!({"type": "check_app_update"}), now + 6);
    assert!(update_snap["error"].is_null());
    assert_eq!(update_snap["appUpdate"]["phase"], "unavailable");
    assert_eq!(
        update_snap["appUpdate"]["message"],
        "当前分发渠道不提供应用内更新"
    );
    assert!(
        matches!(
            listener.accept(),
            Err(err) if err.kind() == std::io::ErrorKind::WouldBlock
        ),
        "check_app_update must not issue a network request when supports_self_update is false"
    );

    let saved = record_short_microphone_clip(&mut runtime, "unlisted-android-mic", now + 7);
    assert_eq!(saved["records"][0]["title"], "Android 麦克风录音");
    assert_eq!(saved["records"][0]["source"], "Android 麦克风");

    let released = send(&mut runtime, json!({"type": "device_release"}), now + 10);
    assert_eq!(
        released["workspaces"]["picker"]["beanControlOwner"],
        "phone"
    );
    assert_eq!(
        released["workspaces"]["picker"]["beanControlState"],
        "released"
    );
    let guidance = released["workspaces"]["picker"]["guidanceText"]
        .as_str()
        .expect("guidanceText");
    assert!(guidance.contains("Android"), "unexpected guidance: {guidance}");
    assert!(!guidance.contains("Mac"), "android guidance leaked Mac: {guidance}");

    let apk_override = send(
        &mut runtime,
        json!({
            "type": "sync_app_metadata",
            "version": "2.9.0",
            "build": "102",
            "platform": "android",
            "supportsSelfUpdate": true
        }),
        now + 11,
    );
    assert!(apk_override["error"].is_null());
    assert_eq!(apk_override["platform"]["supportsSelfUpdate"], true);
}

#[test]
fn ios_profile_sets_iphone_labels_disables_system_audio_and_keeps_apple_speech_label() {
    let ws = TempWorkspace::new("ios");
    let mut runtime = KoeRuntime::open(&ws.0).expect("open runtime");
    let now = 1_800_002_000;

    let synced = send(
        &mut runtime,
        json!({
            "type": "sync_app_metadata",
            "version": "2.9.0",
            "build": "201",
            "platform": "ios"
        }),
        now,
    );
    assert!(synced["error"].is_null());
    assert_eq!(synced["platform"]["id"], "ios");
    assert_eq!(synced["platform"]["hostDisplayName"], "iPhone");
    assert_eq!(synced["platform"]["supportsSystemAudio"], false);
    assert_eq!(synced["platform"]["supportsSelfUpdate"], false);
    assert_eq!(synced["platform"]["nativeSpeechLabel"], "Apple 本机");
    assert_eq!(synced["capture"]["canIncludeSystemAudio"], false);

    let saved = record_short_microphone_clip(&mut runtime, "unlisted-ios-mic", now + 1);
    assert_eq!(saved["records"][0]["title"], "iPhone 麦克风录音");
    assert_eq!(saved["records"][0]["source"], "iPhone 麦克风");

    let ipad = send(
        &mut runtime,
        json!({
            "type": "sync_app_metadata",
            "version": "2.9.0",
            "build": "202",
            "hostDisplayName": "iPad"
        }),
        now + 3,
    );
    assert!(ipad["error"].is_null());
    assert_eq!(ipad["platform"]["id"], "ios");
    assert_eq!(ipad["platform"]["hostDisplayName"], "iPad");
    assert_eq!(ipad["records"][0]["source"], "iPad 麦克风");
}

#[test]
fn invalid_platform_in_sync_app_metadata_is_rejected_without_mutating_profile() {
    let ws = TempWorkspace::new("invalid-platform");
    let mut runtime = KoeRuntime::open(&ws.0).expect("open runtime");
    let now = 1_800_003_000;

    let _ = send(
        &mut runtime,
        json!({
            "type": "sync_app_metadata",
            "version": "2.9.0",
            "build": "301",
            "platform": "ios"
        }),
        now,
    );

    for bad_platform in ["windows", "   "] {
        let rejected = send(
            &mut runtime,
            json!({
                "type": "sync_app_metadata",
                "version": "9.9.9",
                "build": "999",
                "platform": bad_platform
            }),
            now + 1,
        );
        assert!(
            rejected["error"]
                .as_str()
                .is_some_and(|e| e.contains("不支持的宿主平台")),
            "expected invalid platform error for {bad_platform:?}, got {rejected}"
        );
        assert_eq!(rejected["platform"]["id"], "ios");
        assert_eq!(rejected["appUpdate"]["currentVersion"], "2.9.0");
    }
}

#[test]
fn first_install_persists_the_supported_speech_engine() {
    for (platform, expected_engine, supports_native) in [
        ("android", "cloud", false),
        ("ios", "apple_speech", true),
        ("macos", "apple_speech", true),
    ] {
        let ws = TempWorkspace::new(platform);
        let mut runtime = KoeRuntime::open(&ws.0).expect("open fresh workspace");
        let metadata = json!({
            "type": "sync_app_metadata", "version": "2.7.0", "build": "16", "platform": platform
        });
        let snapshot = send(&mut runtime, metadata, 1);
        assert!(
            snapshot["error"].is_null(),
            "{platform}: {}",
            snapshot["error"]
        );
        assert_eq!(snapshot["speech"]["engine"], expected_engine, "{platform}");
        assert_eq!(
            snapshot["platform"]["supportsNativeSpeech"], supports_native,
            "{platform}"
        );
        drop(runtime);
        let reopened = KoeRuntime::open(&ws.0).expect("reopen workspace");
        assert_eq!(
            reopened.snapshot(2)["speech"]["engine"],
            expected_engine,
            "{platform}"
        );
    }
}
