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
    assert_eq!(runtime.snapshot(1800000015)["device"]["busy"], false);
    assert!(runtime.snapshot(1800000015)["error"]
        .as_str()
        .unwrap()
        .contains("未确认"));
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
    runtime.settings.chat_endpoint = "invalid://endpoint".into();
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
