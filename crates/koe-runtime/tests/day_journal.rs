use koe_runtime::KoeRuntime;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicU64, Ordering};

const TODAY: u64 = 1_768_478_400;

fn runtime() -> (KoeRuntime, Sandbox) {
    static NEXT: AtomicU64 = AtomicU64::new(0);
    let path = std::env::temp_dir().join(format!(
        "koe-journal-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir(&path).unwrap();
    (KoeRuntime::open(&path).unwrap(), Sandbox(path))
}

struct Sandbox(std::path::PathBuf);
impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn send_at(runtime: &mut KoeRuntime, now: u64, command: Value) -> Value {
    let snapshot: Value =
        serde_json::from_str(&runtime.dispatch_json(&command.to_string(), now)).unwrap();
    assert!(snapshot["error"].is_null(), "{}", snapshot["error"]);
    snapshot
}

fn send(runtime: &mut KoeRuntime, command: Value) -> Value {
    send_at(runtime, TODAY, command)
}

#[test]
fn meeting_keeps_live_minutes_across_ask_and_record_navigation() {
    let (mut runtime, sandbox) = runtime();
    let empty = send(&mut runtime, json!({"type":"navigate","section":"live_minutes"}));
    assert_eq!(empty["section"], "live_minutes");
    assert!(empty["liveMinutes"].is_null());
    let imported = sandbox.0.join("历史材料.txt");
    std::fs::write(&imported, "历史材料不属于本次录音").unwrap();
    let note = send(&mut runtime, json!({"type":"import_file","path":imported}));
    assert!(note["liveMinutes"].is_null());
    let unrelated = note["selectedRecordId"].clone();

    let started = send(&mut runtime, json!({"type":"start_capture_mode","mode":"meeting"}));
    assert_eq!(started["section"], "live_minutes");
    let scope = &started["liveMinutes"]["scope"];
    assert_eq!(scope, &json!({"kind":"record","id":started["microphone"]["recordId"]}));
    for destination in ["ask", "live_minutes"] {
        let snapshot = send(&mut runtime, json!({"type":"navigate","section":destination}));
        assert_eq!(snapshot["section"], destination);
        assert_eq!(&snapshot["liveMinutes"]["scope"], scope);
    }
    let detail = send(&mut runtime, json!({"type":"select_record","recordId":unrelated}));
    assert_eq!(detail["selectedRecordId"], unrelated);
    assert_eq!(&detail["liveMinutes"]["scope"], scope);
    assert_eq!(detail["liveMinutes"]["parts"], json!([]));
}

#[test]
fn capture_modes_use_the_existing_microphone_across_navigation() {
    for mode in ["quick_note", "meeting", "dictation", "all_day"] {
        let (mut runtime, _sandbox) = runtime();
        let snapshot = send(
            &mut runtime,
            json!({"type":"start_capture_mode","mode":mode}),
        );
        let microphone = &snapshot["microphone"];
        assert!(microphone["sessionId"].is_string());
        assert_eq!(snapshot["activeCapture"]["mode"], mode);
        assert_eq!(snapshot["dictation"]["active"], mode == "dictation");

        let snapshot = send(&mut runtime, json!({"type":"navigate","section":"notes"}));
        assert_eq!(snapshot["section"], "notes");
        assert_eq!(snapshot["microphone"]["sessionId"], microphone["sessionId"]);
        assert_eq!(snapshot["activeCapture"]["mode"], mode);
        let mut epoch = 0;
        if mode == "all_day" {
            send(
                &mut runtime,
                json!({"type":"microphone_prepared","recordId":microphone["recordId"],"sessionId":microphone["sessionId"],"epoch":0,"clockNs":1_000_000_000_u64}),
            );
            send(
                &mut runtime,
                json!({"type":"microphone_started","recordId":microphone["recordId"],"sessionId":microphone["sessionId"],"lane":"microphone","sampleRate":16000}),
            );
            let snapshot = send(
                &mut runtime,
                json!({"type":"start_capture_mode","mode":"dictation"}),
            );
            assert_eq!(snapshot["activeCapture"]["mode"], "all_day");
            assert_eq!(snapshot["dictation"]["active"], true);
            let snapshot = send(
                &mut runtime,
                json!({"type":"capture_action","action":"end_dictation"}),
            );
            assert_eq!(snapshot["dictation"]["active"], false);
            assert_eq!(snapshot["allDay"]["state"], "recording");
            assert_eq!(snapshot["microphone"]["sessionId"], microphone["sessionId"]);
            assert_eq!(snapshot["microphone"]["phase"], "recording");
            send(
                &mut runtime,
                json!({"type":"start_capture_mode","mode":"dictation"}),
            );
            let pausing = send(
                &mut runtime,
                json!({"type":"capture_action","action":"pause"}),
            );
            assert_eq!(pausing["dictation"]["active"], true);
            let paused = send(
                &mut runtime,
                json!({"type":"microphone_paused","recordId":microphone["recordId"],"sessionId":microphone["sessionId"],"lane":"microphone","sequence":0,"epoch":0}),
            );
            assert_eq!(paused["dictation"]["active"], false);
            assert_eq!(paused["activeCapture"]["actions"], json!(["resume", "end"]));
            let resumed = send(
                &mut runtime,
                json!({"type":"resume_microphone","clockNs":2_000_000_000_u64}),
            );
            assert_eq!(resumed["activeCapture"]["phase"], "recording");
            assert_eq!(resumed["dictation"]["active"], false);
            epoch = 1;
        }

        let snapshot = send(
            &mut runtime,
            json!({"type":"capture_action","action":"end"}),
        );
        assert_eq!(snapshot["microphone"]["phase"], "stopping");
        let snapshot = send(
            &mut runtime,
            json!({"type":"microphone_stopped","recordId":microphone["recordId"],"sessionId":microphone["sessionId"],"lane":"microphone","sequence":0,"epoch":epoch}),
        );
        assert!(snapshot["activeCapture"].is_null());
        assert_eq!(snapshot["dictation"]["active"], false);
        assert_eq!(snapshot["section"], "notes");
    }
}

#[test]
fn journal_rolls_to_the_current_day_without_hiding_prior_notes() {
    let (mut runtime, _sandbox) = runtime();
    send_at(
        &mut runtime,
        TODAY - 86_400,
        json!({"type":"create_note","title":"昨天","text":"昨天的原文"}),
    );
    let snapshot = send(
        &mut runtime,
        json!({"type":"create_note","title":"今天","text":"今天的原文"}),
    );
    let today_id = snapshot["selectedRecordId"].clone();
    let today_date = snapshot["workspaces"]["allDay"]["selectedDate"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(snapshot["records"][0]["id"], today_id);
    assert!(snapshot["workspaces"]["allDay"]["dailyReview"].is_null());
    assert_eq!(
        snapshot["workspaces"]["quickNote"]["cards"]
            .as_array()
            .unwrap()
            .len(),
        2
    );

    let old_generation = runtime.generation();
    runtime.ingest_ble_chunk(&[0x09], TODAY + 86_400);
    runtime.poll_timers(250, TODAY + 86_400);
    let snapshot = runtime.snapshot(TODAY + 86_400);
    assert!(runtime.generation() > old_generation);
    assert_ne!(
        snapshot["workspaces"]["allDay"]["selectedDate"],
        json!(today_date)
    );
    assert_eq!(snapshot["records"].as_array().unwrap().len(), 2);
    assert_eq!(
        snapshot["workspaces"]["quickNote"]["cards"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
}

#[test]
fn imported_text_appears_in_notes_with_its_real_text() {
    let (mut runtime, sandbox) = runtime();
    let text = sandbox.0.join("Field notes.txt");
    std::fs::write(&text, "现场留下的原文").unwrap();
    let snapshot = send(&mut runtime, json!({"type":"import_file","path":text}));
    assert_eq!(
        snapshot["workspaces"]["quickNote"]["cards"][0]["id"],
        snapshot["selectedRecordId"]
    );
    assert_eq!(snapshot["records"][0]["preview"], "现场留下的原文");
}
