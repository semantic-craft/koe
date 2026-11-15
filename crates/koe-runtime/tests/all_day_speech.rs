use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::{
    fs,
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};
struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let p = std::env::temp_dir().join(format!(
            "koe-all-day-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&p).unwrap();
        Self(p)
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn send(r: &mut KoeRuntime, v: Value) -> Value {
    serde_json::from_str(&r.dispatch_json(&v.to_string(), 100)).unwrap()
}
fn audio(r: &mut KoeRuntime, t: &Value, sequence: u64, n: usize) -> Value {
    send(
        r,
        json!({"type":"microphone_chunk","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":sequence,"samples":vec![100i16;n]}),
    )
}
#[test]
fn live_minutes_keeps_final_and_draining_draft_until_the_next_recording() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let s = send(&mut r, json!({"type":"start_capture_mode","mode":"meeting"}));
    let t = &s["microphone"];
    microphone_started(&mut r, t);
    audio(&mut r, t, 0, 320);
    let op = accept_windows(&mut r, "")[0];
    let final_segment = send(&mut r, json!({"type":"local_asr_result","operationId":op,"text":"已确认原文","startMs":0,"endMs":10,"isFinal":true}));
    assert_eq!(final_segment["liveMinutes"]["parts"][0]["segments"][0]["text"], "已确认原文");
    send(&mut r, json!({"type":"local_asr_result","operationId":op,"text":"仍在识别","startMs":10,"endMs":20,"isFinal":false}));
    send(&mut r, json!({"type":"navigate","section":"live_minutes"}));
    send(&mut r, json!({"type":"stop_microphone"}));
    let saved = send(&mut r, json!({"type":"microphone_stopped","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":1}));
    assert_eq!(saved["section"], "live_minutes");
    assert_eq!(saved["liveMinutes"]["phase"], "finishing");
    assert_eq!(saved["liveMinutes"]["parts"][0]["drafts"], json!(["仍在识别"]));
    send(&mut r, json!({"type":"local_asr_result","operationId":op,"text":"停止时的尾句","startMs":10,"endMs":20,"isFinal":true}));
    let finished = send(&mut r, json!({"type":"local_asr_finished","operationId":op}));
    let minutes = &finished["liveMinutes"];
    assert_eq!(minutes["phase"], "ended");
    assert_eq!(minutes["parts"][0]["recordId"], t["recordId"]);
    assert_eq!(minutes["parts"][0]["segments"][1]["text"], "停止时的尾句");
    assert_eq!(minutes["parts"][0]["drafts"], json!([]));
    assert_eq!(minutes["parts"][0]["analysis"], "unconfigured");
    assert_eq!(minutes["parts"][0]["summary"], json!([]));

    let next = send(&mut r, json!({"type":"start_capture_mode","mode":"meeting"}));
    assert_ne!(next["liveMinutes"]["scope"], minutes["scope"]);
    assert_eq!(next["liveMinutes"]["parts"], json!([]));
    drop(r);
    let reopened = KoeRuntime::open(&d.0).unwrap();
    assert!(reopened.snapshot(100)["liveMinutes"].is_null());
    assert!(reopened.workspace().record(t["recordId"].as_str().unwrap()).is_some());
}

#[test]
fn microphone_creates_durable_record_on_first_audio_and_uses_selected_speech_engine() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    let s = send(
        &mut r,
        json!({"type":"configure_speech","engine":"apple_speech"}),
    );
    assert!(s["error"].is_null(), "{s}");
    send(
        &mut r,
        json!({"type":"local_asr_readiness","state":"ready","message":"ready"}),
    );
    let s = send(
        &mut r,
        json!({"type":"start_microphone","inputId":"fixture"}),
    );
    let t = &s["microphone"];
    assert!(r.workspace().records().is_empty());
    send(
        &mut r,
        json!({"type":"microphone_started","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sampleRate":16000}),
    );
    audio(&mut r, t, 0, 320);
    assert_eq!(r.workspace().records().len(), 1);
    let effects: Value = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
    let op = effects
        .as_array()
        .unwrap()
        .iter()
        .find(|e| e["kind"] == "start")
        .unwrap()["operationId"]
        .clone();
    let s = send(
        &mut r,
        json!({"type":"local_asr_result","operationId":op,"text":"第一句","startMs":0,"endMs":20,"isFinal":true}),
    );
    assert!(s["error"].is_null(), "{s}");
    assert_eq!(
        r.workspace()
            .records()
            .values()
            .next()
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "第一句"
    );
    send(&mut r, json!({"type":"stop_microphone"}));
    send(
        &mut r,
        json!({"type":"microphone_stopped","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":1}),
    );
    send(
        &mut r,
        json!({"type":"local_asr_finished","operationId":op}),
    );
    drop(r);
    let r = KoeRuntime::open(&d.0).unwrap();
    assert_eq!(
        r.workspace()
            .records()
            .values()
            .next()
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "第一句"
    );
}
#[test]
fn selecting_cloud_does_not_change_audio_upload_permission() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    let s = send(&mut r, json!({"type":"configure_speech","engine":"cloud"}));
    assert!(s["error"].is_null(), "{s}");
    assert_eq!(s["provider"]["meetingAudioPolicy"], "local_only");
    drop(r);
    let r = KoeRuntime::open(&d.0).unwrap();
    assert_eq!(r.snapshot(100)["speech"]["engine"], "cloud");
}

fn apple_ready(r: &mut KoeRuntime) {
    send(
        r,
        json!({"type":"configure_speech","engine":"apple_speech"}),
    );
    send(
        r,
        json!({"type":"local_asr_readiness","state":"ready","message":"ready"}),
    );
}
fn microphone_started(r: &mut KoeRuntime, t: &Value) {
    let s = send(
        r,
        json!({"type":"microphone_started","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sampleRate":16000}),
    );
    assert!(s["error"].is_null(), "{s}");
}
fn accept_windows(r: &mut KoeRuntime, finish_text: &str) -> Vec<u64> {
    let effects: Vec<Value> = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
    let mut starts = vec![];
    for e in effects {
        let op = e["operationId"].as_u64().unwrap();
        if e["kind"] == "start" {
            starts.push(op);
        }
        if e["kind"] == "finish" {
            send(
                r,
                json!({"type":"local_asr_result","operationId":op,"text":finish_text,"startMs":0,"endMs":1,"isFinal":true}),
            );
            send(r, json!({"type":"local_asr_finished","operationId":op}));
        }
    }
    starts
}
#[test]
fn all_day_seals_records_without_restarting_the_native_audio_producer() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/chat", listener.local_addr().unwrap());
    let (received, wait_received) = std::sync::mpsc::channel();
    let (release, wait_release) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        use std::io::{Read, Write};
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(std::time::Duration::from_secs(10)))
            .unwrap();
        let mut request = Vec::new();
        let mut buf = [0; 4096];
        loop {
            let n = socket.read(&mut buf).unwrap();
            assert!(n > 0);
            request.extend_from_slice(&buf[..n]);
            if let Some(end) = request.windows(4).position(|s| s == b"\r\n\r\n") {
                let headers = String::from_utf8_lossy(&request[..end]);
                let len = headers
                    .lines()
                    .find_map(|s| {
                        s.to_ascii_lowercase()
                            .strip_prefix("content-length:")
                            .and_then(|s| s.trim().parse::<usize>().ok())
                    })
                    .unwrap();
                assert!(!headers.to_ascii_lowercase().contains("authorization:"));
                if request.len() >= end + 4 + len {
                    break;
                }
            }
        }
        received.send(()).unwrap();
        wait_release
            .recv_timeout(std::time::Duration::from_secs(10))
            .unwrap();
        let summary=json!({"schemaVersion":2,"title":"全天听记","overview":"已封段原文","topics":[{"text":"本段要点","summary":"已封段原文","sources":["S1"]}],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}).to_string();
        let body = json!({"choices":[{"message":{"content":summary}}]}).to_string();
        write!(socket,"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",body.len(),body).unwrap();
    });
    let settings = send(
        &mut r,
        json!({"type":"configure_provider","model":"fixture","chatEndpoint":endpoint}),
    );
    assert_eq!(settings["provider"]["configured"], true);
    let s = send(
        &mut r,
        json!({"type":"start_all_day","source":"microphone","inputId":"fixture"}),
    );
    assert!(s["error"].is_null(), "{s}");
    let t = s["microphone"].clone();
    microphone_started(&mut r, &t);
    let mut sequence = 0;
    let mut samples = 0;
    while samples < 4_800_000 {
        let n = 8192.min(4_800_000 - samples);
        let s = audio(&mut r, &t, sequence, n);
        assert!(s["error"].is_null(), "{s}");
        accept_windows(&mut r, "已封段原文");
        sequence += 1;
        samples += n;
    }
    let first = r.workspace().records().values().next().unwrap().clone();
    assert_eq!(first.aggregate.duration_ms, 300_000);
    assert!(!first.aggregate.spine.is_empty());
    assert_eq!(first.all_day.as_ref().unwrap().ordinal, 1);
    assert!(d
        .0
        .join("audio")
        .join(format!("{}.wav", first.aggregate.recording_id))
        .is_file());
    r.poll_timers(0, 100);
    wait_received
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    assert!(matches!(
        r.workspace()
            .record(&first.aggregate.recording_id)
            .unwrap()
            .analysis,
        koe_engine::product::AnalysisState::Pending {
            stage: koe_engine::product::AnalysisStage::Summarizing,
            ..
        }
    ));
    let next_day = 100 + 86_400;
    let s: Value = serde_json::from_str(&r.dispatch_json(
        &json!({"type":"microphone_chunk","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":sequence,"samples":vec![100i16;320]}).to_string(), next_day,
    )).unwrap();
    assert!(s["error"].is_null(), "{s}");
    sequence += 1;
    assert_eq!(s["microphone"]["recordId"], t["recordId"]);
    assert_eq!(s["microphone"]["sessionId"], t["sessionId"]);
    assert_eq!(s["microphone"]["phase"], "recording");
    assert_eq!(r.workspace().records().len(), 2);
    let second = r
        .workspace()
        .records()
        .values()
        .find(|v| v.aggregate.recording_id != first.aggregate.recording_id)
        .unwrap();
    assert_eq!(second.all_day.as_ref().unwrap().ordinal, 2);
    assert_eq!(second.aggregate.created_at_epoch_sec, next_day);
    assert_eq!(
        s["workspaces"]["allDay"]["spans"][0]["recordIds"],
        json!([second.aggregate.recording_id])
    );
    assert_eq!(
        second.all_day.as_ref().unwrap().run_id,
        first.all_day.as_ref().unwrap().run_id
    );
    release.send(()).unwrap();
    server.join().unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    while r
        .workspace()
        .record(&first.aggregate.recording_id)
        .unwrap()
        .aggregate
        .minutes
        .is_none()
    {
        r.poll_timers(0, 100);
        assert!(std::time::Instant::now() < deadline, "{}", r.snapshot(100));
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert_eq!(
        r.snapshot(100)["workspaces"]["allDay"]["dailyReview"]["overview"],
        "已封段原文"
    );
    let live = r.snapshot(100);
    let minutes = &live["liveMinutes"];
    assert_eq!(minutes["scope"], json!({"kind":"all_day","id":first.all_day.as_ref().unwrap().run_id}));
    assert_eq!(minutes["phase"], "recording");
    assert_eq!(minutes["parts"][0]["recordId"], first.aggregate.recording_id);
    assert_eq!(minutes["parts"][0]["analysis"], "ready");
    assert_eq!(minutes["parts"][0]["summary"][0]["text"], "已封段原文");
    let source = &minutes["parts"][0]["summary"][1]["sources"][0];
    assert_eq!(source["recordId"], first.aggregate.recording_id);
    assert_eq!(source["segmentId"], "S1");
    assert_eq!(source["quote"], "已封段原文");
    assert_eq!(minutes["parts"][1]["ordinal"], 2);
    assert_eq!(minutes["parts"][1]["summary"], json!([]));

    send(&mut r, json!({"type":"stop_all_day"}));
    send(
        &mut r,
        json!({"type":"microphone_stopped","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":sequence}),
    );
    accept_windows(&mut r, "最后一句");
    r.poll_timers(0, 100);
    assert_eq!(r.snapshot(100)["allDay"]["state"], "idle");
    assert!(
        r.drain_companion_events().is_empty(),
        "ordinary all-day recording must not emit dictation text"
    );
    drop(r);
    let r = KoeRuntime::open(&d.0).unwrap();
    assert_eq!(r.workspace().records().len(), 2);
    assert!(r
        .workspace()
        .records()
        .values()
        .all(|v| v.all_day.is_some() && !v.aggregate.spine.is_empty()));
}
#[test]
fn dictation_bridge_publishes_only_selected_persisted_finals_and_the_stop_tail() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let s = send(
        &mut r,
        json!({"type":"start_microphone","inputId":"fixture"}),
    );
    let t = s["microphone"].clone();
    microphone_started(&mut r, &t);
    audio(&mut r, &t, 0, 320);
    let first = accept_windows(&mut r, "")[0];
    send(
        &mut r,
        json!({"type":"local_asr_result","operationId":first,"text":"普通录音","startMs":0,"endMs":20,"isFinal":true}),
    );
    assert!(r.drain_companion_events().is_empty());
    send(&mut r, json!({"type":"set_dictation_active","active":true}));
    accept_windows(&mut r, "普通录音");
    audio(&mut r, &t, 1, 320);
    let selected = accept_windows(&mut r, "")[0];
    send(
        &mut r,
        json!({"type":"local_asr_result","operationId":selected,"text":"未定稿","startMs":0,"endMs":20,"isFinal":false}),
    );
    assert!(r.drain_companion_events().is_empty());
    send(&mut r, json!({"type":"stop_microphone"}));
    send(
        &mut r,
        json!({"type":"microphone_stopped","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":2}),
    );
    let path = d.0.join("product-workspace.json");
    fs::rename(&path, d.0.join("saved.json")).unwrap();
    fs::create_dir(&path).unwrap();
    send(
        &mut r,
        json!({"type":"local_asr_result","operationId":selected,"text":"真正尾句","startMs":0,"endMs":20,"isFinal":true}),
    );
    assert!(r.drain_companion_events().is_empty());
    send(
        &mut r,
        json!({"type":"local_asr_finished","operationId":selected}),
    );
    fs::remove_dir(&path).unwrap();
    fs::rename(d.0.join("saved.json"), &path).unwrap();
    r.poll_timers(0, 100);
    assert_eq!(r.snapshot(100)["dictation"]["active"], false);
    let events = r.drain_companion_events();
    assert_eq!(events.len(), 1);
    let e = serde_json::to_value(&events[0]).unwrap();
    assert_eq!(e["event"], "transcript_final");
    assert_eq!(e["text"], "真正尾句");
    assert_eq!(e["dictation"], true);
    assert_eq!(e["recordId"], t["recordId"]);
    assert_eq!(e["startMs"], 20);
    assert_eq!(e["endMs"], 40);
    let raw = fs::read_to_string(path).unwrap();
    assert!(raw.contains("真正尾句"));
}
#[test]
fn interrupted_microphone_audio_is_recovered_and_only_local_unfinished_work_resumes() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let s = send(
        &mut r,
        json!({"type":"start_microphone","inputId":"fixture"}),
    );
    let t = s["microphone"].clone();
    microphone_started(&mut r, &t);
    audio(&mut r, &t, 0, 640);
    let op = accept_windows(&mut r, "")[0];
    send(
        &mut r,
        json!({"type":"local_asr_result","operationId":op,"text":"已保存句子","startMs":0,"endMs":20,"isFinal":true}),
    );
    drop(r);
    let mut r = KoeRuntime::open(&d.0).unwrap();
    let record = r
        .workspace()
        .record(t["recordId"].as_str().unwrap())
        .unwrap();
    assert_eq!(record.aggregate.duration_ms, 40);
    assert_eq!(record.aggregate.spine.segments()[0].text, "已保存句子");
    assert!(d
        .0
        .join("audio")
        .join(format!("{}.wav", t["recordId"].as_str().unwrap()))
        .is_file());
    send(
        &mut r,
        json!({"type":"local_asr_readiness","state":"ready","message":"ready"}),
    );
    r.poll_timers(0, 100);
    r.poll_timers(0, 100);
    let effects: Vec<Value> = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
    let op = effects.iter().find(|e| e["kind"] == "start").unwrap()["operationId"].clone();
    assert_eq!(
        effects.iter().find(|e| e["kind"] == "audio").unwrap()["pcm16"]
            .as_array()
            .unwrap()
            .len(),
        320
    );
    send(
        &mut r,
        json!({"type":"local_asr_result","operationId":op,"text":"恢复尾句","startMs":0,"endMs":20,"isFinal":true}),
    );
    send(
        &mut r,
        json!({"type":"local_asr_finished","operationId":op}),
    );
    let record = r
        .workspace()
        .record(t["recordId"].as_str().unwrap())
        .unwrap();
    assert_eq!(record.aggregate.spine.segments().len(), 2);
    assert_eq!(record.aggregate.spine.segments()[1].start_ms, 20);
}

#[test]
fn apple_waits_for_the_previous_window_tail_before_starting_the_next() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let s = send(
        &mut r,
        json!({"type":"start_microphone","inputId":"fixture"}),
    );
    let t = s["microphone"].clone();
    microphone_started(&mut r, &t);
    let mut sequence = 0;
    let mut n = 0;
    let mut operation = None;
    while n < 240_000 {
        let count = 8192.min(240_000 - n);
        audio(&mut r, &t, sequence, count);
        let effects: Vec<Value> = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
        for e in effects {
            if e["kind"] == "start" {
                operation = e["operationId"].as_u64();
            }
        }
        n += count;
        sequence += 1;
    }
    audio(&mut r, &t, sequence, 320);
    let waiting: Vec<Value> = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
    assert!(!waiting
        .iter()
        .any(|e| e["kind"] == "start" || e["kind"] == "cancel"));
    let operation = operation.unwrap();
    send(
        &mut r,
        json!({"type":"local_asr_result","operationId":operation,"text":"前窗尾句","startMs":14980,"endMs":15000,"isFinal":true}),
    );
    send(
        &mut r,
        json!({"type":"local_asr_finished","operationId":operation}),
    );
    let next: Vec<Value> = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
    assert_eq!(next.iter().filter(|e| e["kind"] == "start").count(), 1);
    assert_eq!(
        next.iter().find(|e| e["kind"] == "audio").unwrap()["pcm16"]
            .as_array()
            .unwrap()
            .len(),
        320
    );
    assert!(r
        .workspace()
        .records()
        .values()
        .next()
        .unwrap()
        .aggregate
        .spine
        .segments()
        .iter()
        .any(|s| s.text == "前窗尾句"));
}
#[test]
fn dictation_selection_does_not_publish_background_file_transcription() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let mut bytes = koe_engine::wav::OpusWave::wav_header_with_rate(640, 16000).to_vec();
    bytes.extend(vec![0; 640]);
    let file = d.0.join("audio.wav");
    fs::write(&file, bytes).unwrap();
    let s = send(&mut r, json!({"type":"import_file","path":file}));
    send(&mut r, json!({"type":"set_dictation_active","active":true}));
    send(
        &mut r,
        json!({"type":"transcribe","recordId":s["selectedRecordId"]}),
    );
    let effects: Vec<Value> = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
    let op = effects.iter().find(|e| e["kind"] == "start").unwrap()["operationId"].clone();
    let active = send(&mut r, json!({"type":"start_capture_mode","mode":"meeting"}));
    let ticket = &active["microphone"];
    microphone_started(&mut r, ticket);
    audio(&mut r, ticket, 0, 320);
    let during_background_draft = send(
        &mut r,
        json!({"type":"local_asr_result","operationId":op,"text":"后台文件临时字幕","startMs":0,"endMs":20,"isFinal":false}),
    );
    assert_eq!(during_background_draft["liveCaption"]["text"], "后台文件临时字幕");
    let live = &during_background_draft["liveMinutes"];
    assert_eq!(live["parts"][0]["recordId"], ticket["recordId"]);
    assert_eq!(live["parts"][0]["drafts"], json!([]));
    send(
        &mut r,
        json!({"type":"local_asr_result","operationId":op,"text":"后台文件原文","startMs":0,"endMs":20,"isFinal":true}),
    );
    send(
        &mut r,
        json!({"type":"local_asr_finished","operationId":op}),
    );
    assert_eq!(r.snapshot(100)["liveMinutes"]["parts"][0]["segments"], json!([]));
    assert!(r.drain_companion_events().is_empty());
    assert_eq!(
        r.workspace()
            .record(s["selectedRecordId"].as_str().unwrap())
            .unwrap()
            .aggregate
            .spine
            .segments()[0]
            .text,
        "后台文件原文"
    );
}
#[test]
fn timed_all_day_pause_after_rotation_keeps_one_clock_coordinate() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let s = send(
        &mut r,
        json!({"type":"start_all_day","source":"microphone","inputId":"fixture"}),
    );
    let t = s["microphone"].clone();
    let clock = 1_000_000_000u64;
    send(
        &mut r,
        json!({"type":"microphone_prepared","recordId":t["recordId"],"sessionId":t["sessionId"],"epoch":0,"clockNs":clock}),
    );
    microphone_started(&mut r, &t);
    let mut sequence = 0u64;
    let mut n = 0usize;
    while n < 4_800_320 {
        let count = 8192.min(4_800_320 - n);
        let s = send(
            &mut r,
            json!({"type":"microphone_chunk","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":sequence,"samples":vec![10;count],"timing":{"epoch":0,"capturedStartNs":clock+n as u64*62500+10_000_000}}),
        );
        assert!(s["error"].is_null(), "{s}");
        accept_windows(&mut r, "已识别");
        n += count;
        sequence += 1;
    }
    send(&mut r, json!({"type":"pause_microphone"}));
    send(
        &mut r,
        json!({"type":"microphone_paused","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":sequence,"epoch":0}),
    );
    let resumed_at = clock + n as u64 * 62500 + 10_000_000 + 1_000_000_000;
    let s = send(
        &mut r,
        json!({"type":"resume_microphone","clockNs":resumed_at}),
    );
    assert!(s["error"].is_null(), "{s}");
    let s = send(
        &mut r,
        json!({"type":"microphone_chunk","recordId":t["recordId"],"sessionId":t["sessionId"],"lane":"microphone","sequence":sequence,"samples":vec![20;320],"timing":{"epoch":1,"capturedStartNs":resumed_at}}),
    );
    assert!(s["error"].is_null(), "{s}");
    assert_eq!(s["microphone"]["nextSequence"], sequence + 1);
}

#[test]
fn apple_file_backpressure_waits_for_native_completion_instead_of_filling_its_queue() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let mut bytes = koe_engine::wav::OpusWave::wav_header_with_rate(32000 * 90, 16000).to_vec();
    bytes.resize(44 + 32000 * 90, 0);
    let file = d.0.join("long.wav");
    fs::write(&file, bytes).unwrap();
    let s = send(&mut r, json!({"type":"import_file","path":file}));
    let id = s["selectedRecordId"].clone();
    send(&mut r, json!({"type":"transcribe","recordId":id}));
    for _ in 0..10 {
        r.poll_timers(0, 100);
    }
    assert!(r.snapshot(100)["error"].is_null(), "{}", r.snapshot(100));
    let effects: Vec<Value> = serde_json::from_str(&r.drain_local_asr_json()).unwrap();
    assert_eq!(effects.iter().filter(|e| e["kind"] == "start").count(), 1);
    assert!(!effects.iter().any(|e| e["kind"] == "cancel"));
}

#[test]
fn standalone_dictation_publishes_words_after_microphone_resume() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let started = send(&mut r, json!({"type":"start_capture_mode","mode":"dictation"}));
    let mic = &started["microphone"];
    send(&mut r, json!({"type":"microphone_prepared","recordId":mic["recordId"],"sessionId":mic["sessionId"],"epoch":0,"clockNs":1_000_000_000_u64}));
    microphone_started(&mut r, mic);
    send(&mut r, json!({"type":"capture_action","action":"pause"}));
    let paused = send(&mut r, json!({"type":"microphone_paused","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sequence":0,"epoch":0}));
    assert_eq!(paused["dictation"]["active"], false);
    let resumed = send(&mut r, json!({"type":"resume_microphone","clockNs":2_000_000_000_u64}));
    assert_eq!(resumed["activeCapture"]["phase"], "recording");
    let next_epoch = &resumed["microphone"]["epoch"];
    let recorded = send(&mut r, json!({"type":"microphone_chunk","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sequence":0,"samples":vec![100i16;320],"timing":{"epoch":next_epoch,"capturedStartNs":2_000_000_000_u64}}));
    assert!(recorded["error"].is_null(), "{recorded}");
    send(&mut r, json!({"type":"capture_action","action":"end"}));
    send(&mut r, json!({"type":"microphone_stopped","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sequence":1,"epoch":next_epoch}));
    accept_windows(&mut r, "继续后的听写");
    assert!(r.drain_companion_events().iter().any(|event| matches!(
        event, koe_runtime::CompanionStreamEvent::TranscriptFinal { text, dictation: true, .. } if text == "继续后的听写"
    )));
}

#[test]
fn ending_all_day_delivers_the_selected_audio_while_the_microphone_drains() {
    let d = Sandbox::new();
    let mut r = KoeRuntime::open(&d.0).unwrap();
    apple_ready(&mut r);
    let started = send(&mut r, json!({"type":"start_capture_mode","mode":"all_day"}));
    let mic = &started["microphone"];
    microphone_started(&mut r, mic);
    send(&mut r, json!({"type":"start_capture_mode","mode":"dictation"}));
    send(&mut r, json!({"type":"capture_action","action":"end"}));
    let tail = audio(&mut r, mic, 0, 320);
    assert!(tail["error"].is_null(), "{tail}");
    send(&mut r, json!({"type":"microphone_stopped","recordId":mic["recordId"],"sessionId":mic["sessionId"],"lane":"microphone","sequence":1}));
    accept_windows(&mut r, "排空前的听写");
    assert!(r.drain_companion_events().iter().any(|event| matches!(
        event, koe_runtime::CompanionStreamEvent::TranscriptFinal { text, dictation: true, .. } if text == "排空前的听写"
    )));
    assert_eq!(r.snapshot(100)["dictation"]["active"], false);
}
