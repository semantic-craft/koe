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
    assert_eq!(worker.outstanding(), 0);
    for id in 0..4 {
        worker.transcribe(id, vec![0; 100]).unwrap();
        assert_eq!(worker.outstanding(), id as usize + 1);
    }
    assert!(worker.transcribe(5, vec![0; 100]).is_err());
    assert_eq!(worker.outstanding(), 4);
    let completed = terminal(&worker);
    assert!(!completed.is_empty());
    assert_eq!(worker.outstanding(), 4 - completed.len());
    worker.transcribe(6, vec![0; 100]).unwrap();
    assert_eq!(worker.outstanding(), 5 - completed.len());
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

#[test]
fn cancelled_queued_prepare_preserves_previously_loaded_session() {
    let control = Control::new();
    let queued_epoch = *control.epoch.borrow();
    let mut loaded = Some("existing-session");
    control.cancel();

    let event = handle_prepare(
        &mut loaded,
        &control,
        queued_epoch,
        "sensevoice-small".into(),
        |_| panic!("cancelled prepare must not invoke artifact fetch"),
        |_, _: ()| panic!("cancelled prepare must not invoke model load"),
    );

    assert!(matches!(
        event,
        OfflineSpeechEvent::PreparationFailed { ref model_id, ref error }
            if model_id == "sensevoice-small" && error.contains("cancelled")
    ));
    assert_eq!(
        loaded,
        Some("existing-session"),
        "cancelled queued prepare must not unload an already-loaded session"
    );

    let root = root();
    let worker = OfflineSpeechWorker::new(root.clone()).unwrap();
    let stale_epoch = *worker.control.epoch.borrow();
    worker.cancel();
    {
        let mut events = lock_unpoisoned(&worker.events);
        worker
            .commands
            .try_send(Command {
                epoch: stale_epoch,
                task: Task::Prepare("sensevoice-small".into()),
            })
            .unwrap();
        events.outstanding += 1;
    }
    assert!(matches!(
        &terminal(&worker)[..],
        [OfflineSpeechEvent::PreparationFailed { model_id, error }]
            if model_id == "sensevoice-small" && error.contains("cancelled")
    ));
    assert!(std::fs::read_dir(&root).unwrap().next().is_none());
    drop(worker);
    std::fs::remove_dir(root).unwrap();
}

#[test]
fn failed_or_mid_download_cancelled_prepare_preserves_previously_loaded_session() {
    let control = Control::new();
    let epoch = *control.epoch.borrow();
    let mut loaded = Some("existing-session");

    let failed = handle_prepare(
        &mut loaded,
        &control,
        epoch,
        "qwen3-asr-0.6b".into(),
        |_| Err::<PathBuf, _>("download failed".into()),
        |_, _| panic!("failed fetch must not invoke model load"),
    );
    assert!(matches!(
        failed,
        OfflineSpeechEvent::PreparationFailed { ref model_id, ref error }
            if model_id == "qwen3-asr-0.6b" && error == "download failed"
    ));
    assert_eq!(
        loaded,
        Some("existing-session"),
        "download failure must not unload an already-loaded session"
    );

    let cancelled_mid_download = handle_prepare(
        &mut loaded,
        &control,
        epoch,
        "qwen3-asr-0.6b".into(),
        |_| {
            control.cancel();
            Ok(PathBuf::from("/tmp/fake.gguf"))
        },
        |_, _| panic!("cancelled prepare after fetch must not invoke model load"),
    );
    assert!(matches!(
        cancelled_mid_download,
        OfflineSpeechEvent::PreparationFailed { ref model_id, ref error }
            if model_id == "qwen3-asr-0.6b" && error.contains("cancelled")
    ));
    assert_eq!(
        loaded,
        Some("existing-session"),
        "mid-download cancellation must not unload an already-loaded session"
    );
}
