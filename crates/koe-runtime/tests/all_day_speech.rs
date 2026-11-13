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
    let s = audio(&mut r, &t, sequence, 320);
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
    assert_eq!(
        second.all_day.as_ref().unwrap().run_id,
        first.all_day.as_ref().unwrap().run_id
    );
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
