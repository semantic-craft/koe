use std::time::{Duration, Instant};

use koe_client_providers::{
    ProviderConfig, ProviderLane, ProviderOutput, ProviderPool, ProviderRequest, ProviderTask,
    ProviderWorker, DASHSCOPE_ASR_MODEL,
};

fn wait_result(worker: &mut ProviderWorker) -> koe_client_providers::ProviderEvent {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(event) = worker.poll().pop() {
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
    let mut worker = ProviderWorker::new().unwrap();
    worker.submit(asr_request(endpoint)).unwrap();
    let event = wait_result(&mut worker);
    assert_eq!(event.operation_id, 17);
    assert_eq!(event.record_id, "record-asr");
    assert_eq!(
        event.result.unwrap(),
        ProviderOutput::Transcript {
            segments: vec![koe_client_providers::TranscriptSegment {
                start_ms: 0,
                end_ms: 200,
                text: "corrected final".into(),
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
        let mut worker = ProviderWorker::new().unwrap();
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
        worker.submit(request).unwrap();
        wait_connected.recv_timeout(Duration::from_secs(3)).unwrap();
        assert!(
            worker
                .submit(asr_request(endpoint.replace("http:", "ws:")))
                .is_err(),
            "unbounded concurrent request accepted"
        );
        if drop_early {
            drop(worker);
        } else {
            let event = wait_result(&mut worker);
            assert!(event.result.unwrap_err().contains("超时"));
            assert!(worker.poll().is_empty());
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
    let mut worker = ProviderWorker::new().unwrap();
    worker
        .submit(ProviderRequest {
            operation_id: 1,
            record_id: "errors".into(),
            config,
            task: ProviderTask::Chat {
                system: "system".into(),
                user: "user".into(),
            },
            timeout: Duration::from_secs(3),
        })
        .unwrap();
    let error = wait_result(&mut worker).result.unwrap_err();
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
    let mut worker = ProviderWorker::new().unwrap();
    worker
        .submit(ProviderRequest {
            operation_id: 1,
            record_id: "oversize".into(),
            config: ProviderConfig::new(endpoint, "test-model".into(), "unit-test-key".into()),
            task: ProviderTask::Chat {
                system: "system".into(),
                user: "user".into(),
            },
            timeout: Duration::from_secs(3),
        })
        .unwrap();
    assert!(wait_result(&mut worker)
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
        let mut worker = ProviderWorker::new().unwrap();
        worker.submit(asr_request(endpoint)).unwrap();
        let error = wait_result(&mut worker).result.unwrap_err();
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
    let mut worker = ProviderWorker::new().unwrap();
    worker
        .submit(ProviderRequest {
            operation_id: 42,
            record_id: "record-one".into(),
            config: ProviderConfig::new(endpoint, "qwen-plus".into(), "unit-test-key".into()),
            task: ProviderTask::Chat {
                system: "Use evidence".into(),
                user: "explain the decision".into(),
            },
            timeout: Duration::from_secs(3),
        })
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let event = loop {
        if let Some(event) = worker.poll().pop() {
            break event;
        }
        assert!(Instant::now() < deadline, "worker did not complete");
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
    let mut worker = ProviderWorker::new().unwrap();
    worker
        .submit(ProviderRequest {
            operation_id: 73,
            record_id: "local-chat-record".into(),
            config: ProviderConfig::new(endpoint, "local-model".into(), String::new()),
            task: ProviderTask::Chat {
                system: "Keep the facts".into(),
                user: "Use this recorded evidence".into(),
            },
            timeout: Duration::from_secs(3),
        })
        .unwrap();
    let event = wait_result(&mut worker);
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
    let worker = ProviderWorker::new().unwrap();
    for endpoint in [
        "https://api.example.com/v1/chat/completions",
        "http://192.168.1.5/v1/chat/completions",
        "https://192.168.1.5/v1/chat/completions",
    ] {
        let result = worker.submit(ProviderRequest {
            operation_id: 74,
            record_id: "local-chat-record".into(),
            config: ProviderConfig::new(endpoint.into(), "local-model".into(), String::new()),
            task: ProviderTask::Chat {
                system: "Keep the facts".into(),
                user: "Use this recorded evidence".into(),
            },
            timeout: Duration::from_secs(3),
        });
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
