use crate::*;
use koe_engine::session::CaptureEvent;
use serde_json::json;
use std::{
    fs,
    net::TcpListener,
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::Duration,
};

const NOW: u64 = 1_800_000_000;
struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-audio-policy-{}-{}",
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
fn dispatch(runtime: &mut KoeRuntime, value: Value) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&value.to_string(), NOW)).unwrap()
}
fn policy(runtime: &mut KoeRuntime, value: &str) -> Value {
    dispatch(
        runtime,
        json!({"type":"set_meeting_audio_policy", "policy":value}),
    )
}
fn setup() -> (Sandbox, KoeRuntime, TcpListener) {
    let dir = Sandbox::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let result = dispatch(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"policy-fixture","model":"fixture","asrEndpoint":format!("ws://{}", listener.local_addr().unwrap())}),
    );
    assert!(result["error"].is_null());
    dispatch(
        &mut runtime,
        json!({"type":"configure_speech","engine":"cloud"}),
    );
    policy(&mut runtime, "cloud_allowed");
    (dir, runtime, listener)
}
fn imported(runtime: &mut KoeRuntime, root: &Path) -> String {
    let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(640, 16000).to_vec();
    wav.extend(vec![0; 640]);
    let path = root.join("meeting.wav");
    fs::write(&path, wav).unwrap();
    dispatch(runtime, json!({"type":"import_file","path":path}))["selectedRecordId"]
        .as_str()
        .unwrap()
        .into()
}
fn assert_no_connection(listener: &TcpListener) {
    assert_eq!(
        listener
            .accept()
            .expect_err("meeting audio request escaped local-only")
            .kind(),
        std::io::ErrorKind::WouldBlock
    );
}

fn file_upload_is_blocked(automatic: bool) {
    let (dir, mut runtime, listener) = setup();
    policy(&mut runtime, "local_only");
    let id = imported(&mut runtime, &dir.0);
    if automatic {
        runtime.auto_transcribe.insert(id.clone());
        runtime.drive_analysis_queue();
    } else {
        dispatch(&mut runtime, json!({"type":"transcribe","recordId":id}));
    }
    thread::sleep(Duration::from_millis(80));
    let state = runtime.snapshot(NOW);
    drop(runtime);
    assert_no_connection(&listener);
    assert!(state["error"].as_str().unwrap().contains("音频只留本机"));
}

#[test]
fn local_only_blocks_manual_file_upload() {
    file_upload_is_blocked(false);
}

#[test]
fn local_only_blocks_automatic_file_upload() {
    file_upload_is_blocked(true);
}

#[test]
fn local_only_blocks_live_audio_and_keeps_capture() {
    let (_dir, mut runtime, listener) = setup();
    policy(&mut runtime, "local_only");
    runtime.device.captures.extend([
        CaptureEvent::Started { file_id: 90 },
        CaptureEvent::Audio {
            file_id: 90,
            pcm16: vec![0; 640],
        },
    ]);
    runtime.process_capture_events(NOW).unwrap();
    thread::sleep(Duration::from_millis(80));
    assert_eq!(runtime.workspace().records().len(), 1);
    drop(runtime);
    assert_no_connection(&listener);
}

#[test]
fn policy_survives_restart_and_provider_edits() {
    let (dir, mut runtime, _listener) = setup();
    policy(&mut runtime, "local_only");
    dispatch(
        &mut runtime,
        json!({"type":"configure_provider","model":"different"}),
    );
    drop(runtime);
    let runtime = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(
        runtime.snapshot(NOW)["provider"]["meetingAudioPolicy"],
        "local_only"
    );
    assert_eq!(runtime.snapshot(NOW)["provider"]["model"], "different");
}

#[test]
fn switching_policy_discards_queued_uploads_without_resuming_them() {
    let (dir, mut runtime, listener) = setup();
    let id = imported(&mut runtime, &dir.0);
    runtime.auto_transcribe.insert(id);
    policy(&mut runtime, "local_only");
    policy(&mut runtime, "cloud_allowed");
    runtime.drive_analysis_queue();
    thread::sleep(Duration::from_millis(80));
    drop(runtime);
    assert_no_connection(&listener);
}

#[test]
fn revoked_attempt_cannot_write_late_results_after_policy_is_restored() {
    let (dir, mut runtime, _listener) = setup();
    let id = imported(&mut runtime, &dir.0);
    let key = runtime
        .store
        .transact(|w| w.begin_analysis(&id, AnalysisStage::Transcribing))
        .unwrap();
    runtime
        .pending
        .insert(1, PendingWork::Transcription(key.clone()));
    policy(&mut runtime, "local_only");
    policy(&mut runtime, "cloud_allowed");
    runtime
        .completed
        .push_back(koe_client_providers::ProviderEvent {
            operation_id: 1,
            record_id: id.clone(),
            result: Ok(koe_client_providers::ProviderOutput::Transcript {
                segments: vec![koe_client_providers::TranscriptSegment {
                    start_ms: 0,
                    end_ms: 20,
                    text: "late old words".into(),
                    speaker: None,
                }],
            }),
        });
    runtime.poll_provider();
    assert!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .is_empty()
    );
    assert!(
        runtime
            .store
            .transact(|w| w.accept_transcript(&key, "late", "late old words", 0, 20, "fixture"))
            .is_err()
    );
}

#[test]
fn missing_policy_defaults_to_local_only_without_uploading() {
    let (dir, runtime, listener) = setup();
    drop(runtime);
    let path = dir.0.join("product-workspace.json");
    let mut saved: Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    saved["provider"]
        .as_object_mut()
        .unwrap()
        .remove("meeting_audio_policy");
    fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let id = imported(&mut runtime, &dir.0);
    dispatch(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"fixture","model":"fixture"}),
    );
    dispatch(&mut runtime, json!({"type":"transcribe","recordId":id}));
    thread::sleep(Duration::from_millis(80));
    let snapshot = runtime.snapshot(NOW);
    drop(runtime);
    assert_no_connection(&listener);
    assert_eq!(snapshot["provider"]["meetingAudioPolicy"], "local_only");
}

fn waiting_asr() -> (
    String,
    std::sync::mpsc::Receiver<()>,
    std::sync::mpsc::Sender<()>,
    thread::JoinHandle<usize>,
) {
    use tokio_tungstenite::tungstenite::{Message, accept};
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let (ready, ready_rx) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let server = thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(std::time::Instant::now() < deadline, "ASR never connected");
                    thread::sleep(Duration::from_millis(2));
                }
                Err(error) => panic!("{error}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut ws = accept(stream).unwrap();
        let run: Value = serde_json::from_str(ws.read().unwrap().to_text().unwrap()).unwrap();
        let id = run["header"]["task_id"].as_str().unwrap();
        ready.send(()).unwrap();
        release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        if ws
            .send(Message::Text(
                json!({"header":{"event":"task-started","task_id":id}})
                    .to_string()
                    .into(),
            ))
            .is_err()
        {
            return 0;
        }
        let mut bytes = 0;
        while let Ok(message) = ws.read() {
            match message {
                Message::Binary(chunk) => bytes += chunk.len(),
                Message::Text(_) => {
                    ws.send(Message::Text(json!({"header":{"event":"result-generated","task_id":id},"payload":{"output":{"sentence":{"sentence_id":0,"sentence_end":true,"begin_time":0,"end_time":20,"text":"fixture words"}}}}).to_string().into())).unwrap();
                    let _ = ws.send(Message::Text(
                        json!({"header":{"event":"task-finished","task_id":id}})
                            .to_string()
                            .into(),
                    ));
                    break;
                }
                _ => {}
            }
        }
        bytes
    });
    (endpoint, ready_rx, release, server)
}

fn start_waiting_audio(
    runtime: &mut KoeRuntime,
    root: &Path,
    live: bool,
    endpoint: &str,
) -> String {
    dispatch(
        runtime,
        json!({"type":"configure_provider","apiKey":"fixture","model":"fixture","asrEndpoint":endpoint}),
    );
    dispatch(runtime, json!({"type":"configure_speech","engine":"cloud"}));
    if live {
        runtime.device.captures.extend([
            CaptureEvent::Started { file_id: 999 },
            CaptureEvent::Audio {
                file_id: 999,
                pcm16: vec![0; 640],
            },
        ]);
        runtime.process_capture_events(NOW).unwrap();
        runtime.captures.active[&999].clone()
    } else {
        let id = imported(runtime, root);
        let result = dispatch(runtime, json!({"type":"transcribe","recordId":id}));
        assert!(result["error"].is_null(), "{result}");
        id
    }
}

fn switch_before_audio_upload(live: bool) {
    let (dir, mut runtime, _listener) = setup();
    let (endpoint, ready, release, server) = waiting_asr();
    let id = start_waiting_audio(&mut runtime, &dir.0, live, &endpoint);
    ready.recv_timeout(Duration::from_secs(5)).unwrap();
    let switched = policy(&mut runtime, "local_only");
    release.send(()).unwrap();
    assert_eq!(
        server.join().unwrap(),
        0,
        "queued PCM was sent after policy changed"
    );
    assert!(switched["error"].is_null(), "{switched}");
    policy(&mut runtime, "cloud_allowed");
    runtime.poll_timers(0, NOW);
    assert!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .is_empty()
    );
    assert!(matches!(
        runtime.workspace().record(&id).unwrap().analysis,
        AnalysisState::Failed { .. }
    ));
}

#[test]
fn switch_stops_file_pcm_before_task_started() {
    switch_before_audio_upload(false);
}
#[test]
fn switch_stops_live_pcm_before_task_started() {
    switch_before_audio_upload(true);
}

#[test]
fn cloud_allowed_positive_control_sends_real_pcm() {
    for live in [false, true] {
        let (dir, mut runtime, _listener) = setup();
        let (endpoint, ready, release, server) = waiting_asr();
        let _id = start_waiting_audio(&mut runtime, &dir.0, live, &endpoint);
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        if live {
            runtime.device.captures.push_back(CaptureEvent::Finished {
                file_id: 999,
                saved: false,
            });
            runtime.process_capture_events(NOW).unwrap();
        }
        release.send(()).unwrap();
        assert_eq!(server.join().unwrap(), 640);
    }
}

#[test]
fn failed_policy_save_suspends_audio_until_explicit_policy_retry() {
    let (dir, mut runtime, _listener) = setup();
    let (endpoint, ready, release, server) = waiting_asr();
    let _id = start_waiting_audio(&mut runtime, &dir.0, true, &endpoint);
    ready.recv_timeout(Duration::from_secs(5)).unwrap();
    let path = dir.0.join("product-workspace.json");
    let backup = dir.0.join("backup.json");
    fs::rename(&path, &backup).unwrap();
    fs::create_dir(&path).unwrap();
    let result = policy(&mut runtime, "local_only");
    assert!(result["error"].is_string());
    release.send(()).unwrap();
    assert_eq!(server.join().unwrap(), 0);
    fs::remove_dir(&path).unwrap();
    fs::rename(&backup, &path).unwrap();
    assert!(runtime.snapshot(NOW)["provider"]["meetingAudioStatus"].is_string());
    assert_eq!(
        runtime.snapshot(NOW)["provider"]["meetingAudioPolicy"],
        "cloud_allowed"
    );
    assert!(runtime.snapshot(NOW)["provider"]["meetingAudioPolicyError"].is_string());
    policy(&mut runtime, "local_only");
    assert_eq!(
        runtime.snapshot(NOW)["provider"]["meetingAudioPolicy"],
        "local_only"
    );
}

fn held_chat(
    answer: String,
) -> (
    String,
    std::sync::mpsc::Receiver<()>,
    std::sync::mpsc::Sender<()>,
    thread::JoinHandle<Value>,
) {
    use std::io::{Read, Write};
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let (ready, ready_rx) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let server = thread::spawn(move || {
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(std::time::Instant::now() < deadline);
                    thread::sleep(Duration::from_millis(2));
                }
                Err(e) => panic!("{e}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut bytes = Vec::new();
        let request = loop {
            let mut chunk = [0; 4096];
            let count = stream.read(&mut chunk).unwrap();
            assert!(count > 0);
            bytes.extend_from_slice(&chunk[..count]);
            if let Some(boundary) = bytes.windows(4).position(|p| p == b"\r\n\r\n") {
                let headers = std::str::from_utf8(&bytes[..boundary]).unwrap();
                let length: usize = headers
                    .lines()
                    .find_map(|line| {
                        let (key, value) = line.split_once(':')?;
                        key.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse().unwrap())
                    })
                    .unwrap();
                if bytes.len() >= boundary + 4 + length {
                    break serde_json::from_slice::<Value>(
                        &bytes[boundary + 4..boundary + 4 + length],
                    )
                    .unwrap();
                }
            }
        };
        ready.send(()).unwrap();
        release_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        let body = json!({"choices":[{"message":{"content":answer}}]}).to_string();
        let _ = write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        request
    });
    (endpoint, ready_rx, release, server)
}
fn wait_result(runtime: &mut KoeRuntime, done: impl Fn(&KoeRuntime) -> bool) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !done(runtime) {
        runtime.poll_timers(0, NOW);
        assert!(
            std::time::Instant::now() < deadline,
            "{}",
            runtime.snapshot(NOW)
        );
        thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn local_only_keeps_text_summary_and_ask_available() {
    for summary in [false, true] {
        let (_dir, mut runtime, listener) = setup();
        policy(&mut runtime, "local_only");
        let id=dispatch(&mut runtime,json!({"type":"create_note","title":"Planning","text":"Mina sends prototype tomorrow."}))["selectedRecordId"].as_str().unwrap().to_owned();
        let answer = if summary {
            json!({"schemaVersion":2,"title":"Planning","overview":"Mina sends prototype tomorrow.","topics":[],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}).to_string()
        } else {
            "Mina sends prototype tomorrow. [S1]".into()
        };
        let (endpoint, ready, release, server) = held_chat(answer);
        dispatch(
            &mut runtime,
            json!({"type":"configure_provider","model":"fixture","chatEndpoint":endpoint}),
        );
        let result = if summary {
            dispatch(&mut runtime, json!({"type":"summarize","recordId":id}))
        } else {
            dispatch(
                &mut runtime,
                json!({"type":"ask","question":"Mina","scope":"record","recordId":id}),
            )
        };
        assert!(result["error"].is_null(), "{result}");
        ready.recv_timeout(Duration::from_secs(5)).unwrap();
        release.send(()).unwrap();
        let request = server.join().unwrap();
        assert!(
            request["messages"][1]["content"]
                .as_str()
                .unwrap()
                .contains("Mina")
        );
        wait_result(&mut runtime, |r| r.pending.is_empty());
        assert!(
            runtime.snapshot(NOW)["error"].is_null(),
            "{}",
            runtime.snapshot(NOW)
        );
        if summary {
            assert!(
                runtime
                    .workspace()
                    .record(&id)
                    .unwrap()
                    .aggregate
                    .minutes
                    .is_some()
            );
        } else {
            assert_eq!(runtime.snapshot(NOW)["ask"]["phase"], "ready");
        }
        drop(runtime);
        assert_no_connection(&listener);
    }
}

#[test]
fn refused_audio_submission_does_not_cancel_the_active_text_request() {
    let (dir, mut runtime, _listener) = setup();
    let audio1 = imported(&mut runtime, &dir.0);
    let audio2_path = dir.0.join("meeting-2.wav");
    let mut wav2 = koe_engine::wav::OpusWave::wav_header_with_rate(640, 16000).to_vec();
    wav2.extend(vec![1; 640]);
    fs::write(&audio2_path, wav2).unwrap();
    let audio2 = dispatch(&mut runtime, json!({"type":"import_file","path":audio2_path}))
        ["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let note = dispatch(
        &mut runtime,
        json!({"type":"create_note","title":"Planning","text":"Mina sends prototype tomorrow."}),
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let (asr_endpoint, asr_ready, asr_release, asr_server) = waiting_asr();
    let (chat_endpoint, chat_ready, chat_release, chat_server) =
        held_chat("Mina sends prototype tomorrow. [S1]".into());
    dispatch(
        &mut runtime,
        json!({
            "type":"configure_provider",
            "apiKey":"policy-fixture",
            "model":"fixture",
            "asrEndpoint":asr_endpoint,
            "chatEndpoint":chat_endpoint
        }),
    );
    dispatch(
        &mut runtime,
        json!({"type":"ask","question":"Mina","scope":"record","recordId":note}),
    );
    chat_ready.recv_timeout(Duration::from_secs(5)).unwrap();

    let accepted = dispatch(&mut runtime, json!({"type":"transcribe","recordId":audio1}));
    assert!(accepted["error"].is_null(), "{accepted}");
    asr_ready.recv_timeout(Duration::from_secs(5)).unwrap();
    let refused = dispatch(&mut runtime, json!({"type":"transcribe","recordId":audio2}));
    assert!(refused["error"].is_string(), "{refused}");

    policy(&mut runtime, "local_only");
    asr_release.send(()).unwrap();
    let _ = asr_server.join();
    chat_release.send(()).unwrap();
    chat_server.join().unwrap();
    wait_result(&mut runtime, |r| r.pending.is_empty());
    assert_eq!(runtime.snapshot(NOW)["ask"]["phase"], "ready");
}

#[cfg(unix)]
#[test]
fn uncertain_policy_save_stops_audio_and_requires_reopen() {
    use std::os::unix::fs::PermissionsExt;
    let (dir, mut runtime, _listener) = setup();
    let (endpoint, ready, release, server) = waiting_asr();
    start_waiting_audio(&mut runtime, &dir.0, true, &endpoint);
    ready.recv_timeout(Duration::from_secs(5)).unwrap();
    let permissions = fs::metadata(&dir.0).unwrap().permissions();
    fs::set_permissions(&dir.0, fs::Permissions::from_mode(0o300)).unwrap();
    let result = policy(&mut runtime, "local_only");
    fs::set_permissions(&dir.0, permissions).unwrap();
    release.send(()).unwrap();
    assert_eq!(server.join().unwrap(), 0);
    assert!(
        result["error"]
            .as_str()
            .unwrap()
            .contains("无法确认保存结果")
    );
    let retry = dispatch(&mut runtime, json!({"type":"retry_provider_credentials"}));
    assert_eq!(retry["provider"]["credentialState"], "reopen_required");
    assert!(policy(&mut runtime, "cloud_allowed")["error"].is_string());
    drop(runtime);
    let runtime = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(
        runtime.snapshot(NOW)["provider"]["meetingAudioPolicy"],
        "local_only"
    );
}
