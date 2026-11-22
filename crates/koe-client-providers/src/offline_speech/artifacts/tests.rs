use std::net::TcpListener;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use super::*;

fn download_client() -> reqwest::Client {
    crate::http_client::validated_download_client(
        Duration::from_secs(5),
        Duration::from_secs(5),
        true,
    )
    .unwrap()
}

struct Directory(PathBuf);

impl Directory {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("koe-offline-artifact-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self(path)
    }
}

impl Drop for Directory {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.0).unwrap();
    }
}

fn artifact(url: String) -> Artifact {
    Artifact {
        filename: "model.gguf",
        url,
        bytes: 3,
        sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    }
}

fn server(body: &'static [u8], length: usize, status: u16) -> (String, thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/model", listener.local_addr().unwrap());
    let handle = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut request = [0; 4096];
        assert!(stream.read(&mut request).unwrap() > 0);
        let header = format!(
            "HTTP/1.1 {status} Test\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n"
        );
        let _ = stream.write_all(header.as_bytes());
        let _ = stream.write_all(body);
    });
    (url, handle)
}

#[tokio::test]
async fn verified_download_is_atomic_and_reusable_without_network() {
    let directory = Directory::new();
    let (url, server) = server(b"abc", 3, 200);
    let artifact = artifact(url);
    let control = Control::new();
    let mut progress = Vec::new();
    let client = download_client();
    let path = ensure_artifact(&directory.0, &artifact, &client, &control, 0, |bytes| {
        progress.push(bytes)
    })
    .await
    .unwrap();
    server.join().unwrap();
    assert_eq!(fs::read(&path).unwrap(), b"abc");
    assert_eq!(progress.last(), Some(&3));
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 1);
    let cached = ensure_artifact(&directory.0, &artifact, &client, &control, 0, |_| {})
        .await
        .unwrap();
    assert_eq!(cached, path);
}

#[tokio::test]
async fn corrupt_cached_artifact_is_replaced_with_verified_download() {
    let directory = Directory::new();
    fs::write(directory.0.join("model.gguf"), b"abd").unwrap();
    let (url, server) = server(b"abc", 3, 200);
    let path = ensure_artifact(
        &directory.0,
        &artifact(url),
        &download_client(),
        &Control::new(),
        0,
        |_| {},
    )
    .await
    .unwrap();
    server.join().unwrap();
    assert_eq!(fs::read(path).unwrap(), b"abc");
}

#[tokio::test]
async fn corrupt_download_is_never_published() {
    let directory = Directory::new();
    let (url, server) = server(b"abd", 3, 200);
    let error = ensure_artifact(
        &directory.0,
        &artifact(url),
        &download_client(),
        &Control::new(),
        0,
        |_| {},
    )
    .await
    .unwrap_err();
    server.join().unwrap();
    assert!(error.contains("SHA-256"), "{error}");
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
}

#[tokio::test]
async fn truncated_download_is_never_published() {
    let directory = Directory::new();
    let (url, server) = server(b"ab", 3, 200);
    let result = ensure_artifact(
        &directory.0,
        &artifact(url),
        &download_client(),
        &Control::new(),
        0,
        |_| {},
    )
    .await;
    server.join().unwrap();
    assert!(result.is_err());
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
}

#[tokio::test]
async fn mismatched_download_length_is_rejected() {
    let directory = Directory::new();
    let (url, server) = server(b"abcd", 4, 200);
    let result = ensure_artifact(
        &directory.0,
        &artifact(url),
        &download_client(),
        &Control::new(),
        0,
        |_| {},
    )
    .await;
    server.join().unwrap();
    assert!(result.is_err());
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
}

#[tokio::test]
async fn http_failure_is_not_a_model() {
    let directory = Directory::new();
    let (url, server) = server(b"abc", 3, 503);
    let error = ensure_artifact(
        &directory.0,
        &artifact(url),
        &download_client(),
        &Control::new(),
        0,
        |_| {},
    )
    .await
    .unwrap_err();
    server.join().unwrap();
    assert!(error.contains("503"), "{error}");
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
}

#[tokio::test]
async fn cancellation_interrupts_a_stalled_download_and_removes_partial_file() {
    let directory = Directory::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/model", listener.local_addr().unwrap());
    let control = Arc::new(Control::new());
    let (release, wait) = std::sync::mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(std::time::Duration::from_secs(5)))
            .unwrap();
        let mut request = [0; 4096];
        assert!(stream.read(&mut request).unwrap() > 0);
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\na")
            .unwrap();
        wait.recv_timeout(std::time::Duration::from_secs(5))
            .unwrap();
    });
    let result = tokio::time::timeout(
        std::time::Duration::from_secs(3),
        ensure_artifact(
            &directory.0,
            &artifact(url),
            &download_client(),
            &control,
            0,
            |bytes| {
                if bytes > 0 {
                    control.cancel();
                }
            },
        ),
    )
    .await
    .unwrap();
    release.send(()).unwrap();
    server.join().unwrap();
    assert!(result.unwrap_err().contains("cancelled"));
    assert_eq!(fs::read_dir(&directory.0).unwrap().count(), 0);
}
