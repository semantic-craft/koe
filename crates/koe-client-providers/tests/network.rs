use std::time::{Duration, Instant};

use koe_client_providers::{
    ProviderConfig, ProviderLane, ProviderOutput, ProviderPool, ProviderRequest, ProviderTask,
    DASHSCOPE_ASR_MODEL,
};

fn wait_result(pool: &mut ProviderPool) -> koe_client_providers::ProviderEvent {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(event) = pool.poll().pop() {
            return event;
        }
        assert!(Instant::now() < deadline, "provider result deadline");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn asr_request(endpoint: String) -> ProviderRequest {
    ProviderRequest {
        operation_id: 17,
        record_id: "record-asr".into(),
        config: ProviderConfig::new(endpoint, DASHSCOPE_ASR_MODEL.into(), "unit-test-key".into()),
        task: ProviderTask::TranscribePcm16 {
            pcm16: vec![2; 6400],
        },
        timeout: Duration::from_secs(3),
    }
}

#[test]
#[allow(clippy::result_large_err)] // Tungstenite fixes the handshake callback's error type.
fn asr_waits_for_ack_and_finish_and_keeps_latest_final_sentence() {
    use futures_util::{SinkExt, StreamExt};
    use serde_json::{json, Value};
    use tokio_tungstenite::tungstenite::Message;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let listener = tokio::net::TcpListener::from_std(listener).unwrap();
            let (stream, _) = listener.accept().await.unwrap();
            let mut ws = tokio_tungstenite::accept_hdr_async(stream, |request: &tokio_tungstenite::tungstenite::handshake::server::Request, response| {
                assert_eq!(request.headers()["authorization"], "Bearer unit-test-key");
                Ok(response)
            }).await.unwrap();
            let run: Value = serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(run["payload"]["model"], "qwen-audio-3.1-asr-flash-streaming");
            assert_eq!(run["payload"]["parameters"]["sample_rate"], 16000);
            assert_eq!(run["payload"]["parameters"]["format"], "pcm");
            let id = run["header"]["task_id"].as_str().unwrap();
            assert!(uuid::Uuid::parse_str(id).is_ok());
            assert!(tokio::time::timeout(Duration::from_millis(60), ws.next()).await.is_err(), "audio preceded task-started");
            ws.send(Message::Text(json!({"header":{"event":"task-started","task_id":id},"payload":{}}).to_string().into())).await.unwrap();
            let mut bytes = 0;
            loop {
                match ws.next().await.unwrap().unwrap() {
                    Message::Binary(audio) => { assert!(audio.iter().all(|&v| v == 2)); bytes += audio.len(); },
                    Message::Text(text) => {
                        let finish: Value = serde_json::from_str(&text).unwrap();
                        assert_eq!(finish["header"]["action"], "finish-task");
                        assert_eq!(finish["header"]["task_id"], id);
                        break;
                    }
                    other => panic!("unexpected frame {other:?}"),
                }
            }
            assert_eq!(bytes, 6400);
            for (text, final_result) in [("partial", false), ("first final", true), ("corrected final", true)] {
                ws.send(Message::Text(json!({
                    "header":{"event":"result-generated","task_id":id},
                    "payload":{"output":{"sentence":{"sentence_id":1,"sentence_end":final_result,"begin_time":0,"end_time":200,"text":text}}}
                }).to_string().into())).await.unwrap();
            }
            ws.send(Message::Text(json!({"header":{"event":"task-finished","task_id":id},"payload":{}}).to_string().into())).await.unwrap();
            let _ = ws.close(None).await;
        });
    });
    let mut pool = ProviderPool::new().unwrap();
    pool.submit(ProviderLane::Audio, asr_request(endpoint))
        .unwrap();
    let event = wait_result(&mut pool);
    assert_eq!(event.operation_id, 17);
    assert_eq!(event.record_id, "record-asr");
    assert_eq!(
        event.result.unwrap(),
        ProviderOutput::Transcript {
            segments: vec![koe_client_providers::TranscriptSegment {
                start_ms: 0,
                end_ms: 200,
                text: "corrected final".into(),
                speaker: None,
            }]
        }
    );
    server.join().unwrap();
}

#[test]
fn timeout_is_terminal_and_drop_closes_pending_socket() {
    use std::io::Read;
    for drop_early in [false, true] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
        let (connected, wait_connected) = std::sync::mpsc::channel();
        let (closed, wait_closed) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = [0; 4096];
            assert!(stream.read(&mut bytes).unwrap() > 0);
            connected.send(()).unwrap();
            loop {
                match stream.read(&mut bytes) {
                    Ok(0) => break,
                    Ok(_) => {}
                    Err(err) if err.kind() == std::io::ErrorKind::ConnectionReset => break,
                    Err(err) => panic!("socket not closed: {err}"),
                }
            }
            closed.send(()).unwrap();
            listener.set_nonblocking(true).unwrap();
            assert!(listener.accept().is_err(), "request retried automatically");
        });
        let mut pool = ProviderPool::new().unwrap();
        let request = ProviderRequest {
            operation_id: 3,
            record_id: "timeout".into(),
            config: ProviderConfig::new(
                endpoint.clone(),
                "test-model".into(),
                "unit-test-key".into(),
            ),
            task: ProviderTask::Chat {
                system: "system".into(),
                user: "user".into(),
            },
            timeout: Duration::from_millis(250),
        };
        pool.submit(ProviderLane::Ask, request).unwrap();
        wait_connected.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(
            pool.submit(
                ProviderLane::Ask,
                ProviderRequest {
                    operation_id: 4,
                    record_id: "timeout-2".into(),
                    config: ProviderConfig::new(
                        endpoint.clone(),
                        "test-model".into(),
                        "unit-test-key".into(),
                    ),
                    task: ProviderTask::Chat {
                        system: "system".into(),
                        user: "user-2".into(),
                    },
                    timeout: Duration::from_millis(250),
                },
            )
            .is_err(),
            "unbounded concurrent request accepted on same lane"
        );
        if drop_early {
            drop(pool);
        } else {
            let event = wait_result(&mut pool);
            assert!(event.result.unwrap_err().contains("超时"));
            assert!(pool.poll().is_empty());
        }
        wait_closed.recv_timeout(Duration::from_secs(3)).unwrap();
        server.join().unwrap();
    }
}

#[test]
fn http_errors_do_not_echo_response_or_credential() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut bytes = [0; 4096];
        assert!(stream.read(&mut bytes).unwrap() > 0);
        let body = "unit-test-key private provider error body";
        write!(
            stream,
            "HTTP/1.1 401 Unauthorized\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
    });
    let config = ProviderConfig::new(endpoint, "test-model".into(), "unit-test-key".into());
    assert!(!format!("{config:?}").contains("unit-test-key"));
    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Summary,
        ProviderRequest {
            operation_id: 1,
            record_id: "errors".into(),
            config,
            task: ProviderTask::Chat {
                system: "system".into(),
                user: "user".into(),
            },
            timeout: Duration::from_secs(3),
        },
    )
    .unwrap();
    let error = wait_result(&mut pool).result.unwrap_err();
    assert!(error.contains("401"));
    assert!(!error.contains("unit-test-key"));
    assert!(!error.contains("private"));
    server.join().unwrap();
}

#[test]
fn oversized_http_response_is_rejected_before_body_download() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut bytes = [0; 4096];
        assert!(stream.read(&mut bytes).unwrap() > 0);
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4194305\r\nConnection: close\r\n\r\n")
            .unwrap();
    });
    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Summary,
        ProviderRequest {
            operation_id: 1,
            record_id: "oversize".into(),
            config: ProviderConfig::new(endpoint, "test-model".into(), "unit-test-key".into()),
            task: ProviderTask::Chat {
                system: "system".into(),
                user: "user".into(),
            },
            timeout: Duration::from_secs(3),
        },
    )
    .unwrap();
    assert!(wait_result(&mut pool)
        .result
        .unwrap_err()
        .contains("4 MiB"));
    server.join().unwrap();
}

#[test]
fn asr_rejects_task_failure_and_foreign_task_result() {
    use futures_util::{SinkExt, StreamExt};
    use serde_json::{json, Value};
    use tokio_tungstenite::tungstenite::Message;
    for foreign in [false, true] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let server = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                    let (stream, _) = listener.accept().await.unwrap();
                    let mut ws = tokio_tungstenite::accept_async(stream).await.unwrap();
                    let run: Value =
                        serde_json::from_str(ws.next().await.unwrap().unwrap().to_text().unwrap())
                            .unwrap();
                    let id = if foreign {
                        "another-task"
                    } else {
                        run["header"]["task_id"].as_str().unwrap()
                    };
                    ws.send(Message::Text(
                        json!({"header":{
                    "event":"task-failed", "task_id":id,
                    "error_code":"InvalidParameter", "error_message":"unit-test-key private details"
                },"payload":{}})
                        .to_string()
                        .into(),
                    ))
                    .await
                    .unwrap();
                });
        });
        let mut pool = ProviderPool::new().unwrap();
        pool.submit(ProviderLane::Audio, asr_request(endpoint))
            .unwrap();
        let error = wait_result(&mut pool).result.unwrap_err();
        assert!(error.contains(if foreign {
            "其他任务"
        } else {
            "InvalidParameter"
        }));
        assert!(!error.contains("unit-test-key"));
        assert!(!error.contains("private"));
        server.join().unwrap();
    }
}

#[test]
fn chat_worker_sends_request_and_delivers_tagged_response() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/chat/completions", listener.local_addr().unwrap());
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut buf = [0; 4096];
        loop {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&buf[..n]);
            let text = String::from_utf8_lossy(&bytes);
            if let Some((headers, body)) = text.split_once("\r\n\r\n") {
                let len: usize = headers
                    .lines()
                    .find_map(|line| {
                        line.to_lowercase()
                            .strip_prefix("content-length: ")
                            .map(str::parse)
                    })
                    .unwrap()
                    .unwrap();
                if body.len() >= len {
                    break;
                }
            }
        }
        let request = String::from_utf8(bytes).unwrap();
        assert!(request.starts_with("POST /chat/completions HTTP/1.1"));
        assert!(request.contains("Bearer unit-test-key"));
        assert!(request.contains("explain the decision"));
        let body = r#"{"choices":[{"message":{"content":"Only the recorded evidence."}}]}"#;
        write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
    });
    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Summary,
        ProviderRequest {
            operation_id: 42,
            record_id: "record-one".into(),
            config: ProviderConfig::new(endpoint, "qwen-plus".into(), "unit-test-key".into()),
            task: ProviderTask::Chat {
                system: "Use evidence".into(),
                user: "explain the decision".into(),
            },
            timeout: Duration::from_secs(3),
        },
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let event = loop {
        if let Some(event) = pool.poll().pop() {
            break event;
        }
        assert!(Instant::now() < deadline, "pool did not complete");
        std::thread::sleep(Duration::from_millis(5));
    };
    assert_eq!(event.operation_id, 42);
    assert_eq!(event.record_id, "record-one");
    assert_eq!(
        event.result.unwrap(),
        ProviderOutput::Chat {
            text: "Only the recorded evidence.".into()
        }
    );
    server.join().unwrap();
}

#[test]
fn loopback_chat_without_key_omits_authorization_and_returns_real_response() {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!(
        "http://{}/v1/chat/completions",
        listener.local_addr().unwrap()
    );
    let server = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match listener.accept() {
                Ok((stream, _)) => break stream,
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        Instant::now() < deadline,
                        "local chat request never arrived"
                    );
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(error) => panic!("{error}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut bytes = Vec::new();
        let mut buffer = [0; 4096];
        loop {
            let n = stream.read(&mut buffer).unwrap();
            assert!(n > 0);
            bytes.extend_from_slice(&buffer[..n]);
            let request = String::from_utf8_lossy(&bytes);
            if let Some((headers, body)) = request.split_once("\r\n\r\n") {
                let length: usize = headers
                    .lines()
                    .find_map(|line| {
                        line.to_lowercase()
                            .strip_prefix("content-length: ")
                            .map(str::parse)
                    })
                    .unwrap()
                    .unwrap();
                if body.len() >= length {
                    assert!(!headers.to_lowercase().contains("authorization:"));
                    let json: serde_json::Value = serde_json::from_str(body).unwrap();
                    assert_eq!(json["model"], "local-model");
                    assert_eq!(json["messages"][1]["content"], "Use this recorded evidence");
                    break;
                }
            }
        }
        let body =
            r#"{"choices":[{"finish_reason":"stop","message":{"content":"Local model answer"}}]}"#;
        write!(stream, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", body.len(), body).unwrap();
    });
    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Ask,
        ProviderRequest {
            operation_id: 73,
            record_id: "local-chat-record".into(),
            config: ProviderConfig::new(endpoint, "local-model".into(), String::new()),
            task: ProviderTask::Chat {
                system: "Keep the facts".into(),
                user: "Use this recorded evidence".into(),
            },
            timeout: Duration::from_secs(3),
        },
    )
    .unwrap();
    let event = wait_result(&mut pool);
    assert_eq!(event.operation_id, 73);
    assert_eq!(
        event.result.unwrap(),
        ProviderOutput::Chat {
            text: "Local model answer".into()
        }
    );
    server.join().unwrap();
}

#[test]
fn keyless_chat_is_rejected_for_cloud_and_lan_endpoints() {
    let mut pool = ProviderPool::new().unwrap();
    for endpoint in [
        "https://api.example.com/v1/chat/completions",
        "http://192.168.1.5/v1/chat/completions",
        "https://192.168.1.5/v1/chat/completions",
    ] {
        let result = pool.submit(
            ProviderLane::Ask,
            ProviderRequest {
                operation_id: 74,
                record_id: "local-chat-record".into(),
                config: ProviderConfig::new(endpoint.into(), "local-model".into(), String::new()),
                task: ProviderTask::Chat {
                    system: "Keep the facts".into(),
                    user: "Use this recorded evidence".into(),
                },
                timeout: Duration::from_secs(3),
            },
        );
        assert!(result.is_err(), "accepted keyless endpoint {endpoint}");
    }
}

#[test]
fn provider_pool_isolates_lanes_and_cancels_stale_summary_without_blocking() {
    use std::io::{Read, Write};
    use std::sync::mpsc;

    let ask_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let ask_endpoint = format!("http://{}/chat/completions", ask_listener.local_addr().unwrap());
    let summary_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let summary_endpoint = format!(
        "http://{}/chat/completions",
        summary_listener.local_addr().unwrap()
    );

    let (ask_seen, wait_ask) = mpsc::channel();
    let (release_ask, hold_ask) = mpsc::channel();
    let ask_server = std::thread::spawn(move || {
        let (mut stream, _) = ask_listener.accept().unwrap();
        let mut buf = [0u8; 4096];
        assert!(stream.read(&mut buf).unwrap() > 0);
        ask_seen.send(()).unwrap();
        hold_ask.recv_timeout(Duration::from_secs(5)).unwrap();
        let body = r#"{"choices":[{"finish_reason":"stop","message":{"content":"ask-ok"}}]}"#;
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
    });

    let (sum1_seen, wait_sum1) = mpsc::channel();
    let (sum1_closed, wait_sum1_closed) = mpsc::channel();
    let summary_server = std::thread::spawn(move || {
        let (mut s1, _) = summary_listener.accept().unwrap();
        s1.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
        let mut buf = [0u8; 4096];
        assert!(s1.read(&mut buf).unwrap() > 0);
        sum1_seen.send(()).unwrap();
        loop {
            match s1.read(&mut buf) {
                Ok(0) => break,
                Ok(_) => {}
                Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => break,
                Err(e) => panic!("stale summary socket not closed: {e}"),
            }
        }
        sum1_closed.send(()).unwrap();

        let (mut s2, _) = summary_listener.accept().unwrap();
        assert!(s2.read(&mut buf).unwrap() > 0);
        let body = r#"{"choices":[{"finish_reason":"stop","message":{"content":"summary-ok"}}]}"#;
        write!(
            s2,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
    });

    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Ask,
        ProviderRequest {
            operation_id: 1,
            record_id: "ask".into(),
            config: ProviderConfig::new(ask_endpoint, "model".into(), "key".into()),
            task: ProviderTask::Chat {
                system: "sys".into(),
                user: "question".into(),
            },
            timeout: Duration::from_secs(5),
        },
    )
    .unwrap();
    wait_ask.recv_timeout(Duration::from_secs(3)).unwrap();

    // Ask lane is busy, so a second Ask must fail, while Summary lane remains free.
    assert!(pool
        .submit(
            ProviderLane::Ask,
            ProviderRequest {
                operation_id: 2,
                record_id: "ask".into(),
                config: ProviderConfig::new(summary_endpoint.clone(), "model".into(), "key".into()),
                task: ProviderTask::Chat {
                    system: "sys".into(),
                    user: "q2".into(),
                },
                timeout: Duration::from_secs(5),
            }
        )
        .is_err());

    pool.submit(
        ProviderLane::Summary,
        ProviderRequest {
            operation_id: 3,
            record_id: "rec-1".into(),
            config: ProviderConfig::new(summary_endpoint.clone(), "model".into(), "key".into()),
            task: ProviderTask::Chat {
                system: "sys".into(),
                user: "stale-summary".into(),
            },
            timeout: Duration::from_secs(5),
        },
    )
    .unwrap();
    wait_sum1.recv_timeout(Duration::from_secs(3)).unwrap();

    // Cancel stale Summary without blocking, and verify Ask is untouched while Summary slot reopens.
    let cancel_started = Instant::now();
    pool.cancel(ProviderLane::Summary, 3);
    assert!(cancel_started.elapsed() < Duration::from_millis(50));
    wait_sum1_closed
        .recv_timeout(Duration::from_secs(3))
        .unwrap();

    pool.submit(
        ProviderLane::Summary,
        ProviderRequest {
            operation_id: 4,
            record_id: "rec-2".into(),
            config: ProviderConfig::new(summary_endpoint, "model".into(), "key".into()),
            task: ProviderTask::Chat {
                system: "sys".into(),
                user: "fresh-summary".into(),
            },
            timeout: Duration::from_secs(5),
        },
    )
    .unwrap();

    let deadline = Instant::now() + Duration::from_secs(5);
    let mut events = Vec::new();
    while !events.iter().any(|e: &koe_client_providers::ProviderEvent| e.operation_id == 4) {
        events.extend(pool.poll());
        assert!(Instant::now() < deadline, "fresh summary must complete while Ask is still pending");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert!(!events.iter().any(|e| e.operation_id == 3));
    assert_eq!(
        events.iter().find(|e| e.operation_id == 4).unwrap().result,
        Ok(ProviderOutput::Chat {
            text: "summary-ok".into()
        })
    );
    assert!(pool.is_lane_busy(ProviderLane::Ask));

    release_ask.send(()).unwrap();
    while !events.iter().any(|e| e.operation_id == 1) {
        events.extend(pool.poll());
        assert!(Instant::now() < deadline, "in-flight Ask must complete");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(
        events.iter().find(|e| e.operation_id == 1).unwrap().result,
        Ok(ProviderOutput::Chat {
            text: "ask-ok".into()
        })
    );

    ask_server.join().unwrap();
    summary_server.join().unwrap();
}

#[test]
fn update_lane_validates_endpoints_redirects_payloads_and_sanitizes_untrusted_urls() {
    use koe_client_providers::{
        parse_release_payload, validate_update_endpoint, UpdateCheckOutcome,
    };
    use koe_engine::KOE_GITHUB_RELEASES_URL;
    use std::io::Write;

    assert_eq!(
        validate_update_endpoint("https://api.github.com/repos/semantic-craft/koe/releases/latest"),
        Ok(false)
    );
    assert_eq!(
        validate_update_endpoint("https://api.github.com/repositories/987654321/releases/latest"),
        Ok(false)
    );
    assert_eq!(
        validate_update_endpoint("http://127.0.0.1:8080/releases/latest"),
        Ok(true)
    );
    for rejected in [
        "http://api.github.com/repos/semantic-craft/koe/releases/latest",
        "https://api.github.com:8443/repos/semantic-craft/koe/releases/latest",
        "https://api.github.com/repos/other-org/koe/releases/latest",
        "https://api.github.com/repos/semantic-craft/koe/releases/../../../other-org/koe/releases/latest",
        "https://api.github.com/repos/semantic-craft/koe/releases/%2e%2e/other/releases/latest",
        "https://github.com/semantic-craft/koe/releases/latest",
        "https://evil.example.com/repos/semantic-craft/koe/releases/latest",
        "https://user:pass@api.github.com/repos/semantic-craft/koe/releases/latest",
        "https://api.github.com/repos/semantic-craft/koe/releases/latest#frag",
        "ftp://127.0.0.1/releases/latest",
    ] {
        assert!(
            validate_update_endpoint(rejected).is_err(),
            "accepted unsafe update endpoint: {rejected}"
        );
    }

    // Untrusted html_url and browser_download_url are stripped or replaced with canonical GitHub URL.
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    };
    let untrusted_json = serde_json::json!({
        "tag_name": "v2.4.0",
        "name": "Koe 2.4.0 (13)",
        "draft": false,
        "prerelease": false,
        "html_url": "javascript:alert(1)",
        "body": "Release notes",
        "assets": [
            {
                "name": format!("Koe-2.4.0-macos-{arch}.zip"),
                "size": 1024,
                "browser_download_url": "https://evil.example.com/Koe.zip"
            }
        ]
    });
    match parse_release_payload(untrusted_json.to_string().as_bytes(), false).unwrap() {
        UpdateCheckOutcome::Release(rel) => {
            assert_eq!(rel.version.to_string(), "2.4.0");
            assert_eq!(rel.release_url, KOE_GITHUB_RELEASES_URL);
            assert!(
                rel.asset.is_none(),
                "untrusted download domain must be dropped"
            );
        }
        other => panic!("expected Release, got {other:?}"),
    }

    // Draft and prerelease payloads resolve to Unavailable.
    let prerelease_json = serde_json::json!({
        "tag_name": "v2.5.0",
        "prerelease": true
    });
    assert!(matches!(
        parse_release_payload(prerelease_json.to_string().as_bytes(), false).unwrap(),
        UpdateCheckOutcome::Unavailable { .. }
    ));

    fn read_http_headers(stream: &mut std::net::TcpStream) {
        use std::io::Read;
        let mut req_bytes = Vec::new();
        let mut buf = [0u8; 2048];
        loop {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0, "unexpected EOF before HTTP headers");
            req_bytes.extend_from_slice(&buf[..n]);
            if req_bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
        }
    }

    // Loopback 302 redirect to final release payload succeeds on ProviderLane::Update.
    let redirect_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    redirect_listener.set_nonblocking(true).unwrap();
    let target_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    target_listener.set_nonblocking(true).unwrap();
    let target_url = format!(
        "http://{}/final-release",
        target_listener.local_addr().unwrap()
    );
    let initial_url = format!("http://{}/latest", redirect_listener.local_addr().unwrap());

    let target_url_for_redirect = target_url.clone();
    let redirect_srv = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match redirect_listener.accept() {
                Ok((s, _)) => break s,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "redirect accept timeout");
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(e) => panic!("{e}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        read_http_headers(&mut stream);
        write!(
            stream,
            "HTTP/1.1 302 Found\r\nLocation: {target_url_for_redirect}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
    });

    let target_srv = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match target_listener.accept() {
                Ok((s, _)) => break s,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "target accept timeout");
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(e) => panic!("{e}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        read_http_headers(&mut stream);
        let body = r#"{"tag_name":"v2.4.0","name":"Koe 2.4.0","html_url":"https://github.com/semantic-craft/koe/releases/tag/v2.4.0","assets":[]}"#;
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        )
        .unwrap();
    });

    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Update,
        ProviderRequest {
            operation_id: 99,
            record_id: "app-update".into(),
            config: ProviderConfig::empty(),
            task: ProviderTask::CheckUpdate {
                endpoint: initial_url,
                user_agent: "Koe/2.3.0".into(),
            },
            timeout: Duration::from_secs(3),
        },
    )
    .unwrap();

    let ev = wait_result(&mut pool);
    assert_eq!(ev.operation_id, 99);
    match ev.result.unwrap() {
        ProviderOutput::UpdateCheck(UpdateCheckOutcome::Release(rel)) => {
            assert_eq!(rel.version.to_string(), "2.4.0");
        }
        other => panic!("unexpected output: {other:?}"),
    }
    redirect_srv.join().unwrap();
    target_srv.join().unwrap();
}

#[test]
fn update_lane_blocks_dot_segment_traversal_matches_universal_fallback_and_caps_chunked_and_redirect_loops(
) {
    use koe_client_providers::{parse_release_payload, UpdateCheckOutcome};
    use koe_engine::KOE_GITHUB_RELEASES_URL;
    use std::io::Write;

    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else {
        "x86_64"
    };

    // 1. Dot-segment path traversal in html_url and browser_download_url must be rejected.
    let traversal_json = serde_json::json!({
        "tag_name": "v2.4.0",
        "name": "Koe 2.4.0",
        "draft": false,
        "prerelease": false,
        "html_url": "https://github.com/semantic-craft/koe/releases/../../../evil-org/malware",
        "assets": [
            {
                "name": format!("Koe-2.4.0-macos-{arch}.zip"),
                "size": 4096,
                "browser_download_url": format!(
                    "https://github.com/semantic-craft/koe/releases/download/../../../../evil-org/malware/Koe-2.4.0-macos-{arch}.zip"
                )
            },
            {
                "name": "Koe-2.4.0-macos-universal.zip",
                "size": 8192,
                "browser_download_url": "https://github.com/semantic-craft/koe/releases/download/%2e%2e/evil/Koe-2.4.0-macos-universal.zip"
            }
        ]
    });
    match parse_release_payload(traversal_json.to_string().as_bytes(), false).unwrap() {
        UpdateCheckOutcome::Release(rel) => {
            assert_eq!(rel.release_url, KOE_GITHUB_RELEASES_URL);
            assert!(
                rel.asset.is_none(),
                "dot-segment traversal download URL must be rejected"
            );
        }
        other => panic!("expected Release, got {other:?}"),
    }

    // 2. Universal zip matches as fallback, while exact arch takes priority when both exist.
    let universal_only = serde_json::json!({
        "tag_name": "v2.4.0",
        "assets": [
            {
                "name": "Koe-2.4.0-macos-universal.zip",
                "size": 12345,
                "browser_download_url": "https://github.com/semantic-craft/koe/releases/download/v2.4.0/Koe-2.4.0-macos-universal.zip"
            }
        ]
    });
    match parse_release_payload(universal_only.to_string().as_bytes(), false).unwrap() {
        UpdateCheckOutcome::Release(rel) => {
            assert_eq!(
                rel.asset.as_ref().map(|a| a.name.as_str()),
                Some("Koe-2.4.0-macos-universal.zip")
            );
        }
        other => panic!("expected Release, got {other:?}"),
    }

    let both_arch_and_universal = serde_json::json!({
        "tag_name": "v2.4.0",
        "assets": [
            {
                "name": "Koe-2.4.0-macos-universal.zip",
                "size": 20000,
                "browser_download_url": "https://github.com/semantic-craft/koe/releases/download/v2.4.0/Koe-2.4.0-macos-universal.zip"
            },
            {
                "name": format!("Koe-2.4.0-macos-{arch}.zip"),
                "size": 10000,
                "browser_download_url": format!("https://github.com/semantic-craft/koe/releases/download/v2.4.0/Koe-2.4.0-macos-{arch}.zip")
            }
        ]
    });
    match parse_release_payload(both_arch_and_universal.to_string().as_bytes(), false).unwrap() {
        UpdateCheckOutcome::Release(rel) => {
            assert_eq!(
                rel.asset.as_ref().map(|a| a.name.as_str()),
                Some(format!("Koe-2.4.0-macos-{arch}.zip").as_str())
            );
        }
        other => panic!("expected Release, got {other:?}"),
    }

    fn read_http_headers(stream: &mut std::net::TcpStream) {
        use std::io::Read;
        let mut req_bytes = Vec::new();
        let mut buf = [0u8; 2048];
        loop {
            let n = stream.read(&mut buf).unwrap();
            assert!(n > 0, "unexpected EOF before HTTP headers");
            req_bytes.extend_from_slice(&buf[..n]);
            if req_bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                break;
            }
        }
    }

    // 3. Chunked transfer encoding without Content-Length exceeding 512 KiB is rejected.
    let chunked_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    chunked_listener.set_nonblocking(true).unwrap();
    let chunked_url = format!("http://{}/chunked", chunked_listener.local_addr().unwrap());
    let chunked_srv = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut stream = loop {
            match chunked_listener.accept() {
                Ok((s, _)) => break s,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < deadline, "chunked accept timeout");
                    std::thread::sleep(Duration::from_millis(5));
                }
                Err(e) => panic!("{e}"),
            }
        };
        stream.set_nonblocking(false).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        read_http_headers(&mut stream);
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
        let chunk = vec![b'a'; 64 * 1024];
        for _ in 0..9 {
            if write!(stream, "{:X}\r\n", chunk.len()).is_err() {
                break;
            }
            if stream.write_all(&chunk).is_err() || write!(stream, "\r\n").is_err() {
                break;
            }
        }
        let _ = write!(stream, "0\r\n\r\n");
    });

    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Update,
        ProviderRequest {
            operation_id: 101,
            record_id: "app-update".into(),
            config: ProviderConfig::empty(),
            task: ProviderTask::CheckUpdate {
                endpoint: chunked_url,
                user_agent: "Koe/2.3.0".into(),
            },
            timeout: Duration::from_secs(3),
        },
    )
    .unwrap();
    let chunked_err = wait_result(&mut pool).result.unwrap_err();
    assert!(
        chunked_err.contains("512 KiB"),
        "expected 512 KiB cap error, got: {chunked_err}"
    );
    chunked_srv.join().unwrap();

    // 4. Redirect loop (> 3 hops) is rejected cleanly.
    let loop_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    loop_listener.set_nonblocking(true).unwrap();
    let loop_addr = loop_listener.local_addr().unwrap();
    let loop_url = format!("http://{loop_addr}/hop0");
    let loop_srv = std::thread::spawn(move || {
        let deadline = Instant::now() + Duration::from_secs(5);
        for hop in 1..=4 {
            let mut stream = loop {
                match loop_listener.accept() {
                    Ok((s, _)) => break s,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        assert!(Instant::now() < deadline, "redirect loop accept timeout");
                        std::thread::sleep(Duration::from_millis(5));
                    }
                    Err(e) => panic!("{e}"),
                }
            };
            stream.set_nonblocking(false).unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            read_http_headers(&mut stream);
            write!(
                stream,
                "HTTP/1.1 302 Found\r\nLocation: http://{loop_addr}/hop{hop}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )
            .unwrap();
        }
    });
    pool.submit(
        ProviderLane::Update,
        ProviderRequest {
            operation_id: 102,
            record_id: "app-update".into(),
            config: ProviderConfig::empty(),
            task: ProviderTask::CheckUpdate {
                endpoint: loop_url,
                user_agent: "Koe/2.3.0".into(),
            },
            timeout: Duration::from_secs(3),
        },
    )
    .unwrap();
    let loop_err = wait_result(&mut pool).result.unwrap_err();
    assert!(
        loop_err.contains("重定向次数过多"),
        "expected redirect loop error, got: {loop_err}"
    );
    loop_srv.join().unwrap();
}

fn read_http_request(stream: &mut std::net::TcpStream) -> (String, Vec<u8>) {
    use std::io::Read;
    let mut raw = Vec::new();
    let mut buf = [0u8; 8192];
    let header_end = loop {
        let n = stream.read(&mut buf).unwrap();
        assert!(n > 0, "unexpected EOF reading HTTP headers");
        raw.extend_from_slice(&buf[..n]);
        if let Some(pos) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
    };
    let head = String::from_utf8_lossy(&raw[..header_end]).into_owned();
    let content_length = head
        .lines()
        .find_map(|line| {
            let (name, val) = line.split_once(':')?;
            name.eq_ignore_ascii_case("content-length")
                .then(|| val.trim().parse::<usize>().ok())
                .flatten()
        })
        .unwrap_or(0);
    while raw.len() < header_end + content_length {
        let n = stream.read(&mut buf).unwrap();
        assert!(n > 0, "unexpected EOF reading HTTP body");
        raw.extend_from_slice(&buf[..n]);
    }
    (head, raw[header_end..header_end + content_length].to_vec())
}

#[test]
fn deepseek_asr_auto_splits_over_120s_at_silence_and_stitches_segments() {
    use std::io::Write;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/v1/tools/asr", listener.local_addr().unwrap());

    let server = std::thread::spawn(move || {
        let mut received_chunks = 0usize;
        for reply_text in ["第一段语音内容", "第二段语音内容"] {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let (head, body) = read_http_request(&mut stream);
            assert!(head.starts_with("POST /v1/tools/asr HTTP/1.1"));
            assert!(head.contains("authorization: Bearer ds-test-key") || head.contains("Authorization: Bearer ds-test-key"));
            assert!(head.to_ascii_lowercase().contains("multipart/form-data; boundary="));
            // Verify multipart body contains valid RIFF WAVE header
            assert!(body.windows(4).any(|w| w == b"RIFF"));
            assert!(body.windows(4).any(|w| w == b"WAVE"));
            assert!(body.len() < 8 * 1024 * 1024);
            received_chunks += 1;
            let resp_body = serde_json::json!({ "text": reply_text }).to_string();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                resp_body.len(),
                resp_body
            )
            .unwrap();
        }
        received_chunks
    });

    // 140s of loud audio with a 1-second silent gap at 95..96s
    let total_samples = 140 * 16_000;
    let mut pcm16 = Vec::with_capacity(total_samples * 2);
    for i in 0..total_samples {
        let sample: i16 = if i / 16_000 == 95 { 0 } else { 8_000 };
        pcm16.extend_from_slice(&sample.to_le_bytes());
    }

    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Audio,
        ProviderRequest {
            operation_id: 201,
            record_id: "rec-ds-long".into(),
            config: ProviderConfig::new(endpoint, String::new(), "ds-test-key".into())
                .with_asr_mode(koe_client_providers::AsrTransportMode::DeepSeekHttp),
            task: ProviderTask::TranscribePcm16 { pcm16 },
            timeout: Duration::from_secs(10),
        },
    )
    .unwrap();
    let event = wait_result(&mut pool);
    let ProviderOutput::Transcript { segments } = event.result.unwrap() else {
        panic!("expected transcript output");
    };
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0].text, "第一段语音内容");
    assert_eq!(segments[0].start_ms, 0);
    assert!(segments[0].end_ms >= 95_000 && segments[0].end_ms <= 96_000);
    assert_eq!(segments[1].text, "第二段语音内容");
    assert_eq!(segments[1].start_ms, segments[0].end_ms);
    assert_eq!(segments[1].end_ms, 140_000);
    assert_eq!(server.join().unwrap(), 2);
}

#[test]
fn qwen_flash_and_filetrans_http_asr_parse_diarized_speakers() {
    use std::io::Write;
    // 1. Qwen Flash HTTP ASR
    let flash_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let flash_url = format!(
        "http://{}/api/v1/services/aigc/multimodal-generation/generation",
        flash_listener.local_addr().unwrap()
    );
    let flash_srv = std::thread::spawn(move || {
        let (mut stream, _) = flash_listener.accept().unwrap();
        let (_head, body) = read_http_request(&mut stream);
        let req: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(req["model"], "qwen-audio-3.1-asr-flash");
        assert_eq!(req["parameters"]["format"], "wav");
        assert_eq!(req["parameters"]["speaker_diarization_enabled"], true);
        let audio = req["input"]["messages"][0]["content"][0]["audio"]
            .as_str()
            .unwrap();
        assert!(audio.starts_with("data:audio/wav;base64,"));
        let resp = serde_json::json!({
            "output": {
                "sentences": [
                    {"begin_time": 0, "end_time": 1200, "text": "大家好", "speaker_id": 0},
                    {"begin_time": 1300, "end_time": 2800, "text": "开始同步进度", "speaker_id": 1}
                ]
            }
        })
        .to_string();
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            resp.len(),
            resp
        )
        .unwrap();
    });

    let mut pool = ProviderPool::new().unwrap();
    pool.submit(
        ProviderLane::Audio,
        ProviderRequest {
            operation_id: 202,
            record_id: "rec-qwen-flash".into(),
            config: ProviderConfig::new(
                flash_url,
                "qwen-audio-3.1-asr-flash".into(),
                "qwen-test-key".into(),
            )
            .with_asr_mode(koe_client_providers::AsrTransportMode::DashScopeFlashHttp),
            task: ProviderTask::TranscribePcm16 {
                pcm16: vec![0u8; 32_000],
            },
            timeout: Duration::from_secs(10),
        },
    )
    .unwrap();
    let ProviderOutput::Transcript { segments } = wait_result(&mut pool).result.unwrap() else {
        panic!("expected transcript");
    };
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0].speaker.as_deref(), Some("说话人 1"));
    assert_eq!(segments[1].speaker.as_deref(), Some("说话人 2"));
    flash_srv.join().unwrap();

    // 2. Qwen Filetrans 5-step async HTTP ASR
    let ft_listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = ft_listener.local_addr().unwrap();
    let origin = format!("http://{addr}");
    let ft_url = format!("{origin}/api/v1/services/audio/asr/transcription");
    let origin_srv = origin.clone();
    let ft_srv = std::thread::spawn(move || {
        // Step 1: getPolicy
        let (mut s1, _) = ft_listener.accept().unwrap();
        let (h1, _) = read_http_request(&mut s1);
        assert!(h1.starts_with("GET /api/v1/uploads?action=getPolicy&model=qwen-audio-3.1-asr-flash-filetrans"));
        let pol = serde_json::json!({
            "data": {
                "upload_host": format!("{origin_srv}/oss-upload"),
                "oss_access_key_id": "test-ak",
                "signature": "test-sig",
                "policy": "test-pol",
                "upload_dir": "dashscope-instant/test",
                "x_oss_object_acl": "private",
                "x_oss_forbid_overwrite": "true"
            }
        })
        .to_string();
        write!(
            s1,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            pol.len(),
            pol
        )
        .unwrap();

        // Step 2: OSS upload
        let (mut s2, _) = ft_listener.accept().unwrap();
        let (h2, b2) = read_http_request(&mut s2);
        assert!(h2.starts_with("POST /oss-upload"));
        assert!(b2.windows(4).any(|w| w == b"RIFF"));
        write!(s2, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();

        // Step 3: Submit async job
        let (mut s3, _) = ft_listener.accept().unwrap();
        let (h3, b3) = read_http_request(&mut s3);
        assert!(h3.to_ascii_lowercase().contains("x-dashscope-async: enable"));
        assert!(h3.to_ascii_lowercase().contains("x-dashscope-ossresourceresolve: enable"));
        let req3: serde_json::Value = serde_json::from_slice(&b3).unwrap();
        assert!(req3["input"]["file_url"].as_str().unwrap().starts_with("oss://dashscope-instant/test/"));
        assert_eq!(req3["parameters"]["diarization_enabled"], true);
        let sub = serde_json::json!({"output": {"task_id": "task-ft-1", "task_status": "PENDING"}}).to_string();
        write!(
            s3,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            sub.len(),
            sub
        )
        .unwrap();

        // Step 4a: Poll -> RUNNING, Step 4b: Poll -> SUCCEEDED
        for (status, url) in [
            ("RUNNING", None),
            ("SUCCEEDED", Some(format!("{origin_srv}/result.json"))),
        ] {
            let (mut sp, _) = ft_listener.accept().unwrap();
            let (hp, _) = read_http_request(&mut sp);
            assert!(hp.starts_with("GET /api/v1/tasks/task-ft-1"));
            let body = if let Some(turl) = url {
                serde_json::json!({"output": {"task_status": status, "results": [{"transcription_url": turl}]}}).to_string()
            } else {
                serde_json::json!({"output": {"task_status": status}}).to_string()
            };
            write!(
                sp,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            )
            .unwrap();
        }

        // Step 5: Download result JSON without Authorization header
        let (mut s5, _) = ft_listener.accept().unwrap();
        let (h5, _) = read_http_request(&mut s5);
        assert!(h5.starts_with("GET /result.json"));
        assert!(!h5.to_ascii_lowercase().contains("authorization:"));
        let res = serde_json::json!({
            "transcripts": [{
                "channel_id": 0,
                "sentences": [
                    {"begin_time": 100, "end_time": 1500, "text": "离线文件第一句", "speaker_id": 0},
                    {"begin_time": 1600, "end_time": 3200, "text": "离线文件第二句", "speaker_id": 2}
                ]
            }]
        })
        .to_string();
        write!(
            s5,
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            res.len(),
            res
        )
        .unwrap();
    });

    pool.submit(
        ProviderLane::Audio,
        ProviderRequest {
            operation_id: 203,
            record_id: "rec-qwen-ft".into(),
            config: ProviderConfig::new(
                ft_url,
                "qwen-audio-3.1-asr-flash-filetrans".into(),
                "qwen-test-key".into(),
            )
            .with_asr_mode(koe_client_providers::AsrTransportMode::DashScopeFiletransHttp),
            task: ProviderTask::TranscribePcm16 {
                pcm16: vec![0u8; 32_000],
            },
            timeout: Duration::from_secs(10),
        },
    )
    .unwrap();
    let ProviderOutput::Transcript { segments } = wait_result(&mut pool).result.unwrap() else {
        panic!("expected transcript");
    };
    assert_eq!(segments.len(), 2);
    assert_eq!(segments[0].text, "离线文件第一句");
    assert_eq!(segments[0].speaker.as_deref(), Some("说话人 1"));
    assert_eq!(segments[1].text, "离线文件第二句");
    assert_eq!(segments[1].speaker.as_deref(), Some("说话人 3"));
    ft_srv.join().unwrap();
}

#[test]
fn chat_requests_encode_provider_specific_thinking_controls() {
    use std::io::Write;
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("http://{}/v1/chat/completions", listener.local_addr().unwrap());

    let server = std::thread::spawn(move || {
        let mut seen = Vec::new();
        for _ in 0..3 {
            let (mut stream, _) = listener.accept().unwrap();
            let (_head, body) = read_http_request(&mut stream);
            let req: serde_json::Value = serde_json::from_slice(&body).unwrap();
            seen.push(req);
            let resp = serde_json::json!({
                "choices": [{"finish_reason": "stop", "message": {"content": "ok"}}]
            })
            .to_string();
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                resp.len(),
                resp
            )
            .unwrap();
        }
        seen
    });

    let mut pool = ProviderPool::new().unwrap();
    for (op, model, thinking) in [
        (301, "deepseek-flash", Some(koe_client_providers::ThinkingMode::DeepSeek(false))),
        (302, "deepseek-v4-pro", Some(koe_client_providers::ThinkingMode::DeepSeek(true))),
        (303, "local-ollama", None),
    ] {
        pool.submit(
            ProviderLane::Summary,
            ProviderRequest {
                operation_id: op,
                record_id: "rec-thinking".into(),
                config: ProviderConfig::new(endpoint.clone(), model.into(), "test-key".into())
                    .with_thinking(thinking),
                task: ProviderTask::Chat {
                    system: "sys".into(),
                    user: "hello".into(),
                },
                timeout: Duration::from_secs(5),
            },
        )
        .unwrap();
        assert!(wait_result(&mut pool).result.is_ok());
    }

    let seen = server.join().unwrap();
    assert_eq!(seen[0]["thinking"]["type"], "disabled");
    assert!(seen[0].get("enable_thinking").is_none());
    assert_eq!(seen[1]["thinking"]["type"], "enabled");
    assert!(seen[1].get("enable_thinking").is_none());
    assert!(seen[2].get("enable_thinking").is_none());
    assert!(seen[2].get("thinking").is_none());
}

#[test]
fn qwen_filetrans_fails_fast_on_unknown_status_and_subtask_failure() {
    use std::io::Write;
    for (case_idx, poll_body, expected_substr) in [
        (
            0u64,
            serde_json::json!({"output": {"task_status": "UNKNOWN"}}).to_string(),
            "UNKNOWN",
        ),
        (
            1u64,
            serde_json::json!({
                "output": {
                    "task_status": "SUCCEEDED",
                    "results": [{"subtask_status": "FAILED", "code": "InvalidAudioFormat"}]
                }
            })
            .to_string(),
            "InvalidAudioFormat",
        ),
    ] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let ft_url = format!("{origin}/api/v1/services/audio/asr/transcription");
        let origin_srv = origin.clone();
        let srv = std::thread::spawn(move || {
            let (mut s1, _) = listener.accept().unwrap();
            let _ = read_http_request(&mut s1);
            let pol = serde_json::json!({
                "data": {
                    "upload_host": format!("{origin_srv}/oss"),
                    "oss_access_key_id": "ak",
                    "signature": "sig",
                    "policy": "pol",
                    "upload_dir": "dir"
                }
            })
            .to_string();
            write!(
                s1,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                pol.len(),
                pol
            )
            .unwrap();

            let (mut s2, _) = listener.accept().unwrap();
            let _ = read_http_request(&mut s2);
            write!(s2, "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").unwrap();

            let (mut s3, _) = listener.accept().unwrap();
            let _ = read_http_request(&mut s3);
            let sub = serde_json::json!({"output": {"task_id": "task-err-1"}}).to_string();
            write!(
                s3,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                sub.len(),
                sub
            )
            .unwrap();

            let (mut s4, _) = listener.accept().unwrap();
            let _ = read_http_request(&mut s4);
            write!(
                s4,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                poll_body.len(),
                poll_body
            )
            .unwrap();
        });

        let mut pool = ProviderPool::new().unwrap();
        pool.submit(
            ProviderLane::Audio,
            ProviderRequest {
                operation_id: 400 + case_idx,
                record_id: format!("rec-ft-err-{case_idx}"),
                config: ProviderConfig::new(
                    ft_url,
                    "qwen-audio-3.1-asr-flash-filetrans".into(),
                    "qwen-test-key".into(),
                )
                .with_asr_mode(koe_client_providers::AsrTransportMode::DashScopeFiletransHttp),
                task: ProviderTask::TranscribePcm16 {
                    pcm16: vec![0u8; 32_000],
                },
                timeout: Duration::from_secs(5),
            },
        )
        .unwrap();
        let err = wait_result(&mut pool).result.unwrap_err();
        assert!(
            err.contains(expected_substr),
            "expected error containing {expected_substr}, got: {err}"
        );
        srv.join().unwrap();
    }
}

#[test]
fn remote_http_url_validator_blocks_loopback_aliases_and_non_global_ips() {
    use koe_client_providers::validate_remote_http_url;
    use std::io::Write;

    assert!(validate_remote_http_url("https://oss.aliyuncs.com/path/result.json", false).is_ok());
    assert!(validate_remote_http_url("http://127.0.0.1:8080/mock", true).is_ok());
    assert!(validate_remote_http_url("http://localhost.:8080/mock", true).is_ok());
    assert!(validate_remote_http_url("http://[::ffff:127.0.0.1]:8080/mock", true).is_ok());

    for blocked in [
        "https://localhost./x",
        "https://a.localhost/x",
        "https://a.localhost./x",
        "https://169.254.169.254/latest/meta-data",
        "https://10.0.0.1/x",
        "https://[::ffff:127.0.0.1]/x",
        "https://[::ffff:169.254.169.254]/x",
        "https://[::ffff:0:127.0.0.1]/x",
        "https://[64:ff9b::169.254.169.254]/latest/meta-data",
        "https://[64:ff9b:1::1]/x",
        "https://[2002:7f00:1::]/x",
        "https://[fec0::1]/x",
        "https://[100::1]/x",
        "https://[2001:db8::1]/x",
        "https://172.16.0.1/x",
        "https://192.168.1.1/x",
        "https://100.64.0.1/x",
        "https://0.0.0.0/x",
        "https://[::]/x",
        "https://[fc00::1]/x",
        "https://[fe80::1]/x",
        "https://224.0.0.1/x",
        "https://[ff02::1]/x",
    ] {
        assert!(
            validate_remote_http_url(blocked, false).is_err(),
            "accepted unsafe remote URL: {blocked}"
        );
    }
    assert!(
        validate_remote_http_url("http://a.localhost/x", true).is_err(),
        "subdomain of localhost must not be treated as an allowed loopback endpoint"
    );

    for (idx, bad_upload_host) in [
        "https://169.254.169.254/latest/meta-data",
        "https://10.0.0.1/x",
        "https://[::ffff:169.254.169.254]/x",
    ]
    .into_iter()
    .enumerate()
    {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let origin = format!("http://{}", listener.local_addr().unwrap());
        let ft_url = format!("{origin}/api/v1/services/audio/asr/transcription");
        let host_for_srv = bad_upload_host.to_owned();
        let srv = std::thread::spawn(move || {
            let (mut s1, _) = listener.accept().unwrap();
            let _ = read_http_request(&mut s1);
            let pol = serde_json::json!({
                "data": {
                    "upload_host": host_for_srv,
                    "oss_access_key_id": "ak",
                    "signature": "sig",
                    "policy": "pol",
                    "upload_dir": "dir"
                }
            })
            .to_string();
            write!(
                s1,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                pol.len(),
                pol
            )
            .unwrap();
        });

        let mut pool = ProviderPool::new().unwrap();
        pool.submit(
            ProviderLane::Audio,
            ProviderRequest {
                operation_id: 500 + idx as u64,
                record_id: format!("rec-ssrf-{idx}"),
                config: ProviderConfig::new(
                    ft_url,
                    "qwen-audio-3.1-asr-flash-filetrans".into(),
                    "qwen-test-key".into(),
                )
                .with_asr_mode(koe_client_providers::AsrTransportMode::DashScopeFiletransHttp),
                task: ProviderTask::TranscribePcm16 {
                    pcm16: vec![0u8; 32_000],
                },
                timeout: Duration::from_secs(5),
            },
        )
        .unwrap();
        let err = wait_result(&mut pool).result.unwrap_err();
        assert!(
            err.contains("不安全或受限"),
            "expected SSRF rejection for {bad_upload_host}, got: {err}"
        );
        srv.join().unwrap();
    }
}
