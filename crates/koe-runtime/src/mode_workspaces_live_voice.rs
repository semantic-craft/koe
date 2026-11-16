use super::*;
use crate::{
    capture_studio::CaptureSelection,
    command::CaptureMode,
    live_minutes::{LiveMinutesScope, TranscriptLine},
    microphone::{MicrophoneStatus, Phase},
    projection::{origin, status},
};

impl KoeRuntime {
    pub(super) fn live_minutes_workspace_json(
        &self,
        records: &[&ProductRecord],
        live_record_id: Option<&str>,
        live_duration_ms: u64,
        microphone: Option<&MicrophoneStatus<'_>>,
        capture_selection: &CaptureSelection,
    ) -> Value {
        let meeting_mic = self
            .microphone
            .as_ref()
            .filter(|m| m.mode == Some(CaptureMode::Meeting));
        let meeting_bean_active =
            self.bean_capture_mode == Some(CaptureMode::Meeting) && self.bean_capture_pending();
        let is_active = meeting_mic.is_some() || meeting_bean_active;

        let active_record_id = if let Some(m) = meeting_mic {
            Some(m.current_record_id().to_owned())
        } else if meeting_bean_active {
            live_record_id
                .map(str::to_owned)
                .or_else(|| match &self.selection.live_minutes_scope {
                    Some(LiveMinutesScope::Record(id)) => Some(id.clone()),
                    _ => None,
                })
        } else {
            None
        };

        let meeting_records: Vec<&ProductRecord> = records
            .iter()
            .copied()
            .filter(|r| r.is_live() && r.mode == RecordMode::Meeting)
            .collect();

        let past_meetings: Vec<Value> = meeting_records
            .iter()
            .filter(|r| Some(r.aggregate.recording_id.as_str()) != active_record_id.as_deref())
            .map(|r| {
                let rec_id = r.aggregate.recording_id.as_str();
                let duration_ms = if Some(rec_id) == live_record_id {
                    r.aggregate.duration_ms.max(live_duration_ms)
                } else {
                    r.aggregate.duration_ms
                };
                json!({
                    "id": rec_id,
                    "title": r.title,
                    "createdAtEpochSec": r.aggregate.created_at_epoch_sec,
                    "durationMs": duration_ms,
                    "source": origin(r.origin),
                    "status": status(r),
                    "segmentCount": r.aggregate.spine.len(),
                    "decisionCount": r.aggregate.minutes.as_ref().map_or(0, |m| m.decisions.len()),
                })
            })
            .collect();

        let selected_record_id = if is_active {
            active_record_id.clone()
        } else {
            self.selection
                .selected_live_minutes_record
                .as_deref()
                .filter(|id| {
                    self.workspace()
                        .record(id)
                        .is_some_and(|r| r.is_live() && r.mode == RecordMode::Meeting)
                })
                .map(str::to_owned)
                .or_else(|| {
                    meeting_records
                        .first()
                        .map(|r| r.aggregate.recording_id.clone())
                })
        };

        let selected_record = selected_record_id
            .as_deref()
            .and_then(|id| self.workspace().record(id))
            .filter(|r| r.is_live() && r.mode == RecordMode::Meeting);

        let phase = if let Some(m) = meeting_mic {
            match m.phase {
                Phase::Starting => "starting",
                Phase::Recording | Phase::Pausing => "recording",
                Phase::Paused => "paused",
                Phase::Stopping | Phase::CapacityReached | Phase::Cancelling | Phase::Saving => {
                    "finishing"
                }
            }
        } else if meeting_bean_active {
            if self.device.awaiting_stop || self.device.session.transfer.quiet_draining {
                "finishing"
            } else if self.captures.active.is_empty() {
                "starting"
            } else {
                "recording"
            }
        } else if selected_record.is_some_and(|r| {
            self.capture_speech(r)
                .is_some_and(|session| !session.terminal)
        }) {
            "finishing"
        } else if selected_record.is_some() {
            "ended"
        } else {
            "idle"
        };

        let configured = self.text_provider_configured();
        let source_label = if is_active {
            if meeting_mic.is_some() {
                microphone.map_or_else(|| capture_selection.label.clone(), |m| m.input_label.clone())
            } else {
                self.device
                    .device_name
                    .clone()
                    .unwrap_or_else(|| "Soundcore Work".into())
            }
        } else if let Some(r) = selected_record {
            origin(r.origin).to_owned()
        } else {
            capture_selection.label.clone()
        };

        let error = selected_record.and_then(|r| match &r.live_summary {
            AnalysisState::Failed { message, .. } => Some(message.as_str()),
            _ => match &r.analysis {
                AnalysisState::Failed { message, .. } => Some(message.as_str()),
                _ => None,
            },
        });

        let cov_data = selected_record.map(|r| {
            let rec_id = r.aggregate.recording_id.as_str();
            let eff_live_ms = if Some(rec_id) == live_record_id {
                live_duration_ms
            } else if meeting_mic.is_some_and(|m| m.current_record_id() == rec_id) {
                microphone.map_or(0, |m| m.duration_ms)
            } else {
                0
            };
            let rec_active =
                is_active && active_record_id.as_deref() == Some(r.aggregate.recording_id.as_str());
            compute_meeting_coverage(r, eff_live_ms, rec_active)
        });
        let coverage = cov_data.as_ref().map(|cov| {
            json!({
                "audioDurationMs": cov.audio_duration_ms,
                "transcribedDurationMs": cov.transcribed_duration_ms,
                "transcriptPercent": cov.transcript_percent,
                "totalSegments": cov.total_segments,
                "groundedSegments": cov.grounded_segments,
                "minutesPercent": cov.minutes_percent,
                "consolidationStage": cov.consolidation.as_str(),
                "consolidationLabel": cov.consolidation.label_zh(),
            })
        });

        let segments: Vec<_> = selected_record
            .map(|r| {
                r.aggregate
                    .spine
                    .segments()
                    .iter()
                    .map(TranscriptLine::from)
                    .collect()
            })
            .unwrap_or_default();
        let drafts: Vec<&str> = selected_record
            .and_then(|r| self.capture_speech(r))
            .map_or_else(Vec::new, |s| s.drafts().collect());
        let live_sections = selected_record.map_or_else(Vec::new, |r| self.minutes_sections(r));
        let final_sections = if !is_active
            && cov_data
                .as_ref()
                .is_some_and(|cov| cov.consolidation == ConsolidationStage::Ready)
        {
            selected_record.map_or_else(Vec::new, |r| self.minutes_sections(r))
        } else {
            Vec::new()
        };
        let action_items: Vec<Value> = selected_record_id
            .as_deref()
            .map(|id| {
                self.workspace()
                    .items()
                    .values()
                    .filter(|item| item.sources.iter().any(|s| s.record_id == id))
                    .filter_map(|item| self.sourced_item_json(item))
                    .collect()
            })
            .unwrap_or_default();
        let can_summarize = selected_record.is_some_and(|r| {
            !r.aggregate.spine.is_empty()
                && configured
                && !matches!(r.analysis, AnalysisState::Pending { .. })
        });
        let can_start = self.can_start_capture_mode(capture_selection);

        json!({
            "isActive": is_active,
            "canStart": can_start,
            "phase": phase,
            "configured": configured,
            "sourceLabel": source_label,
            "activeRecordId": active_record_id,
            "selectedRecordId": selected_record_id,
            "selectedTitle": selected_record.map(|r| &r.title),
            "minutesStale": selected_record.is_some_and(ProductRecord::is_minutes_stale),
            "canSummarize": can_summarize,
            "error": error,
            "coverage": coverage,
            "segments": segments,
            "drafts": drafts,
            "liveSections": live_sections,
            "finalSections": final_sections,
            "actionItems": action_items,
            "pastMeetings": past_meetings,
        })
    }
}
