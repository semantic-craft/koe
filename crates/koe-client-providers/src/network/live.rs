use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use futures_util::{FutureExt, SinkExt, StreamExt};
use tokio::sync::{mpsc, watch};
use tokio_tungstenite::tungstenite::Message;

use super::{asr, ProviderConfig, TranscriptSegment};

const AUDIO_QUEUE_CAPACITY: usize = 256;
const EVENT_QUEUE_CAPACITY: usize = 64;
const MAX_CHUNK_BYTES: usize = 64 * 1024;
const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(15);
const SESSION_TIMEOUT: Duration = Duration::from_secs(4 * 60 * 60);

/// A live result for the recording bound to this stream by its caller.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LiveEvent {
    /// An in-progress sentence draft that has not yet been finalized.
    Interim {
        /// Provider sentence identifier, stable within this stream.
        sequence: u64,
        /// Provider draft text and timing, transient until finalized.
        segment: TranscriptSegment,
    },
    /// A finalized sentence. A later event with the same sequence revises that sentence.
    Final {
        /// Provider sentence identifier, stable within this stream.
        sequence: u64,
        /// Provider text and timing, emitted before the recording ends.
        segment: TranscriptSegment,
    },
    /// The matching task-finished event was received after all accepted audio was sent.
    Finished,
    /// Terminal failure. The caller retains local audio for an explicit retry.
    Failed(String),
}

/// A bounded, cancellable live WebSocket session owned by exactly one recording.
///
/// Calls enqueue or poll without waiting for network I/O. Dropping the instance cancels
/// the socket. Audio capacity is 256 chunks of at most 64 KiB each; a full queue is an error.
pub struct LiveTranscription {
    audio: mpsc::Sender<Vec<u8>>,
    events: mpsc::Receiver<LiveEvent>,
    finishing: watch::Sender<bool>,
    cancel: watch::Sender<bool>,
    accepting: AtomicBool,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl LiveTranscription {
    /// Starts a background session using the explicit endpoint, model and credential.
    pub fn start(config: ProviderConfig) -> Result<Self, String> {
        super::validate_endpoint(&config, "wss", "ws")?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| "无法创建实时转写线程".to_string())?;
        let (audio, input) = mpsc::channel(AUDIO_QUEUE_CAPACITY);
        let (output, events) = mpsc::channel(EVENT_QUEUE_CAPACITY);
        let (finishing, finish) = watch::channel(false);
        let (cancel, mut cancellation) = watch::channel(false);
        let thread = std::thread::Builder::new().name("koe-live-asr".into()).spawn(move || {
            runtime.block_on(async {
                let result = tokio::select! {
                    biased;
                    _ = cancellation.changed() => None,
                    result = tokio::time::timeout(
                        SESSION_TIMEOUT,
                        stream(config, input, finish, output.clone()),
                    ) => {
                        Some(result.unwrap_or_else(|_| Err("实时转写已达到四小时会话上限".into())))
                    }
                };
                if let Some(result) = result {
                    let terminal = result.map_or_else(LiveEvent::Failed, |()| LiveEvent::Finished);
                    if !*cancellation.borrow() {
                        tokio::select! {
                            biased;
                            _ = cancellation.changed() => {}
                            _ = output.send(terminal) => {}
                        }
                    }
                }
            });
            runtime.shutdown_timeout(Duration::from_millis(100));
        }).map_err(|_| "无法启动实时转写线程".to_string())?;
        Ok(Self {
            audio,
            events,
            finishing,
            cancel,
            accepting: AtomicBool::new(true),
            thread: Some(thread),
        })
    }

    /// Enqueues little-endian 16 kHz mono PCM. A refusal means these bytes were not accepted.
    pub fn push_audio(&self, pcm: Vec<u8>) -> Result<(), String> {
        if !self.accepting.load(Ordering::Acquire) {
            return Err("实时转写已停止接收音频".into());
        }
        if pcm.is_empty() || !pcm.len().is_multiple_of(2) || pcm.len() > MAX_CHUNK_BYTES {
            return Err("音频块必须为非空 16 位 PCM，且不能超过 64 KiB".into());
        }
        self.audio.try_send(pcm).map_err(|error| match error {
            mpsc::error::TrySendError::Full(_) => {
                "实时转写队列已满，本段音频未发送；请保留本地录音".into()
            }
            mpsc::error::TrySendError::Closed(_) => "实时转写连接已结束，本段音频未发送".into(),
        })
    }

    /// Stops accepting new audio and requests finish after all accepted chunks drain.
    /// The signal has its own channel, so a full audio queue cannot discard it.
    pub fn finish(&self) -> Result<(), String> {
        if !self.accepting.swap(false, Ordering::AcqRel) {
            return Ok(());
        }
        self.finishing
            .send(true)
            .map_err(|_| "实时转写连接已结束".into())
    }

    /// Drains available sentences, then delivers the terminal result once.
    pub fn poll(&mut self) -> Vec<LiveEvent> {
        let mut result = Vec::new();
        while let Ok(event) = self.events.try_recv() {
            if matches!(event, LiveEvent::Finished | LiveEvent::Failed(_)) {
                self.accepting.store(false, Ordering::Release);
            }
            result.push(event);
        }
        result
    }
}

impl Drop for LiveTranscription {
    fn drop(&mut self) {
        let _ = self.cancel.send(true);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

async fn stream(
    config: ProviderConfig,
    mut audio: mpsc::Receiver<Vec<u8>>,
    mut finish: watch::Receiver<bool>,
    output: mpsc::Sender<LiveEvent>,
) -> Result<(), String> {
    let ready = tokio::time::timeout(CONNECT_TIMEOUT, asr::connect(&config))
        .await
        .map_err(|_| "实时转写连接或任务启动超时")??;
    let task_id = ready.task_id;
    let (mut sink, mut source) = ready.socket.split();
    let finished_sending = AtomicBool::new(false);
    let upload = async {
        let mut closing = *finish.borrow_and_update();
        if closing {
            audio.close();
        }
        loop {
            let chunk = tokio::select! {
                biased;
                _ = finish.changed(), if !closing => {
                    closing = true;
                    audio.close();
                    continue;
                }
                chunk = tokio::time::timeout(IDLE_TIMEOUT, audio.recv()) => {
                    chunk.map_err(|_| "实时转写超过一分钟未收到音频")?
                }
            };
            let Some(chunk) = chunk else {
                break;
            };
            for bytes in chunk.chunks(3_200) {
                tokio::time::timeout(
                    IDLE_TIMEOUT,
                    sink.send(Message::Binary(bytes.to_vec().into())),
                )
                .await
                .map_err(|_| "实时音频发送超时")?
                .map_err(|_| "实时音频发送中断，原始录音需要保留")?;
            }
        }
        finished_sending.store(true, Ordering::Release);
        tokio::time::timeout(IDLE_TIMEOUT, sink.send(asr::finish_message(&task_id)))
            .await
            .map_err(|_| "实时转写收尾发送超时")?
            .map_err(|_| "实时转写收尾发送失败")?;
        Ok::<_, String>(())
    };
    let receive = async {
        loop {
            let message = tokio::time::timeout(IDLE_TIMEOUT, source.next())
                .await
                .map_err(|_| "实时转写超过一分钟未收到服务端响应")?
                .ok_or("实时转写连接提前断开")?
                .map_err(|_| "实时转写读取中断或响应超过限制")?;
            match message {
                Message::Text(text) => {
                    let live_event = match asr::decode_event(&text, &task_id)? {
                        asr::Event::Interim(Some((sequence, segment))) => {
                            Some(LiveEvent::Interim { sequence, segment })
                        }
                        asr::Event::Final { sequence, segment } => {
                            Some(LiveEvent::Final { sequence, segment })
                        }
                        asr::Event::Interim(None) => None,
                        asr::Event::Finished if finished_sending.load(Ordering::Acquire) => {
                            return Ok::<_, String>(())
                        }
                        _ => return Err("实时转写服务返回了不符合当前阶段的事件".into()),
                    };
                    if let Some(live_event) = live_event {
                        tokio::time::timeout(IDLE_TIMEOUT, output.send(live_event))
                            .await
                            .map_err(|_| "实时转写结果超过一分钟未被接收")?
                            .map_err(|_| "实时转写结果接收者已关闭")?;
                    }
                }
                Message::Ping(_) | Message::Pong(_) => {}
                _ => return Err("实时转写连接提前断开或返回无效数据".into()),
            }
        }
    };
    tokio::try_join!(upload, receive)?;
    let _ = sink.close().now_or_never();
    Ok(())
}
