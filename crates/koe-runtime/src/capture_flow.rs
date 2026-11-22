use super::*;
use crate::{
    capture_studio::CaptureSelection,
    command::{CaptureAction, CaptureMode},
    microphone::{MicrophoneStatus, Phase},
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
    pub(super) fn start_device_recording(&mut self, now: u64) -> Result<(), String> {
        if self.is_quitting() || self.store.requires_reopen() {
            return Err("当前状态暂不可开始录音豆录音".into());
        }
        if self.microphone.is_some() {
            return Err("请先结束当前麦克风录音并完成保存".into());
        }
        if self.all_day.run.is_some() || self.bean_capture_mode.is_some() {
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

    pub(super) fn stop_device_recording(&mut self) {
        self.device.stop_recording();
    }

    pub(super) fn bean_capture_pending(&self) -> bool {
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

    pub(super) fn start_capture_mode(
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
        if mode == CaptureMode::AllDay {
            self.start_all_day(
                if bean { "bean" } else { "microphone" },
                selection.input_id,
                now,
            )?;
        } else if bean {
            self.start_device_recording(now)?;
        } else {
            self.start_microphone(
                selection.input_id,
                self.capture_studio.include_system_audio,
                None,
                now,
            )?;
        }
        if let Some(mic) = &mut self.microphone {
            mic.mode = Some(mode);
        } else if mode != CaptureMode::AllDay {
            self.bean_capture_mode = Some(mode);
        }
        if mode == CaptureMode::Meeting {
            if let Some(mic) = &self.microphone {
                self.selection.selected_live_minutes_record =
                    Some(mic.current_record_id().to_owned());
            }
            if !stay_on_page {
                self.go(Location {
                    page: Page::LiveMinutes,
                    ..Location::default()
                });
            }
        }
        Ok(())
    }

    pub(super) fn reconcile_bean_capture_mode(&mut self) {
        if !self.bean_capture_pending() {
            self.bean_capture_mode = None;
        }
    }

    pub(super) fn capture_action(
        &mut self,
        action: CaptureAction,
        clock_ns: Option<u64>,
    ) -> Result<(), String> {
        if self.microphone.is_none()
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
                if self.all_day.run.is_some() {
                    self.stop_all_day()
                } else if self.microphone.is_some() {
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

    pub(super) fn can_start_capture_mode(&self, selection: &CaptureSelection) -> bool {
        selection.can_start && self.all_day.run.is_none() && self.bean_capture_mode.is_none()
    }

    pub(super) fn active_capture_json(
        &self,
        microphone: Option<&MicrophoneStatus>,
        live_duration_ms: u64,
    ) -> Value {
        let run = self.all_day.run.as_ref();
        let can_control = !self.is_quitting() && !self.store.requires_reopen();
        let mut actions = Vec::new();
        if let Some((mic, status)) = self.microphone.as_ref().zip(microphone) {
            let mode = if run.is_some() {
                CaptureMode::AllDay
            } else {
                mic.mode.unwrap_or(CaptureMode::QuickNote)
            };
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
        if run.is_some() || self.bean_capture_mode.is_some() || self.is_bean_meeting_recording() {
            let mode = if run.is_some() {
                CaptureMode::AllDay
            } else {
                self.bean_capture_mode.unwrap_or(CaptureMode::QuickNote)
            };
            if can_control && self.device.awaiting_stop {
                actions.push(CaptureAction::RetryStop);
            } else if can_control
                && self.is_bean_meeting_recording()
                && !self.device.session.transfer.quiet_draining
            {
                if self.platform.kind == crate::platform::HostPlatformKind::Android
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
            let source_label = if run.is_some_and(|r| r.source == "microphone") {
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
