use super::*;
use koe_engine::session::TransferPhaseTag;
use serde_json::json;

#[derive(Default, PartialEq, Eq)]
pub(super) enum QuitState {
    #[default]
    Running,
    Draining,
}

impl KoeRuntime {
    pub(super) fn is_quitting(&self) -> bool {
        self.quit == QuitState::Draining
    }

    pub(super) fn request_quit(&mut self) {
        if self.is_quitting() {
            return;
        }
        self.quit = QuitState::Draining;
        let _ = self.stop_microphone(false);
        if self.companion.standby_stream_owned {
            let _ = self.stop_owned_standby_stream();
        }
        let session = &self.device.session;
        if self.device.awaiting_stop
            || session.device_recording_active
            || session.pending_realtime_subscribe
            || (session.active_is_realtime && !session.transfer.quiet_draining)
        {
            self.device.stop_recording();
        }
    }

    pub(super) fn lifecycle_json(&self) -> Value {
        let session = &self.device.session;
        let owned_work = self.microphone.is_some() || session.active_file_id.is_some()
            || session.pending_realtime_subscribe
            || session.device_recording_active
            || self.device.awaiting_stop
            || session.is_offline_pull_suspended()
            || !self.device.finalized.is_empty()
            || !self.device.captures.is_empty()
            || !self.captures.sessions.is_empty()
            || !self.pending.is_empty()
            || !self.completed.is_empty()
            || (self.is_quitting() && session.transfer.phase == TransferPhaseTag::Failed);
        let queued_work = !self.is_quitting()
            && !self.settings.key.is_empty()
            && (!self.auto_summarize.is_empty() || !self.auto_transcribe.is_empty());
        let failure = if self.store.requires_reopen() {
            Some("无法确认保存结果，退出已暂停。请保留应用并恢复存储后处理。".to_string())
        } else if let Some(error) = self.microphone.as_ref().and_then(|m|m.save_error.as_ref()) {
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
        json!({
            "keepAwake": owned_work || queued_work || self.store.requires_reopen(),
            "quitPhase": phase,
            "message": if self.is_quitting() { failure.or_else(|| (phase == "draining").then(|| "正在结束录音并保存结果，完成后将自动退出。".into())) } else { None }
        })
    }

    pub(super) fn save_captures(&mut self, now: u64) -> Result<(), String> {
        let result = self
            .process_capture_events(now)
            .and_then(|()| self.save_device_recordings(now));
        if let Err(error) = &result {
            self.drain_error = Some(error.clone());
        }
        result
    }
}
