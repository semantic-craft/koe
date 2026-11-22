#![allow(clippy::unwrap_used, clippy::expect_used)]

use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::{
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
};

struct Sandbox(PathBuf);
impl Sandbox {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "koe-product-flow-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn open(&self) -> KoeRuntime {
        KoeRuntime::open(&self.0).unwrap()
    }
}
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
fn command(runtime: &mut KoeRuntime, value: Value) -> Value {
    let result: Value =
        serde_json::from_str(&runtime.dispatch_json(&value.to_string(), 1800000000)).unwrap();
    assert!(result["error"].is_null(), "{}", result["error"]);
    result
}
fn note(runtime: &mut KoeRuntime, title: &str, text: &str) -> String {
    command(
        runtime,
        json!({"type":"create_note","title":title,"text":text}),
    )["selectedRecordId"]
        .as_str()
        .unwrap()
        .into()
}

#[test]
fn two_records_switch_and_reopen_without_mixing_transcripts() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();
    assert_eq!(runtime.snapshot(1800000000)["records"], json!([]));
    let first = note(&mut runtime, "Project Alpha", "Alpha delivery on Friday.");
    let second = note(&mut runtime, "Project Beta", "Beta review on Monday.");
    let selected = command(
        &mut runtime,
        json!({"type":"select_record","recordId":first}),
    );
    assert_eq!(selected["detail"]["segments"].as_array().unwrap().len(), 1);
    assert_eq!(
        selected["detail"]["segments"][0]["text"],
        "Alpha delivery on Friday."
    );
    drop(runtime);
    let mut reopened = dir.open();
    let selected = command(
        &mut reopened,
        json!({"type":"select_record","recordId":second}),
    );
    assert_eq!(
        selected["detail"]["segments"][0]["text"],
        "Beta review on Monday."
    );
    assert_eq!(selected["records"].as_array().unwrap().len(), 2);
}

#[test]
fn source_navigation_and_back_preserve_grounded_global_conversation() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();
    note(&mut runtime, "Blue", "蓝色原型用于首页。");
    let target = note(&mut runtime, "Orange", "橙色原型用于录音详情。");
    let answer = command(
        &mut runtime,
        json!({"type":"ask","question":"橙色","scope":"all","recordId":null}),
    );
    let message = answer["ask"]["messages"]
        .as_array()
        .unwrap()
        .last()
        .unwrap();
    assert_eq!(message["mode"], "retrieval");
    let source = &message["sources"][0];
    assert_eq!(source["recordId"], target);
    let opened = command(
        &mut runtime,
        json!({"type":"open_source","recordId":target,"segmentId":source["segmentId"]}),
    );
    assert_eq!(opened["section"], "detail");
    let back = command(&mut runtime, json!({"type":"back"}));
    assert_eq!(back["section"], "ask");
    assert_eq!(back["ask"]["messages"], answer["ask"]["messages"]);
    let scoped = command(
        &mut runtime,
        json!({"type":"ask","question":"蓝色","scope":"record","recordId":target}),
    );
    assert!(scoped["ask"]["messages"]
        .as_array()
        .unwrap()
        .last()
        .unwrap()["sources"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn reviewed_items_and_untimed_highlights_survive_reopen() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();
    let id = note(
        &mut runtime,
        "Planning",
        "Send the prototype Friday.\nKeep the interface simple.",
    );
    let task = command(
        &mut runtime,
        json!({"type":"create_task","recordId":id,"segmentId":"S1"}),
    )["tasks"][0]["id"]
        .clone();
    command(
        &mut runtime,
        json!({"type":"complete_task","itemId":task,"completed":true}),
    );
    command(
        &mut runtime,
        json!({"type":"save_memory","recordId":id,"segmentId":"S2"}),
    );
    command(
        &mut runtime,
        json!({"type":"add_highlight","recordId":id,"segmentId":"S2"}),
    );
    drop(runtime);
    let mut runtime = dir.open();
    let result = command(&mut runtime, json!({"type":"select_record","recordId":id}));
    assert_eq!(result["tasks"][0]["completed"], true);
    assert_eq!(result["memories"][0]["state"], "accepted");
    assert_eq!(result["detail"]["highlights"].as_array().unwrap().len(), 1);
    assert_eq!(result["detail"]["highlights"][0]["segmentId"], "S2");
}

#[test]
fn failed_save_is_visible_and_does_not_publish_uncommitted_record() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();
    std::fs::create_dir(dir.0.join("product-workspace.json")).unwrap();
    let value: Value = serde_json::from_str(&runtime.dispatch_json(
        r#"{"type":"create_note","title":"Blocked","text":"Must not be acknowledged"}"#,
        1800000000,
    ))
    .unwrap();
    assert!(value["error"].is_string());
    assert_eq!(value["records"], json!([]));
}

#[test]
fn only_the_current_scan_can_report_adapter_loss() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();
    let mut event = |kind, id| {
        command(
            &mut runtime,
            json!({"type":"device_event","event":kind,"connectionId":id}),
        )["device"]["phase"].clone()
    };
    assert_eq!(event("scanning", "first"), "scanning");
    assert_eq!(event("scanning", "retry"), "scanning");
    assert_eq!(event("disconnected", "first"), "scanning");
    assert_eq!(event("ready", "retry"), "scanning");
    assert_eq!(event("disconnected", "retry"), "disconnected");
}

#[test]
fn gatt_ready_generates_handshake_and_stale_disconnect_is_ignored() {
    let dir = Sandbox::new();
    let mut runtime = dir.open();
    command(
        &mut runtime,
        json!({"type":"device_event","event":"connecting","connectionId":"new"}),
    );
    command(
        &mut runtime,
        json!({"type":"device_event","event":"ready","connectionId":"new"}),
    );
    assert!(!runtime.drain_outbound_ble_frames().is_empty());
    let before = runtime.snapshot(1800000000)["device"]["state"].clone();
    let result = command(
        &mut runtime,
        json!({"type":"device_event","event":"disconnected","connectionId":"old"}),
    );
    assert_eq!(result["device"]["state"], before);
    let result = command(
        &mut runtime,
        json!({"type":"device_event","event":"disconnected","connectionId":"new"}),
    );
    assert_eq!(result["device"]["state"], "未连接");
}

#[test]
fn wav_import_and_markdown_export_are_real_files() {
    let dir = Sandbox::new();
    let input = dir.0.join("input.wav");
    let mut wav = koe_engine::wav::OpusWave::wav_header_with_rate(3200, 16000).to_vec();
    wav.extend(vec![0u8; 3200]);
    std::fs::write(&input, wav).unwrap();
    let mut runtime = dir.open();
    let imported = command(&mut runtime, json!({"type":"import_file","path":input}));
    assert_eq!(imported["detail"]["durationMs"], 100);
    assert!(std::path::Path::new(imported["detail"]["audioPath"].as_str().unwrap()).exists());
    let id = note(&mut runtime, "Export", "Original export content.");
    let output = dir.0.join("export.md");
    command(
        &mut runtime,
        json!({"type":"export_workspace_markdown","recordId":id,"path":output}),
    );
    assert!(std::fs::read_to_string(output)
        .unwrap()
        .contains("Original export content."));
}
