#![allow(clippy::unwrap_used, clippy::expect_used)]

use koe_client_base::{
    atomic_fs::write_atomic,
    fault_injection::{arm_fs_fault, FsFaultPoint},
};
use koe_client_services::product_store::{ProductStore, StoreError};
use koe_engine::product::RecordOrigin;
use koe_runtime::{KoeRuntime, MicrophonePcmChunk, PcmIngestStatus};
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

struct TempDir(PathBuf);

impl TempDir {
    fn new(prefix: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-fault-{prefix}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn dispatch(runtime: &mut KoeRuntime, cmd: Value, now: u64) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&cmd.to_string(), now)).unwrap()
}

#[test]
fn write_atomic_fault_injection_cleans_tmp_and_preserves_target_for_write_sync_and_rename() {
    let dir = TempDir::new("atomic");
    let target = dir.0.join("state.json");
    write_atomic(&target, b"{\"version\":1}").unwrap();

    for point in [
        FsFaultPoint::AtomicWrite,
        FsFaultPoint::AtomicSync,
        FsFaultPoint::AtomicRename,
    ] {
        let _guard = arm_fs_fault(point, 0, "injected atomic failure");
        let err = write_atomic(&target, b"{\"version\":2}")
            .expect_err("armed fault point must fail write_atomic");
        assert!(
            err.to_string().contains("injected atomic failure"),
            "unexpected error for {point:?}: {err}"
        );
        assert_eq!(
            fs::read(&target).unwrap(),
            b"{\"version\":1}",
            "target file must stay untouched after {point:?} failure"
        );
        let leftovers: Vec<_> = fs::read_dir(&dir.0)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|e| e.file_name().to_string_lossy().ends_with(".tmp"))
            .map(|e| e.file_name())
            .collect();
        assert!(
            leftovers.is_empty(),
            "zero .tmp files may remain after {point:?} failure, found {leftovers:?}"
        );
    }

    write_atomic(&target, b"{\"version\":2}").unwrap();
    assert_eq!(fs::read(&target).unwrap(), b"{\"version\":2}");
}

#[test]
fn product_store_commit_uncertain_sets_requires_reopen_and_rejects_further_writes_safely() {
    let dir = TempDir::new("store-uncertain");
    {
        let mut store = ProductStore::open(&dir.0).unwrap();
        store
            .transact(|w| w.insert_record("r1".into(), "Initial".into(), RecordOrigin::Note, 0, 100, 0))
            .unwrap();
        assert!(!store.requires_reopen());

        {
            let _guard = arm_fs_fault(FsFaultPoint::StoreDirSync, 0, "injected dir fsync failure");
            let err = store
                .transact(|w| {
                    w.insert_record("r2".into(), "Uncertain".into(), RecordOrigin::Note, 0, 101, 0)
                })
                .expect_err("dir sync fault must yield CommitUncertain");
            assert!(
                matches!(err, StoreError::CommitUncertain(_)),
                "expected CommitUncertain, got {err:?}"
            );
        }

        assert!(
            store.requires_reopen(),
            "requires_reopen must be true after CommitUncertain"
        );
        let follow_up = store
            .transact(|w| {
                w.insert_record("r3".into(), "MustNotWrite".into(), RecordOrigin::Note, 0, 102, 0)
            })
            .expect_err("subsequent writes must fail safely with Unavailable");
        assert!(
            matches!(follow_up, StoreError::Unavailable),
            "expected Unavailable, got {follow_up:?}"
        );
    }

    let reopened = ProductStore::open(&dir.0).expect("disk state must remain valid JSON");
    assert!(!reopened.requires_reopen());
    assert!(reopened.workspace().record("r1").is_some());
    assert!(reopened.workspace().record("r2").is_some());
    assert!(reopened.workspace().record("r3").is_none());
}

#[test]
fn capture_asset_append_fault_forces_early_stop_and_recovers_cleanly_on_retry_in_pure_rust() {
    let dir = TempDir::new("capture-append");
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let now = 1_800_000_100;

    let started = dispatch(
        &mut runtime,
        json!({"type": "start_microphone", "inputId": "fixture", "includeSystem": true}),
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

    let payload = vec![19i16; 160];
    {
        let _guard = arm_fs_fault(
            FsFaultPoint::CaptureAssetAppend,
            0,
            "injected partial PCM write failure",
        );
        let receipt = runtime.ingest_microphone_pcm(MicrophonePcmChunk {
            record_id: &record_id,
            session_id: &session_id,
            lane: "microphone",
            sequence: 0,
            samples: &payload,
            timing: None,
            now,
        });
        assert_eq!(receipt.status, PcmIngestStatus::Rejected);
        assert_eq!(receipt.next_sequence, 0);
    }

    let failed_snap = runtime.snapshot(now);
    assert!(
        failed_snap["error"]
            .as_str()
            .is_some_and(|e| e.contains("injected partial PCM write failure")),
        "expected injected append error in snapshot: {}",
        failed_snap["error"]
    );
    assert_eq!(failed_snap["microphone"]["phase"], "stopping");

    for lane in ["microphone", "system"] {
        let retry = runtime.ingest_microphone_pcm(MicrophonePcmChunk {
            record_id: &record_id,
            session_id: &session_id,
            lane,
            sequence: 0,
            samples: &payload,
            timing: None,
            now,
        });
        assert_eq!(retry.status, PcmIngestStatus::Accepted);
        assert_eq!(retry.next_sequence, 1);
    }

    for lane in ["microphone", "system"] {
        let s = dispatch(
            &mut runtime,
            json!({
                "type": "microphone_stopped",
                "recordId": record_id,
                "sessionId": session_id,
                "lane": lane,
                "sequence": 1
            }),
            now + 1,
        );
        assert!(s["error"].is_null(), "{s}");
    }

    let record = runtime
        .workspace()
        .record(&record_id)
        .expect("recovered recording must persist");
    assert_eq!(record.capture_lanes.len(), 2);
    assert!(
        record
            .capture_lanes
            .iter()
            .any(|l| l.lane == "microphone" && l.interruption.is_some()),
        "microphone lane must preserve forced early stop interruption reason"
    );
    let expected_pcm: Vec<u8> = payload.iter().flat_map(|s| s.to_le_bytes()).collect();
    for lane in &record.capture_lanes {
        let wav = fs::read(
            dir.0
                .join("audio")
                .join(format!("{}.wav", lane.asset_id.as_ref().unwrap())),
        )
        .unwrap();
        assert_eq!(
            &wav[44..],
            expected_pcm.as_slice(),
            "retried append must rewind incomplete bytes cleanly for lane {}",
            lane.lane
        );
    }
}
