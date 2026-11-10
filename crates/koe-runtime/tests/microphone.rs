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
        let path = std::env::temp_dir().join(format!(
            "koe-mic-{}-{}",
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
fn send(r: &mut KoeRuntime, v: Value) -> Value {
    serde_json::from_str(&r.dispatch_json(&v.to_string(), 100)).unwrap()
}
fn begin(r: &mut KoeRuntime) -> Value {
    let s = send(r, json!({"type":"start_microphone","inputId":"fixture"}));
    assert!(s["error"].is_null(), "{}", s["error"]);
    s["microphone"].clone()
}
fn event(r: &mut KoeRuntime, ticket: &Value, mut v: Value) -> Value {
    for key in ["recordId", "sessionId", "lane"] {
        v[key] = ticket[key].clone();
    }
    send(r, v)
}
fn started(r: &mut KoeRuntime) -> Value {
    let t = begin(r);
    let s = event(
        r,
        &t,
        json!({"type":"microphone_started","sampleRate":16000}),
    );
    assert!(s["error"].is_null(), "{}", s["error"]);
    t
}
fn chunk(r: &mut KoeRuntime, t: &Value, seq: u64, samples: Vec<i16>) -> Value {
    event(
        r,
        t,
        json!({"type":"microphone_chunk","sequence":seq,"samples":samples}),
    )
}
fn finish(r: &mut KoeRuntime, t: &Value, seq: u64) -> Value {
    send(r, json!({"type":"stop_microphone"}));
    event(r, t, json!({"type":"microphone_stopped","sequence":seq}))
}
#[test]
fn denied_permission_creates_no_record_and_releases_activity() {
    let root = Sandbox::new();
    let mut r = KoeRuntime::open(&root.0).unwrap();
    let t = begin(&mut r);
    assert_eq!(r.snapshot(100)["lifecycle"]["keepAwake"], true);
    event(
        &mut r,
        &t,
        json!({"type":"microphone_failed","message":"权限被拒绝"}),
    );
    event(
        &mut r,
        &t,
        json!({"type":"microphone_stopped","sequence":0}),
    );
    assert!(r.workspace().records().is_empty());
    assert_eq!(r.snapshot(100)["lifecycle"]["keepAwake"], false);
}
#[test]
fn stop_waits_for_final_block_and_reopens_exact_audio() {
    let root = Sandbox::new();
    let mut r = KoeRuntime::open(&root.0).unwrap();
    let t = started(&mut r);
    chunk(&mut r, &t, 0, vec![100; 160]);
    send(&mut r, json!({"type":"request_quit"}));
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "draining");
    assert!(event(
        &mut r,
        &t,
        json!({"type":"microphone_stopped","sequence":2})
    )["error"]
        .is_string());
    chunk(&mut r, &t, 1, vec![200; 160]);
    let s = event(
        &mut r,
        &t,
        json!({"type":"microphone_stopped","sequence":2}),
    );
    assert_eq!(s["lifecycle"]["quitPhase"], "ready");
    let id = t["recordId"].as_str().unwrap();
    assert_eq!(r.workspace().record(id).unwrap().aggregate.duration_ms, 20);
    let bytes = fs::read(root.0.join("audio").join(format!("{id}.wav"))).unwrap();
    assert_eq!(&bytes[44..364], vec![100i16.to_le_bytes(); 160].concat());
    assert_eq!(&bytes[364..], vec![200i16.to_le_bytes(); 160].concat());
    drop(r);
    let r = KoeRuntime::open(&root.0).unwrap();
    assert!(r.workspace().record(id).is_some());
}
#[test]
fn out_of_order_wrong_lane_and_old_session_do_not_cross_records() {
    let root = Sandbox::new();
    let mut r = KoeRuntime::open(&root.0).unwrap();
    let old = started(&mut r);
    assert!(chunk(&mut r, &old, 1, vec![9; 160])["error"].is_string());
    let mut wrong = old.clone();
    wrong["lane"] = json!("system");
    chunk(&mut r, &wrong, 0, vec![9; 160]);
    assert_eq!(r.snapshot(100)["microphone"]["nextSequence"], 0);
    chunk(&mut r, &old, 0, vec![1; 160]);
    finish(&mut r, &old, 1);
    let new = started(&mut r);
    assert_ne!(new["sessionId"], old["sessionId"]);
    chunk(&mut r, &old, 1, vec![9; 160]);
    event(
        &mut r,
        &old,
        json!({"type":"microphone_failed","message":"late"}),
    );
    assert_eq!(r.snapshot(100)["microphone"]["nextSequence"], 0);
    assert_eq!(r.snapshot(100)["microphone"]["phase"], "recording");
    chunk(&mut r, &new, 0, vec![2; 160]);
    finish(&mut r, &new, 1);
    assert_eq!(r.workspace().records().len(), 2);
}
#[test]
fn failed_commit_blocks_quit_cancel_quit_preserves_audio_for_retry() {
    let root = Sandbox::new();
    let mut r = KoeRuntime::open(&root.0).unwrap();
    let t = started(&mut r);
    chunk(&mut r, &t, 0, vec![3; 160]);
    let file = root.0.join("product-workspace.json");
    if file.exists() {
        fs::remove_file(&file).unwrap();
    }
    fs::create_dir(&file).unwrap();
    send(&mut r, json!({"type":"request_quit"}));
    event(
        &mut r,
        &t,
        json!({"type":"microphone_stopped","sequence":1}),
    );
    r.poll_timers(250, 100);
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "blocked");
    assert!(r.workspace().records().is_empty());
    send(&mut r, json!({"type":"cancel_quit"}));
    assert_eq!(r.snapshot(100)["microphone"]["recordId"], t["recordId"]);
    fs::remove_dir(&file).unwrap();
    send(&mut r, json!({"type":"retry_microphone_save"}));
    assert!(r
        .workspace()
        .record(t["recordId"].as_str().unwrap())
        .is_some());
    assert_eq!(r.snapshot(100)["lifecycle"]["keepAwake"], false);
    started(&mut r);
}
#[test]
fn cancel_waits_for_producer_then_discards_without_success_record() {
    let root = Sandbox::new();
    let mut r = KoeRuntime::open(&root.0).unwrap();
    let t = started(&mut r);
    chunk(&mut r, &t, 0, vec![3; 160]);
    send(&mut r, json!({"type":"cancel_microphone"}));
    send(&mut r, json!({"type":"request_quit"}));
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "draining");
    chunk(&mut r, &t, 1, vec![4; 160]);
    event(
        &mut r,
        &t,
        json!({"type":"microphone_stopped","sequence":2}),
    );
    assert!(r.workspace().records().is_empty());
    assert_eq!(r.snapshot(100)["lifecycle"]["quitPhase"], "ready");
}
#[test]
fn oversize_chunk_rejected_without_advancing_and_default_local_only() {
    let root = Sandbox::new();
    let mut r = KoeRuntime::open(&root.0).unwrap();
    let t = started(&mut r);
    assert!(chunk(&mut r, &t, 0, vec![1; 8193])["error"].is_string());
    assert_eq!(r.snapshot(100)["microphone"]["nextSequence"], 0);
    chunk(&mut r, &t, 0, vec![1; 160]);
    finish(&mut r, &t, 1);
    let s = send(
        &mut r,
        json!({"type":"transcribe","recordId":t["recordId"]}),
    );
    assert!(s["error"].as_str().unwrap().contains("本机"));
}
