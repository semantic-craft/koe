#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::fs;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use koe_engine::crypto::DeviceCrypto;
use koe_engine::frame::{ProtocolFrame, RX_MAGIC};
use koe_engine::product::AnalysisState;
use koe_engine::session::REAL_OPUS_20MS_440HZ_PACKET;
use koe_engine::transport::OPUS_FRAME_BYTES;
use koe_engine::wav::OpusWave;
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

const NOW: u64 = 1_800_000_000;
const TEST_KEY: &str = "local-transcript-edit-key";

struct Sandbox(PathBuf);

impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-transcript-edit-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&path).unwrap();
        Self(path)
    }

    fn open(&self) -> KoeRuntime {
        KoeRuntime::open(&self.0).unwrap()
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn dispatch_raw(runtime: &mut KoeRuntime, cmd: Value, now: u64) -> Value {
    serde_json::from_str(&runtime.dispatch_json(&cmd.to_string(), now)).unwrap()
}

fn dispatch_ok(runtime: &mut KoeRuntime, cmd: Value, now: u64) -> Value {
    if cmd["type"] == "configure_provider" {
        runtime.dispatch_json(
            r#"{"type":"set_meeting_audio_policy","policy":"cloud_allowed"}"#,
            now,
        );
    }
    let snap = dispatch_raw(runtime, cmd, now);
    assert!(
        snap["error"].is_null(),
        "unexpected error: {}",
        snap["error"]
    );
    snap
}

fn poll_until(
    runtime: &mut KoeRuntime,
    now: u64,
    predicate: impl Fn(&KoeRuntime) -> bool,
) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        runtime.poll_timers(5, now);
        if predicate(runtime) {
            return runtime.snapshot(now);
        }
        let snap = runtime.snapshot(now);
        assert!(
            snap["error"].is_null(),
            "unexpected poll error: {}",
            snap["error"]
        );
        assert!(
            Instant::now() < deadline,
            "timed out waiting for predicate: {snap}"
        );
        thread::sleep(Duration::from_millis(5));
    }
}

fn accept_http_stream(listener: &TcpListener) -> TcpStream {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut stream = loop {
        match listener.accept() {
            Ok((stream, _)) => break stream,
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(
                    Instant::now() < deadline,
                    "timed out waiting for chat HTTP request"
                );
                thread::sleep(Duration::from_millis(5));
            }
            Err(e) => panic!("accept failed: {e}"),
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
    let mut chunk = [0u8; 4096];
    loop {
        let count = stream.read(&mut chunk).unwrap();
        if count == 0 {
            break;
        }
        bytes.extend_from_slice(&chunk[..count]);
        if let Some(boundary) = bytes.windows(4).position(|w| w == b"\r\n\r\n") {
            let headers = std::str::from_utf8(&bytes[..boundary]).unwrap();
            let length: usize = headers
                .lines()
                .find_map(|line| {
                    let (name, val) = line.split_once(':')?;
                    name.eq_ignore_ascii_case("content-length")
                        .then(|| val.trim().parse().ok())
                        .flatten()
                })
                .unwrap_or(0);
            if bytes.len() >= boundary + 4 + length {
                break;
            }
        }
    }
    stream
}

fn write_chat_response(mut stream: TcpStream, content: &str) {
    let body = json!({"choices": [{"message": {"content": content}}]}).to_string();
    let _ = write!(
        stream,
        "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        body.len(),
        body
    );
}

fn single_chat_server(answer: String) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let handle = thread::spawn(move || {
        let stream = accept_http_stream(&listener);
        write_chat_response(stream, &answer);
    });
    (endpoint, handle)
}

fn rx_frame(group: u8, cmd: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = RX_MAGIC.to_vec();
    frame.extend_from_slice(&[1, group, cmd]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(ProtocolFrame::checksum(&frame));
    frame
}

fn unencrypted_file_head_rx(file_id: u32, file_size: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(9);
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&file_size.to_le_bytes());
    payload.push(0);
    rx_frame(0x1a, 0x07, &payload)
}

fn slices_rx(sequences: std::ops::Range<u32>) -> Vec<u8> {
    let mut payload = Vec::new();
    for seq in sequences {
        payload.extend_from_slice(&seq.to_le_bytes());
        payload.push(0);
        let mut opus = [0u8; OPUS_FRAME_BYTES];
        opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        payload.extend_from_slice(&opus);
        payload.push(0);
    }
    rx_frame(0x1a, 0x08, &payload)
}

fn catalog_1b0e_rx(file_id: u32, duration_ms: u32, end_time: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(14);
    payload.extend_from_slice(&1u16.to_le_bytes());
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&duration_ms.to_le_bytes());
    payload.extend_from_slice(&end_time.to_le_bytes());
    rx_frame(0x1b, 0x0e, &payload)
}

fn connect_bean(runtime: &mut KoeRuntime, connection_id: &str, now: u64) {
    dispatch_ok(
        runtime,
        json!({"type": "device_event", "event": "connecting", "connectionId": connection_id}),
        now,
    );
    dispatch_ok(
        runtime,
        json!({"type": "device_event", "event": "ready", "connectionId": connection_id}),
        now,
    );
    let outbound = runtime.drain_outbound_ble_frames();
    let ecdh_tx = outbound
        .iter()
        .find(|f| f.len() >= 75 && f[5] == 0x2e && f[6] == 0x01)
        .expect("ready event must emit 2E/01 ECDH public key");
    let host_pub = &ecdh_tx[9..74];
    let bean_priv = [0x42u8; 32];
    let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
    let shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, host_pub).unwrap();

    let mut telemetry = vec![0u8; 40];
    telemetry[0] = 1;
    telemetry[1] = 8;
    telemetry[2] = 1;
    telemetry[3..8].copy_from_slice(b"4.92.");
    telemetry[8..24].copy_from_slice(b"007f1d04cca30000");
    telemetry[24..28].copy_from_slice(&65536u32.to_le_bytes());
    telemetry[28..32].copy_from_slice(&32768u32.to_le_bytes());
    telemetry[33..38].copy_from_slice(b"1.0.0");
    telemetry[38] = 9;
    runtime.ingest_ble_chunk(&rx_frame(0x01, 0x01, &telemetry), now);

    let mut ecdh_reply = Vec::with_capacity(97);
    ecdh_reply.extend_from_slice(&bean_pub);
    ecdh_reply.extend_from_slice(&shared);
    runtime.ingest_ble_chunk(&rx_frame(0x2e, 0x01, &ecdh_reply), now);
    runtime.drain_outbound_ble_frames();
    assert_eq!(runtime.snapshot(now)["device"]["connected"], true);
}

fn gated_asr_server() -> (
    String,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
    thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let (audio_received, wait_audio) = mpsc::channel();
    let (release_finals, wait_release) = mpsc::channel();
    let handle = thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                let (stream, _) = tokio::time::timeout(Duration::from_secs(5), listener.accept())
                    .await
                    .unwrap()
                    .unwrap();
                let mut ws = tokio_tungstenite::accept_hdr_async(
                    stream,
                    #[allow(clippy::result_large_err)]
                    |request: &tokio_tungstenite::tungstenite::handshake::server::Request,
                     response| {
                        assert_eq!(
                            request.headers()["authorization"],
                            format!("Bearer {TEST_KEY}")
                        );
                        Ok(response)
                    },
                )
                .await
                .unwrap();
                let first = ws.next().await.unwrap().unwrap();
                let run: Value = serde_json::from_str(first.to_text().unwrap()).unwrap();
                let id = run["header"]["task_id"].as_str().unwrap().to_owned();
                ws.send(Message::Text(
                    json!({"header":{"event":"task-started","task_id":id},"payload":{}})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
                while let Some(Ok(frame)) = ws.next().await {
                    if let Message::Text(text) = frame {
                        let finish: Value = serde_json::from_str(&text).unwrap();
                        if finish["header"]["action"] == "finish-task" {
                            break;
                        }
                    }
                }
                audio_received.send(()).unwrap();
                wait_release.recv_timeout(Duration::from_secs(5)).unwrap();
                ws.send(Message::Text(
                    json!({
                        "header":{"event":"result-generated","task_id":id},
                        "payload":{"output":{"sentence":{"sentence_id":0,"sentence_end":true,"begin_time":0,"end_time":100,"text":"云端转写首句。"}}}
                    })
                    .to_string()
                    .into(),
                ))
                .await
                .unwrap();
                ws.send(Message::Text(
                    json!({"header":{"event":"task-finished","task_id":id},"payload":{}})
                        .to_string()
                        .into(),
                ))
                .await
                .unwrap();
                let _ = ws.close(None).await;
            });
    });
    (endpoint, wait_audio, release_finals, handle)
}

fn write_wav(path: &Path) {
    let mut wav = OpusWave::wav_header_with_rate(3200, 16000).to_vec();
    wav.extend(vec![7u8; 3200]);
    fs::write(path, wav).unwrap();
}

#[test]
fn utterance_edits_and_speaker_merges_persist_and_update_retained_minutes() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let created = dispatch_ok(
        &mut runtime,
        json!({
            "type": "create_note",
            "title": "灰度评审",
            "text": "西卡达模块按70%灰度推进。\n周五前完成压测验收。\n确认网关告警阈值。"
        }),
        NOW,
    );
    let id = created["selectedRecordId"].as_str().unwrap().to_owned();
    assert_eq!(created["detail"]["canEditTranscript"], true);
    assert_eq!(created["detail"]["minutesStale"], false);
    assert_eq!(created["detail"]["speakers"], json!([]));
    assert_eq!(
        created["detail"]["segments"][0]["originalText"],
        Value::Null
    );
    assert_eq!(created["detail"]["segments"][0]["isEdited"], false);

    let sp1 = dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": id,
            "segmentId": "S1",
            "speaker": "  发言人 1：: "
        }),
        NOW,
    );
    assert_eq!(sp1["notice"], "已更新说话人");
    assert_eq!(sp1["detail"]["segments"][0]["speaker"], "发言人 1");

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": id,
            "segmentId": "S2",
            "speaker": "发言人 2："
        }),
        NOW,
    );
    let sp3 = dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": id,
            "segmentId": "S3",
            "speaker": "发言人 1"
        }),
        NOW,
    );
    assert_eq!(
        sp3["detail"]["speakers"],
        json!([
            {"name": "发言人 1", "segmentCount": 2, "firstSegmentId": "S1"},
            {"name": "发言人 2", "segmentCount": 1, "firstSegmentId": "S2"},
        ])
    );

    let cleared = dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": id,
            "segmentId": "S3",
            "speaker": ""
        }),
        NOW,
    );
    assert_eq!(cleared["detail"]["segments"][2]["speaker"], Value::Null);
    let idem_clear = dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": id,
            "segmentId": "S3"
        }),
        NOW,
    );
    assert!(idem_clear["notice"].is_null());
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": id,
            "segmentId": "S3",
            "speaker": "发言人 1"
        }),
        NOW,
    );

    let initial_minutes = json!({
        "schemaVersion": 2,
        "title": "灰度评审",
        "overview": "发言人 1 提议西卡达模块按70%灰度推进。",
        "topics": [{"text": "灰度节奏", "summary": "发言人 1 提议按70%灰度推进", "sources": ["S1"]}],
        "decisions": [{"text": "发言人 1 决定按70%灰度推进", "speaker": "发言人 1", "sources": ["S1"]}],
        "actions": [{"text": "周五前完成压测验收", "owner": "发言人 2", "due": "周五", "sources": ["S2"]}],
        "questions": [],
        "terms": [],
        "reviewItems": []
    })
    .to_string();
    let (chat_url, chat_handle) = single_chat_server(initial_minutes);
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": TEST_KEY,
            "model": "qwen-plus",
            "chatEndpoint": chat_url
        }),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "summarize", "recordId": id}),
        NOW,
    );
    let summarized = poll_until(&mut runtime, NOW, |rt| {
        matches!(
            rt.workspace().record(&id).unwrap().analysis,
            AnalysisState::Ready { .. }
        )
    });
    chat_handle.join().unwrap();
    assert_eq!(summarized["detail"]["status"], "已整理");
    assert_eq!(summarized["detail"]["minutesStale"], false);

    let edit1 = dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": id,
            "segmentId": "S1",
            "text": "Cicada 模块按 80% 灰度推进。"
        }),
        NOW + 1,
    );
    assert_eq!(edit1["notice"], "已更新原文片段");
    assert_eq!(
        edit1["detail"]["segments"][0]["text"],
        "Cicada 模块按 80% 灰度推进。"
    );
    assert_eq!(
        edit1["detail"]["segments"][0]["originalText"],
        "西卡达模块按70%灰度推进。"
    );
    assert_eq!(edit1["detail"]["segments"][0]["isEdited"], true);
    assert_eq!(edit1["detail"]["minutesStale"], true);
    assert_eq!(edit1["detail"]["status"], "原文已变更待重算");
    assert_eq!(edit1["records"][0]["status"], "原文已变更待重算");

    let edit2 = dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": id,
            "segmentId": "S1",
            "text": "Cicada 模块按 85% 灰度推进。"
        }),
        NOW + 2,
    );
    assert_eq!(
        edit2["detail"]["segments"][0]["text"],
        "Cicada 模块按 85% 灰度推进。"
    );
    assert_eq!(
        edit2["detail"]["segments"][0]["originalText"],
        "西卡达模块按70%灰度推进。"
    );
    assert_eq!(edit2["detail"]["segments"][0]["isEdited"], true);

    let reverted = dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": id,
            "segmentId": "S1",
            "text": "西卡达模块按70%灰度推进。"
        }),
        NOW + 3,
    );
    assert_eq!(
        reverted["detail"]["segments"][0]["originalText"],
        Value::Null
    );
    assert_eq!(reverted["detail"]["segments"][0]["isEdited"], false);

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": id,
            "segmentId": "S1",
            "text": "Cicada 模块按 85% 灰度推进。"
        }),
        NOW + 4,
    );

    let renamed = dispatch_ok(
        &mut runtime,
        json!({
            "type": "rename_speaker",
            "recordId": id,
            "fromSpeaker": "发言人 1：",
            "toSpeaker": "张工："
        }),
        NOW + 5,
    );
    assert_eq!(renamed["notice"], "已将 2 段说话人更新为 张工");

    let merged = dispatch_ok(
        &mut runtime,
        json!({
            "type": "rename_speaker",
            "recordId": id,
            "fromSpeaker": "发言人 2",
            "toSpeaker": "张工"
        }),
        NOW + 6,
    );
    assert_eq!(merged["notice"], "已将 1 段说话人更新为 张工");
    assert_eq!(
        merged["detail"]["speakers"],
        json!([{"name": "张工", "segmentCount": 3, "firstSegmentId": "S1"}])
    );
    assert_eq!(merged["detail"]["minutesStale"], true);
    assert_eq!(merged["detail"]["status"], "原文已变更待重算");
    let summary_texts: Vec<&str> = merged["detail"]["summary"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["text"].as_str().unwrap())
        .collect();
    assert!(summary_texts.iter().any(|t| t.contains("发言人 1")));
    assert!(summary_texts.iter().all(|t| !t.contains("张工")));

    drop(runtime);

    let mut reopened = dir.open();
    let persisted = dispatch_ok(
        &mut reopened,
        json!({"type": "select_record", "recordId": id}),
        NOW + 7,
    );
    assert_eq!(
        persisted["detail"]["segments"][0]["text"],
        "Cicada 模块按 85% 灰度推进。"
    );
    assert_eq!(
        persisted["detail"]["segments"][0]["originalText"],
        "西卡达模块按70%灰度推进。"
    );
    assert_eq!(persisted["detail"]["segments"][0]["isEdited"], true);
    assert_eq!(
        persisted["detail"]["speakers"],
        json!([{"name": "张工", "segmentCount": 3, "firstSegmentId": "S1"}])
    );
    assert_eq!(persisted["detail"]["minutesStale"], true);
    assert_eq!(persisted["detail"]["status"], "原文已变更待重算");
    assert_eq!(persisted["detail"]["canEditTranscript"], true);
}

#[test]
fn custody_guards_reject_edits_across_trash_archive_mic_ble_and_cloud_transcription() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let created = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "受保护记录", "text": "初始句子内容。"}),
        NOW,
    );
    let rec_id = created["selectedRecordId"].as_str().unwrap().to_owned();
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": rec_id,
            "segmentId": "S1",
            "speaker": "发言人 1"
        }),
        NOW,
    );
    assert_eq!(runtime.snapshot(NOW)["detail"]["canEditTranscript"], true);

    let archived = dispatch_ok(
        &mut runtime,
        json!({"type": "set_record_archived", "recordId": rec_id, "archived": true}),
        NOW,
    );
    assert_eq!(archived["detail"]["canEditTranscript"], false);
    for cmd in [
        json!({"type": "edit_segment_text", "recordId": rec_id, "segmentId": "S1", "text": "禁止修改"}),
        json!({"type": "set_segment_speaker", "recordId": rec_id, "segmentId": "S1", "speaker": "张工"}),
        json!({"type": "rename_speaker", "recordId": rec_id, "fromSpeaker": "发言人 1", "toSpeaker": "张工"}),
    ] {
        let rejected = dispatch_raw(&mut runtime, cmd, NOW);
        assert!(rejected["error"].as_str().unwrap().contains("归档保护"));
    }
    let unarchived = dispatch_ok(
        &mut runtime,
        json!({"type": "set_record_archived", "recordId": rec_id, "archived": false}),
        NOW,
    );
    assert_eq!(unarchived["detail"]["canEditTranscript"], true);

    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": rec_id}),
        NOW,
    );
    for cmd in [
        json!({"type": "edit_segment_text", "recordId": rec_id, "segmentId": "S1", "text": "回收站禁止修改"}),
        json!({"type": "set_segment_speaker", "recordId": rec_id, "segmentId": "S1", "speaker": "张工"}),
        json!({"type": "rename_speaker", "recordId": rec_id, "fromSpeaker": "发言人 1", "toSpeaker": "张工"}),
    ] {
        let rejected = dispatch_raw(&mut runtime, cmd, NOW);
        assert!(rejected["error"].as_str().unwrap().contains("回收站"));
    }
    dispatch_ok(
        &mut runtime,
        json!({"type": "restore_record", "recordId": rec_id}),
        NOW,
    );
    let restored = dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": rec_id}),
        NOW,
    );
    assert_eq!(restored["detail"]["canEditTranscript"], true);

    let quitting = dispatch_ok(&mut runtime, json!({"type": "request_quit"}), NOW);
    assert_eq!(quitting["detail"]["canEditTranscript"], false);
    assert!(
        dispatch_raw(
            &mut runtime,
            json!({"type": "edit_segment_text", "recordId": rec_id, "segmentId": "S1", "text": "退出中"}),
            NOW
        )["error"]
            .is_string()
    );
    let cancelled_quit = dispatch_ok(&mut runtime, json!({"type": "cancel_quit"}), NOW);
    assert_eq!(cancelled_quit["detail"]["canEditTranscript"], true);

    let mic = dispatch_ok(
        &mut runtime,
        json!({"type": "start_microphone", "inputId": "built-in", "includeSystem": false}),
        NOW,
    )["microphone"]
        .clone();
    let mic_id = mic["recordId"].as_str().unwrap().to_owned();
    let mic_session = mic["sessionId"].as_str().unwrap().to_owned();
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_started",
            "recordId": mic_id,
            "sessionId": mic_session,
            "lane": "microphone",
            "sampleRate": 16000
        }),
        NOW,
    );
    let receipt = runtime.ingest_microphone_pcm(koe_runtime::MicrophonePcmChunk {
        record_id: &mic_id,
        session_id: &mic_session,
        lane: "microphone",
        sequence: 0,
        samples: &vec![12; 320],
        timing: None,
        now: NOW,
    });
    assert_eq!(receipt.status, koe_runtime::PcmIngestStatus::Accepted);
    let mic_rejected = dispatch_raw(
        &mut runtime,
        json!({"type": "edit_segment_text", "recordId": mic_id, "segmentId": "S1", "text": "录音中禁止修改"}),
        NOW,
    );
    assert_eq!(
        mic_rejected["error"],
        "录音仍在进行或等待保存，完成后才能编辑原文"
    );
    dispatch_ok(&mut runtime, json!({"type": "stop_microphone"}), NOW);
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_stopped",
            "recordId": mic_id,
            "sessionId": mic_session,
            "lane": "microphone",
            "sequence": 1
        }),
        NOW,
    );

    connect_bean(&mut runtime, "ble-edit-guard", NOW);
    dispatch_ok(&mut runtime, json!({"type": "device_start"}), NOW);
    runtime.drain_outbound_ble_frames();
    runtime.ingest_ble_chunk(&unencrypted_file_head_rx(711, 0xFFFF_FFFF), NOW);
    runtime.ingest_ble_chunk(&slices_rx(0..1), NOW);
    let live_id = runtime.snapshot(NOW)["device"]["liveRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let live_selected = dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": live_id}),
        NOW,
    );
    assert_eq!(live_selected["detail"]["canEditTranscript"], false);
    let ble_live_rejected = dispatch_raw(
        &mut runtime,
        json!({"type": "edit_segment_text", "recordId": live_id, "segmentId": "S1", "text": "同步中"}),
        NOW,
    );
    assert_eq!(
        ble_live_rejected["error"],
        "这条录音正在同步或保存中，请等待完成后再编辑原文"
    );

    runtime.ingest_ble_chunk(&rx_frame(0x18, 0x82, &[0]), NOW + 1);
    runtime.poll_timers(2_000, NOW + 3);
    runtime.ingest_ble_chunk(&catalog_1b0e_rx(711, 40, NOW as u32 + 1), NOW + 3);
    dispatch_ok(
        &mut runtime,
        json!({"type": "device_download", "fileId": 711}),
        NOW + 3,
    );
    let pulling_selected = dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": live_id}),
        NOW + 3,
    );
    assert_eq!(pulling_selected["detail"]["canEditTranscript"], false);
    let ble_pull_rejected = dispatch_raw(
        &mut runtime,
        json!({"type": "edit_segment_text", "recordId": live_id, "segmentId": "S1", "text": "拉取中"}),
        NOW + 3,
    );
    assert_eq!(
        ble_pull_rejected["error"],
        "这条录音正在同步或保存中，请等待完成后再编辑原文"
    );
    dispatch_ok(&mut runtime, json!({"type": "device_disconnect"}), NOW + 3);
    dispatch_ok(&mut runtime, json!({"type": "trash_record", "recordId": mic_id}), NOW + 3);
    dispatch_ok(&mut runtime, json!({"type": "trash_record", "recordId": live_id}), NOW + 3);

    let wav_path = dir.0.join("cloud-transcribe.wav");
    write_wav(&wav_path);
    let imported = dispatch_ok(
        &mut runtime,
        json!({"type": "import_file", "path": wav_path}),
        NOW + 4,
    );
    let cloud_id = imported["selectedRecordId"].as_str().unwrap().to_owned();

    let (asr_url, wait_audio, release_finals, asr_handle) = gated_asr_server();
    let (chat_url, chat_handle) = single_chat_server(
        json!({
            "schemaVersion": 2,
            "title": "转写纪要",
            "overview": "云端转写首句。",
            "topics": [{"text": "转写纪要", "summary": "云端转写首句。", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [],
            "reviewItems": []
        })
        .to_string(),
    );
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": TEST_KEY,
            "model": "qwen-plus",
            "asrEndpoint": asr_url,
            "chatEndpoint": chat_url
        }),
        NOW + 4,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "configure_speech", "engine": "cloud"}),
        NOW + 4,
    );
    let transcribing = dispatch_ok(
        &mut runtime,
        json!({"type": "transcribe", "recordId": cloud_id}),
        NOW + 4,
    );
    assert_eq!(transcribing["detail"]["status"], "转写中");
    assert_eq!(transcribing["detail"]["canEditTranscript"], false);
    wait_audio.recv_timeout(Duration::from_secs(5)).unwrap();
    let transcribe_rejected = dispatch_raw(
        &mut runtime,
        json!({"type": "edit_segment_text", "recordId": cloud_id, "segmentId": "S1", "text": "转写中禁止修改"}),
        NOW + 4,
    );
    assert!(transcribe_rejected["error"].is_string());
    dispatch_ok(&mut runtime, json!({"type": "clear_error"}), NOW + 4);

    release_finals.send(()).unwrap();
    let finished = poll_until(&mut runtime, NOW + 5, |rt| {
        matches!(
            rt.workspace().record(&cloud_id).unwrap().analysis,
            AnalysisState::Ready { .. }
        )
    });
    asr_handle.join().unwrap();
    chat_handle.join().unwrap();
    assert_eq!(finished["detail"]["canEditTranscript"], true);
}

#[test]
fn inflight_summary_race_allows_edits_drops_stale_minutes_and_resummarizes_cleanly() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let chat_url = format!("http://{}/chat/completions", listener.local_addr().unwrap());

    let (req1_seen, wait_req1) = mpsc::channel();
    let (release_req1, hold_req1) = mpsc::channel::<String>();
    let (req2_seen, wait_req2) = mpsc::channel();
    let (release_req2, hold_req2) = mpsc::channel::<String>();
    let (req3_seen, wait_req3) = mpsc::channel();
    let (release_req3, hold_req3) = mpsc::channel::<String>();

    let server = thread::spawn(move || {
        let s1 = accept_http_stream(&listener);
        req1_seen.send(()).unwrap();
        let body1 = hold_req1.recv_timeout(Duration::from_secs(10)).unwrap();
        write_chat_response(s1, &body1);

        let s2 = accept_http_stream(&listener);
        req2_seen.send(()).unwrap();
        let s3 = accept_http_stream(&listener);
        req3_seen.send(()).unwrap();

        let body2 = hold_req2.recv_timeout(Duration::from_secs(10)).unwrap();
        write_chat_response(s2, &body2);
        let body3 = hold_req3.recv_timeout(Duration::from_secs(10)).unwrap();
        write_chat_response(s3, &body3);
    });

    let dir = Sandbox::new();
    let mut runtime = dir.open();
    let created = dispatch_ok(
        &mut runtime,
        json!({
            "type": "create_note",
            "title": "配额复盘",
            "text": "灰度比例定在 80% 推进。\n周五补齐监控。"
        }),
        NOW,
    );
    let id = created["selectedRecordId"].as_str().unwrap().to_owned();
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": TEST_KEY,
            "model": "qwen-plus",
            "chatEndpoint": chat_url
        }),
        NOW,
    );

    let started1 = dispatch_ok(
        &mut runtime,
        json!({"type": "summarize", "recordId": id}),
        NOW,
    );
    assert_eq!(started1["detail"]["status"], "整理中");
    assert_eq!(started1["detail"]["canEditTranscript"], true);
    wait_req1.recv_timeout(Duration::from_secs(5)).unwrap();

    let edited1 = dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": id,
            "segmentId": "S1",
            "text": "灰度比例定在 82% 推进。"
        }),
        NOW + 1,
    );
    assert_eq!(edited1["detail"]["canEditTranscript"], true);
    assert_eq!(edited1["detail"]["status"], "已有文字");

    release_req1
        .send(
            json!({
                "schemaVersion": 2,
                "title": "配额复盘",
                "overview": "灰度比例定在 80% 推进。",
                "topics": [{"text": "灰度比例", "summary": "按 80% 推进", "sources": ["S1"]}],
                "decisions": [{"text": "灰度比例定在 80% 推进", "sources": ["S1"]}],
                "actions": [],
                "questions": [],
                "terms": [],
                "reviewItems": []
            })
            .to_string(),
        )
        .unwrap();

    thread::sleep(Duration::from_millis(30));
    runtime.poll_timers(30, NOW + 2);
    let after_stale1 = runtime.snapshot(NOW + 2);
    assert!(after_stale1["error"].is_null());
    assert_eq!(after_stale1["detail"]["status"], "已有文字");
    assert!(after_stale1["detail"]["summary"].as_array().unwrap().is_empty());
    assert!(!matches!(
        runtime.workspace().record(&id).unwrap().analysis,
        AnalysisState::Failed { .. }
    ));

    dispatch_ok(
        &mut runtime,
        json!({"type": "summarize", "recordId": id}),
        NOW + 3,
    );
    wait_req2.recv_timeout(Duration::from_secs(5)).unwrap();

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": id,
            "segmentId": "S1",
            "text": "灰度比例定在 85% 推进。"
        }),
        NOW + 4,
    );
    let restarted = dispatch_ok(
        &mut runtime,
        json!({"type": "summarize", "recordId": id}),
        NOW + 4,
    );
    assert_eq!(restarted["detail"]["status"], "整理中");
    assert_eq!(restarted["detail"]["canEditTranscript"], true);
    wait_req3.recv_timeout(Duration::from_secs(5)).unwrap();

    release_req2
        .send(
            json!({
                "schemaVersion": 2,
                "title": "配额复盘",
                "overview": "灰度比例定在 82% 推进。",
                "topics": [{"text": "灰度比例", "summary": "按 82% 推进", "sources": ["S1"]}],
                "decisions": [{"text": "灰度比例定在 82% 推进", "sources": ["S1"]}],
                "actions": [],
                "questions": [],
                "terms": [],
                "reviewItems": []
            })
            .to_string(),
        )
        .unwrap();
    thread::sleep(Duration::from_millis(30));
    runtime.poll_timers(30, NOW + 5);
    assert_eq!(runtime.snapshot(NOW + 5)["detail"]["status"], "整理中");

    release_req3
        .send(
            json!({
                "schemaVersion": 2,
                "title": "配额复盘",
                "overview": "灰度比例定在 85% 推进。",
                "topics": [{"text": "灰度比例", "summary": "按 85% 推进", "sources": ["S1"]}],
                "decisions": [{"text": "灰度比例定在 85% 推进", "sources": ["S1"]}],
                "actions": [],
                "questions": [],
                "terms": [],
                "reviewItems": []
            })
            .to_string(),
        )
        .unwrap();

    let refreshed = poll_until(&mut runtime, NOW + 6, |rt| {
        matches!(
            rt.workspace().record(&id).unwrap().analysis,
            AnalysisState::Ready { .. }
        )
    });
    server.join().unwrap();
    assert_eq!(refreshed["detail"]["status"], "已整理");
    assert_eq!(refreshed["detail"]["minutesStale"], false);
    assert_eq!(
        refreshed["detail"]["summary"][0]["text"],
        "灰度比例定在 85% 推进。"
    );
}

#[test]
fn markdown_export_includes_speaker_prefixes_and_stale_minutes_banner() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let created = dispatch_ok(
        &mut runtime,
        json!({
            "type": "create_note",
            "title": "导出纪要",
            "text": "推进 80% 灰度方案。\n补充压测报告。"
        }),
        NOW,
    );
    let id = created["selectedRecordId"].as_str().unwrap().to_owned();
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": id,
            "segmentId": "S1",
            "speaker": "张工："
        }),
        NOW,
    );

    let (chat_url, chat_handle) = single_chat_server(
        json!({
            "schemaVersion": 2,
            "title": "导出纪要",
            "overview": "张工确认推进 80% 灰度方案。",
            "topics": [{"text": "灰度方案", "summary": "按 80% 灰度执行", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [],
            "reviewItems": []
        })
        .to_string(),
    );
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": TEST_KEY,
            "model": "qwen-plus",
            "chatEndpoint": chat_url
        }),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "summarize", "recordId": id}),
        NOW,
    );
    poll_until(&mut runtime, NOW, |rt| {
        matches!(
            rt.workspace().record(&id).unwrap().analysis,
            AnalysisState::Ready { .. }
        )
    });
    chat_handle.join().unwrap();

    let fresh_md = dir.0.join("fresh.md");
    dispatch_ok(
        &mut runtime,
        json!({"type": "export_workspace_markdown", "recordId": id, "path": fresh_md}),
        NOW,
    );
    let fresh_text = fs::read_to_string(&fresh_md).unwrap();
    assert!(!fresh_text.contains("> 注：原文已变更，以下纪要待重新整理。"));
    assert!(fresh_text.contains("[S1] 张工：推进 80% 灰度方案。\n\n"));
    assert!(fresh_text.contains("[S2] 补充压测报告。\n\n"));

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": id,
            "segmentId": "S1",
            "text": "推进 85% 灰度方案。"
        }),
        NOW + 1,
    );

    let stale_md = dir.0.join("stale.md");
    dispatch_ok(
        &mut runtime,
        json!({"type": "export_workspace_markdown", "recordId": id, "path": stale_md}),
        NOW + 1,
    );
    let stale_text = fs::read_to_string(&stale_md).unwrap();
    assert!(stale_text.starts_with("# 导出纪要\n"));
    assert!(stale_text.contains(
        "## AI 整理\n\n> 注：原文已变更，以下纪要待重新整理。\n\n张工确认推进 80% 灰度方案。\n\n"
    ));
    assert!(stale_text.contains("[S1] 张工：推进 85% 灰度方案。\n\n"));
    assert!(stale_text.contains("[S2] 补充压测报告。\n\n"));
}

#[test]
fn stale_summary_reclaim_unblocks_trash_and_busy_summary_lane_preserves_record_state_while_ask_runs_independently() {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let chat_url = format!("http://{}/chat/completions", listener.local_addr().unwrap());

    let (req1_seen, wait_req1) = mpsc::channel();
    let (release_req1, hold_req1) = mpsc::channel::<()>();
    let (req2_seen, wait_req2) = mpsc::channel();
    let (release_req2, hold_req2) = mpsc::channel::<String>();
    let (req3_seen, wait_req3) = mpsc::channel();
    let (release_req3, hold_req3) = mpsc::channel::<String>();

    let server = thread::spawn(move || {
        let s1 = accept_http_stream(&listener);
        req1_seen.send(()).unwrap();
        hold_req1.recv_timeout(Duration::from_secs(10)).unwrap();
        write_chat_response(s1, "{}");

        let s2 = accept_http_stream(&listener);
        req2_seen.send(()).unwrap();

        let s3 = accept_http_stream(&listener);
        req3_seen.send(()).unwrap();
        let body3 = hold_req3.recv_timeout(Duration::from_secs(10)).unwrap();
        write_chat_response(s3, &body3);

        let body2 = hold_req2.recv_timeout(Duration::from_secs(10)).unwrap();
        write_chat_response(s2, &body2);
    });

    let dir = Sandbox::new();
    let mut runtime = dir.open();
    let rec1 = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "待删记录", "text": "旧的方案草稿。"}),
        NOW,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let rec2 = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "网关预案", "text": "负责主备切换演练。"}),
        NOW,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let rec3 = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "容量规划", "text": "核对峰值并发预算。"}),
        NOW,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "set_segment_speaker",
            "recordId": rec2,
            "segmentId": "S1",
            "speaker": "林架构师"
        }),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": TEST_KEY,
            "model": "qwen-plus",
            "chatEndpoint": chat_url
        }),
        NOW,
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "summarize", "recordId": rec1}),
        NOW,
    );
    wait_req1.recv_timeout(Duration::from_secs(5)).unwrap();

    dispatch_ok(
        &mut runtime,
        json!({
            "type": "edit_segment_text",
            "recordId": rec1,
            "segmentId": "S1",
            "text": "修正后的方案草稿。"
        }),
        NOW + 1,
    );
    let trashed = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": rec1}),
        NOW + 1,
    );
    assert_eq!(trashed["trashRecords"].as_array().unwrap().len(), 1);
    release_req1.send(()).unwrap();

    dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": rec2}),
        NOW + 2,
    );
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "ask",
            "question": "林架构师负责什么？",
            "scope": "record",
            "recordId": rec2
        }),
        NOW + 2,
    );
    wait_req2.recv_timeout(Duration::from_secs(5)).unwrap();

    dispatch_ok(
        &mut runtime,
        json!({"type": "summarize", "recordId": rec3}),
        NOW + 2,
    );
    wait_req3.recv_timeout(Duration::from_secs(5)).unwrap();

    let busy = dispatch_raw(
        &mut runtime,
        json!({"type": "summarize", "recordId": rec2}),
        NOW + 2,
    );
    assert_eq!(busy["error"], "已有云端任务正在处理，请稍后重试");
    runtime.poll_timers(20, NOW + 2);
    assert!(!matches!(
        runtime.workspace().record(&rec2).unwrap().analysis,
        AnalysisState::Failed { .. }
    ));
    let selected_rec2 = dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": rec2}),
        NOW + 2,
    );
    assert_eq!(selected_rec2["detail"]["status"], "已有文字");

    release_req3
        .send(r#"{"schemaVersion":2,"title":"容量规划","overview":"核对峰值并发预算。","topics":[],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#.into())
        .unwrap();
    release_req2
        .send("林架构师负责主备切换演练 [S1]。".into())
        .unwrap();
    let answered = poll_until(&mut runtime, NOW + 3, |rt| {
        let snap = rt.snapshot(NOW + 3);
        snap["ask"]["phase"] == "ready"
            && matches!(
                rt.workspace().record(&rec3).unwrap().analysis,
                AnalysisState::Ready { .. }
            )
    });
    server.join().unwrap();
    assert!(answered["error"].is_null());
    assert!(!matches!(
        runtime.workspace().record(&rec2).unwrap().analysis,
        AnalysisState::Failed { .. }
    ));
}

#[test]
fn legacy_session_messy_speakers_normalize_on_import_without_bumping_edit_revision() {
    let dir = Sandbox::new();
    let messy_speaker = format!("  发言人\u{0007}_{}：: ", "甲".repeat(45));
    fs::write(
        dir.0.join("workspace_session.json"),
        json!({
            "activeFileId": 0,
            "durationMs": 4000,
            "segments": [{
                "text": "历史遗留分段文本。",
                "startMs": 0,
                "endMs": 4000,
                "speaker": messy_speaker
            }]
        })
        .to_string(),
    )
    .unwrap();

    let runtime = dir.open();
    let record = runtime.workspace().record("legacy-workspace").unwrap();
    assert_eq!(record.content_revision, 1);
    let seg = &record.aggregate.spine.segments()[0];
    let spk = seg.speaker.as_deref().unwrap();
    assert_eq!(spk.chars().count(), 40);
    assert!(!spk.chars().any(char::is_control));
    assert!(!spk.ends_with([':', '：']));
    assert!(!seg.is_edited());
}
