#![allow(clippy::unwrap_used, clippy::expect_used)]

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
            "koe-timeline-{}-{}",
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
    serde_json::from_str(&r.dispatch_json(&v.to_string(), 100)).unwrap()
}
fn ok(s: Value) -> Value {
    assert!(s["error"].is_null(), "{}", s["error"]);
    s
}
fn event(r: &mut KoeRuntime, t: &Value, lane: &str, mut v: Value) -> Value {
    v["recordId"] = t["recordId"].clone();
    v["sessionId"] = t["sessionId"].clone();
    v["lane"] = json!(lane);
    send(r, v)
}
fn begin(r: &mut KoeRuntime) -> Value {
    let t=ok(send(r,json!({"type":"start_microphone","inputId":"fixture","includeSystem":true,"clockNs":1_000_000_000u64})))["microphone"].clone();
    for (lane, rate) in [("microphone", 16000), ("system", 48000)] {
        ok(event(
            r,
            &t,
            lane,
            json!({"type":"microphone_started","sampleRate":rate}),
        ));
    }
    t
}
fn chunk(
    r: &mut KoeRuntime,
    t: &Value,
    lane: &str,
    seq: u64,
    epoch: u64,
    ns: u64,
    count: usize,
) -> Value {
    let samples = vec![7i16; count];
    r.ingest_microphone_pcm(koe_runtime::MicrophonePcmChunk {
        record_id: t["recordId"].as_str().unwrap(),
        session_id: t["sessionId"].as_str().unwrap(),
        lane,
        sequence: seq,
        samples: &samples,
        timing: Some((epoch, ns)),
        now: 100,
    });
    r.snapshot(100)
}
fn stop(r: &mut KoeRuntime, t: &Value, lane: &str, seq: u64) -> Value {
    let epoch = r.snapshot(100)["microphone"]["epoch"].clone();
    event(
        r,
        t,
        lane,
        json!({"type":"microphone_stopped","sequence":seq,"epoch":epoch}),
    )
}
#[test]
fn common_clock_preserves_start_delay_rates_gap_tail_and_two_reopens() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    let live = ok(chunk(&mut r, &t, "system", 0, 0, 1_050_000_000, 480));
    assert_eq!(live["microphone"]["durationMs"], 60);
    ok(chunk(&mut r, &t, "microphone", 0, 0, 1_000_000_000, 160));
    ok(send(&mut r, json!({"type":"request_quit"})));
    ok(stop(&mut r, &t, "system", 1));
    ok(chunk(&mut r, &t, "microphone", 1, 0, 1_100_000_000, 160));
    ok(stop(&mut r, &t, "microphone", 2));
    let id = t["recordId"].as_str().unwrap();
    for pass in 0..2 {
        drop(r);
        r = KoeRuntime::open(&p.0).unwrap();
        ok(send(&mut r, json!({"type":"select_record","recordId":id})));
        let s = r.snapshot(100);
        let lanes = &s["detail"]["captureLanes"];
        assert_eq!(lanes[0]["timeline"][1]["startNs"], 100_000_000);
        assert_eq!(lanes[1]["timeline"][0]["startNs"], 50_000_000);
        assert_eq!(lanes[1]["timeline"][0]["sampleCount"], 480);
        assert_eq!(s["detail"]["durationMs"], 110);
        assert_eq!(
            fs::metadata(p.0.join("audio").join(format!("{id}.wav")))
                .unwrap()
                .len(),
            44 + 640
        );
        if pass == 0 {
            ok(send(
                &mut r,
                json!({"type":"rename_record","recordId":id,"title":"recommitted"}),
            ));
        }
    }
}
#[test]
fn pause_waits_for_both_fences_and_rejects_old_epoch_without_consuming_sequence() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    ok(chunk(&mut r, &t, "microphone", 0, 0, 1_000_000_000, 160));
    ok(send(&mut r, json!({"type":"pause_microphone"})));
    assert!(send(
        &mut r,
        json!({"type":"resume_microphone","clockNs":2_000_000_000u64})
    )["error"]
        .is_string());
    ok(chunk(&mut r, &t, "system", 0, 0, 1_020_000_000, 480));
    for lane in ["microphone", "system"] {
        ok(event(
            &mut r,
            &t,
            lane,
            json!({"type":"microphone_paused","epoch":0,"sequence":1}),
        ));
    }
    assert_eq!(r.snapshot(100)["microphone"]["phase"], "paused");
    assert!(chunk(&mut r, &t, "microphone", 1, 0, 1_010_000_000, 160)["error"].is_string());
    ok(send(
        &mut r,
        json!({"type":"resume_microphone","clockNs":2_000_000_000u64}),
    ));
    assert!(chunk(&mut r, &t, "microphone", 1, 0, 1_010_000_000, 160)["error"].is_string());
    ok(event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_stopped","sequence":1,"epoch":0}),
    ));
    ok(event(
        &mut r,
        &t,
        "system",
        json!({"type":"microphone_failed","message":"old epoch","epoch":0}),
    ));
    assert_eq!(r.snapshot(100)["microphone"]["phase"], "recording");
    ok(chunk(&mut r, &t, "microphone", 1, 1, 2_000_000_000, 160));
    ok(chunk(&mut r, &t, "system", 1, 1, 2_005_000_000, 480));
    ok(send(&mut r, json!({"type":"stop_microphone"})));
    ok(stop(&mut r, &t, "microphone", 2));
    ok(stop(&mut r, &t, "system", 2));
    let s = r.snapshot(100);
    assert_eq!(s["detail"]["durationMs"], 45);
    assert_eq!(
        s["detail"]["captureLanes"][0]["timeline"][1]["startNs"],
        30_000_000
    );
    assert_eq!(s["detail"]["captureLanes"][0]["timeline"][1]["epoch"], 1);
}
#[test]
fn invalid_time_never_writes_bytes_or_advances_sequence() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    assert!(chunk(&mut r, &t, "microphone", 0, 0, 999_999_999, 160)["error"].is_string());
    ok(chunk(&mut r, &t, "microphone", 0, 0, 1_000_000_000, 160));
    for ns in [1_000_000_000, u64::MAX, 100_000_000_000] {
        assert!(chunk(&mut r, &t, "microphone", 1, 0, ns, 160)["error"].is_string());
    }
    ok(chunk(&mut r, &t, "microphone", 1, 0, 1_010_000_000, 160));
    ok(send(&mut r, json!({"type":"cancel_microphone"})));
    ok(stop(&mut r, &t, "system", 0));
    ok(stop(&mut r, &t, "microphone", 2));
    assert!(r.workspace().records().is_empty());
}

#[test]
fn untagged_terminal_callback_cannot_end_a_timed_capture() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    ok(chunk(&mut r, &t, "microphone", 0, 0, 1_000_000_000, 160));
    let s = event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_failed","message":"old callback"}),
    );
    assert_eq!(s["microphone"]["phase"], "recording");
    let s = event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_stopped","sequence":1}),
    );
    assert_eq!(s["microphone"]["lanes"]["microphone"]["stopped"], false);
}

#[test]
fn fractional_rate_long_stream_survives_pause_save_retry_and_reopen() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = ok(send(
        &mut r,
        json!({"type":"start_microphone","inputId":"fixture","clockNs":1_000_000_000u64}),
    ))["microphone"]
        .clone();
    ok(event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_started","sampleRate":44100}),
    ));
    let blocks = 4200u64;
    for seq in 0..blocks {
        ok(chunk(
            &mut r,
            &t,
            "microphone",
            seq,
            0,
            1_000_000_000 + seq * 1024 * 1_000_000_000 / 44100,
            1024,
        ));
    }
    ok(send(&mut r, json!({"type":"pause_microphone"})));
    ok(event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_paused","sequence":blocks,"epoch":0}),
    ));
    ok(send(
        &mut r,
        json!({"type":"resume_microphone","clockNs":200_000_000_000u64}),
    ));
    ok(chunk(
        &mut r,
        &t,
        "microphone",
        blocks,
        1,
        200_000_000_000,
        441,
    ));
    let id = t["recordId"].as_str().unwrap();
    let target = p.0.join("audio").join(format!("{id}.wav"));
    fs::create_dir(&target).unwrap();
    ok(send(&mut r, json!({"type":"request_quit"})));
    assert!(stop(&mut r, &t, "microphone", blocks + 1)["error"].is_string());
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "blocked");
    ok(send(&mut r, json!({"type":"cancel_quit"})));
    fs::remove_dir(&target).unwrap();
    ok(send(&mut r, json!({"type":"retry_microphone_save"})));
    drop(r);
    let mut r = KoeRuntime::open(&p.0).unwrap();
    ok(send(&mut r, json!({"type":"select_record","recordId":id})));
    let s = r.snapshot(100);
    assert_eq!(
        s["detail"]["durationMs"],
        (blocks * 1024 * 1_000_000_000 / 44100 + 10_000_000) / 1_000_000
    );
    assert_eq!(
        fs::metadata(target).unwrap().len(),
        44 + (blocks * 1024 + 441) * 2
    );
    let lane = &r.workspace().record(id).unwrap().capture_lanes[0];
    assert_eq!(
        lane.timeline.iter().map(|s| s.sample_count).sum::<u64>(),
        blocks * 1024 + 441
    );
    assert_eq!(lane.timeline.last().unwrap().epoch, 1);
}

#[test]
fn permission_preparation_sets_session_clock_once_before_audio_starts() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = ok(send(
        &mut r,
        json!({"type":"start_microphone","inputId":"fixture"}),
    ))["microphone"]
        .clone();
    let prepared = json!({"type":"microphone_prepared","recordId":t["recordId"],"sessionId":t["sessionId"],"epoch":0,"clockNs":30_000_000_000u64});
    for (field, value) in [
        ("recordId", json!("old")),
        ("sessionId", json!("old")),
        ("epoch", json!(1)),
    ] {
        let mut stale = prepared.clone();
        stale[field] = value;
        assert!(ok(send(&mut r, stale))["microphone"]["clockNs"].is_null());
    }
    assert_eq!(
        ok(send(&mut r, prepared.clone()))["microphone"]["clockNs"],
        30_000_000_000u64
    );
    ok(send(&mut r, prepared.clone()));
    let mut changed = prepared.clone();
    changed["clockNs"] = json!(40_000_000_000u64);
    let rejected = send(&mut r, changed);
    assert!(rejected["error"].is_string());
    assert_eq!(rejected["microphone"]["clockNs"], 30_000_000_000u64);
    let started = ok(event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_started","sampleRate":16000}),
    ));
    assert_eq!(
        started["microphone"]["lanes"]["microphone"]["sampleRate"],
        16000
    );
    ok(chunk(&mut r, &t, "microphone", 0, 0, 30_010_000_000, 160));
    ok(send(&mut r, json!({"type":"pause_microphone"})));
    ok(event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_paused","epoch":0,"sequence":1}),
    ));
    assert_eq!(r.snapshot(100)["microphone"]["phase"], "paused");
    ok(send(&mut r, json!({"type":"request_quit"})));
    ok(stop(&mut r, &t, "microphone", 1));
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "ready");
    assert_eq!(r.snapshot(100)["detail"]["durationMs"], 20);
}

#[test]
fn late_permission_preparation_cannot_revive_cancelled_or_quitting_capture() {
    for command in ["cancel_microphone", "request_quit"] {
        let p = Sandbox::new();
        let mut r = KoeRuntime::open(&p.0).unwrap();
        let t = ok(send(
            &mut r,
            json!({"type":"start_microphone","inputId":"fixture"}),
        ))["microphone"]
            .clone();
        ok(send(&mut r, json!({"type":command})));
        let prepared = json!({"type":"microphone_prepared","recordId":t["recordId"],"sessionId":t["sessionId"],"epoch":0,"clockNs":30_000_000_000u64});
        assert!(ok(send(&mut r, prepared.clone()))["microphone"]["clockNs"].is_null());
        ok(stop(&mut r, &t, "microphone", 0));
        let final_state = ok(send(&mut r, prepared));
        assert!(final_state["microphone"].is_null());
        assert!(r.workspace().records().is_empty());
        if command == "request_quit" {
            assert_eq!(final_state["lifecycle"]["quitPhase"], "ready");
        }
    }
}
