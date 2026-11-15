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
            "koe-dual-{}-{}",
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
fn begin(r: &mut KoeRuntime) -> Value {
    let s = send(
        r,
        json!({"type":"start_microphone","inputId":"fixture","includeSystem":true}),
    );
    assert!(s["error"].is_null(), "{}", s["error"]);
    s["microphone"].clone()
}
fn event(r: &mut KoeRuntime, t: &Value, lane: &str, mut v: Value) -> Value {
    v["recordId"] = t["recordId"].clone();
    v["sessionId"] = t["sessionId"].clone();
    v["lane"] = json!(lane);
    send(r, v)
}
fn start(r: &mut KoeRuntime, t: &Value, lane: &str) {
    let s = event(
        r,
        t,
        lane,
        json!({"type":"microphone_started","sampleRate":16000}),
    );
    assert!(s["error"].is_null(), "{}", s["error"]);
}
fn chunk(r: &mut KoeRuntime, t: &Value, lane: &str, seq: u64, n: i16) -> Value {
    event(
        r,
        t,
        lane,
        json!({"type":"microphone_chunk","sequence":seq,"samples":vec![n;160]}),
    )
}
fn stop(r: &mut KoeRuntime, t: &Value, lane: &str, seq: u64) -> Value {
    event(
        r,
        t,
        lane,
        json!({"type":"microphone_stopped","sequence":seq}),
    )
}
fn audio(p: &Sandbox, id: &str) -> Vec<u8> {
    fs::read(p.0.join("audio").join(format!("{id}.wav"))).unwrap()[44..].to_vec()
}
#[test]
fn independent_sequences_tail_barrier_and_reopen_preserve_both_assets() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    start(&mut r, &t, "system");
    start(&mut r, &t, "microphone");
    assert!(chunk(&mut r, &t, "system", 1, 9)["error"].is_string());
    chunk(&mut r, &t, "system", 0, 2);
    chunk(&mut r, &t, "microphone", 0, 1);
    send(&mut r, json!({"type":"request_quit"}));
    stop(&mut r, &t, "microphone", 1);
    assert!(r
        .workspace()
        .record(t["recordId"].as_str().unwrap())
        .unwrap()
        .capture_lanes
        .is_empty());
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "draining");
    assert!(stop(&mut r, &t, "system", 2)["error"].is_string());
    chunk(&mut r, &t, "system", 1, 3);
    stop(&mut r, &t, "system", 2);
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "ready");
    let id = t["recordId"].as_str().unwrap();
    assert_eq!(audio(&p, id), vec![1i16.to_le_bytes(); 160].concat());
    assert_eq!(
        audio(&p, &format!("{id}-system")),
        [
            vec![2i16.to_le_bytes(); 160].concat(),
            vec![3i16.to_le_bytes(); 160].concat()
        ]
        .concat()
    );
    drop(r);
    let r = KoeRuntime::open(&p.0).unwrap();
    let data: Value =
        serde_json::from_str(&fs::read_to_string(p.0.join("product-workspace.json")).unwrap())
            .unwrap();
    assert_eq!(
        data["records"][0]["capture_lanes"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    let record = r.workspace().record(id).unwrap();
    assert_eq!(record.capture_lanes.len(), 2);
    assert_eq!(record.capture_lanes[0].asset_id.as_deref(), Some(id));
    assert_eq!(
        record.capture_lanes[1].asset_id.as_deref(),
        Some(format!("{id}-system").as_str())
    );
    assert_eq!(record.capture_lanes[1].duration_ms, 20);
}
#[test]
fn failed_lane_is_persisted_as_incomplete_and_old_callbacks_are_isolated() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    start(&mut r, &t, "microphone");
    chunk(&mut r, &t, "microphone", 0, 1);
    event(
        &mut r,
        &t,
        "system",
        json!({"type":"microphone_failed","message":"permission denied"}),
    );
    stop(&mut r, &t, "system", 0);
    assert!(r
        .workspace()
        .record(t["recordId"].as_str().unwrap())
        .unwrap()
        .capture_lanes
        .is_empty());
    stop(&mut r, &t, "microphone", 1);
    let data: Value =
        serde_json::from_str(&fs::read_to_string(p.0.join("product-workspace.json")).unwrap())
            .unwrap();
    let lanes = data["records"][0]["capture_lanes"].as_array().unwrap();
    let system = lanes.iter().find(|l| l["lane"] == "system").unwrap();
    assert_eq!(system["interruption"], "permission denied");
    assert!(system["asset_id"].is_null());
    assert_eq!(r.snapshot(100)["detail"]["status"], "采集不完整");
    assert_eq!(
        r.snapshot(100)["detail"]["captureLanes"][1]["interruption"],
        "permission denied"
    );
    let new = begin(&mut r);
    start(&mut r, &new, "microphone");
    start(&mut r, &new, "system");
    chunk(&mut r, &t, "system", 0, 9);
    stop(&mut r, &t, "system", 0);
    assert_eq!(
        r.snapshot(100)["microphone"]["lanes"]["system"]["nextSequence"],
        0
    );
    send(&mut r, json!({"type":"cancel_microphone"}));
    stop(&mut r, &new, "system", 0);
    stop(&mut r, &new, "microphone", 0);
    assert_eq!(r.workspace().records().len(), 1);
}
#[test]
fn publication_retry_keeps_each_lane_and_cancel_quit_keeps_session() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    for lane in ["microphone", "system"] {
        start(&mut r, &t, lane);
        chunk(&mut r, &t, lane, 0, 4);
    }
    let id = t["recordId"].as_str().unwrap();
    let target = p.0.join("audio").join(format!("{id}-system.wav"));
    fs::create_dir(&target).unwrap();
    send(&mut r, json!({"type":"request_quit"}));
    stop(&mut r, &t, "microphone", 1);
    stop(&mut r, &t, "system", 1);
    assert!(r
        .workspace()
        .record(t["recordId"].as_str().unwrap())
        .unwrap()
        .capture_lanes
        .is_empty());
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "blocked");
    send(&mut r, json!({"type":"cancel_quit"}));
    assert_eq!(r.snapshot(100)["microphone"]["recordId"], t["recordId"]);
    assert!(send(&mut r, json!({"type":"cancel_microphone"}))["error"].is_string());
    fs::remove_dir(&target).unwrap();
    let s = send(&mut r, json!({"type":"retry_microphone_save"}));
    assert!(s["error"].is_null(), "{}", s["error"]);
    assert_eq!(r.workspace().records().len(), 1);
    assert_eq!(audio(&p, id), audio(&p, &format!("{id}-system")));
}
#[test]
fn cancellation_waits_for_both_producers_and_allows_a_new_session() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    for lane in ["microphone", "system"] {
        start(&mut r, &t, lane);
        chunk(&mut r, &t, lane, 0, 7);
    }
    send(&mut r, json!({"type":"cancel_microphone"}));
    stop(&mut r, &t, "system", 1);
    assert!(r.snapshot(100)["microphone"].is_object());
    chunk(&mut r, &t, "microphone", 1, 8);
    stop(&mut r, &t, "microphone", 2);
    assert!(r.workspace().records().is_empty());
    assert!(r.snapshot(100)["microphone"].is_null());
    assert_eq!(fs::read_dir(p.0.join("audio")).unwrap().count(), 0);
    begin(&mut r);
}

fn timed(r: &mut KoeRuntime, t: &Value, lane: &str, mut v: Value, epoch: u64) -> Value {
    v["epoch"] = json!(epoch);
    let s = event(r, t, lane, v);
    assert!(s["error"].is_null(), "{lane}: {}", s["error"]);
    s
}

fn timed_chunk(r: &mut KoeRuntime, t: &Value, lane: &str, seq: u64, epoch: u64, ns: u64, n: i16) {
    let count = if lane == "system" { 480 } else { 160 };
    let s = event(
        r,
        t,
        lane,
        json!({"type":"microphone_chunk","sequence":seq,"samples":vec![n;count],
            "timing":{"epoch":epoch,"capturedStartNs":ns}}),
    );
    assert!(s["error"].is_null(), "{lane} chunk {seq}: {}", s["error"]);
}

#[test]
fn single_lane_permission_failure_keeps_other_lane_recording_and_marks_incomplete() {
    for (denied, healthy) in [("system", "microphone"), ("microphone", "system")] {
        let p = Sandbox::new();
        let mut r = KoeRuntime::open(&p.0).unwrap();
        let t = begin(&mut r);
        let prepared = send(
            &mut r,
            json!({"type":"microphone_prepared","recordId":t["recordId"],"sessionId":t["sessionId"],
                "epoch":0,"clockNs":1_000_000_000u64}),
        );
        assert!(prepared["error"].is_null(), "{}", prepared["error"]);
        let rate = if healthy == "system" { 48000 } else { 16000 };
        let started = event(
            &mut r,
            &t,
            healthy,
            json!({"type":"microphone_started","sampleRate":rate}),
        );
        assert!(started["error"].is_null(), "{}", started["error"]);
        timed(
            &mut r,
            &t,
            denied,
            json!({"type":"microphone_failed","message":"permission denied"}),
            0,
        );
        let s = timed(
            &mut r,
            &t,
            denied,
            json!({"type":"microphone_stopped","sequence":0}),
            0,
        );
        assert_eq!(
            s["microphone"]["phase"], "recording",
            "{denied} denial must not stop the healthy {healthy} lane"
        );
        assert_eq!(s["microphone"]["interruption"], "permission denied");
        timed_chunk(&mut r, &t, healthy, 0, 0, 1_000_000_000, 3);
        assert!(send(&mut r, json!({"type":"pause_microphone"}))["error"].is_null());
        let s = timed(
            &mut r,
            &t,
            healthy,
            json!({"type":"microphone_paused","sequence":1}),
            0,
        );
        assert_eq!(s["microphone"]["phase"], "paused");
        let resumed = send(
            &mut r,
            json!({"type":"resume_microphone","clockNs":5_000_000_000u64}),
        );
        assert!(resumed["error"].is_null(), "{}", resumed["error"]);
        timed_chunk(&mut r, &t, healthy, 1, 1, 5_000_000_000, 4);
        assert!(send(&mut r, json!({"type":"stop_microphone"}))["error"].is_null());
        timed(
            &mut r,
            &t,
            healthy,
            json!({"type":"microphone_stopped","sequence":2}),
            1,
        );
        let id = t["recordId"].as_str().unwrap();
        let record = r.workspace().record(id).expect("surviving lane is saved");
        let survivor = record
            .capture_lanes
            .iter()
            .find(|l| l.lane == healthy)
            .unwrap();
        let failed = record
            .capture_lanes
            .iter()
            .find(|l| l.lane == denied)
            .unwrap();
        assert_eq!(survivor.timeline.len(), 2);
        assert!(survivor.interruption.is_none());
        assert_eq!(failed.interruption.as_deref(), Some("permission denied"));
        assert!(failed.asset_id.is_none());
        let asset = survivor.asset_id.clone().unwrap();
        let count = if healthy == "system" { 480 } else { 160 };
        assert_eq!(
            audio(&p, &asset),
            [
                vec![3i16.to_le_bytes(); count].concat(),
                vec![4i16.to_le_bytes(); count].concat()
            ]
            .concat()
        );
        assert_eq!(r.snapshot(100)["detail"]["status"], "采集不完整");
    }
}

#[test]
fn empty_failed_capture_preserves_actionable_permission_reason() {
    let p = Sandbox::new();
    let mut r = KoeRuntime::open(&p.0).unwrap();
    let t = begin(&mut r);
    event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_failed","message":"microphone permission denied"}),
    );
    event(
        &mut r,
        &t,
        "system",
        json!({"type":"microphone_failed","message":"system permission denied"}),
    );
    stop(&mut r, &t, "microphone", 0);
    let s = stop(&mut r, &t, "system", 0);
    assert!(s["notice"]
        .as_str()
        .unwrap()
        .contains("system permission denied"));
    assert!(s["notice"]
        .as_str()
        .unwrap()
        .contains("microphone permission denied"));
    assert!(r.workspace().records().is_empty());
}
