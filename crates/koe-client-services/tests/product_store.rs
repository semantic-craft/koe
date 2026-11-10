use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_services::product_store::{ProductStore, PRODUCT_WORKSPACE_FILE};
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
