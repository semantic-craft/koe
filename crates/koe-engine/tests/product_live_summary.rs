#![allow(clippy::unwrap_used, clippy::expect_used)]

use koe_engine::domain::{MeetingMinutes, UtteranceSpine};
use koe_engine::minutes::parse_meeting_minutes_json;
use koe_engine::product::*;

fn recording() -> (ProductWorkspace, RequestKey) {
    let mut w = ProductWorkspace::new();
    w.insert_record(
        "a".into(),
        "alpha".into(),
        RecordOrigin::Microphone,
        0,
        100,
        0,
    )
    .unwrap();
    let asr = w.begin_analysis("a", AnalysisStage::Transcribing).unwrap();
    w.accept_transcript(&asr, "one", "Send alpha report", 0, 1000, "asr")
        .unwrap();
    (w, asr)
}

fn minutes(spine: &UtteranceSpine) -> MeetingMinutes {
    parse_meeting_minutes_json(r#"{"schemaVersion":2,"title":"alpha","overview":"Send alpha report","topics":[],"decisions":[],"actions":[{"text":"Send alpha report","sources":["S1"]}],"questions":[]}"#, spine).unwrap()
}

#[test]
fn live_minutes_complete_after_appended_finals_without_stopping_asr_or_proposing_items() {
    let (mut w, asr) = recording();
    let snapshot = w.record("a").unwrap().aggregate.spine.clone();
    let live = w.begin_live_summary("a").unwrap();
    assert_eq!(w.begin_live_summary("a"), Err(ProductError::Busy));
    w.accept_transcript(&asr, "two", "alpha continues", 1000, 2000, "asr")
        .unwrap();
    let output = minutes(&snapshot);
    w.complete_live_summary(&live, &snapshot, output.clone())
        .unwrap();
    let record = w.record("a").unwrap();
    assert_eq!(record.aggregate.minutes, Some(output.clone()));
    assert_eq!(record.minutes_revision(), Some(live.input_revision));
    assert!(record.is_minutes_stale());
    assert_eq!(
        record.analysis,
        AnalysisState::Pending {
            key: asr.clone(),
            stage: AnalysisStage::Transcribing
        }
    );
    assert!(w.items().is_empty());
    w.accept_transcript(&asr, "three", "alpha continues again", 2000, 3000, "asr")
        .unwrap();
    assert_eq!(w.record("a").unwrap().aggregate.minutes, Some(output));
    let next = w.begin_live_summary("a").unwrap();
    w.fail_live_summary(&next, "provider error").unwrap();
    assert!(matches!(
        w.record("a").unwrap().live_summary,
        AnalysisState::Failed { .. }
    ));
    w.finish_transcription(&asr).unwrap();
    let final_key = w.begin_analysis("a", AnalysisStage::Summarizing).unwrap();
    let output = minutes(&w.record("a").unwrap().aggregate.spine);
    w.complete_summary(&final_key, output).unwrap();
    assert_eq!(w.record("a").unwrap().live_summary, AnalysisState::Idle);
    assert_eq!(w.items().len(), 1);
}

#[test]
fn replaced_asr_source_rejects_live_minutes_and_failure_leaves_asr_pending() {
    let (mut w, asr) = recording();
    let snapshot = w.record("a").unwrap().aggregate.spine.clone();
    let live = w.begin_live_summary("a").unwrap();
    w.accept_transcript(&asr, "one", "Corrected alpha report", 0, 1000, "asr")
        .unwrap();
    assert_eq!(
        w.complete_live_summary(&live, &snapshot, minutes(&snapshot)),
        Err(ProductError::StaleRequest)
    );
    w.fail_live_summary(&live, "source changed").unwrap();
    assert_eq!(
        w.record("a").unwrap().analysis,
        AnalysisState::Pending {
            key: asr.clone(),
            stage: AnalysisStage::Transcribing
        }
    );
    w.accept_transcript(&asr, "two", "alpha continues", 1000, 2000, "asr")
        .unwrap();
}

#[test]
fn restored_live_request_is_validated_and_interrupted_independently() {
    let (mut w, asr) = recording();
    let live = w.begin_live_summary("a").unwrap();
    w.finish_transcription(&asr).unwrap();
    let state = w.export_state();
    let mut bad = state.clone();
    bad.next_operation = live.attempt;
    assert_eq!(
        ProductWorkspace::restore(bad),
        Err(ProductError::InvalidPersistedState)
    );
    for key in [
        RequestKey {
            record_id: "wrong".into(),
            ..live.clone()
        },
        RequestKey {
            attempt: 0,
            ..live.clone()
        },
        RequestKey {
            input_revision: 999,
            ..live.clone()
        },
    ] {
        let mut bad = state.clone();
        bad.records[0].live_summary = AnalysisState::Pending {
            key,
            stage: AnalysisStage::Summarizing,
        };
        assert_eq!(
            ProductWorkspace::restore(bad),
            Err(ProductError::InvalidPersistedState)
        );
    }
    let mut bad = state.clone();
    bad.records[0].live_summary = AnalysisState::Pending {
        key: live.clone(),
        stage: AnalysisStage::Transcribing,
    };
    assert_eq!(
        ProductWorkspace::restore(bad),
        Err(ProductError::InvalidPersistedState)
    );
    let mut restored = ProductWorkspace::restore(state).unwrap();
    assert!(restored.interrupt_pending());
    let record = restored.record("a").unwrap();
    assert_eq!(record.analysis, AnalysisState::Idle);
    assert_eq!(
        record.live_summary,
        AnalysisState::Interrupted { key: live }
    );
    assert!(!restored.interrupt_pending());
}

#[test]
fn correcting_a_published_asr_source_removes_the_invalid_live_minutes() {
    let (mut w, asr) = recording();
    let snapshot = w.record("a").unwrap().aggregate.spine.clone();
    let live = w.begin_live_summary("a").unwrap();
    w.complete_live_summary(&live, &snapshot, minutes(&snapshot))
        .unwrap();
    w.accept_transcript(&asr, "one", "Corrected alpha report", 0, 1000, "asr")
        .unwrap();
    assert!(w.record("a").unwrap().aggregate.minutes.is_none());
}

#[test]
fn old_live_response_cannot_overwrite_or_fail_a_final_summary() {
    let (mut w, asr) = recording();
    let snapshot = w.record("a").unwrap().aggregate.spine.clone();
    let live = w.begin_live_summary("a").unwrap();
    w.finish_transcription(&asr).unwrap();
    let final_key = w.begin_analysis("a", AnalysisStage::Summarizing).unwrap();
    let final_output = minutes(&snapshot);
    w.complete_summary(&final_key, final_output.clone())
        .unwrap();
    assert_eq!(
        w.complete_live_summary(&live, &snapshot, final_output.clone()),
        Err(ProductError::StaleRequest)
    );
    assert_eq!(
        w.fail_live_summary(&live, "late failure"),
        Err(ProductError::StaleRequest)
    );
    let record = w.record("a").unwrap();
    assert_eq!(record.aggregate.minutes, Some(final_output));
    assert_eq!(
        record.analysis,
        AnalysisState::Ready {
            input_revision: final_key.input_revision
        }
    );
}
