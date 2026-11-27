pub(crate) mod all_day;
pub(crate) mod audio_policy;
pub(crate) mod flow;
pub(crate) mod live_minutes;
pub(crate) mod microphone;
pub(crate) mod playback;
pub(crate) mod studio;

use crate::command::CaptureMode;
use crate::speech::CaptureOrigin;
use crate::*;
use koe_client_providers::ProviderLane;
use koe_engine::session::CaptureEvent;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

use self::microphone::MicrophoneSession;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SingleShotMode {
    QuickNote,
    Meeting,
}

impl SingleShotMode {
    pub(crate) const fn to_capture_mode(self) -> CaptureMode {
        match self {
            Self::QuickNote => CaptureMode::QuickNote,
            Self::Meeting => CaptureMode::Meeting,
        }
    }

    pub(crate) const fn to_record_mode(self) -> RecordMode {
        self.to_capture_mode().to_record_mode()
    }
}

pub(crate) struct AllDayRun {
    pub id: String,
    pub stopping: bool,
}

pub(crate) enum AllDayActiveSource {
    Bean,
    Microphone(Box<MicrophoneSession>),
    DrainingMicrophone,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum TakenMicSlot {
    SingleShot(Option<SingleShotMode>),
    AllDay,
}

#[derive(Default)]
pub(crate) enum ActiveCaptureSession {
    #[default]
    Idle,
    SingleShotMic {
        session: Box<MicrophoneSession>,
        mode: Option<SingleShotMode>,
    },
    AllDay {
        run: AllDayRun,
        source: AllDayActiveSource,
    },
    BeanSingleShot {
        mode: SingleShotMode,
    },
}

impl ActiveCaptureSession {
    pub(crate) const fn is_idle(&self) -> bool {
        matches!(self, Self::Idle)
    }

    pub(crate) fn microphone(&self) -> Option<&MicrophoneSession> {
        match self {
            Self::SingleShotMic { session, .. }
            | Self::AllDay {
                source: AllDayActiveSource::Microphone(session),
                ..
            } => Some(session),
            Self::Idle
            | Self::BeanSingleShot { .. }
            | Self::AllDay {
                source: AllDayActiveSource::Bean | AllDayActiveSource::DrainingMicrophone,
                ..
            } => None,
        }
    }

    pub(crate) fn microphone_mut(&mut self) -> Option<&mut MicrophoneSession> {
        match self {
            Self::SingleShotMic { session, .. }
            | Self::AllDay {
                source: AllDayActiveSource::Microphone(session),
                ..
            } => Some(session),
            Self::Idle
            | Self::BeanSingleShot { .. }
            | Self::AllDay {
                source: AllDayActiveSource::Bean | AllDayActiveSource::DrainingMicrophone,
                ..
            } => None,
        }
    }

    pub(crate) fn take_microphone(&mut self) -> Option<(MicrophoneSession, TakenMicSlot)> {
        match std::mem::replace(self, Self::Idle) {
            Self::SingleShotMic { session, mode } => Some((*session, TakenMicSlot::SingleShot(mode))),
            Self::AllDay {
                run,
                source: AllDayActiveSource::Microphone(session),
            } => {
                *self = Self::AllDay {
                    run,
                    source: AllDayActiveSource::DrainingMicrophone,
                };
                Some((*session, TakenMicSlot::AllDay))
            }
            other => {
                *self = other;
                None
            }
        }
    }

    pub(crate) fn restore_microphone(&mut self, session: MicrophoneSession, slot: TakenMicSlot) {
        match slot {
            TakenMicSlot::SingleShot(mode) => {
                *self = Self::SingleShotMic {
                    session: Box::new(session),
                    mode,
                };
            }
            TakenMicSlot::AllDay => {
                if let Self::AllDay { source, .. } = self {
                    *source = AllDayActiveSource::Microphone(Box::new(session));
                }
            }
        }
    }

    pub(crate) fn all_day_run(&self) -> Option<&AllDayRun> {
        match self {
            Self::AllDay { run, .. } => Some(run),
            _ => None,
        }
    }

    pub(crate) fn all_day_run_for(&self, origin: CaptureOrigin) -> Option<&AllDayRun> {
        match (self, origin) {
            (
                Self::AllDay {
                    run,
                    source: AllDayActiveSource::Bean,
                },
                CaptureOrigin::Bean,
            )
            | (
                Self::AllDay {
                    run,
                    source:
                        AllDayActiveSource::Microphone(_) | AllDayActiveSource::DrainingMicrophone,
                },
                CaptureOrigin::Microphone,
            ) => Some(run),
            _ => None,
        }
    }

    pub(crate) const fn all_day_is_bean(&self) -> bool {
        matches!(
            self,
            Self::AllDay {
                source: AllDayActiveSource::Bean,
                ..
            }
        )
    }

    pub(crate) const fn all_day_is_microphone(&self) -> bool {
        matches!(
            self,
            Self::AllDay {
                source: AllDayActiveSource::Microphone(_) | AllDayActiveSource::DrainingMicrophone,
                ..
            }
        )
    }

    pub(crate) const fn is_active_all_day_microphone(&self) -> bool {
        matches!(
            self,
            Self::AllDay {
                run,
                source: AllDayActiveSource::Microphone(_),
            } if !run.stopping
        )
    }

    pub(crate) const fn single_shot_mic_mode(&self) -> Option<SingleShotMode> {
        match self {
            Self::SingleShotMic { mode, .. } => *mode,
            _ => None,
        }
    }

    pub(crate) const fn bean_single_shot_mode(&self) -> Option<SingleShotMode> {
        match self {
            Self::BeanSingleShot { mode } => Some(*mode),
            _ => None,
        }
    }

    pub(crate) const fn active_capture_mode_tag(
        &self,
        bean_recording: bool,
    ) -> Option<CaptureMode> {
        match self {
            Self::AllDay { .. } => Some(CaptureMode::AllDay),
            Self::SingleShotMic { mode, .. } => Some(match mode {
                Some(m) => m.to_capture_mode(),
                None => CaptureMode::QuickNote,
            }),
            Self::BeanSingleShot { mode } => Some(mode.to_capture_mode()),
            Self::Idle if bean_recording => Some(CaptureMode::QuickNote),
            Self::Idle => None,
        }
    }

    pub(crate) const fn tag(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::SingleShotMic { .. } => "single_shot_mic",
            Self::AllDay {
                source: AllDayActiveSource::Bean,
                ..
            } => "all_day_bean",
            Self::AllDay {
                source: AllDayActiveSource::Microphone(_),
                ..
            } => "all_day_mic",
            Self::AllDay {
                source: AllDayActiveSource::DrainingMicrophone,
                ..
            } => "all_day_draining_mic",
            Self::BeanSingleShot { .. } => "bean_single_shot",
        }
    }

    pub(crate) const fn state_fingerprint(&self) -> (u8, bool, Option<SingleShotMode>) {
        match self {
            Self::Idle => (0, false, None),
            Self::SingleShotMic { mode, .. } => (1, false, *mode),
            Self::AllDay { run, source } => (
                match source {
                    AllDayActiveSource::Bean => 2,
                    AllDayActiveSource::Microphone(_) => 3,
                    AllDayActiveSource::DrainingMicrophone => 4,
                },
                run.stopping,
                None,
            ),
            Self::BeanSingleShot { mode } => (5, false, Some(*mode)),
        }
    }
}

#[derive(Default)]
pub(crate) struct Captures {
    pub(crate) active: BTreeMap<u32, String>,
    pub(crate) sessions: BTreeMap<String, crate::speech::SpeechSession>,
    pub(crate) targets: VecDeque<(u32, String)>,
}

fn has_recording_asset(root: &Path, id: &str) -> Result<bool, String> {
    Ok(recording_assets::audio_path(root, id)?.exists()
        || recording_assets::opus_path(root, id)?.exists())
}

fn is_free_local_speech_engine(engine: &SpeechEngine) -> bool {
    matches!(
        engine,
        SpeechEngine::AppleSpeech | SpeechEngine::Downloaded(_)
    )
}

fn should_recover_local_transcription(
    record: &ProductRecord,
    configured_engine: &SpeechEngine,
    has_wav_audio: bool,
) -> bool {
    if !record.is_live() || !has_wav_audio {
        return false;
    }
    match &record.analysis {
        AnalysisState::Interrupted { key, stage } => {
            let is_transcription = match stage {
                Some(AnalysisStage::Transcribing) => true,
                Some(AnalysisStage::Summarizing) => false,
                None => {
                    record.aggregate.spine.is_empty()
                        || (record.completed_request().is_none()
                            && key.input_revision < record.content_revision)
                }
            };
            is_transcription
                && is_free_local_speech_engine(crate::speech::record_effective_speech_engine(
                    record,
                    configured_engine,
                ))
        }
        AnalysisState::Idle => {
            is_free_local_speech_engine(configured_engine)
                && record.origin == RecordOrigin::Bean
                && record.aggregate.spine.is_empty()
                && record
                    .speech_engine
                    .as_ref()
                    .is_none_or(is_free_local_speech_engine)
        }
        AnalysisState::Pending { .. }
        | AnalysisState::Ready { .. }
        | AnalysisState::Failed { .. } => false,
    }
}

impl KoeRuntime {
    pub(crate) fn recover_local_captures(&mut self) -> Result<(), String> {
        let ids: Vec<_> = self
            .workspace()
            .records()
            .values()
            .filter(|record| record.is_live())
            .map(|r| r.aggregate.recording_id.clone())
            .collect();
        for id in ids {
            if let Some(duration) =
                koe_client_services::capture_asset::CaptureAsset::recover(&self.root, &id)?
            {
                self.commit(|w| w.finish_capture(&id, duration, &[]))?;
                koe_client_services::capture_asset::CaptureAsset::release_recovered(
                    &self.root, &id,
                )?;
            }
        }
        if !self.env.is_replay_mode() {
            let configured_engine = self
                .workspace()
                .provider_configuration()
                .speech_engine
                .clone();
            let recoverable: Vec<String> = self
                .workspace()
                .records()
                .values()
                .filter(|record| {
                    let has_wav =
                        recording_assets::audio_path(&self.root, &record.aggregate.recording_id)
                            .is_ok_and(|path| path.is_file());
                    should_recover_local_transcription(record, &configured_engine, has_wav)
                })
                .map(|record| record.aggregate.recording_id.clone())
                .collect();
            self.auto_transcribe.extend(recoverable);
        }
        Ok(())
    }

    pub(crate) fn process_capture_events(&mut self, now: u64) -> Result<(), String> {
        while let Some(event) = self.device.captures.front().cloned() {
            match event {
                CaptureEvent::Started { file_id } => {
                    self.ensure_capture(file_id, now)?;
                }
                CaptureEvent::Audio { file_id, pcm16 } => {
                    let id = self.ensure_capture(file_id, now)?;
                    self.feed_speech(&id, &pcm16, Some(CaptureOrigin::Bean))?;
                    if self.all_day_group(CaptureOrigin::Bean).is_some()
                        && self.device.session.received_slice_count() as u64 * 20
                            >= self::all_day::SEGMENT_MS
                    {
                        if let Some(recording) =
                            self.device.session.checkpoint_realtime_segment(now)
                        {
                            self.finish_speech(&id);
                            self.captures.active.remove(&file_id);
                            self.captures.targets.push_back((file_id, id));
                            self.device.finalized.push(recording);
                            self.save_device_recordings(now)?;
                        }
                    }
                }
                CaptureEvent::Finished { file_id, saved } => {
                    let id = self.captures.active.remove(&file_id);
                    if let Some(id) = &id {
                        self.finish_speech(id);
                    }
                    if saved {
                        if let Some(id) = id {
                            self.captures.targets.push_back((file_id, id));
                        }
                    } else {
                        let salvageable_from_catalog = id.as_ref().is_some_and(|rid| {
                            self.device.is_connected()
                                && self
                                    .workspace()
                                    .record(rid)
                                    .is_some_and(|r| r.all_day.is_none())
                                && self.device.session.catalog.iter().any(|e| {
                                    e.file_id == file_id
                                        && e.has_duration()
                                        && e.end_time != Some(0)
                                })
                        });
                        if !salvageable_from_catalog {
                            if let Some(id) = id {
                                if !self.captures.sessions.contains_key(&id)
                                    && !has_recording_asset(&self.root, &id).unwrap_or(true)
                                    && self.workspace().record(&id).is_some_and(|r| {
                                        r.aggregate.duration_ms == 0
                                            && r.aggregate.spine.is_empty()
                                    })
                                {
                                    let now_ms = now.max(1).saturating_mul(1000);
                                    self.commit(|w| {
                                        let was_purged = w.is_bean_file_purged(file_id);
                                        w.trash_record(&id, now_ms)?;
                                        let _ = w.purge_record(&id)?;
                                        if !was_purged {
                                            w.clear_purged_bean_file_id(file_id);
                                        }
                                        Ok(())
                                    })?;
                                    self.detach_records_from_session(&BTreeSet::from([id]));
                                }
                            }
                        }
                    }
                }
            }
            self.device.captures.pop_front();
        }
        Ok(())
    }
    fn ensure_capture(&mut self, file_id: u32, now: u64) -> Result<String, String> {
        if let Some(id) = self.captures.active.get(&file_id) {
            return Ok(id.clone());
        }
        let id = format!("live-{file_id}-{now}-{}", self.workspace().revision() + 1);
        let group = self.all_day_group(CaptureOrigin::Bean);
        let bean_mode = self.active_capture.bean_single_shot_mode();
        self.commit(|w| {
            w.insert_record(
                id.clone(),
                format!("录音 {file_id}"),
                RecordOrigin::Bean,
                file_id,
                now,
                0,
            )?;
            if let Some(group) = &group {
                w.group_all_day(&id, group.clone())?;
            } else if let Some(cm) = bean_mode {
                w.set_record_mode(&id, cm.to_record_mode())?;
            }
            Ok(())
        })?;
        if group.is_none() && bean_mode == Some(SingleShotMode::QuickNote) {
            self.selection.selected_quick_note_record = Some(id.clone());
        } else if group.is_none() && bean_mode == Some(SingleShotMode::Meeting) {
            self.selection.selected_live_minutes_record = Some(id.clone());
        }
        self.captures.active.insert(file_id, id.clone());
        Ok(id)
    }
    pub(crate) fn drive_analysis_queue(&mut self) {
        if self.is_quitting() || self.env.is_replay_mode() {
            return;
        }
        let _ = self.reclaim_stale_summaries();
        if self.text_provider_configured() && !self.has_pending_in_lane(ProviderLane::Summary) {
            if let Some(id) = self.auto_summarize.first().cloned() {
                self.drive_next_auto_item(&id, true);
            }
        }
        if !self.auto_transcribe.is_empty() {
            let next_id = self
                .auto_transcribe
                .iter()
                .find(|id| {
                    let engine = self.record_speech_engine(id);
                    if engine == SpeechEngine::Cloud {
                        !self.has_pending_in_lane(ProviderLane::Audio)
                    } else {
                        self.can_admit_local_file_speech(&engine)
                    }
                })
                .cloned();
            if let Some(id) = next_id {
                self.drive_next_auto_item(&id, false);
            }
        }
    }

    fn drive_next_auto_item(&mut self, id: &str, summary: bool) {
        let needed = self.workspace().record(id).is_some_and(|record| {
            record.is_live()
                && if summary {
                    !record.aggregate.spine.is_empty()
                        && (!matches!(record.analysis, AnalysisState::Ready { input_revision } if input_revision == record.content_revision)
                            || record.is_minutes_stale())
                } else {
                    record.aggregate.spine.is_empty()
                        || matches!(
                            record.analysis,
                            AnalysisState::Interrupted {
                                stage: None | Some(AnalysisStage::Transcribing),
                                ..
                            }
                        )
                }
        });
        let result = if !needed {
            Ok(())
        } else if summary {
            self.try_start_summary(id)
        } else {
            self.try_start_transcription(id)
        };
        let started = self.pending.values().any(|work| match work {
            PendingWork::Transcription(key)
            | PendingWork::Summary(key)
            | PendingWork::LiveSummary { key, .. } => key.record_id == id,
            PendingWork::Ask(_) => false,
        });
        if result.is_ok() || result.as_ref().is_err_and(|e| !e.retryable()) || started {
            if summary {
                self.auto_summarize.remove(id);
            } else {
                self.auto_transcribe.remove(id);
            }
        }
        if let Err(error) = result {
            self.set_error(error.message());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn active_capture_session_enforces_single_source_exclusivity_and_slot_roundtrip() {
        let dir = std::env::temp_dir().join(format!(
            "koe-active-capture-exclusivity-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let mut runtime = KoeRuntime::open(&dir).unwrap();
        let now = 1_800_000_000;

        runtime.start_all_day("microphone", String::new(), now).unwrap();
        assert!(runtime.active_capture.all_day_is_microphone());
        assert!(!runtime.active_capture.all_day_is_bean());
        assert!(runtime.active_capture.microphone().is_some());
        assert!(runtime.start_device_recording(now).is_err());

        let (session, slot) = runtime
            .active_capture
            .take_microphone()
            .expect("all-day microphone session");
        assert_eq!(slot, TakenMicSlot::AllDay);
        assert!(runtime.active_capture.microphone().is_none());
        assert!(runtime.active_capture.all_day_is_microphone());
        assert!(runtime
            .active_capture
            .all_day_run_for(CaptureOrigin::Microphone)
            .is_some());

        runtime.active_capture.restore_microphone(session, slot);
        assert!(runtime.active_capture.microphone().is_some());
        assert!(runtime.active_capture.is_active_all_day_microphone());

        drop(runtime);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
