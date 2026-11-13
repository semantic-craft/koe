use super::*;
use serde_json::json;

pub(super) const SEGMENT_MS: u64 = 5 * 60 * 1000;
pub(super) struct AllDayRun {
    pub id: String,
    pub source: String,
    pub stopping: bool,
}
#[derive(Default)]
pub(super) struct AllDayState {
    pub run: Option<AllDayRun>,
}
impl KoeRuntime {
    pub(super) fn start_all_day(
        &mut self,
        source: &str,
        input_id: String,
        now: u64,
    ) -> Result<(), String> {
        if self.all_day.run.is_some() {
            return Err("全天听记已在运行".into());
        }
        match source {
            "microphone" => self.start_microphone(input_id, false, None, now)?,
            "bean" => {
                if self.microphone.is_some() {
                    return Err("请先结束 Mac 录音".into());
                }
                if !self.device.is_connected() {
                    return Err("请先连接录音豆".into());
                }
                self.ensure_device_idle()?;
                let outcome = self.device.session.start_realtime_recording_with_options(
                    None,
                    now.saturating_mul(1000),
                    false,
                );
                self.device.accept(outcome);
            }
            _ => return Err("请选择 Mac 麦克风或录音豆".into()),
        }
        let id = format!("day-{now}-{}", self.workspace().revision() + 1);
        self.live_minutes_scope = Some(crate::live_minutes::LiveMinutesScope::AllDay(id.clone()));
        self.all_day.run = Some(AllDayRun {
            id,
            source: source.into(),
            stopping: false,
        });
        Ok(())
    }
    pub(super) fn stop_all_day(&mut self) -> Result<(), String> {
        let Some(run) = &mut self.all_day.run else {
            return Ok(());
        };
        run.stopping = true;
        if run.source == "microphone" {
            self.stop_microphone(false)?;
        } else {
            self.device.stop_recording();
        }
        Ok(())
    }
    pub(super) fn all_day_group(&self, source: &str) -> Option<AllDaySegment> {
        let run = self.all_day.run.as_ref().filter(|r| r.source == source)?;
        let ordinal = self
            .workspace()
            .records()
            .values()
            .filter_map(|r| r.all_day.as_ref())
            .filter(|s| s.run_id == run.id)
            .map(|s| s.ordinal)
            .max()
            .unwrap_or(0)
            + 1;
        Some(AllDaySegment {
            run_id: run.id.clone(),
            ordinal,
        })
    }
    pub(super) fn all_day_json(
        &self,
        mic: Option<&crate::microphone::MicrophoneStatus<'_>>,
    ) -> Value {
        let Some(run) = &self.all_day.run else {
            return json!({"state":"idle","source":null,"runId":null,"segmentCount":0,"message":null});
        };
        let count = self
            .workspace()
            .records()
            .values()
            .filter(|r| r.all_day.as_ref().is_some_and(|s| s.run_id == run.id))
            .count();
        let failure = self
            .microphone
            .as_ref()
            .and_then(|m| m.save_error.clone())
            .or_else(|| mic.and_then(|m| m.interruption).map(str::to_owned))
            .or_else(|| self.drain_error.clone());
        let stopping = run.stopping
            || (run.source == "microphone"
                && !mic.is_some_and(|m| {
                    matches!(m.phase, "starting" | "recording" | "paused" | "pausing")
                }));
        json!({"state":if stopping{"finishing"}else{"recording"},"source":run.source,"runId":run.id,"segmentCount":count,"message":failure.or_else(||stopping.then(||"正在保存最后一段".into()))})
    }
    pub(super) fn reconcile_all_day(&mut self) -> bool {
        if let Some(run) = &mut self.all_day.run {
            if run.source == "microphone" && self.microphone.is_none() {
                run.stopping = true;
            }
            if run.source == "bean"
                && !self.device.session.device_recording_active
                && self.captures.active.is_empty()
                && !self.device.session.pending_realtime_subscribe
            {
                run.stopping = true;
            }
        }
        let done = self.all_day.run.as_ref().is_some_and(|run| {
            run.stopping
                && self.microphone.is_none()
                && (run.source != "bean" || !self.bean_capture_pending())
                && self.captures.active.is_empty()
                && !self.captures.sessions.iter().any(|(id, _)| {
                    self.workspace()
                        .record(id)
                        .and_then(|r| r.all_day.as_ref())
                        .is_some_and(|s| s.run_id == run.id)
                })
        });
        if done
            && self
                .all_day
                .run
                .take()
                .is_some_and(|run| run.source == "bean")
        {
            self.set_source_dictation(crate::speech::DictationSource::Bean, false);
        }
        done
    }
}
