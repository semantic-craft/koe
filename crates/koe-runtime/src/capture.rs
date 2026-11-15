use super::*;
use crate::speech::DictationSource;
use koe_engine::session::CaptureEvent;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

#[derive(Default)]
pub(super) struct Captures {
    pub(super) active: BTreeMap<u32, String>,
    pub(super) records_by_file_id: BTreeMap<u32, String>,
    pub(super) sessions: BTreeMap<String, crate::speech::SpeechSession>,
    pub targets: VecDeque<(u32, String)>,
}

fn has_recording_asset(root: &Path, id: &str) -> Result<bool, String> {
    Ok(recording_assets::audio_path(root, id)?.exists()
        || recording_assets::opus_path(root, id)?.exists())
}

impl KoeRuntime {
    pub(super) fn process_capture_events(&mut self, now: u64) -> Result<(), String> {
        while let Some(event) = self.device.captures.front().cloned() {
            match event {
                CaptureEvent::Started { file_id } => {
                    if self.treats_file_as_standby(file_id) {
                        if self.companion.standby_stream_owned
                            || self.companion.pending_standby_stop
                        {
                            self.companion.active_standby_file_id = Some(file_id);
                        }
                        if self.can_own_as_standby_scratch(file_id) {
                            self.mark_standby_scratch_file(file_id)?;
                        }
                        if self.companion.pending_standby_stop {
                            self.companion.pending_standby_stop = false;
                            self.companion.standby_stream_owned = false;
                            self.device.stop_recording();
                        }
                    } else {
                        self.ensure_capture(file_id, now)?;
                    }
                }
                CaptureEvent::Audio { file_id, pcm16 } => {
                    if !self.captures.active.contains_key(&file_id)
                        && self.treats_file_as_standby(file_id)
                    {
                        if self.can_own_as_standby_scratch(file_id) {
                            self.mark_standby_scratch_file(file_id)?;
                        }
                    } else {
                        let id = self.ensure_capture(file_id, now)?;
                        self.feed_speech(&id, &pcm16, Some(DictationSource::Bean))?;
                        if self.all_day_group("bean").is_some()
                            && self.device.session.received_slice_count() as u64 * 20
                                >= crate::all_day::SEGMENT_MS
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
                }
                CaptureEvent::Finished { file_id, saved } => {
                    if self.treats_file_as_standby(file_id) {
                        self.captures.active.remove(&file_id);
                    } else {
                        let id = self.captures.active.remove(&file_id);
                        if let Some(id) = &id {
                            self.finish_speech(id);
                            self.set_source_dictation(DictationSource::Bean, false);
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
                                self.captures.records_by_file_id.remove(&file_id);
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
                                        if matches!(
                                            &self.live_minutes_scope,
                                            Some(crate::live_minutes::LiveMinutesScope::Record(rid))
                                                if rid == &id
                                        ) {
                                            self.live_minutes_scope = None;
                                        }
                                        self.detach_records_from_session(&BTreeSet::from([id]));
                                    }
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
        let group = self.all_day_group("bean");
        let bean_mode = self.bean_capture_mode;
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
        if group.is_none() {
            if bean_mode == Some(command::CaptureMode::Meeting) {
                self.live_minutes_scope =
                    Some(crate::live_minutes::LiveMinutesScope::Record(id.clone()));
                self.selected_live_minutes_record = Some(id.clone());
            } else if bean_mode == Some(command::CaptureMode::QuickNote) {
                self.selected_quick_note_record = Some(id.clone());
            }
        }
        self.captures.active.insert(file_id, id.clone());
        self.captures.records_by_file_id.insert(file_id, id.clone());
        Ok(id)
    }
    pub(super) fn drive_analysis_queue(&mut self) {
        if self.is_quitting()
            || (!self.text_provider_configured() && self.auto_transcribe.is_empty())
        {
            return;
        }
        let _ = self.reclaim_stale_summaries();
        if !self.pending.is_empty() || !self.completed.is_empty() {
            return;
        }
        let summary = self.text_provider_configured() && !self.auto_summarize.is_empty();
        let Some(id) = (if summary {
            self.auto_summarize.first()
        } else {
            self.auto_transcribe.first()
        })
        .cloned() else {
            return;
        };
        if !summary && !self.speech_ready(&self.record_speech_engine(&id)) {
            return;
        }
        let needed = self.workspace().record(&id).is_some_and(|record| {
            record.is_live()
                && if summary {
                    !record.aggregate.spine.is_empty()
                        && (!matches!(record.analysis, AnalysisState::Ready { input_revision } if input_revision == record.content_revision)
                            || record.is_minutes_stale())
                } else {
                    record.aggregate.spine.is_empty()
                        || matches!(record.analysis, AnalysisState::Interrupted { .. })
                }
        });
        let result = if !needed {
            Ok(())
        } else if summary {
            self.try_start_summary(&id)
        } else {
            self.try_start_transcription(&id)
        };
        let started = self.pending.values().any(|work| match work {
            PendingWork::Transcription(key)
            | PendingWork::Summary(key)
            | PendingWork::LiveSummary { key, .. } => key.record_id == id,
            PendingWork::Ask(_) => false,
        });
        if result.is_ok() || result.as_ref().is_err_and(|e| !e.retryable()) || started {
            if summary {
                self.auto_summarize.remove(&id);
            } else {
                self.auto_transcribe.remove(&id);
            }
        }
        if let Err(error) = result {
            self.error = Some(error.message());
        }
    }
}
