use super::*;
use crate::{microphone::Phase, speech::DictationSource};
use koe_engine::domain::UtteranceSegment;
use serde::Serialize;

#[derive(Serialize)]
#[serde(tag = "kind", content = "id", rename_all = "snake_case")]
pub(super) enum LiveMinutesScope {
    BeanStarting,
    Record(String),
    AllDay(String),
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum CapturePhase {
    Starting,
    Recording,
    Paused,
    Finishing,
    Ended,
}

impl From<&Phase> for CapturePhase {
    fn from(phase: &Phase) -> Self {
        match phase {
            Phase::Starting => Self::Starting,
            Phase::Recording | Phase::Pausing => Self::Recording,
            Phase::Paused => Self::Paused,
            Phase::Stopping | Phase::CapacityReached | Phase::Cancelling | Phase::Saving => {
                Self::Finishing
            }
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "snake_case")]
enum MinutesState {
    Unconfigured,
    AfterStop,
    AwaitingTranscript,
    Waiting,
    Queued,
    Summarizing,
    Ready,
    Stale,
    Failed,
    Interrupted,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct TranscriptLine<'a> {
    id: String,
    text: &'a str,
    original_text: Option<&'a str>,
    is_edited: bool,
    start_ms: u64,
    end_ms: u64,
    timed: bool,
    speaker: Option<&'a str>,
}

impl<'a> From<&'a UtteranceSegment> for TranscriptLine<'a> {
    fn from(line: &'a UtteranceSegment) -> Self {
        Self {
            id: line.id.to_string(),
            text: &line.text,
            original_text: line.original_text.as_deref(),
            is_edited: line.is_edited(),
            start_ms: line.start_ms,
            end_ms: line.end_ms,
            timed: line.end_ms > line.start_ms,
            speaker: line.speaker.as_deref(),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct SourceView<'a> {
    record_id: &'a str,
    segment_id: String,
    title: String,
    quote: String,
    start_ms: u64,
}

#[derive(Serialize)]
pub(super) struct SummarySection<'a> {
    pub title: &'a str,
    pub text: &'a str,
    pub sources: Vec<SourceView<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveMinutesPart<'a> {
    record_id: &'a str,
    title: &'a str,
    ordinal: Option<u64>,
    segments: Vec<TranscriptLine<'a>>,
    drafts: Vec<&'a str>,
    summary: Vec<SummarySection<'a>>,
    analysis: MinutesState,
    minutes_stale: bool,
    error: Option<&'a str>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(super) struct LiveMinutesView<'a> {
    scope: &'a LiveMinutesScope,
    phase: CapturePhase,
    configured: bool,
    parts: Vec<LiveMinutesPart<'a>>,
}

impl KoeRuntime {
    pub(super) fn source_view<'a>(
        &self,
        record_id: &'a str,
        segment_id: SegmentId,
    ) -> Option<SourceView<'a>> {
        let evidence = self
            .workspace()
            .resolve_live_source(&SourceRef {
                record_id: record_id.into(),
                segment_id,
            })
            .ok()?;
        Some(SourceView {
            record_id,
            segment_id: segment_id.to_string(),
            title: evidence.title,
            quote: evidence.quote,
            start_ms: evidence.start_ms,
        })
    }

    pub(super) fn minutes_sections<'a>(
        &self,
        record: &'a ProductRecord,
    ) -> Vec<SummarySection<'a>> {
        let aggregate = &record.aggregate;
        let Some(minutes) = &aggregate.minutes else {
            return Vec::new();
        };
        let sources = |ids: &[SegmentId]| {
            ids.iter()
                .filter_map(|id| self.source_view(&aggregate.recording_id, *id))
                .collect()
        };
        let mut sections = Vec::new();
        if !minutes.overview.is_empty() {
            sections.push(SummarySection {
                title: "摘要",
                text: &minutes.overview,
                sources: vec![],
            });
        }
        sections.extend(minutes.topics.iter().map(|topic| SummarySection {
            title: &topic.title,
            text: &topic.summary,
            sources: sources(&topic.citations),
        }));
        sections.extend(minutes.decisions.iter().map(|decision| SummarySection {
            title: "决定",
            text: &decision.claim,
            sources: sources(&decision.citations),
        }));
        sections
    }

    pub(super) fn live_minutes_view(&self) -> Option<LiveMinutesView<'_>> {
        let scope = self.live_minutes_scope.as_ref()?;
        let mut records: Vec<_> = match scope {
            LiveMinutesScope::BeanStarting => Vec::new(),
            LiveMinutesScope::Record(id) => self.workspace().record(id).into_iter().collect(),
            LiveMinutesScope::AllDay(id) => self
                .workspace()
                .records()
                .values()
                .filter(|r| r.all_day.as_ref().is_some_and(|s| &s.run_id == id))
                .collect(),
        };
        records.retain(|r| r.is_live());
        records.sort_by_key(|r| r.all_day.as_ref().map(|s| s.ordinal));
        let recording = self.live_minutes_recording_phase(scope);
        let phase = recording.unwrap_or_else(|| {
            if records.iter().any(|r| {
                self.capture_speech(r)
                    .is_some_and(|session| !session.terminal)
            }) {
                CapturePhase::Finishing
            } else {
                CapturePhase::Ended
            }
        });
        let configured = self.text_provider_configured();
        let parts = records
            .into_iter()
            .map(|r| {
                self.live_minutes_part(
                    r,
                    configured,
                    matches!(scope, LiveMinutesScope::Record(_))
                        && matches!(
                            phase,
                            CapturePhase::Starting | CapturePhase::Recording | CapturePhase::Paused
                        ),
                )
            })
            .collect();
        Some(LiveMinutesView {
            scope,
            phase,
            configured,
            parts,
        })
    }

    fn live_minutes_recording_phase(&self, scope: &LiveMinutesScope) -> Option<CapturePhase> {
        match scope {
            LiveMinutesScope::BeanStarting => self
                .bean_capture_pending()
                .then(|| self.live_minutes_bean_phase()),
            LiveMinutesScope::Record(id) => {
                if let Some(mic) = self.microphone.as_ref().filter(|mic| mic.owns_id(id)) {
                    Some(CapturePhase::from(&mic.phase))
                } else if self.captures.active.values().any(|active| active == id) {
                    Some(self.live_minutes_bean_phase())
                } else {
                    None
                }
            }
            LiveMinutesScope::AllDay(id) => {
                let run = self.all_day.run.as_ref().filter(|run| &run.id == id)?;
                Some(if run.stopping {
                    CapturePhase::Finishing
                } else if run.source == "bean" {
                    self.live_minutes_bean_phase()
                } else {
                    self.microphone
                        .as_ref()
                        .map_or(CapturePhase::Finishing, |mic| {
                            CapturePhase::from(&mic.phase)
                        })
                })
            }
        }
    }

    fn live_minutes_bean_phase(&self) -> CapturePhase {
        if self.device.awaiting_stop || self.device.session.transfer.quiet_draining {
            CapturePhase::Finishing
        } else if self.captures.active.is_empty() {
            CapturePhase::Starting
        } else {
            CapturePhase::Recording
        }
    }

    fn capture_speech(&self, record: &ProductRecord) -> Option<&speech::SpeechSession> {
        let source = match record.origin {
            RecordOrigin::Microphone => DictationSource::Microphone,
            RecordOrigin::Bean => DictationSource::Bean,
            _ => return None,
        };
        self.captures
            .sessions
            .get(&record.aggregate.recording_id)
            .filter(|s| s.capture_source() == Some(source))
    }

    fn live_minutes_part<'a>(
        &'a self,
        record: &'a ProductRecord,
        configured: bool,
        after_stop: bool,
    ) -> LiveMinutesPart<'a> {
        let id = &record.aggregate.recording_id;
        let (analysis, error) = match &record.analysis {
            AnalysisState::Pending {
                stage: AnalysisStage::Summarizing,
                ..
            } => (MinutesState::Summarizing, None),
            AnalysisState::Failed { message, .. } => (MinutesState::Failed, Some(message.as_str())),
            AnalysisState::Interrupted { .. } => (MinutesState::Interrupted, None),
            _ if record.is_minutes_stale() => (MinutesState::Stale, None),
            _ if record.aggregate.minutes.is_some() => (MinutesState::Ready, None),
            _ if !configured => (MinutesState::Unconfigured, None),
            _ if after_stop => (MinutesState::AfterStop, None),
            _ if self.auto_summarize.contains(id) => (MinutesState::Queued, None),
            AnalysisState::Pending {
                stage: AnalysisStage::Transcribing,
                ..
            } => (MinutesState::AwaitingTranscript, None),
            _ if record.aggregate.spine.is_empty() => (MinutesState::AwaitingTranscript, None),
            _ => (MinutesState::Waiting, None),
        };
        LiveMinutesPart {
            record_id: id,
            title: &record.title,
            ordinal: record.all_day.as_ref().map(|s| s.ordinal),
            segments: record
                .aggregate
                .spine
                .segments()
                .iter()
                .map(TranscriptLine::from)
                .collect(),
            drafts: self
                .capture_speech(record)
                .map_or_else(Vec::new, |s| s.drafts().collect()),
            summary: self.minutes_sections(record),
            analysis,
            minutes_stale: record.is_minutes_stale(),
            error,
        }
    }
}
