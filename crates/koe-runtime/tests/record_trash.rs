use std::fs;
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use koe_client_services::recording_assets;
use koe_engine::crypto::DeviceCrypto;
use koe_engine::frame::{ProtocolFrame, RX_MAGIC};
use koe_engine::product::{AnalysisState, SearchScope};
use koe_engine::session::REAL_OPUS_20MS_440HZ_PACKET;
use koe_engine::transport::OPUS_FRAME_BYTES;
use koe_engine::wav::OpusWave;
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

const NOW: u64 = 1_800_000_000;
const TEST_KEY: &str = "local-trash-test-key";

struct Sandbox(PathBuf, PathBuf);

impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let id = NEXT.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!(
            "koe-record-trash-{}-{id}",
            std::process::id(),
        ));
        let external = std::env::temp_dir().join(format!(
            "koe-record-trash-ext-{}-{id}",
            std::process::id(),
        ));
        fs::create_dir_all(&path).unwrap();
        fs::create_dir_all(&external).unwrap();
        Self(path, external)
    }

    fn open(&self) -> KoeRuntime {
        KoeRuntime::open(&self.0).unwrap()
    }

    fn external(&self, name: &str) -> PathBuf {
        self.1.join(name)
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
        let _ = fs::remove_dir_all(&self.1);
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
    assert!(snap["error"].is_null(), "unexpected error: {}", snap["error"]);
    snap
}

fn write_wav(path: &Path, sample_byte: u8) -> Vec<u8> {
    let mut wav = OpusWave::wav_header_with_rate(3200, 16000).to_vec();
    wav.extend(vec![sample_byte; 3200]);
    fs::write(path, &wav).unwrap();
    wav
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

#[allow(clippy::result_large_err)]
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
                let Ok(Ok((stream, _))) =
                    tokio::time::timeout(Duration::from_secs(5), listener.accept()).await
                else {
                    return;
                };
                let Ok(mut ws) = tokio_tungstenite::accept_hdr_async(
                    stream,
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
                else {
                    return;
                };
                let Some(Ok(first)) = ws.next().await else {
                    return;
                };
                let run: Value = serde_json::from_str(first.to_text().unwrap()).unwrap();
                let id = run["header"]["task_id"].as_str().unwrap().to_owned();
                let _ = ws
                    .send(Message::Text(
                        json!({"header":{"event":"task-started","task_id":id},"payload":{}})
                            .to_string()
                            .into(),
                    ))
                    .await;
                while let Some(Ok(frame)) = ws.next().await {
                    if let Message::Text(text) = frame {
                        let finish: Value = serde_json::from_str(&text).unwrap();
                        if finish["header"]["action"] == "finish-task" {
                            break;
                        }
                    }
                }
                let _ = audio_received.send(());
                if wait_release.recv_timeout(Duration::from_secs(5)).is_err() {
                    return;
                }
                let _ = ws
                    .send(Message::Text(
                        json!({
                            "header":{"event":"result-generated","task_id":id},
                            "payload":{"output":{"sentence":{"sentence_id":0,"sentence_end":true,"begin_time":0,"end_time":100,"text":"云端转写完成的句子。"}}}
                        })
                        .to_string()
                        .into(),
                    ))
                    .await;
                let _ = ws
                    .send(Message::Text(
                        json!({"header":{"event":"task-finished","task_id":id},"payload":{}})
                            .to_string()
                            .into(),
                    ))
                    .await;
                let _ = ws.close(None).await;
            });
    });
    (endpoint, wait_audio, release_finals, handle)
}

fn gated_chat_server(
    answer: String,
) -> (
    String,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
    thread::JoinHandle<()>,
) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let (req_received, wait_req) = mpsc::channel();
    let (release_resp, wait_release) = mpsc::channel();
    let handle = thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Err(_) => return,
            }
        };
        stream.set_nonblocking(false).unwrap();
        let _ = stream.set_read_timeout(Some(Duration::from_secs(5)));
        let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));
        let mut bytes = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let Ok(count) = stream.read(&mut chunk) else {
                return;
            };
            if count == 0 {
                break;
            }
            bytes.extend_from_slice(&chunk[..count]);
            if let Some(boundary) = bytes.windows(4).position(|part| part == b"\r\n\r\n") {
                let headers = std::str::from_utf8(&bytes[..boundary]).unwrap_or("");
                let length: usize = headers
                    .lines()
                    .find_map(|line| {
                        let (name, value) = line.split_once(':')?;
                        name.eq_ignore_ascii_case("content-length")
                            .then(|| value.trim().parse().ok())
                            .flatten()
                    })
                    .unwrap_or(0);
                if bytes.len() >= boundary + 4 + length {
                    break;
                }
            }
        }
        let _ = req_received.send(());
        if wait_release.recv_timeout(Duration::from_secs(5)).is_err() {
            return;
        }
        let body = json!({"choices":[{"message":{"content":answer}}]}).to_string();
        let _ = write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
    });
    (endpoint, wait_req, release_resp, handle)
}

#[test]
fn archive_lock_blocks_deletion_and_undo_banner_ticks_without_idle_generation_churn() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();
    let created = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "董事会决议", "text": "保留三年预算方案。"}),
        NOW,
    );
    let id = created["selectedRecordId"].as_str().unwrap().to_owned();
    assert_eq!(created["records"][0]["archived"], false);
    assert_eq!(created["detail"]["archived"], false);
    assert_eq!(created["trashRecords"], json!([]));
    assert!(created["undoTrash"].is_null());

    let archived = dispatch_ok(
        &mut runtime,
        json!({"type": "set_record_archived", "recordId": id, "archived": true}),
        NOW,
    );
    assert_eq!(archived["records"][0]["archived"], true);
    assert_eq!(archived["detail"]["archived"], true);

    let blocked_trash = dispatch_raw(
        &mut runtime,
        json!({"type": "trash_record", "recordId": id}),
        NOW,
    );
    assert!(blocked_trash["error"].as_str().unwrap().contains("归档"));
    assert_eq!(blocked_trash["records"].as_array().unwrap().len(), 1);
    assert_eq!(blocked_trash["trashRecords"], json!([]));
    assert!(blocked_trash["undoTrash"].is_null());

    let blocked_purge = dispatch_raw(
        &mut runtime,
        json!({"type": "purge_record", "recordId": id}),
        NOW,
    );
    assert!(blocked_purge["error"].as_str().unwrap().contains("归档"));

    let unarchived = dispatch_ok(
        &mut runtime,
        json!({"type": "set_record_archived", "recordId": id, "archived": false}),
        NOW,
    );
    assert_eq!(unarchived["records"][0]["archived"], false);

    let trashed = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": id}),
        NOW,
    );
    assert_eq!(trashed["records"], json!([]));
    assert_eq!(trashed["trashRecords"].as_array().unwrap().len(), 1);
    assert_eq!(
        trashed["undoTrash"],
        json!({"recordId": id, "title": "董事会决议"})
    );
    assert!(trashed["undoTrash"].get("remainingMs").is_none());

    let dismissed = dispatch_ok(&mut runtime, json!({"type": "dismiss_undo_trash"}), NOW);
    assert!(dismissed["undoTrash"].is_null());

    dispatch_ok(
        &mut runtime,
        json!({"type": "restore_record", "recordId": id}),
        NOW,
    );
    let trashed_again = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": id}),
        NOW,
    );
    assert_eq!(trashed_again["undoTrash"]["recordId"], id);

    let nav_trash = dispatch_ok(
        &mut runtime,
        json!({"type": "navigate", "section": "trash"}),
        NOW,
    );
    assert_eq!(nav_trash["section"], "trash");

    let gen_before = runtime.generation();
    for step in 0..31 {
        runtime.poll_timers(250, NOW + (step / 4));
        assert_eq!(
            runtime.generation(),
            gen_before,
            "idle 250ms tick {step} must not bump generation while undoTrash is visible"
        );
    }
    assert_eq!(runtime.snapshot(NOW + 7)["undoTrash"]["recordId"], id);

    runtime.poll_timers(250, NOW + 8);
    assert_eq!(runtime.generation(), gen_before + 1);
    assert!(runtime.snapshot(NOW + 8)["undoTrash"].is_null());
}

#[test]
fn soft_delete_stops_playback_hides_across_views_and_restores_tasks_and_audio_intact() {
    let dir = Sandbox::new();
    let wav_input = dir.external("meeting.wav");
    write_wav(&wav_input, 12);

    let mut runtime = dir.open();
    let note_created = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "季度复盘", "text": "周五提交原型方案。\n保留独立音频索引。"}),
        NOW,
    );
    let id = note_created["selectedRecordId"].as_str().unwrap().to_owned();
    let audio_bytes = fs::read(&wav_input).unwrap();
    let owned_wav = recording_assets::save_audio(&dir.0, &id, &audio_bytes).unwrap();

    let with_task = dispatch_ok(
        &mut runtime,
        json!({"type": "create_task", "recordId": id, "segmentId": "S1"}),
        NOW,
    );
    let task_id = with_task["tasks"][0]["id"].as_str().unwrap().to_owned();
    dispatch_ok(
        &mut runtime,
        json!({"type": "complete_task", "itemId": task_id, "completed": true}),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "save_memory", "recordId": id, "segmentId": "S2"}),
        NOW,
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "navigate", "section": "records"}),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": id}),
        NOW,
    );
    let playing = dispatch_ok(
        &mut runtime,
        json!({"type": "playback", "isPlaying": true}),
        NOW,
    );
    assert_eq!(playing["section"], "detail");
    assert_eq!(playing["playback"]["isPlaying"], true);
    let prev_request_id = playing["playback"]["requestId"].as_u64().unwrap();

    let trashed = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": id}),
        NOW,
    );
    assert_eq!(trashed["section"], "records");
    assert!(trashed["detail"].is_null());
    assert!(trashed["selectedRecordId"].is_null());
    assert_eq!(trashed["playback"]["isPlaying"], false);
    assert!(trashed["playback"]["recordId"].is_null());
    assert!(trashed["playback"]["requestId"].as_u64().unwrap() > prev_request_id);
    assert_eq!(trashed["records"], json!([]));
    assert_eq!(trashed["tasks"], json!([]));
    assert_eq!(trashed["memories"], json!([]));
    assert_eq!(trashed["trashRecords"].as_array().unwrap().len(), 1);
    assert_eq!(trashed["trashRecords"][0]["id"], id);
    assert_eq!(trashed["trashRecords"][0]["remainingDays"], 30);
    assert_eq!(trashed["trashRecords"][0]["trashedAtMs"], NOW * 1000);
    assert_eq!(
        trashed["trashRecords"][0]["expiresAtMs"],
        NOW * 1000 + 30 * 86_400_000
    );
    assert!(owned_wav.exists());

    assert!(
        dispatch_raw(&mut runtime, json!({"type": "select_record", "recordId": id}), NOW)["error"]
            .is_string()
    );
    assert!(
        dispatch_raw(&mut runtime, json!({"type": "playback", "isPlaying": true}), NOW)["error"]
            .is_string()
    );
    assert!(runtime
        .workspace()
        .search(&SearchScope::All, "原型方案", 10)
        .unwrap()
        .is_empty());
    assert!(runtime
        .workspace()
        .search(&SearchScope::Record(id.clone()), "原型方案", 10)
        .is_err());
    let scoped_ask = dispatch_raw(
        &mut runtime,
        json!({"type": "ask", "question": "原型方案", "scope": "record", "recordId": id}),
        NOW,
    );
    assert!(scoped_ask["error"].is_string());

    let global_ask = dispatch_ok(
        &mut runtime,
        json!({"type": "ask", "question": "原型方案", "scope": "all", "recordId": null}),
        NOW,
    );
    assert!(global_ask["ask"]["messages"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()["sources"]
        .as_array()
        .unwrap()
        .is_empty());

    let restored = dispatch_ok(
        &mut runtime,
        json!({"type": "restore_record", "recordId": id}),
        NOW + 5,
    );
    assert_eq!(restored["notice"], "已从回收站恢复记录");
    assert!(restored["undoTrash"].is_null());
    assert_eq!(restored["trashRecords"], json!([]));
    assert_eq!(restored["records"].as_array().unwrap().len(), 1);
    assert_eq!(restored["records"][0]["id"], id);
    assert_eq!(restored["tasks"][0]["id"], task_id);
    assert_eq!(restored["tasks"][0]["state"], "accepted");
    assert_eq!(restored["tasks"][0]["completed"], true);
    assert_eq!(restored["memories"][0]["state"], "accepted");

    dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": id}),
        NOW + 5,
    );
    let resumed_play = dispatch_ok(
        &mut runtime,
        json!({"type": "playback", "isPlaying": true}),
        NOW + 5,
    );
    assert_eq!(resumed_play["playback"]["isPlaying"], true);
    assert_eq!(resumed_play["playback"]["recordId"], id);
}

#[test]
fn active_microphone_ble_and_cloud_guards_block_trash_and_preserve_staging_assets() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let other_id = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "旧草稿", "text": "待清理草稿"}),
        NOW,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": other_id}),
        NOW,
    );

    let mic = dispatch_ok(
        &mut runtime,
        json!({"type": "start_microphone", "inputId": "built-in", "includeSystem": true}),
        NOW,
    )["microphone"]
        .clone();
    let mic_id = mic["recordId"].as_str().unwrap().to_owned();
    let mic_session = mic["sessionId"].as_str().unwrap().to_owned();
    for lane in ["microphone", "system"] {
        dispatch_ok(
            &mut runtime,
            json!({
                "type": "microphone_started",
                "recordId": mic_id,
                "sessionId": mic_session,
                "lane": lane,
                "sampleRate": 16000
            }),
            NOW,
        );
        dispatch_ok(
            &mut runtime,
            json!({
                "type": "microphone_chunk",
                "recordId": mic_id,
                "sessionId": mic_session,
                "lane": lane,
                "sequence": 0,
                "samples": vec![42; 320]
            }),
            NOW,
        );
    }
    let mic_staging = dir.0.join("audio").join(format!("{mic_id}.capture"));
    let sys_staging = dir.0.join("audio").join(format!("{mic_id}-system.capture"));
    assert!(mic_staging.exists() && sys_staging.exists());

    let reject_active_mic = dispatch_raw(
        &mut runtime,
        json!({"type": "trash_record", "recordId": mic_id}),
        NOW,
    );
    assert!(reject_active_mic["error"].is_string());

    dispatch_ok(
        &mut runtime,
        json!({"type": "purge_record", "recordId": other_id}),
        NOW,
    );
    assert!(mic_staging.exists() && sys_staging.exists());

    let ws_json = dir.0.join("product-workspace.json");
    let backup_json = dir.0.join("backup-workspace.json");
    fs::rename(&ws_json, &backup_json).unwrap();
    fs::create_dir(&ws_json).unwrap();

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
    let save_err_snap = dispatch_raw(
        &mut runtime,
        json!({
            "type": "microphone_stopped",
            "recordId": mic_id,
            "sessionId": mic_session,
            "lane": "system",
            "sequence": 1
        }),
        NOW,
    );
    assert!(save_err_snap["microphone"]["error"].is_string());
    assert!(dir.0.join("audio").join(format!("{mic_id}.wav")).exists());
    assert!(dir
        .0
        .join("audio")
        .join(format!("{mic_id}-system.wav"))
        .exists());

    let reject_save_err_mic = dispatch_raw(
        &mut runtime,
        json!({"type": "trash_record", "recordId": mic_id}),
        NOW,
    );
    assert!(reject_save_err_mic["error"].is_string());

    fs::remove_dir(&ws_json).unwrap();
    fs::rename(&backup_json, &ws_json).unwrap();
    dispatch_ok(&mut runtime, json!({"type": "retry_microphone_save"}), NOW);
    assert!(runtime.snapshot(NOW)["microphone"].is_null());

    connect_bean(&mut runtime, "ble-guard", NOW);
    dispatch_ok(&mut runtime, json!({"type": "device_start"}), NOW);
    runtime.drain_outbound_ble_frames();
    runtime.ingest_ble_chunk(&unencrypted_file_head_rx(611, 0xFFFF_FFFF), NOW);
    runtime.ingest_ble_chunk(&slices_rx(0..1), NOW);
    let live_id = runtime.snapshot(NOW)["device"]["liveRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    assert!(
        dispatch_raw(&mut runtime, json!({"type": "trash_record", "recordId": live_id}), NOW)["error"]
            .is_string()
    );

    runtime.ingest_ble_chunk(&rx_frame(0x18, 0x82, &[0]), NOW + 1);
    assert!(
        dispatch_raw(
            &mut runtime,
            json!({"type": "trash_record", "recordId": live_id}),
            NOW + 1
        )["error"]
            .is_string()
    );
    runtime.poll_timers(2_000, NOW + 3);
    assert!(recording_assets::audio_path(&dir.0, &live_id).unwrap().exists());

    runtime.ingest_ble_chunk(&catalog_1b0e_rx(611, 40, NOW as u32 + 1), NOW + 3);
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": live_id}),
        NOW + 3,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "device_download", "fileId": 611}),
        NOW + 3,
    );
    assert!(
        dispatch_raw(
            &mut runtime,
            json!({"type": "purge_record", "recordId": live_id}),
            NOW + 3
        )["error"]
            .is_string()
    );
    dispatch_ok(&mut runtime, json!({"type": "device_disconnect"}), NOW + 3);

    let wav_file = dir.external("cloud.wav");
    write_wav(&wav_file, 5);
    let cloud_id = dispatch_ok(
        &mut runtime,
        json!({"type": "import_file", "path": wav_file}),
        NOW + 4,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();

    let summary_body = json!({
        "schemaVersion": 2,
        "title": "云端测试",
        "overview": "云端转写完成的句子。",
        "topics":[{"text":"云端测试","summary":"云端转写完成的句子。","sources":["S1"]}],
        "decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]
    })
    .to_string();
    let (asr_url, wait_audio, release_finals, asr_handle) = gated_asr_server();
    let (chat_url, wait_chat, release_chat, chat_handle) = gated_chat_server(summary_body);
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
    dispatch_ok(
        &mut runtime,
        json!({"type": "transcribe", "recordId": cloud_id}),
        NOW + 4,
    );
    wait_audio.recv_timeout(Duration::from_secs(5)).unwrap();
    assert!(
        dispatch_raw(
            &mut runtime,
            json!({"type": "trash_record", "recordId": cloud_id}),
            NOW + 4
        )["error"]
            .is_string()
    );
    release_finals.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        runtime.poll_timers(25, NOW + 5);
        if wait_chat.try_recv().is_ok() {
            break;
        }
        assert!(Instant::now() < deadline);
        thread::sleep(Duration::from_millis(5));
    }
    assert!(
        dispatch_raw(
            &mut runtime,
            json!({"type": "trash_record", "recordId": cloud_id}),
            NOW + 5
        )["error"]
            .is_string()
    );
    release_chat.send(()).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    while !matches!(
        runtime.workspace().record(&cloud_id).unwrap().analysis,
        AnalysisState::Ready { .. }
    ) {
        assert!(Instant::now() < deadline);
        runtime.poll_timers(25, NOW + 5);
        thread::sleep(Duration::from_millis(5));
    }
    asr_handle.join().unwrap();
    chat_handle.join().unwrap();
    let trashed_after = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": cloud_id}),
        NOW + 6,
    );
    assert!(trashed_after["trashRecords"]
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["id"] == cloud_id));
}

#[test]
fn permanent_purge_empty_trash_and_30_day_expiry_unlink_assets_and_survive_reopen() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let mic = dispatch_ok(
        &mut runtime,
        json!({"type": "start_microphone", "inputId": "built-in", "includeSystem": true}),
        NOW,
    )["microphone"]
        .clone();
    let r1 = mic["recordId"].as_str().unwrap().to_owned();
    let s1 = mic["sessionId"].as_str().unwrap().to_owned();
    for lane in ["microphone", "system"] {
        dispatch_ok(
            &mut runtime,
            json!({"type": "microphone_started", "recordId": r1, "sessionId": s1, "lane": lane, "sampleRate": 16000}),
            NOW,
        );
    }
    for lane in ["microphone", "system"] {
        dispatch_ok(
            &mut runtime,
            json!({"type": "microphone_chunk", "recordId": r1, "sessionId": s1, "lane": lane, "sequence": 0, "samples": vec![9; 320]}),
            NOW,
        );
    }
    for lane in ["microphone", "system"] {
        dispatch_ok(
            &mut runtime,
            json!({"type": "microphone_stopped", "recordId": r1, "sessionId": s1, "lane": lane, "sequence": 1}),
            NOW,
        );
    }
    let r1_wav = dir.0.join("audio").join(format!("{r1}.wav"));
    let r1_sys_wav = dir.0.join("audio").join(format!("{r1}-system.wav"));
    let r1_opus = dir.0.join("audio").join(format!("{r1}.opus"));
    fs::write(&r1_opus, b"OggS-test-opus").unwrap();
    assert!(r1_wav.exists() && r1_sys_wav.exists() && r1_opus.exists());

    let r2 = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "保留记录", "text": "周二发布桌面客户端。"}),
        NOW + 1,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let r2_wav = recording_assets::save_audio(
        &dir.0,
        &r2,
        &write_wav(&dir.external("r2-src.wav"), 3),
    )
    .unwrap();
    dispatch_ok(
        &mut runtime,
        json!({"type": "create_task", "recordId": r2, "segmentId": "S1"}),
        NOW + 1,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "ask", "question": "桌面客户端", "scope": "all", "recordId": null}),
        NOW + 1,
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": r1}),
        NOW + 2,
    );
    assert!(r1_wav.exists() && r1_sys_wav.exists() && r1_opus.exists());

    dispatch_ok(
        &mut runtime,
        json!({"type": "purge_record", "recordId": r1}),
        NOW + 2,
    );
    assert!(!r1_wav.exists() && !r1_sys_wav.exists() && !r1_opus.exists());
    assert!(r2_wav.exists());

    drop(runtime);
    let mut runtime = dir.open();

    let r3 = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "即将过期", "text": "三十天后自动清理。"}),
        NOW + 3,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let r3_opus = dir.0.join("audio").join(format!("{r3}.opus"));
    fs::write(&r3_opus, b"OggS-r3").unwrap();

    let r_later = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "稍后过期", "text": "晚一百秒移入回收站。"}),
        NOW + 4,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let r_later_wav = recording_assets::save_audio(
        &dir.0,
        &r_later,
        &write_wav(&dir.external("rl-src.wav"), 7),
    )
    .unwrap();

    let past_sec = 1_700_000_010u64;
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": r2}),
        past_sec,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": r3}),
        past_sec,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": r_later}),
        past_sec + 100,
    );

    let stray_orphan = dir.0.join("audio").join("stray-orphan.wav");
    fs::write(&stray_orphan, b"orphan").unwrap();
    drop(runtime);

    let mut runtime = dir.open();
    assert!(!stray_orphan.exists());
    assert_eq!(
        runtime.snapshot(past_sec + 100)["trashRecords"]
            .as_array()
            .unwrap()
            .len(),
        3
    );

    let before_expiry = past_sec + 30 * 86_400 - 1;
    runtime.poll_timers(250, before_expiry);
    let snap_before = runtime.snapshot(before_expiry);
    assert_eq!(snap_before["trashRecords"].as_array().unwrap().len(), 3);
    assert!(r2_wav.exists() && r3_opus.exists() && r_later_wav.exists());

    let at_expiry = past_sec + 30 * 86_400;
    let gen_pre_exp = runtime.generation();
    runtime.poll_timers(250, at_expiry);
    assert!(runtime.generation() > gen_pre_exp);
    let snap_after = runtime.snapshot(at_expiry);
    assert_eq!(snap_after["trashRecords"].as_array().unwrap().len(), 1);
    assert_eq!(snap_after["trashRecords"][0]["id"], r_later);
    assert!(!r2_wav.exists() && !r3_opus.exists());
    assert!(r_later_wav.exists());

    let emptied = dispatch_ok(&mut runtime, json!({"type": "empty_trash"}), at_expiry);
    assert_eq!(emptied["trashRecords"], json!([]));
    assert!(!r_later_wav.exists());

    drop(runtime);
    let reopened = dir.open();
    assert_eq!(reopened.snapshot(at_expiry)["records"], json!([]));
    assert_eq!(reopened.snapshot(at_expiry)["trashRecords"], json!([]));
    assert!(!reopened.workspace().ask_session().messages.is_empty());
}

#[test]
fn bean_tombstone_anti_resurrection_opus_custody_and_reimport_restore() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    connect_bean(&mut runtime, "c1", NOW);
    runtime.ingest_ble_chunk(&catalog_1b0e_rx(501, 40, NOW as u32), NOW);
    let pull_tx = runtime.drain_outbound_ble_frames();
    assert!(pull_tx.iter().any(|f| f.len() >= 7 && f[5] == 0x1a && f[6] == 0x07));

    runtime.ingest_ble_chunk(&unencrypted_file_head_rx(501, 332), NOW);
    runtime.ingest_ble_chunk(&slices_rx(0..2), NOW);
    runtime.ingest_ble_chunk(&rx_frame(0x1a, 0x0a, &501u32.to_le_bytes()), NOW);

    let bean_id = runtime.snapshot(NOW)["records"][0]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    let bean_wav = recording_assets::audio_path(&dir.0, &bean_id).unwrap();
    let bean_opus = dir.0.join("audio").join(format!("{bean_id}.opus"));
    assert!(bean_wav.exists() && bean_opus.exists());

    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": bean_id}),
        NOW + 1,
    );
    fs::remove_file(&bean_wav).unwrap();
    assert!(bean_opus.exists());

    drop(runtime);
    let mut runtime = dir.open();
    connect_bean(&mut runtime, "c2", NOW + 2);
    runtime.ingest_ble_chunk(&catalog_1b0e_rx(501, 40, NOW as u32), NOW + 2);
    runtime.poll_timers(250, NOW + 2);
    assert!(
        !runtime
            .drain_outbound_ble_frames()
            .iter()
            .any(|f| f.len() >= 7 && f[5] == 0x1a && f[6] == 0x07),
        "soft-deleted Bean record with .opus on disk must not auto-pull"
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "purge_record", "recordId": bean_id}),
        NOW + 3,
    );
    assert!(!bean_opus.exists());
    assert!(runtime.workspace().is_bean_file_purged(501));

    drop(runtime);
    let mut runtime = dir.open();
    assert!(runtime.workspace().is_bean_file_purged(501));
    connect_bean(&mut runtime, "c3", NOW + 4);
    runtime.ingest_ble_chunk(&catalog_1b0e_rx(501, 40, NOW as u32), NOW + 4);
    runtime.poll_timers(250, NOW + 4);
    assert!(
        !runtime
            .drain_outbound_ble_frames()
            .iter()
            .any(|f| f.len() >= 7 && f[5] == 0x1a && f[6] == 0x07),
        "purged Bean file_id tombstone must block auto-pull across reconnect and reopen"
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "device_download", "fileId": 501}),
        NOW + 5,
    );
    assert!(!runtime.workspace().is_bean_file_purged(501));
    assert!(runtime
        .drain_outbound_ble_frames()
        .iter()
        .any(|f| f.len() >= 7 && f[5] == 0x1a && f[6] == 0x07));

    runtime.ingest_ble_chunk(&unencrypted_file_head_rx(501, 332), NOW + 5);
    runtime.ingest_ble_chunk(&slices_rx(0..2), NOW + 5);
    runtime.ingest_ble_chunk(&rx_frame(0x1a, 0x0a, &501u32.to_le_bytes()), NOW + 5);
    assert_eq!(runtime.snapshot(NOW + 5)["records"][0]["id"], bean_id);
    assert!(bean_wav.exists() && bean_opus.exists());

    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": bean_id}),
        NOW + 6,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "device_download", "fileId": 501}),
        NOW + 6,
    );
    runtime.drain_outbound_ble_frames();
    runtime.ingest_ble_chunk(&unencrypted_file_head_rx(501, 332), NOW + 6);
    runtime.ingest_ble_chunk(&slices_rx(0..2), NOW + 6);
    runtime.ingest_ble_chunk(&rx_frame(0x1a, 0x0a, &501u32.to_le_bytes()), NOW + 6);
    let redownloaded = runtime.snapshot(NOW + 6);
    assert_eq!(redownloaded["trashRecords"], json!([]));
    assert_eq!(redownloaded["records"][0]["id"], bean_id);
    assert!(redownloaded["undoTrash"].is_null());

    let ext_wav = dir.external("external.wav");
    write_wav(&ext_wav, 21);
    let imp_snap = dispatch_ok(
        &mut runtime,
        json!({"type": "import_file", "path": ext_wav}),
        NOW + 7,
    );
    let imp_id = imp_snap["selectedRecordId"].as_str().unwrap().to_owned();
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": imp_id}),
        NOW + 8,
    );
    assert_eq!(runtime.snapshot(NOW + 8)["undoTrash"]["recordId"], imp_id);

    let reimported = dispatch_ok(
        &mut runtime,
        json!({"type": "import_file", "path": ext_wav}),
        NOW + 9,
    );
    assert_eq!(reimported["section"], "detail");
    assert_eq!(reimported["detail"]["id"], imp_id);
    assert!(reimported["undoTrash"].is_null());
    assert_eq!(reimported["trashRecords"], json!([]));
}

#[test]
fn late_cloud_completion_after_policy_cancel_and_purge_converges_quit_to_ready() {
    let dir = Sandbox::new();
    let wav_file = dir.external("late.wav");
    write_wav(&wav_file, 15);

    let mut runtime = dir.open();
    let id = dispatch_ok(
        &mut runtime,
        json!({"type": "import_file", "path": wav_file}),
        NOW,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();

    let (asr_url, wait_audio, release_finals, server) = gated_asr_server();
    dispatch_ok(
        &mut runtime,
        json!({
            "type": "configure_provider",
            "apiKey": TEST_KEY,
            "model": "qwen-plus",
            "asrEndpoint": asr_url
        }),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "configure_speech", "engine": "cloud"}),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "transcribe", "recordId": id}),
        NOW,
    );
    wait_audio.recv_timeout(Duration::from_secs(5)).unwrap();

    dispatch_ok(
        &mut runtime,
        json!({"type": "set_meeting_audio_policy", "policy": "local_only"}),
        NOW + 1,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": id}),
        NOW + 1,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "purge_record", "recordId": id}),
        NOW + 1,
    );
    let _ = release_finals.send(());
    server.join().unwrap();

    runtime.poll_timers(100, NOW + 2);
    let quit_snap = dispatch_ok(&mut runtime, json!({"type": "request_quit"}), NOW + 2);
    assert_eq!(quit_snap["lifecycle"]["quitPhase"], "ready");
    assert_eq!(quit_snap["lifecycle"]["keepAwake"], false);
}

#[test]
fn trashing_record_after_returning_to_today_leaves_no_noop_back_stack_entries() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let rec_a = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "会议 A", "text": "第一条讨论内容。"}),
        NOW,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let at_today = dispatch_ok(&mut runtime, json!({"type": "back"}), NOW);
    assert_eq!(at_today["section"], "today");
    assert_eq!(at_today["canGoBack"], false);

    dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": rec_a}),
        NOW,
    );
    let back_to_today = dispatch_ok(
        &mut runtime,
        json!({"type": "navigate", "section": "today"}),
        NOW,
    );
    assert_eq!(back_to_today["section"], "today");
    assert_eq!(back_to_today["canGoBack"], true);

    let trashed = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": rec_a}),
        NOW,
    );
    assert_eq!(trashed["section"], "today");
    assert!(trashed["selectedRecordId"].is_null());
    assert_eq!(trashed["canGoBack"], false);

    let rec_b = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "会议 B", "text": "第二条讨论内容。"}),
        NOW + 1,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    dispatch_ok(&mut runtime, json!({"type": "back"}), NOW + 1);
    let rec_c = dispatch_ok(
        &mut runtime,
        json!({"type": "create_note", "title": "会议 C", "text": "第三条讨论内容。"}),
        NOW + 2,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    dispatch_ok(&mut runtime, json!({"type": "back"}), NOW + 2);
    assert_eq!(runtime.snapshot(NOW + 2)["canGoBack"], false);

    dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": rec_b}),
        NOW + 2,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "navigate", "section": "today"}),
        NOW + 2,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "select_record", "recordId": rec_c}),
        NOW + 2,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "navigate", "section": "today"}),
        NOW + 2,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": rec_b}),
        NOW + 2,
    );
    let after_both = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": rec_c}),
        NOW + 2,
    );
    assert_eq!(after_both["section"], "today");
    assert_eq!(after_both["canGoBack"], false);
}

#[cfg(unix)]
#[test]
fn purge_with_unwritable_audio_dir_commits_metadata_reports_deferred_cleanup_and_reopen_unlinks() {
    use std::os::unix::fs::PermissionsExt;

    struct DirPermGuard(PathBuf);
    impl Drop for DirPermGuard {
        fn drop(&mut self) {
            let _ = fs::set_permissions(&self.0, fs::Permissions::from_mode(0o755));
        }
    }

    let dir = Sandbox::new();
    let wav_file = dir.external("deferred-unlink.wav");
    write_wav(&wav_file, 19);

    let mut runtime = dir.open();
    let rec_id = dispatch_ok(
        &mut runtime,
        json!({"type": "import_file", "path": wav_file}),
        NOW,
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .to_owned();
    let owned_wav = recording_assets::audio_path(&dir.0, &rec_id).unwrap();
    assert!(owned_wav.exists());

    dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": rec_id}),
        NOW + 1,
    );

    let audio_dir = dir.0.join("audio");
    let _guard = DirPermGuard(audio_dir.clone());
    fs::set_permissions(&audio_dir, fs::Permissions::from_mode(0o555)).unwrap();
    let probe = audio_dir.join(".root-probe");
    if fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .is_ok()
    {
        let _ = fs::remove_file(&probe);
        return;
    }

    let gen_before = runtime.generation();
    let purged = dispatch_raw(
        &mut runtime,
        json!({"type": "purge_record", "recordId": rec_id}),
        NOW + 2,
    );
    assert!(runtime.generation() > gen_before);
    assert_eq!(purged["records"], json!([]));
    assert_eq!(purged["trashRecords"], json!([]));
    assert!(owned_wav.exists());
    let err_msg = purged["error"]
        .as_str()
        .expect("post-commit unlink failure must surface in snapshot error");
    assert!(
        err_msg.contains("记录已移除，音频文件稍后自动重试清理"),
        "unexpected error message: {err_msg}"
    );

    fs::set_permissions(&audio_dir, fs::Permissions::from_mode(0o755)).unwrap();
    drop(runtime);

    let reopened = dir.open();
    assert_eq!(reopened.snapshot(NOW + 3)["records"], json!([]));
    assert_eq!(reopened.snapshot(NOW + 3)["trashRecords"], json!([]));
    assert!(!owned_wav.exists());
}

#[test]
fn trashing_ended_meeting_or_idle_all_day_clears_zombie_live_minutes_scope() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let started = dispatch_ok(
        &mut runtime,
        json!({"type": "start_capture_mode", "mode": "meeting", "stayOnPage": true}),
        NOW,
    );
    let mic = &started["microphone"];
    let meeting_id = mic["recordId"].as_str().unwrap().to_owned();
    let meeting_session = mic["sessionId"].as_str().unwrap().to_owned();
    dispatch_ok(
        &mut runtime,
        json!({"type": "microphone_started", "recordId": meeting_id, "sessionId": meeting_session, "lane": "microphone", "sampleRate": 16000}),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "microphone_chunk", "recordId": meeting_id, "sessionId": meeting_session, "lane": "microphone", "sequence": 0, "samples": vec![42; 320]}),
        NOW,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "capture_action", "action": "end"}),
        NOW + 1,
    );
    let ended = dispatch_ok(
        &mut runtime,
        json!({"type": "microphone_stopped", "recordId": meeting_id, "sessionId": meeting_session, "lane": "microphone", "sequence": 1, "epoch": 0}),
        NOW + 1,
    );
    assert_eq!(
        ended["liveMinutes"]["scope"],
        json!({"kind": "record", "id": meeting_id})
    );
    assert_eq!(ended["liveMinutes"]["phase"], "ended");

    let trashed = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": meeting_id}),
        NOW + 2,
    );
    assert!(
        trashed["liveMinutes"].is_null(),
        "trashing ended meeting record must clear liveMinutes scope, got: {}",
        trashed["liveMinutes"]
    );

    let ad_started = dispatch_ok(
        &mut runtime,
        json!({"type": "start_capture_mode", "mode": "all_day", "stayOnPage": true}),
        NOW + 3,
    );
    let ad_mic = &ad_started["microphone"];
    let ad_id = ad_mic["recordId"].as_str().unwrap().to_owned();
    let ad_session = ad_mic["sessionId"].as_str().unwrap().to_owned();
    let run_id = ad_started["liveMinutes"]["scope"]["id"]
        .as_str()
        .unwrap()
        .to_owned();
    dispatch_ok(
        &mut runtime,
        json!({"type": "microphone_started", "recordId": ad_id, "sessionId": ad_session, "lane": "microphone", "sampleRate": 16000}),
        NOW + 3,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "microphone_chunk", "recordId": ad_id, "sessionId": ad_session, "lane": "microphone", "sequence": 0, "samples": vec![42; 320]}),
        NOW + 3,
    );
    dispatch_ok(
        &mut runtime,
        json!({"type": "capture_action", "action": "end"}),
        NOW + 4,
    );
    let ad_ended = dispatch_ok(
        &mut runtime,
        json!({"type": "microphone_stopped", "recordId": ad_id, "sessionId": ad_session, "lane": "microphone", "sequence": 1, "epoch": 0}),
        NOW + 4,
    );
    assert_eq!(
        ad_ended["liveMinutes"]["scope"],
        json!({"kind": "all_day", "id": run_id})
    );
    assert_eq!(ad_ended["liveMinutes"]["phase"], "ended");

    let ad_trashed = dispatch_ok(
        &mut runtime,
        json!({"type": "trash_record", "recordId": ad_id}),
        NOW + 5,
    );
    assert!(
        ad_trashed["liveMinutes"].is_null(),
        "trashing last live record of an idle all-day run must clear liveMinutes scope, got: {}",
        ad_trashed["liveMinutes"]
    );
}

#[test]
fn cancelled_microphone_meeting_capture_detaches_live_minutes_scope_and_selection() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();

    let started = dispatch_ok(
        &mut runtime,
        json!({"type": "start_capture_mode", "mode": "meeting", "stayOnPage": true}),
        NOW,
    );
    let mic = &started["microphone"];
    let meeting_id = mic["recordId"].as_str().unwrap().to_owned();
    let meeting_session = mic["sessionId"].as_str().unwrap().to_owned();
    assert_eq!(
        started["liveMinutes"]["scope"],
        json!({"kind": "record", "id": meeting_id})
    );
    assert_eq!(
        started["workspaces"]["liveMinutes"]["selectedRecordId"],
        json!(meeting_id)
    );

    dispatch_ok(
        &mut runtime,
        json!({"type": "capture_action", "action": "cancel"}),
        NOW + 1,
    );
    let cancelled = dispatch_ok(
        &mut runtime,
        json!({
            "type": "microphone_stopped",
            "recordId": meeting_id,
            "sessionId": meeting_session,
            "lane": "microphone",
            "sequence": 0,
            "epoch": 0
        }),
        NOW + 1,
    );
    assert!(
        cancelled["liveMinutes"].is_null(),
        "cancelling microphone meeting capture must detach liveMinutes scope, got: {}",
        cancelled["liveMinutes"]
    );
    assert!(
        cancelled["workspaces"]["liveMinutes"]["selectedRecordId"].is_null(),
        "cancelling microphone meeting capture must clear selectedRecordId, got: {}",
        cancelled["workspaces"]["liveMinutes"]["selectedRecordId"]
    );
}
