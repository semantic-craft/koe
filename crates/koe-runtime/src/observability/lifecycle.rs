use crate::*;
use koe_engine::session::TransferPhaseTag;
use serde_json::json;

#[derive(Default, PartialEq, Eq)]
pub(crate) enum QuitState {
    #[default]
    Running,
    Draining,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct LifecycleState {
    keep_awake: bool,
    quit_phase: &'static str,
    message: Option<String>,
}

impl KoeRuntime {
    pub(crate) fn is_quitting(&self) -> bool {
        self.quit == QuitState::Draining
    }

    pub(crate) fn request_quit(&mut self) {
        if self.is_quitting() {
            return;
        }
        self.quit = QuitState::Draining;
        self.cancel_app_update_check();
        let _ = self.stop_microphone(false);
        let session = &self.device.session;
        if self.device.awaiting_stop
            || session.device_recording_active
            || session.pending_realtime_subscribe
            || (session.active_is_realtime && !session.transfer.quiet_draining)
        {
            self.device.stop_recording();
        }
    }

    pub(crate) fn lifecycle_state(&self) -> LifecycleState {
        let session = &self.device.session;
        let owned_work = self.active_capture.microphone().is_some()
            || self.is_device_busy()
            || session.active_file_id.is_some()
            || session.pending_realtime_subscribe
            || !self.device.finalized.is_empty()
            || !self.device.captures.is_empty()
            || !self.captures.sessions.is_empty()
            || !self.pending.is_empty()
            || !self.completed.is_empty()
            || (self.is_quitting() && session.transfer.phase == TransferPhaseTag::Failed);
        let queued_work = !self.is_quitting()
            && ((!self.auto_summarize.is_empty() && self.text_provider_configured())
                || (!self.auto_transcribe.is_empty()
                    && self.auto_transcribe.iter().any(|id| {
                        let engine = self.record_speech_engine(id);
                        engine != SpeechEngine::Cloud
                            || (self.cloud_asr_configured()
                                && self.ensure_meeting_audio_upload().is_ok())
                    })));
        let failure = if self.store.requires_reopen() {
            Some("无法确认保存结果，退出已暂停。请保留应用并恢复存储后处理。".to_string())
        } else if let Some(error) = self
            .active_capture
            .microphone()
            .and_then(|m| m.save_error.as_ref())
        {
            Some(error.clone())
        } else if let Some(error) = &self.drain_error {
            Some(error.clone())
        } else if session.is_offline_pull_suspended() {
            Some("录音取回已暂停，请重新连接录音豆，或取消退出继续处理。".into())
        } else if session.transfer.phase == TransferPhaseTag::Failed {
            Some("录音取回失败，退出已暂停。请取消退出后重试取回。".into())
        } else if self.device.awaiting_stop && !self.device.is_connected() {
            Some("正在等待录音豆确认停止，请恢复连接，或取消退出。".into())
        } else {
            None
        };
        let phase = if !self.is_quitting() {
            "running"
        } else if failure.is_some() {
            "blocked"
        } else if owned_work {
            "draining"
        } else {
            "ready"
        };
        LifecycleState {
            keep_awake: owned_work || queued_work || self.store.requires_reopen(),
            quit_phase: phase,
            message: if self.is_quitting() {
                failure.or_else(|| {
                    (phase == "draining").then(|| "正在结束录音并保存结果，完成后将自动退出。".into())
                })
            } else {
                None
            },
        }
    }

    pub(crate) fn quit_blocker_codes(&self) -> Vec<&'static str> {
        let session = &self.device.session;
        let mut blockers = Vec::new();
        if self.store.requires_reopen() {
            blockers.push("store_requires_reopen");
        }
        if self
            .active_capture
            .microphone()
            .is_some_and(|m| m.save_error.is_some())
        {
            blockers.push("microphone_save_error");
        }
        if self.drain_error.is_some() {
            blockers.push("drain_error");
        }
        if session.is_offline_pull_suspended() {
            blockers.push("offline_pull_suspended");
        }
        if session.transfer.phase == TransferPhaseTag::Failed {
            blockers.push("transfer_failed");
        }
        if self.device.awaiting_stop && !self.device.is_connected() {
            blockers.push("awaiting_stop_disconnected");
        }
        if self.active_capture.microphone().is_some() {
            blockers.push("active_microphone");
        }
        if self.is_device_busy()
            || session.active_file_id.is_some()
            || session.pending_realtime_subscribe
        {
            blockers.push("device_busy");
        }
        if !self.device.finalized.is_empty()
            || !self.device.captures.is_empty()
            || !self.captures.sessions.is_empty()
        {
            blockers.push("pending_captures");
        }
        if !self.pending.is_empty() {
            blockers.push("pending_provider_work");
        }
        if !self.completed.is_empty() {
            blockers.push("completed_queue_nonempty");
        }
        blockers
    }

    pub(crate) fn lifecycle_json(&self) -> Value {
        let state = self.lifecycle_state();
        json!({
            "keepAwake": state.keep_awake,
            "quitPhase": state.quit_phase,
            "message": state.message
        })
    }

    pub(crate) fn save_captures(&mut self, now: u64) -> Result<(), String> {
        let result = self
            .process_capture_events(now)
            .and_then(|()| self.save_device_recordings(now));
        if let Err(error) = &result {
            self.drain_error = Some(error.clone());
        }
        result
    }
}
