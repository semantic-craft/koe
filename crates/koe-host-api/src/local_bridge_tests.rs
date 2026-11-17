use std::{
    fs,
    io::{BufRead, BufReader, Write},
    os::unix::{
        fs::{FileTypeExt, MetadataExt},
        net::{UnixListener, UnixStream},
    },
    path::PathBuf,
    sync::atomic::{AtomicU64, Ordering},
    thread,
    time::{Duration, Instant},
};

use koe_runtime::resolve_bridge_socket_path;
use serde_json::{Value, json};

use crate::HostSessionGuard;

use super::BridgeServer;

pub(crate) fn temp_workspace() -> PathBuf {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    std::env::temp_dir().join(format!(
        "koe-bridge-{}-{}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

#[test]
fn host_session_binds_0600_socket_serves_rpc_and_unlinks_on_destroy() {
    let ws = temp_workspace();
    let _ = fs::remove_dir_all(&ws);
    let sock_path = resolve_bridge_socket_path(&ws).unwrap();

    fs::create_dir_all(&ws).unwrap();
    drop(UnixListener::bind(&sock_path).unwrap());

    let session = HostSessionGuard::open(&ws).expect("host session should open");
    let meta = fs::symlink_metadata(&sock_path).unwrap();
    assert!(meta.file_type().is_socket());
    assert_eq!(meta.mode() & 0o777, 0o600);

    let mut client = UnixStream::connect(&sock_path).unwrap();
    writeln!(
        client,
        "{}",
        json!({"jsonrpc": "2.0", "id": 1, "method": "koe/mcp_tools_list"})
    )
    .unwrap();
    client.flush().unwrap();
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let mut resp_line = String::new();
    reader.read_line(&mut resp_line).unwrap();
    let resp: Value = serde_json::from_str(&resp_line).unwrap();
    assert_eq!(resp["result"]["tools"].as_array().unwrap().len(), 16);

    drop(client);
    drop(reader);
    drop(session);
    assert!(!sock_path.exists());
    let _ = fs::remove_dir_all(&ws);
}

#[test]
fn host_session_destroy_finishes_after_socket_path_is_removed() {
    const CHILD_WORKSPACE: &str = "KOE_BRIDGE_DROP_TEST_WORKSPACE";
    if let Some(ws) = std::env::var_os(CHILD_WORKSPACE) {
        let ws = PathBuf::from(ws);
        let session = HostSessionGuard::open(&ws).unwrap();
        fs::remove_file(resolve_bridge_socket_path(&ws).unwrap()).unwrap();
        drop(session);
        return;
    }

    let ws = temp_workspace();
    let mut child = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "local_bridge::tests::host_session_destroy_finishes_after_socket_path_is_removed",
            "--nocapture",
        ])
        .env(CHILD_WORKSPACE, &ws)
        .spawn()
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break Some(status);
        }
        if Instant::now() >= deadline {
            child.kill().unwrap();
            child.wait().unwrap();
            break None;
        }
        thread::sleep(Duration::from_millis(10));
    };
    let _ = fs::remove_dir_all(&ws);
    assert!(
        status.is_some_and(|status| status.success()),
        "destroy did not finish after its socket path was removed"
    );
}

#[test]
fn local_bridge_start_preserves_non_socket_files() {
    let ws = temp_workspace();
    fs::create_dir_all(&ws).unwrap();
    let path = resolve_bridge_socket_path(&ws).unwrap();
    fs::write(&path, b"unrelated file").unwrap();
    let bridge = BridgeServer::start(0, &ws);
    let rejected = bridge.is_none();
    drop(bridge);
    let contents = fs::read(&path).ok();
    let _ = fs::remove_dir_all(&ws);
    assert!(rejected, "bridge replaced a non-socket file");
    assert_eq!(contents.as_deref(), Some(b"unrelated file".as_slice()));
}

#[test]
fn local_bridge_rejects_raw_dispatch() {
    let base = PathBuf::from(format!("/tmp/kb-{}", std::process::id()));
    let container_ws = base.join(
        "Containers/com.anker.ankerRecorder/Data/Library/Application Support/KoeWorkspace",
    );
    let _ = fs::remove_dir_all(&base);
    let sock_path = resolve_bridge_socket_path(&container_ws).unwrap();
    let dot_koe = sock_path.parent().unwrap();

    let session = HostSessionGuard::open(&container_ws).expect("host session should open");
    let dir_meta = fs::metadata(dot_koe).unwrap();
    assert_eq!(dir_meta.mode() & 0o777, 0o700);

    let mut rpc_client = UnixStream::connect(&sock_path).unwrap();
    writeln!(
        rpc_client,
        "{}",
        json!({
            "jsonrpc": "2.0",
            "id": 99,
            "method": "koe/dispatch",
            "params": {"command": {"type": "empty_trash"}}
        })
    )
    .unwrap();
    rpc_client.flush().unwrap();
    let mut rpc_reader = BufReader::new(rpc_client.try_clone().unwrap());
    let mut dispatch_resp_line = String::new();
    rpc_reader.read_line(&mut dispatch_resp_line).unwrap();
    let dispatch_resp: Value = serde_json::from_str(&dispatch_resp_line).unwrap();
    assert_eq!(dispatch_resp["error"]["code"], -32601);

    drop(rpc_reader);
    drop(rpc_client);
    drop(session);
    let _ = fs::remove_dir_all(&base);
}
