mod apple;
mod live;
mod models;
#[cfg(test)]
mod tests;

use super::*;
use crate::local_asr::{LocalPhase, LocalSession, Readiness, MAX_MESSAGE_BYTES};
use koe_client_providers::{
    LiveEvent, LiveTranscription, OfflineSpeechWorker, ProviderConfig,
};
use std::collections::VecDeque;

const WINDOW_SAMPLES: usize = 16_000 * 15;
const MAX_PENDING_WINDOWS: usize = 4;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum CaptureOrigin {
    Microphone,
    Bean,
}

pub(super) struct SpeechSession {
    pub(in crate::speech) key: RequestKey,
    pub(in crate::speech) engine: SpeechEngine,
    pub(in crate::speech) stream: Option<LiveTranscription>,
    pub(in crate::speech) deferred_batch: bool,
    pub(in crate::speech) operations: BTreeMap<u64, LocalSession>,
    pub(in crate::speech) active_operation: Option<u64>,
    pub(in crate::speech) pcm: Vec<i16>,
    pub(in crate::speech) consumed_samples: u64,
    pub(in crate::speech) input_closed: bool,
    pub(in crate::speech) source: Option<CaptureOrigin>,
    pub(in crate::speech) file_audio: Option<VecDeque<u8>>,
    pub(in crate::speech) live_draft: String,
    pub(in crate::speech) results: VecDeque<LiveEvent>,
    pub(super) minutes_schedule: crate::live_minutes::LiveMinutesSchedule,
    pub saved: bool,
    pub terminal: bool,
    pub(in crate::speech) success: bool,
    pub captured_pcm_bytes: u64,
}
impl SpeechSession {
    pub(super) fn capture_source(&self) -> Option<CaptureOrigin> {
        self.source
    }

    pub(super) fn drafts(&self) -> impl Iterator<Item = &str> {
        let live = (!self.live_draft.is_empty()).then_some(self.live_draft.as_str());
        live.into_iter().chain(
            self.operations
                .values()
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

pub(super) struct SpeechState {
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
    pub(super) fn record_speech_engine(&self, id: &str) -> SpeechEngine {
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
    pub(super) fn speech_ready(&self, engine: &SpeechEngine) -> bool {
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
            self.commit(|w| w.bind_speech_engine(id, engine.clone()))?;
            let session = SpeechSession {
                key: RequestKey {
                    record_id: id.into(),
                    attempt: 0,
                    input_revision: 0,
                },
                engine,
                stream: None,
                deferred_batch: true,
                operations: BTreeMap::new(),
                active_operation: None,
                pcm: Vec::new(),
                consumed_samples: 0,
                input_closed: false,
                source,
                file_audio: None,
                live_draft: String::new(),
                results: VecDeque::new(),
                minutes_schedule: Default::default(),
                saved: false,
                terminal: false,
                success: false,
                captured_pcm_bytes: 0,
            };
            self.captures.sessions.insert(id.into(), session);
            return Ok(());
        }
        let key = self.commit(|w| {
            w.bind_speech_engine(id, engine.clone())?;
            w.begin_analysis(id, AnalysisStage::Transcribing)
        })?;
        let mut session = SpeechSession {
            key,
            engine: engine.clone(),
            stream: None,
            deferred_batch: false,
            operations: BTreeMap::new(),
            active_operation: None,
            pcm: Vec::new(),
            consumed_samples: 0,
            input_closed: false,
            source,
            file_audio: None,
            live_draft: String::new(),
            results: VecDeque::new(),
            minutes_schedule: Default::default(),
            saved: false,
            terminal: false,
            success: false,
            captured_pcm_bytes: 0,
        };
        if engine == SpeechEngine::Cloud {
            if let Some(error) = blocked {
                session.results.push_back(LiveEvent::Failed(error));
            } else if !self.cloud_asr_configured() {
                session.results.push_back(LiveEvent::Failed(
                    "请先配置云端语音凭据；原始录音已保留".into(),
                ));
            } else {
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
                    Ok(stream) => session.stream = Some(stream),
                    Err(e) => session.results.push_back(LiveEvent::Failed(e)),
                }
            }
        }
        self.captures.sessions.insert(id.into(), session);
        Ok(())
    }
    pub(super) fn start_file_speech(&mut self, id: &str, pcm: Vec<u8>) -> Result<(), String> {
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
            s.consumed_samples = offset.saturating_mul(16);
            s.captured_pcm_bytes = offset.saturating_mul(32);
        }
        self.drive_speech_files();
        Ok(())
    }
    pub(super) fn drive_speech_files(&mut self) -> bool {
        let ids: Vec<_> = self
            .captures
            .sessions
            .iter()
            .filter(|(_, s)| {
                !s.terminal && s.file_audio.is_some() && s.operations.len() < MAX_PENDING_WINDOWS
            })
            .map(|(id, _)| id.clone())
            .collect();
        let mut changed = false;
        for id in ids {
            let Some(s) = self.captures.sessions.get_mut(&id) else {
                continue;
            };
            if s.engine == SpeechEngine::AppleSpeech && self.speech.apple_owner.is_some() {
                continue;
            }
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
                self.error = Some(error);
            }
            if finished {
                self.finish_speech(&id);
            }
        }
        changed
    }
    pub(super) fn feed_speech(&mut self, id: &str, pcm16: &[u8], source: Option<CaptureOrigin>) -> Result<(), String> {
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
        if !session.terminal && !session.input_closed {
            if let Some(stream) = &mut session.stream {
                for chunk in pcm16.chunks(64 * 1024) {
                    if let Err(error) = stream.push_audio(chunk.to_vec()) {
                        session.results.extend(stream.poll());
                        session.results.push_back(LiveEvent::Failed(error));
                        session.stream = None;
                        break;
                    }
                }
            } else if session.engine != SpeechEngine::Cloud
                && !session
                    .results
                    .iter()
                    .any(|e| matches!(e, LiveEvent::Failed(_)))
            {
                for bytes in pcm16.chunks(2) {
                    if bytes.len() == 2 {
                        session.pcm.push(i16::from_le_bytes([bytes[0], bytes[1]]));
                    }
                }
                if let Err(error) = self.flush_speech_window(&mut session, false) {
                    session.results.push_back(LiveEvent::Failed(error));
                }
            }
        }
        self.captures.sessions.insert(id.into(), session);
        self.poll_captures();
        Ok(())
    }
    fn flush_speech_window(&mut self, s: &mut SpeechSession, finish: bool) -> Result<(), String> {
        match s.engine {
            SpeechEngine::AppleSpeech => {
                if s.pcm.len() > WINDOW_SAMPLES * MAX_PENDING_WINDOWS {
                    return Err("本机识别队列已满，音频已保留，可稍后补转写".into());
                }
                if s.active_operation.is_none() && self.speech.apple_owner.is_some() {
                    return Ok(());
                }
                if s.active_operation.is_none() && !s.pcm.is_empty() {
                    let op = self.next_job;
                    self.next_job += 1;
                    self.local_asr.start(op);
                    self.speech.apple_owner = Some(op);
                    s.operations.insert(
                        op,
                        LocalSession {
                            operation_id: op,
                            phase: LocalPhase::Active,
                            draft: String::new(),
                            elapsed_ms: 0,
                            offset_ms: s.consumed_samples / 16,
                            duration_ms: 0,
                        },
                    );
                    s.active_operation = Some(op);
                }
                if let Some(op) = s.active_operation {
                    let Some(offset) = s.operations.get(&op).map(|o| o.offset_ms) else {
                        s.active_operation = None;
                        return Ok(());
                    };
                    let current = (s.consumed_samples / 16 - offset) as usize * 16;
                    let n = s.pcm.len().min(WINDOW_SAMPLES.saturating_sub(current));
                    let bytes: Vec<u8> = s.pcm.drain(..n).flat_map(i16::to_le_bytes).collect();
                    self.local_asr.audio(op, &bytes)?;
                    s.consumed_samples += bytes.len() as u64 / 2;
                    if let Some(entry) = s.operations.get_mut(&op) {
                        entry.duration_ms = s.consumed_samples / 16 - offset;
                    }
                    if finish || current + n == WINDOW_SAMPLES {
                        self.local_asr.finish(op);
                        s.active_operation = None;
                        if let Some(entry) = s.operations.get_mut(&op) {
                            entry.phase = LocalPhase::Finishing;
                        }
                    }
                }
            }
            SpeechEngine::Downloaded(_) => {
                while s.pcm.len() >= WINDOW_SAMPLES || (finish && !s.pcm.is_empty()) {
                    if s.operations.len() >= MAX_PENDING_WINDOWS {
                        return Err("本机识别队列已满，音频已保留，可稍后补转写".into());
                    }
                    let n = s.pcm.len().min(WINDOW_SAMPLES);
                    let pcm: Vec<_> = s.pcm.drain(..n).collect();
                    let op = self.next_job;
                    self.next_job += 1;
                    self.speech
                        .worker
                        .as_ref()
                        .ok_or("本机识别不可用")?
                        .transcribe(op, pcm)?;
                    s.operations.insert(
                        op,
                        LocalSession {
                            operation_id: op,
                            phase: LocalPhase::Finishing,
                            draft: String::new(),
                            elapsed_ms: 0,
                            offset_ms: s.consumed_samples / 16,
                            duration_ms: n as u64 / 16,
                        },
                    );
                    s.consumed_samples += n as u64;
                }
            }
            SpeechEngine::Cloud => {}
        }
        Ok(())
    }
    pub(super) fn finish_speech(&mut self, id: &str) {
        if let Some(mut s) = self.captures.sessions.remove(id) {
            s.input_closed = true;
            if s.deferred_batch {
                s.terminal = true;
            } else {
                let result = if let Some(stream) = &s.stream {
                    stream.finish()
                } else {
                    self.flush_speech_window(&mut s, true)
                };
                if let Err(error) = result {
                    s.results.push_back(LiveEvent::Failed(error));
                }
                if s.stream.is_none()
                    && s.operations.is_empty()
                    && s.pcm.is_empty()
                    && s.results.is_empty()
                    && !s.terminal
                {
                    s.results.push_back(LiveEvent::Finished);
                }
            }
            self.captures.sessions.insert(id.into(), s);
        }
        self.poll_captures();
    }
}
