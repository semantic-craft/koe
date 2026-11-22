#![allow(clippy::unwrap_used, clippy::expect_used)]

use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc,
    },
    thread,
    time::{Duration, Instant},
};

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "koe-continuous-minutes-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn send(runtime: &mut KoeRuntime, command: Value) -> Value {
    let snapshot: Value =
        serde_json::from_str(&runtime.dispatch_json(&command.to_string(), 100)).unwrap();
    assert!(snapshot["error"].is_null(), "{snapshot}");
    snapshot
}
fn request(socket: &mut TcpStream) -> Value {
    socket.set_nonblocking(false).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut bytes = Vec::new();
    let mut buffer = [0; 4096];
    loop {
        let n = socket.read(&mut buffer).unwrap();
        assert!(n > 0);
        bytes.extend_from_slice(&buffer[..n]);
        if let Some(end) = bytes.windows(4).position(|s| s == b"\r\n\r\n") {
            let headers = String::from_utf8_lossy(&bytes[..end]);
            let length = headers
                .lines()
                .find_map(|line| {
                    line.to_ascii_lowercase()
                        .strip_prefix("content-length:")
                        .and_then(|n| n.trim().parse::<usize>().ok())
                })
                .unwrap();
            if bytes.len() >= end + 4 + length {
                return serde_json::from_slice(&bytes[end + 4..end + 4 + length]).unwrap();
            }
        }
    }
}
fn respond(socket: &mut TcpStream, text: &str, source: &str) {
    let minutes = json!({"schemaVersion":2,"title":"实时纪要","overview":text,"topics":[{"text":"要点","summary":text,"sources":[source]}],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}).to_string();
    let body = json!({"choices":[{"message":{"content":minutes}}]}).to_string();
    write!(socket,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
}
fn begin(runtime: &mut KoeRuntime, endpoint: &str) -> (Value, u64) {
    begin_mode(runtime, endpoint, "meeting")
}
fn begin_mode(runtime: &mut KoeRuntime, endpoint: &str, mode: &str) -> (Value, u64) {
    send(
        runtime,
        json!({"type":"configure_provider","model":"fixture","chatEndpoint":endpoint}),
    );
    send(
        runtime,
        json!({"type":"configure_speech","engine":"apple_speech"}),
    );
    send(
        runtime,
        json!({"type":"local_asr_readiness","state":"ready","message":"ready"}),
    );
    let snapshot = send(
        runtime,
        json!({"type":"start_capture_mode","mode":mode}),
    );
    let mic = snapshot["microphone"].clone();
    send(
        runtime,
        json!({"type":"microphone_started","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sampleRate":16000}),
    );
    runtime.ingest_microphone_pcm(koe_runtime::MicrophonePcmChunk {
        record_id: mic["recordId"].as_str().unwrap(),
        session_id: mic["sessionId"].as_str().unwrap(),
        lane: "microphone",
        sequence: 0,
        samples: &vec![100i16; 3200],
        timing: None,
        now: 100,
    });
    let effects = runtime.drain_local_asr_effects();
    let operation = effects
        .iter()
        .find_map(|e| match e {
            koe_runtime::LocalAsrEffect::Start { operation_id, .. } => Some(*operation_id),
            _ => None,
        })
        .unwrap();
    (mic, operation)
}
fn final_line(runtime: &mut KoeRuntime, operation: u64, index: u64, text: &str) -> Value {
    send(
        runtime,
        json!({"type":"local_asr_result","operationId":operation,"text":text,"startMs":index*20,"endMs":index*20+20,"isFinal":true}),
    )
}
fn advance_with_drafts(runtime: &mut KoeRuntime, operation: u64, elapsed_ms: u64) {
    let mut remaining = elapsed_ms;
    while remaining > 0 {
        send(
            runtime,
            json!({"type":"local_asr_result","operationId":operation,"text":"识别仍在继续","startMs":100,"endMs":120,"isFinal":false}),
        );
        let elapsed = remaining.min(5_000);
        runtime.poll_timers(elapsed, 100);
        remaining -= elapsed;
    }
}
fn wait_until(runtime: &mut KoeRuntime, check: impl Fn(&Value) -> bool) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        runtime.poll_timers(5, 100);
        let snapshot = runtime.snapshot(100);
        if check(&snapshot) {
            return snapshot;
        }
        assert!(snapshot["error"].is_null(), "{snapshot}");
        assert!(Instant::now() < deadline, "{snapshot}");
        thread::sleep(Duration::from_millis(5));
    }
}
#[test]
fn continuous_minutes_publish_unchanged_prefix_and_catch_up_after_stop_tail() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}/chat", listener.local_addr().unwrap());
    let (received, requests) = mpsc::channel();
    let (release, releases) = mpsc::channel();
    let server = thread::spawn(move || {
        for (text, source) in [
            ("开始讨论方案", "S1"),
            ("继续确认细节", "S2"),
            ("停止时补上末句", "S3"),
        ] {
            let deadline = Instant::now() + Duration::from_secs(8);
            let mut socket = loop {
                match listener.accept() {
                    Ok((socket, _)) => break socket,
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "no summary request");
                        thread::sleep(Duration::from_millis(5));
                    }
                    Err(error) => panic!("{error}"),
                }
            };
            received.send(request(&mut socket)).unwrap();
            releases.recv_timeout(Duration::from_secs(8)).unwrap();
            respond(&mut socket, text, source);
        }
    });
    let (mic, operation) = begin(&mut runtime, &endpoint);
    final_line(&mut runtime, operation, 0, "开始讨论方案");
    for _ in 0..4 {
        send(
            &mut runtime,
            json!({"type":"local_asr_result","operationId":operation,"text":"识别仍在继续","startMs":20,"endMs":40,"isFinal":false}),
        );
        runtime.poll_timers(5_000, 100);
    }
    let first_request = requests
        .recv_timeout(Duration::from_secs(2))
        .unwrap_or_else(|_| {
            panic!(
                "minutes must start before recording stops: {}",
                runtime.snapshot(100)
            )
        });
    assert!(first_request["messages"]
        .to_string()
        .contains("开始讨论方案"));
    let appending = final_line(&mut runtime, operation, 1, "继续确认细节");
    assert_eq!(appending["microphone"]["phase"], "recording");
    assert_eq!(
        appending["workspaces"]["liveMinutes"]["segments"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    release.send(()).unwrap();
    let partial = wait_until(&mut runtime, |s| {
        s["workspaces"]["liveMinutes"]["liveSections"][0]["text"] == "开始讨论方案"
    });
    assert_eq!(partial["microphone"]["phase"], "recording");
    assert_eq!(partial["workspaces"]["liveMinutes"]["minutesStale"], true);
    assert_eq!(
        partial["workspaces"]["liveMinutes"]["liveSections"][1]["sources"][0]["quote"],
        "开始讨论方案"
    );
    assert!(
        runtime.workspace().items().is_empty(),
        "rolling drafts must not create review items"
    );
    advance_with_drafts(&mut runtime, operation, 44_000);
    assert!(
        requests.try_recv().is_err(),
        "updates must coalesce until the next cadence"
    );
    advance_with_drafts(&mut runtime, operation, 1_000);
    let rolling = requests.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(rolling["messages"].to_string().contains("继续确认细节"));
    let refreshing = runtime.snapshot(100);
    let record_id = mic["recordId"].as_str().unwrap();
    assert!(matches!(
        runtime.workspace().record(record_id).unwrap().live_summary,
        koe_engine::product::AnalysisState::Pending {
            stage: koe_engine::product::AnalysisStage::Summarizing,
            ..
        }
    ));
    assert_eq!(
        refreshing["workspaces"]["liveMinutes"]["liveSections"][0]["text"],
        "开始讨论方案"
    );
    release.send(()).unwrap();
    wait_until(&mut runtime, |s| {
        s["workspaces"]["liveMinutes"]["liveSections"][0]["text"] == "继续确认细节"
    });
    advance_with_drafts(&mut runtime, operation, 45_000);
    assert!(
        requests.try_recv().is_err(),
        "unchanged originals must not trigger another call"
    );
    send(&mut runtime, json!({"type":"stop_microphone"}));
    send(
        &mut runtime,
        json!({"type":"microphone_stopped","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sequence":1}),
    );
    final_line(&mut runtime, operation, 2, "停止时补上末句");
    send(
        &mut runtime,
        json!({"type":"local_asr_finished","operationId":operation}),
    );
    runtime.poll_timers(0, 100);
    let final_request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(final_request["messages"]
        .to_string()
        .contains("停止时补上末句"));
    let pending = runtime.snapshot(100);
    assert_eq!(
        pending["workspaces"]["liveMinutes"]["coverage"]["consolidationStage"],
        "in_progress"
    );
    assert_eq!(
        pending["workspaces"]["liveMinutes"]["liveSections"][0]["text"],
        "继续确认细节"
    );
    release.send(()).unwrap();
    let done = wait_until(&mut runtime, |s| {
        s["workspaces"]["liveMinutes"]["coverage"]["consolidationStage"] == "ready"
    });
    assert_eq!(done["workspaces"]["liveMinutes"]["minutesStale"], false);
    assert_eq!(
        done["workspaces"]["liveMinutes"]["finalSections"][1]["sources"][0]["quote"],
        "停止时补上末句"
    );
    server.join().unwrap();
    let id = mic["recordId"].as_str().unwrap().to_string();
    drop(runtime);
    let reopened = KoeRuntime::open(&sandbox.0).unwrap();
    assert_eq!(
        reopened
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .minutes
            .as_ref()
            .unwrap()
            .overview,
        "停止时补上末句"
    );
}

#[test]
fn failed_live_minutes_do_not_repeat_the_revision_and_final_pass_owns_its_outcome() {
    for final_fails in [false, true] {
        let sandbox = Sandbox::new();
        let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("http://{}/chat", listener.local_addr().unwrap());
        let (received, requests) = mpsc::channel();
        let (release, releases) = mpsc::channel();
        let server = thread::spawn(move || {
            for index in 0..2 {
                let deadline = Instant::now() + Duration::from_secs(8);
                let mut socket = loop {
                    match listener.accept() {
                        Ok((socket, _)) => break socket,
                        Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                            assert!(Instant::now() < deadline, "no summary request");
                            thread::sleep(Duration::from_millis(5));
                        }
                        Err(error) => panic!("{error}"),
                    }
                };
                received.send(request(&mut socket)).unwrap();
                releases.recv_timeout(Duration::from_secs(8)).unwrap();
                if index == 0 {
                    let body =
                        json!({"choices":[{"message":{"content":"invalid minutes"}}]}).to_string();
                    write!(socket,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
                } else if final_fails {
                    write!(socket,"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();
                } else {
                    respond(&mut socket, "停止后的完整末句", "S4");
                }
            }
        });
        let (mic, operation) = begin(&mut runtime, &endpoint);
        for (index, text) in ["第一句", "第二句", "第三句"].iter().enumerate() {
            final_line(&mut runtime, operation, index as u64, text);
        }
        runtime.poll_timers(0, 100);
        requests
            .recv_timeout(Duration::from_secs(2))
            .expect("three finalized segments start the first pass");
        release.send(()).unwrap();
        let failed_live = wait_until(&mut runtime, |s| {
            s["workspaces"]["liveMinutes"]["error"].is_string()
        });
        assert!(failed_live["workspaces"]["liveMinutes"]["error"].is_string());
        send(&mut runtime, json!({"type":"clear_error"}));
        advance_with_drafts(&mut runtime, operation, 45_000);
        assert!(
            requests.try_recv().is_err(),
            "failed revision must not be sent repeatedly"
        );
        send(&mut runtime, json!({"type":"stop_microphone"}));
        send(
            &mut runtime,
            json!({"type":"microphone_stopped","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sequence":1}),
        );
        final_line(&mut runtime, operation, 3, "停止后的完整末句");
        send(
            &mut runtime,
            json!({"type":"local_asr_finished","operationId":operation}),
        );
        runtime.poll_timers(0, 100);
        let final_request = requests.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(final_request["messages"]
            .to_string()
            .contains("停止后的完整末句"));
        assert_eq!(
            runtime.snapshot(100)["workspaces"]["liveMinutes"]["coverage"]["consolidationStage"],
            "in_progress"
        );
        release.send(()).unwrap();
        if final_fails {
            let failed = wait_until(&mut runtime, |s| {
                s["workspaces"]["liveMinutes"]["error"]
                    .as_str()
                    .is_some_and(|e| e.contains("HTTP 503"))
            });
            assert_eq!(
                failed["workspaces"]["liveMinutes"]["coverage"]["consolidationStage"],
                "failed"
            );
            let id = mic["recordId"].as_str().unwrap().to_string();
            drop(runtime);
            let reopened = KoeRuntime::open(&sandbox.0).unwrap();
            let record = reopened.workspace().record(&id).unwrap();
            assert!(
                matches!(&record.analysis,koe_engine::product::AnalysisState::Failed {message,..} if message.contains("HTTP 503"))
            );
            assert_eq!(
                record.live_summary,
                koe_engine::product::AnalysisState::Idle
            );
        } else {
            let done = wait_until(&mut runtime, |s| {
                s["workspaces"]["liveMinutes"]["coverage"]["consolidationStage"] == "ready"
            });
            assert_eq!(
                done["workspaces"]["liveMinutes"]["finalSections"][1]["sources"][0]["segmentId"],
                "S4"
            );
        }
        server.join().unwrap();
    }
}

#[test]
fn quick_note_keeps_transcript_without_continuous_minutes_and_summarizes_after_stop() {
    let sandbox = Sandbox::new();
    let mut runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}/chat", listener.local_addr().unwrap());
    let (mic, operation) = begin_mode(&mut runtime, &endpoint, "quick_note");
    let snapshot = final_line(&mut runtime, operation, 0, "随手记下一件事");
    assert_eq!(snapshot["activeCapture"]["mode"], "quick_note");
    advance_with_drafts(&mut runtime, operation, 20_000);
    let quiet_deadline = Instant::now() + Duration::from_millis(250);
    while Instant::now() < quiet_deadline {
        runtime.poll_timers(0, 100);
        assert_eq!(listener.accept().unwrap_err().kind(), std::io::ErrorKind::WouldBlock);
        thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        runtime.snapshot(100)["workspaces"]["liveMinutes"]["isActive"],
        false
    );
    send(&mut runtime, json!({"type":"stop_microphone"}));
    send(&mut runtime, json!({"type":"microphone_stopped","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sequence":1}));
    send(&mut runtime, json!({"type":"local_asr_finished","operationId":operation}));
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut socket = loop {
        runtime.poll_timers(5, 100);
        match listener.accept() {
            Ok((socket, _)) => break socket,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "final summary never started");
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("{error}"),
        }
    };
    assert!(request(&mut socket).to_string().contains("随手记下一件事"));
    respond(&mut socket, "随手记下一件事", "S1");
    let deadline = Instant::now() + Duration::from_secs(5);
    while runtime.workspace().record(mic["recordId"].as_str().unwrap()).unwrap().aggregate.minutes.is_none() {
        runtime.poll_timers(5, 100);
        assert!(Instant::now() < deadline, "final summary was not saved");
        thread::sleep(Duration::from_millis(5));
    }
    assert!(runtime.snapshot(100)["activeCapture"].is_null());
    drop(runtime);
    let runtime = KoeRuntime::open(&sandbox.0).unwrap();
    let record = runtime.workspace().record(mic["recordId"].as_str().unwrap()).unwrap();
    assert_eq!(record.aggregate.spine.segments()[0].text, "随手记下一件事");
    assert_eq!(record.aggregate.minutes.as_ref().unwrap().overview, "随手记下一件事");
}
