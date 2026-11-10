use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};

use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

struct Workspace(PathBuf);
impl Workspace {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Self(std::env::temp_dir().join(format!(
            "koe-cli-process-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )))
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cli(path: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(args)
        .arg("--workspace")
        .arg(path)
        .output()
        .unwrap()
}

fn note_fixture(path: &Path) -> String {
    let mut runtime = KoeRuntime::open(path).unwrap();
    let result: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type":"create_note", "title":"周五交付", "text":"周五交付原生界面，保留录音来源。"
            })
            .to_string(),
            1_775_000_000,
        ),
    )
    .unwrap();
    assert!(result["error"].is_null(), "{result}");
    result["detail"]["id"].as_str().unwrap().into()
}

#[test]
fn cli_reads_native_store_and_returns_navigable_sources() {
    let workspace = Workspace::new();
    let id = note_fixture(&workspace.0);
    let status = cli(&workspace.0, &["status"]);
    assert!(
        status.status.success(),
        "{}",
        String::from_utf8_lossy(&status.stderr)
    );
    let status: Value = serde_json::from_slice(&status.stdout).unwrap();
    assert_eq!(status["records"][0]["id"], id);
    let search = cli(&workspace.0, &["search", "原生界面"]);
    assert!(search.status.success());
    let search: Value = serde_json::from_slice(&search.stdout).unwrap();
    assert_eq!(search["sources"][0]["recordId"], id);
    assert_eq!(search["sources"][0]["segmentId"], "S1");
    let ask = cli(&workspace.0, &["ask", "原生界面"]);
    assert!(
        ask.status.success(),
        "{}",
        String::from_utf8_lossy(&ask.stderr)
    );
    let ask: Value = serde_json::from_slice(&ask.stdout).unwrap();
    assert_eq!(ask["phase"], "ready");
    assert_eq!(
        ask["messages"].as_array().unwrap().last().unwrap()["mode"],
        "retrieval"
    );
    let reopened = KoeRuntime::open(&workspace.0).unwrap();
    assert!(!reopened.workspace().ask_session().messages.is_empty());
}

#[test]
fn occupied_store_fails_without_inventing_an_empty_library() {
    let workspace = Workspace::new();
    let _owner = KoeRuntime::open(&workspace.0).unwrap();
    let output = cli(&workspace.0, &["status"]);
    assert!(!output.status.success());
    assert!(output.stdout.is_empty());
    let error: Value = serde_json::from_slice(&output.stderr).unwrap();
    assert!(error["error"].as_str().unwrap().contains("占用"));
}

#[test]
fn mcp_exposes_only_connected_tools_and_reads_the_same_record() {
    let workspace = Workspace::new();
    let id = note_fixture(&workspace.0);
    let mut process = Command::new(env!("CARGO_BIN_EXE_koe"))
        .args(["mcp-stdio", "--workspace"])
        .arg(&workspace.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let mut input = process.stdin.take().unwrap();
    for request in [
        json!({"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}),
        json!({"jsonrpc":"2.0","method":"notifications/initialized"}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/list"}),
        json!({"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_record","arguments":{"record_id":id}}}),
        json!({"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"google_tasks_sync","arguments":{}}}),
    ] {
        writeln!(input, "{request}").unwrap();
    }
    drop(input);
    let output = process.wait_with_output().unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let responses: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(responses.len(), 4);
    let names: Vec<_> = responses[1]["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|tool| tool["name"].as_str().unwrap())
        .collect();
    assert_eq!(names, ["search", "get_record", "ask"]);
    let record: Value = serde_json::from_str(
        responses[2]["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(record["id"], id);
    assert_eq!(
        record["segments"][0]["text"],
        "周五交付原生界面，保留录音来源。"
    );
    assert!(responses[3]["error"].is_object());
}

#[test]
fn protocol_verification_does_not_create_workspace_data() {
    let workspace = Workspace::new();
    let output = cli(&workspace.0, &["verify-protocol"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let receipt: Value = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(receipt["status"], "ok");
    assert_eq!(receipt["hardwareVerified"], false);
    assert!(!workspace.0.exists());
}
