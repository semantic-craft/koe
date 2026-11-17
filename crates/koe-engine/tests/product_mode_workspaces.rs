use koe_engine::domain::SegmentId;
use koe_engine::minutes::parse_meeting_minutes_json;
use koe_engine::product::*;

fn source(record_id: &str, ordinal: u32) -> SourceRef {
    SourceRef {
        record_id: record_id.to_string(),
        segment_id: SegmentId::new(ordinal).unwrap(),
    }
}

#[test]
fn record_mode_and_quick_note_project_lifecycle_and_dual_stage_restore() {
    for (mode, wire) in [
        (RecordMode::QuickNote, "quick_note"),
        (RecordMode::AllDay, "all_day"),
        (RecordMode::Meeting, "meeting"),
    ] {
        assert_eq!(mode.as_str(), wire);
        assert_eq!(RecordMode::parse(wire), Some(mode));
        assert_eq!(RecordMode::parse(&format!("  {wire}  ")), Some(mode));
    }
    assert_eq!(RecordMode::parse("unknown_mode"), None);

    let mut w = ProductWorkspace::new();
    w.insert_record(
        "note-1".into(),
        "周末灵感".into(),
        RecordOrigin::Note,
        0,
        1_800_000_000,
        0,
    )
    .unwrap();
    assert_eq!(w.record("note-1").unwrap().mode, RecordMode::QuickNote);
    assert_eq!(w.record("note-1").unwrap().project, None);
    assert!(w.record("note-1").unwrap().is_quick_note_inbox());

    w.set_record_project("note-1", Some("  Koe 架构评审  "))
        .unwrap();
    assert_eq!(
        w.record("note-1").unwrap().project.as_deref(),
        Some("Koe 架构评审")
    );
    assert!(!w.record("note-1").unwrap().is_quick_note_inbox());

    let rev_before = w.revision();
    w.set_record_project("note-1", Some("Koe 架构评审")).unwrap();
    assert_eq!(w.revision(), rev_before);

    w.set_record_project("note-1", Some("   ")).unwrap();
    assert_eq!(w.record("note-1").unwrap().project, None);
    assert!(w.record("note-1").unwrap().is_quick_note_inbox());

    let overlong = "项".repeat(MAX_PROJECT_NAME_CHARS + 1);
    assert!(matches!(
        w.set_record_project("note-1", Some(&overlong)),
        Err(ProductError::InvalidInput(_))
    ));
    assert!(matches!(
        w.set_record_project("note-1", Some("Koe\n评审")),
        Err(ProductError::InvalidInput(_))
    ));
    assert_eq!(
        w.set_record_project("missing", Some("Koe")),
        Err(ProductError::UnknownRecord)
    );

    w.set_record_project("note-1", Some("Koe 四模式")).unwrap();
    w.set_record_mode("note-1", RecordMode::Meeting).unwrap();
    assert_eq!(w.record("note-1").unwrap().mode, RecordMode::Meeting);
    let rev_mode = w.revision();
    w.set_record_mode("note-1", RecordMode::Meeting).unwrap();
    assert_eq!(w.revision(), rev_mode);

    w.insert_record(
        "day-slice".into(),
        "录音 9".into(),
        RecordOrigin::Bean,
        9,
        1_800_000_100,
        60_000,
    )
    .unwrap();
    w.group_all_day(
        "day-slice",
        AllDaySegment {
            run_id: "run-1".into(),
            ordinal: 1,
        },
    )
    .unwrap();
    assert_eq!(w.record("day-slice").unwrap().mode, RecordMode::AllDay);
    assert!(!w.record("day-slice").unwrap().is_quick_note_inbox());

    w.insert_record(
        "note-archived".into(),
        "归档想法".into(),
        RecordOrigin::Note,
        0,
        1_800_000_200,
        0,
    )
    .unwrap();
    assert!(w.record("note-archived").unwrap().is_quick_note_inbox());
    w.set_record_archived("note-archived", true).unwrap();
    assert!(!w.record("note-archived").unwrap().is_quick_note_inbox());

    w.insert_record(
        "note-trashed".into(),
        "回收想法".into(),
        RecordOrigin::Note,
        0,
        1_800_000_300,
        0,
    )
    .unwrap();
    w.trash_record("note-trashed", 1_800_000_305_000).unwrap();
    assert!(!w.record("note-trashed").unwrap().is_quick_note_inbox());
    assert_eq!(
        w.set_record_mode("note-trashed", RecordMode::Meeting),
        Err(ProductError::RecordTrashed)
    );
    assert_eq!(
        w.set_record_project("note-trashed", Some("项目")),
        Err(ProductError::RecordTrashed)
    );

    let exported = w.export_state();
    let restored = ProductWorkspace::restore(exported.clone()).unwrap();
    assert_eq!(restored.record("note-1").unwrap().mode, RecordMode::Meeting);
    assert_eq!(
        restored.record("note-1").unwrap().project.as_deref(),
        Some("Koe 四模式")
    );
    assert_eq!(
        restored.record("day-slice").unwrap().mode,
        RecordMode::AllDay
    );

    let mut untrimmed_state = exported;
    untrimmed_state
        .records
        .iter_mut()
        .find(|r| r.aggregate.recording_id == "note-1")
        .unwrap()
        .project = Some("  untrimmed ".into());
    assert_eq!(
        ProductWorkspace::restore(untrimmed_state),
        Err(ProductError::InvalidEvidence)
    );
}

#[test]
fn day_timeline_merges_adjoining_run_slices_and_emits_truthful_pauses_and_gaps() {
    let mut w = ProductWorkspace::new();

    w.insert_record(
        "s1".into(),
        "录音 1".into(),
        RecordOrigin::Microphone,
        0,
        1_800_010_000,
        300_000,
    )
    .unwrap();
    w.group_all_day(
        "s1",
        AllDaySegment {
            run_id: "run-a".into(),
            ordinal: 1,
        },
    )
    .unwrap();
    let s1_seg1 = w
        .append_transcript("s1", "先对齐四模式侧栏边界", 0, 12_000, "local")
        .unwrap();
    w.set_segment_speaker(&source("s1", s1_seg1.ordinal()), Some("Alice"))
        .unwrap();

    w.insert_record(
        "s2".into(),
        "Mac 麦克风录音".into(),
        RecordOrigin::Microphone,
        0,
        1_800_010_320,
        180_000,
    )
    .unwrap();
    w.group_all_day(
        "s2",
        AllDaySegment {
            run_id: "run-a".into(),
            ordinal: 2,
        },
    )
    .unwrap();
    let s2_seg1 = w
        .append_transcript("s2", "确认导航不自动开启语音伴侣", 0, 15_000, "local")
        .unwrap();
    w.set_segment_speaker(&source("s2", s2_seg1.ordinal()), Some("Bob"))
        .unwrap();
    let s2_key = w.begin_analysis("s2", AnalysisStage::Summarizing).unwrap();
    let s2_minutes = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"导航解耦讨论","overview":"确认导航与采集会话分离","topics":[{"text":"导航边界","summary":"进入语音输入页不触发自动连接","sources":["S1"]}],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
        &w.record("s2").unwrap().aggregate.spine,
    )
    .unwrap();
    w.complete_summary(&s2_key, s2_minutes).unwrap();

    w.insert_record(
        "s3".into(),
        "全天听记片段".into(),
        RecordOrigin::Microphone,
        0,
        1_800_010_620,
        60_000,
    )
    .unwrap();
    w.group_all_day(
        "s3",
        AllDaySegment {
            run_id: "run-a".into(),
            ordinal: 3,
        },
    )
    .unwrap();
    w.append_transcript("s3", "下午排期确认", 0, 10_000, "local")
        .unwrap();
    w.set_capture_lanes(
        "s3",
        vec![CaptureLaneRecord {
            lane: "microphone".into(),
            asset_id: Some("s3".into()),
            sample_rate: Some(16_000),
            duration_ms: 60_000,
            interruption: None,
            timeline: vec![
                CaptureSpan {
                    epoch: 0,
                    start_ns: 0,
                    sample_offset: 0,
                    sample_count: 480_000,
                },
                CaptureSpan {
                    epoch: 1,
                    start_ns: 32_500_000_000,
                    sample_offset: 480_000,
                    sample_count: 480_000,
                },
            ],
        }],
    )
    .unwrap();

    w.insert_record(
        "s4".into(),
        "晚间复盘".into(),
        RecordOrigin::Microphone,
        0,
        1_800_010_980,
        90_000,
    )
    .unwrap();
    w.group_all_day(
        "s4",
        AllDaySegment {
            run_id: "run-b".into(),
            ordinal: 1,
        },
    )
    .unwrap();
    w.append_transcript("s4", "整理今日交付清单", 0, 8_000, "local")
        .unwrap();

    let records: Vec<&ProductRecord> = ["s4", "s2", "s1", "s3"]
        .into_iter()
        .map(|id| w.record(id).unwrap())
        .collect();
    let timeline = build_day_timeline(&records);

    assert_eq!(timeline.total_recorded_ms, 630_000);
    assert_eq!(timeline.event_count, 4);
    assert_eq!(timeline.pause_count, 1);
    assert_eq!(timeline.gap_count, 1);
    assert_eq!(timeline.spans.len(), 6);

    let span_bounds: Vec<(u64, u64)> = timeline
        .spans
        .iter()
        .map(|s| match s {
            DayTimelineSpan::Event(e) => (e.start_epoch_sec, e.end_epoch_sec),
            DayTimelineSpan::Pause(p) => (p.start_epoch_sec, p.end_epoch_sec),
            DayTimelineSpan::UnrecordedGap(g) => (g.start_epoch_sec, g.end_epoch_sec),
        })
        .collect();
    assert!(
        span_bounds.windows(2).all(|w| w[0].1 <= w[1].0),
        "timeline spans must be strictly chronological: {span_bounds:?}"
    );

    match &timeline.spans[0] {
        DayTimelineSpan::Event(ev) => {
            assert_eq!(ev.record_ids, vec!["s1".to_string(), "s2".to_string()]);
            assert_eq!(ev.start_epoch_sec, 1_800_010_000);
            assert_eq!(ev.end_epoch_sec, 1_800_010_500);
            assert_eq!(ev.duration_ms, 480_000);
            assert_eq!(ev.segment_count, 2);
            assert_eq!(ev.speakers, vec!["Alice".to_string(), "Bob".to_string()]);
            assert_eq!(ev.first_segment, Some(source("s1", 1)));
            assert_eq!(ev.title, "导航解耦讨论");
            assert!(!ev.summary_points.is_empty());
        }
        other => panic!("expected merged Event at spans[0], got {other:?}"),
    }

    match &timeline.spans[1] {
        DayTimelineSpan::Event(ev) => {
            assert_eq!(ev.record_ids, vec!["s3".to_string()]);
            assert_eq!(ev.start_epoch_sec, 1_800_010_620);
            assert_eq!(ev.end_epoch_sec, 1_800_010_650);
            assert_eq!(ev.title, "下午排期确认");
        }
        other => panic!("expected s3 pre-pause Event at spans[1], got {other:?}"),
    }

    match &timeline.spans[2] {
        DayTimelineSpan::Pause(pause) => {
            assert_eq!(pause.record_id, "s3");
            assert_eq!(pause.duration_ms, 2_500);
            assert_eq!(pause.start_epoch_sec, 1_800_010_650);
            assert_eq!(pause.end_epoch_sec, 1_800_010_653);
        }
        other => panic!("expected intra-record Pause at spans[2], got {other:?}"),
    }

    match &timeline.spans[3] {
        DayTimelineSpan::Event(ev) => {
            assert_eq!(ev.record_ids, vec!["s3".to_string()]);
            assert_eq!(ev.start_epoch_sec, 1_800_010_653);
            assert_eq!(ev.end_epoch_sec, 1_800_010_683);
        }
        other => panic!("expected s3 post-pause Event at spans[3], got {other:?}"),
    }

    match &timeline.spans[4] {
        DayTimelineSpan::UnrecordedGap(gap) => {
            assert!(gap.duration_ms >= MIN_UNRECORDED_GAP_SEC * 1_000);
            assert_eq!(gap.start_epoch_sec, 1_800_010_683);
            assert_eq!(gap.end_epoch_sec, 1_800_010_980);
        }
        other => panic!("expected UnrecordedGap at spans[4], got {other:?}"),
    }

    match &timeline.spans[5] {
        DayTimelineSpan::Event(ev) => {
            assert_eq!(ev.record_ids, vec!["s4".to_string()]);
            assert_eq!(ev.title, "晚间复盘");
        }
        other => panic!("expected s4 Event at spans[5], got {other:?}"),
    }
}

#[test]
fn day_timeline_wall_clock_bounds_symmetric_run_merge_and_dual_lane_pause_union() {
    let mut w = ProductWorkspace::new();

    w.insert_record(
        "p1".into(),
        "双路片段 1".into(),
        RecordOrigin::Microphone,
        0,
        1_800_050_000,
        20_000,
    )
    .unwrap();
    w.group_all_day(
        "p1",
        AllDaySegment {
            run_id: "run-sym".into(),
            ordinal: 1,
        },
    )
    .unwrap();
    w.append_transcript("p1", "暂停前第一段对话", 0, 8_000, "local")
        .unwrap();
    w.append_transcript("p1", "恢复后第二段对话", 12_000, 19_000, "local")
        .unwrap();

    let mut mic_spans = Vec::new();
    let mut sys_spans = Vec::new();
    for idx in 0..20u64 {
        let active_offset_samples = idx * 16_000;
        let wall_start_ns = idx * 10_000_000_000;
        mic_spans.push(CaptureSpan {
            epoch: idx,
            start_ns: wall_start_ns,
            sample_offset: active_offset_samples,
            sample_count: 16_000,
        });
        sys_spans.push(CaptureSpan {
            epoch: idx,
            start_ns: wall_start_ns + if idx > 0 { 1_000_000 } else { 0 },
            sample_offset: active_offset_samples,
            sample_count: 16_000,
        });
    }
    w.set_capture_lanes(
        "p1",
        vec![
            CaptureLaneRecord {
                lane: "microphone".into(),
                asset_id: Some("p1".into()),
                sample_rate: Some(16_000),
                duration_ms: 20_000,
                interruption: None,
                timeline: mic_spans,
            },
            CaptureLaneRecord {
                lane: "system".into(),
                asset_id: Some("p1-system".into()),
                sample_rate: Some(16_000),
                duration_ms: 20_000,
                interruption: None,
                timeline: sys_spans,
            },
        ],
    )
    .unwrap();

    w.insert_record(
        "p2".into(),
        "双路片段 2".into(),
        RecordOrigin::Microphone,
        0,
        1_800_050_230,
        30_000,
    )
    .unwrap();
    w.group_all_day(
        "p2",
        AllDaySegment {
            run_id: "run-sym".into(),
            ordinal: 2,
        },
    )
    .unwrap();
    w.append_transcript("p2", "紧接上一片继续讨论", 0, 10_000, "local")
        .unwrap();

    let records = vec![w.record("p1").unwrap(), w.record("p2").unwrap()];
    let timeline = build_day_timeline(&records);

    assert_eq!(
        timeline.gap_count, 0,
        "wall-clock end of p1 is +191s, so p2 at +230s (39s later) must merge with 0 UnrecordedGap"
    );
    assert_eq!(
        timeline.pause_count, 19,
        "1ms skewed dual-lane pauses must union instead of double-counting (got {})",
        timeline.pause_count
    );
    let last_event = timeline
        .spans
        .iter()
        .rev()
        .find_map(|s| match s {
            DayTimelineSpan::Event(e) => Some(e),
            _ => None,
        })
        .unwrap();
    assert!(
        last_event.record_ids.contains(&"p2".to_string()),
        "p2 must merge symmetrically into the same run after paused p1"
    );
    let bounds: Vec<(u64, u64)> = timeline
        .spans
        .iter()
        .map(|s| match s {
            DayTimelineSpan::Event(e) => (e.start_epoch_sec, e.end_epoch_sec),
            DayTimelineSpan::Pause(p) => (p.start_epoch_sec, p.end_epoch_sec),
            DayTimelineSpan::UnrecordedGap(g) => (g.start_epoch_sec, g.end_epoch_sec),
        })
        .collect();
    assert!(
        bounds.windows(2).all(|w| w[0].1 <= w[1].0),
        "all timeline spans must be strictly monotonic: {bounds:?}"
    );
}

#[test]
fn meeting_coverage_tracks_transcript_grounding_and_consolidation_stages() {
    let mut w = ProductWorkspace::new();
    w.insert_record(
        "m1".into(),
        "产品评审会".into(),
        RecordOrigin::Microphone,
        0,
        1_800_020_000,
        0,
    )
    .unwrap();
    w.set_record_mode("m1", RecordMode::Meeting).unwrap();
    w.append_transcript("m1", "第一段讨论", 0, 25_000, "local")
        .unwrap();
    w.append_transcript("m1", "第二段讨论", 25_000, 50_000, "local")
        .unwrap();

    let live_cov = compute_meeting_coverage(w.record("m1").unwrap(), 100_000, true);
    assert_eq!(live_cov.audio_duration_ms, 100_000);
    assert_eq!(live_cov.transcribed_duration_ms, 50_000);
    assert_eq!(live_cov.transcript_percent, 50);
    assert_eq!(live_cov.total_segments, 2);
    assert_eq!(live_cov.grounded_segments, 0);
    assert_eq!(live_cov.minutes_percent, 0);
    assert_eq!(live_cov.consolidation, ConsolidationStage::NotStarted);
    assert_eq!(live_cov.consolidation.label_zh(), "录音结束后整理");

    w.append_transcript("m1", "第三段决策", 50_000, 75_000, "local")
        .unwrap();
    w.append_transcript("m1", "第四段收尾", 75_000, 100_000, "local")
        .unwrap();
    w.finish_capture("m1", 100_000, &[]).unwrap();

    let sum_key = w.begin_analysis("m1", AnalysisStage::Summarizing).unwrap();
    let pending_cov = compute_meeting_coverage(w.record("m1").unwrap(), 0, false);
    assert_eq!(pending_cov.consolidation, ConsolidationStage::InProgress);
    assert_eq!(pending_cov.consolidation.label_zh(), "正在整理完整纪要");

    let grounded_minutes = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"产品评审会","overview":"确认两项结论","topics":[{"text":"讨论","summary":"覆盖第一段","sources":["S1"]}],"decisions":[{"text":"通过第三段方案","sources":["S3"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
        &w.record("m1").unwrap().aggregate.spine,
    )
    .unwrap();
    w.complete_summary(&sum_key, grounded_minutes).unwrap();

    let ready_cov = compute_meeting_coverage(w.record("m1").unwrap(), 0, false);
    assert_eq!(ready_cov.transcript_percent, 100);
    assert_eq!(ready_cov.total_segments, 4);
    assert_eq!(ready_cov.grounded_segments, 2);
    assert_eq!(ready_cov.minutes_percent, 50);
    assert_eq!(ready_cov.consolidation, ConsolidationStage::Ready);
    assert_eq!(ready_cov.consolidation.label_zh(), "完整纪要已核对");

    w.edit_segment_text(&source("m1", 4), "第四段收尾（补充细节）")
        .unwrap();
    let stale_cov = compute_meeting_coverage(w.record("m1").unwrap(), 0, false);
    assert_eq!(stale_cov.consolidation, ConsolidationStage::Stale);
    assert_eq!(stale_cov.consolidation.label_zh(), "原文已修改待重算");

    let retry_key = w.begin_analysis("m1", AnalysisStage::Summarizing).unwrap();
    w.fail_analysis(&retry_key, "服务暂不可用").unwrap();
    let failed_cov = compute_meeting_coverage(w.record("m1").unwrap(), 0, false);
    assert_eq!(failed_cov.consolidation, ConsolidationStage::Failed);
    assert_eq!(failed_cov.consolidation.label_zh(), "整理未完成");

    w.insert_record(
        "untimed-note".into(),
        "文字导入记录".into(),
        RecordOrigin::ImportedText,
        0,
        1_800_020_500,
        12_000,
    )
    .unwrap();
    w.append_transcript("untimed-note", "纯文本导入内容", 0, 0, "manual")
        .unwrap();
    let untimed_cov = compute_meeting_coverage(w.record("untimed-note").unwrap(), 0, false);
    assert_eq!(untimed_cov.transcribed_duration_ms, 12_000);
    assert_eq!(untimed_cov.transcript_percent, 100);
}

#[test]
fn markdown_export_prioritizes_raw_transcript_and_respects_analysis_and_source_flags() {
    let mut w = ProductWorkspace::new();
    w.insert_record(
        "qn-1".into(),
        "架构闪记".into(),
        RecordOrigin::Microphone,
        0,
        1_800_030_000,
        20_000,
    )
    .unwrap();
    w.set_record_project("qn-1", Some("Koe 核心")).unwrap();
    let seg1 = w
        .append_transcript("qn-1", "先把导出顺序改成原文在前", 0, 10_000, "local")
        .unwrap();
    w.set_segment_speaker(&source("qn-1", seg1.ordinal()), Some("Xianwei"))
        .unwrap();
    w.append_transcript("qn-1", "再核对引用开关是否生效", 10_000, 20_000, "local")
        .unwrap();

    let key = w
        .begin_analysis("qn-1", AnalysisStage::Summarizing)
        .unwrap();
    let mins = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"导出约定","overview":"导出默认原文优先","topics":[{"text":"导出顺序","summary":"原文放在最前","sources":["S1"]}],"decisions":[{"text":"引用可按需关闭","sources":["S2"]}],"actions":[{"text":"补齐导出回退测试","sources":["S2"]}],"questions":[],"terms":[],"reviewItems":[]}"#,
        &w.record("qn-1").unwrap().aggregate.spine,
    )
    .unwrap();
    w.complete_summary(&key, mins).unwrap();

    let record = w.record("qn-1").unwrap();
    let items: Vec<&SourcedItem> = w.items().values().collect();

    let full_md = format_record_markdown(record, &items, MarkdownExportOptions::default());
    assert!(full_md.starts_with("# 架构闪记"));
    assert!(!full_md.contains('·'), "exported markdown must not contain middle dots");
    assert!(full_md.contains("Koe 核心"));
    let raw_pos = full_md.find("## 原文").expect("must include raw transcript heading");
    let ai_pos = full_md.find("## AI 整理").expect("must include AI analysis heading");
    assert!(raw_pos < ai_pos, "## 原文 must appear strictly before ## AI 整理");
    assert!(full_md.contains("[S1] Xianwei：先把导出顺序改成原文在前"));
    let ai_slice = &full_md[ai_pos..];
    assert!(ai_slice.contains("[S1]"));
    assert!(ai_slice.contains("[S2]"));

    let no_sources_md = format_record_markdown(
        record,
        &items,
        MarkdownExportOptions {
            include_analysis: true,
            include_sources: false,
        },
    );
    let no_src_ai_pos = no_sources_md.find("## AI 整理").unwrap();
    assert!(
        !no_sources_md[no_src_ai_pos..].contains("[S1]")
            && !no_sources_md[no_src_ai_pos..].contains("[S2]"),
        "## AI 整理 must omit [S...] tags when include_sources is false"
    );

    let raw_only_md = format_record_markdown(
        record,
        &items,
        MarkdownExportOptions {
            include_analysis: false,
            include_sources: false,
        },
    );
    assert!(raw_only_md.contains("## 原文"));
    assert!(!raw_only_md.contains("## AI 整理"));

    w.edit_segment_text(&source("qn-1", 2), "再核对引用开关和过期提示")
        .unwrap();
    let stale_md = format_record_markdown(
        w.record("qn-1").unwrap(),
        &w.items().values().collect::<Vec<_>>(),
        MarkdownExportOptions::default(),
    );
    assert!(stale_md.contains("> 注：原文已变更，以下纪要待重新整理。"));

    w.insert_record(
        "d1".into(),
        "上午同步".into(),
        RecordOrigin::Microphone,
        0,
        1_800_040_000,
        60_000,
    )
    .unwrap();
    w.group_all_day(
        "d1",
        AllDaySegment {
            run_id: "day-run".into(),
            ordinal: 1,
        },
    )
    .unwrap();
    w.append_transcript("d1", "上午完成接口对齐", 0, 10_000, "local")
        .unwrap();
    w.set_capture_lanes(
        "d1",
        vec![CaptureLaneRecord {
            lane: "microphone".into(),
            asset_id: Some("d1".into()),
            sample_rate: Some(16_000),
            duration_ms: 60_000,
            interruption: None,
            timeline: vec![
                CaptureSpan {
                    epoch: 0,
                    start_ns: 0,
                    sample_offset: 0,
                    sample_count: 480_000,
                },
                CaptureSpan {
                    epoch: 1,
                    start_ns: 33_000_000_000,
                    sample_offset: 480_000,
                    sample_count: 480_000,
                },
            ],
        }],
    )
    .unwrap();
    let d1_key = w.begin_analysis("d1", AnalysisStage::Summarizing).unwrap();
    let d1_mins = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"上午同步","overview":"上午对齐了核心接口","topics":[{"text":"接口","summary":"确认签名不变","sources":["S1"]}],"decisions":[],"actions":[{"text":"跟进下午联调","sources":["S1"]}],"questions":[],"terms":[],"reviewItems":[]}"#,
        &w.record("d1").unwrap().aggregate.spine,
    )
    .unwrap();
    w.complete_summary(&d1_key, d1_mins).unwrap();

    w.insert_record(
        "d2".into(),
        "下午联调".into(),
        RecordOrigin::Microphone,
        0,
        1_800_040_400,
        60_000,
    )
    .unwrap();
    w.group_all_day(
        "d2",
        AllDaySegment {
            run_id: "day-run".into(),
            ordinal: 2,
        },
    )
    .unwrap();
    w.append_transcript("d2", "下午联调通过", 0, 10_000, "local")
        .unwrap();

    let day_records = vec![w.record("d1").unwrap(), w.record("d2").unwrap()];
    let day_items: Vec<&SourcedItem> = w.items().values().collect();
    let day_timeline = build_day_timeline(&day_records);
    let day_md = format_day_markdown(
        "2026-11-15",
        &day_timeline,
        &day_records,
        &day_items,
        MarkdownExportOptions::default(),
    );
    assert!(day_md.starts_with("# 全天听记 2026-11-15"));
    assert!(!day_md.contains('·'));
    assert!(day_md.contains("上午完成接口对齐"));
    assert!(day_md.contains("已暂停"));
    assert!(day_md.contains("未录音空档"));
    assert!(day_md.contains("## 当日行动与记忆"));
    assert!(day_md.contains("## 当日回顾"));

    w.insert_record(
        "ml-1".into(),
        "多段落闪记".into(),
        RecordOrigin::Note,
        0,
        1_800_045_000,
        0,
    )
    .unwrap();
    w.append_transcript("ml-1", "第一段原文", 0, 0, "manual")
        .unwrap();
    let ml_key = w.begin_analysis("ml-1", AnalysisStage::Summarizing).unwrap();
    let ml_mins = parse_meeting_minutes_json(
        r#"{"schemaVersion":2,"title":"多段落闪记","overview":"第一段总览 [S1]\n\n- 要点一 [S1]\n- 要点二","topics":[{"text":"列表议题","summary":"段落甲 [S1]\n段落乙","sources":["S1"]}],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
        &w.record("ml-1").unwrap().aggregate.spine,
    )
    .unwrap();
    w.complete_summary(&ml_key, ml_mins).unwrap();
    let ml_no_src = format_record_markdown(
        w.record("ml-1").unwrap(),
        &[],
        MarkdownExportOptions {
            include_analysis: true,
            include_sources: false,
        },
    );
    assert!(
        ml_no_src.contains("第一段总览\n\n- 要点一\n- 要点二"),
        "stripping citations must preserve paragraph breaks and Markdown list items: {ml_no_src}"
    );
    assert!(
        ml_no_src.contains("段落甲\n段落乙"),
        "stripping citations must preserve single line breaks: {ml_no_src}"
    );
}
