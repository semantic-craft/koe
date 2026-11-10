use super::*;
use koe_client_providers::{ProviderEvent, ProviderOutput, TranscriptSegment};
use koe_engine::{
    frame::{ProtocolFrame, RX_MAGIC},
    session::REAL_OPUS_20MS_440HZ_PACKET,
    transport::OPUS_FRAME_BYTES,
};
use serde_json::json;
use std::{
    fs,
    sync::atomic::{AtomicU64, Ordering},
};

const NOW: u64 = 1_800_000_000;
struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-lifecycle-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn dispatch(runtime: &mut KoeRuntime, command: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&command.to_string(), NOW)).unwrap()
}
fn rx(group: u8, command: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = RX_MAGIC.to_vec();
    frame.extend_from_slice(&[1, group, command]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(ProtocolFrame::checksum(&frame));
    frame
}
fn audio(sequence: u32) -> Vec<u8> {
    let mut payload = sequence.to_le_bytes().to_vec();
    payload.push(0);
    let mut opus = [0; OPUS_FRAME_BYTES];
    opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
    payload.extend_from_slice(&opus);
    payload.push(0);
    rx(0x1a, 0x08, &payload)
}
fn live(runtime: &mut KoeRuntime) -> String {
    runtime.device.session.active_file_id = Some(912);
    runtime.device.session.active_is_realtime = true;
    runtime.device.session.device_recording_active = true;
    runtime.ingest_ble_chunk(&audio(0), NOW);
    runtime.workspace().records().keys().next().unwrap().clone()
}
fn keep_awake(runtime: &KoeRuntime) -> bool {
    runtime.snapshot(NOW)["lifecycle"]["keepAwake"]
        .as_bool()
        .unwrap_or(false)
}
fn quit_phase(runtime: &KoeRuntime) -> String {
    runtime.snapshot(NOW)["lifecycle"]["quitPhase"]
        .as_str()
        .unwrap_or("ready")
        .into()
}
fn queue_transcript(runtime: &mut KoeRuntime, id: &str, operation: u64, text: &str) {
    let key = runtime
        .store
        .transact(|w| w.begin_analysis(id, AnalysisStage::Transcribing))
        .unwrap();
    runtime
        .pending
        .insert(operation, PendingWork::Transcription(key));
    runtime.completed.push_back(ProviderEvent {
        operation_id: operation,
        record_id: id.into(),
        result: Ok(ProviderOutput::Transcript {
            segments: vec![TranscriptSegment {
                text: text.into(),
                start_ms: 0,
                end_ms: 20,
            }],
        }),
    });
}

#[test]
fn overlapping_capture_and_provider_hold_activity_until_both_are_durable() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let id = live(&mut runtime);
    queue_transcript(&mut runtime, &id, 10, "Persist this result");
    assert!(
        keep_awake(&runtime),
        "owned audio and result must hold system activity"
    );
    runtime.poll_timers(0, NOW);
    assert!(
        keep_awake(&runtime),
        "finishing provider cannot release active recording"
    );
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.ingest_ble_chunk(&rx(0x18, 0x82, &[0]), NOW);
    runtime.poll_timers(2_000, NOW + 2);
    assert_eq!(quit_phase(&runtime), "ready");
    assert!(!keep_awake(&runtime));
    assert!(recording_assets::audio_path(&dir.0, &id).unwrap().exists());
    drop(runtime);
    let reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(
        reopened
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "Persist this result"
    );
}

#[test]
fn quit_waits_for_late_audio_and_durable_asset() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let id = live(&mut runtime);
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    assert_ne!(
        quit_phase(&runtime),
        "ready",
        "quit must not drop an in-memory recording"
    );
    runtime.ingest_ble_chunk(&rx(0x18, 0x82, &[0]), NOW);
    runtime.poll_timers(1_900, NOW + 1);
    runtime.ingest_ble_chunk(&audio(1), NOW + 1);
    runtime.poll_timers(1_900, NOW + 2);
    assert_ne!(quit_phase(&runtime), "ready");
    runtime.poll_timers(100, NOW + 3);
    assert_eq!(quit_phase(&runtime), "ready");
    assert!(runtime.device.session.has_disk_custody(912));
    assert!(recording_assets::audio_path(&dir.0, &id).unwrap().exists());
}

#[test]
fn failed_asset_save_blocks_quit_until_retry_even_after_error_is_cleared() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let id = live(&mut runtime);
    fs::write(dir.0.join("audio"), b"storage fault").unwrap();
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.ingest_ble_chunk(&rx(0x18, 0x82, &[0]), NOW);
    runtime.poll_timers(2_000, NOW + 2);
    assert_eq!(
        quit_phase(&runtime),
        "blocked",
        "failed audio persistence must veto exit"
    );
    dispatch(&mut runtime, json!({"type":"clear_error"}));
    assert_eq!(quit_phase(&runtime), "blocked");
    assert!(keep_awake(&runtime));
    fs::remove_file(dir.0.join("audio")).unwrap();
    runtime.poll_timers(0, NOW + 3);
    assert_eq!(quit_phase(&runtime), "ready");
    assert!(recording_assets::audio_path(&dir.0, &id).unwrap().exists());
}

#[test]
fn quit_preserves_completed_result_until_metadata_save_succeeds() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime
        .commit(|w| {
            w.insert_record(
                "r".into(),
                "Record".into(),
                RecordOrigin::ImportedAudio,
                0,
                NOW,
                20,
            )
        })
        .unwrap();
    queue_transcript(&mut runtime, "r", 11, "Late durable result");
    let path = dir.0.join("product-workspace.json");
    fs::rename(&path, dir.0.join("original.json")).unwrap();
    fs::create_dir(&path).unwrap();
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.poll_timers(0, NOW);
    assert_eq!(quit_phase(&runtime), "blocked");
    assert!(keep_awake(&runtime));
    assert!(runtime
        .workspace()
        .record("r")
        .unwrap()
        .aggregate
        .spine
        .is_empty());
    fs::remove_dir(&path).unwrap();
    fs::rename(dir.0.join("original.json"), &path).unwrap();
    runtime.poll_timers(0, NOW);
    assert_eq!(quit_phase(&runtime), "ready");
    drop(runtime);
    let reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(
        reopened
            .workspace()
            .record("r")
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "Late durable result"
    );
}

#[test]
fn cancelling_quit_allows_work_and_keeps_late_results_on_original_record() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime
        .commit(|w| {
            w.insert_record(
                "r".into(),
                "Record".into(),
                RecordOrigin::ImportedAudio,
                0,
                NOW,
                20,
            )
        })
        .unwrap();
    queue_transcript(&mut runtime, "r", 12, "Original record only");
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    let denied = dispatch(
        &mut runtime,
        json!({"type":"create_note","title":"No", "text":"not started"}),
    );
    assert!(
        denied["error"].is_string(),
        "new work must not race the exit drain"
    );
    dispatch(&mut runtime, json!({"type":"cancel_quit"}));
    let allowed = dispatch(
        &mut runtime,
        json!({"type":"create_note","title":"New", "text":"new record"}),
    );
    assert!(allowed["error"].is_null());
    runtime.poll_timers(0, NOW);
    assert_eq!(quit_phase(&runtime), "running");
    assert_eq!(
        runtime
            .workspace()
            .record("r")
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "Original record only"
    );
    assert_eq!(
        runtime
            .workspace()
            .record(allowed["selectedRecordId"].as_str().unwrap())
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "new record"
    );
}

#[test]
fn quit_during_unconfirmed_start_waits_for_device_stop_confirmation() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime.device.session.set_session_key([0x55; 32]);
    dispatch(&mut runtime, json!({"type":"device_start"}));
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.drain_outbound_ble_frames();
    runtime.poll_timers(5_000, NOW + 5);
    assert_ne!(
        quit_phase(&runtime),
        "ready",
        "sending stop is not confirmation that pending recording stopped"
    );
    runtime.ingest_ble_chunk(&rx(0x18, 0x82, &[0]), NOW + 5);
    assert_eq!(quit_phase(&runtime), "ready");
}

fn file_head(file_id: u32, size: u32) -> Vec<u8> {
    let mut payload = file_id.to_le_bytes().to_vec();
    payload.extend_from_slice(&size.to_le_bytes());
    payload.extend_from_slice(&[0; 79]);
    rx(0x1a, 0x07, &payload)
}
fn catalog(file_id: u32) -> Vec<u8> {
    let mut payload = 1u16.to_le_bytes().to_vec();
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&40u32.to_le_bytes());
    payload.extend_from_slice(&(NOW as u32 + 1).to_le_bytes());
    rx(0x1b, 0x0e, &payload)
}

#[test]
fn quit_salvages_zero_live_audio_without_starting_unrelated_catalog_work() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime.device.session.set_session_key([0x55; 32]);
    dispatch(&mut runtime, json!({"type":"device_start"}));
    runtime.ingest_ble_chunk(&file_head(913, 0), NOW);
    let id = runtime.workspace().records().keys().next().unwrap().clone();
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.ingest_ble_chunk(&rx(0x18, 0x82, &[0]), NOW);
    runtime.ingest_ble_chunk(&catalog(913), NOW + 1);
    runtime.poll_timers(2_000, NOW + 2);
    assert_ne!(quit_phase(&runtime), "ready");
    runtime.ingest_ble_chunk(&file_head(913, 166), NOW + 2);
    runtime.ingest_ble_chunk(&audio(0), NOW + 2);
    runtime.ingest_ble_chunk(&rx(0x1a, 0x0a, &913u32.to_le_bytes()), NOW + 2);
    runtime.poll_timers(0, NOW + 2);
    assert_eq!(quit_phase(&runtime), "ready");
    assert!(recording_assets::audio_path(&dir.0, &id).unwrap().exists());
    runtime.ingest_ble_chunk(&catalog(999), NOW + 3);
    assert_eq!(
        quit_phase(&runtime),
        "ready",
        "unrelated next file must wait for next launch"
    );
    assert!(runtime.device.session.active_file_id.is_none());
}

#[test]
fn disconnected_offline_pull_blocks_quit_until_reconnected_and_saved() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime.device.connection = Some("fixture".into());
    runtime.device.session.set_session_key([0x55; 32]);
    runtime.ingest_ble_chunk(&catalog(914), NOW);
    runtime.ingest_ble_chunk(&file_head(914, 332), NOW);
    runtime.ingest_ble_chunk(&audio(0), NOW);
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    dispatch(
        &mut runtime,
        json!({"type":"device_event","event":"disconnected","connectionId":"fixture"}),
    );
    assert_eq!(quit_phase(&runtime), "blocked");
    dispatch(&mut runtime, json!({"type":"cancel_quit"}));
    assert_eq!(quit_phase(&runtime), "running");
    runtime.device.session.set_session_key([0x55; 32]);
    assert!(runtime.device.session.resume_offline_pull().is_some());
    runtime.ingest_ble_chunk(&audio(1), NOW);
    runtime.ingest_ble_chunk(&rx(0x1a, 0x0a, &914u32.to_le_bytes()), NOW);
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    assert_eq!(quit_phase(&runtime), "ready");
    assert!(runtime.device.session.has_disk_custody(914));
}

#[test]
fn repeated_quit_does_not_restart_the_audio_quiet_window() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    live(&mut runtime);
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.ingest_ble_chunk(&rx(0x18, 0x82, &[0]), NOW);
    runtime.poll_timers(1_500, NOW + 1);
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.poll_timers(500, NOW + 2);
    assert_eq!(quit_phase(&runtime), "ready");
    assert!(!keep_awake(&runtime));
    assert!(runtime.device.session.has_disk_custody(912));
}

#[test]
fn cancel_then_new_request_rejects_late_old_success_and_failure() {
    for late_failure in [false, true] {
        let dir = Sandbox::new();
        let mut runtime = KoeRuntime::open(&dir.0).unwrap();
        runtime
            .commit(|w| {
                w.insert_record(
                    "r".into(),
                    "Record".into(),
                    RecordOrigin::ImportedAudio,
                    0,
                    NOW,
                    20,
                )
            })
            .unwrap();
        queue_transcript(&mut runtime, "r", 20, "Must be ignored");
        if late_failure {
            runtime.completed.front_mut().unwrap().result = Err("Old request failed".into());
        }
        dispatch(&mut runtime, json!({"type":"request_quit"}));
        dispatch(&mut runtime, json!({"type":"cancel_quit"}));
        let PendingWork::Transcription(old_key) = runtime.pending[&20].clone() else {
            panic!()
        };
        runtime
            .commit(|w| w.fail_analysis(&old_key, "Cancelled for retry"))
            .unwrap();
        queue_transcript(&mut runtime, "r", 21, "Only current result");
        dispatch(&mut runtime, json!({"type":"request_quit"}));
        runtime.poll_timers(0, NOW);
        assert_eq!(
            quit_phase(&runtime),
            "ready",
            "stale failure must not strand quit"
        );
        assert_eq!(
            runtime
                .workspace()
                .record("r")
                .unwrap()
                .aggregate
                .spine
                .segments()[0]
                .text,
            "Only current result"
        );
    }
}

#[test]
fn idle_quit_does_not_start_unconfigured_automatic_work() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime.auto_summarize.insert("absent".into());
    assert!(!keep_awake(&runtime));
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    assert_eq!(quit_phase(&runtime), "ready");
    runtime.poll_timers(0, NOW);
    assert_eq!(quit_phase(&runtime), "ready");
}

#[cfg(unix)]
#[test]
fn uncertain_commit_never_grants_quit_even_after_cancel_and_error_clear() {
    use std::os::unix::fs::PermissionsExt;
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let original = fs::metadata(&dir.0).unwrap().permissions();
    fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o300)).unwrap();
    let saved = dispatch(
        &mut runtime,
        json!({"type":"create_note","title":"Uncertain", "text":"Retain evidence"}),
    );
    fs::set_permissions(&dir.0, original).unwrap();
    assert!(saved["error"]
        .as_str()
        .unwrap()
        .contains("无法确认保存结果"));
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    assert_eq!(quit_phase(&runtime), "blocked");
    dispatch(&mut runtime, json!({"type":"cancel_quit"}));
    dispatch(&mut runtime, json!({"type":"clear_error"}));
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.poll_timers(0, NOW);
    assert_eq!(quit_phase(&runtime), "blocked");
    assert!(keep_awake(&runtime));
}

#[test]
fn quit_after_manual_stop_still_waits_for_device_confirmation() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    live(&mut runtime);
    dispatch(&mut runtime, json!({"type":"device_stop"}));
    dispatch(&mut runtime, json!({"type":"request_quit"}));
    runtime.poll_timers(2_000, NOW + 2);
    assert_ne!(
        quit_phase(&runtime),
        "ready",
        "manual stop must not bypass stop confirmation"
    );
    runtime.ingest_ble_chunk(&rx(0x18, 0x82, &[0]), NOW + 2);
    assert_eq!(quit_phase(&runtime), "ready");
}
