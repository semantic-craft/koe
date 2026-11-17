use super::*;

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
            "microphone" => {
                self.start_microphone(input_id, false, None, now)?;
            }
            "bean" => {
                self.start_device_recording(now)?;
            }
            _ => return Err("请选择 Mac 麦克风或录音豆".into()),
        }
        let id = format!("day-{now}-{}", self.workspace().revision() + 1);
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
        if done {
            self.all_day.run = None;
        }
        done
    }
}
