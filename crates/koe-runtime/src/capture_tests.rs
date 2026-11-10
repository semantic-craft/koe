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
use tokio_tungstenite::tungstenite::{accept, Message};

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
    assert_eq!(before_stop["device"]["busy"], true);
    assert!(before_stop["detail"]["audioPath"].is_null());
    assert!(fs::read_to_string(dir.0.join("product-workspace.json"))
        .unwrap()
        .contains(FIRST));

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
    assert!(recording_assets::audio_path(&dir.0, &live_id)
        .unwrap()
        .exists());
    assert!(runtime.device.session.has_disk_custody(802));
}
