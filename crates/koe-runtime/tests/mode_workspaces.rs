#![allow(clippy::unwrap_used, clippy::expect_used)]

use koe_client_services::product_store::ProductStore;
use koe_engine::{
    minutes::parse_meeting_minutes_json,
    product::{
        AllDaySegment, AnalysisStage, CaptureLaneRecord, CaptureSpan, ItemKind, RecordMode,
        RecordOrigin, ReviewDecision, SourceRef,
    },
};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};

const NOW: u64 = 1_768_478_400;

struct Sandbox(std::path::PathBuf);

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn new_sandbox() -> Sandbox {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "koe-mode-ws-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&path).unwrap();
    Sandbox(path)
}

fn runtime() -> (KoeRuntime, Sandbox) {
    let sb = new_sandbox();
    let rt = KoeRuntime::open(&sb.0).unwrap();
    (rt, sb)
}

fn send_at(runtime: &mut KoeRuntime, now: u64, command: Value) -> Value {
    let snapshot: Value =
        serde_json::from_str(&runtime.dispatch_json(&command.to_string(), now)).unwrap();
    assert!(
        snapshot["error"].is_null(),
        "unexpected error for {command}: {}",
        snapshot["error"]
    );
    snapshot
}

fn send_raw_at(runtime: &mut KoeRuntime, now: u64, command: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&command.to_string(), now)).unwrap()
}

fn finish_mic_capture(runtime: &mut KoeRuntime, snap: &Value, now: u64) -> Value {
    let rec_id = snap["microphone"]["recordId"].as_str().unwrap();
    let session_id = snap["microphone"]["sessionId"].as_str().unwrap();
    send_at(
        runtime,
        now,
        json!({
            "type": "microphone_prepared",
            "recordId": rec_id,
            "sessionId": session_id,
            "epoch": 0,
            "clockNs": 1_000_000_000_u64
        }),
    );
    send_at(
        runtime,
        now,
        json!({
            "type": "microphone_started",
            "recordId": rec_id,
            "sessionId": session_id,
            "lane": "microphone",
            "sampleRate": 16000
        }),
    );
    let receipt = runtime.ingest_microphone_pcm(
        rec_id,
        session_id,
        "microphone",
        0,
        &vec![120_i16; 320],
        Some((0, 1_000_000_000_u64)),
        now,
    );
    assert_eq!(receipt.status, koe_runtime::PcmIngestStatus::Accepted);
    send_at(runtime, now + 1, json!({ "type": "capture_action", "action": "end" }));
    send_at(
        runtime,
        now + 1,
        json!({
            "type": "microphone_stopped",
            "recordId": rec_id,
            "sessionId": session_id,
            "lane": "microphone",
            "sequence": 1,
            "epoch": 0
        }),
    )
}

#[test]
fn pure_navigation_across_all_mode_workspaces_has_zero_session_or_host_side_effects() {
    let (mut rt, _sb) = runtime();
    let initial: Value = serde_json::from_str(&rt.snapshot_json(NOW)).unwrap();
    let initial_auto_connect = initial["device"]["autoConnect"].clone();

    for section in ["notes", "all_day", "live_minutes", "today"] {
        let snap = send_at(&mut rt, NOW, json!({ "type": "navigate", "section": section }));
        assert_eq!(snap["section"], section);
        assert_eq!(snap["device"]["autoConnect"], initial_auto_connect);
        assert!(snap["activeCapture"].is_null());
    }
}

#[test]
fn mode_stamping_and_stay_on_page_across_capture_and_note_creation() {
    let (mut rt, _sb) = runtime();

    let created = send_at(
        &mut rt,
        NOW,
        json!({ "type": "create_note", "title": "灵感卡片", "text": "第一条闪记内容" }),
    );
    let note_id = created["selectedRecordId"].as_str().unwrap().to_owned();
    assert_eq!(created["detail"]["mode"], "quick_note");
    assert!(created["detail"]["project"].is_null());
    assert_eq!(created["records"][0]["mode"], "quick_note");

    send_at(&mut rt, NOW + 1, json!({ "type": "navigate", "section": "today" }));
    let meeting_started = send_at(
        &mut rt,
        NOW + 2,
        json!({ "type": "start_capture_mode", "mode": "meeting", "stayOnPage": true }),
    );
    assert_eq!(
        meeting_started["section"], "today",
        "stayOnPage must keep Mode Picker on today"
    );
    let picker_cards = meeting_started["workspaces"]["picker"]["cards"]
        .as_array()
        .unwrap();
    assert_eq!(picker_cards.len(), 3);
    let meeting_card = picker_cards
        .iter()
        .find(|c| c["id"] == "live_minutes")
        .unwrap();
    assert_eq!(meeting_card["isSessionActive"], true);
    assert_eq!(meeting_card["canToggleSession"], true);

    let meeting_id = meeting_started["microphone"]["recordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let saved_meeting = finish_mic_capture(&mut rt, &meeting_started, NOW + 2);
    let meeting_row = saved_meeting["records"]
        .as_array()
        .unwrap()
        .iter()
        .find(|r| r["id"] == meeting_id)
        .unwrap();
    assert_eq!(meeting_row["mode"], "meeting");

    let jump_meeting = send_at(
        &mut rt,
        NOW + 20,
        json!({ "type": "start_capture_mode", "mode": "meeting" }),
    );
    assert_eq!(jump_meeting["section"], "live_minutes");
    let _ = finish_mic_capture(&mut rt, &jump_meeting, NOW + 20);

    let final_snap = send_at(
        &mut rt,
        NOW + 30,
        json!({ "type": "select_record", "recordId": note_id }),
    );
    assert_eq!(final_snap["detail"]["mode"], "quick_note");
}

#[test]
fn quick_note_projects_inbox_counts_selection_and_reload_persistence() {
    let sb = new_sandbox();
    let note_a_id;
    let note_b_id;
    {
        let mut rt = KoeRuntime::open(&sb.0).unwrap();
        let a = send_at(
            &mut rt,
            NOW,
            json!({ "type": "create_note", "title": "闪记 A", "text": "收件箱想法 A" }),
        );
        note_a_id = a["selectedRecordId"].as_str().unwrap().to_owned();
        let b = send_at(
            &mut rt,
            NOW + 5,
            json!({ "type": "create_note", "title": "闪记 B", "text": "收件箱想法 B" }),
        );
        note_b_id = b["selectedRecordId"].as_str().unwrap().to_owned();

        assert_eq!(b["workspaces"]["quickNote"]["inboxCount"], 2);
        assert_eq!(b["workspaces"]["quickNote"]["totalCount"], 2);
        assert_eq!(b["workspaces"]["quickNote"]["selectedRecordId"], note_b_id);
        assert!(
            b["workspaces"]["quickNote"]["mcpReadNote"]
                .as_str()
                .unwrap()
                .contains("只读 MCP")
        );

        let assigned = send_at(
            &mut rt,
            NOW + 6,
            json!({
                "type": "set_record_project",
                "recordId": note_a_id,
                "project": "  Koe 架构评审  "
            }),
        );
        assert_eq!(assigned["notice"], "已更新项目归类");
        assert_eq!(assigned["workspaces"]["quickNote"]["inboxCount"], 1);
        assert_eq!(
            assigned["workspaces"]["quickNote"]["projects"],
            json!([{ "name": "Koe 架构评审", "count": 1 }])
        );

        let selected = send_at(
            &mut rt,
            NOW + 7,
            json!({ "type": "select_quick_note_record", "recordId": note_a_id }),
        );
        assert_eq!(
            selected["workspaces"]["quickNote"]["selectedRecordId"],
            note_a_id
        );
    }

    let mut reopened = KoeRuntime::open(&sb.0).unwrap();
    let snap: Value = serde_json::from_str(&reopened.snapshot_json(NOW + 10)).unwrap();
    assert_eq!(snap["workspaces"]["quickNote"]["inboxCount"], 1);
    let card_a = snap["workspaces"]["quickNote"]["cards"]
        .as_array()
        .unwrap()
        .iter()
        .find(|c| c["id"] == note_a_id)
        .unwrap();
    assert_eq!(card_a["project"], "Koe 架构评审");
    assert_eq!(card_a["isInbox"], false);

    send_at(
        &mut reopened,
        NOW + 11,
        json!({ "type": "select_quick_note_record", "recordId": note_a_id }),
    );
    let trashed = send_at(
        &mut reopened,
        NOW + 12,
        json!({ "type": "trash_record", "recordId": note_a_id }),
    );
    assert_eq!(
        trashed["workspaces"]["quickNote"]["selectedRecordId"],
        note_b_id
    );
}

#[test]
fn all_day_workspace_projects_merged_events_pauses_gaps_and_grounded_review() {
    let sb = new_sandbox();
    {
        let mut store = ProductStore::open(&sb.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "ad-1".into(),
                    "录音 1".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW,
                    120_000,
                )?;
                w.group_all_day(
                    "ad-1",
                    AllDaySegment {
                        run_id: "day-run-1".into(),
                        ordinal: 1,
                    },
                )?;
                let s1 = w.append_transcript(
                    "ad-1",
                    "上午讨论接口契约与测试边界",
                    0,
                    30_000,
                    "asr",
                )?;
                let key1 = w.begin_analysis("ad-1", AnalysisStage::Summarizing)?;
                let minutes1 = parse_meeting_minutes_json(
                    r#"{"schemaVersion":2,"title":"接口契约评审","overview":"明确了跨层 JSON 契约","topics":[{"text":"接口契约评审","summary":"保持 C ABI v2 不变","sources":["S1"]}],"decisions":[{"text":"采用单一 workspaces 投影信封","sources":["S1"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                    &w.record("ad-1").unwrap().aggregate.spine,
                )
                .unwrap();
                w.complete_summary(&key1, minutes1)?;
                w.propose_item(
                    ItemKind::Task,
                    "补齐全天时间线回退测试",
                    vec![SourceRef {
                        record_id: "ad-1".into(),
                        segment_id: s1,
                    }],
                )?;

                w.insert_record(
                    "ad-2".into(),
                    "录音 2".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW + 130,
                    60_000,
                )?;
                w.group_all_day(
                    "ad-2",
                    AllDaySegment {
                        run_id: "day-run-1".into(),
                        ordinal: 2,
                    },
                )?;
                w.append_transcript("ad-2", "继续确认空档展示规则", 0, 20_000, "asr")?;

                w.insert_record(
                    "ad-3".into(),
                    "下午同步".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW + 600,
                    60_000,
                )?;
                w.group_all_day(
                    "ad-3",
                    AllDaySegment {
                        run_id: "day-run-2".into(),
                        ordinal: 1,
                    },
                )?;
                w.append_transcript("ad-3", "下午复盘进度", 0, 20_000, "asr")?;
                w.set_capture_lanes(
                    "ad-3",
                    vec![CaptureLaneRecord {
                        lane: "microphone".into(),
                        timeline: vec![
                            CaptureSpan {
                                epoch: 0,
                                start_ns: 0,
                                sample_offset: 0,
                                sample_count: 480_000,
                            },
                            CaptureSpan {
                                epoch: 1,
                                start_ns: 35_000_000_000,
                                sample_offset: 480_000,
                                sample_count: 480_000,
                            },
                        ],
                        asset_id: Some("ad-3".into()),
                        sample_rate: Some(16_000),
                        duration_ms: 60_000,
                        interruption: None,
                    }],
                )?;
                Ok(())
            })
            .unwrap();
    }

    let mut rt = KoeRuntime::open(&sb.0).unwrap();
    let snap: Value = serde_json::from_str(&rt.snapshot_json(NOW + 700)).unwrap();
    let all_day = &snap["workspaces"]["allDay"];
    assert_eq!(all_day["eventCount"], 3);
    assert_eq!(all_day["pauseCount"], 1);
    assert_eq!(all_day["gapCount"], 1);

    let spans = all_day["spans"].as_array().unwrap();
    let span_bounds: Vec<(u64, u64)> = spans
        .iter()
        .map(|s| {
            (
                s["startEpochSec"].as_u64().unwrap(),
                s["endEpochSec"].as_u64().unwrap(),
            )
        })
        .collect();
    assert!(
        span_bounds.windows(2).all(|w| w[0].1 <= w[1].0),
        "allDay spans must be strictly chronological: {spans:?}"
    );
    assert!(spans.iter().any(|s| s["kind"] == "event" && s["recordIds"] == json!(["ad-1", "ad-2"])));
    assert!(spans.iter().any(|s| s["kind"] == "pause" && s["recordId"] == "ad-3"));
    assert!(spans.iter().any(|s| s["kind"] == "unrecorded_gap"));
    assert_eq!(all_day["reviewTasks"].as_array().unwrap().len(), 1);
    assert_eq!(all_day["reviewDecisions"].as_array().unwrap().len(), 1);
    assert!(
        all_day["dailyReview"]["overview"]
            .as_str()
            .unwrap()
            .contains("明确了跨层 JSON 契约")
    );

    let bad = send_raw_at(
        &mut rt,
        NOW + 701,
        json!({ "type": "select_all_day_date", "date": "2026/99/99" }),
    );
    assert_eq!(bad["error"], "日期格式无效");

    let empty_day = send_at(
        &mut rt,
        NOW + 702,
        json!({ "type": "select_all_day_date", "date": "2020-01-02" }),
    );
    assert_eq!(empty_day["workspaces"]["allDay"]["selectedDate"], "2020-01-02");
    assert_eq!(empty_day["workspaces"]["allDay"]["spans"], json!([]));
    assert!(
        empty_day["workspaces"]["allDay"]["dailyReview"].is_null(),
        "empty day must not fabricate dailyReview"
    );
}

#[test]
fn live_minutes_workspace_projects_retrospective_meetings_and_coverage_when_idle() {
    let sb = new_sandbox();
    {
        let mut store = ProductStore::open(&sb.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "mtg-1".into(),
                    "架构周会".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW,
                    100_000,
                )?;
                w.set_record_mode("mtg-1", RecordMode::Meeting)?;
                let _s1 = w.append_transcript("mtg-1", "先过一下引擎层覆盖率指标", 0, 50_000, "asr")?;
                let s2 = w.append_transcript("mtg-1", "确认会后整理与实时整理分层", 50_000, 80_000, "asr")?;
                let key = w.begin_analysis("mtg-1", AnalysisStage::Summarizing)?;
                let minutes = parse_meeting_minutes_json(
                    r#"{"schemaVersion":2,"title":"架构周会","overview":"完成会议纪要覆盖率定义","topics":[{"text":"覆盖率指标","summary":"转写覆盖率与纪要引用覆盖率分开展示","sources":["S1"]}],"decisions":[{"text":"往期会议在空闲时直接可回看","sources":["S2"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                    &w.record("mtg-1").unwrap().aggregate.spine,
                )
                .unwrap();
                w.complete_summary(&key, minutes)?;
                let item_id = w.propose_item(
                    ItemKind::Task,
                    "验证窄窗口单栏切换",
                    vec![SourceRef {
                        record_id: "mtg-1".into(),
                        segment_id: s2,
                    }],
                )?;
                w.review_item(&item_id, ReviewDecision::Accept)?;

                w.insert_record(
                    "mtg-2".into(),
                    "设计走查".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW + 50,
                    60_000,
                )?;
                w.set_record_mode("mtg-2", RecordMode::Meeting)?;
                w.append_transcript("mtg-2", "核对字号梯度与无中点规范", 0, 30_000, "asr")?;
                Ok(())
            })
            .unwrap();
    }

    let mut rt = KoeRuntime::open(&sb.0).unwrap();
    let snap: Value = serde_json::from_str(&rt.snapshot_json(NOW + 100)).unwrap();
    assert!(
        snap.get("liveMinutes").is_none(),
        "top-level legacy liveMinutes key must be absent"
    );

    let lm = &snap["workspaces"]["liveMinutes"];
    assert_eq!(lm["isActive"], false);
    assert_eq!(lm["selectedRecordId"], "mtg-2");
    assert_eq!(lm["pastMeetings"].as_array().unwrap().len(), 2);

    let switched = send_at(
        &mut rt,
        NOW + 101,
        json!({ "type": "select_live_minutes_record", "recordId": "mtg-1" }),
    );
    let lm1 = &switched["workspaces"]["liveMinutes"];
    assert_eq!(lm1["selectedRecordId"], "mtg-1");
    assert_eq!(lm1["coverage"]["transcriptPercent"], 80);
    assert_eq!(lm1["coverage"]["minutesPercent"], 100);
    assert_eq!(lm1["coverage"]["consolidationStage"], "ready");
    assert!(!lm1["finalSections"].as_array().unwrap().is_empty());
    let items = lm1["actionItems"].as_array().unwrap();
    assert_eq!(items.len(), 2);
    assert!(items
        .iter()
        .any(|i| i["kind"] == "task" && i["state"] == "accepted" && i["text"] == "验证窄窗口单栏切换"));
    assert!(items
        .iter()
        .any(|i| i["kind"] == "memory" && i["state"] == "proposed"));
}

#[test]
fn export_workspace_markdown_supports_record_and_all_day() {
    let sb = new_sandbox();
    {
        let mut store = ProductStore::open(&sb.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "qn-exp".into(),
                    "导出测试闪记".into(),
                    RecordOrigin::Note,
                    0,
                    NOW,
                    0,
                )?;
                w.set_record_mode("qn-exp", RecordMode::QuickNote)?;
                w.set_record_project("qn-exp", Some("导出专项"))?;
                let _s1 = w.append_transcript("qn-exp", "这是第一段原始文字。", 0, 0, "manual")?;
                let key = w.begin_analysis("qn-exp", AnalysisStage::Summarizing)?;
                let qn_minutes = parse_meeting_minutes_json(
                    r#"{"schemaVersion":2,"title":"导出测试闪记","overview":"测试导出摘要","topics":[],"decisions":[{"text":"原文必须排在最前","sources":["S1"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                    &w.record("qn-exp").unwrap().aggregate.spine,
                )
                .unwrap();
                w.complete_summary(&key, qn_minutes)?;

                w.insert_record(
                    "ad-exp".into(),
                    "上午站会".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW,
                    60_000,
                )?;
                w.group_all_day(
                    "ad-exp",
                    AllDaySegment {
                        run_id: "run-exp".into(),
                        ordinal: 1,
                    },
                )?;
                w.append_transcript("ad-exp", "全天切片原文行", 0, 10_000, "asr")?;
                Ok(())
            })
            .unwrap();
    }

    let mut rt = KoeRuntime::open(&sb.0).unwrap();
    let initial: Value = serde_json::from_str(&rt.snapshot_json(NOW)).unwrap();
    let selected_date = initial["workspaces"]["allDay"]["selectedDate"]
        .as_str()
        .unwrap()
        .to_owned();

    let raw_only_path = sb.0.join("qn-raw.md");
    let exported = send_at(
        &mut rt,
        NOW,
        json!({
            "type": "export_workspace_markdown",
            "recordId": "qn-exp",
            "path": raw_only_path,
            "includeAnalysis": false,
            "includeSources": false
        }),
    );
    assert_eq!(exported["notice"], "已导出 Markdown");
    let raw_md = std::fs::read_to_string(&raw_only_path).unwrap();
    assert!(raw_md.contains("## 原文"));
    assert!(raw_md.contains("这是第一段原始文字。"));
    assert!(!raw_md.contains("## AI 整理"));

    let full_path = sb.0.join("qn-full.md");
    send_at(
        &mut rt,
        NOW,
        json!({
            "type": "export_workspace_markdown",
            "recordId": "qn-exp",
            "path": full_path,
            "includeAnalysis": true,
            "includeSources": true
        }),
    );
    let full_md = std::fs::read_to_string(&full_path).unwrap();
    let raw_idx = full_md.find("## 原文").unwrap();
    let ai_idx = full_md.find("## AI 整理").unwrap();
    assert!(raw_idx < ai_idx, "raw transcript must precede AI analysis");

    let day_path = sb.0.join("day.md");
    let day_exported = send_at(
        &mut rt,
        NOW,
        json!({
            "type": "export_workspace_markdown",
            "date": selected_date,
            "path": day_path,
            "includeAnalysis": true,
            "includeSources": true
        }),
    );
    assert_eq!(day_exported["notice"], "已导出当日记录 Markdown");
    let day_md = std::fs::read_to_string(&day_path).unwrap();
    assert!(day_md.contains("# 全天听记"));
    assert!(day_md.contains("全天切片原文行"));
}

#[test]
fn create_note_stay_on_page_session_exclusivity_can_start_and_archived_quick_note_filtering() {
    let (mut rt, _sb) = runtime();

    send_at(&mut rt, NOW, json!({ "type": "navigate", "section": "notes" }));
    let saved = send_at(
        &mut rt,
        NOW + 1,
        json!({
            "type": "create_note",
            "title": "页内保存闪记",
            "text": "直接留在随心闪记页",
            "stayOnPage": true
        }),
    );
    assert_eq!(saved["section"], "notes", "stayOnPage must keep user on notes");
    assert_eq!(saved["notice"], "记录已保存");
    let created_id = saved["workspaces"]["quickNote"]["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(saved["workspaces"]["quickNote"]["canStart"], true);
    assert_eq!(saved["workspaces"]["allDay"]["canStart"], true);
    assert_eq!(saved["workspaces"]["liveMinutes"]["canStart"], true);

    let back_to_picker = send_at(&mut rt, NOW + 1, json!({ "type": "back" }));
    assert_eq!(
        back_to_picker["section"], "today",
        "stayOnPage must not push Detail onto back stack"
    );
    assert_eq!(back_to_picker["canGoBack"], false);
    send_at(&mut rt, NOW + 1, json!({ "type": "navigate", "section": "notes" }));

    let archived = send_at(
        &mut rt,
        NOW + 2,
        json!({ "type": "set_record_archived", "recordId": created_id, "archived": true }),
    );
    assert_eq!(
        archived["workspaces"]["quickNote"]["totalCount"], 0,
        "archived QuickNote must be excluded from active QuickNote workspace"
    );
    assert_eq!(archived["workspaces"]["quickNote"]["cards"], json!([]));

    let started = send_at(
        &mut rt,
        NOW + 4,
        json!({ "type": "start_capture_mode", "mode": "quick_note", "stayOnPage": true }),
    );
    let active_cards: Vec<&Value> = started["workspaces"]["picker"]["cards"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|c| c["isSessionActive"] == true)
        .collect();
    assert_eq!(active_cards.len(), 1, "at most one mode card may be active");
    assert_eq!(active_cards[0]["id"], "notes");
    assert_eq!(started["workspaces"]["quickNote"]["canStart"], false);
    assert_eq!(started["workspaces"]["allDay"]["canStart"], false);
    assert_eq!(started["workspaces"]["liveMinutes"]["canStart"], false);
}

#[test]
fn live_minutes_isolation_consolidation_gate_chronological_day_export_and_cloud_retry_provenance() {
    let sb = new_sandbox();
    {
        let mut store = ProductStore::open(&sb.0).unwrap();
        store
            .transact(|w| {
                w.insert_record(
                    "qn-only".into(),
                    "非会议闪记".into(),
                    RecordOrigin::Note,
                    0,
                    NOW,
                    0,
                )?;
                w.set_record_mode("qn-only", RecordMode::QuickNote)?;
                w.append_transcript("qn-only", "闪记文本", 0, 0, "manual")?;

                w.insert_record(
                    "mtg-stale".into(),
                    "待重算会议".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW + 10,
                    60_000,
                )?;
                w.set_record_mode("mtg-stale", RecordMode::Meeting)?;
                w.set_record_project("mtg-stale", Some("专项评审"))?;
                let s1 = w.append_transcript("mtg-stale", "初始会议句子", 0, 20_000, "asr")?;
                let key = w.begin_analysis("mtg-stale", AnalysisStage::Summarizing)?;
                let mins = parse_meeting_minutes_json(
                    r#"{"schemaVersion":2,"title":"待重算会议","overview":"初版纪要","topics":[{"text":"议题","summary":"初版摘要","sources":["S1"]}],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                    &w.record("mtg-stale").unwrap().aggregate.spine,
                )
                .unwrap();
                w.complete_summary(&key, mins)?;
                w.edit_segment_text(
                    &SourceRef {
                        record_id: "mtg-stale".into(),
                        segment_id: s1,
                    },
                    "修改后的会议句子",
                )?;

                w.insert_record(
                    "z-morning".into(),
                    "早间记录".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW + 20,
                    60_000,
                )?;
                w.group_all_day(
                    "z-morning",
                    AllDaySegment {
                        run_id: "day-sort".into(),
                        ordinal: 1,
                    },
                )?;
                w.append_transcript("z-morning", "早上八点讨论", 0, 10_000, "asr")?;
                let kz = w.begin_analysis("z-morning", AnalysisStage::Summarizing)?;
                let mz = parse_meeting_minutes_json(
                    r#"{"schemaVersion":2,"title":"早间记录","overview":"早间复盘总览","topics":[],"decisions":[{"text":"早间先定目标","sources":["S1"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                    &w.record("z-morning").unwrap().aggregate.spine,
                )
                .unwrap();
                w.complete_summary(&kz, mz)?;

                w.insert_record(
                    "a-afternoon".into(),
                    "午后记录".into(),
                    RecordOrigin::Microphone,
                    0,
                    NOW + 400,
                    60_000,
                )?;
                w.group_all_day(
                    "a-afternoon",
                    AllDaySegment {
                        run_id: "day-sort".into(),
                        ordinal: 2,
                    },
                )?;
                w.append_transcript("a-afternoon", "下午两点讨论", 0, 10_000, "asr")?;
                let ka = w.begin_analysis("a-afternoon", AnalysisStage::Summarizing)?;
                let ma = parse_meeting_minutes_json(
                    r#"{"schemaVersion":2,"title":"午后记录","overview":"午后推进总览","topics":[],"decisions":[{"text":"午后确认排期","sources":["S1"]}],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                    &w.record("a-afternoon").unwrap().aggregate.spine,
                )
                .unwrap();
                w.complete_summary(&ka, ma)?;
                Ok(())
            })
            .unwrap();
    }

    let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(640, 16000).to_vec();
    wav.extend(vec![0u8; 640]);
    std::fs::create_dir_all(sb.0.join("audio")).unwrap();
    std::fs::write(sb.0.join("audio").join("mtg-stale.wav"), &wav).unwrap();

    let mut rt = KoeRuntime::open(&sb.0).unwrap();
    let reject = send_raw_at(
        &mut rt,
        NOW + 500,
        json!({ "type": "select_live_minutes_record", "recordId": "qn-only" }),
    );
    assert!(
        !reject["error"].is_null(),
        "select_live_minutes_record must reject non-Meeting records"
    );

    let idle_snap: Value = serde_json::from_str(&rt.snapshot_json(NOW + 501)).unwrap();
    let lm_idle = &idle_snap["workspaces"]["liveMinutes"];
    assert_eq!(lm_idle["selectedRecordId"], "mtg-stale");
    assert_eq!(lm_idle["coverage"]["consolidationStage"], "stale");
    assert_eq!(
        lm_idle["finalSections"],
        json!([]),
        "finalSections must remain empty when consolidationStage != ready"
    );

    let active_mtg = send_at(
        &mut rt,
        NOW + 502,
        json!({ "type": "start_capture_mode", "mode": "meeting", "stayOnPage": true }),
    );
    let active_id = active_mtg["workspaces"]["liveMinutes"]["activeRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        !active_mtg["workspaces"]["liveMinutes"]["pastMeetings"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["id"] == active_id),
        "pastMeetings must exclude activeRecordId while meeting is in progress"
    );
    let _ = finish_mic_capture(&mut rt, &active_mtg, NOW + 502);

    let selected_date = idle_snap["workspaces"]["allDay"]["selectedDate"]
        .as_str()
        .unwrap()
        .to_owned();
    let day_export_path = sb.0.join("sorted-day.md");
    send_at(
        &mut rt,
        NOW + 505,
        json!({
            "type": "export_workspace_markdown",
            "date": selected_date,
            "path": day_export_path,
            "includeAnalysis": true,
            "includeSources": false
        }),
    );
    let day_md = std::fs::read_to_string(&day_export_path).unwrap();
    let morning_dec = day_md.find("早间先定目标").unwrap();
    let afternoon_dec = day_md.find("午后确认排期").unwrap();
    assert!(
        morning_dec < afternoon_dec,
        "All-Day decisions must export in chronological order rather than BTreeMap ID order: {day_md}"
    );
    let morning_ov = day_md.find("早间复盘总览").unwrap();
    let afternoon_ov = day_md.find("午后推进总览").unwrap();
    assert!(
        morning_ov < afternoon_ov,
        "All-Day overviews must export in chronological order: {day_md}"
    );

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    send_at(
        &mut rt,
        NOW + 510,
        json!({
            "type": "configure_provider",
            "apiKey": "policy-fixture",
            "model": "fixture",
            "asrEndpoint": format!("ws://{}", listener.local_addr().unwrap())
        }),
    );
    send_at(
        &mut rt,
        NOW + 510,
        json!({ "type": "configure_speech", "engine": "cloud" }),
    );
    send_at(
        &mut rt,
        NOW + 510,
        json!({ "type": "set_meeting_audio_policy", "policy": "cloud_allowed" }),
    );
    let retried = send_at(
        &mut rt,
        NOW + 511,
        json!({ "type": "transcribe", "recordId": "mtg-stale" }),
    );
    let retry_id = retried["selectedRecordId"].as_str().unwrap();
    assert!(retry_id.starts_with("mtg-stale-retry-"));
    assert_eq!(retried["detail"]["mode"], "meeting");
    assert_eq!(retried["detail"]["project"], "专项评审");
}
