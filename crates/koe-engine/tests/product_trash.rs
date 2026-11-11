use std::collections::BTreeSet;

use koe_engine::domain::SegmentId;
use koe_engine::product::*;

fn source(record_id: &str, ordinal: u32) -> SourceRef {
    SourceRef {
        record_id: record_id.to_string(),
        segment_id: SegmentId::new(ordinal).unwrap(),
    }
}

#[test]
fn accept_transcript_updates_text_and_timestamps_for_same_delivery_id() {
    let mut ws = ProductWorkspace::new();
    ws.insert_record(
        "rec-1".into(),
        "Test".into(),
        RecordOrigin::Bean,
        101,
        1_700_000_000,
        0,
    )
    .unwrap();
    let key = ws
        .begin_analysis("rec-1", AnalysisStage::Transcribing)
        .unwrap();

    let seg_id = ws
        .accept_transcript(&key, "7", "你好", 0, 400, "dashscope")
        .unwrap();
    let rev1 = ws.revision();

    let same_id = ws
        .accept_transcript(&key, "7", "你好世界", 10, 950, "dashscope")
        .unwrap();
    assert_eq!(same_id, seg_id);
    let rev2 = ws.revision();
    assert!(rev2 > rev1);

    let rec = ws.record("rec-1").unwrap();
    let seg = rec.aggregate.spine.get(seg_id).unwrap();
    assert_eq!(seg.text, "你好世界");
    assert_eq!(seg.start_ms, 10);
    assert_eq!(seg.end_ms, 950);
    assert_eq!(rec.aggregate.duration_ms, 950);

    let noop_id = ws
        .accept_transcript(&key, "7", "你好世界", 10, 950, "dashscope")
        .unwrap();
    assert_eq!(noop_id, seg_id);
    assert_eq!(ws.revision(), rev2);
}

#[test]
fn record_retention_from_persisted_rejects_contradictory_and_zero_states() {
    let active = RecordRetention::from_persisted(false, None).unwrap();
    assert_eq!(active, RecordRetention::Active);
    assert!(active.is_live());
    assert!(!active.is_archived());
    assert!(!active.is_trashed());
    assert_eq!(active.trashed_at_ms(), None);
    assert_eq!(active.expires_at_ms(), None);
    assert!(!active.is_expired_at(u64::MAX));

    let archived = RecordRetention::from_persisted(true, None).unwrap();
    assert_eq!(archived, RecordRetention::Archived);
    assert!(archived.is_live());
    assert!(archived.is_archived());
    assert!(!archived.is_trashed());

    let trashed = RecordRetention::from_persisted(false, Some(1_500)).unwrap();
    assert!(!trashed.is_live());
    assert!(!trashed.is_archived());
    assert!(trashed.is_trashed());
    assert_eq!(trashed.trashed_at_ms(), Some(1_500));
    assert_eq!(trashed.expires_at_ms(), Some(1_500 + TRASH_RETENTION_MS));

    assert_eq!(
        RecordRetention::from_persisted(true, Some(1)),
        Err(ProductError::InvalidEvidence)
    );
    assert_eq!(
        RecordRetention::from_persisted(false, Some(0)),
        Err(ProductError::InvalidEvidence)
    );
}

#[test]
fn archive_lock_blocks_trash_and_purge_and_trash_is_idempotent() {
    let mut ws = ProductWorkspace::new();
    ws.insert_record(
        "rec-1".into(),
        "重要复盘".into(),
        RecordOrigin::Bean,
        12,
        1_800_000_000,
        10_000,
    )
    .unwrap();

    ws.set_record_archived("rec-1", true).unwrap();
    assert!(ws.record("rec-1").unwrap().is_archived());
    let rev = ws.revision();
    ws.set_record_archived("rec-1", true).unwrap();
    assert_eq!(ws.revision(), rev);

    assert_eq!(
        ws.trash_record("rec-1", 1_000),
        Err(ProductError::RecordArchived)
    );
    assert_eq!(ws.purge_record("rec-1"), Err(ProductError::RecordArchived));

    ws.set_record_archived("rec-1", false).unwrap();
    assert_eq!(
        ws.record("rec-1").unwrap().retention(),
        RecordRetention::Active
    );
    assert_eq!(
        ws.purge_record("rec-1"),
        Err(ProductError::InvalidTransition)
    );
    assert!(matches!(
        ws.trash_record("rec-1", 0),
        Err(ProductError::InvalidInput(_))
    ));

    let pending_key = ws
        .begin_analysis("rec-1", AnalysisStage::Transcribing)
        .unwrap();
    assert_eq!(ws.trash_record("rec-1", 5_000), Err(ProductError::Busy));
    ws.fail_analysis(&pending_key, "连接中断").unwrap();

    ws.trash_record("rec-1", 5_000).unwrap();
    assert!(ws.record("rec-1").unwrap().is_trashed());
    assert_eq!(
        ws.record("rec-1").unwrap().retention().trashed_at_ms(),
        Some(5_000)
    );

    let trashed_rev = ws.revision();
    ws.trash_record("rec-1", 9_999).unwrap();
    assert_eq!(ws.revision(), trashed_rev);
    assert_eq!(
        ws.record("rec-1").unwrap().retention().trashed_at_ms(),
        Some(5_000)
    );
    assert_eq!(
        ws.set_record_archived("rec-1", true),
        Err(ProductError::RecordTrashed)
    );
}

#[test]
fn soft_delete_hides_from_search_and_ask_while_preserving_reviewed_items_for_restore() {
    let mut ws = ProductWorkspace::new();
    ws.insert_record(
        "rec-a".into(),
        "量子网关会议".into(),
        RecordOrigin::Note,
        0,
        1_800_000_010,
        0,
    )
    .unwrap();
    ws.insert_record(
        "rec-b".into(),
        "供应链打样".into(),
        RecordOrigin::Note,
        0,
        1_800_000_020,
        0,
    )
    .unwrap();
    ws.append_transcript("rec-a", "周五前交付量子加密网关方案", 0, 2_000, "manual")
        .unwrap();
    ws.append_transcript("rec-b", "下周确认包装盒打样排期", 0, 2_000, "manual")
        .unwrap();

    let task_id = ws
        .propose_item(
            ItemKind::Task,
            "交付量子加密网关方案",
            vec![source("rec-a", 1)],
        )
        .unwrap();
    let memory_id = ws
        .propose_item(
            ItemKind::Memory,
            "网关采用双端认证",
            vec![source("rec-a", 1)],
        )
        .unwrap();
    ws.review_item(&task_id, ReviewDecision::Accept).unwrap();
    ws.complete_task(&task_id, true).unwrap();
    ws.review_item(&memory_id, ReviewDecision::Accept).unwrap();

    let inflight = ws
        .begin_ask(SearchScope::All, "量子加密网关", 1_800_000_030)
        .unwrap()
        .unwrap();
    assert_eq!(ws.trash_record("rec-a", 10_000), Err(ProductError::Busy));
    ws.fail_ask(inflight.operation, "网络超时").unwrap();

    ws.set_ask_scope(SearchScope::Record("rec-a".into()))
        .unwrap();
    ws.trash_record("rec-a", 10_000).unwrap();

    assert_eq!(ws.ask_scope(), &SearchScope::All);
    assert!(ws
        .search(&SearchScope::All, "量子加密网关", 10)
        .unwrap()
        .is_empty());
    assert_eq!(
        ws.search(&SearchScope::All, "包装盒打样", 10).unwrap()[0].source,
        source("rec-b", 1)
    );
    assert_eq!(
        ws.search(&SearchScope::Record("rec-a".into()), "量子", 10),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.set_ask_scope(SearchScope::Record("rec-a".into())),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.begin_ask(SearchScope::Record("rec-a".into()), "量子", 1_800_000_040),
        Err(ProductError::RecordTrashed)
    );
    assert!(ws
        .begin_ask(SearchScope::All, "量子加密网关方案", 1_800_000_041)
        .unwrap()
        .is_none());
    assert_eq!(
        ws.resolve_live_source(&source("rec-a", 1)),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.resolve_source(&source("rec-a", 1)).unwrap().quote,
        "周五前交付量子加密网关方案"
    );

    assert_eq!(
        ws.rename_record("rec-a", "改名"),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.append_transcript("rec-a", "新增", 2_000, 3_000, "manual"),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.begin_analysis("rec-a", AnalysisStage::Summarizing),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.add_highlight(source("rec-a", 1)),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.propose_item(ItemKind::Task, "新任务", vec![source("rec-a", 1)]),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.set_segment_speaker(&source("rec-a", 1), Some("张工")),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.finish_capture("rec-a", 5_000, &[500]),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.set_capture_lanes("rec-a", Vec::new()),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.complete_task(&task_id, false),
        Err(ProductError::RecordTrashed)
    );

    let reopened = ProductWorkspace::restore(ws.export_state()).unwrap();
    assert!(reopened.record("rec-a").unwrap().is_trashed());
    assert!(reopened.items()[&task_id].completed);
    assert_eq!(reopened.items()[&memory_id].review, ReviewState::Accepted);

    ws.restore_record("rec-a").unwrap();
    let restored_rev = ws.revision();
    ws.restore_record("rec-a").unwrap();
    assert_eq!(ws.revision(), restored_rev);

    assert_eq!(
        ws.search(&SearchScope::All, "量子加密网关", 10).unwrap()[0].source,
        source("rec-a", 1)
    );
    assert!(ws.items()[&task_id].completed);
    assert_eq!(ws.items()[&memory_id].review, ReviewState::Accepted);
    let ask_after = ws
        .begin_ask(SearchScope::All, "量子加密网关方案", 1_800_000_050)
        .unwrap();
    assert!(ask_after.is_some());
}

#[test]
fn permanent_purge_expiry_and_empty_trash_maintain_restore_totality_and_bean_tombstones() {
    let mut ws = ProductWorkspace::new();
    ws.insert_record(
        "rec-1".into(),
        "架构定稿".into(),
        RecordOrigin::Bean,
        42,
        1_800_000_100,
        4_000,
    )
    .unwrap();
    ws.set_capture_lanes(
        "rec-1",
        vec![
            CaptureLaneRecord {
                lane: "microphone".into(),
                asset_id: Some("rec-1".into()),
                sample_rate: Some(16_000),
                duration_ms: 4_000,
                interruption: None,
                timeline: Vec::new(),
            },
            CaptureLaneRecord {
                lane: "system".into(),
                asset_id: Some("rec-1-system".into()),
                sample_rate: Some(16_000),
                duration_ms: 4_000,
                interruption: None,
                timeline: Vec::new(),
            },
        ],
    )
    .unwrap();
    ws.insert_record(
        "rec-2".into(),
        "硬件联调".into(),
        RecordOrigin::Bean,
        77,
        1_800_000_200,
        3_000,
    )
    .unwrap();
    ws.insert_record(
        "rec-3".into(),
        "发布节奏".into(),
        RecordOrigin::Note,
        0,
        1_800_000_300,
        0,
    )
    .unwrap();

    ws.append_transcript("rec-1", "发布计划先锁死纯领域边界", 0, 2_000, "asr")
        .unwrap();
    ws.append_transcript("rec-2", "蓝牙重连间隔设为五秒", 0, 2_000, "asr")
        .unwrap();
    ws.append_transcript("rec-3", "发布计划定在下周三灰度", 0, 2_000, "manual")
        .unwrap();

    let single_item = ws
        .propose_item(ItemKind::Task, "锁死纯领域边界", vec![source("rec-1", 1)])
        .unwrap();
    let shared_item = ws
        .propose_item(
            ItemKind::Memory,
            "发布计划节奏与边界",
            vec![source("rec-1", 1), source("rec-3", 1)],
        )
        .unwrap();

    let fp = "a".repeat(64);
    ws.finish_migration(MigrationReceipt {
        fingerprint: fp.clone(),
        archive: format!("legacy-imports/{fp}"),
        record_ids: vec!["rec-1".into(), "rec-3".into()],
        pending: vec!["raw.bin".into()],
        summaries: vec![
            ImportedSummary {
                record_id: "rec-1".into(),
                slot: "summary".into(),
                text: "旧版架构摘要".into(),
            },
            ImportedSummary {
                record_id: "rec-3".into(),
                slot: "summary".into(),
                text: "旧版发布摘要".into(),
            },
        ],
    })
    .unwrap();

    let ask_both = ws
        .begin_ask(SearchScope::All, "发布计划", 1_800_000_400)
        .unwrap()
        .unwrap();
    assert_eq!(ask_both.evidence.len(), 2);
    ws.complete_ask(ask_both.operation, "先锁死边界 [S1] 再灰度 [S2]")
        .unwrap();

    let ask_single = ws
        .begin_ask(
            SearchScope::Record("rec-1".into()),
            "纯领域边界",
            1_800_000_410,
        )
        .unwrap()
        .unwrap();
    ws.complete_ask(ask_single.operation, "[S1]").unwrap();

    let referenced = ws.referenced_audio_filenames();
    assert!(referenced.contains("rec-1.wav"));
    assert!(referenced.contains("rec-1.opus"));
    assert!(referenced.contains("rec-1-system.wav"));
    assert!(referenced.contains("rec-2.wav"));

    ws.trash_record("rec-1", 50_000).unwrap();
    let receipt = ws.purge_record("rec-1").unwrap();
    assert_eq!(receipt.purged_record_ids, BTreeSet::from(["rec-1".into()]));
    let surviving_audio = ws.referenced_audio_filenames();
    assert!(!surviving_audio.contains("rec-1.wav"));
    assert!(!surviving_audio.contains("rec-1.opus"));
    assert!(!surviving_audio.contains("rec-1-system.wav"));
    assert!(surviving_audio.contains("rec-2.wav"));
    assert!(ws.is_bean_file_purged(42));
    assert!(!ws.is_bean_file_purged(0));
    assert!(!ws.items().contains_key(&single_item));
    assert_eq!(ws.items()[&shared_item].sources, vec![source("rec-3", 1)]);
    assert_eq!(ws.migrations()[0].record_ids, vec!["rec-3".to_string()]);
    assert_eq!(ws.migrations()[0].summaries.len(), 1);
    assert_eq!(ws.migrations()[0].summaries[0].record_id, "rec-3");

    let msg_both = &ws.ask_session().messages[1];
    assert_eq!(msg_both.sources.len(), 1);
    assert_eq!(msg_both.sources[0].label, "S1");
    assert_eq!(msg_both.sources[0].source.recording_key, "rec-3");
    assert!(msg_both.text.contains("[S1]"));
    assert!(!msg_both.text.contains("[S2]"));
    assert!(msg_both.grounded);

    let msg_stripped = &ws.ask_session().messages[3];
    assert!(msg_stripped.sources.is_empty());
    assert!(!msg_stripped.text.trim().is_empty());
    assert!(!msg_stripped.text.contains("[S1]"));
    assert!(!msg_stripped.grounded);

    let reopened_after_purge = ProductWorkspace::restore(ws.export_state()).unwrap();
    assert!(reopened_after_purge.is_bean_file_purged(42));

    ws.insert_record(
        "rec-42-redownload".into(),
        "显式重拉".into(),
        RecordOrigin::Bean,
        42,
        1_800_000_500,
        1_000,
    )
    .unwrap();
    assert!(!ws.is_bean_file_purged(42));
    ws.trash_record("rec-42-redownload", 60_000).unwrap();
    ws.purge_record("rec-42-redownload").unwrap();
    assert!(ws.is_bean_file_purged(42));
    ws.clear_purged_bean_file_id(42);
    assert!(!ws.is_bean_file_purged(42));
    let rev_clear = ws.revision();
    ws.clear_purged_bean_file_id(42);
    assert_eq!(ws.revision(), rev_clear);

    let t0 = 200_000;
    ws.trash_record("rec-2", t0).unwrap();
    let expires_at = t0 + TRASH_RETENTION_MS;
    assert!(!ws.has_expired_trash(expires_at - 1));
    let rev_before_expiry = ws.revision();
    let not_yet = ws.purge_expired_trash(expires_at - 1).unwrap();
    assert!(not_yet.purged_record_ids.is_empty());
    assert_eq!(ws.revision(), rev_before_expiry);
    assert!(ws.record("rec-2").is_some());

    assert!(ws.has_expired_trash(expires_at));
    let expired = ws.purge_expired_trash(expires_at).unwrap();
    assert_eq!(expired.purged_record_ids, BTreeSet::from(["rec-2".into()]));
    assert!(ws.is_bean_file_purged(77));
    ProductWorkspace::restore(ws.export_state()).unwrap();

    let rev_idle_trash = ws.revision();
    assert!(ws.empty_trash().unwrap().purged_record_ids.is_empty());
    assert_eq!(ws.revision(), rev_idle_trash);

    ws.trash_record("rec-3", 300_000).unwrap();
    let emptied = ws.empty_trash().unwrap();
    assert_eq!(emptied.purged_record_ids, BTreeSet::from(["rec-3".into()]));
    assert!(ws.records().is_empty());
    assert!(ws.items().is_empty());
    assert!(ws.migrations()[0].record_ids.is_empty());
    assert!(ws.migrations()[0].summaries.is_empty());
    assert!(!ws.ask_session().messages[1].grounded);
    ProductWorkspace::restore(ws.export_state()).unwrap();

    let mut bad_state = ws.export_state();
    bad_state.purged_bean_file_ids.insert(0);
    assert_eq!(
        ProductWorkspace::restore(bad_state),
        Err(ProductError::InvalidEvidence)
    );
}
