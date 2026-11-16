use super::*;
use crate::local_asr::{LocalPhase, LocalSession, Readiness, MAX_MESSAGE_BYTES};
use koe_client_providers::{
    offline_speech_models, LiveEvent, LiveTranscription, OfflineSpeechEvent, OfflineSpeechWorker,
    ProviderConfig, TranscriptSegment, DASHSCOPE_ASR_MODEL,
};
use koe_client_services::product_store::StoreError;
use serde_json::json;
use std::collections::{BTreeSet, VecDeque};

const WINDOW_SAMPLES: usize = 16_000 * 15;
const MAX_PENDING_WINDOWS: usize = 4;

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(super) enum DictationSource {
    Microphone,
    Bean,
    Standby,
}

pub(super) struct SpeechSession {
    key: RequestKey,
    engine: SpeechEngine,
    stream: Option<LiveTranscription>,
    operations: BTreeMap<u64, LocalSession>,
    active_operation: Option<u64>,
    pcm: Vec<i16>,
    consumed_samples: u64,
    input_closed: bool,
    source: Option<DictationSource>,
    file_audio: Option<VecDeque<u8>>,
    results: VecDeque<LiveEvent>,
    selected_ranges: Vec<(u64, Option<u64>)>,
    published: BTreeSet<String>,
    pub(super) minutes_schedule: crate::live_minutes::LiveMinutesSchedule,
    pub saved: bool,
    pub terminal: bool,
    success: bool,
    pub captured_pcm_bytes: u64,
}
impl SpeechSession {
    pub(super) fn capture_source(&self) -> Option<DictationSource> {
        self.source
    }

    pub(super) fn drafts(&self) -> impl Iterator<Item = &str> {
        self.operations
            .values()
            .map(|op| op.draft.as_str())
            .filter(|text| !text.is_empty())
    }
}

#[derive(Default)]
struct ModelState {
    state: String,
    bytes: u64,
    message: Option<String>,
}
struct ModelPreparation {
    id: String,
    cancelled: bool,
}

pub(super) struct SpeechState {
    worker: Option<OfflineSpeechWorker>,
    worker_error: Option<String>,
    loaded_model_id: Option<String>,
    preparation: Option<ModelPreparation>,
    apple_owner: Option<u64>,
    models: BTreeMap<String, ModelState>,
    dictation: BTreeSet<DictationSource>,
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
            dictation: BTreeSet::new(),
        }
    }
}
impl KoeRuntime {
    pub(super) fn configure_speech(
        &mut self,
        engine: &str,
        model_id: Option<String>,
    ) -> Result<(), String> {
        let engine = match engine {
            "apple_speech" => SpeechEngine::AppleSpeech,
            "cloud" => SpeechEngine::Cloud,
            "downloaded" => {
                let id = model_id.unwrap_or_else(|| "sensevoice-small".into());
                if !offline_speech_models().iter().any(|m| m.id == id) {
                    return Err("未找到此语音模型".into());
                }
                SpeechEngine::Downloaded(id)
            }
            _ => return Err("无法识别语音引擎".into()),
        };
        self.commit(|w| {
            let mut c = w.provider_configuration().clone();
            c.speech_engine = engine.clone();
            w.configure_provider(c)
        })?;
        if let SpeechEngine::Downloaded(id) = engine {
            if self.speech.loaded_model_id.as_deref() != Some(&id)
                && self.speech.models.get(&id).is_some_and(|s| s.bytes > 0)
            {
                self.prepare_speech_model(&id)?;
            }
        }
        Ok(())
    }
    pub(super) fn prepare_speech_model(&mut self, id: &str) -> Result<(), String> {
        if !offline_speech_models().iter().any(|m| m.id == id) {
            return Err("未找到此语音模型".into());
        }
        if self.speech.preparation.is_some() {
            return Err("请等待当前模型准备结束；取消后也需等待后台确认".into());
        }
        if self
            .captures
            .sessions
            .values()
            .any(|s| matches!(s.engine, SpeechEngine::Downloaded(_)) && !s.terminal)
        {
            return Err("请等待当前本机转写结束后切换模型".into());
        }
        let worker = self.speech.worker.as_ref().ok_or_else(|| {
            self.speech
                .worker_error
                .clone()
                .unwrap_or_else(|| "本机识别不可用".into())
        })?;
        worker.prepare(id)?;
        self.speech.preparation = Some(ModelPreparation {
            id: id.into(),
            cancelled: false,
        });
        self.speech.loaded_model_id = None;
        for state in self
            .speech
            .models
            .values_mut()
            .filter(|s| s.state == "ready")
        {
            state.state = "downloaded".into();
        }
        self.speech.models.insert(
            id.into(),
            ModelState {
                state: "preparing".into(),
                bytes: 0,
                message: None,
            },
        );
        Ok(())
    }
    pub(super) fn cancel_speech_model(&mut self) {
        if self
            .captures
            .sessions
            .values()
            .any(|s| matches!(s.engine, SpeechEngine::Downloaded(_)) && !s.terminal)
        {
            self.notice = Some("请先结束当前本机转写".into());
            return;
        }
        if let Some(preparation) = &mut self.speech.preparation {
            preparation.cancelled = true;
        }
        self.speech.loaded_model_id = None;
        for state in self
            .speech
            .models
            .values_mut()
            .filter(|s| s.state == "ready")
        {
            state.state = "downloaded".into();
        }
        if let Some(worker) = &self.speech.worker {
            worker.cancel();
        }
        for state in self
            .speech
            .models
            .values_mut()
            .filter(|s| s.state == "preparing")
        {
            state.state = "missing".into();
            state.message = Some("已取消准备".into());
        }
    }
    pub(super) fn speech_json(&self) -> Value {
        let engine = &self.workspace().provider_configuration().speech_engine;
        json!({"engine":engine.as_str(),"modelId":match engine { SpeechEngine::Downloaded(id)=>Some(id),_=>None },
            "models":offline_speech_models().iter().map(|m| {let s=self.speech.models.get(m.id);json!({"id":m.id,"name":m.name,"sizeBytes":m.size_bytes,"languages":m.languages,"state":s.map_or("missing",|s|s.state.as_str()),"downloadedBytes":s.map_or(0,|s|s.bytes),"message":s.and_then(|s|s.message.as_ref())})}).collect::<Vec<_>>(),
            "appleState":self.local_asr.state,"appleMessage":self.local_asr.message})
    }
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
            SpeechEngine::Cloud => !self.settings.key.is_empty(),
        }
    }
    fn ensure_speech_session(&mut self, id: &str, source: Option<DictationSource>) -> Result<(), String> {
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
        let key = self.commit(|w| {
            w.bind_speech_engine(id, engine.clone())?;
            w.begin_analysis(id, AnalysisStage::Transcribing)
        })?;
        let mut session = SpeechSession {
            key,
            engine: engine.clone(),
            stream: None,
            operations: BTreeMap::new(),
            active_operation: None,
            pcm: Vec::new(),
            consumed_samples: 0,
            input_closed: false,
            source,
            file_audio: None,
            results: VecDeque::new(),
            selected_ranges: Vec::new(),
            published: BTreeSet::new(),
            minutes_schedule: Default::default(),
            saved: false,
            terminal: false,
            success: false,
            captured_pcm_bytes: 0,
        };
        if source.is_some_and(|source| self.dictation_active(source)) {
            session.selected_ranges.push((0, None));
        }
        if engine == SpeechEngine::Cloud {
            if let Some(error) = blocked {
                session.results.push_back(LiveEvent::Failed(error));
            } else if self.settings.key.is_empty() {
                session.results.push_back(LiveEvent::Failed(
                    "请先配置云端语音凭据；原始录音已保留".into(),
                ));
            } else {
                match LiveTranscription::start(ProviderConfig::new(
                    self.workspace()
                        .provider_configuration()
                        .asr_endpoint
                        .clone(),
                    DASHSCOPE_ASR_MODEL.into(),
                    self.settings.key.clone(),
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
            changed = true;
            let audio = s.file_audio.as_mut().unwrap();
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
    pub(super) fn feed_speech(&mut self, id: &str, pcm16: &[u8], source: Option<DictationSource>) -> Result<(), String> {
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
                    let current =
                        (s.consumed_samples / 16 - s.operations[&op].offset_ms) as usize * 16;
                    let n = s.pcm.len().min(WINDOW_SAMPLES.saturating_sub(current));
                    let bytes: Vec<u8> = s.pcm.drain(..n).flat_map(i16::to_le_bytes).collect();
                    self.local_asr.audio(op, &bytes)?;
                    s.consumed_samples += bytes.len() as u64 / 2;
                    let offset = s.operations[&op].offset_ms;
                    s.operations.get_mut(&op).unwrap().duration_ms =
                        s.consumed_samples / 16 - offset;
                    if finish || current + n == WINDOW_SAMPLES {
                        self.local_asr.finish(op);
                        s.active_operation = None;
                        s.operations.get_mut(&op).unwrap().phase = LocalPhase::Finishing;
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
            self.captures.sessions.insert(id.into(), s);
        }
        self.poll_captures();
    }
    /// Transfers a bounded FIFO batch of Apple recognition effects to its native adapter.
    pub fn drain_local_asr_json(&mut self) -> String {
        for s in self.captures.sessions.values_mut() {
            for op in s.operations.values_mut() {
                if matches!(op.phase, LocalPhase::Active) {
                    op.elapsed_ms = 0;
                }
            }
        }
        self.local_asr.drain()
    }
    pub(super) fn cancel_capture_speech(&mut self, id: &str) {
        if let Some(mut session) = self.captures.sessions.remove(id) {
            self.cancel_speech_operations(&mut session);
        }
    }
    fn cancel_speech_operations(&mut self, session: &mut SpeechSession) {
        if session.engine == SpeechEngine::AppleSpeech {
            for &op in session.operations.keys() {
                if self.speech.apple_owner == Some(op) {
                    self.speech.apple_owner = None;
                }
                self.local_asr.cancel(op);
            }
        }
        session.operations.clear();
        session.active_operation = None;
    }
    pub(super) fn local_asr_readiness(
        &mut self,
        state: Readiness,
        message: String,
    ) -> Result<(), String> {
        if message.len() > MAX_MESSAGE_BYTES {
            return Err("本机识别状态内容过大".into());
        }
        self.local_asr.state = state;
        self.local_asr.message = message;
        if state == Readiness::Unavailable {
            let ops: Vec<_> = self
                .captures
                .sessions
                .values()
                .filter(|s| s.engine == SpeechEngine::AppleSpeech)
                .flat_map(|s| s.operations.keys().copied())
                .collect();
            for op in ops {
                self.local_asr_failed(
                    op,
                    format!("本机语音识别不可用：{}", self.local_asr.message),
                );
            }
        }
        Ok(())
    }
    pub(super) fn local_asr_result(
        &mut self,
        operation_id: u64,
        text: String,
        start_ms: u64,
        end_ms: u64,
        is_final: bool,
    ) -> Result<(), String> {
        let Some(s) = self
            .captures
            .sessions
            .values_mut()
            .find(|s| s.operations.contains_key(&operation_id))
        else {
            return Ok(());
        };
        let queued_bytes: usize = s
            .results
            .iter()
            .map(|e| match e {
                LiveEvent::Final { segment, .. } => segment.text.len(),
                LiveEvent::Failed(error) => error.len(),
                _ => 0,
            })
            .sum();
        if text.len().saturating_add(queued_bytes) > MAX_MESSAGE_BYTES
            || start_ms > end_ms
            || s.results.len() >= 1024
        {
            self.local_asr_failed(operation_id, "本机识别结果超出范围，原始录音已保留".into());
            return Ok(());
        }
        if text.trim().is_empty() {
            return Ok(());
        }
        let op = s.operations.get_mut(&operation_id).unwrap();
        op.elapsed_ms = 0;
        if is_final {
            op.draft.clear();
            s.results.push_back(LiveEvent::Final {
                sequence: operation_id
                    .saturating_mul(1_000_000_000)
                    .saturating_add(start_ms),
                segment: TranscriptSegment {
                    start_ms: op.offset_ms + start_ms,
                    end_ms: op.offset_ms + end_ms,
                    text,
                },
            });
            self.poll_captures();
        } else {
            op.draft = text;
        }
        Ok(())
    }
    pub(super) fn local_asr_finished(&mut self, operation_id: u64) {
        if self.speech.apple_owner == Some(operation_id) {
            self.speech.apple_owner = None;
        }
        if let Some(s) = self
            .captures
            .sessions
            .values_mut()
            .find(|s| s.operations.contains_key(&operation_id))
        {
            s.operations.remove(&operation_id);
            if s.active_operation == Some(operation_id) {
                s.active_operation = None;
            }
            self.local_asr.complete(operation_id);
            if s.input_closed && s.operations.is_empty() && s.pcm.is_empty() {
                s.results.push_back(LiveEvent::Finished);
            }
        }
        self.poll_captures();
        self.drive_apple_speech();
    }
    pub(super) fn local_asr_failed(&mut self, operation_id: u64, message: String) {
        if self.speech.apple_owner == Some(operation_id) {
            self.speech.apple_owner = None;
        }
        if let Some(s) = self
            .captures
            .sessions
            .values_mut()
            .find(|s| s.operations.contains_key(&operation_id))
        {
            s.operations.remove(&operation_id);
            if s.active_operation == Some(operation_id) {
                s.active_operation = None;
            }
            self.local_asr.cancel(operation_id);
            s.results.push_back(LiveEvent::Failed(
                message.chars().take(MAX_MESSAGE_BYTES).collect(),
            ));
        }
        self.poll_captures();
    }
    pub(super) fn drive_apple_speech(&mut self) -> bool {
        if self.speech.apple_owner.is_some() {
            return false;
        }
        let id = self
            .captures
            .sessions
            .iter()
            .filter(|(_, s)| {
                s.engine == SpeechEngine::AppleSpeech && !s.terminal && !s.pcm.is_empty()
            })
            .min_by_key(|(_, s)| s.key.attempt)
            .map(|(id, _)| id.clone());
        let Some(id) = id else {
            return false;
        };
        let mut s = self.captures.sessions.remove(&id).unwrap();
        let finish = s.input_closed;
        if let Err(error) = self.flush_speech_window(&mut s, finish) {
            s.results.push_back(LiveEvent::Failed(error));
        }
        self.captures.sessions.insert(id, s);
        true
    }
    pub(super) fn tick_local_asr(&mut self, elapsed_ms: u64) {
        let mut timeout = Vec::new();
        for s in self.captures.sessions.values_mut() {
            if s.engine == SpeechEngine::AppleSpeech {
                for op in s.operations.values_mut() {
                    op.elapsed_ms = op.elapsed_ms.saturating_add(elapsed_ms);
                    if op.elapsed_ms >= 15_000 {
                        timeout.push(op.operation_id);
                    }
                }
            }
        }
        for op in timeout {
            self.local_asr_failed(op, "本机识别响应超时，原始录音和已识别文字仍会保留".into());
        }
    }
    pub(super) fn poll_offline_speech(&mut self) -> bool {
        let events = self
            .speech
            .worker
            .as_ref()
            .map_or_else(Vec::new, OfflineSpeechWorker::poll);
        let changed = !events.is_empty();
        for event in events {
            self.accept_offline_speech_event(event);
        }
        changed
    }
    pub(super) fn accept_offline_speech_event(&mut self, event: OfflineSpeechEvent) {
        match event {
            OfflineSpeechEvent::Preparing {
                model_id,
                downloaded_bytes,
                ..
            } => {
                if !self
                    .speech
                    .preparation
                    .as_ref()
                    .is_some_and(|p| p.id == model_id && !p.cancelled)
                {
                    return;
                }
                self.speech.models.insert(
                    model_id,
                    ModelState {
                        state: "preparing".into(),
                        bytes: downloaded_bytes,
                        message: None,
                    },
                );
            }
            OfflineSpeechEvent::Ready { model_id } => {
                if !self.complete_model_preparation(&model_id) {
                    return;
                }
                self.speech.loaded_model_id = Some(model_id.clone());
                for state in self
                    .speech
                    .models
                    .values_mut()
                    .filter(|s| s.state == "ready")
                {
                    state.state = "downloaded".into();
                }
                let bytes = offline_speech_models()
                    .iter()
                    .find(|m| m.id == model_id)
                    .map_or(0, |m| m.size_bytes);
                self.speech.models.insert(
                    model_id,
                    ModelState {
                        state: "ready".into(),
                        bytes,
                        message: None,
                    },
                );
            }
            OfflineSpeechEvent::PreparationFailed { model_id, error } => {
                if !self.complete_model_preparation(&model_id) {
                    return;
                }
                self.speech.loaded_model_id = None;
                self.speech.models.insert(
                    model_id,
                    ModelState {
                        state: "failed".into(),
                        bytes: 0,
                        message: Some(error),
                    },
                );
            }
            OfflineSpeechEvent::TranscriptionFailed {
                operation_id,
                error,
            } => self.local_asr_failed(operation_id, error),
            OfflineSpeechEvent::Transcribed {
                operation_id,
                text,
                segments,
            } => {
                if segments.is_empty() && !text.trim().is_empty() {
                    let _ = self.local_asr_result(
                        operation_id,
                        text,
                        0,
                        self.captures
                            .sessions
                            .values()
                            .find_map(|s| s.operations.get(&operation_id).map(|o| o.duration_ms))
                            .unwrap_or(0),
                        true,
                    );
                } else {
                    for segment in segments {
                        let _ = self.local_asr_result(
                            operation_id,
                            segment.text,
                            segment.start_ms,
                            segment.end_ms,
                            true,
                        );
                    }
                }
                self.local_asr_finished(operation_id);
            }
        }
    }
    fn complete_model_preparation(&mut self, id: &str) -> bool {
        if self.speech.preparation.as_ref().is_some_and(|p| p.id == id) {
            return !self.speech.preparation.take().unwrap().cancelled;
        }
        false
    }
    pub(super) fn dictation_active(&self, source: DictationSource) -> bool {
        self.speech.dictation.contains(&source)
    }

    pub(super) fn any_dictation_active(&self) -> bool {
        !self.speech.dictation.is_empty()
    }

    pub(super) fn stop_all_dictation(&mut self) {
        for source in [DictationSource::Microphone, DictationSource::Bean, DictationSource::Standby] {
            self.set_source_dictation(source, false);
        }
    }

    pub(super) fn set_dictation_active(&mut self, active: bool) {
        let source = if self.companion.standby_stream_owned {
            DictationSource::Standby
        } else if self.microphone.is_some() {
            DictationSource::Microphone
        } else {
            DictationSource::Bean
        };
        self.set_source_dictation(source, active);
    }

    pub(super) fn set_source_dictation(&mut self, source: DictationSource, active: bool) {
        if self.dictation_active(source) == active {
            return;
        }
        if source == DictationSource::Standby {
            if !active && self.companion.capture_active {
                self.flush_companion_holdback();
            }
            self.companion.capture_active = active;
        }
        if active {
            self.speech.dictation.insert(source);
        } else {
            self.speech.dictation.remove(&source);
        }
        let ids: Vec<_> = self.captures.sessions.keys().cloned().collect();
        for id in ids {
            if let Some(mut s) = self.captures.sessions.remove(&id) {
                if s.source != Some(source) || s.input_closed || s.terminal {
                    self.captures.sessions.insert(id, s);
                    continue;
                }
                let at = s.captured_pcm_bytes / 32;
                if active {
                    s.selected_ranges.push((at, None));
                } else if let Some((_, end)) = s.selected_ranges.last_mut() {
                    *end = Some(at);
                }
                if let Err(error) = self.flush_speech_window(&mut s, true) {
                    s.results.push_back(LiveEvent::Failed(error));
                }
                self.captures.sessions.insert(id, s);
            }
        }
        if source == DictationSource::Standby && !active {
            if let Err(error) = self.finish_standby_dictation() {
                self.error = Some(error);
            }
        }
    }
    pub(super) fn live_caption_json(&self) -> Value {
        let Some((id, s)) = self.captures.sessions.iter().find(|(_, s)| !s.terminal) else {
            return Value::Null;
        };
        let text = s
            .operations
            .values()
            .find_map(|o| (!o.draft.is_empty()).then_some(o.draft.as_str()))
            .or_else(|| {
                self.workspace()
                    .record(id)?
                    .aggregate
                    .spine
                    .segments()
                    .last()
                    .map(|s| s.text.as_str())
            })
            .unwrap_or("");
        json!({"recordId":id,"text":text.chars().rev().take(120).collect::<Vec<_>>().into_iter().rev().collect::<String>(),"status":if s.input_closed{"正在保存最后的字幕"}else{"正在转写"}})
    }
    pub(super) fn capture_saved(&mut self, id: &str) -> bool {
        if let Some(s) = self.captures.sessions.get_mut(id) {
            s.saved = true;
            true
        } else {
            false
        }
    }
    pub(super) fn local_capture_record_ids(&self) -> BTreeSet<String> {
        self.captures
            .sessions
            .iter()
            .filter(|(_, s)| s.engine != SpeechEngine::Cloud)
            .map(|(id, _)| id.clone())
            .collect()
    }
    pub(super) fn cancel_cloud_captures(&mut self) {
        for session in self
            .captures
            .sessions
            .values_mut()
            .filter(|s| s.engine == SpeechEngine::Cloud)
        {
            session.stream = None;
            session.results.clear();
            session.terminal = true;
            session.success = false;
        }
    }
    pub(super) fn accept_speech_final(
        &mut self,
        key: &RequestKey,
        delivery: &str,
        segment: &TranscriptSegment,
        provider: &str,
    ) -> Result<SegmentId, StoreError> {
        self.store.transact(|w| {
            w.accept_transcript(
                key,
                delivery,
                &segment.text,
                segment.start_ms,
                segment.end_ms,
                provider,
            )
        })
    }
    pub(super) fn poll_captures(&mut self) -> bool {
        let mut sessions = std::mem::take(&mut self.captures.sessions);
        let mut changed = false;
        for (id, s) in &mut sessions {
            if let Some(stream) = &mut s.stream {
                s.results.extend(stream.poll());
            }
            while let Some(event) = s.results.front() {
                let result = match event {
                    LiveEvent::Final { sequence, segment } => self
                        .accept_speech_final(
                            &s.key,
                            &sequence.to_string(),
                            segment,
                            match s.engine {
                                SpeechEngine::AppleSpeech => "apple-speech",
                                SpeechEngine::Downloaded(_) => "downloaded-speech",
                                SpeechEngine::Cloud => "dashscope",
                            },
                        )
                        .map(Some),
                    LiveEvent::Finished => self
                        .store
                        .transact(|w| {
                            if w.record(id).is_some_and(|r| !r.aggregate.spine.is_empty()) {
                                w.finish_transcription(&s.key)
                            } else {
                                w.fail_analysis(&s.key, "未识别到语音，原始录音已保留")
                            }
                        })
                        .map(|_| None),
                    LiveEvent::Failed(error) => self
                        .store
                        .transact(|w| w.fail_analysis(&s.key, error))
                        .map(|_| None),
                };
                match result {
                    Ok(segment_id) => {
                        changed = true;
                        self.error = None;
                        match event {
                            LiveEvent::Final { sequence, segment } => {
                                s.minutes_schedule.observe_final();
                                let delivery = sequence.to_string();
                                let selected = s.selected_ranges.iter().any(|(start, end)| {
                                    segment.start_ms >= *start
                                        && end.is_none_or(|end| segment.end_ms <= end)
                                });
                                if selected && s.published.insert(delivery) {
                                    self.publish_transcript(id, segment_id.unwrap(), segment);
                                }
                            }
                            LiveEvent::Finished => {
                                s.success = self
                                    .workspace()
                                    .record(id)
                                    .is_some_and(|r| !r.aggregate.spine.is_empty());
                                s.terminal = true;
                                s.stream = None;
                            }
                            LiveEvent::Failed(error) => {
                                self.error = Some(error.clone());
                                s.terminal = true;
                                s.stream = None;
                                self.cancel_speech_operations(s);
                                s.pcm.clear();
                            }
                        }
                        s.results.pop_front();
                    }
                    Err(StoreError::Domain(
                        ProductError::StaleRequest
                        | ProductError::UnknownRecord
                        | ProductError::RecordTrashed,
                    )) => {
                        s.terminal = true;
                        s.stream = None;
                        s.results.clear();
                        self.cancel_speech_operations(s);
                        break;
                    }
                    Err(error) => {
                        let message = format!("实时文字等待保存：{error}");
                        self.drain_error = Some(message.clone());
                        self.error = Some(message);
                        break;
                    }
                }
            }
            if s.saved && s.terminal && s.success {
                self.auto_summarize.insert(id.clone());
            }
        }
        sessions.retain(|_, s| !(s.saved && s.terminal && s.results.is_empty()));
        self.captures.sessions = sessions;
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preparation_is_single_owner_and_cancelled_ready_never_reenables_a_model() {
        let root = std::env::temp_dir().join(format!("koe-model-lifecycle-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let mut runtime = KoeRuntime::open(&root).unwrap();
        runtime.speech.preparation = Some(ModelPreparation {
            id: "sensevoice-small".into(),
            cancelled: false,
        });
        runtime.speech.models.insert(
            "sensevoice-small".into(),
            ModelState {
                state: "preparing".into(),
                bytes: 1,
                message: None,
            },
        );
        let busy: Value = serde_json::from_str(&runtime.dispatch_json(
            r#"{"type":"prepare_speech_model","modelId":"qwen3-asr-0.6b"}"#,
            100,
        ))
        .unwrap();
        assert!(busy["error"].as_str().unwrap().contains("等待当前模型"));
        runtime.cancel_speech_model();
        let cancelled_busy: Value = serde_json::from_str(&runtime.dispatch_json(
            r#"{"type":"prepare_speech_model","modelId":"qwen3-asr-0.6b"}"#,
            100,
        ))
        .unwrap();
        assert!(cancelled_busy["error"].is_string());
        runtime.accept_offline_speech_event(OfflineSpeechEvent::Ready {
            model_id: "sensevoice-small".into(),
        });
        let snapshot = runtime.snapshot(100);
        assert!(!snapshot["speech"]["models"]
            .as_array()
            .unwrap()
            .iter()
            .any(|model| model["state"] == "ready"));
        assert!(!runtime.speech_ready(&SpeechEngine::Downloaded("sensevoice-small".into())));
        assert!(runtime.speech.preparation.is_none());
        runtime.accept_offline_speech_event(OfflineSpeechEvent::Ready {
            model_id: "qwen3-asr-0.6b".into(),
        });
        assert!(!runtime.speech_ready(&SpeechEngine::Downloaded("qwen3-asr-0.6b".into())));
        drop(runtime);
        std::fs::remove_dir_all(root).unwrap();
    }
}
