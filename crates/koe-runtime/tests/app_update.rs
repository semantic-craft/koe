#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::io::{Read, Write};
use std::net::TcpListener;
use std::time::{Duration, Instant};

use koe_engine::{KOE_APP_BUILD, KOE_APP_VERSION, KOE_GITHUB_RELEASES_URL};
use koe_runtime::KoeRuntime;
use serde_json::{json, Value};

fn temp_workspace(tag: &str) -> std::path::PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "koe-app-update-{tag}-{}-{nanos}",
        std::process::id()
    ));
    std::fs::create_dir_all(&dir).expect("create temp workspace");
    dir
}

fn accept_http_sequence(
    listener: TcpListener,
    responses: Vec<(&'static str, String)>,
) -> std::thread::JoinHandle<Vec<String>> {
    std::thread::spawn(move || {
        let mut requests = Vec::with_capacity(responses.len());
        for (status_line, body) in responses {
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut stream = loop {
                match listener.accept() {
                    Ok((stream, _)) => break stream,
                    Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(
                            Instant::now() < deadline,
                            "update HTTP request never arrived"
                        );
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(err) => panic!("accept failed: {err}"),
                }
            };
            stream
                .set_nonblocking(false)
                .expect("restore blocking stream");
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .expect("set read timeout");

            let mut req_bytes = Vec::new();
            let mut buf = [0u8; 4096];
            loop {
                let n = stream.read(&mut buf).expect("read request");
                assert!(n > 0, "unexpected EOF before HTTP headers");
                req_bytes.extend_from_slice(&buf[..n]);
                if req_bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                    break;
                }
            }
            requests.push(String::from_utf8_lossy(&req_bytes).into_owned());
            write!(
                stream,
                "HTTP/1.1 {status_line}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .expect("write HTTP response");
        }
        requests
    })
}

fn accept_http_once(
    listener: TcpListener,
    status_line: &'static str,
    body: String,
) -> std::thread::JoinHandle<String> {
    let handle = accept_http_sequence(listener, vec![(status_line, body)]);
    std::thread::spawn(move || {
        handle
            .join()
            .expect("join sequence")
            .into_iter()
            .next()
            .expect("single request")
    })
}

fn poll_until_settled(runtime: &mut KoeRuntime, now_sec: u64) -> Value {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        runtime.poll_timers(50, now_sec);
        let snap = runtime.snapshot(now_sec);
        if snap["appUpdate"]["phase"] != "checking" {
            return snap;
        }
        assert!(
            Instant::now() < deadline,
            "appUpdate stayed in checking phase"
        );
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn initial_snapshot_and_doctor_expose_compiled_version_without_network_activity() {
    let root = temp_workspace("initial");
    let mut runtime = KoeRuntime::open(&root).expect("open runtime");

    let snap = runtime.snapshot(1_800_000_000);
    assert_eq!(snap["appUpdate"]["currentVersion"], KOE_APP_VERSION);
    assert_eq!(snap["appUpdate"]["currentBuild"], KOE_APP_BUILD);
    assert_eq!(snap["appUpdate"]["phase"], "idle");
    assert_eq!(snap["appUpdate"]["releaseUrl"], KOE_GITHUB_RELEASES_URL);
    assert!(snap["appUpdate"]["checkedAtEpochSec"].is_null());

    let doctor = runtime.doctor_snapshot(1_800_000_010);
    assert_eq!(doctor["workspaceReadable"], true);
    assert_eq!(doctor["version"], KOE_APP_VERSION);
    assert_eq!(doctor["build"], KOE_APP_BUILD);
    assert_eq!(doctor["appUpdate"]["phase"], "idle");

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn check_app_update_detects_newer_semver_and_reconciles_when_bundle_metadata_advances() {
    let root = temp_workspace("available");
    let mut runtime = KoeRuntime::open(&root).expect("open runtime");

    let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback");
    listener
        .set_nonblocking(true)
        .expect("nonblocking listener");
    let addr = listener.local_addr().expect("local addr");
    let endpoint = format!("http://{addr}/repos/semantic-craft/koe/releases/latest");
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
    let asset_name = format!("Koe-2.10.0-macos-{arch}.zip");
    let download_url =
        format!("https://github.com/semantic-craft/koe/releases/download/v2.10.0/{asset_name}");
    let payload = json!({
        "tag_name": "v2.10.0",
        "name": "Koe 2.10.0 (20)",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-11-19T02:00:00Z",
        "html_url": "https://github.com/semantic-craft/koe/releases/tag/v2.10.0",
        "body": "## 更新亮点\n- 新增检查更新与版本号显示",
        "assets": [
            {
                "name": asset_name,
                "size": 7_687_514,
                "browser_download_url": download_url
            }
        ]
    })
    .to_string();

    let server = accept_http_sequence(
        listener,
        vec![
            ("200 OK", payload),
            ("500 Internal Server Error", "{}".into()),
        ],
    );

    let sync_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "sync_app_metadata",
                "version": "2.9.0",
                "build": "19",
                "updateEndpoint": endpoint,
            })
            .to_string(),
            1_800_000_100,
        ),
    )
    .expect("parse sync snapshot");
    assert!(sync_snap["error"].is_null());
    assert_eq!(sync_snap["appUpdate"]["currentVersion"], "2.9.0");
    assert_eq!(sync_snap["appUpdate"]["currentBuild"], "19");

    let checking_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(r#"{"type":"check_app_update"}"#, 1_800_000_105),
    )
    .expect("parse checking snapshot");
    assert_eq!(checking_snap["appUpdate"]["phase"], "checking");

    let dup_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(r#"{"type":"check_app_update"}"#, 1_800_000_106),
    )
    .expect("parse duplicate checking snapshot");
    assert!(dup_snap["error"].is_null());
    assert_eq!(dup_snap["appUpdate"]["phase"], "checking");

    let settled = poll_until_settled(&mut runtime, 1_800_000_110);
    assert!(settled["error"].is_null());
    assert_eq!(settled["appUpdate"]["phase"], "available");
    assert_eq!(settled["appUpdate"]["latestVersion"], "2.10.0");
    assert_eq!(settled["appUpdate"]["releaseTitle"], "Koe 2.10.0 (20)");
    assert_eq!(settled["appUpdate"]["assetName"], asset_name);
    assert_eq!(settled["appUpdate"]["assetSizeBytes"], 7_687_514);
    assert_eq!(settled["appUpdate"]["downloadUrl"], download_url);
    assert_eq!(settled["appUpdate"]["checkedAtEpochSec"], 1_800_000_110);
    assert!(settled["notice"]
        .as_str()
        .is_some_and(|s| s.contains("v2.10.0")));

    let upgraded: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "sync_app_metadata",
                "version": "2.10.0",
                "build": "20"
            })
            .to_string(),
            1_800_000_120,
        ),
    )
    .expect("parse upgraded snapshot");
    assert_eq!(upgraded["appUpdate"]["phase"], "up_to_date");
    assert_eq!(upgraded["appUpdate"]["currentVersion"], "2.10.0");
    assert!(
        upgraded["notice"].is_null(),
        "stale update-available notice must clear when bundle metadata advances to up_to_date: {:?}",
        upgraded["notice"]
    );
    assert!(upgraded["appUpdate"]["message"]
        .as_str()
        .is_some_and(|m| m.contains("已是最新版本")));

    let _ = runtime.dispatch_json(r#"{"type":"check_app_update"}"#, 1_800_000_125);
    let failed_snap = poll_until_settled(&mut runtime, 1_800_000_130);
    let raw_requests = server.join().expect("server thread");
    assert_eq!(raw_requests.len(), 2);
    assert!(raw_requests[0].contains("GET /repos/semantic-craft/koe/releases/latest HTTP/1.1"));
    assert!(raw_requests[0]
        .to_ascii_lowercase()
        .contains("user-agent: koe/2.9.0"));
    assert!(!raw_requests[0]
        .to_ascii_lowercase()
        .contains("authorization:"));

    assert_eq!(failed_snap["appUpdate"]["phase"], "failed");
    let resynced_after_fail: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "sync_app_metadata",
                "version": "2.10.0",
                "build": "21"
            })
            .to_string(),
            1_800_000_135,
        ),
    )
    .expect("parse resynced after fail");
    assert_eq!(
        resynced_after_fail["appUpdate"]["phase"], "failed",
        "sync_app_metadata must not overwrite Failed outcome with stale cached release"
    );
    assert_eq!(resynced_after_fail["appUpdate"]["currentBuild"], "21");

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn private_repo_404_reports_unavailable_without_global_error_and_quit_cancels_inflight_check() {
    let root = temp_workspace("unavailable-and-quit");
    let mut runtime = KoeRuntime::open(&root).expect("open runtime");

    let listener_404 = TcpListener::bind("127.0.0.1:0").expect("bind 404");
    listener_404.set_nonblocking(true).expect("nonblocking");
    let endpoint_404 = format!(
        "http://{}/releases/latest",
        listener_404.local_addr().unwrap()
    );
    let server_404 = accept_http_once(
        listener_404,
        "404 Not Found",
        r#"{"message":"Not Found","secret":"should-never-echo"}"#.into(),
    );

    let _ = runtime.dispatch_json(
        &json!({
            "type": "sync_app_metadata",
            "version": "2.3.0",
            "build": "12",
            "updateEndpoint": endpoint_404,
        })
        .to_string(),
        1_800_000_200,
    );
    let _ = runtime.dispatch_json(r#"{"type":"check_app_update"}"#, 1_800_000_201);
    let snap_404 = poll_until_settled(&mut runtime, 1_800_000_205);
    let _ = server_404.join().expect("join 404 server");

    assert!(snap_404["error"].is_null());
    assert_eq!(snap_404["appUpdate"]["phase"], "unavailable");
    let msg = snap_404["appUpdate"]["message"]
        .as_str()
        .expect("unavailable message");
    assert!(!msg.contains("should-never-echo"));
    assert!(msg.contains("发行页面"));

    let hanging_listener = TcpListener::bind("127.0.0.1:0").expect("bind hanging");
    hanging_listener
        .set_nonblocking(true)
        .expect("nonblocking hanging");
    let endpoint_hang = format!(
        "http://{}/releases/latest",
        hanging_listener.local_addr().unwrap()
    );
    let (accepted_tx, accepted_rx) = std::sync::mpsc::channel();
    let (closed_tx, closed_rx) = std::sync::mpsc::channel();
    let hang_server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match hanging_listener.accept() {
                Ok((stream, _)) => break stream,
                Err(err) if err.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "hanging update HTTP request never arrived"
                    );
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(err) => panic!("accept hang failed: {err}"),
            }
        };
        stream
            .set_nonblocking(false)
            .expect("restore blocking hang stream");
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .expect("set timeout");
        let mut buf = [0u8; 2048];
        assert!(stream.read(&mut buf).expect("read request") > 0);
        accepted_tx.send(()).expect("notify accepted");
        loop {
            match stream.read(&mut buf) {
                Ok(0) => break,
                Ok(_) => {}
                Err(err) if err.kind() == std::io::ErrorKind::ConnectionReset => break,
                Err(err) => panic!("expected socket abort on quit, got {err}"),
            }
        }
        closed_tx.send(()).expect("notify closed");
    });

    let _ = runtime.dispatch_json(
        &json!({
            "type": "sync_app_metadata",
            "version": "2.3.0",
            "build": "12",
            "updateEndpoint": endpoint_hang,
        })
        .to_string(),
        1_800_000_300,
    );
    let checking: Value = serde_json::from_str(
        &runtime.dispatch_json(r#"{"type":"check_app_update"}"#, 1_800_000_301),
    )
    .expect("checking snapshot");
    assert_eq!(checking["appUpdate"]["phase"], "checking");
    assert_eq!(checking["lifecycle"]["keepAwake"], false);
    accepted_rx
        .recv_timeout(Duration::from_secs(3))
        .expect("server saw request");

    let quit_snap: Value =
        serde_json::from_str(&runtime.dispatch_json(r#"{"type":"request_quit"}"#, 1_800_000_302))
            .expect("quit snapshot");
    assert_eq!(quit_snap["lifecycle"]["quitPhase"], "ready");
    assert_eq!(quit_snap["lifecycle"]["keepAwake"], false);
    assert_eq!(quit_snap["appUpdate"]["phase"], "idle");

    closed_rx
        .recv_timeout(Duration::from_secs(3))
        .expect("inflight update socket closed immediately on quit");
    hang_server.join().expect("join hang server");

    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn non_semver_or_prerelease_bundle_metadata_never_sets_global_error_or_clobbers_existing_error() {
    let root = temp_workspace("custom-bundle-metadata");
    let mut runtime = KoeRuntime::open(&root).expect("open runtime");

    let seeded: Value = serde_json::from_str(
        &runtime.dispatch_json(r#"{"type":"unknown_command"}"#, 1_800_000_400),
    )
    .expect("seeded error snapshot");
    let initial_error = seeded["error"]
        .as_str()
        .expect("expected seeded error")
        .to_owned();

    let prerelease_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "sync_app_metadata",
                "version": "2.4.0-beta.1",
                "build": "12_qa+1"
            })
            .to_string(),
            1_800_000_401,
        ),
    )
    .expect("prerelease sync snapshot");
    assert_eq!(
        prerelease_snap["error"].as_str(),
        Some(initial_error.as_str())
    );
    assert_eq!(prerelease_snap["appUpdate"]["currentVersion"], "2.4.0");
    assert_eq!(prerelease_snap["appUpdate"]["currentBuild"], "12_qa+1");

    let _ = runtime.dispatch_json(r#"{"type":"clear_error"}"#, 1_800_000_402);
    let fallback_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "sync_app_metadata",
                "version": "dev-local",
                "build": "bad build with spaces"
            })
            .to_string(),
            1_800_000_403,
        ),
    )
    .expect("fallback sync snapshot");
    assert!(fallback_snap["error"].is_null());
    assert_eq!(
        fallback_snap["appUpdate"]["currentVersion"],
        KOE_APP_VERSION
    );
    assert_eq!(fallback_snap["appUpdate"]["currentBuild"], KOE_APP_BUILD);

    let bad_endpoint_snap: Value = serde_json::from_str(
        &runtime.dispatch_json(
            &json!({
                "type": "sync_app_metadata",
                "version": "2.3.0",
                "build": "12",
                "updateEndpoint": "http://evil.example.com/releases/latest"
            })
            .to_string(),
            1_800_000_404,
        ),
    )
    .expect("bad endpoint snapshot");
    assert!(bad_endpoint_snap["error"].is_string());

    let _ = std::fs::remove_dir_all(&root);
}
