use crate::capture::{ActiveCaptureSession, AllDayActiveSource, AllDayRun};
use crate::speech::CaptureOrigin;
use crate::*;

pub(crate) const SEGMENT_MS: u64 = 5 * 60 * 1000;

impl KoeRuntime {
    pub(crate) fn start_all_day(
        &mut self,
        source: &str,
        input_id: String,
        now: u64,
    ) -> Result<(), String> {
        if self.active_capture.all_day_run().is_some() {
            return Err("全天听记已在运行".into());
        }
        match source {
            "microphone" => {
                let session = self.build_microphone_session(input_id, false, None, now)?;
                let id = format!("day-{now}-{}", self.workspace().revision() + 1);
                self.active_capture = ActiveCaptureSession::AllDay {
                    run: AllDayRun {
                        id,
                        stopping: false,
                    },
                    source: AllDayActiveSource::Microphone(Box::new(session)),
                };
            }
            "bean" => {
                self.start_device_recording(now)?;
                let id = format!("day-{now}-{}", self.workspace().revision() + 1);
                self.active_capture = ActiveCaptureSession::AllDay {
                    run: AllDayRun {
                        id,
                        stopping: false,
                    },
                    source: AllDayActiveSource::Bean,
                };
            }
            _ => return Err(format!("请选择 {}或录音豆", self.platform.mic_label())),
        }
        Ok(())
    }

    pub(crate) fn stop_all_day(&mut self) -> Result<(), String> {
        let is_mic = match &mut self.active_capture {
            ActiveCaptureSession::AllDay { run, source } => {
                run.stopping = true;
                !matches!(source, AllDayActiveSource::Bean)
            }
            _ => return Ok(()),
        };
        if is_mic {
            self.stop_microphone(false)?;
        } else {
            self.device.stop_recording();
        }
        Ok(())
    }

    pub(crate) fn all_day_group(&self, origin: CaptureOrigin) -> Option<AllDaySegment> {
        let run = self.active_capture.all_day_run_for(origin)?;
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

    pub(crate) fn reconcile_capture_session(&mut self) -> bool {
        match &mut self.active_capture {
            ActiveCaptureSession::Idle | ActiveCaptureSession::SingleShotMic { .. } => false,
            ActiveCaptureSession::BeanSingleShot { .. } => {
                if !self.bean_capture_pending() {
                    self.active_capture = ActiveCaptureSession::Idle;
                    true
                } else {
                    false
                }
            }
            ActiveCaptureSession::AllDay { .. } => {
                let bean_idle_stop = !self.device.session.device_recording_active
                    && self.captures.active.is_empty()
                    && !self.device.session.pending_realtime_subscribe;
                if let ActiveCaptureSession::AllDay { run, source } = &mut self.active_capture {
                    match source {
                        AllDayActiveSource::DrainingMicrophone => {
                            run.stopping = true;
                        }
                        AllDayActiveSource::Bean if bean_idle_stop => {
                            run.stopping = true;
                        }
                        AllDayActiveSource::Bean | AllDayActiveSource::Microphone(_) => {}
                    }
                }
                let done = match &self.active_capture {
                    ActiveCaptureSession::AllDay { run, source } => {
                        run.stopping
                            && match source {
                                AllDayActiveSource::Microphone(_) => false,
                                AllDayActiveSource::DrainingMicrophone => true,
                                AllDayActiveSource::Bean => !self.bean_capture_pending(),
                            }
                            && self.captures.active.is_empty()
                            && !self.captures.sessions.iter().any(|(id, _)| {
                                self.workspace()
                                    .record(id)
                                    .and_then(|r| r.all_day.as_ref())
                                    .is_some_and(|s| s.run_id == run.id)
                            })
                    }
                    _ => false,
                };
                if done {
                    self.active_capture = ActiveCaptureSession::Idle;
                }
                done
            }
        }
    }
}
