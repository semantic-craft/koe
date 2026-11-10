use std::collections::BTreeMap;

use futures_util::{FutureExt, SinkExt, StreamExt};
use serde_json::{json, Value};
use tokio_tungstenite::tungstenite::{
    client::IntoClientRequest, http::HeaderValue, protocol::WebSocketConfig, Message,
};

use super::{ProviderConfig, ProviderOutput, TranscriptSegment, MAX_RESPONSE_BYTES};

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

pub(super) struct Ready {
    pub socket: Socket,
    pub task_id: String,
    pub response_bytes: usize,
}

pub(super) enum Event {
    Started,
    Final {
        sequence: u64,
        segment: TranscriptSegment,
    },
    Interim(Option<(u64, TranscriptSegment)>),
    Finished,
}

pub(super) async fn connect(config: &ProviderConfig) -> Result<Ready, String> {
    let mut request = config
        .endpoint
        .as_str()
        .into_client_request()
        .map_err(|_| "语音服务地址无效")?;
    let mut authorization = HeaderValue::from_str(&format!("Bearer {}", config.api_key))
        .map_err(|_| "语音服务凭据格式无效")?;
    authorization.set_sensitive(true);
    request.headers_mut().insert("Authorization", authorization);
    let wire_config = WebSocketConfig::default()
        .max_message_size(Some(MAX_RESPONSE_BYTES))
        .max_frame_size(Some(MAX_RESPONSE_BYTES));
    let (mut socket, _) =
        tokio_tungstenite::connect_async_with_config(request, Some(wire_config), false)
            .await
            .map_err(|error| match error {
                tokio_tungstenite::tungstenite::Error::Http(response) => {
                    format!("语音服务握手返回 HTTP {}", response.status().as_u16())
                }
                _ => "无法建立语音服务连接".into(),
            })?;
    let task_id = uuid::Uuid::new_v4().to_string();
    socket.send(Message::Text(json!({
        "header": {"action": "run-task", "task_id": task_id, "streaming": "duplex"},
        "payload": {"task_group": "audio", "task": "asr", "function": "recognition",
                    "model": config.model, "parameters": {"format": "pcm", "sample_rate": 16000},
                    "input": {}}
    }).to_string().into())).await.map_err(|_| "语音任务启动发送失败")?;
    let mut response_bytes = 0usize;
    loop {
        let message = socket
            .next()
            .await
            .ok_or("语音服务在启动前断开")?
            .map_err(|_| "语音服务启动响应读取失败")?;
        match message {
            Message::Text(text) => match decode_event(&text, &task_id, &mut response_bytes)? {
                Event::Started => break,
                _ => return Err("语音服务未按协议启动任务".into()),
            },
            Message::Ping(_) => socket.flush().await.map_err(|_| "语音服务保活失败")?,
            Message::Pong(_) => {}
            _ => return Err("语音服务在启动前断开或返回无效数据".into()),
        }
    }
    Ok(Ready {
        socket,
        task_id,
        response_bytes,
    })
}

pub(super) fn finish_message(task_id: &str) -> Message {
    Message::Text(
        json!({
            "header": {"action": "finish-task", "task_id": task_id, "streaming": "duplex"},
            "payload": {"input": {}}
        })
        .to_string()
        .into(),
    )
}

pub(super) async fn transcribe(
    config: &ProviderConfig,
    pcm16: &[u8],
) -> Result<ProviderOutput, String> {
    let Ready {
        socket,
        task_id,
        mut response_bytes,
    } = connect(config).await?;
    let (mut sink, mut source) = socket.split();
    let finished_sending = std::sync::atomic::AtomicBool::new(false);
    let upload = async {
        let mut pacing = tokio::time::interval(std::time::Duration::from_millis(50));
        pacing.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        for chunk in pcm16.chunks(3_200) {
            pacing.tick().await;
            sink.send(Message::Binary(chunk.to_vec().into()))
                .await
                .map_err(|_| "音频发送中断，结果未知；未自动重试".to_string())?;
        }
        finished_sending.store(true, std::sync::atomic::Ordering::Release);
        sink.send(finish_message(&task_id))
            .await
            .map_err(|_| "语音任务收尾发送失败".to_string())?;
        Ok::<(), String>(())
    };
    let receive = async {
        let mut segments = BTreeMap::new();
        loop {
            let message = source
                .next()
                .await
                .ok_or("语音服务提前断开，结果未完成")?
                .map_err(|_| "语音结果读取中断或超过大小限制")?;
            match message {
                Message::Text(text) => match decode_event(&text, &task_id, &mut response_bytes)? {
                    Event::Final { sequence, segment } => {
                        segments.insert(sequence, segment);
                    }
                    Event::Interim(_) => {}
                    Event::Finished => {
                        if !finished_sending.load(std::sync::atomic::Ordering::Acquire) {
                            return Err("语音服务在音频发送完成前结束任务".into());
                        }
                        return Ok::<_, String>(segments.into_values().collect::<Vec<_>>());
                    }
                    _ => return Err("语音服务返回未知任务事件".into()),
                },
                Message::Ping(_) | Message::Pong(_) => {}
                _ => return Err("语音服务提前断开或返回无效数据".into()),
            }
        }
    };
    let (_, segments) = tokio::try_join!(upload, receive)?;
    // A slow close handshake must not turn a completed transcript into a timeout.
    let _ = sink.close().now_or_never();
    Ok(ProviderOutput::Transcript { segments })
}

pub(super) fn decode_event(text: &str, task_id: &str, bytes: &mut usize) -> Result<Event, String> {
    *bytes = bytes.saturating_add(text.len());
    if *bytes > MAX_RESPONSE_BYTES {
        return Err("语音响应超过 4 MiB 限制".into());
    }
    let value: Value = serde_json::from_str(text).map_err(|_| "语音服务返回无效 JSON")?;
    if value.pointer("/header/task_id").and_then(Value::as_str) != Some(task_id) {
        return Err("语音服务返回了其他任务的结果".into());
    }
    match value.pointer("/header/event").and_then(Value::as_str) {
        Some("task-started") => Ok(Event::Started),
        Some("task-finished") => Ok(Event::Finished),
        Some("task-failed") => Err(task_failure(&value)),
        Some("result-generated") => parse_sentence(&value),
        _ => Err("语音服务返回未知任务事件".into()),
    }
}

fn task_failure(value: &Value) -> String {
    let code = value
        .pointer("/header/error_code")
        .and_then(Value::as_str)
        .unwrap_or("Unknown");
    let safe_code: String = code
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_')
        .take(64)
        .collect();
    format!("语音任务失败（{safe_code}）；未自动重试")
}

fn parse_sentence(value: &Value) -> Result<Event, String> {
    let sentence = value
        .pointer("/payload/output/sentence")
        .ok_or("语音结果缺少句子")?;
    if sentence.get("heartbeat").and_then(Value::as_bool) == Some(true) {
        return Ok(Event::Interim(None));
    }
    if sentence.get("sentence_end").and_then(Value::as_bool) != Some(true) {
        let Some(id) = sentence.get("sentence_id").and_then(Value::as_u64) else {
            return Ok(Event::Interim(None));
        };
        let start_ms = sentence
            .get("begin_time")
            .and_then(Value::as_u64)
            .unwrap_or(0);
        let end_ms = sentence
            .get("end_time")
            .and_then(Value::as_u64)
            .unwrap_or(start_ms)
            .max(start_ms);
        let Some(text) = sentence.get("text").and_then(Value::as_str) else {
            return Ok(Event::Interim(None));
        };
        if text.len() > 64 * 1024 {
            return Err("语音结果单句超过 64 KiB 限制".into());
        }
        if text.trim().is_empty() {
            return Ok(Event::Interim(None));
        }
        return Ok(Event::Interim(Some((
            id,
            TranscriptSegment {
                start_ms,
                end_ms,
                text: text.to_owned(),
            },
        ))));
    }
    let id = sentence
        .get("sentence_id")
        .and_then(Value::as_u64)
        .ok_or("语音结果缺少句子标识")?;
    let start_ms = sentence
        .get("begin_time")
        .and_then(Value::as_u64)
        .ok_or("语音结果缺少起始时间")?;
    let end_ms = sentence
        .get("end_time")
        .and_then(Value::as_u64)
        .ok_or("语音结果缺少结束时间")?;
    let text = sentence
        .get("text")
        .and_then(Value::as_str)
        .ok_or("语音结果缺少文本")?;
    if end_ms < start_ms {
        return Err("语音结果的时间顺序无效".into());
    }
    if text.len() > 64 * 1024 {
        return Err("语音结果单句超过 64 KiB 限制".into());
    }
    if text.trim().is_empty() {
        return Ok(Event::Interim(None));
    }
    Ok(Event::Final {
        sequence: id,
        segment: TranscriptSegment {
            start_ms,
            end_ms,
            text: text.to_owned(),
        },
    })
}
