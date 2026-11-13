use std::time::{Duration, Instant};

use super::*;

fn root() -> PathBuf {
    std::env::temp_dir().join(format!("koe-offline-worker-{}", uuid::Uuid::new_v4()))
}

fn terminal(worker: &OfflineSpeechWorker) -> Vec<OfflineSpeechEvent> {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let events = worker.poll();
        if events
            .iter()
            .any(|event| !matches!(event, OfflineSpeechEvent::Preparing { .. }))
        {
            return events;
        }
        assert!(
            Instant::now() < deadline,
            "worker did not return a terminal event"
        );
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn transcription_without_preparation_reports_the_original_operation() {
    let root = root();
    let worker = OfflineSpeechWorker::new(root.clone()).unwrap();
    worker.transcribe(42, vec![123; 16_000]).unwrap();
    assert!(
        matches!(&terminal(&worker)[..], [OfflineSpeechEvent::TranscriptionFailed { operation_id: 42, error }] if error.contains("not ready"))
    );
    drop(worker);
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn invalid_requests_fail_without_claiming_readiness() {
    let root = root();
    let worker = OfflineSpeechWorker::new(root.clone()).unwrap();
    assert!(worker.prepare("missing-model").is_err());
    assert!(worker.transcribe(5, Vec::new()).is_err());
    assert!(worker.poll().is_empty());
    drop(worker);
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn unpolled_completions_apply_backpressure() {
    let root = root();
    let worker = OfflineSpeechWorker::new(root.clone()).unwrap();
    for id in 0..4 {
        worker.transcribe(id, vec![0; 100]).unwrap();
    }
    assert!(worker.transcribe(5, vec![0; 100]).is_err());
    let completed = terminal(&worker);
    assert!(!completed.is_empty());
    worker.transcribe(6, vec![0; 100]).unwrap();
    drop(worker);
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn model_directory_creation_failure_is_reported() {
    let root = root();
    std::fs::write(&root, b"not a directory").unwrap();
    assert!(OfflineSpeechWorker::new(root.clone()).is_err());
    std::fs::remove_file(root).unwrap();
}
