use crate::KoeRuntime;
use koe_client_services::product_store::StoreError;
use koe_engine::product::{
    is_loopback_http_endpoint, valid_reference, CloudAsrProvider, CredentialBinding, LlmProvider,
    ProviderConfiguration, DEFAULT_ASR_MODEL,
};

const STORAGE_ERROR: &str = "无法读取或保存安全凭据，请重试读取安全配置。";

#[derive(Default, PartialEq, Eq)]
pub(crate) enum CredentialSlotState {
    #[default]
    Uninitialized,
    Cleared,
    Unavailable,
    MissingSaved,
    ReopenRequired,
    Ready {
        secret: String,
    },
}

impl std::fmt::Debug for CredentialSlotState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Uninitialized => f.write_str("Uninitialized"),
            Self::Cleared => f.write_str("Cleared"),
            Self::Unavailable => f.write_str("Unavailable"),
            Self::MissingSaved => f.write_str("MissingSaved"),
            Self::ReopenRequired => f.write_str("ReopenRequired"),
            Self::Ready { .. } => f.write_str("Ready { secret: <redacted> }"),
        }
    }
}

impl CredentialSlotState {
    pub(crate) fn secret(&self) -> &str {
        match self {
            Self::Ready { secret } => secret.as_str(),
            Self::Uninitialized
            | Self::Cleared
            | Self::Unavailable
            | Self::MissingSaved
            | Self::ReopenRequired => "",
        }
    }

    pub(crate) fn is_ready(&self) -> bool {
        matches!(self, Self::Ready { secret } if !secret.is_empty())
    }

    pub(crate) const fn is_unavailable(&self) -> bool {
        matches!(self, Self::Unavailable | Self::ReopenRequired)
    }

    pub(crate) const fn as_snapshot_str(&self) -> &'static str {
        match self {
            Self::Uninitialized => "missing",
            Self::Cleared => "cleared",
            Self::Unavailable => "unavailable",
            Self::MissingSaved => "missing_saved",
            Self::ReopenRequired => "reopen_required",
            Self::Ready { .. } => "ready",
        }
    }
}

#[derive(Default, Debug)]
pub(crate) struct ProviderSettings {
    pub(crate) qwen: CredentialSlotState,
    pub(crate) deepseek: CredentialSlotState,
}

impl ProviderSettings {
    pub(crate) fn mark_all_unavailable(&mut self) {
        self.qwen = CredentialSlotState::Unavailable;
        self.deepseek = CredentialSlotState::Unavailable;
    }

    pub(crate) fn mark_all_reopen_required(&mut self) {
        self.qwen = CredentialSlotState::ReopenRequired;
        self.deepseek = CredentialSlotState::ReopenRequired;
    }

    pub(crate) const fn any_unavailable(&self) -> bool {
        self.qwen.is_unavailable() || self.deepseek.is_unavailable()
    }

    fn slot(&self, slot: CredentialSlot) -> &CredentialSlotState {
        match slot {
            CredentialSlot::Qwen => &self.qwen,
            CredentialSlot::DeepSeek => &self.deepseek,
        }
    }

    fn set_slot(&mut self, slot: CredentialSlot, state: CredentialSlotState) {
        match slot {
            CredentialSlot::Qwen => self.qwen = state,
            CredentialSlot::DeepSeek => self.deepseek = state,
        }
    }
}

pub(crate) struct ConfigureProviderParams {
    pub api_key: Option<String>,
    pub deepseek_api_key: Option<String>,
    pub asr_provider: Option<String>,
    pub asr_model: Option<String>,
    pub llm_provider: Option<String>,
    pub model: String,
    pub enable_thinking: Option<bool>,
    pub qwen_workspace_id: Option<String>,
    pub asr_endpoint: Option<String>,
    pub chat_endpoint: Option<String>,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum CredentialSlot {
    Qwen,
    DeepSeek,
}
impl CredentialSlot {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Qwen => "qwen",
            Self::DeepSeek => "deepseek",
        }
    }
}

impl KoeRuntime {
    pub(crate) fn credential_state(&self) -> &'static str {
        self.slot_credential_state(CredentialSlot::Qwen)
    }

    pub(crate) fn deepseek_credential_state(&self) -> &'static str {
        self.slot_credential_state(CredentialSlot::DeepSeek)
    }

    fn slot_credential_state(&self, slot: CredentialSlot) -> &'static str {
        if self.store.requires_reopen() {
            "reopen_required"
        } else {
            self.settings.slot(slot).as_snapshot_str()
        }
    }

    pub(crate) fn active_asr_key(&self) -> &str {
        match self.workspace().provider_configuration().asr_provider {
            CloudAsrProvider::Qwen => self.settings.qwen.secret(),
            CloudAsrProvider::DeepSeek => self.settings.deepseek.secret(),
        }
    }

    pub(crate) fn active_llm_key(&self) -> &str {
        match self.workspace().provider_configuration().llm_provider {
            LlmProvider::DeepSeek => self.settings.deepseek.secret(),
            LlmProvider::Custom => {
                if self.settings.deepseek.is_ready() {
                    self.settings.deepseek.secret()
                } else {
                    self.settings.qwen.secret()
                }
            }
        }
    }

    pub(crate) fn cloud_asr_configured(&self) -> bool {
        if !self.active_asr_key().is_empty() {
            return true;
        }
        is_loopback_http_endpoint(&self.workspace().provider_configuration().asr_endpoint)
    }

    pub(crate) fn load_credentials(&mut self) -> Result<(), String> {
        if self.store.requires_reopen() {
            self.settings.mark_all_reopen_required();
            return Err("工作区保存结果尚未确认，请退出并重新打开 Koe。".into());
        }
        self.settings.mark_all_unavailable();

        let qwen_binding = self.workspace().provider_configuration().credential.clone();
        let ds_binding = self
            .workspace()
            .provider_configuration()
            .deepseek_credential
            .clone();
        let need_legacy_qwen = matches!(qwen_binding, CredentialBinding::Uninitialized);
        let need_legacy_ds = self.credentials.isolated()
            && matches!(ds_binding, CredentialBinding::Uninitialized);
        let legacy_values: Option<std::collections::BTreeMap<String, Option<String>>> =
            if need_legacy_qwen || need_legacy_ds {
                match self.credentials.read_legacy().map_err(|_| STORAGE_ERROR)? {
                    None => None,
                    Some(raw) => {
                        let values: std::collections::BTreeMap<String, Option<String>> =
                            serde_json::from_str(&raw).map_err(|_| STORAGE_ERROR)?;
                        if values.keys().any(|k| {
                            ![
                                "qwen",
                                "deepseek",
                                "doubao",
                                "analysisOpenAiCompatible",
                                "mcpSyncToken",
                            ]
                            .contains(&k.as_str())
                        }) {
                            return Err(STORAGE_ERROR.into());
                        }
                        Some(values)
                    }
                }
            } else {
                None
            };

        match qwen_binding {
            CredentialBinding::Saved(reference) => {
                match self
                    .credentials
                    .read(&reference)
                    .map_err(|_| STORAGE_ERROR)?
                {
                    Some(key) => {
                        validate_key(&key)?;
                        self.settings.qwen = CredentialSlotState::Ready { secret: key };
                    }
                    None => {
                        self.settings.qwen = CredentialSlotState::MissingSaved;
                    }
                }
            }
            CredentialBinding::Cleared => {
                self.settings.qwen = CredentialSlotState::Cleared;
            }
            CredentialBinding::Uninitialized => {
                match legacy_values.as_ref().and_then(|v| v.get("qwen")) {
                    Some(Some(key)) if !key.trim().is_empty() => {
                        validate_key(key)?;
                        let configuration = self.workspace().provider_configuration().clone();
                        self.save_credential_slot(configuration, CredentialSlot::Qwen, key.trim())?;
                    }
                    Some(None) => {
                        let mut configuration = self.workspace().provider_configuration().clone();
                        configuration.credential = CredentialBinding::Cleared;
                        self.commit(|w| w.configure_provider(configuration))?;
                        self.settings.qwen = CredentialSlotState::Cleared;
                    }
                    _ => {
                        self.settings.qwen = CredentialSlotState::Uninitialized;
                    }
                }
            }
        }

        match ds_binding {
            CredentialBinding::Saved(reference) => {
                match self
                    .credentials
                    .read(&reference)
                    .map_err(|_| STORAGE_ERROR)?
                {
                    Some(key) => {
                        validate_key(&key)?;
                        self.settings.deepseek = CredentialSlotState::Ready { secret: key };
                    }
                    None => {
                        self.settings.deepseek = CredentialSlotState::MissingSaved;
                    }
                }
            }
            CredentialBinding::Cleared => {
                self.settings.deepseek = CredentialSlotState::Cleared;
            }
            CredentialBinding::Uninitialized => {
                if self.credentials.isolated() {
                    match legacy_values.as_ref().and_then(|v| v.get("deepseek")) {
                        Some(Some(key)) if !key.trim().is_empty() => {
                            validate_key(key)?;
                            let configuration = self.workspace().provider_configuration().clone();
                            self.save_credential_slot(
                                configuration,
                                CredentialSlot::DeepSeek,
                                key.trim(),
                            )?;
                        }
                        _ => {
                            self.settings.deepseek = CredentialSlotState::Uninitialized;
                        }
                    }
                } else {
                    self.settings.deepseek = CredentialSlotState::Uninitialized;
                }
            }
        }
        self.cleanup_credentials()
    }

    pub(crate) fn retry_credentials(&mut self, authorize: bool) -> Result<(), String> {
        if self.store.requires_reopen() {
            self.settings.mark_all_reopen_required();
            return Err("工作区保存结果尚未确认，请退出并重新打开 Koe。".into());
        }
        if authorize {
            let configuration = self.workspace().provider_configuration();
            let reclaimable = configuration
                .retired_credentials
                .iter()
                .chain(&configuration.pending_credentials)
                .next()
                .cloned();
            let mut targets: Vec<Option<String>> = Vec::new();
            if self.settings.qwen.is_unavailable() {
                if let CredentialBinding::Saved(reference) = &configuration.credential {
                    targets.push(Some(reference.clone()));
                }
            }
            if self.settings.deepseek.is_unavailable() {
                if let CredentialBinding::Saved(reference) = &configuration.deepseek_credential {
                    targets.push(Some(reference.clone()));
                }
            }
            if targets.is_empty() {
                if let Some(ref rec) = reclaimable {
                    targets.push(Some(rec.clone()));
                } else {
                    if let CredentialBinding::Saved(reference) = &configuration.credential {
                        targets.push(Some(reference.clone()));
                    }
                    if let CredentialBinding::Saved(reference) = &configuration.deepseek_credential {
                        targets.push(Some(reference.clone()));
                    }
                    if targets.is_empty()
                        && matches!(configuration.credential, CredentialBinding::Uninitialized)
                    {
                        targets.push(None);
                    }
                }
            }
            for reference in targets {
                if self.credentials.authorize(reference.as_deref()).is_err() {
                    if reference.is_none() || reference != reclaimable {
                        self.settings.mark_all_unavailable();
                    }
                    return Err(STORAGE_ERROR.into());
                }
            }
        }
        self.load_credentials()
    }

    pub(crate) fn configure_provider(
        &mut self,
        params: ConfigureProviderParams,
    ) -> Result<(), String> {
        if self.settings.any_unavailable() {
            return Err(STORAGE_ERROR.into());
        }
        let mut configuration = self.workspace().provider_configuration().clone();
        let workspace_changed = params.qwen_workspace_id.is_some();
        if let Some(ws_id) = params.qwen_workspace_id {
            configuration.qwen_workspace_id = ws_id.trim().into();
        }
        let asr_provider_explicit = params.asr_provider.is_some();
        if let Some(raw_provider) = params.asr_provider {
            configuration.asr_provider =
                CloudAsrProvider::parse(&raw_provider).ok_or("无法识别语音识别服务商")?;
        }
        let asr_model_explicit = params.asr_model.is_some();
        if let Some(raw_model) = params.asr_model {
            configuration.asr_model = raw_model.trim().into();
        }
        if configuration.asr_provider == CloudAsrProvider::Qwen
            && configuration.asr_model.trim().is_empty()
        {
            configuration.asr_model = DEFAULT_ASR_MODEL.into();
        }

        let llm_provider_explicit = params.llm_provider.is_some();
        if let Some(raw_llm) = params.llm_provider {
            configuration.llm_provider = LlmProvider::parse(&raw_llm)
                .ok_or("无法识别文本整理服务商（文本处理仅支持 DeepSeek 官方或自定义兼容服务）")?;
        }
        if let Some(thinking) = params.enable_thinking {
            configuration.enable_thinking = thinking;
        }
        configuration.model = params.model.trim().into();

        if let Some(endpoint) = params.asr_endpoint {
            let trimmed = endpoint.trim();
            configuration.asr_endpoint = if trimmed.is_empty() {
                ProviderConfiguration::default_asr_endpoint(
                    configuration.asr_provider,
                    &configuration.asr_model,
                    &configuration.qwen_workspace_id,
                )
            } else {
                if !asr_provider_explicit
                    && ProviderConfiguration::infer_asr_provider(trimmed)
                        == CloudAsrProvider::DeepSeek
                {
                    configuration.asr_provider = CloudAsrProvider::DeepSeek;
                }
                trimmed.into()
            };
        } else if asr_provider_explicit
            || asr_model_explicit
            || (workspace_changed && configuration.asr_provider == CloudAsrProvider::Qwen)
        {
            configuration.asr_endpoint = ProviderConfiguration::default_asr_endpoint(
                configuration.asr_provider,
                &configuration.asr_model,
                &configuration.qwen_workspace_id,
            );
        }

        if let Some(endpoint) = params.chat_endpoint {
            let trimmed = endpoint.trim();
            configuration.chat_endpoint = if trimmed.is_empty() {
                if configuration.llm_provider == LlmProvider::Custom {
                    if llm_provider_explicit {
                        return Err("使用自定义兼容服务时，请填写对话接口地址。".into());
                    }
                    configuration.llm_provider = LlmProvider::DeepSeek;
                }
                ProviderConfiguration::default_chat_endpoint(configuration.llm_provider)
            } else {
                if !llm_provider_explicit {
                    configuration.llm_provider =
                        ProviderConfiguration::infer_llm_provider(trimmed);
                }
                trimmed.into()
            };
        } else if llm_provider_explicit && configuration.llm_provider != LlmProvider::Custom {
            configuration.chat_endpoint =
                ProviderConfiguration::default_chat_endpoint(configuration.llm_provider);
        }

        configuration
            .validate()
            .map_err(|_| "请检查模型名称与服务地址；地址不能包含账户、密码、查询参数或片段。")?;

        if let Some(ref key) = params.api_key {
            if !key.trim().is_empty() {
                validate_key(key)?;
            }
        }
        if let Some(ref key) = params.deepseek_api_key {
            if !key.trim().is_empty() {
                validate_key(key)?;
            }
        }

        let mut committed = false;
        if let Some(key) = params.api_key {
            if key.trim().is_empty() {
                self.clear_credential_slot_with_configuration(
                    configuration.clone(),
                    CredentialSlot::Qwen,
                )?;
            } else {
                self.save_credential_slot(configuration.clone(), CredentialSlot::Qwen, key.trim())?;
            }
            configuration = self.workspace().provider_configuration().clone();
            committed = true;
        }
        if let Some(ds_key) = params.deepseek_api_key {
            if ds_key.trim().is_empty() {
                self.clear_credential_slot_with_configuration(
                    configuration.clone(),
                    CredentialSlot::DeepSeek,
                )?;
            } else {
                self.save_credential_slot(
                    configuration.clone(),
                    CredentialSlot::DeepSeek,
                    ds_key.trim(),
                )?;
            }
            committed = true;
        }
        if !committed {
            self.commit(|w| w.configure_provider(configuration))?;
        }

        self.cleanup_credentials()?;
        self.notice = Some(
            if self.credentials.isolated() {
                "配置已保存；隔离运行的密钥仅在本次会话使用。"
            } else {
                "模型配置与安全凭据已保存。"
            }
            .into(),
        );
        Ok(())
    }

    /// Records the new reference before creating its item, so termination at
    /// any point leaves either a committed binding or a reclaimable reference.
    fn save_credential_slot(
        &mut self,
        mut configuration: ProviderConfiguration,
        slot: CredentialSlot,
        key: &str,
    ) -> Result<(), String> {
        let candidate = self
            .credentials
            .prepare_for_slot(slot.as_str(), key)
            .map_err(|_| STORAGE_ERROR)?;
        if !valid_reference(&candidate) {
            self.mark_slot_unavailable(slot);
            return Err(STORAGE_ERROR.into());
        }
        let mut staged = self.workspace().provider_configuration().clone();
        staged.pending_credentials.push(candidate.clone());
        self.commit(|w| w.configure_provider(staged))?;
        let created = self.credentials.create(&candidate, key).is_ok()
            && self.credentials.read(&candidate).ok().flatten().as_deref() == Some(key);
        if !created {
            self.discard_pending(&candidate);
            return Err(STORAGE_ERROR.into());
        }
        let binding = match slot {
            CredentialSlot::Qwen => &mut configuration.credential,
            CredentialSlot::DeepSeek => &mut configuration.deepseek_credential,
        };
        if let CredentialBinding::Saved(previous) = binding {
            configuration.retired_credentials.push(previous.clone());
        }
        *binding = CredentialBinding::Saved(candidate.clone());
        configuration.pending_credentials = self
            .workspace()
            .provider_configuration()
            .pending_credentials
            .iter()
            .filter(|r| **r != candidate)
            .cloned()
            .collect();
        if let Err(error) = self.store.transact(|w| w.configure_provider(configuration)) {
            if matches!(
                error,
                StoreError::CommitUncertain(_) | StoreError::Unavailable
            ) {
                self.settings.mark_all_reopen_required();
            } else {
                self.discard_pending(&candidate);
            }
            return Err(error.to_string());
        }
        self.settings.set_slot(
            slot,
            CredentialSlotState::Ready {
                secret: key.into(),
            },
        );
        Ok(())
    }

    fn mark_slot_unavailable(&mut self, slot: CredentialSlot) {
        self.settings.set_slot(slot, CredentialSlotState::Unavailable);
    }

    /// Best effort; a reference whose deletion is unconfirmed stays recorded.
    fn discard_pending(&mut self, candidate: &str) {
        if self.credentials.delete(candidate).is_ok() {
            let mut configuration = self.workspace().provider_configuration().clone();
            configuration.pending_credentials.retain(|r| r != candidate);
            let _ = self.commit(|w| w.configure_provider(configuration));
        }
    }

    pub(crate) fn clear_credential(&mut self, provider: Option<&str>) -> Result<(), String> {
        let slot = match provider.map(str::trim) {
            None | Some("") | Some("qwen") => CredentialSlot::Qwen,
            Some("deepseek") => CredentialSlot::DeepSeek,
            _ => return Err("无法识别要清除的服务商凭据".into()),
        };
        self.clear_credential_slot_with_configuration(
            self.workspace().provider_configuration().clone(),
            slot,
        )?;
        self.cleanup_credentials()?;
        self.notice = Some(
            match slot {
                CredentialSlot::Qwen => "Qwen 凭据已清除，旧版密钥不会再次恢复。",
                CredentialSlot::DeepSeek => "DeepSeek 凭据已清除。",
            }
            .into(),
        );
        Ok(())
    }

    fn clear_credential_slot_with_configuration(
        &mut self,
        mut configuration: ProviderConfiguration,
        slot: CredentialSlot,
    ) -> Result<(), String> {
        let binding = match slot {
            CredentialSlot::Qwen => &mut configuration.credential,
            CredentialSlot::DeepSeek => &mut configuration.deepseek_credential,
        };
        if let CredentialBinding::Saved(reference) = binding {
            configuration.retired_credentials.push(reference.clone());
        }
        *binding = CredentialBinding::Cleared;
        self.commit(|w| w.configure_provider(configuration))?;
        self.settings.set_slot(slot, CredentialSlotState::Cleared);
        Ok(())
    }

    fn cleanup_credentials(&mut self) -> Result<(), String> {
        let mut configuration = self.workspace().provider_configuration().clone();
        if configuration.retired_credentials.is_empty()
            && configuration.pending_credentials.is_empty()
        {
            return Ok(());
        }
        let isolated = self.credentials.isolated();
        let mut failed = false;
        for references in [
            &mut configuration.retired_credentials,
            &mut configuration.pending_credentials,
        ] {
            references.retain(|reference| {
                if isolated && !reference.starts_with("isolated-") {
                    return true;
                }
                let retained = self.credentials.delete(reference).is_err();
                failed |= retained;
                retained
            });
        }
        self.commit(|w| w.configure_provider(configuration))?;
        if failed {
            Err("配置已保存，但旧的或未使用的安全凭据尚未删除；重试读取安全配置可继续清理。".into())
        } else {
            Ok(())
        }
    }
}

fn validate_key(key: &str) -> Result<(), String> {
    if key.trim().is_empty() || key.len() > 4096 || key.chars().any(char::is_control) {
        Err("请检查 API Key。".into())
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::CredentialSlotState;

    #[test]
    fn credential_slot_state_redacts_secret_in_debug_and_maps_snapshot_labels() {
        let ready = CredentialSlotState::Ready {
            secret: "sk-top-secret-value".into(),
        };
        let debug = format!("{ready:?}");
        assert!(!debug.contains("sk-top-secret-value"));
        assert!(debug.contains("redacted"));
        assert_eq!(ready.as_snapshot_str(), "ready");
        assert_eq!(CredentialSlotState::Uninitialized.as_snapshot_str(), "missing");
        assert_eq!(CredentialSlotState::Cleared.as_snapshot_str(), "cleared");
        assert_eq!(CredentialSlotState::Unavailable.as_snapshot_str(), "unavailable");
        assert_eq!(CredentialSlotState::MissingSaved.as_snapshot_str(), "missing_saved");
        assert_eq!(
            CredentialSlotState::ReopenRequired.as_snapshot_str(),
            "reopen_required"
        );
    }
}
