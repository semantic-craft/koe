#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use koe_engine::product::AnalysisState;
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

const NOW: u64 = 1_800_000_000;
const TEST_KEY: &str = "local-wire-fixture-key";
const DECISION: &str = "We decided to keep the daily memory homepage.";
const ACTION: &str = "Mina will send the prototype tomorrow.";

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-cloud-workflow-{}-{}",
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

fn command(runtime: &mut KoeRuntime, command: Value) -> Value {
    if command["type"] == "configure_provider" {
        runtime.dispatch_json(r#"{"type":"configure_speech","engine":"cloud"}"#, NOW);
        runtime.dispatch_json(
            r#"{"type":"set_meeting_audio_policy","policy":"cloud_allowed"}"#,
            NOW,
        );
    }
    let result: Value =
        serde_json::from_str(&runtime.dispatch_json(&command.to_string(), NOW)).unwrap();
    assert!(result["error"].is_null(), "{}", result["error"]);
    result
}

fn poll_until(runtime: &mut KoeRuntime, completed: impl Fn(&KoeRuntime) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        runtime.poll_timers(5, NOW);
        if completed(runtime) {
            return runtime.snapshot(NOW);
        }
        let snapshot = runtime.snapshot(NOW);
        assert!(snapshot["error"].is_null(), "{}", snapshot["error"]);
        assert!(
            Instant::now() < deadline,
            "runtime did not reach the final result: {snapshot}"
        );
        thread::sleep(Duration::from_millis(5));
    }
}

fn read_http_request(stream: &mut TcpStream) -> Value {
    stream.set_nonblocking(false).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    stream
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut bytes = Vec::new();
    let mut chunk = [0; 4096];
    loop {
        let count = stream.read(&mut chunk).unwrap();
        assert!(count > 0, "HTTP request ended before its body");
        bytes.extend_from_slice(&chunk[..count]);
        assert!(
            bytes.len() < 512 * 1024,
            "unexpectedly large fixture request"
        );
        let Some(boundary) = bytes.windows(4).position(|part| part == b"\r\n\r\n") else {
            continue;
        };
        let headers = std::str::from_utf8(&bytes[..boundary]).unwrap();
        assert!(headers.starts_with("POST /chat/completions HTTP/1.1"));
        let expected_auth = format!("authorization: bearer {TEST_KEY}");
        assert!(headers.to_lowercase().contains(&expected_auth));
        let length: usize = headers
            .lines()
            .find_map(|line| {
                let (name, value) = line.split_once(':')?;
                name.eq_ignore_ascii_case("content-length")
                    .then(|| value.trim().parse().unwrap())
            })
            .expect("client did not send content length");
        if bytes.len() >= boundary + 4 + length {
            return serde_json::from_slice(&bytes[boundary + 4..boundary + 4 + length]).unwrap();
        }
    }
}

fn chat_server(
    answer: String,
    verify: impl FnOnce(&Value) + Send + 'static,
) -> (String, thread::JoinHandle<()>, TcpListener) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let observer = listener.try_clone().unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let handle = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "runtime never submitted chat request"
                    );
                    thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("fixture accept failed: {error}"),
            }
        };
        let request = read_http_request(&mut stream);
        verify(&request);
        let body = json!({"choices":[{"message":{"content":answer}}]}).to_string();
        write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
    });
    (endpoint, handle, observer)
}

#[allow(clippy::result_large_err)] // Tungstenite defines the handshake callback error type.
fn asr_server(
    expected_pcm: Vec<u8>,
) -> (
    String,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
    thread::JoinHandle<()>,
    TcpListener,
) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let observer = listener.try_clone().unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let (audio_received, wait_audio) = mpsc::channel();
    let (release_finals, wait_release) = mpsc::channel();
    let handle = thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            tokio::time::timeout(Duration::from_secs(10), async {
                let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                let mut ws = tokio_tungstenite::accept_hdr_async(stream, |request: &tokio_tungstenite::tungstenite::handshake::server::Request, response| {
                    assert_eq!(request.headers()["authorization"], format!("Bearer {TEST_KEY}"));
                    Ok(response)
                }).await.unwrap();
                let run: Value = serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
                assert_eq!(run["header"]["action"], "run-task");
                assert_eq!(run["payload"]["model"], "qwen-audio-3.1-asr-flash-streaming");
                assert_eq!(run["payload"]["parameters"]["sample_rate"], 16000);
                let id = run["header"]["task_id"].as_str().unwrap();
                ws.send(Message::Text(json!({"header":{"event":"task-started","task_id":id},"payload":{}}).to_string().into())).await.unwrap();
                let mut pcm = Vec::new();
                loop {
                    match ws.next().await.unwrap().unwrap() {
                        Message::Binary(bytes) => pcm.extend_from_slice(&bytes),
                        Message::Text(text) => {
                            let finish: Value = serde_json::from_str(&text).unwrap();
                            assert_eq!(finish["header"]["action"], "finish-task");
                            assert_eq!(finish["header"]["task_id"], id);
                            break;
                        }
                        other => panic!("unexpected ASR frame {other:?}"),
                    }
                }
                assert_eq!(pcm, expected_pcm, "WAV import did not deliver the original 16 kHz PCM");
                audio_received.send(()).unwrap();
                wait_release.recv_timeout(Duration::from_secs(5)).unwrap();
                for (index, text) in [DECISION, ACTION].iter().enumerate() {
                    ws.send(Message::Text(json!({
                        "header":{"event":"result-generated","task_id":id},
                        "payload":{"output":{"sentence":{"sentence_id":index,"sentence_end":true,"begin_time":index * 160,"end_time":(index + 1) * 160,"text":text}}}
                    }).to_string().into())).await.unwrap();
                }
                ws.send(Message::Text(json!({"header":{"event":"task-finished","task_id":id},"payload":{}}).to_string().into())).await.unwrap();
                let _ = ws.close(None).await;
            }).await.expect("ASR fixture deadline");
        });
    });
    (endpoint, wait_audio, release_finals, handle, observer)
}

#[test]
fn real_wire_transcription_and_auto_summary_remain_on_the_imported_record() {
    let dir = Sandbox::new();
    let pcm: Vec<_> = (0..5120).flat_map(|_| [16_u8, 0]).collect();
    let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(pcm.len() as u32, 16000).to_vec();
    wav.extend_from_slice(&pcm);
    let input = dir.0.join("planning.wav");
    fs::write(&input, wav).unwrap();

    let (asr_endpoint, wait_audio, release_finals, asr, _asr_observer) = asr_server(pcm);
    let summary = json!({
        "schemaVersion":2,"title":"Daily memory homepage","overview":DECISION,
        "topics":[{"text":"Daily memory homepage","summary":DECISION,"sources":["S1"]}],
        "decisions":[{"text":DECISION,"sources":["S1"]}],
        "actions":[{"text":ACTION,"owner":"Mina","due":"tomorrow","sources":["S2"]}],
        "questions":[],"terms":[],"reviewItems":[]
    })
    .to_string();
    let (chat_endpoint, chat, _chat_observer) = chat_server(summary, |request| {
        assert_eq!(request["model"], "wire-fixture-model");
        let user = request["messages"][1]["content"].as_str().unwrap();
        assert!(user.contains(DECISION) && user.contains(ACTION));
        assert!(user.contains("S1") && user.contains("S2"));
        assert!(!user.contains("Violet calendar"));
    });
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let configured = command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":TEST_KEY,"model":"wire-fixture-model","asrEndpoint":asr_endpoint,"chatEndpoint":chat_endpoint}),
    );
    assert_eq!(configured["provider"]["configured"], true);
    assert!(!configured.to_string().contains(TEST_KEY));
    let imported = command(&mut runtime, json!({"type":"import_file","path":input}));
    let recording = imported["selectedRecordId"].as_str().unwrap().to_string();
    let started = command(
        &mut runtime,
        json!({"type":"transcribe","recordId":recording}),
    );
    assert_eq!(started["detail"]["status"], "转写中");
    wait_audio.recv_timeout(Duration::from_secs(5)).unwrap();
    let other = command(
        &mut runtime,
        json!({"type":"create_note","title":"Other note","text":"Violet calendar reminder."}),
    );
    let other_id = other["selectedRecordId"].as_str().unwrap().to_string();
    assert_ne!(other_id, recording);
    release_finals.send(()).unwrap();
    let completed = poll_until(&mut runtime, |runtime| {
        matches!(
            runtime.workspace().record(&recording).unwrap().analysis,
            AnalysisState::Ready { .. }
        )
    });
    assert_eq!(completed["selectedRecordId"], other_id);
    assert_eq!(
        completed["detail"]["segments"][0]["text"],
        "Violet calendar reminder."
    );
    assert_eq!(completed["tasks"].as_array().unwrap().len(), 1);
    assert_eq!(completed["tasks"][0]["text"], ACTION);
    assert_eq!(completed["tasks"][0]["due"], "tomorrow");
    assert_eq!(completed["tasks"][0]["state"], "proposed");
    assert_eq!(completed["tasks"][0]["sources"][0]["recordId"], recording);
    assert_eq!(completed["tasks"][0]["sources"][0]["segmentId"], "S2");
    assert_eq!(completed["memories"][0]["text"], DECISION);
    assert_eq!(
        completed["memories"][0]["sources"][0]["recordId"],
        recording
    );
    assert_eq!(completed["memories"][0]["sources"][0]["segmentId"], "S1");
    let detail = command(
        &mut runtime,
        json!({"type":"select_record","recordId":recording}),
    );
    assert_eq!(detail["detail"]["segments"][0]["text"], DECISION);
    assert_eq!(detail["detail"]["segments"][1]["text"], ACTION);
    assert_eq!(detail["detail"]["status"], "已整理");
    assert!(detail["detail"]["summary"]
        .as_array()
        .unwrap()
        .iter()
        .any(|row| row["sources"]
            .as_array()
            .unwrap()
            .iter()
            .any(|source| source["recordId"] == recording && source["segmentId"] == "S1")));
    asr.join().unwrap();
    chat.join().unwrap();
    drop(runtime);

    let stored = fs::read_to_string(dir.0.join("product-workspace.json")).unwrap();
    assert!(!stored.contains(TEST_KEY), "test credential was persisted");
    let mut reopened = KoeRuntime::open(&dir.0).unwrap();
    let reopened_detail = command(
        &mut reopened,
        json!({"type":"select_record","recordId":recording}),
    );
    assert_eq!(reopened_detail["provider"]["configured"], true);
    assert_eq!(
        reopened_detail["provider"]["credentialState"],
        "missing_saved"
    );
    assert_eq!(reopened_detail["detail"], detail["detail"]);
    assert_eq!(reopened_detail["tasks"], detail["tasks"]);
    assert_eq!(reopened_detail["memories"], detail["memories"]);
    assert_eq!(reopened_detail["records"].as_array().unwrap().len(), 2);
}

#[test]
fn invalid_cloud_citations_fail_without_mutating_recording_evidence() {
    let dir = Sandbox::new();
    let (chat_endpoint, chat, _chat_observer) =
        chat_server("The source was fabricated [S999].".into(), |request| {
            let user = request["messages"][1]["content"].as_str().unwrap();
            assert!(user.contains(ACTION));
            assert!(!user.contains("unrelated second record"));
        });
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let first = command(
        &mut runtime,
        json!({"type":"create_note","title":"Planning","text":ACTION}),
    );
    let recording = first["selectedRecordId"].as_str().unwrap().to_string();
    command(
        &mut runtime,
        json!({"type":"create_note","title":"Other","text":"unrelated second record"}),
    );
    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":TEST_KEY,"model":"wire-fixture-model","chatEndpoint":chat_endpoint}),
    );
    let before = runtime.workspace().record(&recording).unwrap().clone();
    command(
        &mut runtime,
        json!({"type":"ask","question":"Mina","scope":"record","recordId":recording}),
    );
    let failed = poll_until(&mut runtime, |runtime| {
        runtime.snapshot(NOW)["ask"]["phase"] == "failed"
    });
    assert!(failed["error"].is_string());
    let last = failed["ask"]["messages"]
        .as_array()
        .unwrap()
        .last()
        .unwrap();
    assert!(last["sources"].as_array().unwrap().is_empty());
    assert!(!last["text"].as_str().unwrap().contains("S999"));
    assert_eq!(runtime.workspace().record(&recording).unwrap(), &before);
    assert!(runtime.workspace().items().is_empty());
    chat.join().unwrap();
    drop(runtime);
    let reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(reopened.snapshot(NOW)["ask"]["phase"], "failed");
    assert_eq!(reopened.workspace().record(&recording).unwrap(), &before);
}

#[test]
fn successful_paid_result_survives_local_save_failure_without_resending() {
    let dir = Sandbox::new();
    let pcm: Vec<_> = (0..5120).flat_map(|_| [16_u8, 0]).collect();
    let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(pcm.len() as u32, 16000).to_vec();
    wav.extend_from_slice(&pcm);
    let input = dir.0.join("pending-save.wav");
    fs::write(&input, wav).unwrap();

    let (asr_endpoint, wait_audio, release_finals, asr, asr_observer) = asr_server(pcm);
    let summary = json!({
        "schemaVersion":2,"title":"Daily memory homepage","overview":DECISION,
        "topics":[{"text":"Daily memory homepage","summary":DECISION,"sources":["S1"]}],
        "decisions":[{"text":DECISION,"sources":["S1"]}],
        "actions":[{"text":ACTION,"sources":["S2"]}],
        "questions":[],"terms":[],"reviewItems":[]
    })
    .to_string();
    let (chat_endpoint, chat, chat_observer) = chat_server(summary, |request| {
        let user = request["messages"][1]["content"].as_str().unwrap();
        assert!(user.contains(DECISION) && user.contains(ACTION));
    });
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":TEST_KEY,"model":"wire-fixture-model","asrEndpoint":asr_endpoint,"chatEndpoint":chat_endpoint}),
    );
    let imported = command(&mut runtime, json!({"type":"import_file","path":input}));
    let recording = imported["selectedRecordId"].as_str().unwrap().to_string();
    command(
        &mut runtime,
        json!({"type":"transcribe","recordId":recording}),
    );
    wait_audio.recv_timeout(Duration::from_secs(5)).unwrap();

    let state = dir.0.join("product-workspace.json");
    let backup = dir.0.join("pending-result-backup.json");
    fs::rename(&state, &backup).unwrap();
    fs::create_dir(&state).unwrap();
    release_finals.send(()).unwrap();
    let blocked = poll_until(&mut runtime, |runtime| {
        runtime.snapshot(NOW)["error"].is_string()
    });
    assert!(blocked["error"].as_str().unwrap().contains("等待保存"));
    let record = runtime.workspace().record(&recording).unwrap();
    assert!(
        record.aggregate.spine.is_empty(),
        "uncommitted provider text became visible"
    );
    assert!(record.aggregate.minutes.is_none());
    assert!(runtime.workspace().items().is_empty());
    assert!(
        matches!(record.analysis, AnalysisState::Pending { .. }),
        "a successful cloud result was converted to a failed provider job"
    );

    fs::remove_dir(&state).unwrap();
    fs::rename(&backup, &state).unwrap();
    // Only pump the runtime after restoring storage: no new transcribe command,
    // process restart, or network retry can supply the lost result.
    let completed = poll_until(&mut runtime, |runtime| {
        matches!(
            runtime.workspace().record(&recording).unwrap().analysis,
            AnalysisState::Ready { .. }
        )
    });
    assert!(completed["error"].is_null());
    assert_eq!(completed["detail"]["segments"][0]["text"], DECISION);
    assert_eq!(completed["detail"]["segments"][1]["text"], ACTION);
    assert_eq!(completed["tasks"][0]["sources"][0]["recordId"], recording);
    assert_eq!(
        completed["memories"][0]["sources"][0]["recordId"],
        recording
    );
    asr.join().unwrap();
    chat.join().unwrap();
    drop(runtime);

    // Both listener clones stayed open throughout recovery. After the worker has
    // stopped, their accept queues prove that neither paid task was resent.
    for listener in [&asr_observer, &chat_observer] {
        let error = listener
            .accept()
            .expect_err("server received a duplicate paid-task connection");
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
    }
    let mut reopened = KoeRuntime::open(&dir.0).unwrap();
    let persisted = command(
        &mut reopened,
        json!({"type":"select_record","recordId":recording}),
    );
    assert_eq!(persisted["detail"], completed["detail"]);
    assert_eq!(persisted["tasks"], completed["tasks"]);
    assert_eq!(persisted["memories"], completed["memories"]);
}
