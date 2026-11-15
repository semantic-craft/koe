use crate::KoeRuntime;
use koe_client_services::product_store::StoreError;
use koe_engine::product::{valid_reference, CredentialBinding, ProviderConfiguration};

const STORAGE_ERROR: &str = "无法读取或保存安全凭据，请重试读取安全配置。";
#[derive(Default)]
pub(crate) struct ProviderSettings {
    pub key: String,
    pub unavailable: bool,
}
impl KoeRuntime {
    pub(crate) fn credential_state(&self) -> &'static str {
        if self.store.requires_reopen() {
            "reopen_required"
        } else if self.settings.unavailable {
            "unavailable"
        } else if !self.settings.key.is_empty() {
            "ready"
        } else if matches!(
            self.workspace().provider_configuration().credential,
            CredentialBinding::Cleared
        ) {
            "cleared"
        } else if matches!(
            self.workspace().provider_configuration().credential,
            CredentialBinding::Saved(_)
        ) {
            "missing_saved"
        } else {
            "missing"
        }
    }
    pub(crate) fn load_credentials(&mut self) -> Result<(), String> {
        if self.store.requires_reopen() {
            return Err("工作区保存结果尚未确认，请退出并重新打开 Koe。".into());
        }
        self.settings.key.clear();
        self.settings.unavailable = true;
        let binding = self.workspace().provider_configuration().credential.clone();
        let value = match binding {
            CredentialBinding::Saved(reference) => self
                .credentials
                .read(&reference)
                .map_err(|_| STORAGE_ERROR)?,
            CredentialBinding::Cleared => None,
            CredentialBinding::Uninitialized => {
                let legacy = self.credentials.read_legacy().map_err(|_| STORAGE_ERROR)?;
                match legacy {
                    None => None,
                    Some(raw) => {
                        let values: std::collections::BTreeMap<String, Option<String>> =
                            serde_json::from_str(&raw).map_err(|_| STORAGE_ERROR)?;
                        if values.keys().any(|k| {
                            !["qwen", "doubao", "analysisOpenAiCompatible", "mcpSyncToken"]
                                .contains(&k.as_str())
                        }) {
                            return Err(STORAGE_ERROR.into());
                        }
                        match values.get("qwen") {
                            Some(Some(key)) if !key.trim().is_empty() => {
                                validate_key(key)?;
                                let configuration =
                                    self.workspace().provider_configuration().clone();
                                self.save_credential(configuration, key)?;
                                return self.cleanup_credentials();
                            }
                            Some(None) => {
                                let mut configuration =
                                    self.workspace().provider_configuration().clone();
                                configuration.credential = CredentialBinding::Cleared;
                                self.commit(|w| w.configure_provider(configuration))?;
                                None
                            }
                            _ => None,
                        }
                    }
                }
            }
        };
        if let Some(key) = value {
            validate_key(&key)?;
            self.settings.key = key;
        }
        self.settings.unavailable = false;
        self.cleanup_credentials()
    }
    pub(crate) fn retry_credentials(&mut self, authorize: bool) -> Result<(), String> {
        if self.store.requires_reopen() {
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
            let target = match &configuration.credential {
                CredentialBinding::Saved(reference) if self.settings.unavailable => {
                    Some(Some(reference.clone()))
                }
                _ if reclaimable.is_some() => Some(reclaimable.clone()),
                CredentialBinding::Saved(reference) => Some(Some(reference.clone())),
                CredentialBinding::Uninitialized => Some(None),
                CredentialBinding::Cleared => None,
            };
            if let Some(reference) = target {
                if self.credentials.authorize(reference.as_deref()).is_err() {
                    if reference.is_none() || reference != reclaimable {
                        self.settings.key.clear();
                        self.settings.unavailable = true;
                    }
                    return Err(STORAGE_ERROR.into());
                }
            }
        }
        self.load_credentials()
    }
    pub(crate) fn configure_provider(
        &mut self,
        key: Option<String>,
        model: String,
        asr: Option<String>,
        chat: Option<String>,
    ) -> Result<(), String> {
        if self.settings.unavailable {
            return Err(STORAGE_ERROR.into());
        }
        let mut configuration = self.workspace().provider_configuration().clone();
        configuration.model = model.trim().into();
        if let Some(endpoint) = asr {
            configuration.asr_endpoint = if endpoint.trim().is_empty() {
                ProviderConfiguration::default().asr_endpoint
            } else {
                endpoint.trim().into()
            };
        }
        if let Some(endpoint) = chat {
            configuration.chat_endpoint = if endpoint.trim().is_empty() {
                ProviderConfiguration::default().chat_endpoint
            } else {
                endpoint.trim().into()
            };
        }
        configuration
            .validate()
            .map_err(|_| "请检查模型名称与服务地址；地址不能包含账户、密码、查询参数或片段。")?;
        match key {
            Some(key) if key.trim().is_empty() => {
                self.clear_credential_with_configuration(configuration)?;
            }
            Some(key) => {
                validate_key(&key)?;
                self.save_credential(configuration, key.trim())?;
            }
            None => self.commit(|w| w.configure_provider(configuration))?,
        }
        self.cleanup_credentials()?;
        self.notice = Some(
            if self.credentials.isolated() {
                "配置已保存；隔离运行的密钥仅在本次会话使用。"
            } else {
                "配置与安全凭据已保存。"
            }
            .into(),
        );
        Ok(())
    }
    /// Records the new reference before creating its item, so termination at
    /// any point leaves either a committed binding or a reclaimable reference.
    fn save_credential(
        &mut self,
        mut configuration: ProviderConfiguration,
        key: &str,
    ) -> Result<(), String> {
        let candidate = self.credentials.prepare(key).map_err(|_| STORAGE_ERROR)?;
        if !valid_reference(&candidate) {
            self.settings.unavailable = true;
            self.settings.key.clear();
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
        if let CredentialBinding::Saved(previous) = &configuration.credential {
            configuration.retired_credentials.push(previous.clone());
        }
        configuration.pending_credentials = self
            .workspace()
            .provider_configuration()
            .pending_credentials
            .iter()
            .filter(|r| **r != candidate)
            .cloned()
            .collect();
        configuration.credential = CredentialBinding::Saved(candidate.clone());
        if let Err(error) = self.store.transact(|w| w.configure_provider(configuration)) {
            if matches!(
                error,
                StoreError::CommitUncertain(_) | StoreError::Unavailable
            ) {
                // The binding may be on disk; reopening decides from durable truth.
                self.settings.key.clear();
                self.settings.unavailable = true;
            } else {
                self.discard_pending(&candidate);
            }
            return Err(error.to_string());
        }
        self.settings.key = key.into();
        self.settings.unavailable = false;
        Ok(())
    }
    /// Best effort; a reference whose deletion is unconfirmed stays recorded.
    fn discard_pending(&mut self, candidate: &str) {
        if self.credentials.delete(candidate).is_ok() {
            let mut configuration = self.workspace().provider_configuration().clone();
            configuration.pending_credentials.retain(|r| r != candidate);
            let _ = self.commit(|w| w.configure_provider(configuration));
        }
    }
    pub(crate) fn clear_credential(&mut self) -> Result<(), String> {
        self.clear_credential_with_configuration(
            self.workspace().provider_configuration().clone(),
        )?;
        self.cleanup_credentials()?;
        self.notice = Some("凭据已清除，旧版密钥不会再次恢复。".into());
        Ok(())
    }
    fn clear_credential_with_configuration(
        &mut self,
        mut configuration: ProviderConfiguration,
    ) -> Result<(), String> {
        if let CredentialBinding::Saved(reference) = &configuration.credential {
            configuration.retired_credentials.push(reference.clone());
        }
        configuration.credential = CredentialBinding::Cleared;
        self.commit(|w| w.configure_provider(configuration))?;
        self.settings.key.clear();
        self.settings.unavailable = false;
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
