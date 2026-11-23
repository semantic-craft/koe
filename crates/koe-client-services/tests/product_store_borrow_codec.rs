#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

use koe_client_services::product_store::{ProductStore, StoreError, PRODUCT_WORKSPACE_FILE};
use koe_engine::hash::sha256_hex;
use koe_engine::minutes::parse_meeting_minutes_json;
use koe_engine::product::*;

static NEXT: AtomicU64 = AtomicU64::new(1);

struct TempWorkspace(PathBuf);

impl TempWorkspace {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "koe-borrow-codec-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for TempWorkspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn populate_rich_workspace(store: &mut ProductStore) {
    store
        .transact(|w| {
            let mut provider = w.provider_configuration().clone();
            provider.meeting_audio_policy = MeetingAudioPolicy::CloudAllowed;
            provider.speech_engine = SpeechEngine::Downloaded("whisper-tiny".into());
            provider.enable_thinking = true;
            provider.qwen_workspace_id = "ws-bj-1".into();
            provider.credential = CredentialBinding::Saved("qwen-ref-1".into());
            provider.deepseek_credential = CredentialBinding::Saved("ds-ref-1".into());
            provider.retired_credentials = vec!["old-ref-1".into()];
            provider.pending_credentials = vec!["pending-ref-1".into()];
            w.configure_provider(provider)?;
            w.set_ble_auto_connect(false);
            w.record_purged_bean_file_id(7001);
            w.record_purged_bean_file_id(7002);

            w.insert_record(
                "rec-fresh".into(),
                "Sprint Planning".into(),
                RecordOrigin::Microphone,
                0,
                1_800_000_000,
                12_000,
            )?;
            w.set_record_mode("rec-fresh", RecordMode::Meeting)?;
            w.set_record_project("rec-fresh", Some("Core Roadmap"))?;
            w.bind_speech_engine("rec-fresh", SpeechEngine::Cloud)?;
            let seg1 = w.append_transcript(
                "rec-fresh",
                "We approved the release schedule with 80% test coverage.",
                0,
                4_000,
                "qwen",
            )?;
            let seg2 = w.append_transcript(
                "rec-fresh",
                "Alice will send the checklist tomorrow.",
                4_000,
                8_000,
                "qwen",
            )?;
            w.set_segment_speaker(
                &SourceRef {
                    record_id: "rec-fresh".into(),
                    segment_id: seg1,
                },
                Some("Bob"),
            )?;
            w.edit_segment_text(
                &SourceRef {
                    record_id: "rec-fresh".into(),
                    segment_id: seg1,
                },
                "We approved the release schedule with 80% coverage.",
            )?;
            w.add_highlight(SourceRef {
                record_id: "rec-fresh".into(),
                segment_id: seg2,
            })?;
            w.finish_capture("rec-fresh", 12_000, &[2_500, 6_000])?;
            w.set_capture_lanes(
                "rec-fresh",
                vec![CaptureLaneRecord {
                    lane: "microphone".into(),
                    asset_id: Some("rec-fresh".into()),
                    sample_rate: Some(16_000),
                    duration_ms: 12_000,
                    interruption: None,
                    timeline: vec![CaptureSpan {
                        epoch: 1,
                        start_ns: 100_000,
                        sample_offset: 0,
                        sample_count: 192_000,
                    }],
                }],
            )?;
            let sum_key = w.begin_analysis("rec-fresh", AnalysisStage::Summarizing)?;
            let minutes = parse_meeting_minutes_json(
                r#"{"schemaVersion":2,"title":"Sprint Planning","overview":"We approved the release schedule with 80% coverage.","topics":[{"text":"Release schedule","summary":"Approved with 80% coverage.","sources":["S1"]}],"decisions":[{"text":"Approved release schedule","sources":["S1"]}],"actions":[{"text":"Send checklist","owner":"Alice","due":"tomorrow","sources":["S2"]}],"questions":[]}"#,
                &w.record("rec-fresh").unwrap().aggregate.spine,
            )
            .unwrap();
            w.complete_summary(&sum_key, minutes)?;

            w.insert_record(
                "rec-stale".into(),
                "All Day Slice".into(),
                RecordOrigin::Bean,
                42,
                1_800_001_000,
                5_000,
            )?;
            w.group_all_day(
                "rec-stale",
                AllDaySegment {
                    run_id: "run-2026".into(),
                    ordinal: 1,
                },
            )?;
            let asr_key = w.begin_analysis("rec-stale", AnalysisStage::Transcribing)?;
            w.accept_transcript_with_speaker(
                &asr_key,
                TranscriptFinal {
                    final_id: "f-1",
                    text: "Budget target is 50% complete.",
                    start_ms: 0,
                    end_ms: 2_500,
                    provider: "qwen",
                    speaker: Some("Carol"),
                },
            )?;
            w.finish_transcription(&asr_key)?;
            let stale_sum_key = w.begin_analysis("rec-stale", AnalysisStage::Summarizing)?;
            let stale_minutes = parse_meeting_minutes_json(
                r#"{"schemaVersion":2,"title":"All Day Slice","overview":"Budget target is 50% complete.","topics":[{"text":"Budget","summary":"50% complete.","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}"#,
                &w.record("rec-stale").unwrap().aggregate.spine,
            )
            .unwrap();
            w.complete_summary(&stale_sum_key, stale_minutes)?;
            w.append_transcript(
                "rec-stale",
                "Follow up note added after summary.",
                2_500,
                5_000,
                "manual",
            )?;

            w.insert_record(
                "rec-archived".into(),
                "Archived Note".into(),
                RecordOrigin::Note,
                0,
                1_800_002_000,
                1_000,
            )?;
            w.append_transcript("rec-archived", "Locked decision.", 0, 1_000, "manual")?;
            w.set_record_archived("rec-archived", true)?;

            w.insert_record(
                "rec-trashed".into(),
                "Trashed Draft".into(),
                RecordOrigin::ImportedText,
                0,
                1_800_003_000,
                1_000,
            )?;
            w.append_transcript("rec-trashed", "Discard me.", 0, 1_000, "manual")?;
            w.trash_record("rec-trashed", 1_800_003_500_000)?;

            let item_ids: Vec<String> = w.items().keys().cloned().collect();
            for id in item_ids {
                w.review_item(&id, ReviewDecision::Accept)?;
                if w.items()[&id].kind == ItemKind::Task {
                    w.complete_task(&id, true)?;
                }
            }

            let req = w
                .begin_ask(
                    SearchScope::Record("rec-fresh".into()),
                    "What is the coverage?",
                    1_800_004_000,
                )?
                .expect("grounded ask request");
            w.complete_ask(req.operation, "Coverage is 80% [S1].")?;
            let _pending_req = w.begin_ask(SearchScope::All, "Who sends the checklist?", 1_800_004_100)?;
            Ok(())
        })
        .unwrap();
}

#[test]
fn borrow_codec_serializes_byte_exact_json_and_round_trips_all_workspace_fields() {
    let dir = TempWorkspace::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    populate_rich_workspace(&mut store);

    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let raw_before_reopen = fs::read_to_string(&json_path).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&raw_before_reopen).unwrap();
    assert_eq!(parsed["version"], 1);
    assert_eq!(parsed["ble_auto_connect"], false);
    assert_eq!(parsed["purged_bean_file_ids"], serde_json::json!([7001, 7002]));
    assert!(parsed.get("companion_mode").is_none());
    assert!(parsed.get("standby_scratch_file_ids").is_none());
    assert!(parsed.get("reclaimed_standby_file_ids").is_none());
    assert_eq!(
        parsed["provider"]["deepseek_credential"],
        serde_json::json!({"state": "saved", "reference": "ds-ref-1"})
    );
    assert_eq!(
        parsed["provider"]["pending_credentials"],
        serde_json::json!(["pending-ref-1"])
    );

    let digest = sha256_hex(raw_before_reopen.as_bytes());
    assert_eq!(
        digest,
        "e325e9ae6d7c2e37de4cb1089225cc1121c272d8c79c4d894643b6bb60c59e96",
        "borrow-based PersistedWorkspaceRef JSON must stay byte-for-byte identical to the owned-DTO format"
    );
    drop(store);

    let mut reopened = ProductStore::open(&dir.0).unwrap();
    assert!(reopened.workspace().ask_session().messages.len() >= 4);
    assert!(reopened.workspace().pending_ask().is_none());
    let fresh = reopened.workspace().record("rec-fresh").unwrap();
    assert_eq!(fresh.mode, RecordMode::Meeting);
    assert_eq!(fresh.project.as_deref(), Some("Core Roadmap"));
    assert_eq!(fresh.speech_engine, Some(SpeechEngine::Cloud));
    assert!(!fresh.is_minutes_stale());
    assert_eq!(fresh.capture_lanes.len(), 1);
    assert_eq!(fresh.capture_lanes[0].timeline.len(), 1);
    assert_eq!(fresh.aggregate.spine.segments()[0].speaker.as_deref(), Some("Bob"));
    assert!(fresh.aggregate.spine.segments()[0].original_text.is_some());

    let stale = reopened.workspace().record("rec-stale").unwrap();
    assert_eq!(stale.mode, RecordMode::AllDay);
    assert!(stale.is_minutes_stale());
    assert_eq!(stale.final_keys().len(), 1);
    assert!(reopened.workspace().record("rec-archived").unwrap().is_archived());
    assert!(reopened.workspace().record("rec-trashed").unwrap().is_trashed());

    let mtime_before = fs::metadata(&json_path).unwrap().modified().unwrap();
    reopened.transact(|_| Ok(())).unwrap();
    assert_eq!(
        fs::metadata(&json_path).unwrap().modified().unwrap(),
        mtime_before
    );

    let rev_before = reopened.workspace().revision();
    let err = reopened.transact(|w| {
        w.rename_record("rec-fresh", "Should Roll Back")?;
        Err::<(), _>(ProductError::InvalidTransition)
    });
    assert!(matches!(err, Err(StoreError::Domain(ProductError::InvalidTransition))));
    assert_eq!(reopened.workspace().revision(), rev_before);
    assert_eq!(
        reopened.workspace().record("rec-fresh").unwrap().title,
        "Sprint Planning"
    );
}

#[test]
fn single_pass_decode_enforces_all_minutes_grounding_and_revision_invariants() {
    let dir = TempWorkspace::new();
    let mut store = ProductStore::open(&dir.0).unwrap();
    populate_rich_workspace(&mut store);
    drop(store);

    let json_path = dir.0.join(PRODUCT_WORKSPACE_FILE);
    let valid_raw = fs::read_to_string(&json_path).unwrap();

    let mut ungrounded: serde_json::Value = serde_json::from_str(&valid_raw).unwrap();
    for rec in ungrounded["records"].as_array_mut().unwrap() {
        if rec["id"] == "rec-fresh" {
            rec["minutes"] = serde_json::json!(
                r#"{"schemaVersion":2,"title":"Sprint Planning","overview":"We approved the release schedule with 99% coverage.","topics":[{"text":"Release schedule","summary":"Approved with 99% coverage.","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}"#
            );
        }
    }
    fs::write(&json_path, serde_json::to_string(&ungrounded).unwrap()).unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));

    let mut bad_stale_citation: serde_json::Value = serde_json::from_str(&valid_raw).unwrap();
    for rec in bad_stale_citation["records"].as_array_mut().unwrap() {
        if rec["id"] == "rec-stale" {
            rec["minutes"] = serde_json::json!(
                r#"{"schemaVersion":2,"title":"All Day Slice","overview":"Budget target is 50% complete.","topics":[{"text":"Budget","summary":"50% complete.","sources":["S99"]}],"decisions":[],"actions":[],"questions":[]}"#
            );
        }
    }
    fs::write(
        &json_path,
        serde_json::to_string(&bad_stale_citation).unwrap(),
    )
    .unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));

    let mut orphan_minutes_rev: serde_json::Value = serde_json::from_str(&valid_raw).unwrap();
    for rec in orphan_minutes_rev["records"].as_array_mut().unwrap() {
        if rec["id"] == "rec-archived" {
            rec["minutes_revision"] = serde_json::json!(1);
        }
    }
    fs::write(
        &json_path,
        serde_json::to_string(&orphan_minutes_rev).unwrap(),
    )
    .unwrap();
    assert!(matches!(
        ProductStore::open(&dir.0),
        Err(StoreError::InvalidData(_))
    ));

    fs::write(&json_path, &valid_raw).unwrap();
    assert!(ProductStore::open(&dir.0).is_ok());
}
