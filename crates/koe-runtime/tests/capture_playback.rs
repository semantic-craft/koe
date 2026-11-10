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
        static N: AtomicU64 = AtomicU64::new(0);
        let p = std::env::temp_dir().join(format!(
            "koe-capture-playback-{}-{}",
            std::process::id(),
            N.fetch_add(1, Ordering::Relaxed)
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
    let s: Value = serde_json::from_str(&r.dispatch_json(&v.to_string(), 100)).unwrap();
    assert!(s["error"].is_null(), "{}", s["error"]);
    s
}
fn event(r: &mut KoeRuntime, t: &Value, lane: &str, mut v: Value) -> Value {
    v["recordId"] = t["recordId"].clone();
    v["sessionId"] = t["sessionId"].clone();
    v["lane"] = json!(lane);
    send(r, v)
}
fn recording(r: &mut KoeRuntime, system_only: bool) -> String {
    let t = send(r, json!({"type":"start_microphone","includeSystem":true,"inputId":"fixture","clockNs":1_000_000_000u64}))["microphone"].clone();
    for (lane, rate) in [("microphone", 16000), ("system", 48000)] {
        event(
            r,
            &t,
            lane,
            json!({"type":"microphone_started","sampleRate":rate}),
        );
    }
    if !system_only {
        for (seq, ns) in [(0, 1_000_000_000u64), (1, 1_100_000_000)] {
            event(
                r,
                &t,
                "microphone",
                json!({"type":"microphone_chunk","sequence":seq,"timing":{"epoch":0,"capturedStartNs":ns},"samples":vec![700;160]}),
            );
        }
    }
    event(
        r,
        &t,
        "system",
        json!({"type":"microphone_chunk","sequence":0,"timing":{"epoch":0,"capturedStartNs":1_050_000_000u64},"samples":vec![900;480]}),
    );
    send(r, json!({"type":"stop_microphone"}));
    event(
        r,
        &t,
        "microphone",
        json!({"type":"microphone_stopped","sequence":if system_only {0} else {2},"epoch":0}),
    );
    event(
        r,
        &t,
        "system",
        json!({"type":"microphone_stopped","sequence":1,"epoch":0}),
    );
    t["recordId"].as_str().unwrap().to_owned()
}

#[test]
fn sparse_lanes_have_exact_source_ranges_and_common_duration_after_reopen() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let id = recording(&mut r, false);
    for _ in 0..2 {
        drop(r);
        r = KoeRuntime::open(&p.0).unwrap();
        let s = send(&mut r, json!({"type":"select_record","recordId":id}));
        assert_eq!(s["playback"]["lane"], "microphone");
        let asset = &s["playback"]["asset"];
        assert_eq!(asset["durationNs"], 110_000_000);
        assert_eq!(asset["sampleRate"], 16000);
        assert_eq!(
            asset["segments"],
            json!([
                {"sourceStartSample":0,"sampleCount":160,"timelineStartNs":0},
                {"sourceStartSample":160,"sampleCount":160,"timelineStartNs":100_000_000}
            ])
        );
        assert_eq!(
            fs::metadata(p.0.join("audio").join(format!("{id}.wav")))
                .unwrap()
                .len(),
            684
        );
        send(&mut r, json!({"type":"seek","positionMs":75}));
        let switched = send(
            &mut r,
            json!({"type":"select_playback_lane","lane":"system"}),
        );
        assert_eq!(switched["playback"]["positionMs"], 75);
        assert_eq!(switched["playback"]["asset"]["durationNs"], 110_000_000);
        assert_eq!(switched["playback"]["asset"]["sampleRate"], 48000);
        assert_eq!(
            switched["playback"]["asset"]["segments"],
            json!([
                {"sourceStartSample":0,"sampleCount":480,"timelineStartNs":50_000_000}
            ])
        );
        send(
            &mut r,
            json!({"type":"rename_record","recordId":id,"title":"recommitted"}),
        );
    }
}

#[test]
fn system_only_record_is_playable_and_late_progress_cannot_undo_seek_or_lane_change() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let id = recording(&mut r, true);
    let s = send(&mut r, json!({"type":"playback","isPlaying":true}));
    assert_eq!(s["playback"]["lane"], "system");
    assert_eq!(s["playback"]["isPlaying"], true);
    let old_request = s["playback"]["requestId"].clone();
    let sought = send(&mut r, json!({"type":"seek","positionMs":55}));
    assert_ne!(sought["playback"]["requestId"], old_request);
    let stale = send(
        &mut r,
        json!({"type":"playback_progress","recordId":id,"requestId":old_request,"positionMs":5,"isPlaying":false}),
    );
    assert_eq!(stale["playback"]["positionMs"], 55);
    assert_eq!(stale["playback"]["isPlaying"], true);
    let accepted = send(
        &mut r,
        json!({"type":"playback_progress","recordId":id,"requestId":sought["playback"]["requestId"],"positionMs":59,"isPlaying":false}),
    );
    assert_eq!(accepted["playback"]["positionMs"], 59);
    let next = recording(&mut r, false);
    let next_s = send(&mut r, json!({"type":"playback","isPlaying":true}));
    let switched = send(
        &mut r,
        json!({"type":"select_playback_lane","lane":"system"}),
    );
    let late = send(
        &mut r,
        json!({"type":"playback_progress","recordId":next,"requestId":next_s["playback"]["requestId"],"positionMs":5,"isPlaying":false}),
    );
    assert_eq!(late["playback"], switched["playback"]);
    let wrong_record = send(
        &mut r,
        json!({"type":"playback_progress","recordId":id,"requestId":switched["playback"]["requestId"],"positionMs":5,"isPlaying":false}),
    );
    assert_eq!(wrong_record["playback"], switched["playback"]);
}

