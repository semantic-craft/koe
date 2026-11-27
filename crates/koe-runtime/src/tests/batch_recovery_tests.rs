use super::super::*;
use crate::observability::env::RuntimeEnvMetadata;
use crate::speech::LocalSpeechJobView;
use koe_client_services::recording_assets;
use koe_engine::product::{AnalysisStage, AnalysisState, RecordOrigin, SpeechEngine};
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::{
    atomic::{AtomicU64, AtomicUsize, Ordering},
    mpsc, Arc,
};
use std::thread;
use std::time::{Duration, Instant};

const NOW: u64 = 1_800_000_000;

struct Sandbox(PathBuf);

impl Sandbox {
    fn new(tag: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-batch-recovery-{tag}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn dispatch(runtime: &mut KoeRuntime, value: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&value.to_string(), NOW)).unwrap()
}

fn save_test_wav(root: &Path, id: &str, sample_count: usize) {
    let pcm_bytes = sample_count * 2;
    let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(pcm_bytes as u32, 16_000).to_vec();
    for i in 0..sample_count {
        let sample = ((i % 64) as i16).wrapping_mul(64);
        wav.extend_from_slice(&sample.to_le_bytes());
    }
    recording_assets::save_audio(root, id, &wav).unwrap();
}

fn seed_bean_record(runtime: &mut KoeRuntime, root: &Path, id: &str, file_id: u32, with_wav: bool) {
    runtime
        .commit(|w| {
            w.insert_record(
                id.into(),
                format!("Bean {file_id}"),
                RecordOrigin::Bean,
                file_id,
                NOW + u64::from(file_id),
                1_000,
            )
        })
        .unwrap();
    if with_wav {
        save_test_wav(root, id, 1_600);
    }
}

fn read_http_request(stream: &mut std::net::TcpStream) -> String {
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        let n = stream.read(&mut chunk).unwrap();
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            let hdrs = std::str::from_utf8(&buf[..pos]).unwrap();
            let len: usize = hdrs
                .lines()
                .find_map(|line| {
                    let (k, v) = line.split_once(':')?;
                    k.eq_ignore_ascii_case("content-length")
                        .then(|| v.trim().parse().unwrap())
                })
                .unwrap_or(0);
            if buf.len() >= pos + 4 + len {
                break;
            }
        }
    }
    String::from_utf8_lossy(&buf).into_owned()
}

fn write_minutes_response(stream: &mut std::net::TcpStream, title: &str, overview: &str) {
    let minutes = json!({
        "schemaVersion": 2,
        "title": title,
        "overview": overview,
        "topics": [{"text": title, "summary": overview, "sources": ["S1"]}],
        "decisions": [],
        "actions": [],
        "questions": [],
        "terms": [],
        "reviewItems": []
    })
    .to_string();
    let body = json!({"choices": [{"message": {"content": minutes}}]}).to_string();
    write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    )
    .unwrap();
}

#[cfg(feature = "offline-speech")]
#[test]
fn downloaded_batch_serializes_file_sessions_without_overflowing_offline_worker() {
    use koe_client_providers::{OfflineSpeechEvent, OfflineSpeechSegment};

    let dir = Sandbox::new("downloaded-batch");
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let configured = dispatch(
        &mut runtime,
        json!({"type": "configure_speech", "engine": "downloaded", "modelId": "sensevoice-small"}),
    );
    assert!(configured["error"].is_null(), "{configured}");
    runtime.mark_downloaded_model_ready_for_test("sensevoice-small");

    let count = 12usize;
    let ids: Vec<String> = (0..count).map(|i| format!("bean-{i:02}")).collect();
    for (idx, id) in ids.iter().enumerate() {
        seed_bean_record(&mut runtime, &dir.0, id, (idx + 1) as u32, true);
        runtime.auto_transcribe.insert(id.clone());
    }

    for _ in 0..count {
        runtime.drive_analysis_queue();
    }

    assert!(
        runtime.error_str().is_none(),
        "batch admission must not overflow OfflineSpeechWorker: {:?}",
        runtime.error_str()
    );
    let jobs = runtime.active_local_speech_jobs();
    assert_eq!(
        jobs.len(),
        1,
        "expected exactly 1 active downloaded file session, got {jobs:?}"
    );
    assert_eq!(jobs[0].record_id, "bean-00");
    assert_eq!(jobs[0].engine, "downloaded");

    let refused = dispatch(&mut runtime, json!({"type": "transcribe", "recordId": "bean-01"}));
    assert!(
        refused["error"].is_string(),
        "manual transcribe must reject concurrent local file session: {refused}"
    );
    runtime.clear_error();
    assert_eq!(runtime.active_local_speech_jobs().len(), 1);

    let mut completed_order = Vec::new();
    let mut peak_active = 0usize;
    for step in 0..count {
        let active = runtime.active_local_speech_jobs();
        peak_active = peak_active.max(active.len());
        assert_eq!(
            active.len(),
            1,
            "step {step}: expected 1 active local job, got {active:?}"
        );
        let job = active[0].clone();
        completed_order.push(job.record_id.clone());

        let deadline = Instant::now() + Duration::from_secs(5);
        while runtime.drain_offline_worker_slots_for_test() == 0 {
            assert!(
                Instant::now() < deadline,
                "offline worker did not drain synthetic slot for {}",
                job.record_id
            );
            thread::sleep(Duration::from_millis(2));
        }

        runtime.accept_offline_speech_event(OfflineSpeechEvent::Transcribed {
            operation_id: job.operation_id,
            text: format!("Transcript for {}", job.record_id),
            segments: vec![OfflineSpeechSegment {
                start_ms: 0,
                end_ms: 100,
                text: format!("Transcript for {}", job.record_id),
            }],
        });
        assert!(
            runtime.error_str().is_none(),
            "unexpected error after {}: {:?}",
            job.record_id,
            runtime.error_str()
        );
        runtime.drive_analysis_queue();
        runtime.drive_analysis_queue();
    }

    assert_eq!(peak_active, 1);
    assert_eq!(completed_order, ids);
    assert!(runtime.active_local_speech_jobs().is_empty());
    assert!(runtime.auto_transcribe.is_empty());
    for id in &ids {
        let record = runtime.workspace().record(id).unwrap();
        assert_eq!(record.aggregate.spine.len(), 1);
        assert_eq!(
            record.aggregate.spine.segments()[0].text,
            format!("Transcript for {id}")
        );
        assert!(matches!(record.analysis, AnalysisState::Idle));
    }
}

#[test]
fn apple_batch_serializes_file_sessions_and_auto_summarizes_serially() {
    let dir = Sandbox::new("apple-batch-summary");
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let chat_endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());

    let count = 10usize;
    let in_flight = Arc::new(AtomicUsize::new(0));
    let max_in_flight = Arc::new(AtomicUsize::new(0));
    let served = Arc::new(AtomicUsize::new(0));
    let (first_seen_tx, first_seen_rx) = mpsc::channel();
    let (release_first_tx, release_first_rx) = mpsc::channel();

    let in_flight_srv = Arc::clone(&in_flight);
    let max_in_flight_srv = Arc::clone(&max_in_flight);
    let served_srv = Arc::clone(&served);
    let server = thread::spawn(move || {
        for idx in 0..count {
            let (mut stream, _) = listener.accept().unwrap();
            let current = in_flight_srv.fetch_add(1, Ordering::SeqCst) + 1;
            max_in_flight_srv.fetch_max(current, Ordering::SeqCst);
            let req = read_http_request(&mut stream);
            let matched = (0..count)
                .map(|i| format!("Apple text {i:02}"))
                .find(|needle| req.contains(needle))
                .expect("request must include batch transcript text");
            if idx == 0 {
                first_seen_tx.send(()).unwrap();
                release_first_rx
                    .recv_timeout(Duration::from_secs(10))
                    .unwrap();
            }
            write_minutes_response(&mut stream, "Batch note", &matched);
            in_flight_srv.fetch_sub(1, Ordering::SeqCst);
            served_srv.fetch_add(1, Ordering::SeqCst);
        }
    });

    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    assert!(
        dispatch(
            &mut runtime,
            json!({"type": "configure_speech", "engine": "apple_speech"}),
        )["error"]
            .is_null()
    );
    assert!(
        dispatch(
            &mut runtime,
            json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}),
        )["error"]
            .is_null()
    );
    assert!(
        dispatch(
            &mut runtime,
            json!({"type": "configure_provider", "model": "fixture", "chatEndpoint": chat_endpoint}),
        )["error"]
            .is_null()
    );

    let ids: Vec<String> = (0..count).map(|i| format!("apple-{i:02}")).collect();
    for (idx, id) in ids.iter().enumerate() {
        seed_bean_record(&mut runtime, &dir.0, id, (idx + 1) as u32, true);
        runtime.auto_transcribe.insert(id.clone());
    }

    for _ in 0..6 {
        runtime.poll_timers(0, NOW);
    }
    assert_eq!(
        runtime.active_local_speech_jobs().len(),
        1,
        "Apple batch must admit only 1 file session at a time"
    );
    let initial_effects = runtime.drain_local_asr_effects();
    let starts: Vec<u64> = initial_effects
        .iter()
        .filter_map(|effect| match effect {
            LocalAsrEffect::Start { operation_id, .. } => Some(*operation_id),
            _ => None,
        })
        .collect();
    assert_eq!(starts.len(), 1, "expected exactly 1 Start effect, got {starts:?}");

    let mut current_op = starts[0];
    let mut released_first_summary = false;
    for (idx, id) in ids.iter().enumerate() {
        let active = runtime.active_local_speech_jobs();
        assert_eq!(active.len(), 1);
        assert_eq!(active[0].record_id, *id);
        assert_eq!(active[0].operation_id, current_op);

        let text = format!("Apple text {idx:02}");
        assert!(
            dispatch(
                &mut runtime,
                json!({
                    "type": "local_asr_result",
                    "operationId": current_op,
                    "text": text,
                    "startMs": 0,
                    "endMs": 80,
                    "isFinal": true
                }),
            )["error"]
                .is_null()
        );
        assert!(
            dispatch(
                &mut runtime,
                json!({"type": "local_asr_finished", "operationId": current_op}),
            )["error"]
                .is_null()
        );

        runtime.poll_timers(0, NOW);
        if idx == 0 {
            first_seen_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        }
        if idx == 2 {
            assert!(
                runtime.auto_summarize.contains("apple-01")
                    && runtime.auto_summarize.contains("apple-02"),
                "queued summaries must wait in auto_summarize while slot 0 is busy: {:?}",
                runtime.auto_summarize
            );
            release_first_tx.send(()).unwrap();
            released_first_summary = true;
        }
        if idx + 1 < count {
            let next_starts: Vec<u64> = runtime
                .drain_local_asr_effects()
                .into_iter()
                .filter_map(|effect| match effect {
                    LocalAsrEffect::Start { operation_id, .. } => Some(operation_id),
                    _ => None,
                })
                .collect();
            assert_eq!(
                next_starts.len(),
                1,
                "expected exactly 1 next Start effect after {id}, got {next_starts:?}"
            );
            current_op = next_starts[0];
        }
    }
    assert!(released_first_summary);

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        runtime.poll_timers(10, NOW + 1);
        let all_ready = ids.iter().all(|id| {
            let record = runtime.workspace().record(id).unwrap();
            matches!(record.analysis, AnalysisState::Ready { .. })
                && record.aggregate.minutes.is_some()
        });
        if all_ready {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "not all batch summaries completed: auto_summarize={:?} error={:?}",
            runtime.auto_summarize,
            runtime.error_str()
        );
        thread::sleep(Duration::from_millis(5));
    }

    server.join().unwrap();
    assert_eq!(max_in_flight.load(Ordering::SeqCst), 1);
    assert_eq!(served.load(Ordering::SeqCst), count);
    assert!(runtime.active_local_speech_jobs().is_empty());
    assert!(runtime.auto_transcribe.is_empty());
    assert!(runtime.auto_summarize.is_empty());
}

#[test]
fn reopen_recovers_unstarted_idle_and_interrupted_local_bean_records_idempotently() {
    let dir = Sandbox::new("reopen-local-recovery");
    {
        let mut runtime = KoeRuntime::open(&dir.0).unwrap();
        assert!(
            dispatch(
                &mut runtime,
                json!({"type": "configure_speech", "engine": "apple_speech"}),
            )["error"]
                .is_null()
        );

        for idx in 1..=3 {
            seed_bean_record(&mut runtime, &dir.0, &format!("bean-idle-{idx}"), idx, true);
        }

        seed_bean_record(&mut runtime, &dir.0, "bean-interrupted", 4, true);
        runtime
            .commit(|w| {
                w.bind_speech_engine("bean-interrupted", SpeechEngine::AppleSpeech)?;
                w.begin_analysis("bean-interrupted", AnalysisStage::Transcribing)?;
                Ok(())
            })
            .unwrap();

        seed_bean_record(&mut runtime, &dir.0, "bean-done", 5, true);
        runtime
            .commit(|w| {
                w.append_transcript("bean-done", "already done", 0, 100, "apple-speech")?;
                Ok(())
            })
            .unwrap();

        seed_bean_record(&mut runtime, &dir.0, "bean-failed", 6, true);
        runtime
            .commit(|w| {
                let key = w.begin_analysis("bean-failed", AnalysisStage::Transcribing)?;
                w.fail_analysis(&key, "silence")
            })
            .unwrap();

        seed_bean_record(&mut runtime, &dir.0, "bean-trashed", 7, true);
        runtime
            .commit(|w| w.trash_record("bean-trashed", NOW * 1000))
            .unwrap();

        runtime
            .commit(|w| {
                w.insert_record(
                    "imported-idle".into(),
                    "Imported".into(),
                    RecordOrigin::ImportedAudio,
                    0,
                    NOW + 8,
                    1_000,
                )
            })
            .unwrap();
        save_test_wav(&dir.0, "imported-idle", 1_600);

        seed_bean_record(&mut runtime, &dir.0, "bean-no-wav", 9, false);
    }

    let expected: std::collections::BTreeSet<String> = [
        "bean-idle-1",
        "bean-idle-2",
        "bean-idle-3",
        "bean-interrupted",
    ]
    .into_iter()
    .map(String::from)
    .collect();

    let mut replay_rt = KoeRuntime::open_with_env(
        &dir.0,
        Box::<credentials::IsolatedCredentials>::default(),
        RuntimeEnv::for_replay(&RuntimeEnvMetadata {
            tz_offset_secs: Some(0),
            rng_seed: Some(7),
            nonce_seed: 7,
            initial_now_sec: NOW,
        }),
    )
    .unwrap();
    replay_rt.poll_timers(0, NOW + 1);
    assert!(
        replay_rt.active_local_speech_jobs().is_empty(),
        "replay mode must not start local file speech sessions"
    );
    drop(replay_rt);

    let mut quitting_rt = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(quitting_rt.auto_transcribe, expected);
    assert!(
        dispatch(
            &mut quitting_rt,
            json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}),
        )["error"]
            .is_null()
    );
    assert!(dispatch(&mut quitting_rt, json!({"type": "request_quit"}))["error"].is_null());
    quitting_rt.poll_timers(0, NOW + 1);
    assert!(
        quitting_rt.active_local_speech_jobs().is_empty(),
        "quitting runtime must not start recovered local batch work"
    );
    drop(quitting_rt);

    let mut reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(reopened.auto_transcribe, expected);
    assert!(
        dispatch(
            &mut reopened,
            json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}),
        )["error"]
            .is_null()
    );

    for expected_id in &expected {
        reopened.poll_timers(0, NOW + 2);
        let jobs = reopened.active_local_speech_jobs();
        assert_eq!(jobs.len(), 1);
        assert_eq!(jobs[0].record_id, *expected_id);
        let op = reopened
            .drain_local_asr_effects()
            .into_iter()
            .find_map(|e| match e {
                LocalAsrEffect::Start { operation_id, .. } => Some(operation_id),
                _ => None,
            })
            .expect("expected Start effect for recovered record");
        assert!(
            dispatch(
                &mut reopened,
                json!({
                    "type": "local_asr_result",
                    "operationId": op,
                    "text": format!("Recovered {expected_id}"),
                    "startMs": 0,
                    "endMs": 60,
                    "isFinal": true
                }),
            )["error"]
                .is_null()
        );
        assert!(
            dispatch(
                &mut reopened,
                json!({"type": "local_asr_finished", "operationId": op}),
            )["error"]
                .is_null()
        );
    }
    assert!(reopened.auto_transcribe.is_empty());
    assert!(reopened.active_local_speech_jobs().is_empty());
    drop(reopened);

    let mut second_reopen = KoeRuntime::open(&dir.0).unwrap();
    assert!(
        second_reopen.auto_transcribe.is_empty(),
        "completed batch must not re-enqueue on subsequent reopen: {:?}",
        second_reopen.auto_transcribe
    );
    assert!(
        dispatch(
            &mut second_reopen,
            json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}),
        )["error"]
            .is_null()
    );
    second_reopen.poll_timers(0, NOW + 3);
    assert!(second_reopen.drain_local_asr_effects().is_empty());
    drop(second_reopen);

    let dl_dir = Sandbox::new("reopen-downloaded-recovery");
    {
        let mut rt = KoeRuntime::open(&dl_dir.0).unwrap();
        assert!(
            dispatch(
                &mut rt,
                json!({"type": "configure_speech", "engine": "downloaded", "modelId": "sensevoice-small"}),
            )["error"]
                .is_null()
        );
        seed_bean_record(&mut rt, &dl_dir.0, "dl-idle", 1, true);
        seed_bean_record(&mut rt, &dl_dir.0, "dl-interrupted", 2, true);
        rt.commit(|w| {
            w.bind_speech_engine(
                "dl-interrupted",
                SpeechEngine::Downloaded("sensevoice-small".into()),
            )?;
            w.begin_analysis("dl-interrupted", AnalysisStage::Transcribing)?;
            Ok(())
        })
        .unwrap();
    }
    let _ = fs::remove_dir_all(dl_dir.0.join("speech-models"));
    fs::write(dl_dir.0.join("speech-models"), b"offline-test-guard").unwrap();
    let dl_reopened = KoeRuntime::open(&dl_dir.0).unwrap();
    assert_eq!(
        dl_reopened.auto_transcribe,
        ["dl-idle", "dl-interrupted"]
            .into_iter()
            .map(String::from)
            .collect()
    );
}

#[test]
fn reopen_never_auto_retries_cloud_asr_or_interrupted_summary() {
    let cloud_dir = Sandbox::new("billing-guard-cloud");
    let asr_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    asr_listener.set_nonblocking(true).unwrap();
    let chat_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    chat_listener.set_nonblocking(true).unwrap();
    let asr_endpoint = format!("ws://{}", asr_listener.local_addr().unwrap());
    let chat_endpoint = format!(
        "http://{}/chat/completions",
        chat_listener.local_addr().unwrap()
    );

    {
        let mut runtime = KoeRuntime::open(&cloud_dir.0).unwrap();
        assert!(
            dispatch(
                &mut runtime,
                json!({"type": "configure_speech", "engine": "cloud"}),
            )["error"]
                .is_null()
        );
        assert!(
            dispatch(
                &mut runtime,
                json!({"type": "set_meeting_audio_policy", "policy": "cloud_allowed"}),
            )["error"]
                .is_null()
        );
        assert!(
            dispatch(
                &mut runtime,
                json!({
                    "type": "configure_provider",
                    "apiKey": "billing-guard-key",
                    "model": "fixture",
                    "asrEndpoint": asr_endpoint,
                    "chatEndpoint": chat_endpoint
                }),
            )["error"]
                .is_null()
        );

        seed_bean_record(&mut runtime, &cloud_dir.0, "cloud-bean-idle", 1, true);
        seed_bean_record(&mut runtime, &cloud_dir.0, "cloud-bean-interrupted", 2, true);
        runtime
            .commit(|w| {
                w.bind_speech_engine("cloud-bean-interrupted", SpeechEngine::Cloud)?;
                w.begin_analysis("cloud-bean-interrupted", AnalysisStage::Transcribing)?;
                Ok(())
            })
            .unwrap();
    }

    let mut reopened_cloud = KoeRuntime::open(&cloud_dir.0).unwrap();
    assert!(reopened_cloud.auto_transcribe.is_empty());
    assert!(reopened_cloud.auto_summarize.is_empty());
    for _ in 0..5 {
        reopened_cloud.poll_timers(10, NOW + 1);
    }
    assert!(matches!(
        reopened_cloud
            .workspace()
            .record("cloud-bean-interrupted")
            .unwrap()
            .analysis,
        AnalysisState::Interrupted { .. }
    ));
    assert!(matches!(
        reopened_cloud
            .workspace()
            .record("cloud-bean-idle")
            .unwrap()
            .analysis,
        AnalysisState::Idle
    ));
    assert_eq!(
        asr_listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    assert_eq!(
        chat_listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    drop(reopened_cloud);

    let local_dir = Sandbox::new("billing-guard-summary");
    let summary_listener = TcpListener::bind("127.0.0.1:0").unwrap();
    summary_listener.set_nonblocking(true).unwrap();
    let summary_endpoint = format!(
        "http://{}/chat/completions",
        summary_listener.local_addr().unwrap()
    );

    {
        let mut runtime = KoeRuntime::open(&local_dir.0).unwrap();
        assert!(
            dispatch(
                &mut runtime,
                json!({"type": "configure_speech", "engine": "apple_speech"}),
            )["error"]
                .is_null()
        );
        assert!(
            dispatch(
                &mut runtime,
                json!({
                    "type": "configure_provider",
                    "model": "fixture",
                    "chatEndpoint": summary_endpoint
                }),
            )["error"]
                .is_null()
        );

        seed_bean_record(&mut runtime, &local_dir.0, "summary-interrupted", 10, true);
        runtime
            .commit(|w| {
                w.bind_speech_engine("summary-interrupted", SpeechEngine::AppleSpeech)?;
                let asr_key = w.begin_analysis("summary-interrupted", AnalysisStage::Transcribing)?;
                w.accept_transcript(
                    &asr_key,
                    "1",
                    "Local transcript already finished.",
                    0,
                    1_000,
                    "apple-speech",
                )?;
                w.finish_transcription(&asr_key)?;
                w.begin_analysis("summary-interrupted", AnalysisStage::Summarizing)?;
                Ok(())
            })
            .unwrap();

        seed_bean_record(&mut runtime, &local_dir.0, "cloud-asr-interrupted", 11, true);
        runtime
            .commit(|w| {
                w.bind_speech_engine("cloud-asr-interrupted", SpeechEngine::Cloud)?;
                w.begin_analysis("cloud-asr-interrupted", AnalysisStage::Transcribing)?;
                Ok(())
            })
            .unwrap();
    }

    let mut reopened_local = KoeRuntime::open(&local_dir.0).unwrap();
    assert!(
        reopened_local.auto_transcribe.is_empty(),
        "interrupted Summary or Cloud ASR must never enter auto_transcribe: {:?}",
        reopened_local.auto_transcribe
    );
    assert!(reopened_local.auto_summarize.is_empty());
    assert!(
        dispatch(
            &mut reopened_local,
            json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}),
        )["error"]
            .is_null()
    );
    for _ in 0..5 {
        reopened_local.poll_timers(10, NOW + 2);
    }
    assert!(reopened_local.drain_local_asr_effects().is_empty());
    assert!(reopened_local.auto_summarize.is_empty());
    assert!(matches!(
        reopened_local
            .workspace()
            .record("summary-interrupted")
            .unwrap()
            .analysis,
        AnalysisState::Interrupted { .. }
    ));
    assert!(matches!(
        reopened_local
            .workspace()
            .record("cloud-asr-interrupted")
            .unwrap()
            .analysis,
        AnalysisState::Interrupted { .. }
    ));
    assert_eq!(
        summary_listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
}

#[test]
fn active_local_speech_jobs_reports_single_inflight_job_and_clears_on_completion() {
    let dir = Sandbox::new("active-jobs-view");
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    assert!(
        dispatch(
            &mut runtime,
            json!({"type": "configure_speech", "engine": "apple_speech"}),
        )["error"]
            .is_null()
    );
    assert!(
        dispatch(
            &mut runtime,
            json!({"type": "local_asr_readiness", "state": "ready", "message": "ready"}),
        )["error"]
            .is_null()
    );

    let ids = ["job-0", "job-1", "job-2"];
    for (idx, id) in ids.iter().enumerate() {
        seed_bean_record(&mut runtime, &dir.0, id, (idx + 1) as u32, true);
        runtime.auto_transcribe.insert((*id).into());
    }

    assert!(runtime.active_local_speech_jobs().is_empty());

    for id in ids {
        runtime.poll_timers(0, NOW);
        runtime.poll_timers(0, NOW);
        let op = runtime
            .drain_local_asr_effects()
            .into_iter()
            .find_map(|effect| match effect {
                LocalAsrEffect::Start { operation_id, .. } => Some(operation_id),
                _ => None,
            })
            .expect("expected active Apple speech Start effect");
        assert_eq!(
            runtime.active_local_speech_jobs(),
            vec![LocalSpeechJobView {
                operation_id: op,
                record_id: id.into(),
                engine: "apple_speech".into(),
            }]
        );

        assert!(
            dispatch(
                &mut runtime,
                json!({
                    "type": "local_asr_result",
                    "operationId": op,
                    "text": format!("Done {id}"),
                    "startMs": 0,
                    "endMs": 40,
                    "isFinal": true
                }),
            )["error"]
                .is_null()
        );
        assert!(
            dispatch(
                &mut runtime,
                json!({"type": "local_asr_finished", "operationId": op}),
            )["error"]
                .is_null()
        );
    }

    assert!(runtime.active_local_speech_jobs().is_empty());
}
