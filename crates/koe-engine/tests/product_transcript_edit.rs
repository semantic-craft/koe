#![allow(clippy::unwrap_used, clippy::expect_used)]

use koe_engine::domain::{SegmentId, UtteranceSpine};
use koe_engine::minutes::parse_meeting_minutes_json;
use koe_engine::product::*;

fn source(record_id: &str, ordinal: u32) -> SourceRef {
    SourceRef {
        record_id: record_id.to_string(),
        segment_id: SegmentId::new(ordinal).unwrap(),
    }
}

fn seeded_workspace() -> ProductWorkspace {
    let mut ws = ProductWorkspace::new();
    ws.insert_record(
        "rec-1".into(),
        "技术评审".into(),
        RecordOrigin::Bean,
        7,
        1_800_000_000,
        15_000,
    )
    .unwrap();
    ws.append_transcript(
        "rec-1",
        "西卡达模块按70%灰度推进。",
        1_000,
        4_500,
        "qwen-asr",
    )
    .unwrap();
    ws.append_transcript("rec-1", "周五前完成压测验收。", 4_500, 8_000, "qwen-asr")
        .unwrap();
    ws.append_transcript("rec-1", "确认网关告警阈值。", 8_000, 12_000, "qwen-asr")
        .unwrap();
    ws
}

#[test]
fn repeated_segment_edits_preserve_asr_provenance_citations_and_collapse_on_revert() {
    let mut ws = seeded_workspace();
    let s1 = source("rec-1", 1);
    let task_id = ws
        .propose_item(ItemKind::Task, "推进灰度方案", vec![s1.clone()])
        .unwrap();
    let ask_req = ws
        .begin_ask(SearchScope::All, "灰度推进", 1_800_000_010)
        .unwrap()
        .unwrap();
    ws.complete_ask(ask_req.operation, "按70%灰度推进 [S1]")
        .unwrap();

    let seg_before = ws.record("rec-1").unwrap().aggregate.spine.segments()[0].clone();
    assert!(!seg_before.is_edited());
    assert_eq!(seg_before.asr_text(), "西卡达模块按70%灰度推进。");
    assert_eq!(seg_before.original_text, None);

    let first_edit = ws
        .edit_segment_text(&s1, "  Cicada 模块按 80% 灰度推进。  ")
        .unwrap();
    assert_eq!(first_edit.updated_segments, 1);
    assert_eq!(first_edit.minutes_freshness, MinutesFreshness::Absent);

    let rev_after_first = ws.record("rec-1").unwrap().content_revision;
    let ws_rev_after_first = ws.revision();
    let idempotent = ws
        .edit_segment_text(&s1, "Cicada 模块按 80% 灰度推进。")
        .unwrap();
    assert_eq!(idempotent.updated_segments, 0);
    assert_eq!(idempotent.content_revision, rev_after_first);
    assert_eq!(ws.revision(), ws_rev_after_first);

    let second_edit = ws
        .edit_segment_text(&s1, "Cicada 模块按 85% 灰度推进。")
        .unwrap();
    assert_eq!(second_edit.updated_segments, 1);
    assert_eq!(second_edit.content_revision, rev_after_first + 1);

    let seg_after = &ws.record("rec-1").unwrap().aggregate.spine.segments()[0];
    assert_eq!(seg_after.id, seg_before.id);
    assert_eq!(seg_after.start_ms, 1_000);
    assert_eq!(seg_after.end_ms, 4_500);
    assert!(seg_after.is_edited());
    assert_eq!(seg_after.text, "Cicada 模块按 85% 灰度推进。");
    assert_eq!(seg_after.asr_text(), "西卡达模块按70%灰度推进。");
    assert_eq!(
        seg_after.original_text.as_deref(),
        Some("西卡达模块按70%灰度推进。")
    );

    let item_evidence = ws.resolve_source(&ws.items()[&task_id].sources[0]).unwrap();
    assert_eq!(item_evidence.quote, "Cicada 模块按 85% 灰度推进。");
    assert_eq!(item_evidence.start_ms, 1_000);

    let ask_msg = ws.ask_session().messages.last().unwrap();
    let ask_source = SourceRef {
        record_id: ask_msg.sources[0].source.recording_key.clone(),
        segment_id: ask_msg.sources[0].source.segment_id,
    };
    assert_eq!(
        ws.resolve_source(&ask_source).unwrap().quote,
        "Cicada 模块按 85% 灰度推进。"
    );

    let revert = ws.edit_segment_text(&s1, "西卡达模块按70%灰度推进。").unwrap();
    assert_eq!(revert.updated_segments, 1);
    let seg_reverted = &ws.record("rec-1").unwrap().aggregate.spine.segments()[0];
    assert!(!seg_reverted.is_edited());
    assert_eq!(seg_reverted.original_text, None);
    assert_eq!(seg_reverted.asr_text(), "西卡达模块按70%灰度推进。");

    assert!(matches!(
        ws.edit_segment_text(&s1, "   "),
        Err(ProductError::InvalidInput(_))
    ));
    assert!(matches!(
        ws.edit_segment_text(&s1, "含有\u{0007}控制字符"),
        Err(ProductError::InvalidInput(_))
    ));
    assert!(matches!(
        ws.edit_segment_text(&s1, &"字".repeat(MAX_SEGMENT_TEXT_CHARS + 1)),
        Err(ProductError::InvalidInput(_))
    ));
    assert_eq!(
        ws.edit_segment_text(&source("rec-1", 99), "合法文本"),
        Err(ProductError::SegmentNotFound)
    );

    let mut live_spine = UtteranceSpine::new("stream-1");
    let live_id = live_spine
        .accept_final(koe_engine::FinalUtterance {
            session: "stream-1",
            stream_key: "k1",
            text: "初稿文本",
            source_language: "zh",
            translation: None,
            target_language: None,
            provider: "qwen",
        })
        .unwrap();
    assert!(live_spine.update_segment_text(live_id, "人工暂改"));
    assert_eq!(
        live_spine.get(live_id).unwrap().original_text.as_deref(),
        Some("初稿文本")
    );
    live_spine.accept_final(koe_engine::FinalUtterance {
        session: "stream-1",
        stream_key: "k1",
        text: "初稿文本",
        source_language: "zh",
        translation: None,
        target_language: None,
        provider: "qwen",
    });
    assert_eq!(live_spine.get(live_id).unwrap().original_text, None);

    assert!(live_spine.update_segment_text(live_id, "二次人工暂改"));
    assert_eq!(
        live_spine.get(live_id).unwrap().original_text.as_deref(),
        Some("初稿文本")
    );
    assert!(live_spine.update_segment(live_id, "初稿文本", 100, 900));
    assert_eq!(live_spine.get(live_id).unwrap().original_text, None);
    assert!(live_spine.restore_original_text(live_id, "初稿文本   ".to_string()));
    assert_eq!(live_spine.get(live_id).unwrap().original_text, None);
    assert!(live_spine.restore_original_text(live_id, "   ".to_string()));
    assert_eq!(live_spine.get(live_id).unwrap().original_text, None);
}

#[test]
fn speaker_attribution_normalizes_colons_validates_bounds_and_merges_batches() {
    let mut ws = seeded_workspace();
    let s1 = source("rec-1", 1);
    let s2 = source("rec-1", 2);
    let s3 = source("rec-1", 3);

    let r1 = ws.set_segment_speaker(&s1, Some("  发言人 1：: ")).unwrap();
    assert_eq!(r1.updated_segments, 1);
    assert_eq!(
        ws.record("rec-1").unwrap().aggregate.spine.segments()[0]
            .speaker
            .as_deref(),
        Some("发言人 1")
    );

    let rev_before = ws.record("rec-1").unwrap().content_revision;
    let idem = ws.set_segment_speaker(&s1, Some("发言人 1:")).unwrap();
    assert_eq!(idem.updated_segments, 0);
    assert_eq!(idem.content_revision, rev_before);

    ws.set_segment_speaker(&s2, Some("发言人 2：")).unwrap();
    ws.set_segment_speaker(&s3, Some("发言人 1")).unwrap();

    assert_eq!(
        ws.record("rec-1").unwrap().distinct_speakers(),
        vec![
            SpeakerSummary {
                name: "发言人 1".to_string(),
                segment_count: 2,
                first_segment_id: SegmentId::new(1).unwrap(),
            },
            SpeakerSummary {
                name: "发言人 2".to_string(),
                segment_count: 1,
                first_segment_id: SegmentId::new(2).unwrap(),
            },
        ]
    );

    let idem_rename = ws.rename_speaker("rec-1", "发言人 1：", "发言人 1").unwrap();
    assert_eq!(idem_rename.updated_segments, 0);

    let renamed_first = ws.rename_speaker("rec-1", "发言人 1：", "张工：").unwrap();
    assert_eq!(renamed_first.updated_segments, 2);

    let merged = ws.rename_speaker("rec-1", "发言人 2", "张工").unwrap();
    assert_eq!(merged.updated_segments, 1);

    assert_eq!(
        ws.record("rec-1").unwrap().distinct_speakers(),
        vec![SpeakerSummary {
            name: "张工".to_string(),
            segment_count: 3,
            first_segment_id: SegmentId::new(1).unwrap(),
        }]
    );

    let cleared = ws.set_segment_speaker(&s2, Some("   ")).unwrap();
    assert_eq!(cleared.updated_segments, 1);
    assert_eq!(
        ws.record("rec-1").unwrap().aggregate.spine.segments()[1].speaker,
        None
    );
    let cleared_again = ws.set_segment_speaker(&s2, None).unwrap();
    assert_eq!(cleared_again.updated_segments, 0);

    assert!(matches!(
        ws.set_segment_speaker(&s1, Some(&"张".repeat(MAX_SPEAKER_NAME_CHARS + 1))),
        Err(ProductError::InvalidInput(_))
    ));
    assert!(matches!(
        ws.set_segment_speaker(&s1, Some("张\n工")),
        Err(ProductError::InvalidInput(_))
    ));
    assert_eq!(
        ws.set_segment_speaker(&source("rec-1", 99), Some("张工")),
        Err(ProductError::SegmentNotFound)
    );
    assert!(matches!(
        ws.rename_speaker("rec-1", "不存在的人", "李工"),
        Err(ProductError::InvalidInput(_))
    ));
    assert!(matches!(
        ws.rename_speaker("rec-1", "不存在的人", "不存在的人"),
        Err(ProductError::InvalidInput(_))
    ));
}

#[test]
fn bm25_and_ask_ground_speaker_names_preserve_pending_restore_and_reject_mid_ask_speaker_edits() {
    let mut ws = seeded_workspace();
    let s1 = source("rec-1", 1);
    let s2 = source("rec-1", 2);

    ws.edit_segment_text(&s1, "Cicada 核心引擎完成流式切换。")
        .unwrap();
    ws.set_segment_speaker(&s1, Some("发言人 1")).unwrap();
    ws.rename_speaker("rec-1", "发言人 1", "林架构师").unwrap();
    ws.set_segment_speaker(&s2, Some("陈测试")).unwrap();

    let text_hits = ws.search(&SearchScope::All, "Cicada", 5).unwrap();
    assert_eq!(text_hits.len(), 1);
    assert_eq!(text_hits[0].source, s1);
    assert_eq!(text_hits[0].quote, "Cicada 核心引擎完成流式切换。");

    let speaker_hits = ws.search(&SearchScope::All, "林架构师", 5).unwrap();
    assert_eq!(speaker_hits.len(), 1);
    assert_eq!(speaker_hits[0].source, s1);
    assert_eq!(speaker_hits[0].quote, "Cicada 核心引擎完成流式切换。");

    let pending = ws
        .begin_ask(SearchScope::All, "林架构师说了什么？", 1_800_000_020)
        .unwrap()
        .unwrap();
    assert_eq!(pending.evidence[0].source, s1);
    assert_eq!(
        pending.evidence[0].quote,
        "林架构师：Cicada 核心引擎完成流式切换。"
    );
    assert!(pending
        .source_text
        .contains("林架构师：Cicada 核心引擎完成流式切换。"));

    let mut restored = ProductWorkspace::restore(ws.export_state()).unwrap();
    assert_eq!(restored.pending_ask().unwrap().operation, pending.operation);

    restored
        .rename_speaker("rec-1", "林架构师", "王总监")
        .unwrap();
    assert_eq!(
        restored.complete_ask(pending.operation, "已完成流式切换 [S1]"),
        Err(ProductError::StaleRequest)
    );
}

#[test]
fn multi_cycle_edits_keep_stale_minutes_alive_and_detach_inflight_summarization() {
    let mut ws = seeded_workspace();
    let s1 = source("rec-1", 1);
    let s2 = source("rec-1", 2);
    ws.set_segment_speaker(&s1, Some("发言人 1")).unwrap();
    ws.set_segment_speaker(&s2, Some("发言人 2")).unwrap();

    let aborted_initial = ws.begin_analysis("rec-1", AnalysisStage::Summarizing).unwrap();
    ws.edit_segment_text(&s1, "西卡达模块按70%灰度推进。")
        .unwrap();
    let aborted_edit = ws
        .edit_segment_text(&s1, "西卡达模块按70%灰度正式推进。")
        .unwrap();
    assert_eq!(aborted_edit.minutes_freshness, MinutesFreshness::Absent);
    assert_eq!(ws.record("rec-1").unwrap().analysis, AnalysisState::Idle);
    assert_eq!(
        ws.fail_analysis(&aborted_initial, "cancelled"),
        Err(ProductError::StaleRequest)
    );
    ws.edit_segment_text(&s1, "西卡达模块按70%灰度推进。")
        .unwrap();

    let key1 = ws.begin_analysis("rec-1", AnalysisStage::Summarizing).unwrap();
    let mins1 = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"灰度评审","overview":"按70%灰度推进","topics":[{"text":"灰度节奏","summary":"发言人 1 提议按70%灰度推进","sources":["S1"]}],"decisions":[{"text":"按70%灰度推进","speaker":"发言人 1","sources":["S1"]}],"actions":[{"text":"周五前完成压测验收","owner":"发言人 2","due":"周五","sources":["S2"]}],"questions":[],"terms":[{"name":"Cicada","note":"流式双语引擎","heard":["西卡达"],"sources":["S1"]}],"reviewItems":[]}"#,
        &ws.record("rec-1").unwrap().aggregate.spine,
    )
    .unwrap();
    ws.complete_summary(&key1, mins1).unwrap();
    assert!(!ws.record("rec-1").unwrap().is_minutes_stale());
    assert_eq!(
        ws.record("rec-1").unwrap().minutes_freshness(),
        MinutesFreshness::Fresh {
            input_revision: key1.input_revision
        }
    );

    let edit_80 = ws
        .edit_segment_text(&s1, "西卡达模块按80%灰度推进。")
        .unwrap();
    assert!(ws.record("rec-1").unwrap().is_minutes_stale());
    assert_eq!(
        edit_80.minutes_freshness,
        MinutesFreshness::Stale {
            minutes_revision: key1.input_revision,
            current_revision: edit_80.content_revision,
        }
    );
    assert!(ws.record("rec-1").unwrap().aggregate.minutes.is_some());

    let key2 = ws.begin_analysis("rec-1", AnalysisStage::Summarizing).unwrap();
    let mins2 = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"灰度评审","overview":"按80%灰度推进","topics":[{"text":"灰度节奏","summary":"发言人 1 调整为按80%灰度推进","sources":["S1"]}],"decisions":[{"text":"按80%灰度推进","speaker":"发言人 1","sources":["S1"]}],"actions":[{"text":"周五前完成压测验收","owner":"发言人 2","due":"周五","sources":["S2"]}],"questions":[],"terms":[{"name":"Cicada","note":"流式双语引擎","heard":["西卡达"],"sources":["S1"]}],"reviewItems":[]}"#,
        &ws.record("rec-1").unwrap().aggregate.spine,
    )
    .unwrap();
    ws.complete_summary(&key2, mins2).unwrap();
    assert!(!ws.record("rec-1").unwrap().is_minutes_stale());
    assert_eq!(
        ws.record("rec-1").unwrap().minutes_revision(),
        Some(key2.input_revision)
    );

    ws.edit_segment_text(&s1, "Cicada 模块按85%灰度推进。")
        .unwrap();
    let rename_receipt = ws.rename_speaker("rec-1", "发言人 1", "张工").unwrap();
    assert!(matches!(
        rename_receipt.minutes_freshness,
        MinutesFreshness::Stale { minutes_revision, current_revision }
            if minutes_revision == key2.input_revision && current_revision > minutes_revision
    ));
    let retained_mins = ws
        .record("rec-1")
        .unwrap()
        .aggregate
        .minutes
        .as_ref()
        .unwrap();
    assert_eq!(retained_mins.decisions[0].speaker.as_deref(), Some("发言人 1"));
    assert!(retained_mins.topics[0].summary.contains("发言人 1"));
    assert!(!retained_mins.topics[0].summary.contains("张工"));

    let reopened = ProductWorkspace::restore(ws.export_state()).unwrap();
    assert!(reopened.record("rec-1").unwrap().is_minutes_stale());
    assert_eq!(
        reopened
            .record("rec-1")
            .unwrap()
            .aggregate
            .minutes
            .as_ref()
            .unwrap()
            .decisions[0]
            .speaker
            .as_deref(),
        Some("发言人 1")
    );

    let stale_inflight_mins = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"灰度评审","overview":"按85%灰度推进","topics":[{"text":"灰度节奏","summary":"张工确认按85%灰度推进","sources":["S1"]}],"decisions":[{"text":"按85%灰度推进","speaker":"张工","sources":["S1"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
        &ws.record("rec-1").unwrap().aggregate.spine,
    )
    .unwrap();
    let inflight_key = ws.begin_analysis("rec-1", AnalysisStage::Summarizing).unwrap();
    ws.edit_segment_text(&s1, "Cicada 模块按90%灰度推进。")
        .unwrap();
    assert_eq!(
        ws.record("rec-1").unwrap().analysis,
        AnalysisState::Ready {
            input_revision: key2.input_revision
        }
    );
    assert_eq!(
        ws.complete_summary(&inflight_key, stale_inflight_mins),
        Err(ProductError::StaleRequest)
    );
    assert_eq!(
        ws.fail_analysis(&inflight_key, "late failure"),
        Err(ProductError::StaleRequest)
    );

    let fresh_key = ws.begin_analysis("rec-1", AnalysisStage::Summarizing).unwrap();
    assert!(fresh_key.input_revision > inflight_key.input_revision);
}

#[test]
fn trashed_archived_and_transcribing_records_reject_transcript_edits() {
    let mut ws = seeded_workspace();
    let s1 = source("rec-1", 1);
    ws.set_segment_speaker(&s1, Some("发言人 1")).unwrap();

    ws.set_record_archived("rec-1", true).unwrap();
    assert_eq!(
        ws.edit_segment_text(&s1, "不可修改"),
        Err(ProductError::RecordArchived)
    );
    assert_eq!(
        ws.set_segment_speaker(&s1, Some("张工")),
        Err(ProductError::RecordArchived)
    );
    assert_eq!(
        ws.rename_speaker("rec-1", "发言人 1", "张工"),
        Err(ProductError::RecordArchived)
    );
    assert!(ProductError::RecordArchived.to_string().contains("归档保护"));
    ws.set_record_archived("rec-1", false).unwrap();

    let transcribing = ws
        .begin_analysis("rec-1", AnalysisStage::Transcribing)
        .unwrap();
    assert_eq!(
        ws.edit_segment_text(&s1, "转写中禁止修改"),
        Err(ProductError::Busy)
    );
    assert_eq!(
        ws.set_segment_speaker(&s1, Some("张工")),
        Err(ProductError::Busy)
    );
    assert_eq!(
        ws.rename_speaker("rec-1", "发言人 1", "张工"),
        Err(ProductError::Busy)
    );
    ws.finish_transcription(&transcribing).unwrap();

    ws.trash_record("rec-1", 50_000).unwrap();
    assert_eq!(
        ws.edit_segment_text(&s1, "回收站禁止修改"),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.set_segment_speaker(&s1, Some("张工")),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        ws.rename_speaker("rec-1", "发言人 1", "张工"),
        Err(ProductError::RecordTrashed)
    );

    ws.restore_record("rec-1").unwrap();
    assert!(ws.edit_segment_text(&s1, "恢复后允许修改").is_ok());
}
