use koe_core::{
    Library,
    mcp::McpPublisher,
    recorder::{WavRecorder, write_pcm16le_wav},
};
use serde_json::{Value, json};
use std::{
    fs,
    io::{BufRead, BufReader, Write},
    process::{Command, Stdio},
};

#[test]
fn saves_manual_transcript_and_minutes_while_preserving_unknown_json_fields() {
    let dir = tempfile::tempdir().unwrap();
    let audio = dir.path().join("phone_1793836800000000.wav");
    write_pcm16le_wav(&audio, 16_000, 1, &[0, 1200, -1200, 0]).unwrap();

    fs::write(
        dir.path().join("recording_library.json"),
        json!({
            "version": 1,
            "customRootField": {"keep": true},
            "assets": [{
                "path": audio,
                "displayName": "产品评审录音",
                "source": "phone",
                "importedAt": "2026-11-05T08:00:00Z",
                "extraAssetField": 42
            }]
        })
        .to_string(),
    )
    .unwrap();

    fs::write(
        dir.path().join("transcripts.json"),
        json!({
            "version": 4,
            "futureTranscriptRoot": "keep-me",
            "byPath": {
                audio.to_str().unwrap(): "说话人 1：我们需要在本周完成桌面端录音与纪要整理。\n说话人 2：同意，周cf五前交付。"
            },
            "aliasesByPath": {
                audio.to_str().unwrap(): {"1": "林工", "2": "陈工"}
            }
        })
        .to_string(),
    )
    .unwrap();

    let mut library = Library::open(dir.path()).unwrap();
    assert_eq!(library.recordings.len(), 1);
    assert!(library.recordings[0].transcript.contains("林工："));

    library
        .save_manual_transcript(
            0,
            "说话人 1：本周完成 Rust 桌面端录音、纪要生成与 MCP 授权共享。\n说话人 2：确认，周五前由林工完成联调。",
        )
        .unwrap();

    let minutes = library.generate_minutes(0, "提炼会议纪要与行动项").unwrap();
    assert!(minutes["current"]["text"].as_str().is_some());

    let reopened = Library::open(dir.path()).unwrap();
    assert_eq!(
        reopened.recordings[0].transcript,
        "林工：本周完成 Rust 桌面端录音、纪要生成与 MCP 授权共享。\n陈工：确认，周五前由林工完成联调。"
    );
    assert!(reopened.recordings[0].minutes.is_some());
    let rendered = reopened.recordings[0].formatted_minutes().unwrap();
    assert!(rendered.contains("标题："));
    assert!(rendered.contains("概览："));

    let raw_transcripts: Value =
        serde_json::from_slice(&fs::read(dir.path().join("transcripts.json")).unwrap()).unwrap();
    assert_eq!(raw_transcripts["futureTranscriptRoot"], "keep-me");
    assert_eq!(
        raw_transcripts["byPath"][audio.to_str().unwrap()],
        "说话人 1：我们需要在本周完成桌面端录音与纪要整理。\n说话人 2：同意，周cf五前交付。"
    );

    let raw_catalog: Value =
        serde_json::from_slice(&fs::read(dir.path().join("recording_library.json")).unwrap())
            .unwrap();
    assert_eq!(raw_catalog["customRootField"]["keep"], true);
}

#[test]
fn records_synthetic_wav_and_registers_into_library_as_playable() {
    let dir = tempfile::tempdir().unwrap();
    let wav_path = dir.path().join("phone_1793836899000000.wav");
    let recorder = WavRecorder::start_synthetic(wav_path.clone(), 16_000, 440.0).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(120));
    let receipt = recorder.stop().unwrap();
    assert!(receipt.samples_written >= 800);
    assert_eq!(receipt.content_hash.len(), 64);

    let mut library = Library::open(dir.path()).unwrap();
    let idx = library
        .register_recording(&wav_path, "桌面麦克风录音", "localImport")
        .unwrap();
    assert!(library.recordings[idx].playable());
    assert_eq!(
        library.recordings[idx].recording_id().unwrap(),
        receipt.content_hash
    );

    let reopened = Library::open(dir.path()).unwrap();
    assert_eq!(reopened.recordings.len(), 1);
    assert_eq!(reopened.recordings[0].display_name, "桌面麦克风录音");
    assert!(reopened.recordings[0].playable());
}

#[test]
fn publishes_session_leased_mcp_records_and_serves_stdio_jsonrpc() {
    let dir = tempfile::tempdir().unwrap();
    let live_dir = dir.path().join("mcp-live");
    fs::create_dir_all(&live_dir).unwrap();

    let audio = dir.path().join("phone_1793836900000000.wav");
    write_pcm16le_wav(&audio, 16_000, 1, &[100, -100, 200, -200]).unwrap();

    let mut library = Library::open(dir.path()).unwrap();
    let idx = library
        .register_recording(&audio, "MCP 联调录音", "phone")
        .unwrap();
    library
        .save_manual_transcript(idx, "林工：确认 MCP 只在当前会话授权时暴露。")
        .unwrap();
    library.generate_minutes(idx, "整理纪要").unwrap();
    let rec_id = library.recordings[idx].recording_id().unwrap();

    let mut publisher = McpPublisher::new();
    assert!(!publisher.is_granted(&rec_id));
    publisher.grant(&rec_id);
    let pub_receipt = publisher.publish_live(&library, &live_dir, 15).unwrap();
    assert_eq!(pub_receipt.generation, 1);
    assert!(live_dir.join("live.json").is_file());

    let bin = std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("koe-pack");
    if !bin.is_file() {
        let status = Command::new("cargo")
            .args([
                "build",
                "--locked",
                "--manifest-path",
                concat!(env!("CARGO_MANIFEST_DIR"), "/../Cargo.toml"),
                "--bin",
                "koe-pack",
            ])
            .status()
            .unwrap();
        assert!(status.success());
    }
    let mut child = Command::new(&bin)
        .args(["mcp", "--live-directory", live_dir.to_str().unwrap()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    let mut stdout = BufReader::new(child.stdout.take().unwrap());

    fn rpc(
        stdin: &mut std::process::ChildStdin,
        stdout: &mut BufReader<std::process::ChildStdout>,
        req: Value,
    ) -> Value {
        writeln!(stdin, "{req}").unwrap();
        stdin.flush().unwrap();
        let mut line = String::new();
        stdout.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    }

    let init = rpc(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "1.0"}
            }
        }),
    );
    assert_eq!(init["result"]["serverInfo"]["name"], "koe-live-mcp");
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
    )
    .unwrap();
    stdin.flush().unwrap();

    let list = rpc(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "list_recordings", "arguments": {}}
        }),
    );
    let list_payload: Value =
        serde_json::from_str(list["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(list_payload["snapshotRevision"], "1");
    assert_eq!(list_payload["recordings"].as_array().unwrap().len(), 1);
    let listed_id = list_payload["recordings"][0]["recording_id"]
        .as_str()
        .unwrap()
        .to_owned();
    assert_eq!(listed_id, rec_id);

    let transcript = rpc(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc": "2.0",
            "id": 3,
            "method": "tools/call",
            "params": {
                "name": "get_transcript",
                "arguments": {"recording_id": listed_id, "expected_revision": "1"}
            }
        }),
    );
    let transcript_payload: Value =
        serde_json::from_str(transcript["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert!(
        transcript_payload["text"]
            .as_str()
            .unwrap()
            .contains("确认 MCP 只在当前会话授权时暴露")
    );

    let minutes = rpc(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc": "2.0",
            "id": 4,
            "method": "tools/call",
            "params": {
                "name": "get_minutes",
                "arguments": {"recording_id": listed_id, "expected_revision": "1"}
            }
        }),
    );
    let minutes_payload: Value =
        serde_json::from_str(minutes["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(minutes_payload["freshness"], "current");

    let py_server = std::path::Path::new(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tools/koe-mcp/server.py"
    ));
    let mut py_child = Command::new("python3")
        .args([
            py_server.to_str().unwrap(),
            "--directory",
            live_dir.to_str().unwrap(),
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut py_in = py_child.stdin.take().unwrap();
    let mut py_out = BufReader::new(py_child.stdout.take().unwrap());
    let _ = rpc(
        &mut py_in,
        &mut py_out,
        json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-11-25",
                "capabilities": {},
                "clientInfo": {"name": "test", "version": "1.0"}
            }
        }),
    );
    writeln!(
        py_in,
        "{}",
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"})
    )
    .unwrap();
    py_in.flush().unwrap();
    let py_list = rpc(
        &mut py_in,
        &mut py_out,
        json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {"name": "list_recordings", "arguments": {}}
        }),
    );
    let py_list_payload: Value =
        serde_json::from_str(py_list["result"]["content"][0]["text"].as_str().unwrap()).unwrap();
    assert_eq!(py_list_payload["recordings"].as_array().unwrap().len(), 1);
    assert_eq!(py_list_payload["recordings"][0]["title"], "MCP 联调录音");
    drop(py_in);
    let _ = py_child.wait();

    library
        .save_manual_transcript(idx, "林工：正文已改但纪要未重跑。")
        .unwrap();
    publisher.publish_live(&library, &live_dir, 15).unwrap();

    let stale_rev = rpc(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc": "2.0",
            "id": 5,
            "method": "tools/call",
            "params": {
                "name": "get_minutes",
                "arguments": {"recording_id": listed_id, "expected_revision": "1"}
            }
        }),
    );
    assert_eq!(stale_rev["result"]["isError"], true);
    assert!(
        stale_rev["result"]["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("snapshot_changed")
    );

    let stale_minutes = rpc(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": {
                "name": "get_minutes",
                "arguments": {"recording_id": listed_id, "expected_revision": "2"}
            }
        }),
    );
    let stale_payload: Value = serde_json::from_str(
        stale_minutes["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(stale_payload["freshness"], "stale");

    publisher.revoke(&rec_id);
    publisher.publish_live(&library, &live_dir, 15).unwrap();
    let after_revoke = rpc(
        &mut stdin,
        &mut stdout,
        json!({
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {"name": "list_recordings", "arguments": {}}
        }),
    );
    let revoked_payload: Value = serde_json::from_str(
        after_revoke["result"]["content"][0]["text"]
            .as_str()
            .unwrap(),
    )
    .unwrap();
    assert_eq!(revoked_payload["recordings"].as_array().unwrap().len(), 0);

    drop(stdin);
    let _ = child.wait();
}
