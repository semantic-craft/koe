//! A single durable product workspace shared by the native host and CLI.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

#[cfg(test)]
mod ask_tests;
mod audio_policy;
#[cfg(test)]
mod audio_policy_tests;
mod capture;
#[cfg(test)]
mod capture_tests;
mod command;
pub mod credentials;
mod device;
mod flutter_import;
mod legacy;
mod lifecycle;
#[cfg(test)]
mod lifecycle_tests;
mod microphone;
#[cfg(test)]
mod navigation_tests;
mod playback;
mod processing;
mod projection;
mod provider_settings;
use provider_settings::ProviderSettings;
mod restore;
mod trash;

use command::{Command, Location, Page, Playback};
use device::DeviceRuntime;
use koe_client_providers::ProviderWorker;
use koe_client_services::{product_store::ProductStore, recording_assets};
use koe_engine::{domain::SegmentId, product::*};
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
    provider: ProviderWorker,
    settings: ProviderSettings,
    credentials: Box<dyn credentials::CredentialStore>,
    pending: BTreeMap<u64, PendingWork>,
    completed: std::collections::VecDeque<koe_client_providers::ProviderEvent>,
    captures: capture::Captures,
    microphone: Option<microphone::Microphone>,
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
            root,
            generation: 1,
            location: Location::default(),
            back: Vec::new(),
            playback: Playback::default(),
            device: DeviceRuntime::default(),
            provider: ProviderWorker::new()?,
            settings: ProviderSettings::default(),
            credentials,
            pending: BTreeMap::new(),
            completed: std::collections::VecDeque::new(),
            captures: Default::default(),
            microphone: None,
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
        runtime.reconcile_orphan_audio();
        if let Err(error) = runtime.load_credentials() {
            runtime.error = Some(error);
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
                    if !matches!(command, Command::PlaybackProgress { .. }) {
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
                Command::RequestQuit
                    | Command::CancelQuit
                    | Command::ClearError
                    | Command::DismissUndoTrash
                    | Command::Navigate { .. }
                    | Command::Back
                    | Command::SelectRecord { .. }
                    | Command::OpenSource { .. }
                    | Command::DeviceEvent { .. }
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
            Command::StartMicrophone {
                input_id,
                include_system,
                clock_ns,
            } => self.start_microphone(input_id, include_system, clock_ns, now)?,
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
            Command::CancelQuit => self.quit = lifecycle::QuitState::Running,
            Command::ImportFlutterLibrary { path } => {
                self.import_flutter_library(Path::new(&path))?
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
            Command::Transcribe { record_id } => self.start_transcription(&record_id)?,
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
            }
            Command::DeviceOpenGuide => self.device.open_guide(),
            Command::DeviceOnboardingNext => self.device.onboarding_next(),
            Command::DeviceCloseGuide => self.device.close_guide(),
            Command::DeviceRefresh => self.device.refresh(),
            Command::DeviceDisconnect => self.device.disconnect(),
            Command::DeviceDownload { file_id } => {
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
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
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
                }
                self.ensure_device_idle()?;
                let outcome = self
                    .device
                    .session
                    .start_realtime_recording(None, now.saturating_mul(1000));
                self.device.accept(outcome);
            }
            Command::DeviceStop => self.device.stop_recording(),
        }
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
        let lifecycle = self.lifecycle_json();
        let revision = self.workspace().revision();
        let error = self.error.clone();
        let mut changed = self.device.ingest(bytes, now);
        if let Err(error) = self.save_captures(now) {
            self.error = Some(error);
        }
        changed |= self.maybe_start_auto_offline_pull();
        if changed
            || revision != self.workspace().revision()
            || error != self.error
            || lifecycle != self.lifecycle_json()
        {
            self.generation = self.generation.saturating_add(1);
        }
    }
    /// Advances protocol deadlines and consumes completed provider work.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now: u64) {
        if now > 0 {
            self.last_now_sec = now;
        }
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
        let mut completed = self.poll_provider() | self.poll_captures();
        self.drive_analysis_queue();
        completed |= self.maybe_start_auto_offline_pull();
        if changed
            || completed
            || undo_expired
            || trash_expired
            || revision != self.workspace().revision()
            || error != self.error
            || lifecycle != self.lifecycle_json()
        {
            self.generation = self.generation.saturating_add(1);
        }
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
