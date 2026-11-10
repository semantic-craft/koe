use koe_engine::domain::{MeetingMinutes, SegmentId};
use koe_engine::minutes::parse_meeting_minutes_json;
use koe_engine::product::*;

fn workspace() -> ProductWorkspace {
    let mut workspace = ProductWorkspace::new();
    for id in ["a", "b"] {
        workspace
            .insert_record(
                id.to_string(),
                id.to_string(),
                RecordOrigin::Note,
                0,
                1_800_000_000,
                0,
            )
            .unwrap();
    }
    workspace
}

fn source(id: &str, ordinal: u32) -> SourceRef {
    SourceRef {
        record_id: id.to_string(),
        segment_id: SegmentId::new(ordinal).unwrap(),
    }
}

fn minutes(workspace: &ProductWorkspace, id: &str) -> MeetingMinutes {
    parse_meeting_minutes_json(r#"{"schemaVersion":2,"title":"alpha","overview":"alpha","topics":[{"text":"alpha","summary":"alpha","sources":["S1"]}],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#, &workspace.record(id).unwrap().aggregate.spine).unwrap()
}

#[test]
fn independent_records_keep_finals_and_equal_segment_ids_separate() {
    let mut w = workspace();
    let capture_a = w.begin_analysis("a", AnalysisStage::Transcribing).unwrap();
    w.accept_transcript(&capture_a, "first", "alpha recording", 0, 1000, "test")
        .unwrap();
    w.append_transcript("b", "beta recording", 0, 1000, "manual")
        .unwrap();
    w.accept_transcript(&capture_a, "second", "alpha final", 1000, 2000, "test")
        .unwrap();
    let revision = w.revision();
    w.accept_transcript(&capture_a, "second", "alpha final", 1000, 2000, "test")
        .unwrap();
    assert_eq!(w.revision(), revision, "duplicate finals are idempotent");
    w.finish_transcription(&capture_a).unwrap();
    assert_eq!(w.record("a").unwrap().aggregate.spine.len(), 2);
    assert_eq!(w.record("b").unwrap().aggregate.spine.len(), 1);
    assert_eq!(
        w.resolve_source(&source("a", 1)).unwrap().quote,
        "alpha recording"
    );
    assert_eq!(
        w.resolve_source(&source("b", 1)).unwrap().quote,
        "beta recording"
    );
    assert!(w.resolve_source(&source("missing", 1)).is_err());
    assert!(w
        .search(&SearchScope::Record("a".into()), "beta", 10)
        .unwrap()
        .is_empty());
    assert_eq!(
        w.search(&SearchScope::All, "beta", 10).unwrap()[0].source,
        source("b", 1)
    );
}

#[test]
fn stale_attempts_and_changed_input_cannot_replace_content() {
    let mut w = workspace();
    w.append_transcript("a", "alpha", 0, 1000, "manual")
        .unwrap();
    let old = w.begin_analysis("a", AnalysisStage::Summarizing).unwrap();
    let output = minutes(&w, "a");
    w.append_transcript("a", "more content", 1000, 2000, "manual")
        .unwrap();
    assert_eq!(
        w.complete_summary(&old, output),
        Err(ProductError::StaleRequest)
    );
    let current = w.begin_analysis("a", AnalysisStage::Summarizing).unwrap();
    assert_eq!(
        w.fail_analysis(&old, "late error"),
        Err(ProductError::StaleRequest)
    );
    assert!(
        matches!(&w.record("a").unwrap().analysis, AnalysisState::Pending { key, .. } if key == &current)
    );
    let output = minutes(&w, "a");
    w.complete_summary(&current, output.clone()).unwrap();
    let revision = w.revision();
    w.complete_summary(&current, output).unwrap();
    assert_eq!(w.revision(), revision);
}

#[test]
fn review_decisions_are_explicit_reversible_and_source_preserving() {
    let mut w = workspace();
    w.append_transcript("a", "submit the report", 0, 1000, "manual")
        .unwrap();
    let id = w
        .propose_item(ItemKind::Task, "submit the report", vec![source("a", 1)])
        .unwrap();
    assert_eq!(w.items()[&id].review, ReviewState::Proposed);
    assert_eq!(
        w.complete_task(&id, true),
        Err(ProductError::InvalidTransition)
    );
    w.review_item(&id, ReviewDecision::Accept).unwrap();
    w.edit_item(&id, "Send report", Some("2026-11-12".into()))
        .unwrap();
    w.complete_task(&id, true).unwrap();
    assert!(w.items()[&id].completed);
    w.complete_task(&id, false).unwrap();
    w.review_item(&id, ReviewDecision::Dismiss).unwrap();
    w.review_item(&id, ReviewDecision::Reset).unwrap();
    assert_eq!(w.items()[&id].review, ReviewState::Proposed);
    assert_eq!(
        w.resolve_source(&source("a", 1)).unwrap().quote,
        "submit the report"
    );
    assert_eq!(
        w.propose_item(ItemKind::Memory, "invented", vec![source("a", 99)]),
        Err(ProductError::InvalidSource)
    );
}

#[test]
fn ask_answers_require_request_evidence_and_cannot_cross_scopes() {
    let mut w = workspace();
    w.append_transcript("a", "alpha decision", 0, 1000, "manual")
        .unwrap();
    w.append_transcript("b", "beta decision", 0, 1000, "manual")
        .unwrap();
    let request = w
        .begin_ask(SearchScope::Record("b".into()), "beta", 1_800_000_000)
        .unwrap()
        .unwrap();
    assert_eq!(request.evidence.len(), 1);
    assert_eq!(request.evidence[0].source, source("b", 1));
    assert_eq!(
        w.complete_ask(request.operation, "beta [S2]"),
        Err(ProductError::InvalidEvidence)
    );
    assert_eq!(
        w.complete_ask(request.operation, "answer without evidence"),
        Err(ProductError::InvalidEvidence)
    );
    w.complete_ask(request.operation, "beta decision [S1]")
        .unwrap();
    let next = w
        .begin_ask(SearchScope::All, "alpha", 1_800_000_001)
        .unwrap()
        .unwrap();
    assert_eq!(
        w.complete_ask(request.operation, "beta decision [S1]"),
        Err(ProductError::StaleRequest)
    );
    w.complete_retrieval(next.operation).unwrap();
    let last = w.ask_session().messages.last().unwrap();
    assert!(
        last.notice,
        "local snippets must be labeled separately from a model answer"
    );
    assert_eq!(last.sources[0].source.recording_key, "a");
    assert_eq!(last.sources[0].source.line, Some(0));
}

#[test]
fn empty_workspace_and_unmatched_questions_never_create_fake_sources() {
    let mut w = ProductWorkspace::new();
    assert!(w
        .begin_ask(SearchScope::All, "什么决定", 100)
        .unwrap()
        .is_none());
    assert!(w.records().is_empty());
    assert!(w.items().is_empty());
    assert!(w.ask_session().messages.last().unwrap().sources.is_empty());
}

#[test]
fn highlighting_one_untimed_sentence_does_not_highlight_all_zero_offsets() {
    let mut w = workspace();
    w.append_transcript("a", "first sentence", 0, 0, "manual")
        .unwrap();
    w.append_transcript("a", "second sentence", 0, 0, "manual")
        .unwrap();
    w.add_highlight(source("a", 2)).unwrap();
    // The old timestamp representation cannot distinguish these sources.
    assert_eq!(
        w.record("a").unwrap().aggregate.bookmarks.len(),
        0,
        "untimed text must not create an ambiguous timestamp bookmark"
    );
    assert_eq!(
        w.record("a")
            .unwrap()
            .highlighted_segments
            .iter()
            .copied()
            .collect::<Vec<_>>(),
        vec![SegmentId::new(2).unwrap()]
    );
}

#[test]
fn summary_candidates_keep_due_dates_and_do_not_overwrite_user_edits() {
    let mut w = workspace();
    w.append_transcript("a", "Send alpha report", 0, 1000, "manual")
        .unwrap();
    let output = parse_meeting_minutes_json(r#"{"schemaVersion":2,"title":"alpha","overview":"Send alpha report","topics":[],"decisions":[],"actions":[{"text":"Send alpha report","sources":["S1"],"due":"2026-11-12"}],"questions":[]}"#, &w.record("a").unwrap().aggregate.spine).unwrap();
    let key = w.begin_analysis("a", AnalysisStage::Summarizing).unwrap();
    w.complete_summary(&key, output.clone()).unwrap();
    let item = w.items().values().next().unwrap();
    assert_eq!(item.due.as_deref(), Some("2026-11-12"));
    let id = item.id.clone();
    w.edit_item(&id, "Send alpha report", Some("2026-11-13".into()))
        .unwrap();
    let key = w.begin_analysis("a", AnalysisStage::Summarizing).unwrap();
    w.complete_summary(&key, output).unwrap();
    assert_eq!(w.items().len(), 1);
    assert_eq!(w.items()[&id].due.as_deref(), Some("2026-11-13"));
}
