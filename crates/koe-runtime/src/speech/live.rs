use super::*;
use koe_client_providers::{LiveEvent, TranscriptSegment};
use koe_client_services::product_store::StoreError;
use serde_json::json;
use std::collections::BTreeSet;

impl KoeRuntime {
    pub(crate) fn live_caption_json(&self) -> Value {
        let Some((id, s)) = self
            .captures
            .sessions
            .iter()
            .find(|(_, s)| !s.is_terminal())
        else {
            return Value::Null;
        };
        let text = s
            .drafts()
            .next()
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
        let status = if s.is_deferred_batch() {
            "录音结束后自动转写（非实时模型）"
        } else if s.phase == SpeechPhase::Draining {
            "正在保存最后的字幕"
        } else {
            "正在转写"
        };
        json!({"recordId":id,"text":text.chars().rev().take(120).collect::<Vec<_>>().into_iter().rev().collect::<String>(),"status":status})
    }
    pub(crate) fn capture_saved(&mut self, id: &str) -> bool {
        if let Some(s) = self.captures.sessions.get_mut(id) {
            s.saved = true;
            true
        } else {
            false
        }
    }
    pub(crate) fn local_capture_record_ids(&self) -> BTreeSet<String> {
        self.captures
            .sessions
            .iter()
            .filter(|(_, s)| !s.is_cloud())
            .map(|(id, _)| id.clone())
            .collect()
    }
    pub(crate) fn cancel_cloud_captures(&mut self) {
        for session in self
            .captures
            .sessions
            .values_mut()
            .filter(|s| s.is_cloud())
        {
            session.drop_cloud_stream();
            session.clear_live_draft();
            session.results.clear();
            session.phase = SpeechPhase::Cancelled;
        }
    }
    pub(crate) fn accept_speech_final(
        &mut self,
        key: &RequestKey,
        delivery: &str,
        segment: &TranscriptSegment,
        provider: &str,
    ) -> Result<SegmentId, StoreError> {
        self.store.transact(|w| {
            w.accept_transcript_with_speaker(
                key,
                TranscriptFinal {
                    final_id: delivery,
                    text: &segment.text,
                    start_ms: segment.start_ms,
                    end_ms: segment.end_ms,
                    provider,
                    speaker: segment.speaker.as_deref(),
                },
            )
        })
    }
    pub(crate) fn poll_captures(&mut self) -> bool {
        let mut sessions = std::mem::take(&mut self.captures.sessions);
        let active_downloaded_sessions = sessions
            .values()
            .filter(|s| !s.is_terminal() && s.is_downloaded())
            .count();
        let mut changed = false;
        for (id, s) in &mut sessions {
            if let SpeechBackend::CloudLive {
                stream: Some(stream),
                ..
            } = &mut s.backend
            {
                s.results.extend(stream.poll());
            }
            while let Some(event) = s.results.front() {
                let result = match event {
                    LiveEvent::Interim { segment, .. } => {
                        if let SpeechBackend::CloudLive { live_draft, .. } = &mut s.backend {
                            if *live_draft != segment.text {
                                live_draft.clone_from(&segment.text);
                                changed = true;
                            }
                        }
                        s.results.pop_front();
                        continue;
                    }
                    LiveEvent::Final { sequence, segment } => self
                        .accept_speech_final(
                            &s.key,
                            &sequence.to_string(),
                            segment,
                            s.provider_label(),
                        )
                        .map(|_| ()),
                    LiveEvent::Finished => self
                        .store
                        .transact(|w| {
                            if w.record(id).is_some_and(|r| !r.aggregate.spine.is_empty()) {
                                w.finish_transcription(&s.key)
                            } else {
                                w.fail_analysis(&s.key, "未识别到语音，原始录音已保留")
                            }
                        })
                        .map(|_| ()),
                    LiveEvent::Failed(error) => self
                        .store
                        .transact(|w| w.fail_analysis(&s.key, error))
                        .map(|_| ()),
                };
                match result {
                    Ok(()) => {
                        changed = true;
                        self.clear_error();
                        match event {
                            LiveEvent::Interim { .. } => {}
                            LiveEvent::Final { .. } => {
                                s.clear_live_draft();
                                s.minutes_schedule.observe_final();
                            }
                            LiveEvent::Finished => {
                                s.clear_live_draft();
                                let succeeded = self
                                    .workspace()
                                    .record(id)
                                    .is_some_and(|r| !r.aggregate.spine.is_empty());
                                s.phase = SpeechPhase::Completed { succeeded };
                                s.drop_cloud_stream();
                            }
                            LiveEvent::Failed(error) => {
                                self.set_error(error.clone());
                                s.clear_live_draft();
                                s.phase = SpeechPhase::Completed { succeeded: false };
                                s.drop_cloud_stream();
                                let cancel_worker = self.speech.preparation.is_none()
                                    && active_downloaded_sessions == 1;
                                self.cancel_speech_operations(s, cancel_worker);
                                s.clear_local_pcm();
                            }
                        }
                        s.results.pop_front();
                    }
                    Err(StoreError::Domain(
                        ProductError::StaleRequest
                        | ProductError::UnknownRecord
                        | ProductError::RecordTrashed,
                    )) => {
                        s.clear_live_draft();
                        s.phase = SpeechPhase::Cancelled;
                        s.drop_cloud_stream();
                        s.results.clear();
                        let cancel_worker = self.speech.preparation.is_none()
                            && active_downloaded_sessions == 1;
                        self.cancel_speech_operations(s, cancel_worker);
                        break;
                    }
                    Err(error) => {
                        let message = format!("实时文字等待保存：{error}");
                        self.drain_error = Some(message.clone());
                        self.set_error(message);
                        break;
                    }
                }
            }
            if s.saved && s.phase == SpeechPhase::DeferredReady {
                if recording_assets::audio_path(&self.root, id).is_ok_and(|p| p.exists()) {
                    self.auto_transcribe.insert(id.clone());
                    changed = true;
                }
            } else if s.saved && s.phase == (SpeechPhase::Completed { succeeded: true }) {
                self.auto_summarize.insert(id.clone());
            }
        }
        sessions.retain(|_, s| !(s.saved && s.phase.is_terminal() && s.results.is_empty()));
        self.captures.sessions = sessions;
        changed
    }
}
