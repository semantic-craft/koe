#![allow(clippy::unwrap_used, clippy::expect_used)]

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
fn live_minutes_and_independent_paid_requests_survive_reopen_without_retry() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    seed(&mut store);
    let (asr, live) = store.transact(|w| {
        let asr = w.begin_analysis("a", AnalysisStage::Transcribing)?;
        let live = w.begin_live_summary("a")?;
        let snapshot = w.record("a").unwrap().aggregate.spine.clone();
        let minutes = koe_engine::minutes::parse_meeting_minutes_json(r#"{"schemaVersion":2,"title":"alpha","overview":"alpha decision","topics":[{"text":"alpha","summary":"alpha decision","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}"#, &snapshot).unwrap();
        w.complete_live_summary(&live, &snapshot, minutes)?;
        w.accept_transcript(&asr, "next", "alpha continues", 1000, 2000, "asr")?;
        let live = w.begin_live_summary("a")?;
        Ok((asr, live))
    }).unwrap();
    drop(store);
    let mut store = ProductStore::open(&dir.0).unwrap();
    let record = store.workspace().record("a").unwrap();
    assert_eq!(record.analysis, AnalysisState::Interrupted { key: asr });
    assert_eq!(
        record.live_summary,
        AnalysisState::Interrupted { key: live.clone() }
    );
    assert!(record.aggregate.minutes.is_some());
    assert!(record.is_minutes_stale());
    assert!(store.workspace().items().is_empty());
    let next = store.transact(|w| w.begin_live_summary("a")).unwrap();
    assert!(next.attempt > live.attempt);
    store
        .transact(|w| w.fail_live_summary(&next, "known failure"))
        .unwrap();
    drop(store);
    let path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let mut raw: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    for record in raw["records"].as_array_mut().unwrap() {
        record.as_object_mut().unwrap().remove("live_summary");
    }
    fs::write(&path, serde_json::to_vec(&raw).unwrap()).unwrap();
    let store = ProductStore::open(&dir.0).unwrap();
    assert_eq!(
        store.workspace().record("a").unwrap().live_summary,
        AnalysisState::Idle
    );
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

#[test]
fn edited_segments_stale_minutes_and_legacy_v1_records_round_trip_cleanly() {
    use koe_engine::minutes::parse_meeting_minutes_json;

    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    let s1 = SourceRef {
        record_id: "m1".into(),
        segment_id: SegmentId::new(1).unwrap(),
    };
    let s2 = SourceRef {
        record_id: "m1".into(),
        segment_id: SegmentId::new(2).unwrap(),
    };

    store
        .transact(|w| {
            w.insert_record(
                "m1".into(),
                "架构例会".into(),
                RecordOrigin::Bean,
                9,
                1_800_000_100,
                10_000,
            )?;
            w.append_transcript("m1", "西卡达模块按80%灰度上线。", 0, 4_000, "qwen")?;
            w.append_transcript("m1", "下周复核监控面板。", 4_000, 8_000, "qwen")?;
            w.set_segment_speaker(&s1, Some("发言人 1："))?;
            w.set_segment_speaker(&s2, Some("发言人 2："))?;
            let key = w.begin_analysis("m1", AnalysisStage::Summarizing)?;
            let mins = parse_meeting_minutes_json(
                r#"{"schemaVersion":2,"title":"架构例会","overview":"按80%灰度上线","topics":[{"text":"灰度上线","summary":"发言人 1 确认按80%灰度上线","sources":["S1"]}],"decisions":[{"text":"按80%灰度上线","speaker":"发言人 1","sources":["S1"]}],"actions":[{"text":"下周复核监控面板","owner":"发言人 2","sources":["S2"]}],"questions":[],"terms":[{"name":"Cicada","note":"实时双语引擎","heard":["西卡达"],"sources":["S1"]}],"reviewItems":[]}"#,
                &w.record("m1").unwrap().aggregate.spine,
            )
            .unwrap();
            w.complete_summary(&key, mins)?;
            w.edit_segment_text(&s1, "Cicada 模块按85%灰度上线。")?;
            w.rename_speaker("m1", "发言人 1", "张工")?;
            Ok(())
        })
        .unwrap();
    drop(store);

    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let saved_raw = fs::read_to_string(&json_path).unwrap();
    let saved_val: serde_json::Value = serde_json::from_str(&saved_raw).unwrap();
    assert_eq!(
        saved_val["records"][0]["segments"][0]["original_text"].as_str(),
        Some("西卡达模块按80%灰度上线。")
    );
    assert!(saved_val["records"][0]["segments"][1]
        .get("original_text")
        .is_none());
    assert!(saved_val["records"][0]["minutes_revision"].is_u64());

    let reopened = ProductStore::open(&dir.0).unwrap();
    let rec = reopened.workspace().record("m1").unwrap();
    assert!(rec.is_minutes_stale());
    let seg0 = &rec.aggregate.spine.segments()[0];
    assert!(seg0.is_edited());
    assert_eq!(seg0.text, "Cicada 模块按85%灰度上线。");
    assert_eq!(seg0.asr_text(), "西卡达模块按80%灰度上线。");
    assert_eq!(seg0.speaker.as_deref(), Some("张工"));
    assert_eq!(
        rec.aggregate.minutes.as_ref().unwrap().decisions[0]
            .speaker
            .as_deref(),
        Some("发言人 1")
    );
    drop(reopened);

    let mut store = ProductStore::open(&dir.0).unwrap();
    store
        .transact(|w| {
            w.edit_segment_text(&s1, "西卡达模块按80%灰度上线。")?;
            let key = w.begin_analysis("m1", AnalysisStage::Summarizing)?;
            let fresh_mins = parse_meeting_minutes_json(
                r#"{"schemaVersion":2,"title":"架构例会","overview":"按80%灰度上线","topics":[{"text":"灰度上线","summary":"张工确认按80%灰度上线","sources":["S1"]}],"decisions":[{"text":"按80%灰度上线","speaker":"张工","sources":["S1"]}],"actions":[],"questions":[],"terms":[{"name":"Cicada","note":"实时双语引擎","heard":["西卡达"],"sources":["S1"]}],"reviewItems":[]}"#,
                &w.record("m1").unwrap().aggregate.spine,
            )
            .unwrap();
            w.complete_summary(&key, fresh_mins)?;
            Ok(())
        })
        .unwrap();
    drop(store);

    let fresh_raw = fs::read_to_string(&json_path).unwrap();
    let mut legacy_val: serde_json::Value = serde_json::from_str(&fresh_raw).unwrap();
    legacy_val["records"][0]
        .as_object_mut()
        .unwrap()
        .remove("minutes_revision");
    assert!(legacy_val["records"][0]["segments"][0]
        .get("original_text")
        .is_none());
    fs::write(&json_path, serde_json::to_string(&legacy_val).unwrap()).unwrap();

    let legacy_reopened = ProductStore::open(&dir.0).unwrap();
    let legacy_rec = legacy_reopened.workspace().record("m1").unwrap();
    assert!(!legacy_rec.is_minutes_stale());
    assert_eq!(
        legacy_rec.minutes_revision(),
        Some(legacy_rec.content_revision)
    );
    drop(legacy_reopened);

    let mut redundant_orig: serde_json::Value = serde_json::from_str(&fresh_raw).unwrap();
    redundant_orig["records"][0]["segments"][0]["text"] = serde_json::Value::String("foo".into());
    redundant_orig["records"][0]["segments"][0]["original_text"] =
        serde_json::Value::String("foo ".into());
    redundant_orig["records"][0]["minutes"] = serde_json::Value::Null;
    redundant_orig["records"][0]
        .as_object_mut()
        .unwrap()
        .remove("minutes_revision");
    redundant_orig["records"][0]["analysis"] = serde_json::json!({"state": "idle"});
    redundant_orig["records"][0]["segments"][0]["speaker"] =
        serde_json::Value::String("发言人 1：".into());
    redundant_orig["records"][0]["segments"][1]["speaker"] =
        serde_json::Value::String(format!("{}：\t", "长".repeat(48)));
    fs::write(&json_path, serde_json::to_string(&redundant_orig).unwrap()).unwrap();

    let mut healed_store = ProductStore::open(&dir.0).unwrap();
    let healed_seg0 = &healed_store
        .workspace()
        .record("m1")
        .unwrap()
        .aggregate
        .spine
        .segments()[0];
    assert!(!healed_seg0.is_edited());
    assert_eq!(healed_seg0.original_text, None);
    assert_eq!(healed_seg0.speaker.as_deref(), Some("发言人 1"));
    let healed_seg1 = &healed_store
        .workspace()
        .record("m1")
        .unwrap()
        .aggregate
        .spine
        .segments()[1];
    assert_eq!(
        healed_seg1.speaker.as_deref(),
        Some("长".repeat(MAX_SPEAKER_NAME_CHARS).as_str())
    );
    healed_store
        .transact(|w| w.rename_speaker("m1", "发言人 1：", "张工"))
        .unwrap();
    assert_eq!(
        healed_store
            .workspace()
            .record("m1")
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .speaker
            .as_deref(),
        Some("张工")
    );
    drop(healed_store);

    let mut orphan_min_rev: serde_json::Value = serde_json::from_str(&fresh_raw).unwrap();
    orphan_min_rev["records"][0]["minutes"] = serde_json::Value::Null;
    orphan_min_rev["records"][0]["analysis"] = serde_json::json!({"state": "idle"});
    fs::write(&json_path, serde_json::to_string(&orphan_min_rev).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));
}

#[test]
fn rename_speaker_keeps_near_cap_minutes_immutable_without_corrupting_numbers_or_bricking_open() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    let s1 = SourceRef {
        record_id: "m-cap".into(),
        segment_id: koe_engine::domain::SegmentId::new(1).unwrap(),
    };
    let padding = "稳".repeat(19_650);
    let overview = format!("{}{padding}", "100%".repeat(50));
    assert!(overview.chars().count() > 19_800 && overview.chars().count() < 20_000);

    store
        .transact(|w| {
            w.insert_record(
                "m-cap".into(),
                "容量与指标评审".into(),
                RecordOrigin::Bean,
                12,
                1_800_000_200,
                10_000,
            )?;
            w.append_transcript("m-cap", "全链路达成 100% 可用率。", 0, 5_000, "qwen")?;
            w.set_segment_speaker(&s1, Some("1"))?;
            let key = w.begin_analysis("m-cap", AnalysisStage::Summarizing)?;
            let raw_mins = serde_json::json!({
                "schemaVersion": 2,
                "title": "1 号议题：100% 可用率",
                "overview": overview,
                "topics": [{"text": "可用率", "summary": "达成 100% 目标", "sources": ["S1"]}],
                "decisions": [{"text": "保持 100% 目标", "speaker": "1", "sources": ["S1"]}],
                "actions": [],
                "questions": [],
                "terms": [],
                "reviewItems": []
            })
            .to_string();
            let mins = koe_engine::minutes::parse_meeting_minutes_json(
                &raw_mins,
                &w.record("m-cap").unwrap().aggregate.spine,
            )
            .unwrap();
            w.complete_summary(&key, mins)?;
            let receipt = w.rename_speaker("m-cap", "1", "Alexandria_Product_Lead")?;
            assert!(matches!(
                receipt.minutes_freshness,
                MinutesFreshness::Stale { .. }
            ));
            Ok(())
        })
        .unwrap();
    drop(store);

    let reopened = ProductStore::open(&dir.0).unwrap();
    let rec = reopened.workspace().record("m-cap").unwrap();
    assert!(rec.is_minutes_stale());
    assert_eq!(
        rec.aggregate.spine.segments()[0].speaker.as_deref(),
        Some("Alexandria_Product_Lead")
    );
    let mins = rec.aggregate.minutes.as_ref().unwrap();
    assert_eq!(mins.overview.matches("100%").count(), 50);
    assert!(!mins.overview.contains("Alexandria_Product_Lead"));
    assert_eq!(mins.decisions[0].speaker.as_deref(), Some("1"));
}

#[test]
fn ble_auto_connect_and_edited_segments_round_trip_and_accept_legacy_json() {
    let dir = Directory::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    seed(&mut store);
    store
        .transact(|w| {
            let minutes = koe_engine::minutes::parse_meeting_minutes_json(
                r#"{"schemaVersion":2,"title":"a","overview":"alpha decision","topics":[{"text":"alpha","summary":"alpha decision","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}"#,
                &w.record("a").unwrap().aggregate.spine,
            )
            .unwrap();
            let key = w.begin_analysis("a", AnalysisStage::Summarizing)?;
            w.complete_summary(&key, minutes)?;
            w.edit_segment_text(&source("a"), "alpha decision edited")?;
            w.set_ble_auto_connect(false);
            Ok(())
        })
        .unwrap();
    drop(store);

    let reopened = ProductStore::open(&dir.0).unwrap();
    let ws = reopened.workspace();
    assert!(!ws.ble_auto_connect());
    assert_eq!(
        ws.resolve_source(&source("a")).unwrap().quote,
        "alpha decision edited"
    );
    assert!(ws.record("a").unwrap().is_minutes_stale());
    drop(reopened);

    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let baseline = fs::read_to_string(&json_path).unwrap();

    let mut legacy_val: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    let obj = legacy_val.as_object_mut().unwrap();
    obj.remove("ble_auto_connect");
    obj.insert(
        "companion_mode".into(),
        serde_json::json!("collar_standby"),
    );
    obj.insert(
        "standby_scratch_file_ids".into(),
        serde_json::json!([0, 9101, 9102]),
    );
    obj.insert(
        "reclaimed_standby_file_ids".into(),
        serde_json::json!([9103]),
    );
    fs::write(&json_path, serde_json::to_string(&legacy_val).unwrap()).unwrap();

    let mut legacy = ProductStore::open(&dir.0).unwrap();
    assert!(legacy.workspace().ble_auto_connect());
    assert!(legacy.workspace().is_bean_file_purged(9101));
    assert!(legacy.workspace().is_bean_file_purged(9102));
    assert!(legacy.workspace().is_bean_file_purged(9103));
    assert!(!legacy.workspace().purged_bean_file_ids().contains(&0));
    legacy
        .transact(|w| {
            w.set_ble_auto_connect(false);
            Ok(())
        })
        .unwrap();
    drop(legacy);

    let resaved: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&json_path).unwrap()).unwrap();
    assert!(resaved.get("companion_mode").is_none());
    assert!(resaved.get("standby_scratch_file_ids").is_none());
    assert!(resaved.get("reclaimed_standby_file_ids").is_none());
    let resaved_purged: Vec<u64> = resaved["purged_bean_file_ids"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_u64().unwrap())
        .collect();
    assert_eq!(resaved_purged, vec![9101, 9102, 9103]);
}

#[test]
fn reopen_heals_persisted_bookmark_exceeding_duration() {
    let dir = Directory::new();
    {
        let mut store = ProductStore::open(&dir.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "live-1794444326-1794444325-32".into(),
                    "Live Meeting".into(),
                    RecordOrigin::Bean,
                    1,
                    1_794_444_325,
                    0,
                )?;
                w.finish_capture("live-1794444326-1794444325-32", 27_660, &[12_000])?;
                w.append_transcript(
                    "live-1794444326-1794444325-32",
                    "audio segment text",
                    0,
                    1000,
                    "manual",
                )?;
                Ok(())
            })
            .unwrap();
    }
    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let baseline = fs::read_to_string(&json_path).unwrap();
    let mut val: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    let record_obj = val["records"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|r| r["id"] == "live-1794444326-1794444325-32")
        .unwrap();
    assert_eq!(record_obj["duration_ms"], 27_660);
    record_obj["bookmarks"] = serde_json::json!([12_000, 27_680]);
    fs::write(&json_path, serde_json::to_string(&val).unwrap()).unwrap();

    let reopened = ProductStore::open(&dir.0).expect("open must succeed and heal bookmarks");
    let record = reopened
        .workspace()
        .record("live-1794444326-1794444325-32")
        .expect("record must be preserved");
    assert_eq!(record.aggregate.duration_ms, 27_660);
    assert_eq!(record.aggregate.bookmarks, vec![12_000, 27_660]);
    assert_eq!(record.aggregate.spine.segments().len(), 1);
}

#[test]
fn zero_duration_preserves_bookmarks_across_reopen_and_subsequent_finish_clamps() {
    let dir = Directory::new();
    {
        let mut store = ProductStore::open(&dir.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "rec-zero".into(),
                    "Zero Duration Meeting".into(),
                    RecordOrigin::Bean,
                    1,
                    1_794_444_325,
                    0,
                )?;
                w.finish_capture("rec-zero", 0, &[12_000, 27_680])?;
                Ok(())
            })
            .unwrap();
    }
    let mut reopened = ProductStore::open(&dir.0).unwrap();
    let record = reopened.workspace().record("rec-zero").unwrap();
    assert_eq!(record.aggregate.duration_ms, 0);
    assert_eq!(record.aggregate.bookmarks, vec![12_000, 27_680]);

    reopened
        .transact(|w| {
            w.finish_capture("rec-zero", 27_660, &[])?;
            Ok(())
        })
        .unwrap();
    let updated = reopened.workspace().record("rec-zero").unwrap();
    assert_eq!(updated.aggregate.duration_ms, 27_660);
    assert_eq!(updated.aggregate.bookmarks, vec![12_000, 27_660]);
}

#[test]
fn persisted_legacy_coarse_place_and_selected_format_load_cleanly_and_omit_on_save() {
    let dir = Directory::new();
    {
        let mut store = ProductStore::open(&dir.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "rec-legacy".into(),
                    "Legacy Record".into(),
                    RecordOrigin::Bean,
                    77,
                    1_794_444_325,
                    15_000,
                )?;
                let seg = w.append_transcript(
                    "rec-legacy",
                    "legacy utterance",
                    0,
                    2_000,
                    "manual",
                )?;
                w.finish_capture("rec-legacy", 15_000, &[4_000])?;
                w.add_highlight(SourceRef {
                    record_id: "rec-legacy".into(),
                    segment_id: seg,
                })?;
                Ok(())
            })
            .unwrap();
    }

    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let mut raw: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&json_path).unwrap()).unwrap();
    assert_eq!(raw["version"], 1);
    let rec_obj = raw["records"][0].as_object_mut().unwrap();
    rec_obj.insert(
        "coarse_place".into(),
        serde_json::Value::String("北京市·海淀区".into()),
    );
    rec_obj.insert(
        "selected_format".into(),
        serde_json::Value::String("decision_memo".into()),
    );
    fs::write(&json_path, serde_json::to_string(&raw).unwrap()).unwrap();

    let mut store = ProductStore::open(&dir.0).unwrap();
    {
        let record = store.workspace().record("rec-legacy").unwrap();
        assert_eq!(record.title, "Legacy Record");
        assert_eq!(record.origin, RecordOrigin::Bean);
        assert_eq!(record.aggregate.file_id, 77);
        assert_eq!(record.aggregate.created_at_epoch_sec, 1_794_444_325);
        assert_eq!(record.aggregate.duration_ms, 15_000);
        assert_eq!(record.aggregate.bookmarks, vec![0, 4_000]);
        assert_eq!(record.aggregate.spine.len(), 1);
        assert_eq!(
            record.aggregate.spine.segments()[0].text,
            "legacy utterance"
        );
        assert_eq!(record.highlighted_segments.len(), 1);
    }

    store
        .transact(|w| w.rename_record("rec-legacy", "Legacy Record Updated"))
        .unwrap();
    drop(store);

    let saved: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&json_path).unwrap()).unwrap();
    let saved_obj = saved["records"][0].as_object().unwrap();
    assert!(!saved_obj.contains_key("coarse_place"));
    assert!(!saved_obj.contains_key("selected_format"));

    let reloaded = ProductStore::open(&dir.0).unwrap();
    let record = reloaded.workspace().record("rec-legacy").unwrap();
    assert_eq!(record.title, "Legacy Record Updated");
    assert_eq!(record.aggregate.file_id, 77);
    assert_eq!(record.aggregate.duration_ms, 15_000);
    assert_eq!(record.aggregate.bookmarks, vec![0, 4_000]);
    assert_eq!(
        record.aggregate.spine.segments()[0].text,
        "legacy utterance"
    );
    assert_eq!(record.highlighted_segments.len(), 1);
}

#[test]
fn record_mode_and_project_roundtrip_and_legacy_fallback_on_reopen() {
    let dir = Directory::new();
    {
        let mut store = ProductStore::open(&dir.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "rec-qn".into(),
                    "闪记项目卡".into(),
                    RecordOrigin::Note,
                    0,
                    1_800_100_000,
                    0,
                )?;
                w.set_record_project("rec-qn", Some("  Koe 工作区  "))?;

                w.insert_record(
                    "rec-meeting".into(),
                    "周会纪要".into(),
                    RecordOrigin::Microphone,
                    0,
                    1_800_100_100,
                    30_000,
                )?;
                w.set_record_mode("rec-meeting", RecordMode::Meeting)?;

                w.insert_record(
                    "rec-allday".into(),
                    "全天分段".into(),
                    RecordOrigin::Microphone,
                    0,
                    1_800_100_300,
                    300_000,
                )?;
                w.group_all_day(
                    "rec-allday",
                    AllDaySegment {
                        run_id: "run-persist".into(),
                        ordinal: 1,
                    },
                )?;
                Ok(())
            })
            .unwrap();
    }

    let reopened = ProductStore::open(&dir.0).unwrap();
    assert_eq!(
        reopened.workspace().record("rec-qn").unwrap().mode,
        RecordMode::QuickNote
    );
    assert_eq!(
        reopened
            .workspace()
            .record("rec-qn")
            .unwrap()
            .project
            .as_deref(),
        Some("Koe 工作区")
    );
    assert_eq!(
        reopened.workspace().record("rec-meeting").unwrap().mode,
        RecordMode::Meeting
    );
    assert_eq!(
        reopened.workspace().record("rec-allday").unwrap().mode,
        RecordMode::AllDay
    );
    drop(reopened);

    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let baseline = fs::read_to_string(&json_path).unwrap();

    let mut legacy_dictation: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    legacy_dictation["companion_mode"] = serde_json::json!("collar_standby");
    for rec in legacy_dictation["records"].as_array_mut().unwrap() {
        if rec["id"] == "rec-qn" {
            rec["mode"] = serde_json::json!("dictation");
        }
    }
    fs::write(
        &json_path,
        serde_json::to_string(&legacy_dictation).unwrap(),
    )
    .unwrap();
    let mut legacy_dictation_store = ProductStore::open(&dir.0).unwrap();
    assert_eq!(
        legacy_dictation_store
            .workspace()
            .record("rec-qn")
            .unwrap()
            .mode,
        RecordMode::QuickNote
    );
    legacy_dictation_store
        .transact(|w| w.set_record_project("rec-qn", Some("Koe 工作区（迁移）")))
        .unwrap();
    drop(legacy_dictation_store);
    let migrated_json: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&json_path).unwrap()).unwrap();
    assert!(migrated_json.get("companion_mode").is_none());
    let migrated_qn = migrated_json["records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|rec| rec["id"] == "rec-qn")
        .unwrap();
    assert_eq!(migrated_qn["mode"], "quick_note");

    let mut legacy_json: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    for rec in legacy_json["records"].as_array_mut().unwrap() {
        let obj = rec.as_object_mut().unwrap();
        obj.remove("mode");
        obj.remove("project");
    }
    fs::write(&json_path, serde_json::to_string(&legacy_json).unwrap()).unwrap();

    let legacy_reopened = ProductStore::open(&dir.0).unwrap();
    assert_eq!(
        legacy_reopened.workspace().record("rec-qn").unwrap().mode,
        RecordMode::QuickNote
    );
    assert!(legacy_reopened
        .workspace()
        .record("rec-qn")
        .unwrap()
        .is_quick_note_inbox());
    assert_eq!(
        legacy_reopened
            .workspace()
            .record("rec-allday")
            .unwrap()
            .mode,
        RecordMode::AllDay
    );
    drop(legacy_reopened);

    let mut bad_mode: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    bad_mode["records"][0]["mode"] = serde_json::json!("bogus_mode");
    fs::write(&json_path, serde_json::to_string(&bad_mode).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));

    let mut bad_project: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    bad_project["records"][0]["project"] =
        serde_json::json!("项".repeat(MAX_PROJECT_NAME_CHARS + 1));
    fs::write(&json_path, serde_json::to_string(&bad_project).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));
}

#[test]
fn corrupt_or_truncated_workspace_json_fails_closed_without_clobbering_disk() {
    let dir = Directory::new();
    {
        let mut store = ProductStore::open(&dir.0).unwrap();
        seed(&mut store);
    }
    let path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let valid_bytes = fs::read(&path).unwrap();
    let truncated = valid_bytes[..valid_bytes.len() / 2].to_vec();
    fs::write(&path, &truncated).unwrap();

    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));
    assert_eq!(fs::read(&path).unwrap(), truncated);

    let corrupt_dir = Directory::new();
    let corrupt_path = corrupt_dir.0.join(PRODUCT_WORKSPACE_FILE);
    let malformed = br#"{"version":1,"revision":7,"records":[{"id":"rec-partial""#;
    fs::write(&corrupt_path, malformed).unwrap();

    assert!(matches!(
        ProductStore::open(&corrupt_dir.0),
        Err(StoreError::InvalidData(_))
    ));
    assert_eq!(fs::read(&corrupt_path).unwrap(), malformed);
}

#[test]
fn leftover_atomic_tmp_file_does_not_prevent_reopen_or_corrupt_workspace() {
    let dir = Directory::new();
    {
        let mut store = ProductStore::open(&dir.0).unwrap();
        seed(&mut store);
        store
            .transact(|w| {
                w.set_ble_auto_connect(false);
                w.add_highlight(source("a"))?;
                Ok(())
            })
            .unwrap();
    }

    let atomic_residue = dir.0.join(format!(".{PRODUCT_WORKSPACE_FILE}.99999.1.tmp"));
    let suffix_residue = dir.0.join(format!("{PRODUCT_WORKSPACE_FILE}.tmp.99999"));
    fs::write(&atomic_residue, br#"{"version":1,"revision":999,"records":["#).unwrap();
    fs::write(&suffix_residue, b"corrupt crash residue").unwrap();

    let mut reopened = ProductStore::open(&dir.0).unwrap();
    assert!(!reopened.workspace().ble_auto_connect());
    assert_eq!(reopened.workspace().records().len(), 2);
    assert_eq!(
        reopened.workspace().resolve_source(&source("a")).unwrap().quote,
        "alpha decision"
    );
    assert!(reopened
        .workspace()
        .record("a")
        .unwrap()
        .highlighted_segments
        .contains(&SegmentId::new(1).unwrap()));

    reopened
        .transact(|w| w.rename_record("a", "alpha durable"))
        .unwrap();
    drop(reopened);

    let verified = ProductStore::open(&dir.0).unwrap();
    assert_eq!(
        verified.workspace().record("a").unwrap().title,
        "alpha durable"
    );
    assert!(!verified.workspace().ble_auto_connect());
}

#[test]
fn historical_schema_corpus_round_trip_is_idempotent() {
    let dir = Directory::new();
    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);

    let minutes_json = serde_json::json!({
        "schemaVersion": 2,
        "title": "历史架构复盘",
        "overview": "确认历史工作区迁移后字段保持幂等。",
        "topics": [{
            "text": "存储兼容",
            "summary": "历史字段自动收敛并保留纪要。",
            "sources": ["S1"]
        }],
        "decisions": [{
            "text": "保留历史纪要并标记待重算",
            "speaker": "发言人 1",
            "sources": ["S1"]
        }],
        "actions": [{
            "text": "周五前完成双轨回放验证",
            "owner": "张工",
            "sources": ["S2"]
        }],
        "questions": [],
        "terms": [],
        "reviewItems": []
    })
    .to_string();

    let provider_json = serde_json::json!({
        "meeting_audio_policy": "local_only",
        "speech_engine": "apple_speech",
        "speech_model_id": null,
        "asr_provider": "qwen",
        "asr_model": DEFAULT_ASR_MODEL,
        "llm_provider": "qwen",
        "enable_thinking": false,
        "qwen_workspace_id": "ws-legacy",
        "model": "qwen-plus",
        "asr_endpoint": DEFAULT_DASHSCOPE_WS_URL,
        "chat_endpoint": "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
        "credential": { "state": "saved", "reference": "cred-qwen-active" },
        "deepseek_credential": { "state": "saved", "reference": "cred-ds-active" },
        "retired_credentials": ["cred-retired-1", "cred-retired-2"],
        "pending_credentials": ["cred-pending-crash"]
    });
    let segments_json = serde_json::json!([
        {
            "id": 1,
            "text": "历史工作区字段迁移后保持幂等。",
            "original_text": "历史工作区字段迁移后保持一致。",
            "start_ms": 0,
            "end_ms": 5_000,
            "language": "zh",
            "provider": "apple",
            "speaker": "发言人 1：",
            "translation": null,
            "target_language": null
        },
        {
            "id": 2,
            "text": "周五前完成双轨回放验证。",
            "start_ms": 5_000,
            "end_ms": 11_000,
            "language": "zh",
            "provider": "apple",
            "speaker": "张工",
            "translation": "Finish dual-lane playback verification by Friday.",
            "target_language": "en"
        }
    ]);
    let lanes_json = serde_json::json!([
        {
            "lane": "microphone",
            "asset_id": "rec-corpus-dual",
            "sample_rate": 16_000u32,
            "duration_ms": 12_000u64,
            "interruption": null,
            "timeline": [
                { "epoch": 0, "start_ns": 0, "sample_offset": 0, "sample_count": 96_000 },
                { "epoch": 1, "start_ns": 6_000_000_000u64, "sample_offset": 96_000, "sample_count": 96_000 }
            ]
        },
        {
            "lane": "system",
            "asset_id": "rec-corpus-dual-system",
            "sample_rate": 48_000u32,
            "duration_ms": 12_000u64,
            "interruption": null,
            "timeline": [
                { "epoch": 0, "start_ns": 0, "sample_offset": 0, "sample_count": 288_000 },
                { "epoch": 1, "start_ns": 6_000_000_000u64, "sample_offset": 288_000, "sample_count": 288_000 }
            ]
        }
    ]);
    let record_json = serde_json::json!({
        "id": "rec-corpus-dual",
        "title": "历史双轨会议",
        "origin": "microphone",
        "mode": "dictation",
        "project": "  核心项目  ",
        "speech_engine": "apple_speech",
        "speech_model_id": null,
        "all_day_run_id": null,
        "all_day_ordinal": null,
        "file_id": 0,
        "created_at": 1_795_000_000u64,
        "duration_ms": 12_000u64,
        "content_revision": 3,
        "minutes_revision": 1,
        "archived": false,
        "trashed_at_ms": null,
        "coarse_place": "上海市·徐汇区",
        "selected_format": "decision_memo",
        "segments": segments_json,
        "minutes": minutes_json,
        "bookmarks": [4_500u64, 18_500u64],
        "highlighted_segments": [1u32],
        "capture_lanes": lanes_json,
        "analysis": { "state": "ready", "input_revision": 1 },
        "live_summary": null,
        "final_keys": { "seg-0": 1 },
        "completed_request": { "record_id": "rec-corpus-dual", "attempt": 1, "input_revision": 1 }
    });
    let corpus = serde_json::json!({
        "version": 1,
        "revision": 9,
        "next_operation": 14,
        "ble_auto_connect": true,
        "companion_mode": "collar_standby",
        "standby_scratch_file_ids": [0, 501],
        "reclaimed_standby_file_ids": [502],
        "purged_bean_file_ids": [401],
        "migrations": [],
        "provider": provider_json,
        "records": [record_json],
        "items": [{
            "id": "item-1",
            "kind": "task",
            "text": "周五前完成双轨回放验证",
            "sources": [{ "record_id": "rec-corpus-dual", "segment_id": 2 }],
            "review": "accepted",
            "completed": false,
            "due": "周五"
        }],
        "ask": {
            "id": "ask-1",
            "created_at": 1_795_000_000u64,
            "messages": [],
            "draft": "",
            "in_flight": false,
            "scope": null,
            "pending": null,
            "last_operation": null
        }
    });
    fs::write(&json_path, serde_json::to_string(&corpus).unwrap()).unwrap();

    let mut store = ProductStore::open(&dir.0).unwrap();
    {
        let ws = store.workspace();
        assert_eq!(ws.purged_bean_file_ids(), &BTreeSet::from([401, 501, 502]));
        let provider = ws.provider_configuration();
        assert_eq!(provider.llm_provider, LlmProvider::DeepSeek);
        assert_eq!(provider.model, DEFAULT_TEXT_MODEL);
        assert_eq!(provider.chat_endpoint, DEFAULT_DEEPSEEK_CHAT_URL);
        assert_eq!(
            provider.credential,
            CredentialBinding::Saved("cred-qwen-active".into())
        );
        assert_eq!(
            provider.deepseek_credential,
            CredentialBinding::Saved("cred-ds-active".into())
        );
        assert_eq!(
            provider.retired_credentials,
            vec!["cred-retired-1".to_string(), "cred-retired-2".to_string()]
        );
        assert_eq!(
            provider.pending_credentials,
            vec!["cred-pending-crash".to_string()]
        );

        let rec = ws.record("rec-corpus-dual").unwrap();
        assert_eq!(rec.mode, RecordMode::QuickNote);
        assert_eq!(rec.project.as_deref(), Some("核心项目"));
        assert!(rec.is_minutes_stale());
        assert!(rec.aggregate.minutes.is_some());
        assert_eq!(rec.aggregate.bookmarks, vec![4_500, 12_000]);
        assert_eq!(rec.capture_lanes.len(), 2);
        assert_eq!(rec.capture_lanes[0].lane, "microphone");
        assert_eq!(rec.capture_lanes[0].timeline.len(), 2);
        assert_eq!(rec.capture_lanes[1].lane, "system");
        assert_eq!(rec.capture_lanes[1].sample_rate, Some(48_000));
        assert_eq!(
            rec.aggregate.spine.segments()[0].speaker.as_deref(),
            Some("发言人 1")
        );
        assert!(rec.aggregate.spine.segments()[0].is_edited());
        assert_eq!(
            rec.aggregate.spine.segments()[1].translation.as_deref(),
            Some("Finish dual-lane playback verification by Friday.")
        );
    }

    store
        .transact(|w| {
            w.set_ble_auto_connect(false);
            Ok(())
        })
        .unwrap();
    let after_commit = store.workspace().clone();
    drop(store);

    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&json_path).unwrap()).unwrap();
    assert!(on_disk.get("companion_mode").is_none());
    assert!(on_disk.get("standby_scratch_file_ids").is_none());
    assert!(on_disk.get("reclaimed_standby_file_ids").is_none());
    let disk_rec = on_disk["records"][0].as_object().unwrap();
    assert!(!disk_rec.contains_key("coarse_place"));
    assert!(!disk_rec.contains_key("selected_format"));
    assert_eq!(disk_rec["bookmarks"], serde_json::json!([4_500, 12_000]));

    let mut reopened = ProductStore::open(&dir.0).unwrap();
    assert_eq!(reopened.workspace(), &after_commit);
    reopened
        .transact(|w| {
            w.set_ble_auto_connect(false);
            Ok(())
        })
        .unwrap();
    let second_disk_raw = fs::read_to_string(&json_path).unwrap();
    drop(reopened);

    let reopened_again = ProductStore::open(&dir.0).unwrap();
    assert_eq!(reopened_again.workspace(), &after_commit);
    assert_eq!(fs::read_to_string(&json_path).unwrap(), second_disk_raw);
}

#[test]
fn koepack_v2_on_disk_round_trip_and_trailing_bytes_rejection() {
    use koe_client_base::write_atomic;
    use koe_client_services::recording_assets::{import_recording, save_audio};
    use koe_engine::hash::sha256_hex;
    use koe_engine::koepack::{
        decode_koepack, MaterialPackError, KOEPACK_FORMAT_NAME, KOEPACK_MAGIC,
    };
    use koe_engine::wav::OpusWave;

    let dir = Directory::new();
    let mut wav_payload = OpusWave::wav_header_with_rate(3200, 16_000).to_vec();
    wav_payload.extend((0..3200usize).map(|i| (i % 251) as u8));
    let audio_hash = sha256_hex(&wav_payload);
    let saved_audio_path = save_audio(&dir.0, "koepack-audio-ref", &wav_payload).unwrap();
    assert_eq!(sha256_hex(&fs::read(&saved_audio_path).unwrap()), audio_hash);

    let sources = vec![
        "季度架构复盘确认端到端加密音频落盘。".to_string(),
        "资料包导入必须拒绝尾部附加字节。".to_string(),
    ];
    let source_hash = sha256_hex(sources.join("\n").as_bytes());
    let minutes_text = serde_json::json!({
        "schemaVersion": 2,
        "title": "季度架构复盘",
        "overview": "端到端落盘与资料包完整性校验。",
        "topics": [{
            "text": "落盘完整性",
            "summary": "校验音频哈希与尾部字节拒绝。",
            "sources": ["S1", "S2"]
        }],
        "decisions": [{
            "text": "严格校验资料包长度",
            "sources": ["S2"]
        }],
        "actions": [],
        "questions": [],
        "terms": [],
        "reviewItems": []
    })
    .to_string();

    let make_manifest = |audio_included: bool| {
        serde_json::json!({
            "format": KOEPACK_FORMAT_NAME,
            "version": 2,
            "exportedAt": "2026-11-20T10:00:00Z",
            "material": {
                "contentHash": audio_hash,
                "title": "季度架构复盘",
                "source": "device",
                "deviceFileId": 19,
                "recordedAt": "2026-11-20T09:00:00Z",
                "audioExtension": ".wav"
            },
            "minutes": {
                "current": {
                    "text": minutes_text,
                    "sourceHash": source_hash,
                    "model": "deepseek-flash",
                    "instruction": "整理季度复盘纪要",
                    "sources": sources,
                    "createdAt": "2026-11-20T09:30:00Z",
                    "templateId": "minutes",
                    "templateVersion": 4,
                    "isDraft": false
                },
                "history": [{
                    "text": minutes_text,
                    "sourceHash": source_hash,
                    "model": "deepseek-flash",
                    "instruction": "初版纪要",
                    "sources": sources,
                    "createdAt": "2026-11-20T09:15:00Z",
                    "templateId": "minutes",
                    "templateVersion": 4,
                    "isDraft": true
                }]
            },
            "audio": { "included": audio_included }
        })
        .to_string()
    };

    let manifest_json = make_manifest(false);
    let mut artifact = format!("{KOEPACK_MAGIC}\n{}\n", manifest_json.len()).into_bytes();
    artifact.extend_from_slice(manifest_json.as_bytes());

    let pack_path = dir.0.join("quarterly-review.koepack");
    write_atomic(&pack_path, &artifact).unwrap();

    let disk_bytes = fs::read(&pack_path).unwrap();
    let decoded = decode_koepack(&disk_bytes).unwrap();
    assert_eq!(decoded.version, 2);
    assert_eq!(decoded.material.title, "季度架构复盘");
    assert_eq!(decoded.material.content_hash, audio_hash);
    assert_eq!(decoded.material.device_file_id, Some(19));
    let decoded_minutes = decoded.minutes.as_ref().unwrap();
    assert_eq!(decoded_minutes.current.sources, sources);
    assert_eq!(decoded_minutes.history.len(), 1);

    let imported = import_recording(&dir.0, &pack_path, 1_800_000_000).unwrap();
    assert_eq!(imported.title, "季度架构复盘");
    assert_eq!(imported.paragraphs, sources);
    assert!(imported.minutes.is_some());
    assert!(!imported.has_audio);

    let mut tampered = disk_bytes;
    tampered.push(0x00);
    write_atomic(&pack_path, &tampered).unwrap();
    assert_eq!(
        decode_koepack(&fs::read(&pack_path).unwrap()),
        Err(MaterialPackError::TrailingBytes)
    );
    assert!(import_recording(&dir.0, &pack_path, 1_800_000_000).is_err());

    let audio_manifest = make_manifest(true);
    let mut audio_pack = format!("{KOEPACK_MAGIC}\n{}\n", audio_manifest.len()).into_bytes();
    audio_pack.extend_from_slice(audio_manifest.as_bytes());
    let audio_pack_path = dir.0.join("with-audio.koepack");
    write_atomic(&audio_pack_path, &audio_pack).unwrap();
    assert_eq!(
        decode_koepack(&fs::read(&audio_pack_path).unwrap()),
        Err(MaterialPackError::AudioCarrierUnsupported)
    );
}
