#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use koe_client_providers::{LiveEvent, LiveTranscription, ProviderConfig, DASHSCOPE_ASR_MODEL};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::Message;

fn config(endpoint: String) -> ProviderConfig {
    ProviderConfig::new(endpoint, DASHSCOPE_ASR_MODEL.into(), "unit-test-key".into())
}

fn wait_event(live: &mut LiveTranscription) -> LiveEvent {
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        let mut events = live.poll();
        if !events.is_empty() {
            assert_eq!(events.len(), 1);
            return events.remove(0);
        }
        assert!(Instant::now() < deadline, "live event did not arrive");
        std::thread::sleep(Duration::from_millis(5));
    }
}

type ServerSocket = tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>;

async fn ready(stream: tokio::net::TcpStream) -> (ServerSocket, String) {
    let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
    let run: Value =
        serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap()).unwrap();
    assert_eq!(run["payload"]["model"], "qwen-audio-3.1-asr-flash-streaming");
    let id = run["header"]["task_id"].as_str().unwrap().to_owned();
    socket
        .send(Message::Text(
            json!({"header":{"task_id":id,"event":"task-started"},"payload":{}})
                .to_string()
                .into(),
        ))
        .await
        .unwrap();
    (socket, id)
}

fn event(id: &str, name: &str) -> Message {
    Message::Text(
        json!({"header":{"task_id":id,"event":name},"payload":{}})
            .to_string()
            .into(),
    )
}

fn final_sentence(id: &str, text: &str) -> Message {
    Message::Text(json!({"header":{"task_id":id,"event":"result-generated"},
        "payload":{"output":{"sentence":{"sentence_id":7,"sentence_end":true,"begin_time":0,"end_time":100,"text":text}}}
    }).to_string().into())
}

fn interim_sentence(id: &str, text: &str, begin_time: u64, end_time: u64) -> Message {
    Message::Text(json!({"header":{"task_id":id,"event":"result-generated"},
        "payload":{"output":{"sentence":{"sentence_id":7,"sentence_end":false,"begin_time":begin_time,"end_time":end_time,"text":text}}}
    }).to_string().into())
}

#[test]
fn interim_sentences_stream_as_live_events_before_sentence_end() {
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
                let (mut socket, id) = ready(stream).await;
                assert!(matches!(
                    socket.next().await.unwrap().unwrap(),
                    Message::Binary(_)
                ));
                socket
                    .send(interim_sentence(&id, "   ", 0, 20))
                    .await
                    .unwrap();
                socket
                    .send(interim_sentence(&id, "partial words", 0, 60))
                    .await
                    .unwrap();
                assert!(matches!(
                    socket.next().await.unwrap().unwrap(),
                    Message::Binary(_)
                ));
                socket
                    .send(final_sentence(&id, "partial words complete"))
                    .await
                    .unwrap();
                let finish: Value =
                    serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                        .unwrap();
                assert_eq!(finish["header"]["action"], "finish-task");
                socket.send(event(&id, "task-finished")).await.unwrap();
            });
    });
    let mut live = LiveTranscription::start(config(endpoint)).unwrap();
    live.push_audio(vec![1; 3200]).unwrap();
    match wait_event(&mut live) {
        LiveEvent::Interim { sequence, segment } => {
            assert_eq!(sequence, 7);
            assert_eq!(segment.text, "partial words");
            assert_eq!(segment.start_ms, 0);
            assert_eq!(segment.end_ms, 60);
        }
        other => panic!("expected interim sentence, got {other:?}"),
    }
    live.push_audio(vec![2; 3200]).unwrap();
    match wait_event(&mut live) {
        LiveEvent::Final { sequence, segment } => {
            assert_eq!(sequence, 7);
            assert_eq!(segment.text, "partial words complete");
            assert_eq!(segment.start_ms, 0);
            assert_eq!(segment.end_ms, 100);
        }
        other => panic!("expected final sentence, got {other:?}"),
    }
    live.finish().unwrap();
    assert_eq!(wait_event(&mut live), LiveEvent::Finished);
    server.join().unwrap();
}

#[test]
fn finalized_sentences_and_corrections_arrive_before_finish() {
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
                let (mut socket, id) = ready(stream).await;
                assert!(matches!(
                    socket.next().await.unwrap().unwrap(),
                    Message::Binary(_)
                ));
                socket
                    .send(final_sentence(&id, "first sentence"))
                    .await
                    .unwrap();
                assert!(matches!(
                    socket.next().await.unwrap().unwrap(),
                    Message::Binary(_)
                ));
                socket
                    .send(final_sentence(&id, "corrected sentence"))
                    .await
                    .unwrap();
                let finish: Value =
                    serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                        .unwrap();
                assert_eq!(finish["header"]["action"], "finish-task");
                socket.send(event(&id, "task-finished")).await.unwrap();
            });
    });
    let mut live = LiveTranscription::start(config(endpoint)).unwrap();
    live.push_audio(vec![1; 3200]).unwrap();
    match wait_event(&mut live) {
        LiveEvent::Final { sequence, segment } => {
            assert_eq!(sequence, 7);
            assert_eq!(segment.text, "first sentence");
        }
        other => panic!("expected sentence before finishing, got {other:?}"),
    }
    live.push_audio(vec![2; 3200]).unwrap();
    match wait_event(&mut live) {
        LiveEvent::Final { sequence, segment } => {
            assert_eq!(sequence, 7);
            assert_eq!(segment.text, "corrected sentence");
        }
        other => panic!("expected corrected sentence, got {other:?}"),
    }
    live.finish().unwrap();
    assert_eq!(wait_event(&mut live), LiveEvent::Finished);
    assert!(live.push_audio(vec![0; 640]).is_err());
    server.join().unwrap();
}

#[test]
fn full_audio_queue_reports_backpressure_and_finish_drains_accepted_audio() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let (connected, connection) = std::sync::mpsc::channel();
    let (release, released) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        connected.send(()).unwrap();
        released.recv_timeout(Duration::from_secs(5)).unwrap();
        stream.set_nonblocking(true).unwrap();
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let (mut socket, id) =
                    ready(tokio::net::TcpStream::from_std(stream).unwrap()).await;
                let mut received = 0;
                loop {
                    match socket.next().await.unwrap().unwrap() {
                        Message::Binary(bytes) => received += bytes.len(),
                        Message::Text(text) => {
                            let finish: Value = serde_json::from_str(&text).unwrap();
                            assert_eq!(finish["header"]["action"], "finish-task");
                            socket.send(event(&id, "task-finished")).await.unwrap();
                            return received;
                        }
                        other => panic!("unexpected message {other:?}"),
                    }
                }
            })
    });
    let mut live = LiveTranscription::start(config(endpoint)).unwrap();
    connection.recv_timeout(Duration::from_secs(5)).unwrap();
    let mut accepted = 0;
    while live.push_audio(vec![1; 640]).is_ok() {
        accepted += 1;
        assert!(accepted < 1024, "unbounded audio queue");
    }
    assert!(accepted > 0);
    live.finish().unwrap();
    live.finish().unwrap();
    release.send(()).unwrap();
    assert_eq!(wait_event(&mut live), LiveEvent::Finished);
    assert_eq!(server.join().unwrap(), accepted * 640);
}

#[test]
fn disconnect_reports_failure_and_drop_cancels_socket() {
    for drop_client in [false, true] {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        listener.set_nonblocking(true).unwrap();
        let endpoint = format!("ws://{}", listener.local_addr().unwrap());
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let server = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                    let (stream, _) = listener.accept().await.unwrap();
                    let (mut socket, _) = ready(stream).await;
                    assert!(matches!(
                        socket.next().await.unwrap().unwrap(),
                        Message::Binary(_)
                    ));
                    ready_tx.send(()).unwrap();
                    if drop_client {
                        let result = tokio::time::timeout(Duration::from_secs(2), socket.next())
                            .await
                            .expect("drop did not cancel connection");
                        assert!(!matches!(result, Some(Ok(Message::Binary(_)))));
                    }
                });
        });
        let mut live = LiveTranscription::start(config(endpoint)).unwrap();
        live.push_audio(vec![0; 640]).unwrap();
        ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
        if drop_client {
            drop(live);
        } else {
            assert!(matches!(wait_event(&mut live), LiveEvent::Failed(_)));
        }
        server.join().unwrap();
    }
}

#[test]
fn burst_sentences_right_before_finish_arrive_in_fifo_order_before_finished() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                let (mut socket, id) = ready(stream).await;
                assert!(matches!(
                    socket.next().await.unwrap().unwrap(),
                    Message::Binary(_)
                ));
                let finish: Value =
                    serde_json::from_str(socket.next().await.unwrap().unwrap().to_text().unwrap())
                        .unwrap();
                assert_eq!(finish["header"]["action"], "finish-task");
                for seq in 1..=80u64 {
                    socket
                        .send(Message::Text(
                            json!({
                                "header": {"task_id": id, "event": "result-generated"},
                                "payload": {"output": {"sentence": {
                                    "sentence_id": seq,
                                    "sentence_end": true,
                                    "begin_time": seq * 10,
                                    "end_time": seq * 10 + 5,
                                    "text": format!("sentence-{seq}")
                                }}}
                            })
                            .to_string()
                            .into(),
                        ))
                        .await
                        .unwrap();
                }
                socket.send(event(&id, "task-finished")).await.unwrap();
                done_tx.send(()).unwrap();
            });
    });

    let mut live = LiveTranscription::start(config(endpoint)).unwrap();
    live.push_audio(vec![1; 3200]).unwrap();
    live.finish().unwrap();
    done_rx.recv_timeout(Duration::from_secs(5)).unwrap();

    let mut collected = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        collected.extend(live.poll());
        if collected.last() == Some(&LiveEvent::Finished) {
            break;
        }
        assert!(Instant::now() < deadline, "did not observe LiveEvent::Finished");
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(collected.len(), 81);
    for (idx, event) in collected[..80].iter().enumerate() {
        let expected_seq = (idx + 1) as u64;
        match event {
            LiveEvent::Final { sequence, segment } => {
                assert_eq!(*sequence, expected_seq);
                assert_eq!(segment.text, format!("sentence-{expected_seq}"));
            }
            other => panic!("expected Final #{expected_seq} before Finished, got {other:?}"),
        }
    }
    assert_eq!(collected[80], LiveEvent::Finished);
    assert!(live.poll().is_empty(), "terminal event must be delivered only once");
    assert!(live.push_audio(vec![0; 640]).is_err());
    server.join().unwrap();
}

#[test]
fn unpolled_server_flood_applies_backpressure() {
    use std::sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    };

    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let endpoint = format!("ws://{}", listener.local_addr().unwrap());
    let sent_count = Arc::new(AtomicUsize::new(0));
    let sent_for_server = Arc::clone(&sent_count);
    let (flushed_tx, flushed_rx) = std::sync::mpsc::channel();
    let server = std::thread::spawn(move || {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap()
            .block_on(async {
                let listener = tokio::net::TcpListener::from_std(listener).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                let (mut socket, id) = ready(stream).await;
                assert!(matches!(
                    socket.next().await.unwrap().unwrap(),
                    Message::Binary(_)
                ));
                let payload_text = "a".repeat(60 * 1024);
                let mut sent = 0usize;
                for seq in 1..=256u64 {
                    let msg = Message::Text(
                        json!({
                            "header": {"task_id": id, "event": "result-generated"},
                            "payload": {"output": {"sentence": {
                                "sentence_id": seq,
                                "sentence_end": true,
                                "begin_time": seq * 10,
                                "end_time": seq * 10 + 5,
                                "text": payload_text
                            }}}
                        })
                        .to_string()
                        .into(),
                    );
                    match tokio::time::timeout(Duration::from_secs(5), socket.send(msg)).await {
                        Ok(Ok(())) => {
                            sent += 1;
                            sent_for_server.store(sent, Ordering::Release);
                        }
                        _ => break,
                    }
                }
                let _ = flushed_tx.send(sent);
                sent
            })
    });

    let live = LiveTranscription::start(config(endpoint)).unwrap();
    live.push_audio(vec![1; 3200]).unwrap();

    let fill_deadline = Instant::now() + Duration::from_secs(5);
    while sent_count.load(Ordering::Acquire) < 64 {
        assert!(
            Instant::now() < fill_deadline,
            "server did not fill initial bounded channel"
        );
        std::thread::sleep(Duration::from_millis(5));
    }

    assert!(
        flushed_rx.recv_timeout(Duration::from_millis(300)).is_err(),
        "server flushed all {} frames without polling; receive backpressure is missing",
        sent_count.load(Ordering::Acquire)
    );
    assert!(sent_count.load(Ordering::Acquire) < 256);

    let drop_started = Instant::now();
    drop(live);
    assert!(
        drop_started.elapsed() < Duration::from_secs(2),
        "drop(live) blocked on full bounded event channel"
    );

    let total_sent = server.join().unwrap();
    assert!(
        (64..256).contains(&total_sent),
        "unexpected total_sent={total_sent}"
    );
}
