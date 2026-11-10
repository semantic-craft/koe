use super::{ProductError, ProductWorkspace};

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
}
impl Default for ProviderConfiguration {
    fn default() -> Self {
        Self {
            model: "qwen-plus".into(),
            asr_endpoint: "wss://dashscope.aliyuncs.com/api-ws/v1/inference".into(),
            chat_endpoint: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"
                .into(),
            credential: CredentialBinding::Uninitialized,
            retired_credentials: Vec::new(),
        }
    }
}
impl ProviderConfiguration {
    /// Validates non-sensitive metadata before persistence or restoration.
    pub fn validate(&self) -> Result<(), ProductError> {
        if self.model.trim().is_empty()
            || self.model.len() > 200
            || !safe_endpoint(&self.asr_endpoint, &["wss://", "ws://"])
            || !safe_endpoint(&self.chat_endpoint, &["https://", "http://"])
            || self.retired_credentials.len() > 64
            || self.retired_credentials.iter().any(|s| !valid_reference(s))
            || matches!(&self.credential, CredentialBinding::Saved(s) if !valid_reference(s) || self.retired_credentials.contains(s))
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
