use super::local_asr::{LocalPhase, Readiness};
use super::*;
use koe_client_providers::{LiveEvent, TranscriptSegment};

impl KoeRuntime {
    fn reset_active_local_asr_timers(&mut self) {
        for s in self.captures.sessions.values_mut() {
            if let Some(ops) = s.local_operations_mut() {
                for op in ops.values_mut() {
                    if matches!(op.phase, LocalPhase::Active) {
                        op.elapsed_ms = 0;
                    }
                }
            }
        }
    }
    /// Transfers a bounded FIFO batch of typed Apple recognition effects to its native adapter.
    pub fn drain_local_asr_effects(&mut self) -> Vec<super::local_asr::LocalAsrEffect> {
        self.reset_active_local_asr_timers();
        self.local_asr.drain_effects()
    }
    /// Transfers a bounded FIFO batch of Apple recognition effects as binary C ABI frames.
    pub fn drain_local_asr_binary(&mut self) -> Vec<u8> {
        self.reset_active_local_asr_timers();
        self.local_asr.drain_binary()
    }
    pub(crate) fn cancel_capture_speech(&mut self, id: &str) {
        if let Some(mut session) = self.captures.sessions.remove(id) {
            self.cancel_speech_operations(&mut session);
        }
    }
    pub(super) fn cancel_speech_operations(&mut self, session: &mut SpeechSession) {
        match &mut session.backend {
            SpeechBackend::AppleLocal {
                operations,
                active_operation,
                ..
            } => {
                for &op in operations.keys() {
                    if self.speech.apple_owner == Some(op) {
                        self.speech.apple_owner = None;
                    }
                    self.local_asr.cancel(op);
                }
                operations.clear();
                *active_operation = None;
            }
            SpeechBackend::DownloadedLocal { operations, .. } => {
                operations.clear();
            }
            SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => {}
        }
    }
    pub(crate) fn local_asr_readiness(
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
                .filter_map(|s| match &s.backend {
                    SpeechBackend::AppleLocal { operations, .. } => Some(operations.keys().copied()),
                    _ => None,
                })
                .flatten()
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
    pub(crate) fn local_asr_result(
        &mut self,
        operation_id: u64,
        text: String,
        start_ms: u64,
        end_ms: u64,
        is_final: bool,
    ) -> Result<(), String> {
        let Some(s) = self.captures.sessions.values_mut().find(|s| {
            s.local_operations()
                .is_some_and(|ops| ops.contains_key(&operation_id))
        }) else {
            return Ok(());
        };
        let queued_bytes: usize = s
            .results
            .iter()
            .map(|e| match e {
                LiveEvent::Interim { segment, .. } | LiveEvent::Final { segment, .. } => {
                    segment.text.len()
                }
                LiveEvent::Failed(error) => error.len(),
                LiveEvent::Finished => 0,
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
        let offset_ms = {
            let Some(op) = s
                .local_operations_mut()
                .and_then(|ops| ops.get_mut(&operation_id))
            else {
                return Ok(());
            };
            op.elapsed_ms = 0;
            if is_final {
                op.draft.clear();
                Some(op.offset_ms)
            } else {
                op.draft = text.clone();
                None
            }
        };
        if let Some(offset_ms) = offset_ms {
            s.results.push_back(LiveEvent::Final {
                sequence: operation_id
                    .saturating_mul(1_000_000_000)
                    .saturating_add(start_ms),
                segment: TranscriptSegment {
                    start_ms: offset_ms + start_ms,
                    end_ms: offset_ms + end_ms,
                    text,
                    speaker: None,
                },
            });
            self.poll_captures();
        }
        Ok(())
    }
    pub(crate) fn local_asr_finished(&mut self, operation_id: u64) {
        if self.speech.apple_owner == Some(operation_id) {
            self.speech.apple_owner = None;
        }
        if let Some(s) = self.captures.sessions.values_mut().find(|s| {
            s.local_operations()
                .is_some_and(|ops| ops.contains_key(&operation_id))
        }) {
            match &mut s.backend {
                SpeechBackend::AppleLocal {
                    operations,
                    active_operation,
                    ..
                } => {
                    operations.remove(&operation_id);
                    if *active_operation == Some(operation_id) {
                        *active_operation = None;
                    }
                }
                SpeechBackend::DownloadedLocal { operations, .. } => {
                    operations.remove(&operation_id);
                }
                SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => {}
            }
            self.local_asr.complete(operation_id);
            if s.phase == SpeechPhase::Draining && !s.has_inflight_work() {
                s.results.push_back(LiveEvent::Finished);
            }
        }
        self.poll_captures();
        self.drive_apple_speech();
    }
    pub(crate) fn local_asr_failed(&mut self, operation_id: u64, message: String) {
        if self.speech.apple_owner == Some(operation_id) {
            self.speech.apple_owner = None;
        }
        if let Some(s) = self.captures.sessions.values_mut().find(|s| {
            s.local_operations()
                .is_some_and(|ops| ops.contains_key(&operation_id))
        }) {
            match &mut s.backend {
                SpeechBackend::AppleLocal {
                    operations,
                    active_operation,
                    ..
                } => {
                    operations.remove(&operation_id);
                    if *active_operation == Some(operation_id) {
                        *active_operation = None;
                    }
                }
                SpeechBackend::DownloadedLocal { operations, .. } => {
                    operations.remove(&operation_id);
                }
                SpeechBackend::CloudLive { .. } | SpeechBackend::CloudDeferredBatch => {}
            }
            self.local_asr.cancel(operation_id);
            s.results.push_back(LiveEvent::Failed(
                message.chars().take(MAX_MESSAGE_BYTES).collect(),
            ));
        }
        self.poll_captures();
    }
    pub(crate) fn drive_apple_speech(&mut self) -> bool {
        if self.speech.apple_owner.is_some() {
            return false;
        }
        let id = self
            .captures
            .sessions
            .iter()
            .filter(|(_, s)| {
                !s.is_terminal()
                    && matches!(&s.backend, SpeechBackend::AppleLocal { pcm, .. } if !pcm.is_empty())
            })
            .min_by_key(|(_, s)| s.key.attempt)
            .map(|(id, _)| id.clone());
        let Some(id) = id else {
            return false;
        };
        let Some(mut s) = self.captures.sessions.remove(&id) else {
            return false;
        };
        let finish = s.phase == SpeechPhase::Draining;
        if let Err(error) = self.flush_speech_window(&mut s, finish) {
            s.results.push_back(LiveEvent::Failed(error));
        }
        self.captures.sessions.insert(id, s);
        true
    }
    pub(crate) fn tick_local_asr(&mut self, elapsed_ms: u64) {
        let mut timeout = Vec::new();
        for s in self.captures.sessions.values_mut() {
            if let SpeechBackend::AppleLocal { operations, .. } = &mut s.backend {
                for op in operations.values_mut() {
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
}
