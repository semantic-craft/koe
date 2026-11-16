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
mod device_custody;
mod dictation_capture;
mod capture_flow;
mod legacy;
mod lifecycle;
#[cfg(test)]
mod lifecycle_tests;
mod live_minutes;
mod local_asr;
/// Centralized 16-tool MCP registry and step/poll dispatcher shared by native host and CLI.
pub mod mcp_surface;
mod microphone;
mod mode_workspaces;
mod mode_workspaces_all_day;
mod mode_workspaces_live_voice;
#[cfg(test)]
mod navigation_tests;
mod playback;
mod processing;
mod projection;
mod provider_settings;
mod selection;
mod speech;
use provider_settings::ProviderSettings;
mod transcript_edit;
mod trash;
mod voice_input;

use command::{Command, Location, Page};
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
pub use mcp_surface::{drive_mcp_tool_blocking, McpToolCallState, McpToolError};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Version of the native JSON snapshot and command contract.
pub const KOE_HOST_SNAPSHOT_VERSION: u32 = 2;

/// Outcome of attempting to ingest a native microphone PCM chunk.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PcmIngestStatus {
    /// Chunk was accepted and lane sequence advanced by one.
    Accepted = 0,
    /// No active microphone session or lane matches the caller's identity.
    StaleSession = 1,
    /// Session matched, but the chunk was rejected or failed to persist.
    Rejected = 2,
}

/// Summary receipt returned by [`KoeRuntime::ingest_microphone_pcm`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PcmIngestReceipt {
    /// Resulting runtime view generation after processing the chunk.
    pub generation: u64,
    /// Current expected sequence number for the addressed lane (`0` when stale).
    pub next_sequence: u64,
    /// Acceptance classification for the chunk.
    pub status: PcmIngestStatus,
}

/// Summary receipt returned by [`KoeRuntime::report_playback_progress`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlaybackProgressReceipt {
    /// Resulting runtime view generation.
    pub generation: u64,
    /// Runtime view generation immediately prior to this progress report.
    pub prev_generation: u64,
    /// Clamped playback position in milliseconds (`0` when unmatched).
    pub position_ms: u64,
    /// Effective wall-clock timestamp in epoch seconds resolved for this receipt.
    pub now_epoch_sec: u64,
    /// Resulting playing state (`false` when unmatched).
    pub is_playing: bool,
    /// Whether active playback state was applied.
    pub applied: bool,
    /// Whether day rollover, trash retention, or session reconciliation requires a full snapshot.
    pub needs_full_snapshot: bool,
}

#[derive(Clone)]
enum PendingWork {
    Transcription(RequestKey),
    Summary(RequestKey),
    LiveSummary {
        key: RequestKey,
        sources: koe_engine::domain::UtteranceSpine,
    },
    Ask(u64),
}

/// Serialized application session. Network I/O runs on an owned background worker.
pub struct KoeRuntime {
    store: ProductStore,
    root: PathBuf,
    generation: u64,
    selection: selection::WorkspaceSelection,
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
            root,
            generation: 1,
            selection: Default::default(),
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

    /// Appends a microphone PCM16 chunk without JSON command serialization or full snapshot projection.
    #[allow(clippy::too_many_arguments)]
    pub fn ingest_microphone_pcm(
        &mut self,
        record_id: &str,
        session_id: &str,
        lane: &str,
        sequence: u64,
        samples: &[i16],
        timing: Option<(u64, u64)>,
        now: u64,
    ) -> PcmIngestReceipt {
        self.error = None;
        self.notice = None;
        if now > 0 {
            self.last_now_sec = now;
        }
        if !self.is_quitting() {
            self.reconcile_expired_trash(now);
        }
        let capture_timing = timing.map(|(epoch, captured_start_ns)| command::CaptureTiming {
            epoch,
            captured_start_ns,
        });
        let result = self.microphone_chunk(
            (record_id, session_id, lane),
            sequence,
            samples,
            capture_timing,
        );
        match result {
            Ok(()) => {
                self.reconcile_all_day();
                self.reconcile_bean_capture_mode();
            }
            Err(ref error) => {
                self.error = Some(error.clone());
            }
        }
        self.generation = self.generation.saturating_add(1);
        let Some((next_sequence, has_lane_error)) = self
            .microphone
            .as_ref()
            .and_then(|m| m.lane_receipt_state(record_id, session_id, lane))
        else {
            return PcmIngestReceipt {
                generation: self.generation,
                next_sequence: 0,
                status: PcmIngestStatus::StaleSession,
            };
        };
        let status = if result.is_ok()
            && sequence.checked_add(1) == Some(next_sequence)
            && !has_lane_error
        {
            PcmIngestStatus::Accepted
        } else {
            PcmIngestStatus::Rejected
        };
        PcmIngestReceipt {
            generation: self.generation,
            next_sequence,
            status,
        }
    }

    /// Updates native playhead progress, eliding generation bumps when unchanged and clock state is clean.
    pub fn report_playback_progress(
        &mut self,
        record_id: &str,
        request_id: u64,
        position_ms: u64,
        is_playing: bool,
        last_projected_now_sec: u64,
        now: u64,
    ) -> PlaybackProgressReceipt {
        let prev_generation = self.generation;
        if now > 0 {
            self.last_now_sec = now;
        }
        let rev_before = self.workspace().revision();
        let trash_reconciled = if !self.is_quitting() {
            self.reconcile_expired_trash(now)
        } else {
            false
        };
        let eff_now = if now > 0 { now } else { self.last_now_sec };
        let today = projection::local_date(eff_now);
        let prev_day = if last_projected_now_sec > 0 {
            projection::local_date(last_projected_now_sec)
        } else {
            None
        };
        let trash_countdown_dirty = self.workspace().records().values().any(|r| {
            r.is_trashed()
                && (last_projected_now_sec == 0
                    || projection::trash_remaining_days(r, eff_now)
                        != projection::trash_remaining_days(r, last_projected_now_sec))
        });
        let all_day_stopping_before = self.all_day.run.as_ref().map(|r| r.stopping);
        let bean_mode_before = self.bean_capture_mode;
        let all_day_done = self.reconcile_all_day();
        self.reconcile_bean_capture_mode();
        let post_hook_changed = all_day_done
            || self.all_day.run.as_ref().map(|r| r.stopping) != all_day_stopping_before
            || self.bean_capture_mode != bean_mode_before;
        let clock_dirty = last_projected_now_sec == 0
            || eff_now == 0
            || today.is_none()
            || today != prev_day
            || trash_reconciled
            || trash_countdown_dirty
            || self.workspace().revision() != rev_before
            || post_hook_changed;

        let Some(clamped_pos) = self.clamped_playback_position(record_id, request_id, position_ms)
        else {
            if !clock_dirty {
                return PlaybackProgressReceipt {
                    generation: prev_generation,
                    prev_generation,
                    position_ms: 0,
                    now_epoch_sec: eff_now,
                    is_playing: false,
                    applied: false,
                    needs_full_snapshot: false,
                };
            }
            self.generation = self.generation.saturating_add(1);
            return PlaybackProgressReceipt {
                generation: self.generation,
                prev_generation,
                position_ms: 0,
                now_epoch_sec: eff_now,
                is_playing: false,
                applied: false,
                needs_full_snapshot: true,
            };
        };

        if (clamped_pos, is_playing)
            == (
                self.selection.playback.position_ms,
                self.selection.playback.playing,
            )
            && !clock_dirty
        {
            return PlaybackProgressReceipt {
                generation: prev_generation,
                prev_generation,
                position_ms: clamped_pos,
                now_epoch_sec: eff_now,
                is_playing,
                applied: false,
                needs_full_snapshot: false,
            };
        }

        self.selection.playback.position_ms = clamped_pos;
        self.selection.playback.playing = is_playing;
        self.generation = self.generation.saturating_add(1);
        PlaybackProgressReceipt {
            generation: self.generation,
            prev_generation,
            position_ms: clamped_pos,
            now_epoch_sec: eff_now,
            is_playing,
            applied: true,
            needs_full_snapshot: clock_dirty,
        }
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
                    | Command::SelectQuickNoteRecord { .. }
                    | Command::SelectAllDayDate { .. }
                    | Command::SelectLiveMinutesRecord { .. }
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
            Command::PrepareVoiceInput => self.prepare_voice_input(now)?,
            Command::SetVoiceInputSession { enabled } => {
                self.set_voice_input_session(enabled, now)?
            }
            Command::StartCaptureMode { mode, stay_on_page } => {
                self.start_capture_mode(mode, stay_on_page, now)?
            }
            Command::CaptureAction { action, clock_ns } => self.capture_action(action, clock_ns)?,
            Command::StartMicrophone {
                input_id,
                include_system,
                clock_ns,
            } => self.start_microphone(input_id, include_system, clock_ns, now)?,
            Command::SyncAudioInputs { inputs } => self.sync_audio_inputs(inputs)?,
            Command::SelectCaptureSource { source } => self.select_capture_source(&source)?,
            Command::SetCaptureSystemAudio { enabled } => self.set_capture_system_audio(enabled)?,
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
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
                self.drive_companion(now);
            }
            Command::Navigate { section } => self.go(Location {
                page: section,
                ..self.selection.location.clone()
            }),
            Command::Back => self.selection.pop_back(),
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
            Command::CreateNote {
                title,
                text,
                stay_on_page,
            } => {
                let id = self.create_quick_note(title, &text, true, now)?;
                if !stay_on_page {
                    self.open_record(&id, None)?;
                }
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
            Command::SetRecordProject { record_id, project } => {
                self.set_record_project(&record_id, project.as_deref())?
            }
            Command::SelectQuickNoteRecord { record_id } => {
                self.select_quick_note_record(record_id)?
            }
            Command::SelectAllDayDate { date } => self.select_all_day_date(&date)?,
            Command::SelectLiveMinutesRecord { record_id } => {
                self.select_live_minutes_record(record_id)?
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
            Command::ExportWorkspaceMarkdown {
                record_id,
                date,
                path,
                include_analysis,
                include_sources,
            } => self.export_workspace_markdown(
                record_id.as_deref(),
                date.as_deref(),
                Path::new(&path),
                include_analysis,
                include_sources,
            )?,
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
            } => {
                let _ = self.accept_segment_item(ItemKind::Memory, &record_id, &segment_id)?;
            }
            Command::CreateTask {
                record_id,
                segment_id,
            } => {
                let _ = self.accept_segment_item(ItemKind::Task, &record_id, &segment_id)?;
            }
            Command::AddHighlight {
                record_id,
                segment_id,
            } => self.highlight_segment(&record_id, &segment_id)?,
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
            } => {
                let _ = self.rename_speaker(&record_id, &from_speaker, &to_speaker)?;
            }
            Command::Ask {
                question,
                scope,
                record_id,
            } => {
                self.start_ask(search_scope(&scope, record_id)?, &question, now)?;
                self.go(Location {
                    page: Page::Ask,
                    ..self.selection.location.clone()
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
            Command::DeviceOpenGuide => {
                if !self.workspace().ble_auto_connect() {
                    self.commit(|w| {
                        w.set_ble_auto_connect(true);
                        Ok(())
                    })?;
                }
                self.device.open_guide();
            }
            Command::DeviceOnboardingNext => self.device.onboarding_next(),
            Command::DeviceCloseGuide => self.device.close_guide(),
            Command::DeviceRefresh => {
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
                self.device.refresh();
            }
            Command::DeviceDisconnect => {
                self.disconnect_device_session(false, now)?;
            }
            Command::DeviceRelease => {
                if let Some(reason) = self.release_to_phone_block_reason() {
                    return Err(reason.into());
                }
                self.stop_bean_dictation();
                self.commit(|w| {
                    w.set_ble_auto_connect(false);
                    Ok(())
                })?;
                self.reset_bean_preference_if_needed();
                self.disconnect_device_session(true, now)?;
                self.notice = Some("已释放录音豆蓝牙控制权".into());
            }
            Command::SetBleAutoConnect { enabled } => {
                self.commit(|w| {
                    w.set_ble_auto_connect(enabled);
                    Ok(())
                })?;
                if !enabled {
                    self.reset_bean_preference_if_needed();
                }
            }
            Command::SetCompanionMode { mode } => {
                let parsed = CompanionRoutingMode::parse(&mode).ok_or("无效的领夹麦伴侣模式")?;
                self.commit(|w| {
                    w.set_companion_mode(parsed);
                    Ok(())
                })?;
                self.apply_companion_mode(parsed, now)?;
            }
            Command::DeviceDownload { file_id } => {
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
                }
                if self.companion.standby_stream_owned {
                    return Err(
                        "当前处于领夹麦待命模式，请先切换为关闭或实时纪要兼听写模式后再下载录音".into(),
                    );
                }
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
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
                let quitting = self.is_quitting();
                self.device.reset_failed_transfer_if_idle(quitting);
                if self.active_companion_mode() == CompanionRoutingMode::CollarStandby {
                    if self.companion.standby_stream_owned {
                        return Err(
                            "当前处于领夹麦待命模式，如需录制实时纪要请先切换为普通或实时纪要兼听写模式"
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

    pub(crate) fn release_to_phone_block_reason(&self) -> Option<&'static str> {
        use koe_engine::session::TransferPhaseTag;
        if self.is_quitting() || self.store.requires_reopen() {
            return Some("当前状态暂不可释放录音豆蓝牙控制权");
        }
        if matches!(
            self.device.session.transfer.phase,
            TransferPhaseTag::PullingOffline
        ) {
            return Some("正在从录音豆拉取离线录音，请等待完成后再切回手机");
        }
        if self.is_bean_meeting_recording()
            || (self.device.session.device_recording_active && !self.companion.standby_stream_owned)
            || self.bean_capture_mode.is_some()
            || self
                .all_day
                .run
                .as_ref()
                .is_some_and(|run| run.source == "bean")
            || self.device.session.pending_realtime_subscribe
        {
            return Some("录音豆正在录音，请先停止当前录音再切回手机");
        }
        None
    }

    pub(crate) fn can_release_to_phone(&self) -> bool {
        self.release_to_phone_block_reason().is_none()
    }

    fn reset_bean_preference_if_needed(&mut self) {
        if self.capture_studio.preference == capture_studio::CaptureSourcePreference::Bean {
            self.capture_studio.preference = capture_studio::CaptureSourcePreference::Auto;
        }
    }

    fn mark_active_standby_scratch(&mut self) {
        if self.companion.standby_stream_owned
            || self.companion.pending_standby_stop
            || self.companion.active_standby_file_id.is_some()
        {
            if let Some(fid) = self
                .device
                .session
                .active_file_id
                .filter(|&id| id > 0)
                .or(self.companion.active_standby_file_id)
            {
                if self.can_own_as_standby_scratch(fid) {
                    let _ = self.mark_standby_scratch_file(fid);
                }
            }
        }
    }

    pub(crate) fn retire_active_standby_stream(&mut self) {
        if self.companion.standby_stream_owned
            || self.companion.pending_standby_stop
            || self.companion.active_standby_file_id.is_some()
        {
            self.mark_active_standby_scratch();
            self.companion.active_standby_file_id = None;
            self.companion.standby_stream_owned = false;
            self.companion.pending_standby_stop = false;
        }
    }

    fn disconnect_device_session(&mut self, released: bool, now: u64) -> Result<(), String> {
        self.mark_active_standby_scratch();
        if released {
            self.companion.on_ble_released();
        } else {
            self.companion.on_ble_disconnected();
        }
        self.device.disconnect();
        self.save_captures(now)?;
        self.retire_active_standby_stream();
        self.drive_companion(now);
        Ok(())
    }

    fn go(&mut self, location: Location) {
        self.selection.go(location);
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

    pub(crate) fn create_quick_note(
        &mut self,
        title: String,
        text: &str,
        select_in_ui: bool,
        now: u64,
    ) -> Result<String, String> {
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
        if select_in_ui {
            self.selection.selected_quick_note_record = Some(id.clone());
        }
        self.notice = Some("记录已保存".into());
        Ok(id)
    }

    pub(crate) fn accept_segment_item(
        &mut self,
        kind: ItemKind,
        record_id: &str,
        segment_id: &str,
    ) -> Result<String, String> {
        let source = source_ref(record_id, segment_id)?;
        let item_id = self.commit(|w| {
            let evidence = w.resolve_live_source(&source)?;
            let id = w.propose_item(kind, &evidence.quote, vec![source])?;
            w.review_item(&id, ReviewDecision::Accept)?;
            Ok(id)
        })?;
        self.notice = Some("已保存，可从来源返回原文".into());
        Ok(item_id)
    }

    pub(crate) fn highlight_segment(
        &mut self,
        record_id: &str,
        segment_id: &str,
    ) -> Result<(), String> {
        let source = source_ref(record_id, segment_id)?;
        self.commit(|w| w.add_highlight(source))
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
        self.drive_live_minutes(elapsed_ms);
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
    /// Advances timers and returns the diagnostic projection shared by CLI and local bridge.
    pub fn doctor_snapshot(&mut self, now: u64) -> Value {
        self.poll_timers(0, now);
        json!({
            "workspaceReadable": true,
            "generation": self.generation,
            "device": self.device_json(),
            "provider": self.provider_json(),
            "error": self.error
        })
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
