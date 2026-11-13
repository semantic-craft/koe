use super::*;
use std::fs;
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use koe_engine::frame::{ProtocolFrame, RX_MAGIC};
use koe_engine::models::OfflineFileEntry;
use koe_engine::session::REAL_OPUS_20MS_440HZ_PACKET;
use koe_engine::transport::OPUS_FRAME_BYTES;
use serde_json::json;
use tokio_tungstenite::tungstenite::{Message, accept};

const NOW: u64 = 1_800_000_000;
const FIRST: &str = "The first live sentence.";
const REVISED: &str = "The corrected live sentence.";

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-capture-{}-{}",
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

fn command(runtime: &mut KoeRuntime, value: Value) -> Value {
    if value["type"] == "configure_provider" {
        runtime.dispatch_json(r#"{"type":"configure_speech","engine":"cloud"}"#, NOW);
        runtime.dispatch_json(
            r#"{"type":"set_meeting_audio_policy","policy":"cloud_allowed"}"#,
            NOW,
        );
    }
    let value: Value =
        serde_json::from_str(&runtime.dispatch_json(&value.to_string(), NOW)).unwrap();
    assert!(value["error"].is_null(), "{}", value["error"]);
    value
}

fn poll_until(runtime: &mut KoeRuntime, done: impl Fn(&KoeRuntime) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        runtime.poll_timers(0, NOW);
        let snapshot = runtime.snapshot(NOW);
        assert!(snapshot["error"].is_null(), "{}", snapshot["error"]);
        if done(runtime) {
            return;
        }
        assert!(
            Instant::now() < deadline,
            "capture did not finish: {snapshot}"
        );
        thread::sleep(Duration::from_millis(5));
    }
}

fn rx(command: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = RX_MAGIC.to_vec();
    frame.extend_from_slice(&[1, 0x1a, command]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(ProtocolFrame::checksum(&frame));
    frame
}

fn slices(sequences: std::ops::Range<u32>) -> Vec<u8> {
    let mut payload = Vec::new();
    for sequence in sequences {
        payload.extend_from_slice(&sequence.to_le_bytes());
        payload.push(0);
        let mut opus = [0; OPUS_FRAME_BYTES];
        opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        payload.extend_from_slice(&opus);
        payload.push(0);
    }
    rx(0x08, &payload)
}

fn prepare_capture(runtime: &mut KoeRuntime, file_id: u32, realtime: bool) {
    // Fixture starts after authentication/header exchange; all audio uses the public ingest path.
    runtime.device.session.active_file_id = Some(file_id);
    runtime.device.session.active_is_realtime = realtime;
}

fn final_event(task_id: &str, text: &str) -> Message {
    Message::Text(
        json!({"header":{"event":"result-generated","task_id":task_id},
            "payload":{"output":{"sentence":{"sentence_id":7,"sentence_end":true,
                "begin_time":0,"end_time":40,"text":text}}}})
        .to_string()
        .into(),
    )
}

fn accept_before_deadline(listener: &TcpListener) -> TcpStream {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match listener.accept() {
            Ok((stream, _)) => return stream,
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(Instant::now() < deadline, "live ASR never connected");
                thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("cannot accept live ASR: {error}"),
        }
    }
}

fn live_server() -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let server = thread::spawn(move || {
        let stream = accept_before_deadline(&listener);
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut socket = accept(stream).unwrap();
        let run: Value = serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(run["header"]["action"], "run-task");
        assert_eq!(run["payload"]["parameters"]["sample_rate"], 16000);
        let task = run["header"]["task_id"].as_str().unwrap();
        socket
            .send(Message::Text(
                json!({"header":{"event":"task-started","task_id":task},"payload":{}})
                    .to_string()
                    .into(),
            ))
            .unwrap();
        for (index, text) in [FIRST, REVISED].into_iter().enumerate() {
            let Message::Binary(pcm) = socket.read().unwrap() else {
                panic!("finish arrived before both live chunks");
            };
            assert_eq!(
                pcm.len(),
                640,
                "one Opus packet must decode to 20ms mono PCM"
            );
            assert!(pcm.iter().any(|byte| *byte != 0));
            if index == 0 {
                let sample = i16::from_le_bytes([pcm[260], pcm[261]]);
                assert!(
                    (i32::from(sample) + 4130).abs() <= 16,
                    "unexpected decoded sample {sample}"
                );
            }
            socket.send(final_event(task, text)).unwrap();
        }
        let finish: Value =
            serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(finish["header"]["action"], "finish-task");
        assert_eq!(finish["header"]["task_id"], task);
        socket
            .send(Message::Text(
                json!({"header":{"event":"task-finished","task_id":task},"payload":{}})
                    .to_string()
                    .into(),
            ))
            .unwrap();
    });
    (endpoint, server)
}

#[test]
fn live_words_are_durable_before_stop_and_keep_their_owner_after_selection_changes() {
    let dir = Sandbox::new();
    let (endpoint, server) = live_server();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"local-capture-fixture","model":"fixture","asrEndpoint":endpoint}),
    );
    prepare_capture(&mut runtime, 701, true);
    runtime.ingest_ble_chunk(&slices(0..1), NOW);
    poll_until(&mut runtime, |runtime| {
        runtime
            .workspace()
            .records()
            .values()
            .any(|record| !record.aggregate.spine.is_empty())
    });
    let id = runtime.workspace().records().keys().next().unwrap().clone();
    let before_stop = command(&mut runtime, json!({"type":"select_record","recordId":id}));
    assert_eq!(before_stop["detail"]["segments"][0]["text"], FIRST);
    assert_eq!(before_stop["liveCaption"]["recordId"], id);
    assert_eq!(before_stop["liveCaption"]["text"], FIRST);
    assert_eq!(before_stop["device"]["busy"], true);
    assert!(before_stop["detail"]["audioPath"].is_null());
    assert!(
        fs::read_to_string(dir.0.join("product-workspace.json"))
            .unwrap()
            .contains(FIRST)
    );

    let other = command(
        &mut runtime,
        json!({"type":"create_note","title":"Other record","text":"Unrelated violet calendar."}),
    );
    let other_id = other["selectedRecordId"].as_str().unwrap().to_owned();
    runtime.ingest_ble_chunk(&slices(1..2), NOW);
    poll_until(&mut runtime, |runtime| {
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text
            == REVISED
    });
    let corrected = runtime.workspace().record(&id).unwrap();
    assert_eq!(
        corrected.aggregate.spine.len(),
        1,
        "same provider sequence must revise its segment"
    );
    assert_eq!(corrected.aggregate.spine.segments()[0].id.to_string(), "S1");
    assert_eq!(runtime.snapshot(NOW)["selectedRecordId"], other_id);
    assert_eq!(runtime.snapshot(NOW)["liveCaption"]["recordId"], id);
    assert_eq!(runtime.snapshot(NOW)["liveCaption"]["text"], REVISED);
    assert_eq!(
        runtime
            .workspace()
            .record(&other_id)
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "Unrelated violet calendar."
    );

    // Disable subsequent paid analysis; the already-owned live session still completes.
    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"","model":"fixture"}),
    );
    command(&mut runtime, json!({"type":"device_stop"}));
    runtime.poll_timers(2_000, NOW + 2);
    poll_until(&mut runtime, |runtime| {
        recording_assets::audio_path(&dir.0, &id).unwrap().exists()
            && !matches!(
                runtime.workspace().record(&id).unwrap().analysis,
                AnalysisState::Pending { .. }
            )
    });
    server.join().unwrap();
    assert_eq!(
        runtime.workspace().records().len(),
        2,
        "finishing must reuse the live record"
    );
    assert_eq!(runtime.snapshot(NOW)["selectedRecordId"], other_id);
    let audio = fs::read(recording_assets::audio_path(&dir.0, &id).unwrap()).unwrap();
    let wav = koe_engine::wav::parse_pcm_wave(&audio).unwrap();
    assert_eq!(wav.sample_rate, 48_000);
    assert_eq!(wav.samples.len(), 2 * 960 * 2);
    assert!(runtime.device.session.has_disk_custody(701));
    drop(runtime);

    let mut reopened = KoeRuntime::open(&dir.0).unwrap();
    let detail = command(&mut reopened, json!({"type":"select_record","recordId":id}));
    assert_eq!(detail["detail"]["segments"][0]["text"], REVISED);
    assert_eq!(detail["detail"]["segments"].as_array().unwrap().len(), 1);
    assert!(detail["detail"]["audioPath"].is_string());
}

#[test]
fn busy_device_rejects_start_and_download_without_discarding_captured_audio() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime.device.session.set_session_key([0x55; 32]);
    runtime.device.session.catalog.push(OfflineFileEntry {
        file_id: 999,
        duration_ms: 400,
        end_time: Some(1),
    });
    prepare_capture(&mut runtime, 702, true);
    runtime.ingest_ble_chunk(&slices(0..1), NOW);
    let original = runtime.device.session.opus_buffer.clone();
    runtime.drain_outbound_ble_frames();
    for request in [
        json!({"type":"device_start"}),
        json!({"type":"device_download","fileId":999}),
    ] {
        let snapshot: Value =
            serde_json::from_str(&runtime.dispatch_json(&request.to_string(), NOW)).unwrap();
        assert!(snapshot["error"].as_str().unwrap().contains("等待"));
        assert_eq!(runtime.device.session.opus_buffer, original);
        assert_eq!(runtime.device.session.active_file_id, Some(702));
        assert!(runtime.drain_outbound_ble_frames().is_empty());
    }
    runtime.ingest_ble_chunk(&rx(0x0a, &702u32.to_le_bytes()), NOW);
    let id = runtime.workspace().records().keys().next().unwrap();
    assert!(recording_assets::audio_path(&dir.0, id).unwrap().exists());
    assert!(runtime.device.session.has_disk_custody(702));
}

#[test]
fn reused_bean_file_id_with_changed_content_preserves_both_recordings() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    prepare_capture(&mut runtime, 703, false);
    runtime.ingest_ble_chunk(&slices(0..1), NOW);
    runtime.ingest_ble_chunk(&rx(0x0a, &703u32.to_le_bytes()), NOW);
    let first_id = runtime.workspace().records().keys().next().unwrap().clone();
    let first_path = recording_assets::audio_path(&dir.0, &first_id).unwrap();
    let original = fs::read(&first_path).unwrap();
    prepare_capture(&mut runtime, 703, false);
    runtime.ingest_ble_chunk(&slices(0..2), NOW + 1);
    runtime.ingest_ble_chunk(&rx(0x0a, &703u32.to_le_bytes()), NOW + 1);
    assert!(runtime.snapshot(NOW)["error"].is_null());
    assert_eq!(runtime.workspace().records().len(), 2);
    assert_eq!(fs::read(first_path).unwrap(), original);
    let second_id = runtime
        .workspace()
        .records()
        .keys()
        .find(|id| **id != first_id)
        .unwrap();
    let second = fs::read(recording_assets::audio_path(&dir.0, second_id).unwrap()).unwrap();
    assert_eq!(
        koe_engine::wav::parse_pcm_wave(&original)
            .unwrap()
            .samples
            .len(),
        960 * 2
    );
    assert_eq!(
        koe_engine::wav::parse_pcm_wave(&second)
            .unwrap()
            .samples
            .len(),
        2 * 960 * 2
    );
}

#[test]
fn recovering_disk_write_during_idle_poll_publishes_a_new_generation() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    fs::write(dir.0.join("audio"), b"block audio directory creation").unwrap();
    prepare_capture(&mut runtime, 704, false);
    runtime.ingest_ble_chunk(&slices(0..1), NOW);
    runtime.ingest_ble_chunk(&rx(0x0a, &704u32.to_le_bytes()), NOW);
    assert!(runtime.snapshot(NOW)["error"].is_string());
    assert!(runtime.workspace().records().is_empty());
    assert!(!runtime.device.session.has_disk_custody(704));
    let generation = runtime.generation();
    fs::remove_file(dir.0.join("audio")).unwrap();
    runtime.poll_timers(0, NOW);
    assert!(runtime.snapshot(NOW)["error"].is_null());
    assert!(runtime.generation() > generation);
    assert_eq!(runtime.workspace().records().len(), 1);
    let id = runtime.workspace().records().keys().next().unwrap();
    assert!(recording_assets::audio_path(&dir.0, id).unwrap().exists());
    assert!(runtime.device.session.has_disk_custody(704));
    drop(runtime);
    assert_eq!(
        KoeRuntime::open(&dir.0)
            .unwrap()
            .workspace()
            .records()
            .len(),
        1
    );
}

fn rx_cmd(group: u8, command: u8, payload: &[u8]) -> Vec<u8> {
    let mut frame = RX_MAGIC.to_vec();
    frame.extend_from_slice(&[1, group, command]);
    frame.extend_from_slice(&u16::try_from(payload.len() + 10).unwrap().to_le_bytes());
    frame.extend_from_slice(payload);
    frame.push(ProtocolFrame::checksum(&frame));
    frame
}

fn file_head_rx(file_id: u32, file_size: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(87);
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&file_size.to_le_bytes());
    payload.extend_from_slice(&[0u8; 78]);
    payload.push(0);
    rx_cmd(0x1a, 0x07, &payload)
}

fn catalog_1b0e_rx(file_id: u32, duration_ms: u32, end_time: u32) -> Vec<u8> {
    let mut payload = Vec::with_capacity(14);
    payload.extend_from_slice(&1u16.to_le_bytes());
    payload.extend_from_slice(&file_id.to_le_bytes());
    payload.extend_from_slice(&duration_ms.to_le_bytes());
    payload.extend_from_slice(&end_time.to_le_bytes());
    rx_cmd(0x1b, 0x0e, &payload)
}

#[test]
fn live_head_with_zero_size_creates_record_immediately_and_hardware_stop_finalizes_audio() {
    let dir = Sandbox::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let server = thread::spawn(move || {
        let stream = accept_before_deadline(&listener);
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut socket = accept(stream).unwrap();
        let run: Value = serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
        let task = run["header"]["task_id"].as_str().unwrap();
        socket
            .send(Message::Text(
                json!({"header":{"event":"task-started","task_id":task},"payload":{}})
                    .to_string()
                    .into(),
            ))
            .unwrap();
        let Message::Binary(_) = socket.read().unwrap() else {
            panic!("expected first live PCM chunk");
        };
        socket
            .send(Message::Text(
                json!({"header":{"event":"result-generated","task_id":task},
                    "payload":{"output":{"sentence":{"sentence_id":1,"sentence_end":false,
                        "begin_time":0,"end_time":20,"text":FIRST}}}})
                .to_string()
                .into(),
            ))
            .unwrap();
        let Message::Binary(_) = socket.read().unwrap() else {
            panic!("expected second live PCM chunk");
        };
        socket
            .send(Message::Text(
                json!({"header":{"event":"result-generated","task_id":task},
                    "payload":{"output":{"sentence":{"sentence_id":1,"sentence_end":true,
                        "begin_time":0,"end_time":40,"text":REVISED}}}})
                .to_string()
                .into(),
            ))
            .unwrap();
        let finish: Value =
            serde_json::from_str(socket.read().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(finish["header"]["action"], "finish-task");
        socket
            .send(Message::Text(
                json!({"header":{"event":"task-finished","task_id":task},"payload":{}})
                    .to_string()
                    .into(),
            ))
            .unwrap();
    });

    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    runtime.device.session.set_session_key([0x55; 32]);
    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"local-capture-fixture","model":"fixture","asrEndpoint":endpoint}),
    );
    command(&mut runtime, json!({"type":"device_start"}));
    runtime.drain_outbound_ble_frames();

    runtime.ingest_ble_chunk(&file_head_rx(801, 0), NOW);
    let snap_after_head = runtime.snapshot(NOW);
    assert_eq!(snap_after_head["records"].as_array().unwrap().len(), 1);
    let live_id = snap_after_head["device"]["liveRecordId"]
        .as_str()
        .expect("liveRecordId must be populated immediately on 1A/07 head")
        .to_owned();
    assert_eq!(
        snap_after_head["device"]["transferPhase"],
        "streaming_realtime"
    );

    runtime.ingest_ble_chunk(&slices(0..1), NOW);
    poll_until(&mut runtime, |runtime| {
        runtime
            .workspace()
            .record(&live_id)
            .is_some_and(|r| !r.aggregate.spine.is_empty())
    });
    let snap_interim = runtime.snapshot(NOW);
    assert_eq!(snap_interim["records"][0]["preview"], FIRST);
    assert!(snap_interim["device"]["liveDurationMs"].as_u64().unwrap() >= 20);

    runtime.ingest_ble_chunk(&slices(1..2), NOW);
    poll_until(&mut runtime, |runtime| {
        runtime
            .workspace()
            .record(&live_id)
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text
            == REVISED
    });
    let seg = &runtime
        .workspace()
        .record(&live_id)
        .unwrap()
        .aggregate
        .spine
        .segments()[0];
    assert_eq!(seg.end_ms, 40);

    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"","model":"fixture"}),
    );
    runtime.ingest_ble_chunk(&rx_cmd(0x18, 0x82, &[0x00]), NOW + 1);
    let tx_after_stop = runtime.drain_outbound_ble_frames();
    assert!(
        tx_after_stop
            .iter()
            .any(|f| f.len() >= 7 && f[5] == 0x1b && f[6] == 0x0e),
        "hardware stop must queue 1B/0E catalog refresh"
    );

    runtime.poll_timers(2_000, NOW + 3);
    poll_until(&mut runtime, |_runtime| {
        recording_assets::audio_path(&dir.0, &live_id)
            .unwrap()
            .exists()
    });
    server.join().unwrap();
    assert!(runtime.device.session.has_disk_custody(801));
}

#[test]
fn hardware_stop_with_zero_live_slices_auto_pulls_offline_audio_into_live_record() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"fixture","model":"fixture","asrEndpoint":format!("ws://{}",listener.local_addr().unwrap())}),
    );
    runtime.device.session.set_session_key([0x55; 32]);
    command(&mut runtime, json!({"type":"device_start"}));
    runtime.drain_outbound_ble_frames();

    runtime.ingest_ble_chunk(&file_head_rx(802, 0), NOW);
    assert_eq!(runtime.workspace().records().len(), 1);
    let live_id = runtime.workspace().records().keys().next().unwrap().clone();

    runtime.ingest_ble_chunk(&rx_cmd(0x18, 0x82, &[0x00]), NOW + 1);
    let tx_stop = runtime.drain_outbound_ble_frames();
    assert!(
        tx_stop
            .iter()
            .any(|f| f.len() >= 7 && f[5] == 0x1b && f[6] == 0x0e),
        "hardware stop must request 1B/0E catalog"
    );

    runtime.ingest_ble_chunk(&catalog_1b0e_rx(802, 40, NOW as u32 + 1), NOW + 1);
    runtime.poll_timers(2_000, NOW + 3);
    let tx_auto_pull = runtime.drain_outbound_ble_frames();
    assert!(
        tx_auto_pull
            .iter()
            .any(|f| f.len() >= 7 && f[5] == 0x1a && f[6] == 0x07),
        "receiving un-synced catalog entry after stop must auto-trigger 1A/07 offline pull"
    );

    runtime.ingest_ble_chunk(&file_head_rx(802, 332), NOW + 2);
    runtime.ingest_ble_chunk(&slices(0..2), NOW + 2);
    runtime.ingest_ble_chunk(&rx(0x0a, &802u32.to_le_bytes()), NOW + 2);

    assert_eq!(
        runtime.workspace().records().len(),
        1,
        "offline pull after empty live stream must reuse the live record"
    );
    assert!(
        recording_assets::audio_path(&dir.0, &live_id)
            .unwrap()
            .exists()
    );
    assert!(runtime.device.session.has_disk_custody(802));
    runtime.drive_analysis_queue();
    assert!(
        !runtime.pending.is_empty(),
        "offline audio needs transcription when no live PCM arrived"
    );
    let stream = accept_before_deadline(&listener);
    drop(stream);
}

#[test]
fn local_capture_is_not_uploaded_automatically_when_cloud_is_enabled_before_stop() {
    let dir = Sandbox::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    command(
        &mut runtime,
        json!({"type":"configure_provider","apiKey":"fixture","model":"fixture","asrEndpoint":format!("ws://{}",listener.local_addr().unwrap())}),
    );
    command(
        &mut runtime,
        json!({"type":"set_meeting_audio_policy","policy":"local_only"}),
    );
    prepare_capture(&mut runtime, 703, true);
    runtime.ingest_ble_chunk(&slices(0..2), NOW);
    let id = runtime.workspace().records().keys().next().unwrap().clone();
    command(
        &mut runtime,
        json!({"type":"set_meeting_audio_policy","policy":"cloud_allowed"}),
    );
    command(&mut runtime, json!({"type":"device_stop"}));
    runtime.poll_timers(2_000, NOW + 2);
    poll_until(&mut runtime, |runtime| {
        recording_assets::audio_path(&dir.0, &id).unwrap().exists()
            && runtime.captures.sessions.is_empty()
    });
    assert!(
        runtime.pending.is_empty(),
        "cancelled capture was automatically queued for cloud transcription"
    );
    drop(runtime);
    assert_eq!(
        listener
            .accept()
            .expect_err("local capture was uploaded after enabling cloud")
            .kind(),
        std::io::ErrorKind::WouldBlock
    );
}

fn local_effects(runtime: &mut KoeRuntime) -> Vec<Value> {
    serde_json::from_str(&runtime.drain_local_asr_json()).unwrap()
}

fn start_local(runtime: &mut KoeRuntime, file_id: u32) -> (String, u64) {
    command(
        runtime,
        json!({"type":"configure_speech","engine":"apple_speech"}),
    );
    command(
        runtime,
        json!({"type":"local_asr_readiness","state":"ready","message":"本机识别已就绪"}),
    );
    prepare_capture(runtime, file_id, true);
    runtime.ingest_ble_chunk(&slices(0..1), NOW);
    let id = runtime.workspace().records().keys().last().unwrap().clone();
    let effects = local_effects(runtime);
    assert_eq!(effects[0]["kind"], "start");
    assert_eq!(effects[0]["locale"], "zh-CN");
    assert_eq!(effects[1]["kind"], "audio");
    assert_eq!(effects[1]["pcm16"].as_array().unwrap().len(), 320);
    assert!(
        effects[1]["pcm16"]
            .as_array()
            .unwrap()
            .iter()
            .any(|sample| sample != 0)
    );
    (id, effects[0]["operationId"].as_u64().unwrap())
}

fn local_result(
    runtime: &mut KoeRuntime,
    operation: u64,
    text: &str,
    start: u64,
    final_result: bool,
) -> Value {
    command(
        runtime,
        json!({"type":"local_asr_result","operationId":operation,"text":text,"startMs":start,"endMs":start+20,"isFinal":final_result}),
    )
}

#[test]
fn local_only_words_are_durable_before_hardware_stop() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    command(
        &mut runtime,
        json!({"type":"configure_provider","model":"fixture","asrEndpoint":format!("ws://{}",listener.local_addr().unwrap())}),
    );
    command(
        &mut runtime,
        json!({"type":"set_meeting_audio_policy","policy":"local_only"}),
    );
    let (id, operation) = start_local(&mut runtime, 910);
    command(
        &mut runtime,
        json!({"type":"navigate","section":"settings"}),
    );
    let partial = local_result(&mut runtime, operation, "未定稿", 0, false);
    assert_eq!(partial["liveCaption"]["text"], "未定稿");
    assert!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .is_empty()
    );
    let finalized = local_result(&mut runtime, operation, "离线实时文字。", 0, true);
    assert_eq!(finalized["section"], "settings");
    assert_eq!(finalized["liveCaption"]["recordId"], id);
    assert_eq!(finalized["liveCaption"]["text"], "离线实时文字。");
    assert_eq!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "离线实时文字。"
    );
    assert!(
        fs::read_to_string(dir.0.join("product-workspace.json"))
            .unwrap()
            .contains("离线实时文字。")
    );
    assert!(runtime.device.session.active_file_id.is_some());
    local_result(&mut runtime, operation, "离线实时文字。", 0, true);
    assert_eq!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .len(),
        1
    );
    command(&mut runtime, json!({"type":"navigate","section":"tasks"}));
    runtime.ingest_ble_chunk(&slices(1..2), NOW);
    runtime.ingest_ble_chunk(&rx(0x0a, &910u32.to_le_bytes()), NOW);
    let effects = local_effects(&mut runtime);
    assert_eq!(
        effects
            .iter()
            .map(|e| e["kind"].as_str().unwrap())
            .collect::<Vec<_>>(),
        ["audio", "finish"]
    );
    assert_eq!(runtime.snapshot(NOW)["liveCaption"]["recordId"], id);
    command(&mut runtime, json!({"type":"request_quit"}));
    local_result(&mut runtime, operation, "停录后的尾句。", 20, true);
    command(
        &mut runtime,
        json!({"type":"local_asr_finished","operationId":operation}),
    );
    runtime.poll_timers(0, NOW);
    assert_eq!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .len(),
        2
    );
    assert!(runtime.snapshot(NOW)["liveCaption"].is_null());
    assert!(runtime.auto_summarize.contains(&id));
    assert_eq!(runtime.snapshot(NOW)["lifecycle"]["quitPhase"], "ready");
    command(
        &mut runtime,
        json!({"type":"local_asr_failed","operationId":operation,"message":"过期失败"}),
    );
    assert!(runtime.snapshot(NOW)["error"].is_null());
    assert_eq!(
        listener.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    drop(runtime);
    let reopened = KoeRuntime::open(&dir.0).unwrap();
    assert_eq!(
        reopened
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .segments()[1]
            .text,
        "停录后的尾句。"
    );
    assert!(recording_assets::audio_path(&dir.0, &id).unwrap().exists());
}

#[test]
fn local_final_and_finish_wait_for_storage_and_old_callbacks_cannot_touch_new_capture() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let (id, operation) = start_local(&mut runtime, 920);
    runtime.ingest_ble_chunk(&rx(0x0a, &920u32.to_le_bytes()), NOW);
    let path = dir.0.join("product-workspace.json");
    fs::rename(&path, dir.0.join("original.json")).unwrap();
    fs::create_dir(&path).unwrap();
    runtime.dispatch_json(&json!({"type":"local_asr_result","operationId":operation,"text":"等待保存的尾句。","startMs":0,"endMs":20,"isFinal":true}).to_string(), NOW);
    runtime.dispatch_json(
        &json!({"type":"local_asr_finished","operationId":operation}).to_string(),
        NOW,
    );
    assert!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .is_empty()
    );
    assert_eq!(runtime.snapshot(NOW)["liveCaption"]["recordId"], id);
    fs::remove_dir(&path).unwrap();
    fs::rename(dir.0.join("original.json"), &path).unwrap();
    runtime.poll_timers(0, NOW);
    assert_eq!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "等待保存的尾句。"
    );
    assert!(!matches!(
        runtime.workspace().record(&id).unwrap().analysis,
        AnalysisState::Pending { .. }
    ));
    let (_, new_operation) = start_local(&mut runtime, 921);
    assert_ne!(new_operation, operation);
    local_result(&mut runtime, operation, "旧的文字", 40, true);
    command(
        &mut runtime,
        json!({"type":"local_asr_failed","operationId":operation,"message":"旧的失败"}),
    );
    assert_eq!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .len(),
        1
    );
    assert_eq!(runtime.snapshot(NOW)["liveCaption"]["text"], "");
    local_result(&mut runtime, new_operation, "新的文字", 0, true);
    assert_eq!(runtime.snapshot(NOW)["liveCaption"]["text"], "新的文字");
    command(
        &mut runtime,
        json!({"type":"set_meeting_audio_policy","policy":"local_only"}),
    );
    local_result(&mut runtime, new_operation, "仍在本机识别", 20, true);
    assert_eq!(runtime.snapshot(NOW)["liveCaption"]["text"], "仍在本机识别");
}

#[test]
fn local_audio_overflow_and_finish_timeout_keep_audio_and_confirmed_text() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let (id, operation) = start_local(&mut runtime, 930);
    local_result(&mut runtime, operation, "已识别文字", 0, true);
    for start in (1..1001).step_by(100) {
        runtime.ingest_ble_chunk(&slices(start..start + 100), NOW);
    }
    let batch = local_effects(&mut runtime);
    let bytes: usize = batch
        .iter()
        .filter_map(|effect| effect["pcm16"].as_array())
        .map(|samples| samples.len() * 2)
        .sum();
    assert!(bytes > 0 && bytes <= 256 * 1024);
    for start in (1001..4401).step_by(100) {
        runtime.ingest_ble_chunk(&slices(start..start + 100), NOW);
    }
    runtime.poll_timers(0, NOW);
    assert!(
        matches!(&runtime.workspace().record(&id).unwrap().analysis, AnalysisState::Failed { message, .. } if message.contains("队列已满"))
    );
    let effects = local_effects(&mut runtime);
    assert!(!effects.is_empty());
    assert!(effects.iter().all(|effect| effect["kind"] == "cancel"));
    runtime.ingest_ble_chunk(&rx(0x0a, &930u32.to_le_bytes()), NOW);
    assert!(recording_assets::audio_path(&dir.0, &id).unwrap().exists());
    assert_eq!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .len(),
        1
    );
    runtime.poll_timers(0, NOW);
    let (next_id, next_operation) = start_local(&mut runtime, 931);
    runtime.ingest_ble_chunk(&rx(0x0a, &931u32.to_le_bytes()), NOW);
    local_effects(&mut runtime);
    runtime.poll_timers(15_000, NOW + 15);
    assert!(
        matches!(&runtime.workspace().record(&next_id).unwrap().analysis, AnalysisState::Failed { message, .. } if message.contains("超时"))
    );
    runtime.dispatch_json(&json!({"type":"local_asr_result","operationId":next_operation,"text":"迟到的尾句","startMs":0,"endMs":20,"isFinal":true}).to_string(), NOW);
    assert!(
        runtime
            .workspace()
            .record(&next_id)
            .unwrap()
            .aggregate
            .spine
            .is_empty()
    );
    assert!(runtime.snapshot(NOW)["liveCaption"].is_null());
}

#[test]
fn local_result_queue_overflow_keeps_accepted_finals_until_storage_recovers() {
    let dir = Sandbox::new();
    let mut runtime = KoeRuntime::open(&dir.0).unwrap();
    let (id, operation) = start_local(&mut runtime, 940);
    runtime.ingest_ble_chunk(&rx(0x0a, &940u32.to_le_bytes()), NOW);
    local_effects(&mut runtime);
    let path = dir.0.join("product-workspace.json");
    fs::rename(&path, dir.0.join("original.json")).unwrap();
    fs::create_dir(&path).unwrap();
    let text = "字".repeat(10_000);
    for start in [0, 20, 40] {
        runtime.dispatch_json(&json!({"type":"local_asr_result","operationId":operation,"text":text,"startMs":start,"endMs":start+20,"isFinal":true}).to_string(), NOW);
    }
    assert_eq!(local_effects(&mut runtime)[0]["kind"], "cancel");
    assert!(
        runtime
            .workspace()
            .record(&id)
            .unwrap()
            .aggregate
            .spine
            .is_empty()
    );
    fs::remove_dir(&path).unwrap();
    fs::rename(dir.0.join("original.json"), &path).unwrap();
    runtime.poll_timers(0, NOW);
    let record = runtime.workspace().record(&id).unwrap();
    assert_eq!(record.aggregate.spine.len(), 2);
    assert_eq!(record.aggregate.spine.segments()[0].text, text);
    assert!(
        matches!(&record.analysis, AnalysisState::Failed { message, .. } if message.contains("超出范围"))
    );
}
