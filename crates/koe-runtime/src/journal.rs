use super::*;
use crate::{
    capture_studio::CaptureSelection,
    command::{CaptureAction, CaptureMode},
    microphone::{MicrophoneStatus, Phase},
    speech::DictationSource,
};
use serde::Serialize;
use serde_json::json;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ModeEntry<'a> {
    mode: CaptureMode,
    source_label: &'a str,
    available: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ActiveCapture<'a> {
    mode: CaptureMode,
    phase: &'a str,
    source_label: &'a str,
    duration_ms: u64,
    actions: Vec<CaptureAction>,
    dictating: bool,
    error: Option<&'a str>,
    level: Option<f64>,
}

impl KoeRuntime {
    fn capture_dictation_source(&self) -> DictationSource {
        if self.microphone.is_some() {
            DictationSource::Microphone
        } else {
            DictationSource::Bean
        }
    }

    pub(super) fn bean_capture_pending(&self) -> bool {
        self.is_bean_meeting_recording()
            || self.device.session.pending_realtime_subscribe
            || !self.captures.active.is_empty()
            || self.device.finalized.iter().any(|recording| {
                self.captures
                    .records_by_file_id
                    .contains_key(&recording.entry.id)
            })
    }

    fn can_start_dictation_in_all_day(&self) -> bool {
        self.all_day.run.as_ref().is_some_and(|run| {
            !run.stopping
                && if run.source == "microphone" {
                    self.microphone
                        .as_ref()
                        .is_some_and(|mic| mic.phase == Phase::Recording)
                } else {
                    !self.device.awaiting_stop && !self.captures.active.is_empty()
                }
        }) && !self.dictation_active(self.capture_dictation_source())
            && !self.is_quitting()
            && !self.store.requires_reopen()
    }

    pub(super) fn start_capture_mode(&mut self, mode: CaptureMode, now: u64) -> Result<(), String> {
        if mode == CaptureMode::Dictation && self.can_start_dictation_in_all_day() {
            self.set_source_dictation(self.capture_dictation_source(), true);
            return Ok(());
        }
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
            self.dispatch(Command::DeviceStart, now)?;
        } else {
            self.start_microphone(selection.input_id, false, None, now)?;
        }
        if let Some(mic) = &mut self.microphone {
            mic.mode = Some(mode);
        } else if mode != CaptureMode::AllDay {
            self.bean_capture_mode = Some(mode);
        }
        if mode == CaptureMode::Dictation {
            self.set_source_dictation(self.capture_dictation_source(), true);
        }
        if mode == CaptureMode::Meeting {
            self.live_minutes_scope = Some(if let Some(mic) = &self.microphone {
                crate::live_minutes::LiveMinutesScope::Record(mic.record_id().to_owned())
            } else {
                crate::live_minutes::LiveMinutesScope::BeanStarting
            });
            self.go(Location {
                page: Page::LiveMinutes,
                ..Location::default()
            });
        }
        Ok(())
    }

    pub(super) fn reconcile_bean_capture_mode(&mut self) {
        if !self.bean_capture_pending()
            && self.bean_capture_mode.take() == Some(CaptureMode::Dictation)
        {
            self.set_source_dictation(DictationSource::Bean, false);
        }
    }

    pub(super) fn capture_action(
        &mut self,
        action: CaptureAction,
        clock_ns: Option<u64>,
    ) -> Result<(), String> {
        match action {
            CaptureAction::Pause => self.pause_microphone(),
            CaptureAction::Resume => {
                self.resume_microphone(clock_ns.ok_or("缺少恢复录音的采样时钟")?)
            }
            CaptureAction::EndDictation if self.all_day.run.is_some() => {
                self.set_source_dictation(self.capture_dictation_source(), false);
                Ok(())
            }
            CaptureAction::End | CaptureAction::EndDictation => {
                if action == CaptureAction::EndDictation
                    && self
                        .microphone
                        .as_ref()
                        .and_then(|m| m.mode)
                        .or(self.bean_capture_mode)
                        != Some(CaptureMode::Dictation)
                {
                    return Err("没有正在进行的语音输入".into());
                }
                if self.all_day.run.is_some() {
                    self.stop_all_day()
                } else if self.microphone.is_some() {
                    self.stop_microphone(false)
                } else if self.is_bean_meeting_recording() {
                    self.dispatch(Command::DeviceStop, self.last_now_sec)
                } else {
                    Ok(())
                }
            }
            CaptureAction::RetryStop => self.dispatch(Command::DeviceStop, self.last_now_sec),
            CaptureAction::RetrySave => self.save_microphone(),
            CaptureAction::Cancel => self.stop_microphone(true),
        }
    }

    fn can_start_capture_mode(&self, selection: &CaptureSelection) -> bool {
        selection.can_start && self.all_day.run.is_none() && self.bean_capture_mode.is_none()
    }

    pub(super) fn capture_modes_json(&self, selection: &CaptureSelection) -> Value {
        json!([
            CaptureMode::QuickNote,
            CaptureMode::AllDay,
            CaptureMode::Meeting,
            CaptureMode::Dictation,
        ]
        .map(|mode| ModeEntry {
            mode,
            source_label: &selection.label,
            available: self.can_start_capture_mode(selection)
                || (mode == CaptureMode::Dictation && self.can_start_dictation_in_all_day()),
        }))
    }

    pub(super) fn active_capture_json(
        &self,
        microphone: Option<&MicrophoneStatus>,
        live_duration_ms: u64,
    ) -> Value {
        let run = self.all_day.run.as_ref();
        let can_control = !self.is_quitting() && !self.store.requires_reopen();
        let dictating = self.dictation_active(self.capture_dictation_source());
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
                if run.is_some() && dictating {
                    actions.push(CaptureAction::EndDictation);
                }
            }
            return json!(ActiveCapture {
                mode,
                phase: status.phase,
                source_label: &status.input_label,
                duration_ms: status.duration_ms,
                actions,
                dictating,
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
                actions.push(CaptureAction::End);
            }
            if can_control && run.is_some() && dictating {
                actions.push(CaptureAction::EndDictation);
            }
            return json!(ActiveCapture {
                mode,
                phase: if self.device.awaiting_stop
                    || self.device.session.transfer.quiet_draining
                    || run.is_some_and(|r| r.stopping)
                    || !self.is_bean_meeting_recording()
                {
                    "stopping"
                } else if self.captures.active.is_empty() {
                    "starting"
                } else {
                    "recording"
                },
                source_label: if run.is_some_and(|r| r.source == "microphone") {
                    "Mac 麦克风"
                } else {
                    self.device
                        .device_name
                        .as_deref()
                        .unwrap_or("Soundcore Work")
                },
                duration_ms: live_duration_ms,
                actions,
                dictating,
                error: self.drain_error.as_deref(),
                level: None,
            });
        }
        Value::Null
    }
}

pub(super) fn journal_json(now: u64, records: &[&ProductRecord], today_ids: &[&String]) -> Value {
    let summaries: Vec<_> = records
        .iter()
        .filter_map(|record| {
            let aggregate = &record.aggregate;
            if !today_ids.contains(&&aggregate.recording_id) || record.is_minutes_stale() {
                return None;
            }
            let overview = &aggregate.minutes.as_ref()?.overview;
            (!overview.trim().is_empty()).then(
                || json!({"recordId":aggregate.recording_id,"title":record.title,"text":overview}),
            )
        })
        .collect();
    let note_ids: Vec<_> = records
        .iter()
        .filter(|record| record.is_live() && !record.aggregate.spine.is_empty())
        .map(|record| &record.aggregate.recording_id)
        .collect();
    json!({"dateEpochSec":now,"recordIds":today_ids,"summaries":summaries,"noteRecordIds":note_ids})
}
