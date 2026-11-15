use super::{ProductError, ProductWorkspace};

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
    /// Text model identifier.
    pub model: String,
    /// Complete speech service endpoint, without embedded credentials.
    pub asr_endpoint: String,
    /// Complete chat service endpoint, without embedded credentials.
    pub chat_endpoint: String,
    /// Reference only; never the credential itself.
    pub credential: CredentialBinding,
    /// Superseded items awaiting confirmed deletion.
    pub retired_credentials: Vec<String>,
    /// References recorded before their secure item is created. Each is either
    /// promoted to `credential` or deleted; a crash leaves it for reclamation.
    pub pending_credentials: Vec<String>,
}
impl Default for ProviderConfiguration {
    fn default() -> Self {
        Self {
            meeting_audio_policy: MeetingAudioPolicy::default(),
            speech_engine: SpeechEngine::default(),
            model: "qwen-plus".into(),
            asr_endpoint: "wss://dashscope.aliyuncs.com/api-ws/v1/inference".into(),
            chat_endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
                .into(),
            credential: CredentialBinding::Uninitialized,
            retired_credentials: Vec::new(),
            pending_credentials: Vec::new(),
        }
    }
}
impl ProviderConfiguration {
    /// Validates non-sensitive metadata before persistence or restoration.
    pub fn validate(&self) -> Result<(), ProductError> {
        let pending = &self.pending_credentials;
        if matches!(&self.speech_engine, SpeechEngine::Downloaded(id) if id.is_empty() || id.len() > 200)
            || self.model.trim().is_empty()
            || self.model.len() > 200
            || !safe_endpoint(&self.asr_endpoint, &["wss://", "ws://"])
            || !safe_endpoint(&self.chat_endpoint, &["https://", "http://"])
            || self.retired_credentials.len() > 64
            || self.retired_credentials.iter().any(|s| !valid_reference(s))
            || matches!(&self.credential, CredentialBinding::Saved(s) if !valid_reference(s) || self.retired_credentials.contains(s) || pending.contains(s))
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
