use std::fmt;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use tokio::sync::{mpsc, watch};

mod asr;
mod chat;
mod live;

pub use live::{LiveEvent, LiveTranscription};

const MAX_PCM_BYTES: usize = 64 * 1024 * 1024;
const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;

/// Documented Beijing public endpoint; a workspace-specific WSS URL may override it.
pub const DASHSCOPE_ASR_ENDPOINT: &str = "wss://dashscope.aliyuncs.com/api-ws/v1/inference";
/// Documented Beijing OpenAI-compatible public chat endpoint.
pub const DASHSCOPE_CHAT_ENDPOINT: &str =
    "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions";
/// Default real-time ASR model.
pub const DASHSCOPE_ASR_MODEL: &str = "fun-asr-realtime";
/// Default general-purpose chat model.
pub const DASHSCOPE_CHAT_MODEL: &str = "qwen-plus";

/// Per-request connection settings. Credentials are never read from disk or the environment.
#[derive(Clone)]
pub struct ProviderConfig {
    pub(super) endpoint: String,
    pub(super) model: String,
    pub(super) api_key: String,
}

impl ProviderConfig {
    /// Uses a complete WebSocket or chat-completions endpoint and an explicit credential.
    #[must_use]
    pub fn new(endpoint: String, model: String, api_key: String) -> Self {
        Self {
            endpoint,
            model,
            api_key,
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

/// One bounded background worker. Submission and polling never perform network I/O.
///
/// A second task is refused until the first result is polled. Dropping the worker
/// cancels its pending network future and lets the background thread shut down.
pub struct ProviderWorker {
    requests: mpsc::Sender<ProviderRequest>,
    events: mpsc::Receiver<ProviderEvent>,
    cancel: watch::Sender<bool>,
    busy: AtomicBool,
}

impl ProviderWorker {
    /// Starts an isolated async runtime on one background thread.
    pub fn new() -> Result<Self, String> {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| "无法创建云端工作线程".to_string())?;
        let (requests, mut input) = mpsc::channel::<ProviderRequest>(1);
        let (output, events) = mpsc::channel(1);
        let (cancel, mut cancellation) = watch::channel(false);
        std::thread::Builder::new().name("koe-provider".into()).spawn(move || {
            runtime.block_on(async {
                loop {
                    let request = tokio::select! {
                        biased;
                        _ = cancellation.changed() => break,
                        request = input.recv() => match request { Some(r) => r, None => break },
                    };
                    let result = tokio::select! {
                        biased;
                        _ = cancellation.changed() => break,
                        result = tokio::time::timeout(request.timeout, execute(&request)) => {
                            result.unwrap_or_else(|_| Err("云端请求超时，结果未知；未自动重试".into()))
                        }
                    };
                    let event = ProviderEvent {
                        operation_id: request.operation_id, record_id: request.record_id, result,
                    };
                    if output.send(event).await.is_err() { break; }
                }
            });
            runtime.shutdown_timeout(Duration::from_millis(100));
        }).map_err(|_| "无法启动云端工作线程".to_string())?;
        Ok(Self {
            requests,
            events,
            cancel,
            busy: AtomicBool::new(false),
        })
    }

    /// Accepts one task or returns a validation/busy error without sending a request.
    pub fn submit(&self, request: ProviderRequest) -> Result<(), String> {
        validate(&request)?;
        if self
            .busy
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .is_err()
        {
            return Err("已有云端任务正在处理，请稍后重试".into());
        }
        if self.requests.try_send(request).is_err() {
            self.busy.store(false, Ordering::Release);
            return Err("云端工作线程不可用".into());
        }
        Ok(())
    }

    /// Drains completed results without blocking.
    pub fn poll(&mut self) -> Vec<ProviderEvent> {
        let mut results = Vec::new();
        while let Ok(result) = self.events.try_recv() {
            results.push(result);
            self.busy.store(false, Ordering::Release);
        }
        results
    }
}

impl Drop for ProviderWorker {
    fn drop(&mut self) {
        let _ = self.cancel.send(true);
    }
}

fn validate(request: &ProviderRequest) -> Result<(), String> {
    if request.record_id.trim().is_empty() {
        return Err("缺少记录标识".into());
    }
    if request.timeout.is_zero() || request.timeout > Duration::from_secs(1_800) {
        return Err("云端请求超时设置必须在 0 到 30 分钟之间".into());
    }
    let (secure, local) = match &request.task {
        ProviderTask::TranscribePcm16 { pcm16 } => {
            if pcm16.is_empty() || pcm16.len() % 2 != 0 || pcm16.len() > MAX_PCM_BYTES {
                return Err("音频必须为非空 16 位 PCM，且不能超过 64 MiB".into());
            }
            ("wss", "ws")
        }
        ProviderTask::Chat { system, user } => {
            if user.trim().is_empty() || system.len().saturating_add(user.len()) > MAX_TEXT_BYTES {
                return Err("问答内容为空或超过 2 MiB 限制".into());
            }
            ("https", "http")
        }
    };
    validate_endpoint(&request.config, secure, local)
}

fn validate_endpoint(config: &ProviderConfig, secure: &str, local: &str) -> Result<(), String> {
    if config.model.trim().is_empty() {
        return Err("缺少模型名称".into());
    }
    if config.api_key.trim().is_empty() {
        return Err("尚未配置云端 API Key".into());
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
    if url.scheme() != secure && !(url.scheme() == local && loopback) {
        return Err("云端地址必须加密；仅本机服务允许明文连接".into());
    }
    Ok(())
}

async fn execute(request: &ProviderRequest) -> Result<ProviderOutput, String> {
    match &request.task {
        ProviderTask::TranscribePcm16 { pcm16 } => asr::transcribe(&request.config, pcm16).await,
        ProviderTask::Chat { system, user } => chat::complete(&request.config, system, user).await,
    }
}
