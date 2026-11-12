use super::*;
use crate::local_asr::{LocalPhase, LocalSession, Readiness, MAX_MESSAGE_BYTES};
use koe_client_providers::{LiveEvent, LiveTranscription, ProviderConfig, DASHSCOPE_ASR_MODEL};
use koe_client_services::product_store::StoreError;
use koe_engine::session::CaptureEvent;
use std::collections::{BTreeMap, VecDeque};

enum CaptureTranscription {
    Unstarted,
    Revoked,
    Started(RequestKey),
}

pub(super) struct Capture {
    transcription: CaptureTranscription,
    stream: Option<LiveTranscription>,
    local: Option<LocalSession>,
    results: VecDeque<LiveEvent>,
    saved: bool,
    terminal: bool,
    success: bool,
    pub(super) captured_pcm_bytes: u64,
}

#[derive(Default)]
pub(super) struct Captures {
    pub(super) active: BTreeMap<u32, String>,
    pub(super) records_by_file_id: BTreeMap<u32, String>,
    pub(super) sessions: BTreeMap<String, Capture>,
    pub targets: VecDeque<Option<String>>,
}

impl KoeRuntime {
    /// Transfers a bounded FIFO batch of local speech effects to the native adapter.
    pub fn drain_local_asr_json(&mut self) -> String {
        for capture in self.captures.sessions.values_mut() {
            if let Some(local) = &mut capture.local {
                if matches!(local.phase, local_asr::LocalPhase::Active) {
                    local.elapsed_ms = 0;
                }
            }
        }
        self.local_asr.drain()
    }

    pub(super) fn process_capture_events(&mut self, now: u64) -> Result<(), String> {
        while let Some(event) = self.device.captures.front().cloned() {
            match event {
                CaptureEvent::Started { file_id } => {
                    if self.treats_file_as_standby(file_id) {
                        if self.companion.standby_stream_owned
                            || self.companion.pending_standby_stop
                        {
                            self.companion.active_standby_file_id = Some(file_id);
                        }
                        if self.can_own_as_standby_scratch(file_id) {
                            self.mark_standby_scratch_file(file_id)?;
                        }
                        if self.companion.pending_standby_stop {
                            self.companion.pending_standby_stop = false;
                            self.companion.standby_stream_owned = false;
                            self.device.stop_recording();
                        }
                        self.device.captures.pop_front();
                        continue;
                    }
                    let _ = self.ensure_capture(file_id, now)?;
                }
                CaptureEvent::Audio { file_id, pcm16 } => {
                    if !self.captures.active.contains_key(&file_id)
                        && self.treats_file_as_standby(file_id)
                    {
                        if self.companion.standby_stream_owned
                            || self.companion.pending_standby_stop
                        {
                            self.companion.active_standby_file_id = Some(file_id);
                        }
                        if self.can_own_as_standby_scratch(file_id) {
                            self.mark_standby_scratch_file(file_id)?;
                        }
                        self.device.captures.pop_front();
                        continue;
                    }
                    let id = self.ensure_capture(file_id, now)?;
                    self.ensure_live_stream(&id)?;
                    let capture = self
                        .captures
                        .sessions
                        .get_mut(&id)
                        .ok_or("实时记录状态不可用")?;
                    capture.captured_pcm_bytes = capture
                        .captured_pcm_bytes
                        .saturating_add(pcm16.len() as u64);
                    if let Some(local) = &capture.local {
                        if matches!(local.phase, LocalPhase::Active) {
                            if let Err(error) = self.local_asr.audio(local.operation_id, &pcm16) {
                                self.local_asr.cancel(local.operation_id);
                                capture.local.as_mut().unwrap().phase = LocalPhase::Closed;
                                capture.results.push_back(LiveEvent::Failed(error));
                            }
                        }
                    }
                    if let Some(stream) = &mut capture.stream {
                        for chunk in pcm16.chunks(64 * 1024) {
                            if let Err(error) = stream.push_audio(chunk.to_vec()) {
                                capture.results.extend(stream.poll());
                                capture.results.push_back(LiveEvent::Failed(error));
                                capture.stream = None;
                                break;
                            }
                        }
                    }
                }
                CaptureEvent::Finished { file_id } => {
                    if self.is_standby_file(file_id)
                        || (!self.captures.active.contains_key(&file_id)
                            && (self.companion.standby_stream_owned
                                || self.companion.pending_standby_stop))
                    {
                        if self.companion.active_standby_file_id == Some(file_id) {
                            self.companion.active_standby_file_id = None;
                        }
                        self.captures.active.remove(&file_id);
                        self.device.captures.pop_front();
                        continue;
                    }
                    let id = self.captures.active.remove(&file_id);
                    if let Some(capture) = id
                        .as_ref()
                        .and_then(|id| self.captures.sessions.get_mut(id))
                    {
                        if let Some(local) = &mut capture.local {
                            if matches!(local.phase, LocalPhase::Active) {
                                local.phase = LocalPhase::Finishing;
                                local.elapsed_ms = 0;
                                self.local_asr.finish(local.operation_id);
                            }
                        }
                        if let Some(stream) = &capture.stream {
                            if let Err(error) = stream.finish() {
                                capture.results.push_back(LiveEvent::Failed(error));
                            }
                        } else if !matches!(capture.transcription, CaptureTranscription::Started(_))
                        {
                            capture.terminal = true;
                        }
                    }
                    self.captures.targets.push_back(id);
                }
            }
            self.device.captures.pop_front();
        }
        Ok(())
    }

    fn ensure_capture(&mut self, file_id: u32, now: u64) -> Result<String, String> {
        if let Some(id) = self.captures.active.get(&file_id) {
            return Ok(id.clone());
        }
        let id = format!("live-{file_id}-{now}-{}", self.workspace().revision() + 1);
        self.commit(|w| {
            w.insert_record(
                id.clone(),
                format!("录音 {file_id}"),
                RecordOrigin::Bean,
                file_id,
                now,
                0,
            )
        })?;
        let capture = Capture {
            transcription: CaptureTranscription::Unstarted,
            stream: None,
            local: None,
            results: VecDeque::new(),
            saved: false,
            terminal: false,
            success: false,
            captured_pcm_bytes: 0,
        };
        self.captures.active.insert(file_id, id.clone());
        self.captures.records_by_file_id.insert(file_id, id.clone());
        self.captures.sessions.insert(id.clone(), capture);
        Ok(id)
    }

    fn ensure_live_stream(&mut self, id: &str) -> Result<(), String> {
        let needs_start = self.captures.sessions.get(id).is_some_and(|c| {
            matches!(c.transcription, CaptureTranscription::Unstarted) && !c.terminal
        });
        if !needs_start {
            return Ok(());
        }
        if self
            .workspace()
            .provider_configuration()
            .meeting_audio_policy
            == MeetingAudioPolicy::LocalOnly
        {
            if self.store.requires_reopen() || self.audio_policy_error.is_some() {
                return Err("工作区保存结果尚未确认，请重新打开 Koe".into());
            }
            let key = self.commit(|w| w.begin_analysis(id, AnalysisStage::Transcribing))?;
            let operation_id = self.next_job;
            self.next_job += 1;
            let capture = self.captures.sessions.get_mut(id).unwrap();
            capture.transcription = CaptureTranscription::Started(key);
            capture.local = Some(LocalSession {
                operation_id,
                phase: LocalPhase::Active,
                draft: String::new(),
                elapsed_ms: 0,
            });
            if self.local_asr.state == Readiness::Unavailable {
                capture.local.as_mut().unwrap().phase = LocalPhase::Closed;
                capture.results.push_back(LiveEvent::Failed(format!(
                    "本机语音识别不可用：{}；原始录音已保留",
                    self.local_asr.message
                )));
            } else {
                self.local_asr.start(operation_id);
            }
            if self.local_asr.state == Readiness::Unavailable {
                self.poll_captures();
            }
            return Ok(());
        }
        if let Err(error) = self.ensure_meeting_audio_upload() {
            let capture = self.captures.sessions.get_mut(id).unwrap();
            capture.terminal = true;
            capture.transcription = CaptureTranscription::Revoked;
            self.notice = Some(error);
            return Ok(());
        }
        let configured = !self.settings.key.is_empty();
        let key = if configured {
            Some(self.commit(|w| w.begin_analysis(id, AnalysisStage::Transcribing))?)
        } else {
            None
        };
        let capture = self
            .captures
            .sessions
            .get_mut(id)
            .ok_or("实时记录状态不可用")?;
        capture.transcription = key.map_or(
            CaptureTranscription::Unstarted,
            CaptureTranscription::Started,
        );
        capture.terminal = !configured;
        if configured {
            match LiveTranscription::start(ProviderConfig::new(
                self.store
                    .workspace()
                    .provider_configuration()
                    .asr_endpoint
                    .clone(),
                DASHSCOPE_ASR_MODEL.into(),
                self.settings.key.clone(),
            )) {
                Ok(stream) => capture.stream = Some(stream),
                Err(error) => capture.results.push_back(LiveEvent::Failed(error)),
            }
        }
        Ok(())
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
            let operations: Vec<_> = self
                .captures
                .sessions
                .values()
                .filter_map(|c| c.local.as_ref())
                .filter(|l| !matches!(l.phase, LocalPhase::Closed))
                .map(|l| l.operation_id)
                .collect();
            for operation in operations {
                self.local_asr_failed(
                    operation,
                    format!(
                        "本机语音识别不可用：{}；原始录音已保留",
                        self.local_asr.message
                    ),
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
        let Some(capture) = self.captures.sessions.values_mut().find(|c| {
            c.local.as_ref().is_some_and(|l| {
                l.operation_id == operation_id && !matches!(l.phase, LocalPhase::Closed)
            })
        }) else {
            return Ok(());
        };
        let queued_bytes: usize = capture
            .results
            .iter()
            .map(|event| match event {
                LiveEvent::Final { segment, .. } => segment.text.len(),
                LiveEvent::Failed(error) => error.len(),
                _ => 0,
            })
            .sum();
        if text.len().saturating_add(queued_bytes) > MAX_MESSAGE_BYTES
            || capture.results.len() >= 1024
            || start_ms > end_ms
        {
            self.local_asr_failed(
                operation_id,
                "本机识别结果超出范围，原始录音和已识别文字仍会保留".into(),
            );
            return Ok(());
        }
        if text.trim().is_empty() {
            return Ok(());
        }
        let local = capture.local.as_mut().unwrap();
        local.elapsed_ms = 0;
        if is_final {
            local.draft.clear();
            capture.results.push_back(LiveEvent::Final {
                sequence: start_ms,
                segment: koe_client_providers::TranscriptSegment {
                    start_ms,
                    end_ms,
                    text,
                },
            });
            self.poll_captures();
        } else {
            local.draft = text;
        }
        Ok(())
    }

    pub(super) fn local_asr_finished(&mut self, operation_id: u64) {
        if let Some(capture) = self.captures.sessions.values_mut().find(|c| {
            c.local.as_ref().is_some_and(|l| {
                l.operation_id == operation_id && matches!(l.phase, LocalPhase::Finishing)
            })
        }) {
            let local = capture.local.as_mut().unwrap();
            local.phase = LocalPhase::Closed;
            local.draft.clear();
            capture.results.push_back(LiveEvent::Finished);
            self.local_asr.complete(operation_id);
            self.poll_captures();
        }
    }

    pub(super) fn local_asr_failed(&mut self, operation_id: u64, message: String) {
        if let Some(capture) = self.captures.sessions.values_mut().find(|c| {
            c.local.as_ref().is_some_and(|l| {
                l.operation_id == operation_id && !matches!(l.phase, LocalPhase::Closed)
            })
        }) {
            let local = capture.local.as_mut().unwrap();
            local.phase = LocalPhase::Closed;
            self.local_asr.cancel(operation_id);
            let message = if message.len() <= MAX_MESSAGE_BYTES {
                message
            } else {
                "本机语音识别失败，原始录音已保留".into()
            };
            capture.results.push_back(LiveEvent::Failed(message));
            self.poll_captures();
        }
    }

    pub(super) fn tick_local_asr(&mut self, elapsed_ms: u64) {
        let mut timed_out = Vec::new();
        for capture in self.captures.sessions.values_mut() {
            if let Some(local) = &mut capture.local {
                if matches!(local.phase, LocalPhase::Closed) {
                    continue;
                }
                local.elapsed_ms = local.elapsed_ms.saturating_add(elapsed_ms);
                if local.elapsed_ms >= 15_000 {
                    timed_out.push(local.operation_id);
                }
            }
        }
        for operation in timed_out {
            self.local_asr_failed(
                operation,
                "本机识别响应超时，原始录音和已识别文字仍会保留".into(),
            );
        }
    }

    pub(super) fn live_caption_json(&self) -> Value {
        let capture = self
            .captures
            .active
            .values()
            .find_map(|id| self.captures.sessions.get_key_value(id))
            .or_else(|| {
                self.captures
                    .sessions
                    .iter()
                    .find(|(_, c)| !c.terminal || !c.results.is_empty())
            });
        let Some((id, capture)) = capture else {
            return Value::Null;
        };
        let Some(record) = self.workspace().record(id) else {
            return Value::Null;
        };
        let text = capture
            .local
            .as_ref()
            .filter(|local| !local.draft.is_empty())
            .map(|local| local.draft.as_str())
            .or_else(|| {
                record
                    .aggregate
                    .spine
                    .segments()
                    .last()
                    .map(|s| s.text.as_str())
            })
            .unwrap_or("");
        let text: String = text
            .chars()
            .rev()
            .take(120)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect();
        let finishing = !self.captures.active.values().any(|active| active == id);
        let status = match &record.analysis {
            AnalysisState::Failed { message, .. } => message.as_str(),
            _ if finishing => "正在保存最后的字幕",
            _ if self
                .workspace()
                .provider_configuration()
                .meeting_audio_policy
                == MeetingAudioPolicy::LocalOnly
                && self.local_asr.state == Readiness::Unavailable =>
            {
                self.local_asr.message.as_str()
            }
            _ if self
                .workspace()
                .provider_configuration()
                .meeting_audio_policy
                == MeetingAudioPolicy::LocalOnly
                && self.local_asr.state == Readiness::Preparing =>
            {
                "正在准备本机语音识别"
            }
            _ if capture.local.is_some()
                || self
                    .workspace()
                    .provider_configuration()
                    .meeting_audio_policy
                    == MeetingAudioPolicy::LocalOnly =>
            {
                "正在本机实时转写"
            }
            _ if capture.terminal => "录音中，未启用实时转写",
            _ => "正在云端实时转写",
        };
        serde_json::json!({"recordId": id, "text": text, "status": status})
    }

    pub(super) fn capture_saved(&mut self, id: &str) -> bool {
        if let Some(capture) = self.captures.sessions.get_mut(id) {
            capture.saved = true;
            return !matches!(capture.transcription, CaptureTranscription::Unstarted);
        }
        false
    }

    pub(super) fn local_capture_record_ids(&self) -> std::collections::BTreeSet<String> {
        self.captures
            .sessions
            .iter()
            .filter(|(_, capture)| capture.local.is_some())
            .map(|(id, _)| id.clone())
            .collect()
    }

    pub(super) fn cancel_cloud_captures(&mut self) {
        for capture in self.captures.sessions.values_mut() {
            if capture.local.is_some() {
                continue;
            }
            capture.stream = None;
            capture.transcription = CaptureTranscription::Revoked;
            capture.results.clear();
            capture.terminal = true;
            capture.success = false;
        }
    }

    pub(super) fn poll_captures(&mut self) -> bool {
        let mut sessions = std::mem::take(&mut self.captures.sessions);
        let mut changed = false;
        for (id, capture) in &mut sessions {
            if let Some(stream) = &mut capture.stream {
                capture.results.extend(stream.poll());
            }
            while let Some(event) = capture.results.front() {
                let CaptureTranscription::Started(key) = &capture.transcription else {
                    break;
                };
                let result = self.store.transact(|w| match event {
                    LiveEvent::Final { sequence, segment } => w
                        .accept_transcript(
                            key,
                            &sequence.to_string(),
                            &segment.text,
                            segment.start_ms,
                            segment.end_ms,
                            if capture.local.is_some() {
                                "apple-speech-live"
                            } else {
                                "dashscope-live"
                            },
                        )
                        .map(|_| ()),
                    LiveEvent::Finished => {
                        if w.record(id).is_some_and(|r| !r.aggregate.spine.is_empty()) {
                            w.finish_transcription(key)
                        } else {
                            w.fail_analysis(key, "未识别到语音，原始录音已保留")
                        }
                    }
                    LiveEvent::Failed(error) => w.fail_analysis(key, error),
                });
                match result {
                    Ok(()) => {
                        changed = true;
                        self.error = None;
                        match event {
                            LiveEvent::Finished => {
                                capture.success = self
                                    .workspace()
                                    .record(id)
                                    .is_some_and(|r| !r.aggregate.spine.is_empty());
                                capture.terminal = true;
                                capture.stream = None;
                            }
                            LiveEvent::Failed(error) => {
                                self.error = Some(error.clone());
                                capture.terminal = true;
                                capture.stream = None;
                            }
                            LiveEvent::Final { .. } => {}
                        }
                        capture.results.pop_front();
                    }
                    Err(StoreError::Domain(
                        ProductError::StaleRequest
                        | ProductError::UnknownRecord
                        | ProductError::RecordTrashed,
                    )) => {
                        capture.terminal = true;
                        capture.stream = None;
                        capture.results.clear();
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
            if capture.saved && capture.terminal && capture.success && capture.local.is_none() {
                self.auto_summarize.insert(id.clone());
            }
        }
        sessions.retain(|_, capture| {
            !(capture.saved && capture.terminal && capture.results.is_empty())
        });
        self.captures.sessions = sessions;
        changed
    }

    pub(super) fn drive_analysis_queue(&mut self) {
        if self.is_quitting() || self.settings.key.is_empty() {
            return;
        }
        let _ = self.reclaim_stale_summaries();
        if !self.pending.is_empty() || !self.completed.is_empty() {
            return;
        }
        let summary = !self.auto_summarize.is_empty();
        let Some(id) = (if summary {
            self.auto_summarize.first()
        } else {
            self.auto_transcribe.first()
        })
        .cloned() else {
            return;
        };
        let needed = self.workspace().record(&id).is_some_and(|record| {
            record.is_live()
                && if summary {
                    !record.aggregate.spine.is_empty() && record.aggregate.minutes.is_none()
                } else {
                    record.aggregate.spine.is_empty()
                }
        });
        let result = if !needed {
            Ok(())
        } else if summary {
            self.try_start_summary(&id)
        } else {
            self.try_start_transcription(&id)
        };
        let started = self.pending.values().any(|work| match work {
            PendingWork::Transcription(key) | PendingWork::Summary(key) => key.record_id == id,
            PendingWork::Ask(_) => false,
        });
        if result.is_ok() || result.as_ref().is_err_and(|e| !e.retryable()) || started {
            if summary {
                self.auto_summarize.remove(&id);
            } else {
                self.auto_transcribe.remove(&id);
            }
        }
        if let Err(error) = result {
            self.error = Some(error.message());
        }
    }
}
