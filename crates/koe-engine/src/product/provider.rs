use super::{ProductError, ProductWorkspace};

/// Default DashScope host name when no Qwen Beijing workspace ID is set.
pub const DEFAULT_QWEN_HOST: &str = "dashscope.aliyuncs.com";
/// Host suffix appended to a Qwen Beijing workspace ID.
pub const QWEN_WORKSPACE_HOST_SUFFIX: &str = ".cn-beijing.maas.aliyuncs.com";
/// Default DashScope streaming ASR WebSocket endpoint.
pub const DEFAULT_DASHSCOPE_WS_URL: &str = "wss://dashscope.aliyuncs.com/api-ws/v1/inference";
/// Default DashScope synchronous non-realtime ASR HTTP endpoint (`qwen-audio-3.1-asr-flash`).
pub const DEFAULT_DASHSCOPE_FLASH_ASR_URL: &str =
    "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation";
/// Default DashScope asynchronous file transcription endpoint (`qwen-audio-3.1-asr-flash-filetrans`).
pub const DEFAULT_DASHSCOPE_FILETRANS_ASR_URL: &str =
    "https://dashscope.aliyuncs.com/api/v1/services/audio/asr/transcription";
/// Default DeepSeek OpenAI-compatible chat-completions HTTP endpoint.
pub const DEFAULT_DEEPSEEK_CHAT_URL: &str = "https://api.deepseek.com/chat/completions";
/// Default DeepSeek standalone HTTP ASR endpoint (WAV/Opus, <= 120s per chunk).
pub const DEFAULT_DEEPSEEK_ASR_URL: &str = "https://api.deepseek.com/v1/tools/asr";
/// Default real-time streaming ASR model identifier (Qwen primary).
pub const DEFAULT_ASR_MODEL: &str = "qwen-audio-3.1-asr-flash-streaming";
/// Default text generation and summarization model identifier (DeepSeek 4.1 Flash).
pub const DEFAULT_TEXT_MODEL: &str = "deepseek-flash";
/// Default DeepSeek text generation and summarization model identifier.
pub const DEFAULT_DEEPSEEK_TEXT_MODEL: &str = "deepseek-flash";
/// DeepSeek flagship reasoning text model identifier.
pub const DEEPSEEK_PRO_TEXT_MODEL: &str = "deepseek-v4-pro";
/// Qwen non-realtime synchronous ASR model identifier (<= 5 min, diarization).
pub const QWEN_FLASH_ASR_MODEL: &str = "qwen-audio-3.1-asr-flash";
/// Qwen asynchronous file transcription model identifier (long audio, diarization).
pub const QWEN_FILETRANS_ASR_MODEL: &str = "qwen-audio-3.1-asr-flash-filetrans";
/// Qwen short-segment real-time WebSocket ASR model identifier.
pub const QWEN_MESSAGE_ASR_MODEL: &str = "qwen-audio-3.1-asr-flash-message";

/// Canonical metadata for one supported Qwen cloud ASR model option.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct QwenAsrModelOption {
    /// Model identifier sent to DashScope.
    pub id: &'static str,
    /// Concise Chinese capability note shown in settings.
    pub note: &'static str,
    /// Optional highlight badge (for example, `"默认"`).
    pub badge: Option<&'static str>,
    /// Whether the model supports real-time WebSocket streaming captions.
    pub is_realtime: bool,
    /// Label describing the endpoint protocol mode.
    pub endpoint_label: &'static str,
    /// URL path appended to the resolved Qwen host.
    pub path: &'static str,
    /// Warning shown when live captions are unavailable for this model.
    pub non_realtime_warning: Option<&'static str>,
}

/// Canonical metadata for one supported DeepSeek official LLM model option.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LlmModelOption {
    /// Model identifier sent to the chat completions API.
    pub id: &'static str,
    /// Primary positioning badge shown in settings.
    pub primary_badge: &'static str,
    /// Whether the primary badge highlights the recommended default.
    pub primary_badge_recommended: bool,
    /// Secondary model capability badges.
    pub meta_badges: &'static [&'static str],
    /// Concise Chinese description shown in settings.
    pub description: &'static str,
}

/// Authoritative provider model catalog and default endpoint metadata.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProviderCatalog {
    /// Supported Qwen cloud ASR model options.
    pub qwen_asr_models: &'static [QwenAsrModelOption],
    /// Supported DeepSeek official LLM model options.
    pub deepseek_llm_models: &'static [LlmModelOption],
    /// Default Qwen DashScope authority host when no workspace ID is set.
    pub default_qwen_host: &'static str,
    /// Host suffix appended to a Qwen Beijing workspace ID.
    pub qwen_workspace_host_suffix: &'static str,
    /// Default DeepSeek standalone HTTP ASR endpoint.
    pub default_deepseek_asr_endpoint: &'static str,
    /// Default DeepSeek OpenAI-compatible chat endpoint.
    pub default_deepseek_chat_endpoint: &'static str,
    /// Default Qwen ASR model identifier.
    pub default_qwen_asr_model: &'static str,
    /// Default DeepSeek LLM model identifier.
    pub default_deepseek_llm_model: &'static str,
}

/// Canonical Qwen cloud ASR model options shared across all hosts.
pub const QWEN_ASR_MODELS: &[QwenAsrModelOption] = &[
    QwenAsrModelOption {
        id: DEFAULT_ASR_MODEL,
        note: "WebSocket 实时流式 | 会议/字幕/长录音 | 中间结果与时间戳",
        badge: Some("默认"),
        is_realtime: true,
        endpoint_label: "当前 ASR 接口（WebSocket 实时流式）",
        path: "/api-ws/v1/inference",
        non_realtime_warning: None,
    },
    QwenAsrModelOption {
        id: QWEN_MESSAGE_ASR_MODEL,
        note: "WebSocket 实时短段 | 随心闪记 | 支持原生文本润色",
        badge: None,
        is_realtime: true,
        endpoint_label: "当前 ASR 接口（WebSocket 实时短段）",
        path: "/api-ws/v1/inference",
        non_realtime_warning: None,
    },
    QwenAsrModelOption {
        id: QWEN_FLASH_ASR_MODEL,
        note: "HTTP 非实时（<=5 分钟）| 支持说话人分离与润色",
        badge: None,
        is_realtime: false,
        endpoint_label: "当前 ASR 接口（HTTP 同步 <=5 分钟）",
        path: "/api/v1/services/aigc/multimodal-generation/generation",
        non_realtime_warning: Some(
            "qwen-audio-3.1-asr-flash 为 HTTP 非实时接口（单段 <=5 分钟，支持说话人分离），录音结束后自动转写，不输出边录边看实时字幕。",
        ),
    },
    QwenAsrModelOption {
        id: QWEN_FILETRANS_ASR_MODEL,
        note: "HTTP 异步长录音 | 录音豆离线文件 | 支持说话人分离",
        badge: None,
        is_realtime: false,
        endpoint_label: "当前 ASR 接口（HTTP 异步任务）",
        path: "/api/v1/services/audio/asr/transcription",
        non_realtime_warning: Some(
            "qwen-audio-3.1-asr-flash-filetrans 为异步文件转写任务（适合录音豆离线长录音并支持说话人分离），录音结束后自动转写，不输出实时字幕。",
        ),
    },
];

/// Canonical DeepSeek official LLM model options shared across all hosts.
pub const DEEPSEEK_LLM_MODELS: &[LlmModelOption] = &[
    LlmModelOption {
        id: DEFAULT_DEEPSEEK_TEXT_MODEL,
        primary_badge: "默认推荐",
        primary_badge_recommended: true,
        meta_badges: &["DeepSeek-V4.1-Flash", "1M / 384K"],
        description: "官方最新主力模型，空闲时段 1 元/百万输入、4 元/百万输出（高峰 2 元/8 元），支持思考切换。",
    },
    LlmModelOption {
        id: DEEPSEEK_PRO_TEXT_MODEL,
        primary_badge: "旗舰推理",
        primary_badge_recommended: false,
        meta_badges: &["DeepSeek-V4-Pro", "1M / 384K"],
        description: "面向深度分析与复杂结构化纪要，空闲 4.5 元/13.5 元（高峰 9 元/27 元），最大输出 384K。",
    },
];

/// Canonical provider catalog projected to native hosts.
pub const PROVIDER_CATALOG: ProviderCatalog = ProviderCatalog {
    qwen_asr_models: QWEN_ASR_MODELS,
    deepseek_llm_models: DEEPSEEK_LLM_MODELS,
    default_qwen_host: DEFAULT_QWEN_HOST,
    qwen_workspace_host_suffix: QWEN_WORKSPACE_HOST_SUFFIX,
    default_deepseek_asr_endpoint: DEFAULT_DEEPSEEK_ASR_URL,
    default_deepseek_chat_endpoint: DEFAULT_DEEPSEEK_CHAT_URL,
    default_qwen_asr_model: DEFAULT_ASR_MODEL,
    default_deepseek_llm_model: DEFAULT_DEEPSEEK_TEXT_MODEL,
};

/// Returns the authoritative provider model catalog.
#[must_use]
pub const fn provider_catalog() -> ProviderCatalog {
    PROVIDER_CATALOG
}

/// Whether meeting audio may be sent to a remote speech service.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum MeetingAudioPolicy {
    /// Use the configured cloud speech service.
    CloudAllowed,
    /// Keep meeting audio on this device; text services remain available.
    #[default]
    LocalOnly,
}
impl MeetingAudioPolicy {
    /// Stable persisted and host-facing identifier.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::CloudAllowed => "cloud_allowed",
            Self::LocalOnly => "local_only",
        }
    }
}

/// Cloud speech recognition service provider.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CloudAsrProvider {
    /// Alibaba Cloud Model Studio (DashScope / Qwen).
    #[default]
    Qwen,
    /// DeepSeek official `/v1/tools/asr` HTTP service.
    DeepSeek,
}
impl CloudAsrProvider {
    /// Stable persisted and host-facing identifier.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Qwen => "qwen",
            Self::DeepSeek => "deepseek",
        }
    }
    /// Parses a persisted or host-supplied provider identifier.
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "qwen" => Some(Self::Qwen),
            "deepseek" => Some(Self::DeepSeek),
            _ => None,
        }
    }
}

/// Cloud or local text generation / summarization provider.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum LlmProvider {
    /// DeepSeek official OpenAI-compatible API (primary text provider).
    #[default]
    DeepSeek,
    /// Custom OpenAI-compatible or local localhost service.
    Custom,
}
impl LlmProvider {
    /// Stable persisted and host-facing identifier.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::DeepSeek => "deepseek",
            Self::Custom => "custom",
        }
    }
    /// Parses a persisted or host-supplied LLM provider identifier.
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "deepseek" => Some(Self::DeepSeek),
            "custom" => Some(Self::Custom),
            _ => None,
        }
    }
}

/// Speech execution engine, independent of audio upload permission.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum SpeechEngine {
    /// Native Apple on-device recognition.
    #[default]
    AppleSpeech,
    /// Downloaded model executed inside the Rust client.
    Downloaded(String),
    /// Configured cloud speech service, subject to MeetingAudioPolicy.
    Cloud,
}
impl SpeechEngine {
    /// Stable host identifier.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::AppleSpeech => "apple_speech",
            Self::Downloaded(_) => "downloaded",
            Self::Cloud => "cloud",
        }
    }
}

/// Durable reference to a secret held outside the workspace.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum CredentialBinding {
    /// An older installation may still supply its qwen credential once.
    #[default]
    Uninitialized,
    /// Immutable item in secure platform storage.
    Saved(String),
    /// Explicit user removal. Legacy values must never be restored.
    Cleared,
}

/// Non-sensitive provider preferences and secure-item lifecycle metadata.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProviderConfiguration {
    /// Upload policy for meeting audio, independent of text services.
    pub meeting_audio_policy: MeetingAudioPolicy,
    /// Persisted speech engine selection.
    pub speech_engine: SpeechEngine,
    /// Selected cloud ASR provider when `speech_engine == SpeechEngine::Cloud`.
    pub asr_provider: CloudAsrProvider,
    /// Selected cloud ASR model identifier (used by Qwen; empty or informational for DeepSeek).
    pub asr_model: String,
    /// Selected LLM provider for minutes and Q&A.
    pub llm_provider: LlmProvider,
    /// Text model identifier.
    pub model: String,
    /// Whether deep thinking (`enable_thinking` / `thinking`) is enabled for LLM requests.
    pub enable_thinking: bool,
    /// Optional Alibaba Cloud Model Studio workspace ID (Beijing region dedicated host).
    pub qwen_workspace_id: String,
    /// Complete speech service endpoint, without embedded credentials.
    pub asr_endpoint: String,
    /// Complete chat service endpoint, without embedded credentials.
    pub chat_endpoint: String,
    /// Reference to the Qwen / primary credential; never the credential itself.
    pub credential: CredentialBinding,
    /// Reference to the independent DeepSeek credential; never the credential itself.
    pub deepseek_credential: CredentialBinding,
    /// Superseded items awaiting confirmed deletion.
    pub retired_credentials: Vec<String>,
    /// References recorded before their secure item is created. Each is either
    /// promoted to `credential` / `deepseek_credential` or deleted; a crash leaves it for reclamation.
    pub pending_credentials: Vec<String>,
}
impl Default for ProviderConfiguration {
    fn default() -> Self {
        Self {
            meeting_audio_policy: MeetingAudioPolicy::default(),
            speech_engine: SpeechEngine::default(),
            asr_provider: CloudAsrProvider::default(),
            asr_model: DEFAULT_ASR_MODEL.into(),
            llm_provider: LlmProvider::default(),
            model: DEFAULT_TEXT_MODEL.into(),
            enable_thinking: false,
            qwen_workspace_id: String::new(),
            asr_endpoint: DEFAULT_DASHSCOPE_WS_URL.into(),
            chat_endpoint: DEFAULT_DEEPSEEK_CHAT_URL.into(),
            credential: CredentialBinding::Uninitialized,
            deepseek_credential: CredentialBinding::Uninitialized,
            retired_credentials: Vec::new(),
            pending_credentials: Vec::new(),
        }
    }
}
impl ProviderConfiguration {
    /// Returns the Qwen DashScope host name derived from an optional Beijing workspace ID.
    #[must_use]
    pub fn qwen_host(workspace_id: &str) -> String {
        let trimmed = workspace_id.trim();
        if trimmed.is_empty() {
            DEFAULT_QWEN_HOST.into()
        } else {
            format!("{trimmed}{QWEN_WORKSPACE_HOST_SUFFIX}")
        }
    }

    /// Computes the canonical default ASR endpoint for a provider, model, and workspace ID.
    #[must_use]
    pub fn default_asr_endpoint(
        provider: CloudAsrProvider,
        asr_model: &str,
        workspace_id: &str,
    ) -> String {
        match provider {
            CloudAsrProvider::DeepSeek => DEFAULT_DEEPSEEK_ASR_URL.into(),
            CloudAsrProvider::Qwen => {
                let host = Self::qwen_host(workspace_id);
                match asr_model.trim() {
                    QWEN_FLASH_ASR_MODEL => {
                        format!("https://{host}/api/v1/services/aigc/multimodal-generation/generation")
                    }
                    QWEN_FILETRANS_ASR_MODEL => {
                        format!("https://{host}/api/v1/services/audio/asr/transcription")
                    }
                    _ => format!("wss://{host}/api-ws/v1/inference"),
                }
            }
        }
    }

    /// Computes the canonical default chat endpoint for an LLM provider.
    #[must_use]
    pub fn default_chat_endpoint(_provider: LlmProvider) -> String {
        DEFAULT_DEEPSEEK_CHAT_URL.into()
    }

    /// Infers the cloud ASR provider from an endpoint's authority host.
    #[must_use]
    pub fn infer_asr_provider(endpoint: &str) -> CloudAsrProvider {
        match endpoint_host(endpoint) {
            Some(host) if host.eq_ignore_ascii_case("api.deepseek.com") => {
                CloudAsrProvider::DeepSeek
            }
            _ => CloudAsrProvider::Qwen,
        }
    }

    /// Infers the LLM provider from an endpoint's authority host.
    #[must_use]
    pub fn infer_llm_provider(endpoint: &str) -> LlmProvider {
        match endpoint_host(endpoint) {
            Some(host) if host.eq_ignore_ascii_case("api.deepseek.com") => LlmProvider::DeepSeek,
            _ => LlmProvider::Custom,
        }
    }

    /// Returns whether an endpoint belongs to Alibaba Cloud DashScope / Model Studio
    /// (used only to migrate legacy persisted Qwen LLM settings to DeepSeek).
    #[must_use]
    pub fn is_legacy_qwen_chat_endpoint(endpoint: &str) -> bool {
        match endpoint_host(endpoint) {
            Some(host) => {
                host.eq_ignore_ascii_case("dashscope.aliyuncs.com")
                    || host
                        .to_ascii_lowercase()
                        .ends_with(".maas.aliyuncs.com")
            }
            None => false,
        }
    }

    /// Whether the configured cloud ASR model supports real-time WebSocket streaming captions.
    #[must_use]
    pub fn is_realtime_cloud_asr(&self) -> bool {
        if self.asr_provider != CloudAsrProvider::Qwen {
            return false;
        }
        let endpoint = self.asr_endpoint.trim();
        let is_ws = endpoint
            .split_once("://")
            .is_some_and(|(scheme, _)| {
                scheme.eq_ignore_ascii_case("wss") || scheme.eq_ignore_ascii_case("ws")
            });
        is_ws
            && !matches!(
                self.asr_model.trim(),
                QWEN_FLASH_ASR_MODEL | QWEN_FILETRANS_ASR_MODEL
            )
    }

    /// Validates non-sensitive metadata before persistence or restoration.
    pub fn validate(&self) -> Result<(), ProductError> {
        let pending = &self.pending_credentials;
        let same_saved_ref = matches!(
            (&self.credential, &self.deepseek_credential),
            (CredentialBinding::Saved(a), CredentialBinding::Saved(b)) if a == b
        );
        let valid_ws_id = self.qwen_workspace_id.len() <= 128
            && self
                .qwen_workspace_id
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_');
        let valid_asr_model = self.asr_model.len() <= 200
            && (self.asr_provider == CloudAsrProvider::DeepSeek
                || !self.asr_model.trim().is_empty());
        if matches!(&self.speech_engine, SpeechEngine::Downloaded(id) if id.is_empty() || id.len() > 200)
            || !valid_asr_model
            || !valid_ws_id
            || self.model.trim().is_empty()
            || self.model.len() > 200
            || validate_provider_endpoint(&self.asr_endpoint, &["wss", "ws", "https", "http"])
                .is_err()
            || validate_provider_endpoint(&self.chat_endpoint, &["https", "http"]).is_err()
            || self.retired_credentials.len() > 64
            || self.retired_credentials.iter().any(|s| !valid_reference(s))
            || matches!(&self.credential, CredentialBinding::Saved(s) if !valid_reference(s) || self.retired_credentials.contains(s) || pending.contains(s))
            || matches!(&self.deepseek_credential, CredentialBinding::Saved(s) if !valid_reference(s) || self.retired_credentials.contains(s) || pending.contains(s))
            || same_saved_ref
            || pending.len() > 64
            || pending
                .iter()
                .enumerate()
                .any(|(i, s)| !valid_reference(s) || pending[..i].contains(s))
        {
            return Err(ProductError::InvalidConfiguration);
        }
        Ok(())
    }
}

/// Failure classification returned by [`validate_provider_endpoint`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EndpointValidationError {
    /// Endpoint is empty, oversized, contains whitespace/control chars, or has an invalid host/port.
    InvalidSyntax,
    /// Endpoint embeds userinfo (`@`), query parameters (`?`), or a fragment (`#`).
    DisallowedComponents,
    /// Endpoint scheme is not allowed for the requested transport.
    UnsupportedScheme,
    /// Endpoint uses plaintext `http://` or `ws://` against a non-loopback host.
    InsecureNonLoopback,
}

/// Returns `true` when `host` resolves syntactically to `localhost` or a loopback IP literal.
#[must_use]
pub fn is_loopback_host_str(host: &str) -> bool {
    let trimmed = host.trim().trim_end_matches('.');
    if trimmed.eq_ignore_ascii_case("localhost") {
        return true;
    }
    trimmed
        .trim_matches(['[', ']'])
        .parse::<std::net::IpAddr>()
        .is_ok_and(|ip| match ip {
            std::net::IpAddr::V4(v4) => v4.is_loopback(),
            std::net::IpAddr::V6(v6) => {
                v6.is_loopback() || v6.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback())
            }
        })
}

/// Returns `true` when `endpoint` is a valid plaintext `http://` URL targeting a loopback host.
#[must_use]
pub fn is_loopback_http_endpoint(endpoint: &str) -> bool {
    endpoint
        .split_once("://")
        .is_some_and(|(scheme, _)| scheme.eq_ignore_ascii_case("http"))
        && validate_provider_endpoint(endpoint, &["https", "http"])
            .is_ok_and(|loopback| loopback)
}

/// Validates a provider endpoint against unified syntax, component, scheme, and TLS-or-loopback rules.
///
/// Returns `Ok(is_loopback)` when valid.
pub fn validate_provider_endpoint(
    value: &str,
    allowed_schemes: &[&str],
) -> Result<bool, EndpointValidationError> {
    if value.is_empty()
        || value.len() > 2048
        || value.chars().any(|c| c.is_whitespace() || c.is_control())
    {
        return Err(EndpointValidationError::InvalidSyntax);
    }
    if value.contains(['@', '?', '#']) {
        return Err(EndpointValidationError::DisallowedComponents);
    }
    let Some((scheme, rest)) = value.split_once("://") else {
        return Err(EndpointValidationError::InvalidSyntax);
    };
    if !allowed_schemes
        .iter()
        .any(|allowed| scheme.eq_ignore_ascii_case(allowed))
    {
        return Err(EndpointValidationError::UnsupportedScheme);
    }
    if rest.is_empty() || rest.starts_with('/') {
        return Err(EndpointValidationError::InvalidSyntax);
    }
    let authority = rest.split('/').next().unwrap_or("");
    if authority.is_empty() {
        return Err(EndpointValidationError::InvalidSyntax);
    }
    let host = if let Some(after_open) = authority.strip_prefix('[') {
        let Some((ip, suffix)) = after_open.split_once(']') else {
            return Err(EndpointValidationError::InvalidSyntax);
        };
        if ip.is_empty() || ip.parse::<std::net::Ipv6Addr>().is_err() {
            return Err(EndpointValidationError::InvalidSyntax);
        }
        if !suffix.is_empty() {
            let Some(port) = suffix.strip_prefix(':') else {
                return Err(EndpointValidationError::InvalidSyntax);
            };
            if port.is_empty() || port.parse::<u16>().is_err() {
                return Err(EndpointValidationError::InvalidSyntax);
            }
        }
        ip
    } else {
        if authority.contains(['[', ']']) {
            return Err(EndpointValidationError::InvalidSyntax);
        }
        let (host, port) = match authority.split_once(':') {
            Some((h, p)) => (h, Some(p)),
            None => (authority, None),
        };
        if host.is_empty() {
            return Err(EndpointValidationError::InvalidSyntax);
        }
        if let Some(port) = port {
            if port.is_empty() || port.parse::<u16>().is_err() {
                return Err(EndpointValidationError::InvalidSyntax);
            }
        }
        host
    };
    let loopback = is_loopback_host_str(host);
    if (scheme.eq_ignore_ascii_case("http") || scheme.eq_ignore_ascii_case("ws")) && !loopback {
        return Err(EndpointValidationError::InsecureNonLoopback);
    }
    Ok(loopback)
}

/// Whether a platform reference is safe for an exact secure-item lookup.
pub fn valid_reference(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-')
}
fn endpoint_host(endpoint: &str) -> Option<&str> {
    let trimmed = endpoint.trim();
    let (_, rest) = trimmed.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next()?;
    let host_port = authority.rsplit('@').next()?;
    if host_port.starts_with('[') {
        host_port.split(']').next().map(|h| h.trim_start_matches('['))
    } else {
        host_port.split(':').next()
    }
    .filter(|h| !h.is_empty())
}
impl ProductWorkspace {
    /// Persisted provider settings, excluding all secret values.
    pub fn provider_configuration(&self) -> &ProviderConfiguration {
        &self.provider_configuration
    }
    /// Replaces provider settings inside the workspace transaction.
    pub fn configure_provider(&mut self, value: ProviderConfiguration) -> Result<(), ProductError> {
        value.validate()?;
        if self.provider_configuration != value {
            self.provider_configuration = value;
            self.changed();
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_inference_matches_authority_host_only() {
        assert_eq!(
            ProviderConfiguration::infer_asr_provider("https://api.deepseek.com/v1/tools/asr"),
            CloudAsrProvider::DeepSeek
        );
        assert_eq!(
            ProviderConfiguration::infer_asr_provider("https://evil.example/api.deepseek.com/asr"),
            CloudAsrProvider::Qwen
        );
        assert_eq!(
            ProviderConfiguration::infer_llm_provider("https://api.deepseek.com/chat/completions"),
            LlmProvider::DeepSeek
        );
        assert!(ProviderConfiguration::is_legacy_qwen_chat_endpoint(
            "https://ws-bj.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
        ));
        assert!(ProviderConfiguration::is_legacy_qwen_chat_endpoint(
            "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
        ));
        assert!(!ProviderConfiguration::is_legacy_qwen_chat_endpoint(
            "https://evil.example/dashscope.aliyuncs.com/chat/completions"
        ));
        assert_eq!(
            ProviderConfiguration::infer_llm_provider(
                "https://ws-bj.cn-beijing.maas.aliyuncs.com/compatible-mode/v1/chat/completions"
            ),
            LlmProvider::Custom
        );
        assert_eq!(
            ProviderConfiguration::infer_llm_provider(
                "https://evil.example/api.deepseek.com/chat/completions"
            ),
            LlmProvider::Custom
        );
        assert_eq!(
            ProviderConfiguration::infer_llm_provider(
                "https://evil.example/dashscope.aliyuncs.com/chat/completions"
            ),
            LlmProvider::Custom
        );
    }

    #[test]
    fn provider_configuration_rejects_plaintext_non_loopback_endpoints() {
        let bad_http = ProviderConfiguration {
            chat_endpoint: "http://192.168.1.5/v1/chat/completions".into(),
            ..Default::default()
        };
        assert_eq!(bad_http.validate(), Err(ProductError::InvalidConfiguration));

        let bad_ws = ProviderConfiguration {
            asr_endpoint: "ws://example.com/api-ws/v1/inference".into(),
            ..Default::default()
        };
        assert_eq!(bad_ws.validate(), Err(ProductError::InvalidConfiguration));

        let ok_loopback = ProviderConfiguration {
            chat_endpoint: "http://127.0.0.1:8080/v1/chat/completions".into(),
            asr_endpoint: "ws://localhost:9001/asr".into(),
            ..Default::default()
        };
        assert!(ok_loopback.validate().is_ok());
    }

    #[test]
    fn validate_provider_endpoint_matches_schemes_case_insensitively_and_rejects_uppercase_insecure_remote() {
        assert_eq!(
            validate_provider_endpoint("HTTPS://api.deepseek.com/chat/completions", &["https", "http"]),
            Ok(false)
        );
        assert_eq!(
            validate_provider_endpoint("HTTP://127.0.0.1:8080/chat/completions", &["https", "http"]),
            Ok(true)
        );
        assert!(is_loopback_http_endpoint("HTTP://127.0.0.1:8080/chat/completions"));
        assert_eq!(
            validate_provider_endpoint("HTTP://evil.example.com/chat/completions", &["https", "http"]),
            Err(EndpointValidationError::InsecureNonLoopback)
        );
        assert_eq!(
            validate_provider_endpoint("FTP://api.deepseek.com/chat/completions", &["https", "http"]),
            Err(EndpointValidationError::UnsupportedScheme)
        );
    }

    #[test]
    fn provider_catalog_matches_default_endpoints_and_qwen_host_rules() {
        let catalog = provider_catalog();
        assert_eq!(catalog.default_qwen_host, DEFAULT_QWEN_HOST);
        assert_eq!(
            catalog.qwen_workspace_host_suffix,
            QWEN_WORKSPACE_HOST_SUFFIX
        );
        assert_eq!(
            catalog.default_deepseek_asr_endpoint,
            DEFAULT_DEEPSEEK_ASR_URL
        );
        assert_eq!(
            catalog.default_deepseek_chat_endpoint,
            DEFAULT_DEEPSEEK_CHAT_URL
        );
        assert_eq!(catalog.default_qwen_asr_model, DEFAULT_ASR_MODEL);
        assert_eq!(catalog.default_deepseek_llm_model, DEFAULT_DEEPSEEK_TEXT_MODEL);
        assert_eq!(catalog.qwen_asr_models.len(), 4);
        assert_eq!(catalog.deepseek_llm_models.len(), 2);

        for ws in ["", "ws-bj-01"] {
            let host = ProviderConfiguration::qwen_host(ws);
            for opt in catalog.qwen_asr_models {
                let scheme = if opt.is_realtime { "wss://" } else { "https://" };
                let expected = format!("{scheme}{host}{}", opt.path);
                assert_eq!(
                    ProviderConfiguration::default_asr_endpoint(
                        CloudAsrProvider::Qwen,
                        opt.id,
                        ws,
                    ),
                    expected,
                    "endpoint mismatch for model {}",
                    opt.id
                );
            }
        }
    }
}
