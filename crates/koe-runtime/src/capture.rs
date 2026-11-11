use super::*;
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
    pub(super) fn process_capture_events(&mut self, now: u64) -> Result<(), String> {
        while let Some(event) = self.device.captures.front().cloned() {
            match event {
                CaptureEvent::Started { file_id } => {
                    if self.workspace().companion_mode() == CompanionRoutingMode::CollarStandby
                        || self.companion.standby_stream_owned
                        || self.is_standby_file(file_id)
                    {
                        self.mark_standby_scratch_file(file_id)?;
                        self.device.captures.pop_front();
                        continue;
                    }
                    let _ = self.ensure_capture(file_id, now)?;
                }
                CaptureEvent::Audio { file_id, pcm16 } => {
                    if self.workspace().companion_mode() == CompanionRoutingMode::CollarStandby
                        || self.companion.standby_stream_owned
                        || self.is_standby_file(file_id)
                    {
                        self.mark_standby_scratch_file(file_id)?;
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
                        || (self.workspace().companion_mode() == CompanionRoutingMode::CollarStandby
                            && !self.captures.active.contains_key(&file_id))
                        || (self.companion.standby_stream_owned
                            && !self.captures.active.contains_key(&file_id))
                    {
                        self.captures.active.remove(&file_id);
                        self.device.captures.pop_front();
                        continue;
                    }
                    let id = self.captures.active.remove(&file_id);
                    if let Some(capture) = id
                        .as_ref()
                        .and_then(|id| self.captures.sessions.get_mut(id))
                    {
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
        let upload_error = self.ensure_meeting_audio_upload().err();
        if let Some(error) = &upload_error {
            self.notice = Some(error.clone());
        }
        let capture = Capture {
            transcription: if upload_error.is_none() {
                CaptureTranscription::Unstarted
            } else {
                CaptureTranscription::Revoked
            },
            stream: None,
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

    pub(super) fn capture_saved(&mut self, id: &str) -> bool {
        if let Some(capture) = self.captures.sessions.get_mut(id) {
            capture.saved = true;
            return !matches!(capture.transcription, CaptureTranscription::Unstarted);
        }
        false
    }

    pub(super) fn cancel_meeting_captures(&mut self) {
        for capture in self.captures.sessions.values_mut() {
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
                            "dashscope-live",
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
            if capture.saved && capture.terminal && capture.success {
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
