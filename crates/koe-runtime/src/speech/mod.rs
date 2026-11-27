mod apple;
mod live;
pub(crate) mod local_asr;
mod models;
#[cfg(test)]
mod tests;

use crate::*;
use local_asr::{LocalPhase, LocalSession, Readiness, MAX_MESSAGE_BYTES};
use koe_client_providers::{
    LiveEvent, LiveTranscription, OfflineSpeechWorker, ProviderConfig,
};
use std::collections::VecDeque;

const WINDOW_SAMPLES: usize = 16_000 * 15;
const MAX_PENDING_WINDOWS: usize = 4;

/// Read-only view of an active on-device speech transcription session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalSpeechJobView {
    /// Active local operation identifier, or the request attempt while queued to flush.
    pub operation_id: u64,
    /// Recording identifier owned by this local speech session.
    pub record_id: String,
    /// Stable speech engine identifier (`"apple_speech"` or `"downloaded"`).
    pub engine: String,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum CaptureOrigin {
    Microphone,
    Bean,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(in crate::speech) enum SpeechPhase {
    Accepting,
    Draining,
    Completed { succeeded: bool },
    DeferredReady,
    Cancelled,
}

impl SpeechPhase {
    pub(crate) const fn is_terminal(self) -> bool {
        matches!(
            self,
            Self::Completed { .. } | Self::DeferredReady | Self::Cancelled
        )
    }
}

pub(in crate::speech) enum SpeechBackend {
    CloudLive {
        stream: Option<LiveTranscription>,
        live_draft: String,
    },
    CloudDeferredBatch,
    AppleLocal {
        operations: BTreeMap<u64, LocalSession>,
        active_operation: Option<u64>,
        pcm: Vec<i16>,
        consumed_samples: u64,
    },
    DownloadedLocal {
        operations: BTreeMap<u64, LocalSession>,
        pcm: Vec<i16>,
        consumed_samples: u64,
    },
}

pub(crate) struct SpeechSession {
    pub(in crate::speech) key: RequestKey,
    pub(in crate::speech) backend: SpeechBackend,
    pub(in crate::speech) phase: SpeechPhase,
    pub(in crate::speech) source: Option<CaptureOrigin>,
    pub(in crate::speech) file_audio: Option<VecDeque<u8>>,
    pub(in crate::speech) results: VecDeque<LiveEvent>,
    pub(crate) minutes_schedule: crate::capture::live_minutes::LiveMinutesSchedule,
    pub saved: bool,
    pub captured_pcm_bytes: u64,
}

impl SpeechSession {
    pub(crate) const fn is_terminal(&self) -> bool {
        self.phase.is_terminal()
    }

    pub(crate) fn capture_source(&self) -> Option<CaptureOrigin> {
        self.source
    }

    pub(in crate::speech) const fn is_cloud(&self) -> bool {
        matches!(
            self.backend,
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch
        )
    }

    pub(in crate::speech) const fn is_apple(&self) -> bool {
        matches!(self.backend, SpeechBackend::AppleLocal { .. })
    }

    pub(in crate::speech) const fn is_downloaded(&self) -> bool {
        matches!(self.backend, SpeechBackend::DownloadedLocal { .. })
    }

    pub(in crate::speech) const fn is_local(&self) -> bool {
        matches!(
            self.backend,
            SpeechBackend::AppleLocal { .. } | SpeechBackend::DownloadedLocal { .. }
        )
    }

    pub(in crate::speech) const fn is_file_backed(&self) -> bool {
        self.source.is_none()
    }

    pub(in crate::speech) fn local_job_view(&self, record_id: &str) -> Option<LocalSpeechJobView> {
        if self.is_terminal() {
            return None;
        }
        let (operation_id, engine) = match &self.backend {
            SpeechBackend::AppleLocal {
                operations,
                active_operation,
                ..
            } => (
                active_operation
                    .or_else(|| operations.keys().next().copied())
                    .unwrap_or(self.key.attempt),
                SpeechEngine::AppleSpeech.as_str(),
            ),
            SpeechBackend::DownloadedLocal { operations, .. } => (
                operations.keys().next().copied().unwrap_or(self.key.attempt),
                "downloaded",
            ),
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => return None,
        };
        Some(LocalSpeechJobView {
            operation_id,
            record_id: record_id.to_owned(),
            engine: engine.to_owned(),
        })
    }

    pub(in crate::speech) const fn is_deferred_batch(&self) -> bool {
        matches!(self.backend, SpeechBackend::CloudDeferredBatch)
    }

    pub(in crate::speech) const fn provider_label(&self) -> &'static str {
        match self.backend {
            SpeechBackend::AppleLocal { .. } => "apple-speech",
            SpeechBackend::DownloadedLocal { .. } => "downloaded-speech",
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => "dashscope",
        }
    }

    pub(in crate::speech) fn local_operations(&self) -> Option<&BTreeMap<u64, LocalSession>> {
        match &self.backend {
            SpeechBackend::AppleLocal { operations, .. }
            | SpeechBackend::DownloadedLocal { operations, .. } => Some(operations),
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => None,
        }
    }

    pub(in crate::speech) fn local_operations_mut(
        &mut self,
    ) -> Option<&mut BTreeMap<u64, LocalSession>> {
        match &mut self.backend {
            SpeechBackend::AppleLocal { operations, .. }
            | SpeechBackend::DownloadedLocal { operations, .. } => Some(operations),
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => None,
        }
    }

    pub(in crate::speech) fn clear_live_draft(&mut self) {
        if let SpeechBackend::CloudLive { live_draft, .. } = &mut self.backend {
            live_draft.clear();
        }
    }

    pub(in crate::speech) fn drop_cloud_stream(&mut self) {
        if let SpeechBackend::CloudLive { stream, .. } = &mut self.backend {
            *stream = None;
        }
    }

    pub(in crate::speech) fn clear_local_pcm(&mut self) {
        match &mut self.backend {
            SpeechBackend::AppleLocal { pcm, .. }
            | SpeechBackend::DownloadedLocal { pcm, .. } => pcm.clear(),
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => {}
        }
    }

    pub(in crate::speech) fn set_consumed_samples(&mut self, samples: u64) {
        match &mut self.backend {
            SpeechBackend::AppleLocal {
                consumed_samples, ..
            }
            | SpeechBackend::DownloadedLocal {
                consumed_samples, ..
            } => *consumed_samples = samples,
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => {}
        }
    }

    pub(in crate::speech) fn has_inflight_work(&self) -> bool {
        match &self.backend {
            SpeechBackend::CloudLive { stream, .. } => stream.is_some(),
            SpeechBackend::CloudDeferredBatch => false,
            SpeechBackend::AppleLocal {
                operations, pcm, ..
            }
            | SpeechBackend::DownloadedLocal {
                operations, pcm, ..
            } => !operations.is_empty() || !pcm.is_empty(),
        }
    }

    pub(crate) fn drafts(&self) -> impl Iterator<Item = &str> {
        let (live, ops): (Option<&str>, Option<&BTreeMap<u64, LocalSession>>) = match &self.backend
        {
            SpeechBackend::CloudLive { live_draft, .. } => (
                (!live_draft.is_empty()).then_some(live_draft.as_str()),
                None,
            ),
            SpeechBackend::CloudDeferredBatch => (None, None),
            SpeechBackend::AppleLocal { operations, .. }
            | SpeechBackend::DownloadedLocal { operations, .. } => (None, Some(operations)),
        };
        live.into_iter().chain(
            ops.into_iter()
                .flat_map(|ops| ops.values())
                .map(|op| op.draft.as_str())
                .filter(|text| !text.is_empty()),
        )
    }
}

#[derive(Default)]
pub(in crate::speech) struct ModelState {
    pub(in crate::speech) state: String,
    pub(in crate::speech) bytes: u64,
    pub(in crate::speech) message: Option<String>,
}
pub(in crate::speech) struct ModelPreparation {
    pub(in crate::speech) id: String,
    pub(in crate::speech) cancelled: bool,
}

pub(crate) struct SpeechState {
    pub(in crate::speech) worker: Option<OfflineSpeechWorker>,
    pub(in crate::speech) worker_error: Option<String>,
    pub(in crate::speech) loaded_model_id: Option<String>,
    pub(in crate::speech) preparation: Option<ModelPreparation>,
    pub(in crate::speech) apple_owner: Option<u64>,
    pub(in crate::speech) models: BTreeMap<String, ModelState>,
}
impl SpeechState {
    pub fn new(root: &Path) -> Self {
        let (worker, worker_error) = match OfflineSpeechWorker::new(root.join("speech-models")) {
            Ok(worker) => (Some(worker), None),
            Err(error) => (None, Some(error)),
        };
        Self {
            worker,
            worker_error,
            loaded_model_id: None,
            preparation: None,
            apple_owner: None,
            models: BTreeMap::new(),
        }
    }
}
impl KoeRuntime {
    /// Returns read-only views of all active on-device speech transcription sessions.
    #[must_use]
    pub fn active_local_speech_jobs(&self) -> Vec<LocalSpeechJobView> {
        self.captures
            .sessions
            .iter()
            .filter_map(|(record_id, session)| session.local_job_view(record_id))
            .collect()
    }

    pub(crate) fn has_active_file_speech_session(&self) -> bool {
        self.captures
            .sessions
            .values()
            .any(|s| !s.is_terminal() && s.is_local() && s.is_file_backed())
    }

    fn is_downloaded_speech_busy(&self) -> bool {
        self.speech.preparation.is_some()
            || self
                .captures
                .sessions
                .values()
                .any(|s| !s.is_terminal() && s.is_downloaded())
    }

    pub(crate) fn can_admit_local_file_speech(&self, engine: &SpeechEngine) -> bool {
        if !self.speech_ready(engine) || self.has_active_file_speech_session() {
            return false;
        }
        match engine {
            SpeechEngine::AppleSpeech => !self
                .captures
                .sessions
                .values()
                .any(|s| !s.is_terminal() && s.is_apple()),
            SpeechEngine::Downloaded(_) => !self.is_downloaded_speech_busy(),
            SpeechEngine::Cloud => false,
        }
    }

    fn active_downloaded_operation_count(&self) -> usize {
        self.captures
            .sessions
            .values()
            .filter(|s| s.is_downloaded())
            .map(|s| s.local_operations().map_or(0, BTreeMap::len))
            .sum()
    }

    #[cfg(all(test, feature = "offline-speech"))]
    pub(crate) fn mark_downloaded_model_ready_for_test(&mut self, model_id: &str) {
        self.speech.loaded_model_id = Some(model_id.to_owned());
        self.speech.preparation = None;
        self.speech.models.insert(
            model_id.to_owned(),
            ModelState {
                state: "ready".into(),
                bytes: 1,
                message: None,
            },
        );
    }

    #[cfg(all(test, feature = "offline-speech"))]
    pub(crate) fn drain_offline_worker_slots_for_test(&mut self) -> usize {
        self.speech
            .worker
            .as_ref()
            .map_or(0, |worker| worker.poll().len())
    }

    pub(crate) fn record_speech_engine(&self, id: &str) -> SpeechEngine {
        self.workspace()
            .record(id)
            .filter(|r| matches!(r.analysis, AnalysisState::Interrupted { .. }))
            .and_then(|r| r.speech_engine.clone())
            .unwrap_or_else(|| {
                self.workspace()
                    .provider_configuration()
                    .speech_engine
                    .clone()
            })
    }
    pub(crate) fn speech_ready(&self, engine: &SpeechEngine) -> bool {
        match engine {
            SpeechEngine::AppleSpeech => self.local_asr.state == Readiness::Ready,
            SpeechEngine::Downloaded(id) => {
                self.speech.loaded_model_id.as_deref() == Some(id.as_str())
            }
            SpeechEngine::Cloud => self.cloud_asr_configured(),
        }
    }
    pub(in crate::speech) fn ensure_speech_session(&mut self, id: &str, source: Option<CaptureOrigin>) -> Result<(), String> {
        if self.captures.sessions.contains_key(id) {
            return Ok(());
        }
        if self.store.requires_reopen() {
            return Err("工作区保存结果尚未确认，请重新打开 Koe".into());
        }
        let engine = self.record_speech_engine(id);
        if engine == SpeechEngine::AppleSpeech && self.local_asr.state == Readiness::Unavailable {
            return Err(format!(
                "本机语音识别不可用：{}；原始录音已保留",
                self.local_asr.message
            ));
        }
        if matches!(&engine,SpeechEngine::Downloaded(id) if self.speech.loaded_model_id.as_deref()!=Some(id.as_str()))
        {
            return Err("请先准备选中的本机语音模型；原始录音已保留".into());
        }
        let blocked = if engine == SpeechEngine::Cloud {
            self.ensure_meeting_audio_upload().err()
        } else {
            None
        };
        let is_non_realtime_cloud = engine == SpeechEngine::Cloud
            && blocked.is_none()
            && self.cloud_asr_configured()
            && !self
                .workspace()
                .provider_configuration()
                .is_realtime_cloud_asr();
        if is_non_realtime_cloud {
            self.commit(|w| w.bind_speech_engine(id, engine))?;
            let session = SpeechSession {
                key: RequestKey {
                    record_id: id.into(),
                    attempt: 0,
                    input_revision: 0,
                },
                backend: SpeechBackend::CloudDeferredBatch,
                phase: SpeechPhase::Accepting,
                source,
                file_audio: None,
                results: VecDeque::new(),
                minutes_schedule: Default::default(),
                saved: false,
                captured_pcm_bytes: 0,
            };
            self.captures.sessions.insert(id.into(), session);
            return Ok(());
        }
        let key = self.commit(|w| {
            w.bind_speech_engine(id, engine.clone())?;
            w.begin_analysis(id, AnalysisStage::Transcribing)
        })?;
        let mut results = VecDeque::new();
        let backend = match engine {
            SpeechEngine::Cloud => {
                let mut stream = None;
                if let Some(error) = blocked {
                    results.push_back(LiveEvent::Failed(error));
                } else if !self.cloud_asr_configured() {
                    results.push_back(LiveEvent::Failed(
                        "请先配置云端语音凭据；原始录音已保留".into(),
                    ));
                } else if !self.env.is_replay_mode() {
                    let cfg = self.workspace().provider_configuration();
                    let asr_model = if cfg.asr_model.trim().is_empty() {
                        DEFAULT_ASR_MODEL.to_string()
                    } else {
                        cfg.asr_model.clone()
                    };
                    match LiveTranscription::start(ProviderConfig::new(
                        cfg.asr_endpoint.clone(),
                        asr_model,
                        self.active_asr_key().to_owned(),
                    )) {
                        Ok(live) => stream = Some(live),
                        Err(e) => results.push_back(LiveEvent::Failed(e)),
                    }
                }
                SpeechBackend::CloudLive {
                    stream,
                    live_draft: String::new(),
                }
            }
            SpeechEngine::AppleSpeech => SpeechBackend::AppleLocal {
                operations: BTreeMap::new(),
                active_operation: None,
                pcm: Vec::new(),
                consumed_samples: 0,
            },
            SpeechEngine::Downloaded(_) => SpeechBackend::DownloadedLocal {
                operations: BTreeMap::new(),
                pcm: Vec::new(),
                consumed_samples: 0,
            },
        };
        let session = SpeechSession {
            key,
            backend,
            phase: SpeechPhase::Accepting,
            source,
            file_audio: None,
            results,
            minutes_schedule: Default::default(),
            saved: false,
            captured_pcm_bytes: 0,
        };
        self.captures.sessions.insert(id.into(), session);
        Ok(())
    }
    pub(crate) fn start_file_speech(&mut self, id: &str, pcm: Vec<u8>) -> Result<(), String> {
        if !self.captures.sessions.contains_key(id) {
            let downloaded_busy = matches!(
                self.record_speech_engine(id),
                SpeechEngine::Downloaded(_)
            ) && self.is_downloaded_speech_busy();
            if self.has_active_file_speech_session() || downloaded_busy {
                return Err("已有本机转写正在处理，请稍后重试".into());
            }
        }
        let offset = self.workspace().record(id).map_or(0, |r| {
            r.aggregate
                .spine
                .segments()
                .iter()
                .map(|s| s.end_ms)
                .max()
                .unwrap_or(0)
        });
        self.ensure_speech_session(id, None)?;
        if let Some(s) = self.captures.sessions.get_mut(id) {
            s.saved = true;
            let skip = (offset as usize).saturating_mul(32).min(pcm.len());
            s.file_audio = Some(pcm[skip..].to_vec().into());
            s.set_consumed_samples(offset.saturating_mul(16));
            s.captured_pcm_bytes = offset.saturating_mul(32);
        }
        self.drive_speech_files();
        Ok(())
    }
    pub(crate) fn drive_speech_files(&mut self) -> bool {
        let ids: Vec<_> = self
            .captures
            .sessions
            .iter()
            .filter(|(_, s)| {
                !s.is_terminal()
                    && s.file_audio.is_some()
                    && s.local_operations().map_or(0, BTreeMap::len) < MAX_PENDING_WINDOWS
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut changed = false;
        for id in ids {
            let Some((is_apple, is_downloaded)) = self
                .captures
                .sessions
                .get(&id)
                .map(|s| (s.is_apple(), s.is_downloaded()))
            else {
                continue;
            };
            if is_apple && self.speech.apple_owner.is_some() {
                continue;
            }
            if is_downloaded
                && (self.speech.preparation.is_some()
                    || self.active_downloaded_operation_count() >= MAX_PENDING_WINDOWS)
            {
                continue;
            }
            let Some(s) = self.captures.sessions.get_mut(&id) else {
                continue;
            };
            let Some(audio) = s.file_audio.as_mut() else {
                continue;
            };
            changed = true;
            let n = audio.len().min(WINDOW_SAMPLES * 2);
            let chunk: Vec<u8> = audio.drain(..n).collect();
            let finished = audio.is_empty();
            if finished {
                s.file_audio = None;
            }
            if let Err(error) = self.feed_speech(&id, &chunk, None) {
                self.set_error(error);
            }
            if finished {
                self.finish_speech(&id);
            }
        }
        changed
    }
    pub(crate) fn feed_speech(&mut self, id: &str, pcm16: &[u8], source: Option<CaptureOrigin>) -> Result<(), String> {
        if let Err(error) = self.ensure_speech_session(id, source) {
            self.notice = Some(error);
            return Ok(());
        }
        let Some(mut session) = self.captures.sessions.remove(id) else {
            return Ok(());
        };
        session.captured_pcm_bytes = session
            .captured_pcm_bytes
            .saturating_add(pcm16.len() as u64);
        if session.phase == SpeechPhase::Accepting {
            match &mut session.backend {
                SpeechBackend::CloudLive { stream, .. } => {
                    if let Some(active) = stream.as_mut() {
                        for chunk in pcm16.chunks(64 * 1024) {
                            if let Err(error) = active.push_audio(chunk.to_vec()) {
                                session.results.extend(active.poll());
                                session.results.push_back(LiveEvent::Failed(error));
                                *stream = None;
                                break;
                            }
                        }
                    }
                }
                SpeechBackend::CloudDeferredBatch => {}
                SpeechBackend::AppleLocal { pcm, .. }
                | SpeechBackend::DownloadedLocal { pcm, .. } => {
                    if !session
                        .results
                        .iter()
                        .any(|e| matches!(e, LiveEvent::Failed(_)))
                    {
                        for bytes in pcm16.chunks(2) {
                            if bytes.len() == 2 {
                                pcm.push(i16::from_le_bytes([bytes[0], bytes[1]]));
                            }
                        }
                        if let Err(error) = self.flush_speech_window(&mut session, false) {
                            session.results.push_back(LiveEvent::Failed(error));
                        }
                    }
                }
            }
        }
        self.captures.sessions.insert(id.into(), session);
        self.poll_captures();
        Ok(())
    }
    fn flush_speech_window(&mut self, s: &mut SpeechSession, finish: bool) -> Result<(), String> {
        match &mut s.backend {
            SpeechBackend::AppleLocal {
                operations,
                active_operation,
                pcm,
                consumed_samples,
            } => {
                if pcm.len() > WINDOW_SAMPLES * MAX_PENDING_WINDOWS {
                    return Err("本机识别队列已满，音频已保留，可稍后补转写".into());
                }
                if active_operation.is_none() && self.speech.apple_owner.is_some() {
                    return Ok(());
                }
                if active_operation.is_none() && !pcm.is_empty() {
                    let op = self.next_job;
                    self.next_job += 1;
                    self.local_asr.start(op);
                    self.speech.apple_owner = Some(op);
                    operations.insert(
                        op,
                        LocalSession {
                            operation_id: op,
                            phase: LocalPhase::Active,
                            draft: String::new(),
                            elapsed_ms: 0,
                            offset_ms: *consumed_samples / 16,
                            duration_ms: 0,
                        },
                    );
                    *active_operation = Some(op);
                }
                if let Some(op) = *active_operation {
                    let Some(offset) = operations.get(&op).map(|o| o.offset_ms) else {
                        *active_operation = None;
                        return Ok(());
                    };
                    let current = (*consumed_samples / 16 - offset) as usize * 16;
                    let n = pcm.len().min(WINDOW_SAMPLES.saturating_sub(current));
                    let bytes: Vec<u8> = pcm.drain(..n).flat_map(i16::to_le_bytes).collect();
                    self.local_asr.audio(op, &bytes)?;
                    *consumed_samples += bytes.len() as u64 / 2;
                    if let Some(entry) = operations.get_mut(&op) {
                        entry.duration_ms = *consumed_samples / 16 - offset;
                    }
                    if finish || current + n == WINDOW_SAMPLES {
                        self.local_asr.finish(op);
                        *active_operation = None;
                        if let Some(entry) = operations.get_mut(&op) {
                            entry.phase = LocalPhase::Finishing;
                        }
                    }
                }
            }
            SpeechBackend::DownloadedLocal {
                operations,
                pcm,
                consumed_samples,
            } => {
                let other_downloaded_ops = self.active_downloaded_operation_count();
                while pcm.len() >= WINDOW_SAMPLES || (finish && !pcm.is_empty()) {
                    if other_downloaded_ops + operations.len() >= MAX_PENDING_WINDOWS {
                        return Err("本机识别队列已满，音频已保留，可稍后补转写".into());
                    }
                    let n = pcm.len().min(WINDOW_SAMPLES);
                    let window: Vec<_> = pcm.drain(..n).collect();
                    let op = self.next_job;
                    self.next_job += 1;
                    self.speech
                        .worker
                        .as_ref()
                        .ok_or("本机识别不可用")?
                        .transcribe(op, window)?;
                    operations.insert(
                        op,
                        LocalSession {
                            operation_id: op,
                            phase: LocalPhase::Finishing,
                            draft: String::new(),
                            elapsed_ms: 0,
                            offset_ms: *consumed_samples / 16,
                            duration_ms: n as u64 / 16,
                        },
                    );
                    *consumed_samples += n as u64;
                }
            }
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => {}
        }
        Ok(())
    }
    pub(crate) fn finish_speech(&mut self, id: &str) {
        if let Some(mut s) = self.captures.sessions.remove(id) {
            if !s.phase.is_terminal() {
                if s.is_deferred_batch() {
                    s.phase = SpeechPhase::DeferredReady;
                } else {
                    s.phase = SpeechPhase::Draining;
                    let result = match &s.backend {
                        SpeechBackend::CloudLive {
                            stream: Some(stream),
                            ..
                        } => stream.finish(),
                        _ => self.flush_speech_window(&mut s, true),
                    };
                    if let Err(error) = result {
                        s.results.push_back(LiveEvent::Failed(error));
                    }
                    if !s.has_inflight_work() && s.results.is_empty() && !s.phase.is_terminal() {
                        s.results.push_back(LiveEvent::Finished);
                    }
                }
            }
            self.captures.sessions.insert(id.into(), s);
        }
        self.poll_captures();
    }
}
