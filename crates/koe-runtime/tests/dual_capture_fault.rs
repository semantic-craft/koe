//! Real partial-write regression in a disposable child: never change the test runner's limits.
#![cfg(unix)]
#![allow(unsafe_code)]
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
fn send(r: &mut KoeRuntime, v: Value) -> Value {
    serde_json::from_str(&r.dispatch_json(&v.to_string(), 100)).unwrap()
}
fn event(r: &mut KoeRuntime, t: &Value, lane: &str, mut v: Value) -> Value {
    v["recordId"] = t["recordId"].clone();
    v["sessionId"] = t["sessionId"].clone();
    v["lane"] = json!(lane);
    send(r, v)
}
#[test]
fn append_retry_preserves_forced_stop_reason() {
    if std::env::var_os("KOE_APPEND_FAILURE_CHILD").is_none() {
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "append_retry_preserves_forced_stop_reason",
                "--nocapture",
            ])
            .env("KOE_APPEND_FAILURE_CHILD", "1")
            .output()
            .unwrap();
        assert!(
            result.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
        return;
    }

    let root = std::env::temp_dir().join(format!("koe-append-review-{}", std::process::id()));
    let mut r = KoeRuntime::open(&root).unwrap();
    let t = send(
        &mut r,
        json!({"type":"start_microphone","inputId":"fixture","includeSystem":true}),
    )["microphone"]
        .clone();
    for lane in ["microphone", "system"] {
        event(
            &mut r,
            &t,
            lane,
            json!({"type":"microphone_started","sampleRate":16000}),
        );
    }
    let mut previous = libc::rlimit {
        rlim_cur: 0,
        rlim_max: 0,
    };
    unsafe {
        assert_eq!(libc::getrlimit(libc::RLIMIT_FSIZE, &mut previous), 0);
        libc::signal(libc::SIGXFSZ, libc::SIG_IGN);
    }
    let limited = libc::rlimit {
        rlim_cur: 100,
        rlim_max: previous.rlim_max,
    };
    unsafe {
        assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &limited), 0);
    }
    let failed = event(
        &mut r,
        &t,
        "microphone",
        json!({"type":"microphone_chunk","sequence":0,"samples":vec![7;160]}),
    );
    unsafe {
        assert_eq!(libc::setrlimit(libc::RLIMIT_FSIZE, &previous), 0);
    }
    assert!(
        failed["error"].is_string(),
        "must reproduce a real append failure"
    );
    assert_eq!(failed["microphone"]["phase"], "stopping");
    for lane in ["microphone", "system"] {
        let s = event(
            &mut r,
            &t,
            lane,
            json!({"type":"microphone_chunk","sequence":0,"samples":vec![7;160]}),
        );
        assert!(s["error"].is_null(), "retry failed: {}", s["error"]);
    }
    for lane in ["microphone", "system"] {
        event(
            &mut r,
            &t,
            lane,
            json!({"type":"microphone_stopped","sequence":1}),
        );
    }
    let record = r
        .workspace()
        .record(t["recordId"].as_str().unwrap())
        .unwrap();
    let incomplete = record
        .capture_lanes
        .iter()
        .any(|l| l.interruption.is_some());
    assert_eq!(record.capture_lanes.len(), 2);
    for lane in &record.capture_lanes {
        let bytes = std::fs::read(
            root.join("audio")
                .join(format!("{}.wav", lane.asset_id.as_ref().unwrap())),
        )
        .unwrap();
        assert_eq!(&bytes[44..], vec![7i16.to_le_bytes(); 160].concat());
    }
    drop(r);
    std::fs::remove_dir_all(&root).unwrap();
    assert!(
        incomplete,
        "append failure forced an early session stop but saved outcomes claim complete capture"
    );
}
