use std::cmp::Ordering;
use std::time::Duration;

use koe_client_providers::{
    validate_update_endpoint, ProviderConfig, ProviderEvent, ProviderLane, ProviderOutput,
    ProviderRequest, ProviderTask, RemoteRelease, UpdateCheckOutcome,
};
use koe_engine::{
    validate_build_number, SemanticVersion, KOE_APP_BUILD, KOE_GITHUB_LATEST_RELEASE_API_URL,
    KOE_GITHUB_RELEASES_URL,
};
use serde_json::{json, Value};

use crate::local_asr::Readiness;
use crate::{KoeRuntime, SpeechEngine};

const UPDATE_CHECK_TIMEOUT: Duration = Duration::from_secs(15);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum AppUpdateOutcome {
    Idle,
    Checking,
    UpToDate {
        latest_version: String,
        release_url: String,
        checked_at_epoch_sec: Option<u64>,
        message: String,
    },
    Available {
        release: RemoteRelease,
        checked_at_epoch_sec: Option<u64>,
        message: String,
    },
    Unavailable {
        message: String,
        release_url: String,
        checked_at_epoch_sec: Option<u64>,
    },
    Failed {
        message: String,
        release_url: String,
        checked_at_epoch_sec: Option<u64>,
    },
}

pub(crate) struct AppUpdateState {
    pub(crate) current_version: SemanticVersion,
    pub(crate) current_build: String,
    pub(crate) endpoint: String,
    pub(crate) pending_operation_id: Option<u64>,
    pub(crate) last_remote: Option<RemoteRelease>,
    pub(crate) active_notice: Option<String>,
    pub(crate) outcome: AppUpdateOutcome,
}

impl Default for AppUpdateState {
    fn default() -> Self {
        Self {
            current_version: SemanticVersion::current(),
            current_build: KOE_APP_BUILD.to_owned(),
            endpoint: KOE_GITHUB_LATEST_RELEASE_API_URL.to_owned(),
            pending_operation_id: None,
            last_remote: None,
            active_notice: None,
            outcome: AppUpdateOutcome::Idle,
        }
    }
}

impl AppUpdateState {
    fn checked_timestamp(&self) -> Option<u64> {
        match &self.outcome {
            AppUpdateOutcome::UpToDate {
                checked_at_epoch_sec,
                ..
            }
            | AppUpdateOutcome::Available {
                checked_at_epoch_sec,
                ..
            }
            | AppUpdateOutcome::Unavailable {
                checked_at_epoch_sec,
                ..
            }
            | AppUpdateOutcome::Failed {
                checked_at_epoch_sec,
                ..
            } => *checked_at_epoch_sec,
            AppUpdateOutcome::Idle | AppUpdateOutcome::Checking => None,
        }
    }

    pub(crate) fn apply_remote_release(
        &mut self,
        remote: RemoteRelease,
        checked_at_epoch_sec: Option<u64>,
    ) -> bool {
        let remote_str = remote.version.to_string();
        match remote.version.cmp(&self.current_version) {
            Ordering::Greater => {
                let message = format!("发现新版本 v{remote_str}");
                self.outcome = AppUpdateOutcome::Available {
                    release: remote,
                    checked_at_epoch_sec,
                    message,
                };
                true
            }
            Ordering::Equal => {
                self.outcome = AppUpdateOutcome::UpToDate {
                    latest_version: remote_str.clone(),
                    release_url: remote.release_url,
                    checked_at_epoch_sec,
                    message: format!("当前已是最新版本（v{remote_str}）"),
                };
                false
            }
            Ordering::Less => {
                let current_str = self.current_version.to_string();
                self.outcome = AppUpdateOutcome::UpToDate {
                    latest_version: remote_str.clone(),
                    release_url: remote.release_url,
                    checked_at_epoch_sec,
                    message: format!(
                        "当前运行版本（v{current_str}）新于最新公开发行版（v{remote_str}）"
                    ),
                };
                false
            }
        }
    }
}

fn parse_bundle_version_or_current(raw: &str) -> SemanticVersion {
    if let Ok(parsed) = SemanticVersion::parse(raw) {
        return parsed;
    }
    let trimmed = raw.trim();
    if let Some((core, suffix)) = trimmed.split_once('-') {
        let suffix_core = suffix.split_once('+').map_or(suffix, |(pre, _)| pre);
        if !suffix_core.is_empty()
            && suffix_core
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-')
        {
            if let Ok(parsed) = SemanticVersion::parse(core) {
                return parsed;
            }
        }
    }
    SemanticVersion::current()
}

impl KoeRuntime {
    fn clear_app_update_notice(&mut self) {
        if let Some(expected) = self.app_update.active_notice.take() {
            if self.notice.as_deref() == Some(expected.as_str()) {
                self.notice = None;
            }
        }
    }

    pub(crate) fn sync_app_metadata(
        &mut self,
        version: &str,
        build: &str,
        update_endpoint: Option<&str>,
        platform_patch: crate::platform::PlatformMetadataPatch<'_>,
    ) -> Result<(), String> {
        let next_platform = self.platform.apply_patch(platform_patch)?;
        let endpoint = update_endpoint.map(str::trim);
        if let Some(endpoint) = endpoint {
            validate_update_endpoint(endpoint)?;
        }
        if !next_platform.supports_native_speech
            && self.local_asr.state == Readiness::Unavailable
            && !self.store.requires_reopen()
            && self.workspace().provider_configuration().speech_engine == SpeechEngine::AppleSpeech
        {
            self.configure_speech("cloud", None)?;
        }
        if let Some(endpoint) = endpoint.filter(|value| *value != self.app_update.endpoint) {
            self.cancel_app_update_check();
            self.app_update.last_remote = None;
            self.app_update.outcome = AppUpdateOutcome::Idle;
            self.app_update.endpoint = endpoint.to_owned();
            self.clear_app_update_notice();
        }
        self.platform = next_platform;
        if !self.platform.supports_system_audio {
            self.capture_studio.include_system_audio = false;
        }
        if !self.platform.supports_self_update {
            self.cancel_app_update_check();
            self.app_update.last_remote = None;
        }
        let parsed_version = parse_bundle_version_or_current(version);
        let valid_build = validate_build_number(build)
            .unwrap_or(KOE_APP_BUILD)
            .to_owned();
        self.app_update.current_version = parsed_version;
        self.app_update.current_build = valid_build;
        if self.app_update.pending_operation_id.is_none() {
            if let Some(remote) = self.app_update.last_remote.clone() {
                let checked_at = self.app_update.checked_timestamp();
                if !self.app_update.apply_remote_release(remote, checked_at) {
                    self.clear_app_update_notice();
                }
            }
        }
        Ok(())
    }

    pub(crate) fn check_app_update(&mut self, now: u64) -> Result<(), String> {
        let eff_now = if now > 0 { now } else { self.last_now_sec };
        let checked_at = (eff_now > 0).then_some(eff_now);
        if !self.platform.supports_self_update {
            self.cancel_app_update_check();
            self.app_update.last_remote = None;
            self.clear_app_update_notice();
            self.app_update.outcome = AppUpdateOutcome::Unavailable {
                message: "当前分发渠道不提供应用内更新".into(),
                release_url: KOE_GITHUB_RELEASES_URL.to_owned(),
                checked_at_epoch_sec: checked_at,
            };
            return Ok(());
        }
        if self.app_update.pending_operation_id.is_some() {
            return Ok(());
        }
        let operation_id = self.next_job;
        self.next_job += 1;
        let request = ProviderRequest {
            operation_id,
            record_id: "app-update".into(),
            config: ProviderConfig::empty(),
            task: ProviderTask::CheckUpdate {
                endpoint: self.app_update.endpoint.clone(),
                user_agent: format!("Koe/{}", self.app_update.current_version),
            },
            timeout: UPDATE_CHECK_TIMEOUT,
        };
        match self.provider.submit(ProviderLane::Update, request) {
            Ok(()) => {
                self.app_update.pending_operation_id = Some(operation_id);
                self.app_update.outcome = AppUpdateOutcome::Checking;
                self.clear_app_update_notice();
            }
            Err(error) => {
                self.app_update.last_remote = None;
                self.clear_app_update_notice();
                self.app_update.outcome = AppUpdateOutcome::Failed {
                    message: error,
                    release_url: KOE_GITHUB_RELEASES_URL.to_owned(),
                    checked_at_epoch_sec: checked_at,
                };
            }
        }
        Ok(())
    }

    pub(crate) fn cancel_app_update_check(&mut self) {
        if let Some(operation_id) = self.app_update.pending_operation_id.take() {
            self.provider.cancel(ProviderLane::Update, operation_id);
        }
        if matches!(self.app_update.outcome, AppUpdateOutcome::Checking) {
            self.app_update.outcome = AppUpdateOutcome::Idle;
        }
        self.clear_app_update_notice();
    }

    pub(crate) fn handle_app_update_event(&mut self, event: &ProviderEvent, now: u64) -> bool {
        if self.app_update.pending_operation_id != Some(event.operation_id) {
            return false;
        }
        self.app_update.pending_operation_id = None;
        let eff_now = if now > 0 { now } else { self.last_now_sec };
        let checked_at = (eff_now > 0).then_some(eff_now);
        match &event.result {
            Ok(ProviderOutput::UpdateCheck(UpdateCheckOutcome::Release(remote))) => {
                self.app_update.last_remote = Some(remote.clone());
                let is_newer = self
                    .app_update
                    .apply_remote_release(remote.clone(), checked_at);
                if is_newer {
                    let msg = format!("发现新版本 v{}，可在设置中查看更新说明", remote.version);
                    self.app_update.active_notice = Some(msg.clone());
                    self.notice = Some(msg);
                } else {
                    self.clear_app_update_notice();
                }
            }
            Ok(ProviderOutput::UpdateCheck(UpdateCheckOutcome::Unavailable { message })) => {
                self.app_update.last_remote = None;
                self.clear_app_update_notice();
                self.app_update.outcome = AppUpdateOutcome::Unavailable {
                    message: message.clone(),
                    release_url: KOE_GITHUB_RELEASES_URL.to_owned(),
                    checked_at_epoch_sec: checked_at,
                };
            }
            Ok(_) => {
                self.app_update.last_remote = None;
                self.clear_app_update_notice();
                self.app_update.outcome = AppUpdateOutcome::Failed {
                    message: "更新响应类型不匹配".into(),
                    release_url: KOE_GITHUB_RELEASES_URL.to_owned(),
                    checked_at_epoch_sec: checked_at,
                };
            }
            Err(error) => {
                self.app_update.last_remote = None;
                self.clear_app_update_notice();
                self.app_update.outcome = AppUpdateOutcome::Failed {
                    message: error.clone(),
                    release_url: KOE_GITHUB_RELEASES_URL.to_owned(),
                    checked_at_epoch_sec: checked_at,
                };
            }
        }
        true
    }

    pub(super) fn app_update_json(&self) -> Value {
        let current_version = self.app_update.current_version.to_string();
        let current_build = &self.app_update.current_build;
        match &self.app_update.outcome {
            AppUpdateOutcome::Idle => json!({
                "currentVersion": current_version,
                "currentBuild": current_build,
                "phase": "idle",
                "checkedAtEpochSec": null,
                "latestVersion": null,
                "releaseTitle": null,
                "publishedAt": null,
                "releaseNotes": null,
                "releaseUrl": KOE_GITHUB_RELEASES_URL,
                "downloadUrl": null,
                "assetName": null,
                "assetSizeBytes": null,
                "message": null,
            }),
            AppUpdateOutcome::Checking => json!({
                "currentVersion": current_version,
                "currentBuild": current_build,
                "phase": "checking",
                "checkedAtEpochSec": null,
                "latestVersion": null,
                "releaseTitle": null,
                "publishedAt": null,
                "releaseNotes": null,
                "releaseUrl": KOE_GITHUB_RELEASES_URL,
                "downloadUrl": null,
                "assetName": null,
                "assetSizeBytes": null,
                "message": "正在连接 GitHub Releases 检查更新…",
            }),
            AppUpdateOutcome::UpToDate {
                latest_version,
                release_url,
                checked_at_epoch_sec,
                message,
            } => json!({
                "currentVersion": current_version,
                "currentBuild": current_build,
                "phase": "up_to_date",
                "checkedAtEpochSec": checked_at_epoch_sec,
                "latestVersion": latest_version,
                "releaseTitle": null,
                "publishedAt": null,
                "releaseNotes": null,
                "releaseUrl": release_url,
                "downloadUrl": null,
                "assetName": null,
                "assetSizeBytes": null,
                "message": message,
            }),
            AppUpdateOutcome::Available {
                release,
                checked_at_epoch_sec,
                message,
            } => json!({
                "currentVersion": current_version,
                "currentBuild": current_build,
                "phase": "available",
                "checkedAtEpochSec": checked_at_epoch_sec,
                "latestVersion": release.version.to_string(),
                "releaseTitle": release.title,
                "publishedAt": release.published_at,
                "releaseNotes": (!release.notes.is_empty()).then_some(&release.notes),
                "releaseUrl": release.release_url,
                "downloadUrl": release.asset.as_ref().map(|a| &a.download_url),
                "assetName": release.asset.as_ref().map(|a| &a.name),
                "assetSizeBytes": release.asset.as_ref().map(|a| a.size_bytes),
                "message": message,
            }),
            AppUpdateOutcome::Unavailable {
                message,
                release_url,
                checked_at_epoch_sec,
            } => json!({
                "currentVersion": current_version,
                "currentBuild": current_build,
                "phase": "unavailable",
                "checkedAtEpochSec": checked_at_epoch_sec,
                "latestVersion": null,
                "releaseTitle": null,
                "publishedAt": null,
                "releaseNotes": null,
                "releaseUrl": release_url,
                "downloadUrl": null,
                "assetName": null,
                "assetSizeBytes": null,
                "message": message,
            }),
            AppUpdateOutcome::Failed {
                message,
                release_url,
                checked_at_epoch_sec,
            } => json!({
                "currentVersion": current_version,
                "currentBuild": current_build,
                "phase": "failed",
                "checkedAtEpochSec": checked_at_epoch_sec,
                "latestVersion": null,
                "releaseTitle": null,
                "publishedAt": null,
                "releaseNotes": null,
                "releaseUrl": release_url,
                "downloadUrl": null,
                "assetName": null,
                "assetSizeBytes": null,
                "message": message,
            }),
        }
    }
}
