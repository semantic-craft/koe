use super::*;
use koe_client_providers::{LiveEvent, TranscriptSegment};
use koe_client_services::product_store::StoreError;
use serde_json::json;
use std::collections::BTreeSet;

impl KoeRuntime {
    pub(crate) fn live_caption_json(&self) -> Value {
        let Some((id, s)) = self.captures.sessions.iter().find(|(_, s)| !s.terminal) else {
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
        let status = if s.deferred_batch {
            "录音结束后自动转写（非实时模型）"
        } else if s.input_closed {
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
            .filter(|(_, s)| s.engine != SpeechEngine::Cloud)
            .map(|(id, _)| id.clone())
            .collect()
    }
    pub(crate) fn cancel_cloud_captures(&mut self) {
        for session in self
            .captures
            .sessions
            .values_mut()
            .filter(|s| s.engine == SpeechEngine::Cloud)
        {
            session.stream = None;
            session.deferred_batch = false;
            session.live_draft.clear();
            session.results.clear();
            session.terminal = true;
            session.success = false;
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
                delivery,
                &segment.text,
                segment.start_ms,
                segment.end_ms,
                provider,
                segment.speaker.as_deref(),
            )
        })
    }
    pub(crate) fn poll_captures(&mut self) -> bool {
        let mut sessions = std::mem::take(&mut self.captures.sessions);
        let mut changed = false;
        for (id, s) in &mut sessions {
            if let Some(stream) = &mut s.stream {
                s.results.extend(stream.poll());
            }
            while let Some(event) = s.results.front() {
                let result = match event {
                    LiveEvent::Interim { segment, .. } => {
                        if s.live_draft != segment.text {
                            s.live_draft.clone_from(&segment.text);
                            changed = true;
                        }
                        s.results.pop_front();
                        continue;
                    }
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
                        self.error = None;
                        match event {
                            LiveEvent::Interim { .. } => {}
                            LiveEvent::Final { .. } => {
                                s.live_draft.clear();
                                s.minutes_schedule.observe_final();
                            }
                            LiveEvent::Finished => {
                                s.live_draft.clear();
                                s.success = self
                                    .workspace()
                                    .record(id)
                                    .is_some_and(|r| !r.aggregate.spine.is_empty());
                                s.terminal = true;
                                s.stream = None;
                            }
                            LiveEvent::Failed(error) => {
                                s.live_draft.clear();
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
                        s.live_draft.clear();
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
            if s.saved && s.terminal && s.deferred_batch {
                if recording_assets::audio_path(&self.root, id).is_ok_and(|p| p.exists()) {
                    self.auto_transcribe.insert(id.clone());
                    changed = true;
                }
            } else if s.saved && s.terminal && s.success {
                self.auto_summarize.insert(id.clone());
            }
        }
        sessions.retain(|_, s| !(s.saved && s.terminal && s.results.is_empty()));
        self.captures.sessions = sessions;
        changed
    }
}
