use super::*;
use crate::speech::CaptureOrigin;
use koe_client_providers::ProviderLane;
use koe_engine::domain::UtteranceSegment;
use serde::Serialize;

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

    pub(super) fn capture_speech(&self, record: &ProductRecord) -> Option<&speech::SpeechSession> {
        let source = match record.origin {
            RecordOrigin::Microphone => CaptureOrigin::Microphone,
            RecordOrigin::Bean => CaptureOrigin::Bean,
            _ => return None,
        };
        self.captures
            .sessions
            .get(&record.aggregate.recording_id)
            .filter(|s| s.capture_source() == Some(source))
    }
}

#[derive(Default)]
pub(super) struct LiveMinutesSchedule {
    elapsed_ms: u64,
    first_final_at: Option<u64>,
    last_request_at: Option<u64>,
    requested_revision: u64,
}

impl LiveMinutesSchedule {
    pub(super) fn observe_final(&mut self) {
        self.first_final_at.get_or_insert(self.elapsed_ms);
    }

    fn ready(&self, revision: u64, segments: usize) -> bool {
        if revision <= self.requested_revision || segments == 0 {
            return false;
        }
        match self.last_request_at {
            Some(last) => self.elapsed_ms.saturating_sub(last) >= 45_000,
            None => {
                segments >= 3
                    || self
                        .first_final_at
                        .is_some_and(|first| self.elapsed_ms.saturating_sub(first) >= 20_000)
            }
        }
    }

    pub(super) fn requested(&mut self, revision: u64) {
        self.last_request_at = Some(self.elapsed_ms);
        self.requested_revision = revision;
    }
}

impl KoeRuntime {
    pub(super) fn drive_live_minutes(&mut self, elapsed_ms: u64) {
        for session in self.captures.sessions.values_mut() {
            session.minutes_schedule.elapsed_ms = session
                .minutes_schedule
                .elapsed_ms
                .saturating_add(elapsed_ms);
        }
        if self.is_quitting()
            || !self.text_provider_configured()
            || self.has_pending_in_lane(ProviderLane::Summary)
        {
            return;
        }
        let active_all_day_run = self.all_day.run.as_ref().map(|run| run.id.as_str());
        let candidate = self.captures.sessions.iter().find_map(|(id, session)| {
            if session.terminal
                || !matches!(
                    session.capture_source(),
                    Some(CaptureOrigin::Microphone | CaptureOrigin::Bean)
                )
            {
                return None;
            }
            let record = self.workspace().record(id)?;
            let included = record.is_live()
                && (record.mode == RecordMode::Meeting
                    || record.all_day.as_ref().is_some_and(|group| {
                        active_all_day_run == Some(group.run_id.as_str())
                    }));
            if !included {
                return None;
            }
            session
                .minutes_schedule
                .ready(record.content_revision, record.aggregate.spine.len())
                .then(|| id.clone())
        });
        let Some(id) = candidate else {
            return;
        };
        if let Err(error) = self.try_start_live_summary(&id) {
            self.error = Some(error.message());
        }
    }
}
