//! A single durable product workspace shared by the native host and CLI.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod all_day;
#[cfg(test)]
mod ask_tests;
mod audio_policy;
#[cfg(test)]
mod audio_policy_tests;
mod capture;
mod capture_studio;
#[cfg(test)]
mod capture_tests;
mod command;
/// Typeless-compatible D3200 collar companion protocol and tap-thump gating state machine.
pub mod companion;
#[cfg(test)]
mod companion_mcp_tests;
pub mod credentials;
mod device;
mod dictation_capture;
mod journal;
mod legacy;
mod lifecycle;
mod live_minutes;
#[cfg(test)]
mod lifecycle_tests;
mod local_asr;
/// Centralized 16-tool MCP registry and step/poll dispatcher shared by native host and CLI.
pub mod mcp_surface;
mod microphone;
#[cfg(test)]
mod navigation_tests;
mod playback;
mod processing;
mod projection;
mod provider_settings;
mod speech;
use provider_settings::ProviderSettings;
mod restore;
mod transcript_edit;
mod trash;

use command::{Command, Location, Page, Playback};
pub use companion::{
    decode_pcm16_le_b64, encode_pcm16_le_b64, resolve_bridge_socket_path, CompanionClientCommand,
    CompanionRoutingMode, CompanionStreamEvent, DeclaredControlSpec, COMPANION_AUDIO_FORMAT,
    COMPANION_DOUBLE_TAP_TRIGGER, COMPANION_FRONT_CONTROL, COMPANION_PROTOCOL_VERSION,
    POST_TAP_SKIP_SLICES, PRE_STOP_TAP_HOLDBACK_SLICES,
};
use device::DeviceRuntime;
use koe_client_providers::ProviderWorker;
use koe_client_services::{product_store::ProductStore, recording_assets};
use koe_engine::{domain::SegmentId, product::*};
pub use mcp_surface::{McpToolCallState, McpToolError};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Version of the native JSON snapshot and command contract.
pub const KOE_HOST_SNAPSHOT_VERSION: u32 = 2;

#[derive(Clone)]
enum PendingWork {
    Transcription(RequestKey),
    Summary(RequestKey),
    Ask(u64),
}

/// Serialized application session. Network I/O runs on an owned background worker.
pub struct KoeRuntime {
    store: ProductStore,
    root: PathBuf,
    generation: u64,
    location: Location,
    back: Vec<Location>,
    playback: Playback,
    device: DeviceRuntime,
    companion: companion::CompanionRuntime,
    provider: ProviderWorker,
    settings: ProviderSettings,
    credentials: Box<dyn credentials::CredentialStore>,
    pending: BTreeMap<u64, PendingWork>,
    completed: std::collections::VecDeque<koe_client_providers::ProviderEvent>,
    captures: capture::Captures,
    local_asr: local_asr::LocalAsr,
    speech: speech::SpeechState,
    dictation_capture: Option<dictation_capture::DictationCapture>,
    all_day: all_day::AllDayState,
    live_minutes_scope: Option<live_minutes::LiveMinutesScope>,
    capture_studio: capture_studio::CaptureStudioState,
    microphone: Option<microphone::Microphone>,
    bean_capture_mode: Option<command::CaptureMode>,
    auto_transcribe: std::collections::BTreeSet<String>,
    auto_summarize: std::collections::BTreeSet<String>,
    next_job: u64,
    error: Option<String>,
    notice: Option<String>,
    audio_policy_error: Option<String>,
    quit: lifecycle::QuitState,
    drain_error: Option<String>,
    undo_trash: Option<trash::UndoTrashBanner>,
    last_now_sec: u64,
}

impl KoeRuntime {
    /// Opens durable state, rejecting corrupted storage and concurrent writers.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        Self::open_with_credentials(path, Box::<credentials::IsolatedCredentials>::default())
    }

    /// Opens with a platform secure storage adapter.
    pub fn open_with_credentials(
        path: impl AsRef<Path>,
        credentials: Box<dyn credentials::CredentialStore>,
    ) -> Result<Self, String> {
        let root = path.as_ref().to_path_buf();
        let existed = root.join("product-workspace.json").exists();
        let store = ProductStore::open(&root).map_err(|e| e.to_string())?;
        let mut runtime = Self {
            store,
            speech: speech::SpeechState::new(&root),
            dictation_capture: None,
            all_day: Default::default(),
            live_minutes_scope: None,
            root,
            generation: 1,
            location: Location::default(),
            back: Vec::new(),
            playback: Playback::default(),
            device: DeviceRuntime::default(),
            companion: Default::default(),
            provider: ProviderWorker::new()?,
            settings: ProviderSettings::default(),
            credentials,
            pending: BTreeMap::new(),
            completed: std::collections::VecDeque::new(),
            captures: Default::default(),
            local_asr: Default::default(),
            capture_studio: Default::default(),
            microphone: None,
            bean_capture_mode: None,
            auto_transcribe: Default::default(),
            auto_summarize: Default::default(),
            next_job: 1,
            error: None,
            notice: None,
            audio_policy_error: None,
            quit: Default::default(),
            drain_error: None,
            undo_trash: None,
            last_now_sec: 0,
        };
        if !existed {
            runtime.restore_legacy()?;
        }
        runtime.recover_local_captures()?;
        runtime.reconcile_orphan_audio();
        if let Err(error) = runtime.load_credentials() {
            runtime.error = Some(error);
        }
        if let SpeechEngine::Downloaded(id) = runtime
            .workspace()
            .provider_configuration()
            .speech_engine
            .clone()
        {
            let _ = runtime.prepare_speech_model(&id);
        }
        Ok(runtime)
    }

    /// Immutable facts for trusted query callers.
    pub fn workspace(&self) -> &ProductWorkspace {
        self.store.workspace()
    }
    /// UI change generation, independent of wall-clock time.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Applies a native command and returns a projection including any operation failure.
    pub fn dispatch_json(&mut self, json: &str, now: u64) -> String {
        let result = if json.len() > 2 * 1024 * 1024 {
            Err("操作内容过大".into())
        } else {
            serde_json::from_str::<Command>(json)
                .map_err(|_| "无法识别此操作，请更新 Koe 后重试".to_string())
                .and_then(|command| {
                    if !matches!(
                        command,
                        Command::PlaybackProgress { .. }
                            | Command::SyncAudioInputs { .. }
                            | Command::LocalAsrReadiness { .. }
                            | Command::LocalAsrResult { .. }
                            | Command::LocalAsrFinished { .. }
                            | Command::LocalAsrFailed { .. }
                    ) {
                        self.error = None;
                        self.notice = None;
                    }
                    self.dispatch(command, now)
                })
        };
        if let Err(error) = result {
            self.error = Some(error);
        }
        self.generation = self.generation.saturating_add(1);
        self.snapshot_json(now)
    }

    fn commit<T>(
        &mut self,
        change: impl FnOnce(&mut ProductWorkspace) -> Result<T, ProductError>,
    ) -> Result<T, String> {
        self.store.transact(change).map_err(|e| {
            if matches!(
                e,
                koe_client_services::product_store::StoreError::CommitUncertain(_)
                    | koe_client_services::product_store::StoreError::Unavailable
            ) {
                self.settings.key.clear();
                self.settings.unavailable = true;
            }
            e.to_string()
        })
    }

    fn dispatch(&mut self, command: Command, now: u64) -> Result<(), String> {
        if now > 0 {
            self.last_now_sec = now;
        }
        if self.is_quitting()
            && !matches!(
                command,
                Command::LocalAsrReadiness { .. }
                    | Command::LocalAsrResult { .. }
                    | Command::LocalAsrFinished { .. }
                    | Command::LocalAsrFailed { .. }
                    | Command::RequestQuit
                    | Command::CancelQuit
                    | Command::ClearError
                    | Command::DismissUndoTrash
                    | Command::Navigate { .. }
                    | Command::Back
                    | Command::SelectRecord { .. }
                    | Command::OpenSource { .. }
                    | Command::DeviceEvent { .. }
                    | Command::SyncAudioInputs { .. }
                    | Command::PlaybackProgress { .. }
                    | Command::MicrophoneStarted { .. }
                    | Command::MicrophonePrepared { .. }
                    | Command::MicrophoneChunk { .. }
                    | Command::MicrophonePaused { .. }
                    | Command::MicrophoneStopped { .. }
                    | Command::MicrophoneFailed { .. }
                    | Command::RetryMicrophoneSave
            )
        {
            return Err("正在退出，请先取消退出再开始新操作".into());
        }
        if !self.is_quitting() {
            self.reconcile_expired_trash(now);
        }
        match command {
            Command::StartCaptureMode { mode } => self.start_capture_mode(mode, now)?,
            Command::CaptureAction { action, clock_ns } => self.capture_action(action, clock_ns)?,
            Command::StartMicrophone {
                input_id,
                include_system,
                clock_ns,
            } => self.start_microphone(input_id, include_system, clock_ns, now)?,
            Command::SyncAudioInputs { inputs } => self.sync_audio_inputs(inputs)?,
            Command::SelectCaptureSource { source } => self.select_capture_source(&source)?,
            Command::PauseMicrophone => self.pause_microphone()?,
            Command::MicrophonePrepared {
                record_id,
                session_id,
                epoch,
                clock_ns,
            } => self.microphone_prepared(&record_id, &session_id, epoch, clock_ns)?,
            Command::ResumeMicrophone { clock_ns } => self.resume_microphone(clock_ns)?,
            Command::MicrophonePaused {
                record_id,
                session_id,
                lane,
                sequence,
                epoch,
            } => self.microphone_paused(&record_id, &session_id, &lane, sequence, epoch)?,
            Command::StopMicrophone => self.stop_microphone(false)?,
            Command::CancelMicrophone => self.stop_microphone(true)?,
            Command::RetryMicrophoneSave => self.save_microphone()?,
            Command::MicrophoneStarted {
                record_id,
                session_id,
                lane,
                sample_rate,
            } => self.microphone_started(&record_id, &session_id, &lane, sample_rate)?,
            Command::MicrophoneChunk {
                record_id,
                session_id,
                lane,
                sequence,
                samples,
                timing,
            } => {
                self.microphone_chunk((&record_id, &session_id, &lane), sequence, &samples, timing)?
            }
            Command::MicrophoneStopped {
                record_id,
                session_id,
                lane,
                sequence,
                epoch,
            } => self.microphone_stopped(&record_id, &session_id, &lane, sequence, epoch)?,
            Command::MicrophoneFailed {
                record_id,
                session_id,
                lane,
                message,
                epoch,
            } => self.microphone_failed(&record_id, &session_id, &lane, message, epoch),
            Command::RequestQuit => self.request_quit(),
            Command::CancelQuit => {
                self.quit = lifecycle::QuitState::Running;
                if matches!(
                    self.device.session.transfer.phase,
                    koe_engine::session::TransferPhaseTag::Failed
                ) {
                    self.device.session.reset_active_transfer();
                }
                self.drive_companion(now);
            }
            Command::Navigate { section } => self.go(Location {
                page: section,
                ..self.location.clone()
            }),
            Command::Back => {
                if let Some(location) = self.back.pop() {
                    self.set_location(location);
                }
            }
            Command::SelectRecord { record_id } => self.open_record(&record_id, None)?,
            Command::OpenSource {
                record_id,
                segment_id,
            } => {
                let source = self
                    .workspace()
                    .resolve_live_source(&source_ref(&record_id, &segment_id)?)
                    .map_err(|e| e.to_string())?;
                self.open_record(&record_id, Some(segment_id))?;
                self.seek_playback(source.start_ms)?;
            }
            Command::CreateNote { title, text } => {
                if text.trim().is_empty() {
                    return Err("先写下一段内容".into());
                }
                let id = format!("note-{now}-{}", self.workspace().revision() + 1);
                self.commit(|workspace| {
                    workspace.insert_record(id.clone(), title, RecordOrigin::Note, 0, now, 0)?;
                    for paragraph in text.lines().map(str::trim).filter(|v| !v.is_empty()) {
                        workspace.append_transcript(&id, paragraph, 0, 0, "manual")?;
                    }
                    Ok(())
                })?;
                self.open_record(&id, None)?;
                self.notice = Some("记录已保存".into());
            }
            Command::ImportFile { path } => {
                let imported =
                    recording_assets::import_recording(&self.root, Path::new(&path), now)?;
                let id = imported.id.clone();
                if let Some(existing) = self.workspace().record(&id) {
                    if existing.is_trashed() {
                        self.commit(|w| w.restore_record(&id))?;
                        self.clear_undo_trash_for(&id);
                    }
                } else {
                    self.commit(|workspace| {
                        let origin = if imported.has_audio {
                            RecordOrigin::ImportedAudio
                        } else {
                            RecordOrigin::ImportedText
                        };
                        workspace.insert_record(
                            id.clone(),
                            imported.title,
                            origin,
                            0,
                            imported.created_at,
                            imported.duration_ms,
                        )?;
                        for paragraph in imported.paragraphs {
                            workspace.append_transcript(&id, &paragraph, 0, 0, "import")?;
                        }
                        if let Some(minutes) = imported.minutes {
                            let key = workspace.begin_analysis(&id, AnalysisStage::Summarizing)?;
                            workspace.complete_summary(&key, minutes)?;
                        }
                        Ok(())
                    })?;
                }
                self.open_record(&id, None)?;
                self.notice = Some("导入完成".into());
            }
            Command::RenameRecord { record_id, title } => {
                self.commit(|w| w.rename_record(&record_id, &title))?
            }
            Command::SetRecordArchived {
                record_id,
                archived,
            } => self.handle_set_record_archived(&record_id, archived)?,
            Command::TrashRecord { record_id } => self.handle_trash_record(&record_id, now)?,
            Command::RestoreRecord { record_id } => self.handle_restore_record(&record_id)?,
            Command::PurgeRecord { record_id } => self.handle_purge_record(&record_id)?,
            Command::EmptyTrash => self.handle_empty_trash()?,
            Command::DismissUndoTrash => self.handle_dismiss_undo_trash(),
            Command::ExportRecord { record_id, path } => {
                self.export_record(&record_id, Path::new(&path))?
            }
            Command::ReviewItem { item_id, decision } => {
                let decision = match decision.as_str() {
                    "accept" => ReviewDecision::Accept,
                    "dismiss" => ReviewDecision::Dismiss,
                    "reset" => ReviewDecision::Reset,
                    _ => return Err("无效的确认操作".into()),
                };
                self.commit(|w| w.review_item(&item_id, decision))?;
            }
            Command::CompleteTask { item_id, completed } => {
                self.commit(|w| w.complete_task(&item_id, completed))?
            }
            Command::EditItem { item_id, text, due } => {
                self.commit(|w| w.edit_item(&item_id, &text, due))?
            }
            Command::SaveMemory {
                record_id,
                segment_id,
            } => self.create_item(ItemKind::Memory, &record_id, &segment_id)?,
            Command::CreateTask {
                record_id,
                segment_id,
            } => self.create_item(ItemKind::Task, &record_id, &segment_id)?,
            Command::AddHighlight {
                record_id,
                segment_id,
            } => {
                let source = source_ref(&record_id, &segment_id)?;
                self.commit(|w| w.add_highlight(source))?;
            }
            Command::EditSegmentText {
                record_id,
                segment_id,
                text,
            } => self.edit_segment_text(&record_id, &segment_id, &text)?,
            Command::SetSegmentSpeaker {
                record_id,
                segment_id,
                speaker,
            } => self.set_segment_speaker(&record_id, &segment_id, speaker.as_deref())?,
            Command::RenameSpeaker {
                record_id,
                from_speaker,
                to_speaker,
            } => self.rename_speaker(&record_id, &from_speaker, &to_speaker)?,
            Command::Ask {
                question,
                scope,
                record_id,
            } => {
                self.start_ask(search_scope(&scope, record_id)?, &question, now)?;
                self.go(Location {
                    page: Page::Ask,
                    ..self.location.clone()
                });
            }
            Command::SetAskScope { scope, record_id } => {
                let scope = search_scope(&scope, record_id)?;
                self.commit(|w| w.set_ask_scope(scope))?;
            }
            Command::ConfigureSpeech { engine, model_id } => {
                self.configure_speech(&engine, model_id)?
            }
            Command::PrepareSpeechModel { model_id } => self.prepare_speech_model(&model_id)?,
            Command::CancelSpeechModel => self.cancel_speech_model(),
            Command::StartAllDay { source, input_id } => {
                self.start_all_day(&source, input_id.unwrap_or_default(), now)?
            }
            Command::StopAllDay => self.stop_all_day()?,
            Command::SetDictationActive { active } => self.set_dictation_active(active),
            Command::Transcribe { record_id } => self.start_transcription(&record_id)?,
            Command::LocalAsrReadiness { state, message } => {
                self.local_asr_readiness(state, message)?
            }
            Command::LocalAsrResult {
                operation_id,
                text,
                start_ms,
                end_ms,
                is_final,
            } => self.local_asr_result(operation_id, text, start_ms, end_ms, is_final)?,
            Command::LocalAsrFinished { operation_id } => self.local_asr_finished(operation_id),
            Command::LocalAsrFailed {
                operation_id,
                message,
            } => self.local_asr_failed(operation_id, message),
            Command::SetMeetingAudioPolicy { policy } => self.set_meeting_audio_policy(&policy)?,
            Command::Summarize { record_id } => self.start_summary(&record_id)?,
            Command::ConfigureProvider {
                api_key,
                model,
                asr_endpoint,
                chat_endpoint,
            } => self.configure_provider(api_key, model, asr_endpoint, chat_endpoint)?,
            Command::ClearProviderCredential => self.clear_credential()?,
            Command::RetryProviderCredentials { authorize } => self.retry_credentials(authorize)?,
            Command::ClearError => {}
            Command::Seek { position_ms } => self.seek_playback(position_ms)?,
            Command::Playback { is_playing } => self.set_playback(is_playing)?,
            Command::SelectPlaybackLane { lane } => self.select_playback_lane(lane)?,
            Command::PlaybackProgress {
                record_id,
                request_id,
                position_ms,
                is_playing,
            } => {
                self.playback_progress(&record_id, request_id, position_ms, is_playing);
            }
            Command::DeviceEvent {
                event,
                connection_id,
                device_name,
            } => {
                self.device
                    .event(&event, &connection_id, device_name.as_deref())?;
                self.save_captures(now)?;
                self.drive_companion(now);
            }
            Command::DeviceOpenGuide => self.device.open_guide(),
            Command::DeviceOnboardingNext => self.device.onboarding_next(),
            Command::DeviceCloseGuide => self.device.close_guide(),
            Command::DeviceRefresh => {
                if !self.is_quitting()
                    && matches!(
                        self.device.session.transfer.phase,
                        koe_engine::session::TransferPhaseTag::Failed
                    )
                {
                    self.device.session.reset_active_transfer();
                }
                self.device.refresh();
            }
            Command::DeviceDisconnect => {
                if self.companion.standby_stream_owned
                    || self.companion.pending_standby_stop
                    || self.companion.active_standby_file_id.is_some()
                {
                    if let Some(fid) = self
                        .device
                        .session
                        .active_file_id
                        .filter(|&id| id > 0)
                        .or_else(|| self.companion.active_standby_file_id.take())
                    {
                        if self.can_own_as_standby_scratch(fid) {
                            let _ = self.mark_standby_scratch_file(fid);
                        }
                    }
                    self.companion.active_standby_file_id = None;
                    self.companion.standby_stream_owned = false;
                    self.companion.pending_standby_stop = false;
                }
                self.companion.deleted_in_connection.clear();
                self.device.disconnect();
                self.drive_companion(now);
            }
            Command::DeviceRelease => {
                self.stop_bean_dictation();
                self.commit(|w| {
                    w.set_ble_auto_connect(false);
                    Ok(())
                })?;
                if self.companion.standby_stream_owned
                    || self.companion.pending_standby_stop
                    || self.companion.active_standby_file_id.is_some()
                {
                    if let Some(fid) = self
                        .device
                        .session
                        .active_file_id
                        .filter(|&id| id > 0)
                        .or_else(|| self.companion.active_standby_file_id.take())
                    {
                        if self.can_own_as_standby_scratch(fid) {
                            let _ = self.mark_standby_scratch_file(fid);
                        }
                    }
                    self.companion.active_standby_file_id = None;
                    self.companion.standby_stream_owned = false;
                    self.companion.pending_standby_stop = false;
                }
                self.companion.deleted_in_connection.clear();
                self.companion.capture_active = false;
                self.companion.post_tap_skip_slices = 0;
                self.companion.tail_holdback.clear();
                self.device.disconnect();
                self.drive_companion(now);
                self.notice = Some("已释放录音豆蓝牙控制权".into());
            }
            Command::SetBleAutoConnect { enabled } => {
                self.commit(|w| {
                    w.set_ble_auto_connect(enabled);
                    Ok(())
                })?;
            }
            Command::SetCompanionMode { mode } => {
                if !self.is_quitting()
                    && matches!(
                        self.device.session.transfer.phase,
                        koe_engine::session::TransferPhaseTag::Failed
                    )
                {
                    self.device.session.reset_active_transfer();
                }
                let parsed = CompanionRoutingMode::parse(&mode).ok_or("无效的领夹麦伴侣模式")?;
                self.commit(|w| {
                    w.set_companion_mode(parsed);
                    Ok(())
                })?;
                self.companion.standby_suppressed_for_connection = false;
                if parsed != CompanionRoutingMode::CollarStandby
                    && self.companion.standby_stream_owned
                {
                    self.stop_owned_standby_stream()?;
                } else if parsed == CompanionRoutingMode::Disabled {
                    self.companion.capture_active = false;
                    self.companion.post_tap_skip_slices = 0;
                    self.companion.tail_holdback.clear();
                }
                self.drive_companion(now);
            }
            Command::DeviceDownload { file_id } => {
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
                }
                if self.companion.standby_stream_owned {
                    return Err(
                        "当前处于领夹麦待命模式，请先切换为关闭或会议兼领夹模式后再下载录音".into(),
                    );
                }
                if !self.is_quitting()
                    && matches!(
                        self.device.session.transfer.phase,
                        koe_engine::session::TransferPhaseTag::Failed
                    )
                {
                    self.device.session.reset_active_transfer();
                }
                self.ensure_device_idle()?;
                let entry = self
                    .device
                    .session
                    .catalog
                    .iter()
                    .find(|v| v.file_id == file_id)
                    .cloned()
                    .ok_or("设备上没有这条录音")?;
                if self.workspace().is_bean_file_purged(file_id) {
                    self.commit(|w| {
                        w.clear_purged_bean_file_id(file_id);
                        Ok(())
                    })?;
                }
                let frame = self
                    .device
                    .session
                    .begin_offline_pull(file_id, entry.duration_ms);
                self.device.outbound.push(frame);
            }
            Command::DeviceStart => {
                if self.microphone.is_some() {
                    return Err("请先结束当前麦克风录音并完成保存".into());
                }
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
                }
                if !self.is_quitting()
                    && matches!(
                        self.device.session.transfer.phase,
                        koe_engine::session::TransferPhaseTag::Failed
                    )
                {
                    self.device.session.reset_active_transfer();
                }
                if self.workspace().companion_mode() == CompanionRoutingMode::CollarStandby {
                    if self.companion.standby_stream_owned {
                        return Err(
                            "当前处于领夹麦待命模式，如需录制会议请先切换为普通或会议兼领夹模式"
                                .into(),
                        );
                    }
                    self.companion.standby_suppressed_for_connection = false;
                    self.ensure_device_idle()?;
                    self.drive_companion(now);
                } else {
                    if self.companion.standby_stream_owned {
                        self.stop_owned_standby_stream()?;
                    }
                    self.ensure_device_idle()?;
                    let outcome = self.device.session.start_realtime_recording_with_options(
                        None,
                        now.saturating_mul(1000),
                        false,
                    );
                    self.device.accept(outcome);
                    self.live_minutes_scope = Some(live_minutes::LiveMinutesScope::BeanStarting);
                    self.drive_companion(now);
                }
            }
            Command::DeviceStop => {
                if self.companion.standby_stream_owned {
                    self.companion.standby_suppressed_for_connection = true;
                    self.stop_owned_standby_stream()?;
                } else {
                    self.device.stop_recording();
                }
                self.drive_companion(now);
            }
        }
        self.reconcile_all_day();
        self.reconcile_bean_capture_mode();
        Ok(())
    }

    fn go(&mut self, location: Location) {
        self.back.push(self.location.clone());
        if self.back.len() > 32 {
            self.back.remove(0);
        }
        self.set_location(location);
    }
    fn set_location(&mut self, location: Location) {
        if self.playback.record != location.record {
            self.playback.record = location.record.clone();
            self.playback.lane = None;
            self.playback.request_id = self.playback.request_id.saturating_add(1);
            self.playback.position_ms = 0;
            self.playback.playing = false;
        }
        self.location = location;
    }
    fn open_record(&mut self, id: &str, segment: Option<String>) -> Result<(), String> {
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        self.go(Location {
            page: Page::Detail,
            record: Some(id.into()),
            segment,
        });
        Ok(())
    }
    fn create_item(&mut self, kind: ItemKind, id: &str, segment: &str) -> Result<(), String> {
        let source = source_ref(id, segment)?;
        self.commit(|w| {
            let evidence = w.resolve_live_source(&source)?;
            let id = w.propose_item(kind, &evidence.quote, vec![source])?;
            w.review_item(&id, ReviewDecision::Accept)
        })?;
        self.notice = Some("已保存，可从来源返回原文".into());
        Ok(())
    }

    /// Feeds real platform notifications into the existing protocol engine.
    pub fn ingest_ble_chunk(&mut self, bytes: &[u8], now: u64) {
        let day_changed = self.advance_clock(now);
        let lifecycle = self.lifecycle_json();
        let revision = self.workspace().revision();
        let error = self.error.clone();
        let mut changed = self.device.ingest(bytes, now);
        if let Err(error) = self.save_captures(now) {
            self.error = Some(error);
        }
        changed |= self.drive_companion(now);
        changed |= self.maybe_start_auto_offline_pull();
        self.reconcile_bean_capture_mode();
        let all_day_finished = self.reconcile_all_day();
        if changed
            || day_changed
            || all_day_finished
            || revision != self.workspace().revision()
            || error != self.error
            || lifecycle != self.lifecycle_json()
        {
            self.generation = self.generation.saturating_add(1);
        }
    }
    /// Advances protocol deadlines and consumes completed provider work.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now: u64) {
        let day_changed = self.advance_clock(now);
        let lifecycle = self.lifecycle_json();
        let revision = self.workspace().revision();
        let error = self.error.clone();
        self.drain_error = None;
        let undo_expired = self.tick_undo_trash(elapsed_ms);
        let trash_expired = self.reconcile_expired_trash(now);
        let changed = match self.device.tick(elapsed_ms.min(60_000), now) {
            Ok(changed) => changed,
            Err(error) => {
                self.error = Some(error);
                true
            }
        };
        if let Err(error) = self.save_captures(now) {
            self.error = Some(error);
        }
        if let Err(error) = self.retry_standby_dictation_save() {
            self.error = Some(error);
        }
        self.tick_local_asr(elapsed_ms);
        let mut completed = self.poll_offline_speech()
            | self.drive_speech_files()
            | self.drive_apple_speech()
            | self.poll_provider()
            | self.poll_captures();
        self.drive_analysis_queue();
        let all_day_finished = self.reconcile_all_day();
        completed |= self.drive_companion(now);
        completed |= self.maybe_start_auto_offline_pull();
        self.reconcile_bean_capture_mode();
        if changed
            || completed
            || day_changed
            || all_day_finished
            || undo_expired
            || trash_expired
            || revision != self.workspace().revision()
            || error != self.error
            || lifecycle != self.lifecycle_json()
        {
            self.generation = self.generation.saturating_add(1);
        }
    }

    fn advance_clock(&mut self, now: u64) -> bool {
        if now == 0 {
            return false;
        }
        let before = std::mem::replace(&mut self.last_now_sec, now);
        before > 0 && projection::local_date(before) != projection::local_date(now)
    }

    fn ensure_device_idle(&self) -> Result<(), String> {
        use koe_engine::session::TransferPhaseTag;
        if self.device.awaiting_stop
            || matches!(
                self.device.session.transfer.phase,
                TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
            )
            || self.device.session.is_offline_pull_suspended()
            || self.device.session.device_recording_active
        {
            Err("请等待当前录音取回或录制结束".into())
        } else {
            Ok(())
        }
    }
    /// Transfers queued protocol frames to the native transport adapter.
    pub fn drain_outbound_ble_frames(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.device.outbound)
    }
    /// Serializes an immutable projection without changing domain state.
    pub fn snapshot_json(&self, now: u64) -> String {
        self.snapshot(now).to_string()
    }
    /// Structured read-only projection for native and CLI clients.
    pub fn snapshot(&self, now: u64) -> Value {
        self.project(now)
    }
}

fn source_ref(record: &str, segment: &str) -> Result<SourceRef, String> {
    Ok(SourceRef {
        record_id: record.into(),
        segment_id: SegmentId::parse_citation(segment).ok_or("原文片段标识无效")?,
    })
}
fn search_scope(scope: &str, id: Option<String>) -> Result<SearchScope, String> {
    match scope {
        "all" => Ok(SearchScope::All),
        "record" => Ok(SearchScope::Record(id.ok_or("先选择一条记录")?)),
        _ => Err("无效的问答范围".into()),
    }
}
