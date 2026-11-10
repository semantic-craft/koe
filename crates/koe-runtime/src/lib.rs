//! A single durable product workspace shared by the native host and CLI.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

#[cfg(test)]
mod ask_tests;
mod capture;
#[cfg(test)]
mod capture_tests;
mod command;
mod device;
mod legacy;
#[cfg(test)]
mod navigation_tests;
mod processing;
mod projection;
mod restore;

use command::{Command, Location, Page, Playback};
use device::DeviceRuntime;
use koe_client_providers::{
    ProviderWorker, DASHSCOPE_ASR_ENDPOINT, DASHSCOPE_CHAT_ENDPOINT, DASHSCOPE_CHAT_MODEL,
};
use koe_client_services::{product_store::ProductStore, recording_assets};
use koe_engine::{domain::SegmentId, product::*};
use serde_json::Value;
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Version of the native JSON snapshot and command contract.
pub const KOE_HOST_SNAPSHOT_VERSION: u32 = 2;

struct ProviderSettings {
    key: String,
    model: String,
    asr_endpoint: String,
    chat_endpoint: String,
}
impl Default for ProviderSettings {
    fn default() -> Self {
        Self {
            key: String::new(),
            model: DASHSCOPE_CHAT_MODEL.into(),
            asr_endpoint: DASHSCOPE_ASR_ENDPOINT.into(),
            chat_endpoint: DASHSCOPE_CHAT_ENDPOINT.into(),
        }
    }
}
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
    pending: BTreeMap<u64, PendingWork>,
    completed: std::collections::VecDeque<koe_client_providers::ProviderEvent>,
    captures: capture::Captures,
    auto_transcribe: std::collections::BTreeSet<String>,
    auto_summarize: std::collections::BTreeSet<String>,
    next_job: u64,
    error: Option<String>,
    notice: Option<String>,
}

impl KoeRuntime {
    /// Opens durable state, rejecting corrupted storage and concurrent writers.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
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
            pending: BTreeMap::new(),
            completed: std::collections::VecDeque::new(),
            captures: Default::default(),
            auto_transcribe: Default::default(),
            auto_summarize: Default::default(),
            next_job: 1,
            error: None,
            notice: None,
        };
        if !existed {
            runtime.restore_legacy()?;
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
        self.store.transact(change).map_err(|e| e.to_string())
    }

    fn dispatch(&mut self, command: Command, now: u64) -> Result<(), String> {
        match command {
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
                    .resolve_source(&source_ref(&record_id, &segment_id)?)
                    .map_err(|e| e.to_string())?;
                self.open_record(&record_id, Some(segment_id))?;
                self.playback.position_ms = source.start_ms;
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
                if self.workspace().record(&id).is_none() {
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
            Command::Summarize { record_id } => self.start_summary(&record_id)?,
            Command::ConfigureProvider {
                api_key,
                model,
                asr_endpoint,
                chat_endpoint,
            } => {
                if api_key.len() > 4096 || model.trim().is_empty() || model.len() > 200 {
                    return Err("请检查模型配置".into());
                }
                self.settings.key = api_key.trim().to_string();
                self.settings.model = model.trim().to_string();
                if let Some(endpoint) = asr_endpoint {
                    self.settings.asr_endpoint = endpoint;
                }
                if let Some(endpoint) = chat_endpoint {
                    self.settings.chat_endpoint = endpoint;
                }
                self.notice = Some("模型配置已用于当前会话".into());
            }
            Command::ClearError => {}
            Command::Seek { position_ms } => {
                let id = self.location.record.clone().ok_or("先选择一条录音")?;
                let duration = self
                    .workspace()
                    .record(&id)
                    .ok_or("录音不存在")?
                    .aggregate
                    .duration_ms;
                self.playback.record = Some(id);
                self.playback.position_ms = position_ms.min(duration);
            }
            Command::Playback { is_playing } => {
                let id = self.location.record.clone().ok_or("先选择一条录音")?;
                if !recording_assets::audio_path(&self.root, &id)?.exists() {
                    return Err("这条记录没有可播放的音频".into());
                }
                if self.playback.record.as_ref() != Some(&id) {
                    self.playback.position_ms = 0;
                }
                self.playback.record = Some(id);
                self.playback.playing = is_playing;
            }
            Command::PlaybackProgress {
                position_ms,
                is_playing,
            } => {
                if let Some(id) = &self.playback.record {
                    if let Some(record) = self.workspace().record(id) {
                        self.playback.position_ms = position_ms.min(record.aggregate.duration_ms);
                        self.playback.playing = is_playing;
                    }
                }
            }
            Command::DeviceEvent {
                event,
                connection_id,
                device_name,
            } => {
                self.device
                    .event(&event, &connection_id, device_name.as_deref())?;
                self.process_capture_events(now)?;
                self.save_device_recordings(now)?;
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
                    .ok_or("设备上没有这条录音")?;
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
            Command::DeviceStop => {
                let outcome = self.device.session.stop_realtime_recording();
                self.device.accept(outcome);
            }
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
            self.playback.position_ms = 0;
            self.playback.playing = false;
        }
        self.location = location;
    }
    fn open_record(&mut self, id: &str, segment: Option<String>) -> Result<(), String> {
        if self.workspace().record(id).is_none() {
            return Err("记录不存在".into());
        }
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
            let evidence = w.resolve_source(&source)?;
            let id = w.propose_item(kind, &evidence.quote, vec![source])?;
            w.review_item(&id, ReviewDecision::Accept)
        })?;
        self.notice = Some("已保存，可从来源返回原文".into());
        Ok(())
    }

    /// Feeds real platform notifications into the existing protocol engine.
    pub fn ingest_ble_chunk(&mut self, bytes: &[u8], now: u64) {
        let revision = self.workspace().revision();
        let error = self.error.clone();
        let changed = self.device.ingest(bytes, now);
        if let Err(error) = self
            .process_capture_events(now)
            .and_then(|()| self.save_device_recordings(now))
        {
            self.error = Some(error);
        }
        if changed || revision != self.workspace().revision() || error != self.error {
            self.generation = self.generation.saturating_add(1);
        }
    }
    /// Advances protocol deadlines and consumes completed provider work.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now: u64) {
        let revision = self.workspace().revision();
        let error = self.error.clone();
        let changed = match self.device.tick(elapsed_ms.min(60_000), now) {
            Ok(changed) => changed,
            Err(error) => {
                self.error = Some(error);
                true
            }
        };
        if let Err(error) = self
            .process_capture_events(now)
            .and_then(|()| self.save_device_recordings(now))
        {
            self.error = Some(error);
        }
        let completed = self.poll_provider() | self.poll_captures();
        self.drive_analysis_queue();
        if changed || completed || revision != self.workspace().revision() || error != self.error {
            self.generation = self.generation.saturating_add(1);
        }
    }

    fn ensure_device_idle(&self) -> Result<(), String> {
        use koe_engine::session::TransferPhaseTag;
        if matches!(
            self.device.session.transfer.phase,
            TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
        ) || self.device.session.is_offline_pull_suspended()
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
