use super::*;
use koe_client_providers::{ProviderEvent, ProviderOutput};
use koe_engine::context::AskStatus;
use serde_json::json;
use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

const NOW: u64 = 1_800_000_000;
const OLD_QUOTE: &str = "Alpha deadline is Friday.";
const CURRENT_QUOTE: &str = "Alpha deadline is Monday.";

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-stale-ask-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn enqueue_answer_after_source_changed(runtime: &mut KoeRuntime) -> u64 {
    let operation = runtime
        .commit(|workspace| {
            workspace.insert_record(
                "source".into(),
                "Alpha plan".into(),
                RecordOrigin::Bean,
                7,
                NOW,
                1000,
            )?;
            let capture = workspace.begin_analysis("source", AnalysisStage::Transcribing)?;
            workspace.accept_transcript(&capture, "first", OLD_QUOTE, 0, 1000, "fixture")?;
            let request = workspace
                .begin_ask(SearchScope::Record("source".into()), "Alpha deadline", NOW)?
                .unwrap();
            workspace.accept_transcript(&capture, "first", CURRENT_QUOTE, 0, 1000, "fixture")?;
            workspace.finish_transcription(&capture)?;
            Ok(request.operation)
        })
        .unwrap();
    let job = runtime.next_job;
    runtime.next_job += 1;
    runtime.pending.insert(job, PendingWork::Ask(operation));
    runtime.completed.push_back(ProviderEvent {
        operation_id: job,
        record_id: "ask".into(),
        result: Ok(ProviderOutput::Chat {
            text: format!("{OLD_QUOTE} [S1]"),
        }),
    });
    operation
}

fn assert_failed_and_unlocked(runtime: &KoeRuntime) {
    let session = runtime.workspace().ask_session();
    assert!(!session.in_flight);
    assert!(runtime.workspace().pending_ask().is_none());
    let answer = session.messages.last().unwrap();
    assert_eq!(answer.status, AskStatus::Failed);
    assert!(answer.sources.is_empty());
    assert!(answer.text.contains("来源"));
    assert!(!answer.text.contains(OLD_QUOTE));
    assert_eq!(
        runtime
            .workspace()
            .record("source")
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        CURRENT_QUOTE
    );
}

fn ask_again(runtime: &mut KoeRuntime) {
    let result: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type":"ask","question":"Alpha deadline","scope":"record","recordId":"source"
            })
            .to_string(),
            NOW + 1,
        ),
    )
    .unwrap();
    assert!(result["error"].is_null(), "{}", result["error"]);
    assert_eq!(result["ask"]["phase"], "ready");
    let latest = result["ask"]["messages"]
        .as_array()
        .unwrap()
        .last()
        .unwrap();
    assert_eq!(latest["mode"], "retrieval");
    assert!(latest["text"].as_str().unwrap().contains(CURRENT_QUOTE));
    assert!(!latest["text"].as_str().unwrap().contains(OLD_QUOTE));
}

#[test]
fn changed_ask_evidence_records_failure_and_allows_the_next_question() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    enqueue_answer_after_source_changed(&mut runtime);
    runtime.poll_provider();
    assert_failed_and_unlocked(&runtime);
    assert!(runtime.completed.is_empty());
    drop(runtime);
    let mut reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_failed_and_unlocked(&reopened);
    ask_again(&mut reopened);
}

#[test]
fn changed_ask_failure_waits_for_local_storage_then_unlocks_without_a_new_response() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let operation = enqueue_answer_after_source_changed(&mut runtime);
    let state = dir.0.join("product-workspace.json");
    let backup = dir.0.join("ask-recovery-backup.json");
    fs::rename(&state, &backup).unwrap();
    fs::create_dir(&state).unwrap();
    runtime.poll_provider();
    assert_eq!(
        runtime.workspace().pending_ask().unwrap().operation,
        operation
    );
    assert!(runtime.workspace().ask_session().in_flight);
    assert!(runtime.error.is_some());
    assert!(
        !runtime.completed.is_empty(),
        "the received answer was discarded before its failure status could be saved"
    );

    fs::remove_dir(&state).unwrap();
    fs::rename(&backup, &state).unwrap();
    runtime.poll_provider();
    assert_failed_and_unlocked(&runtime);
    assert!(runtime.completed.is_empty());
    assert!(
        runtime.error.is_none(),
        "a resolved storage error remains visible after the failure status was committed"
    );
    drop(runtime);
    let mut reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_failed_and_unlocked(&reopened);
    ask_again(&mut reopened);
}
