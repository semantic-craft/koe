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
fn companion_fields_and_edited_segments_round_trip_and_accept_legacy_json() {
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
            w.set_companion_mode(CompanionRoutingMode::CollarStandby);
            w.record_standby_scratch_file_id(9101);
            w.record_standby_scratch_file_id(9102);
            Ok(())
        })
        .unwrap();
    drop(store);

    let reopened = ProductStore::open(&dir.0).unwrap();
    let ws = reopened.workspace();
    assert!(!ws.ble_auto_connect());
    assert_eq!(ws.companion_mode(), CompanionRoutingMode::CollarStandby);
    assert_eq!(
        ws.standby_scratch_file_ids()
            .iter()
            .copied()
            .collect::<Vec<_>>(),
        vec![9101, 9102]
    );
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
    obj.remove("companion_mode");
    obj.remove("standby_scratch_file_ids");
    fs::write(&json_path, serde_json::to_string(&legacy_val).unwrap()).unwrap();

    let legacy = ProductStore::open(&dir.0).unwrap();
    assert!(legacy.workspace().ble_auto_connect());
    assert_eq!(
        legacy.workspace().companion_mode(),
        CompanionRoutingMode::Disabled
    );
    assert!(legacy.workspace().standby_scratch_file_ids().is_empty());
    drop(legacy);

    let mut bad_mode: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    bad_mode["companion_mode"] = serde_json::json!("bogus_mode");
    fs::write(&json_path, serde_json::to_string(&bad_mode).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));

    let mut bad_scratch: serde_json::Value = serde_json::from_str(&baseline).unwrap();
    bad_scratch["standby_scratch_file_ids"] = serde_json::json!([0]);
    fs::write(&json_path, serde_json::to_string(&bad_scratch).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));
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
