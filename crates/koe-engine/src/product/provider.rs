use super::{ProductError, ProductWorkspace};

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
/// Qwen non-realtime synchronous ASR model identifier (<= 5 min, diarization).
pub const QWEN_FLASH_ASR_MODEL: &str = "qwen-audio-3.1-asr-flash";
/// Qwen asynchronous file transcription model identifier (long audio, diarization).
pub const QWEN_FILETRANS_ASR_MODEL: &str = "qwen-audio-3.1-asr-flash-filetrans";
/// Qwen short-segment real-time WebSocket ASR model identifier.
pub const QWEN_MESSAGE_ASR_MODEL: &str = "qwen-audio-3.1-asr-flash-message";

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
            "dashscope.aliyuncs.com".into()
        } else {
            format!("{trimmed}.cn-beijing.maas.aliyuncs.com")
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
        let is_ws = endpoint.starts_with("wss://") || endpoint.starts_with("ws://");
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
            || !safe_endpoint(&self.asr_endpoint, &["wss://", "ws://", "https://", "http://"])
            || !safe_endpoint(&self.chat_endpoint, &["https://", "http://"])
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
            return Err(ProductError::InvalidEvidence);
        }
        Ok(())
    }
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

fn safe_endpoint(value: &str, schemes: &[&str]) -> bool {
    value.len() <= 2048
        && !value.chars().any(|c| c.is_whitespace() || c.is_control())
        && !value.contains(['@', '?', '#'])
        && schemes.iter().any(|scheme| {
            value
                .strip_prefix(scheme)
                .is_some_and(|rest| !rest.is_empty() && !rest.starts_with('/'))
        })
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
    fn default_provider_uses_qwen_asr_and_deepseek_flash_llm() {
        let cfg = ProviderConfiguration::default();
        assert_eq!(cfg.asr_provider, CloudAsrProvider::Qwen);
        assert_eq!(cfg.asr_model, "qwen-audio-3.1-asr-flash-streaming");
        assert_eq!(cfg.asr_endpoint, DEFAULT_DASHSCOPE_WS_URL);
        assert_eq!(cfg.llm_provider, LlmProvider::DeepSeek);
        assert_eq!(cfg.model, "deepseek-flash");
        assert_eq!(cfg.chat_endpoint, DEFAULT_DEEPSEEK_CHAT_URL);
        assert!(LlmProvider::parse("qwen").is_none());
        assert_eq!(LlmProvider::parse("deepseek"), Some(LlmProvider::DeepSeek));
        assert_eq!(LlmProvider::parse("custom"), Some(LlmProvider::Custom));
    }

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
}
