use crate::{
    capture::{
        microphone::{MicrophoneStatus, Phase},
        studio::CaptureSelection,
        ActiveCaptureSession, SingleShotMode,
    },
    command::{CaptureAction, CaptureMode},
    *,
};
use serde::Serialize;
use serde_json::json;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActiveCapture<'a> {
    mode: CaptureMode,
    phase: &'a str,
    source_label: &'a str,
    duration_ms: u64,
    actions: Vec<CaptureAction>,
    error: Option<&'a str>,
    level: Option<f64>,
}

impl KoeRuntime {
    pub(crate) fn start_device_recording(&mut self, now: u64) -> Result<(), String> {
        if self.is_quitting() || self.store.requires_reopen() {
            return Err("当前状态暂不可开始录音豆录音".into());
        }
        if self.active_capture.microphone().is_some() {
            return Err("请先结束当前麦克风录音并完成保存".into());
        }
        if !self.active_capture.is_idle() {
            return Err("当前无法开始记录，请检查录音音源或结束当前记录".into());
        }
        if !self.device.is_connected() {
            return Err("请先连接录音豆".into());
        }
        let quitting = self.is_quitting();
        self.device.reset_failed_transfer_if_idle(quitting);
        self.ensure_device_idle()?;
        let outcome = self
            .device
            .session
            .start_realtime_recording(None, now.saturating_mul(1000));
        self.device.accept(outcome);
        Ok(())
    }

    pub(crate) fn stop_device_recording(&mut self) {
        self.device.stop_recording();
    }

    pub(crate) fn bean_capture_pending(&self) -> bool {
        self.is_bean_meeting_recording()
            || self.device.session.pending_realtime_subscribe
            || !self.captures.active.is_empty()
            || self.device.finalized.iter().any(|recording| {
                recording.is_realtime
                    || self
                        .captures
                        .targets
                        .iter()
                        .any(|(fid, _)| *fid == recording.entry.id)
                    || self
                        .unsaved_bean_capture_record_id(recording.entry.id)
                        .is_some()
            })
    }

    pub(crate) fn start_capture_mode(
        &mut self,
        mode: CaptureMode,
        stay_on_page: bool,
        now: u64,
    ) -> Result<(), String> {
        let selection = self.capture_selection();
        if !self.can_start_capture_mode(&selection) {
            return Err("当前无法开始记录，请检查录音音源或结束当前记录".into());
        }
        let bean = selection.source == "bean";
        let single_mode = match mode {
            CaptureMode::AllDay => {
                self.start_all_day(
                    if bean { "bean" } else { "microphone" },
                    selection.input_id,
                    now,
                )?;
                return Ok(());
            }
            CaptureMode::QuickNote => SingleShotMode::QuickNote,
            CaptureMode::Meeting => SingleShotMode::Meeting,
        };
        if bean {
            self.start_device_recording(now)?;
            self.active_capture = ActiveCaptureSession::BeanSingleShot { mode: single_mode };
        } else {
            let session = self.build_microphone_session(
                selection.input_id,
                self.capture_studio.include_system_audio,
                None,
                now,
            )?;
            let record_id = session.current_record_id().to_owned();
            self.active_capture = ActiveCaptureSession::SingleShotMic {
                session: Box::new(session),
                mode: Some(single_mode),
            };
            if single_mode == SingleShotMode::Meeting {
                self.selection.selected_live_minutes_record = Some(record_id);
            }
        }
        if single_mode == SingleShotMode::Meeting && !stay_on_page {
            self.go(Location {
                page: Page::LiveMinutes,
                ..Location::default()
            });
        }
        Ok(())
    }

    pub(crate) fn capture_action(
        &mut self,
        action: CaptureAction,
        clock_ns: Option<u64>,
    ) -> Result<(), String> {
        if self.active_capture.microphone().is_none()
            && self.is_bean_meeting_recording()
            && matches!(action, CaptureAction::Pause | CaptureAction::Resume)
        {
            let frame = self
                .device
                .session
                .set_realtime_paused(matches!(action, CaptureAction::Pause))
                .ok_or("当前录音豆状态无法暂停或继续")?;
            self.device.outbound.push(frame);
            return Ok(());
        }
        match action {
            CaptureAction::Pause => self.pause_microphone(),
            CaptureAction::Resume => {
                self.resume_microphone(clock_ns.ok_or("缺少恢复录音的采样时钟")?)
            }
            CaptureAction::End => {
                if self.active_capture.all_day_run().is_some() {
                    self.stop_all_day()
                } else if self.active_capture.microphone().is_some() {
                    self.stop_microphone(false)
                } else if self.is_bean_meeting_recording() {
                    self.stop_device_recording();
                    Ok(())
                } else {
                    Ok(())
                }
            }
            CaptureAction::RetryStop => {
                self.stop_device_recording();
                Ok(())
            }
            CaptureAction::RetrySave => self.save_microphone(),
            CaptureAction::Cancel => self.stop_microphone(true),
        }
    }

    pub(crate) fn can_start_capture_mode(&self, selection: &CaptureSelection) -> bool {
        selection.can_start && self.active_capture.is_idle()
    }

    pub(crate) fn active_capture_json(
        &self,
        microphone: Option<&MicrophoneStatus>,
        live_duration_ms: u64,
    ) -> Value {
        let run = self.active_capture.all_day_run();
        let can_control = !self.is_quitting() && !self.store.requires_reopen();
        let mut actions = Vec::new();
        if let Some((mic, status)) = self.active_capture.microphone().zip(microphone) {
            let mode = self
                .active_capture
                .active_capture_mode_tag(false)
                .unwrap_or(CaptureMode::QuickNote);
            if can_control {
                if mic.save_error.is_some() {
                    actions.push(CaptureAction::RetrySave);
                    if mic.phase != Phase::Saving && run.is_none() {
                        actions.push(CaptureAction::Cancel);
                    }
                } else {
                    if mic.can_pause() {
                        actions.push(CaptureAction::Pause);
                    } else if mic.phase == Phase::Paused {
                        actions.push(CaptureAction::Resume);
                    }
                    if matches!(
                        mic.phase,
                        Phase::Starting | Phase::Recording | Phase::Pausing | Phase::Paused
                    ) {
                        actions.push(CaptureAction::End);
                        if run.is_none() {
                            actions.push(CaptureAction::Cancel);
                        }
                    }
                }
            }
            return json!(ActiveCapture {
                mode,
                phase: status.phase,
                source_label: &status.input_label,
                duration_ms: status.duration_ms,
                actions,
                error: mic.save_error.as_deref().or(status.interruption),
                level: Some(mic.level),
            });
        }
        if let Some(mode) = self
            .active_capture
            .active_capture_mode_tag(self.is_bean_meeting_recording())
        {
            if can_control && self.device.awaiting_stop {
                actions.push(CaptureAction::RetryStop);
            } else if can_control
                && self.is_bean_meeting_recording()
                && !self.device.session.transfer.quiet_draining
            {
                if self.platform.kind == crate::workspace::platform::HostPlatformKind::Android
                    && !self.captures.active.is_empty()
                {
                    actions.push(if self.device.session.realtime_paused() {
                        CaptureAction::Resume
                    } else {
                        CaptureAction::Pause
                    });
                }
                actions.push(CaptureAction::End);
            }
            let mic_fallback_label;
            let source_label = if self.active_capture.all_day_is_microphone() {
                mic_fallback_label = self.platform.mic_label();
                mic_fallback_label.as_str()
            } else {
                self.device
                    .device_name
                    .as_deref()
                    .unwrap_or("Soundcore Work")
            };
            return json!(ActiveCapture {
                mode,
                phase: if self.device.awaiting_stop
                    || self.device.session.transfer.quiet_draining
                    || run.is_some_and(|r| r.stopping)
                    || !self.is_bean_meeting_recording()
                {
                    "stopping"
                } else if self.device.session.realtime_paused() {
                    "paused"
                } else if self.captures.active.is_empty() {
                    "starting"
                } else {
                    "recording"
                },
                source_label,
                duration_ms: live_duration_ms,
                actions,
                error: self.drain_error.as_deref(),
                level: None,
            });
        }
        Value::Null
    }
}
