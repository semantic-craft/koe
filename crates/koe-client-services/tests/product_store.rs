use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_services::product_store::{ProductStore, StoreError, PRODUCT_WORKSPACE_FILE};
use koe_client_services::recording_assets::reconcile_audio_directory;
use koe_engine::domain::SegmentId;
use koe_engine::product::*;

static NEXT: AtomicU64 = AtomicU64::new(1);
struct Directory(PathBuf);
impl Directory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "koe-product-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Directory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn source(id: &str) -> SourceRef {
    SourceRef {
        record_id: id.into(),
        segment_id: SegmentId::new(1).unwrap(),
    }
}
fn seed(store: &mut ProductStore) {
    store
        .transact(|w| {
            for (id, text) in [("a", "alpha decision"), ("b", "beta report")] {
                w.insert_record(
                    id.into(),
                    id.into(),
                    RecordOrigin::Note,
                    0,
                    1_800_000_000,
                    0,
                )?;
                w.append_transcript(id, text, 0, 1000, "manual")?;
            }
            Ok(())
        })
        .unwrap();
}

#[test]
fn reviews_and_cross_record_sources_survive_reopening() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    seed(&mut store);
    let (task, memory) = store
        .transact(|w| {
            let task = w.propose_item(ItemKind::Task, "send beta report", vec![source("b")])?;
            let memory = w.propose_item(ItemKind::Memory, "alpha decision", vec![source("a")])?;
            w.review_item(&task, ReviewDecision::Accept)?;
            w.complete_task(&task, true)?;
            w.review_item(&memory, ReviewDecision::Accept)?;
            let highlighted =
                w.append_transcript("a", "untimed second sentence", 0, 0, "manual")?;
            w.add_highlight(SourceRef {
                record_id: "a".into(),
                segment_id: highlighted,
            })?;
            let request = w
                .begin_ask(SearchScope::All, "beta", 1_800_000_001)?
                .unwrap();
            w.complete_retrieval(request.operation)?;
            Ok((task, memory))
        })
        .unwrap();
    drop(store);
    let store = ProductStore::open(&dir.0).unwrap();
    let w = store.workspace();
    assert_eq!(w.records().len(), 2);
    assert_eq!(
        w.resolve_source(&source("a")).unwrap().quote,
        "alpha decision"
    );
    assert_eq!(w.resolve_source(&source("b")).unwrap().quote, "beta report");
    assert!(w.items()[&task].completed);
    assert_eq!(w.items()[&memory].review, ReviewState::Accepted);
    assert_eq!(
        w.record("a")
            .unwrap()
            .highlighted_segments
            .iter()
            .copied()
            .collect::<Vec<_>>(),
        vec![SegmentId::new(2).unwrap()]
    );
    assert_eq!(
        w.ask_session().messages.last().unwrap().sources[0]
            .source
            .recording_key,
        "b"
    );
}

#[test]
fn failed_persistence_rolls_back_memory_and_does_not_report_saved() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    seed(&mut store);
    let path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let before = fs::read(&path).unwrap();
    fs::remove_file(&path).unwrap();
    fs::create_dir(&path).unwrap();
    assert!(store
        .transact(|w| w.rename_record("a", "not saved"))
        .is_err());
    assert_eq!(store.workspace().record("a").unwrap().title, "a");
    fs::remove_dir(&path).unwrap();
    fs::write(&path, &before).unwrap();
    drop(store);
    assert_eq!(
        ProductStore::open(&dir.0)
            .unwrap()
            .workspace()
            .record("a")
            .unwrap()
            .title,
        "a"
    );
}

#[test]
fn corrupt_or_unknown_schema_is_never_replaced_with_empty_data() {
    let dir = Directory::new();
    let path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let corrupt = b"{\"version\":999,\"records\":[]}";
    fs::write(&path, corrupt).unwrap();
    assert!(ProductStore::open(&dir.0).is_err());
    assert_eq!(fs::read(&path).unwrap(), corrupt);
}

#[test]
fn restart_preserves_partial_finals_and_marks_unknown_requests_interrupted() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    seed(&mut store);
    let key = store
        .transact(|w| {
            let key = w.begin_analysis("a", AnalysisStage::Transcribing)?;
            w.accept_transcript(&key, "one", "late alpha", 1000, 2000, "asr")?;
            let _ = w.begin_ask(SearchScope::All, "beta", 1_800_000_002)?;
            Ok(key)
        })
        .unwrap();
    drop(store);
    let mut store = ProductStore::open(&dir.0).unwrap();
    assert!(
        matches!(&store.workspace().record("a").unwrap().analysis, AnalysisState::Interrupted { key: current } if current == &key)
    );
    assert_eq!(
        store.workspace().record("a").unwrap().aggregate.spine.len(),
        2
    );
    assert!(store.workspace().pending_ask().is_none());
    assert!(store
        .transact(|w| w.accept_transcript(&key, "two", "stale", 2000, 3000, "asr"))
        .is_err());
}

#[test]
fn only_one_writer_can_open_the_same_workspace() {
    let dir = Directory::new();
    let first = ProductStore::open(&dir.0).unwrap();
    assert!(ProductStore::open(&dir.0).is_err());
    drop(first);
    assert!(ProductStore::open(&dir.0).is_ok());
}

#[test]
fn changed_inflight_evidence_does_not_make_the_store_unreadable() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    store
        .transact(|w| {
            w.insert_record("a".into(), "a".into(), RecordOrigin::Bean, 1, 100, 0)?;
            let key = w.begin_analysis("a", AnalysisStage::Transcribing)?;
            w.accept_transcript(&key, "one", "alpha first", 0, 1000, "asr")?;
            let request = w.begin_ask(SearchScope::All, "alpha", 100)?.unwrap();
            w.accept_transcript(&key, "one", "alpha revised", 0, 1000, "asr")?;
            assert_eq!(
                w.complete_ask(request.operation, "alpha first [S1]"),
                Err(ProductError::StaleRequest)
            );
            Ok(())
        })
        .unwrap();
    drop(store);
    let store =
        ProductStore::open(&dir.0).expect("a legitimate in-flight edit must remain recoverable");
    assert_eq!(
        store
            .workspace()
            .resolve_source(&source("a"))
            .unwrap()
            .quote,
        "alpha revised"
    );
    assert!(store.workspace().pending_ask().is_none());
}

#[test]
fn retention_and_tombstones_round_trip_with_legacy_compatibility_and_corruption_rejection() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    store
        .transact(|w| {
            w.insert_record(
                "arch".into(),
                "Archived".into(),
                RecordOrigin::Note,
                0,
                1_800_000_000,
                0,
            )?;
            w.set_record_archived("arch", true)?;
            w.insert_record(
                "trash".into(),
                "Trashed".into(),
                RecordOrigin::Note,
                0,
                1_800_000_001,
                0,
            )?;
            w.trash_record("trash", 77_000)?;
            w.insert_record(
                "bean-gone".into(),
                "Bean".into(),
                RecordOrigin::Bean,
                42,
                1_800_000_002,
                1_000,
            )?;
            w.trash_record("bean-gone", 78_000)?;
            w.purge_record("bean-gone")?;
            Ok(())
        })
        .unwrap();
    drop(store);

    let reopened = ProductStore::open(&dir.0).unwrap();
    let ws = reopened.workspace();
    assert!(ws.record("arch").unwrap().is_archived());
    assert!(ws.record("trash").unwrap().is_trashed());
    assert_eq!(
        ws.record("trash").unwrap().retention().trashed_at_ms(),
        Some(77_000)
    );
    assert!(ws.is_bean_file_purged(42));
    drop(reopened);

    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let baseline_raw = fs::read_to_string(&json_path).unwrap();

    let mut legacy_val: serde_json::Value = serde_json::from_str(&baseline_raw).unwrap();
    legacy_val
        .as_object_mut()
        .unwrap()
        .remove("purged_bean_file_ids");
    for rec in legacy_val["records"].as_array_mut().unwrap() {
        let obj = rec.as_object_mut().unwrap();
        obj.remove("archived");
        obj.remove("trashed_at_ms");
    }
    fs::write(&json_path, serde_json::to_string(&legacy_val).unwrap()).unwrap();
    let legacy_store = ProductStore::open(&dir.0).unwrap();
    assert_eq!(
        legacy_store.workspace().record("arch").unwrap().retention(),
        RecordRetention::Active
    );
    assert_eq!(
        legacy_store
            .workspace()
            .record("trash")
            .unwrap()
            .retention(),
        RecordRetention::Active
    );
    assert!(legacy_store.workspace().purged_bean_file_ids().is_empty());
    drop(legacy_store);

    let mut contradictory: serde_json::Value = serde_json::from_str(&baseline_raw).unwrap();
    contradictory["records"][0]["archived"] = serde_json::Value::Bool(true);
    contradictory["records"][0]["trashed_at_ms"] = serde_json::Value::from(100u64);
    fs::write(&json_path, serde_json::to_string(&contradictory).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));

    let mut zero_trash: serde_json::Value = serde_json::from_str(&baseline_raw).unwrap();
    zero_trash["records"][0]["archived"] = serde_json::Value::Bool(false);
    zero_trash["records"][0]["trashed_at_ms"] = serde_json::Value::from(0u64);
    fs::write(&json_path, serde_json::to_string(&zero_trash).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));

    let mut zero_tombstone: serde_json::Value = serde_json::from_str(&baseline_raw).unwrap();
    zero_tombstone["purged_bean_file_ids"] = serde_json::json!([0]);
    fs::write(&json_path, serde_json::to_string(&zero_tombstone).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));
}

#[test]
fn reconcile_audio_directory_unlinks_only_unreferenced_regular_wav_and_opus_files() {
    let dir = Directory::new();
    assert_eq!(
        reconcile_audio_directory(&dir.0, &BTreeSet::new()).unwrap(),
        0
    );

    let audio_dir = dir.0.join("audio");
    fs::create_dir_all(&audio_dir).unwrap();
    fs::write(audio_dir.join("keep.wav"), b"wav-keep").unwrap();
    fs::write(audio_dir.join("keep.opus"), b"opus-keep").unwrap();
    fs::write(audio_dir.join("orphan.wav"), b"wav-orphan").unwrap();
    fs::write(audio_dir.join("orphan.opus"), b"opus-orphan").unwrap();
    fs::write(audio_dir.join("mic-live.capture"), b"staging").unwrap();
    fs::create_dir(audio_dir.join("nested.wav")).unwrap();

    let external_target = dir.0.join("external.wav");
    fs::write(&external_target, b"outside").unwrap();
    #[cfg(unix)]
    std::os::unix::fs::symlink(&external_target, audio_dir.join("symlink.wav")).unwrap();

    let retained = BTreeSet::from(["keep.wav".to_string(), "keep.opus".to_string()]);
    let removed = reconcile_audio_directory(&dir.0, &retained).unwrap();
    assert_eq!(removed, 2);

    assert!(audio_dir.join("keep.wav").exists());
    assert!(audio_dir.join("keep.opus").exists());
    assert!(!audio_dir.join("orphan.wav").exists());
    assert!(!audio_dir.join("orphan.opus").exists());
    assert!(audio_dir.join("mic-live.capture").exists());
    assert!(audio_dir.join("nested.wav").is_dir());
    assert!(external_target.exists());
    #[cfg(unix)]
    assert!(fs::symlink_metadata(audio_dir.join("symlink.wav")).is_ok());

    assert_eq!(reconcile_audio_directory(&dir.0, &retained).unwrap(), 0);
}
