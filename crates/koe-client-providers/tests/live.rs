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
        LiveEvent::Final { sequence, segment } => {
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
