use std::time::Duration;

#[cfg(any(feature = "offline-speech", test))]
const MAX_DOWNLOAD_REDIRECTS: usize = 5;

#[allow(clippy::disallowed_methods, clippy::disallowed_types)]
fn hardened_builder() -> reqwest::ClientBuilder {
    reqwest::Client::builder().retry(reqwest::retry::never())
}

pub(crate) fn cloud_api_client() -> Result<reqwest::Client, reqwest::Error> {
    hardened_builder()
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .connect_timeout(Duration::from_secs(15))
        .build()
}

pub(crate) fn update_check_client(no_proxy: bool) -> Result<reqwest::Client, reqwest::Error> {
    let mut builder = hardened_builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(10));
    if no_proxy {
        builder = builder.no_proxy();
    }
    builder.build()
}

#[cfg(any(feature = "offline-speech", test))]
pub(crate) fn validate_download_redirect(
    previous_urls: &[reqwest::Url],
    next: &reqwest::Url,
) -> Result<(), &'static str> {
    if previous_urls.len() > MAX_DOWNLOAD_REDIRECTS {
        return Err("download exceeded maximum redirect hops");
    }
    let initial_is_loopback = previous_urls
        .first()
        .is_some_and(crate::network::is_loopback_host);
    if crate::network::validate_remote_http_url_parsed(next.as_str(), initial_is_loopback).is_err()
    {
        return Err("download redirect target is unsafe or restricted");
    }
    Ok(())
}

#[cfg(any(feature = "offline-speech", test))]
pub(crate) fn validated_download_client(
    connect_timeout: Duration,
    read_timeout: Duration,
    no_proxy: bool,
) -> Result<reqwest::Client, reqwest::Error> {
    let policy = reqwest::redirect::Policy::custom(|attempt| {
        match validate_download_redirect(attempt.previous(), attempt.url()) {
            Ok(()) => attempt.follow(),
            Err(reason) => attempt.error(reason),
        }
    });
    let mut builder = hardened_builder()
        .redirect(policy)
        .connect_timeout(connect_timeout)
        .read_timeout(read_timeout);
    if no_proxy {
        builder = builder.no_proxy();
    }
    builder.build()
}

#[cfg(test)]
mod tests {
    use std::io::{ErrorKind, Read, Write};
    use std::net::{TcpListener, TcpStream};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Instant;

    use super::*;

    fn url(raw: &str) -> reqwest::Url {
        reqwest::Url::parse(raw).expect("valid test url")
    }

    fn accept_with_timeout(listener: &TcpListener, timeout: Duration) -> Option<TcpStream> {
        let deadline = Instant::now() + timeout;
        loop {
            match listener.accept() {
                Ok((stream, _)) => {
                    stream
                        .set_nonblocking(false)
                        .expect("restore blocking mode on accepted socket");
                    return Some(stream);
                }
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return None;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
                Err(_) => return None,
            }
        }
    }

    #[test]
    fn validate_download_redirect_allows_https_cdn_redirect() {
        let initial = [url(
            "https://huggingface.co/owner/repo/resolve/main/model.gguf",
        )];
        let cdn = url("https://cdn-lfs-us-1.hf.co/repos/abc/model.gguf?response-content-disposition=attachment");
        assert!(validate_download_redirect(&initial, &cdn).is_ok());
    }

    #[test]
    fn validate_download_redirect_rejects_ssrf_and_downgrade_targets() {
        let initial = [url(
            "https://huggingface.co/owner/repo/resolve/main/model.gguf",
        )];
        let blocked = [
            "http://169.254.169.254/latest/meta-data/",
            "https://127.0.0.1/internal/model.gguf",
            "https://[::1]/internal/model.gguf",
            "https://localhost/internal/model.gguf",
            "https://sub.localhost/internal/model.gguf",
            "http://cdn.example.com/model.gguf",
            "https://10.0.0.1/model.gguf",
            "https://192.168.1.1/model.gguf",
            "https://100.64.0.1/model.gguf",
            "https://[fc00::1]/model.gguf",
            "https://[::ffff:127.0.0.1]/model.gguf",
        ];
        for target in blocked {
            let next = url(target);
            assert!(
                validate_download_redirect(&initial, &next).is_err(),
                "expected redirect target to be rejected: {target}"
            );
        }
    }

    #[test]
    fn validate_download_redirect_enforces_five_hop_limit() {
        let chain: Vec<reqwest::Url> = (0..=5)
            .map(|hop| url(&format!("https://cdn.example.com/hop-{hop}")))
            .collect();
        let next = url("https://cdn.example.com/final.gguf");
        assert!(validate_download_redirect(&chain[..5], &next).is_ok());
        assert!(validate_download_redirect(&chain[..6], &next).is_err());
    }

    #[tokio::test]
    async fn validated_download_client_rejects_loopback_redirect_loop_over_five_hops() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback listener");
        listener
            .set_nonblocking(true)
            .expect("enable nonblocking accept");
        let addr = listener.local_addr().expect("listener addr");
        let requests = Arc::new(AtomicUsize::new(0));
        let server_requests = Arc::clone(&requests);
        let server = thread::spawn(move || {
            for _ in 0..8 {
                let Some(mut stream) = accept_with_timeout(&listener, Duration::from_secs(3))
                else {
                    break;
                };
                let hop = server_requests.fetch_add(1, Ordering::SeqCst) + 1;
                let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf);
                let response = format!(
                    "HTTP/1.1 302 Found\r\nLocation: http://{addr}/hop-{hop}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                );
                let _ = stream.write_all(response.as_bytes());
                if hop >= 6 {
                    break;
                }
            }
        });

        let client =
            validated_download_client(Duration::from_secs(5), Duration::from_secs(5), true)
                .expect("build validated download client");
        let result = client.get(format!("http://{addr}/hop-0")).send().await;
        server.join().expect("server thread finished");

        assert!(result.is_err(), "redirect loop past 5 hops must fail");
        assert_eq!(
            requests.load(Ordering::SeqCst),
            6,
            "client must perform initial request plus 5 followed redirects and reject the 6th"
        );
    }

    #[tokio::test]
    async fn validated_download_client_rejects_loopback_redirect_to_metadata_ip() {
        let listener = TcpListener::bind("127.0.0.1:0").expect("bind loopback listener");
        listener
            .set_nonblocking(true)
            .expect("enable nonblocking accept");
        let addr = listener.local_addr().expect("listener addr");
        let server = thread::spawn(move || {
            let Some(mut stream) = accept_with_timeout(&listener, Duration::from_secs(3)) else {
                return;
            };
            let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
            let mut buf = [0u8; 2048];
            let _ = stream.read(&mut buf);
            let response = "HTTP/1.1 302 Found\r\nLocation: http://169.254.169.254/latest/meta-data/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            let _ = stream.write_all(response.as_bytes());
        });

        let client =
            validated_download_client(Duration::from_secs(5), Duration::from_secs(5), true)
                .expect("build validated download client");
        let result = client.get(format!("http://{addr}/model")).send().await;
        server.join().expect("server thread finished");

        assert!(
            result.is_err(),
            "redirect to metadata IP 169.254.169.254 must be rejected"
        );
    }
}
