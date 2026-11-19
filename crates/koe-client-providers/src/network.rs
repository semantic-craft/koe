use std::fmt;
use std::time::Duration;

use koe_engine::product::{
    DEFAULT_ASR_MODEL, DEFAULT_DASHSCOPE_WS_URL, DEFAULT_DEEPSEEK_CHAT_URL, DEFAULT_TEXT_MODEL,
};
use tokio::sync::{mpsc, oneshot};

mod asr;
mod chat;
mod http_asr;
mod live;
mod update;

pub use live::{LiveEvent, LiveTranscription};
pub use update::{
    parse_release_payload, validate_update_endpoint, ReleaseAsset, RemoteRelease,
    UpdateCheckOutcome,
};

const LANE_COUNT: usize = 4;

const MAX_PCM_BYTES: usize = 64 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

/// Documented Beijing public DashScope ASR endpoint; a workspace-specific WSS URL may override it.
pub const DASHSCOPE_ASR_ENDPOINT: &str = DEFAULT_DASHSCOPE_WS_URL;
/// Default DeepSeek official OpenAI-compatible chat endpoint.
pub const DEEPSEEK_CHAT_ENDPOINT: &str = DEFAULT_DEEPSEEK_CHAT_URL;
/// Default real-time ASR model (Qwen primary).
pub const DASHSCOPE_ASR_MODEL: &str = DEFAULT_ASR_MODEL;
/// Default general-purpose chat model (DeepSeek 4.1 Flash).
pub const DEEPSEEK_CHAT_MODEL: &str = DEFAULT_TEXT_MODEL;

/// Provider-specific thinking control sent in chat completion payloads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ThinkingMode {
    /// DeepSeek official `thinking: { "type": "enabled" | "disabled" }`.
    DeepSeek(bool),
}

/// Wire protocol used for batch cloud audio transcription.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum AsrTransportMode {
    /// DashScope duplex WebSocket protocol (`run-task` / binary PCM / `finish-task`).
    #[default]
    DashScopeWebSocket,
    /// DashScope synchronous HTTP multimodal-generation (`qwen-audio-3.1-asr-flash`, <= 5 min).
    DashScopeFlashHttp,
    /// DashScope asynchronous file transcription (`qwen-audio-3.1-asr-flash-filetrans`).
    DashScopeFiletransHttp,
    /// DeepSeek official multipart WAV upload (`POST /v1/tools/asr`, auto silence-split <= 110s).
    DeepSeekHttp,
}

/// Per-request connection settings. Credentials are never read from disk or the environment.
#[derive(Clone)]
pub struct ProviderConfig {
    pub(super) endpoint: String,
    pub(super) model: String,
    pub(super) api_key: String,
    pub(super) thinking: Option<ThinkingMode>,
    pub(super) asr_mode: AsrTransportMode,
}

impl ProviderConfig {
    /// Uses a complete WebSocket or chat-completions endpoint and an explicit credential.
    #[must_use]
    pub fn new(endpoint: String, model: String, api_key: String) -> Self {
        Self {
            endpoint,
            model,
            api_key,
            thinking: None,
            asr_mode: AsrTransportMode::DashScopeWebSocket,
        }
    }

    /// Configures provider-specific thinking mode for chat requests.
    #[must_use]
    pub const fn with_thinking(mut self, thinking: Option<ThinkingMode>) -> Self {
        self.thinking = thinking;
        self
    }

    /// Configures the wire protocol used for batch ASR transcription.
    #[must_use]
    pub const fn with_asr_mode(mut self, asr_mode: AsrTransportMode) -> Self {
        self.asr_mode = asr_mode;
        self
    }

    /// Empty credential-free configuration for unauthenticated tasks such as [`ProviderTask::CheckUpdate`].
    #[must_use]
    pub const fn empty() -> Self {
        Self {
            endpoint: String::new(),
            model: String::new(),
            api_key: String::new(),
            thinking: None,
            asr_mode: AsrTransportMode::DashScopeWebSocket,
        }
    }
}

impl fmt::Debug for ProviderConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("ProviderConfig")
            .field("endpoint", &"<configured>")
            .field("model", &self.model)
            .field("api_key", &"<redacted>")
            .finish()
    }
}

/// Work performed by the provider thread. No task retries automatically.
pub enum ProviderTask {
    /// Transcribe signed little-endian PCM, 16 kHz, mono, without a WAV header.
    TranscribePcm16 {
        /// Owned PCM bytes, bounded to 64 MiB at submission.
        pcm16: Vec<u8>,
    },
    /// Request a complete non-streaming OpenAI-compatible chat response.
    Chat {
        /// Instruction message.
        system: String,
        /// User message, including any validated source material.
        user: String,
    },
    /// Query GitHub Releases metadata for the latest stable Koe version.
    CheckUpdate {
        /// Validated HTTPS GitHub API URL (or loopback HTTP URL in tests).
        endpoint: String,
        /// Explicit ASCII `User-Agent` header (`Koe/<version>`).
        user_agent: String,
    },
}

/// A request whose completion retains its original operation and recording identity.
pub struct ProviderRequest {
    /// Caller-owned attempt identifier.
    pub operation_id: u64,
    /// Destination recording; navigation changes cannot redirect a completion.
    pub record_id: String,
    /// Explicit model, endpoint and credential.
    pub config: ProviderConfig,
    /// Task payload.
    pub task: ProviderTask,
    /// Total deadline, including connection, upload and response; at most 30 minutes.
    pub timeout: Duration,
}

/// A finalized sentence with timing from the ASR provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptSegment {
    /// Start offset in milliseconds.
    pub start_ms: u64,
    /// End offset in milliseconds.
    pub end_ms: u64,
    /// Recognized text.
    pub text: String,
    /// Optional diarized speaker label (e.g. `说话人 1`).
    pub speaker: Option<String>,
}

/// Successfully completed provider work.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProviderOutput {
    /// ASR result, released only after the matching task-finished event.
    Transcript {
        /// Final sentences ordered by provider sentence identifier.
        segments: Vec<TranscriptSegment>,
    },
    /// Complete chat response text.
    Chat {
        /// Provider response, not a local substitute.
        text: String,
    },
    /// GitHub Releases metadata lookup outcome.
    UpdateCheck(UpdateCheckOutcome),
}

/// Terminal result of exactly one accepted attempt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderEvent {
    /// Original operation identifier.
    pub operation_id: u64,
    /// Original recording identifier.
    pub record_id: String,
    /// Provider output or a credential-safe diagnostic.
    pub result: Result<ProviderOutput, String>,
}

/// Isolated execution lane inside [`ProviderPool`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProviderLane {
    /// Batch cloud audio transcription (`TranscribePcm16`).
    Audio = 0,
    /// Post-session or live meeting summary (`Summary` / `LiveSummary`).
    Summary = 1,
    /// Cross-record Q&A (`Ask`).
    Ask = 2,
    /// Application release metadata check (`CheckUpdate`).
    Update = 3,
}

enum PoolControl {
    Submit {
        lane: ProviderLane,
        request: ProviderRequest,
    },
    Cancel {
        lane: ProviderLane,
        operation_id: u64,
    },
    CancelAudioAndWait(oneshot::Sender<()>),
    Shutdown,
}

/// Multi-lane bounded background provider pool running on one Tokio runtime thread.
///
/// Audio transcription, summary generation, Q&A, and update checks run in separate single-slot
/// lanes so a slow operation never blocks another lane, and stale tasks cancel without joining threads.
pub struct ProviderPool {
    controls: mpsc::UnboundedSender<PoolControl>,
    events: mpsc::UnboundedReceiver<(ProviderLane, ProviderEvent)>,
    active_ops: [Option<u64>; LANE_COUNT],
    thread: Option<std::thread::JoinHandle<()>>,
}

impl ProviderPool {
    /// Starts an isolated multi-lane async runtime on one background thread.
    pub fn new() -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| "无法创建云端工作线程".to_string())?;
        let (controls, mut rx) = mpsc::unbounded_channel::<PoolControl>();
        let (events_tx, events) = mpsc::unbounded_channel::<(ProviderLane, ProviderEvent)>();
        let thread = std::thread::Builder::new()
            .name("koe-provider-pool".into())
            .spawn(move || {
                runtime.block_on(async {
                    let mut slots: [Option<(u64, tokio::task::JoinHandle<()>)>; LANE_COUNT] =
                        [None, None, None, None];
                    while let Some(control) = rx.recv().await {
                        match control {
                            PoolControl::Submit { lane, request } => {
                                let idx = lane as usize;
                                if let Some((_, existing)) = slots[idx].take() {
                                    existing.abort();
                                }
                                let op_id = request.operation_id;
                                let tx = events_tx.clone();
                                let handle = tokio::spawn(async move {
                                    let result =
                                        tokio::time::timeout(request.timeout, execute(&request))
                                            .await
                                            .unwrap_or_else(|_| {
                                                if lane == ProviderLane::Update {
                                                    Err("更新检查连接超时，请检查网络后重试。"
                                                        .into())
                                                } else {
                                                    Err("云端请求超时，结果未知；未自动重试".into())
                                                }
                                            });
                                    let _ = tx.send((
                                        lane,
                                        ProviderEvent {
                                            operation_id: op_id,
                                            record_id: request.record_id,
                                            result,
                                        },
                                    ));
                                });
                                slots[idx] = Some((op_id, handle));
                            }
                            PoolControl::Cancel { lane, operation_id } => {
                                let idx = lane as usize;
                                if slots[idx]
                                    .as_ref()
                                    .is_some_and(|(id, _)| *id == operation_id)
                                {
                                    if let Some((_, handle)) = slots[idx].take() {
                                        handle.abort();
                                    }
                                }
                            }
                            PoolControl::CancelAudioAndWait(ack) => {
                                let idx = ProviderLane::Audio as usize;
                                if let Some((_, handle)) = slots[idx].take() {
                                    handle.abort();
                                    let _ = handle.await;
                                }
                                let _ = ack.send(());
                            }
                            PoolControl::Shutdown => break,
                        }
                    }
                    for slot in &mut slots {
                        if let Some((_, handle)) = slot.take() {
                            handle.abort();
                            let _ = handle.await;
                        }
                    }
                });
                runtime.shutdown_timeout(Duration::from_millis(100));
            })
            .map_err(|_| "无法启动云端工作线程".to_string())?;
        Ok(Self {
            controls,
            events,
            active_ops: [None; LANE_COUNT],
            thread: Some(thread),
        })
    }

    /// Returns whether `lane` currently owns an unpolled operation.
    #[must_use]
    pub fn is_lane_busy(&self, lane: ProviderLane) -> bool {
        self.active_ops[lane as usize].is_some()
    }

    /// Submits one task onto `lane`, rejecting invalid requests or a busy lane without blocking.
    pub fn submit(&mut self, lane: ProviderLane, request: ProviderRequest) -> Result<(), String> {
        validate(&request)?;
        let idx = lane as usize;
        if self.active_ops[idx].is_some() {
            return Err("已有云端任务正在处理，请稍后重试".into());
        }
        let op_id = request.operation_id;
        self.controls
            .send(PoolControl::Submit { lane, request })
            .map_err(|_| "云端工作线程不可用".to_string())?;
        self.active_ops[idx] = Some(op_id);
        Ok(())
    }

    /// Cancels an in-flight operation on `lane` without blocking the caller thread.
    pub fn cancel(&mut self, lane: ProviderLane, operation_id: u64) {
        let idx = lane as usize;
        if self.active_ops[idx] == Some(operation_id) {
            self.active_ops[idx] = None;
            let _ = self.controls.send(PoolControl::Cancel {
                lane,
                operation_id,
            });
        }
    }

    /// Cancels any active audio transcription and waits until its transport task stops.
    ///
    /// Summary and Q&A lanes continue unaffected.
    pub fn cancel_audio(&mut self) -> Result<(), String> {
        let idx = ProviderLane::Audio as usize;
        if self.active_ops[idx].is_none() {
            return Ok(());
        }
        self.active_ops[idx] = None;
        let (tx, rx) = oneshot::channel();
        self.controls
            .send(PoolControl::CancelAudioAndWait(tx))
            .map_err(|_| "云端工作线程不可用".to_string())?;
        rx.blocking_recv()
            .map_err(|_| "云端工作线程不可用".to_string())
    }

    /// Drains completed non-cancelled events without blocking.
    pub fn poll(&mut self) -> Vec<ProviderEvent> {
        let mut results = Vec::new();
        while let Ok((lane, event)) = self.events.try_recv() {
            let idx = lane as usize;
            if self.active_ops[idx] == Some(event.operation_id) {
                self.active_ops[idx] = None;
                results.push(event);
            }
        }
        results
    }
}

impl Drop for ProviderPool {
    fn drop(&mut self) {
        let _ = self.controls.send(PoolControl::Shutdown);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn validate(request: &ProviderRequest) -> Result<(), String> {
    if request.record_id.trim().is_empty() {
        return Err("缺少记录标识".into());
    }
    if request.timeout.is_zero() || request.timeout > Duration::from_secs(1_800) {
        return Err("云端请求超时设置必须在 0 到 30 分钟之间".into());
    }
    let (secure, local, require_model) = match &request.task {
        ProviderTask::TranscribePcm16 { pcm16 } => {
            if pcm16.is_empty() || pcm16.len() % 2 != 0 || pcm16.len() > MAX_PCM_BYTES {
                return Err("音频必须为非空 16 位 PCM，且不能超过 64 MiB".into());
            }
            match request.config.asr_mode {
                AsrTransportMode::DashScopeWebSocket => ("wss", "ws", true),
                AsrTransportMode::DashScopeFlashHttp | AsrTransportMode::DashScopeFiletransHttp => {
                    ("https", "http", true)
                }
                AsrTransportMode::DeepSeekHttp => ("https", "http", false),
            }
        }
        ProviderTask::Chat { system, user } => {
            if user.trim().is_empty() || system.len().saturating_add(user.len()) > MAX_TEXT_BYTES {
                return Err("问答内容为空或超过 2 MiB 限制".into());
            }
            ("https", "http", true)
        }
        ProviderTask::CheckUpdate {
            endpoint,
            user_agent,
        } => {
            update::validate_update_endpoint(endpoint)?;
            update::validate_user_agent(user_agent)?;
            return Ok(());
        }
    };
    validate_endpoint_inner(&request.config, secure, local, require_model)
}

fn validate_endpoint(config: &ProviderConfig, secure: &str, local: &str) -> Result<(), String> {
    validate_endpoint_inner(config, secure, local, true)
}

fn validate_endpoint_inner(
    config: &ProviderConfig,
    secure: &str,
    local: &str,
    require_model: bool,
) -> Result<(), String> {
    if require_model && config.model.trim().is_empty() {
        return Err("缺少模型名称".into());
    }
    let url = reqwest::Url::parse(&config.endpoint).map_err(|_| "云端地址无效")?;
    if !url.username().is_empty() || url.password().is_some() || url.fragment().is_some() {
        return Err("云端地址不能包含账户、密码或片段".into());
    }
    let loopback = url.host_str().is_some_and(|host| {
        host == "localhost"
            || host
                .trim_matches(['[', ']'])
                .parse::<std::net::IpAddr>()
                .is_ok_and(|ip| ip.is_loopback())
    });
    let keyless_local_http = secure == "https" && url.scheme() == "http" && loopback;
    if config.api_key.trim().is_empty() && !keyless_local_http {
        return Err("尚未配置云端 API Key".into());
    }
    if url.scheme() != secure && !(url.scheme() == local && loopback) {
        return Err("云端地址必须加密；仅本机服务允许明文连接".into());
    }
    Ok(())
}

async fn execute(request: &ProviderRequest) -> Result<ProviderOutput, String> {
    match &request.task {
        ProviderTask::TranscribePcm16 { pcm16 } => match request.config.asr_mode {
            AsrTransportMode::DashScopeWebSocket => asr::transcribe(&request.config, pcm16).await,
            AsrTransportMode::DashScopeFlashHttp => {
                http_asr::transcribe_qwen_flash(&request.config, pcm16).await
            }
            AsrTransportMode::DashScopeFiletransHttp => {
                http_asr::transcribe_qwen_filetrans(&request.config, pcm16).await
            }
            AsrTransportMode::DeepSeekHttp => {
                http_asr::transcribe_deepseek(&request.config, pcm16).await
            }
        },
        ProviderTask::Chat { system, user } => chat::complete(&request.config, system, user).await,
        ProviderTask::CheckUpdate {
            endpoint,
            user_agent,
        } => update::check_latest(endpoint, user_agent).await,
    }
}
