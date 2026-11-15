//! Chronological All-Day event grouping, intra-record pause extraction, and unrecorded gaps.

use std::collections::BTreeSet;

use super::{ProductRecord, SourceRef};

/// Minimum gap in seconds between consecutive recordings to surface an explicit unrecorded gap.
pub const MIN_UNRECORDED_GAP_SEC: u64 = 180;

/// Maximum gap in seconds between consecutive slices of the same All-Day run that merge into one event.
pub const ADJOINING_EVENT_MERGE_GAP_SEC: u64 = 90;

/// Minimum jump in milliseconds between consecutive `CaptureSpan`s to surface an intra-record pause.
pub const MIN_INTRA_RECORD_PAUSE_MS: u64 = 1_000;

/// Chronological projection of a single local day's All-Day recordings.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DayTimeline {
    /// Sum of recorded audio duration in milliseconds across all live slices for the day.
    pub total_recorded_ms: u64,
    /// Number of merged semantic event blocks in `spans`.
    pub event_count: usize,
    /// Number of explicit intra-record pause spans in `spans`.
    pub pause_count: usize,
    /// Number of explicit unrecorded gaps (`>= 180s`) in `spans`.
    pub gap_count: usize,
    /// Chronological sequence of events, pauses, and unrecorded gaps.
    pub spans: Vec<DayTimelineSpan>,
}

/// One chronological entry in a [`DayTimeline`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DayTimelineSpan {
    /// One or more merged All-Day slices forming a continuous semantic event.
    Event(DayEventBlock),
    /// An explicit pause measured inside a recording's capture lane timeline.
    Pause(DayPauseSpan),
    /// An unrecorded interval of at least [`MIN_UNRECORDED_GAP_SEC`] between recordings.
    UnrecordedGap(DayUnrecordedGap),
}

/// A semantic event block spanning one or more adjoining All-Day slices.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DayEventBlock {
    /// Stable deterministic block identifier derived from its first recording.
    pub id: String,
    /// User-facing event title derived from custom title, grounded topic, or opening utterance.
    pub title: String,
    /// Event start timestamp in Unix seconds.
    pub start_epoch_sec: u64,
    /// Event end timestamp in Unix seconds.
    pub end_epoch_sec: u64,
    /// Total active recorded duration in milliseconds across merged slices.
    pub duration_ms: u64,
    /// Ordered recording IDs merged into this event block.
    pub record_ids: Vec<String>,
    /// Source reference to the first utterance segment in this event, if any.
    pub first_segment: Option<SourceRef>,
    /// Concise opening utterance preview without fabricated placeholder text.
    pub preview: String,
    /// Grounded summary bullets extracted from non-stale minutes across merged slices.
    pub summary_points: Vec<String>,
    /// Distinct speaker names in first-appearance order across merged slices.
    pub speakers: Vec<String>,
    /// Total utterance segment count across merged slices.
    pub segment_count: usize,
}

/// An explicit intra-record pause extracted from sparse capture-lane spans.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DayPauseSpan {
    /// Recording containing this pause.
    pub record_id: String,
    /// Approximate pause start timestamp in Unix seconds.
    pub start_epoch_sec: u64,
    /// Approximate pause end timestamp in Unix seconds.
    pub end_epoch_sec: u64,
    /// Measured pause duration in milliseconds (`>= MIN_INTRA_RECORD_PAUSE_MS`).
    pub duration_ms: u64,
}

/// An explicit unrecorded interval between two recordings on the same day.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DayUnrecordedGap {
    /// Start of the unrecorded interval in Unix seconds.
    pub start_epoch_sec: u64,
    /// End of the unrecorded interval in Unix seconds.
    pub end_epoch_sec: u64,
    /// Unrecorded interval duration in milliseconds.
    pub duration_ms: u64,
}

struct EventAccumulator<'a> {
    run_id: Option<&'a str>,
    start_epoch_sec: u64,
    end_epoch_sec: u64,
    duration_ms: u64,
    slices: Vec<&'a ProductRecord>,
    pauses: Vec<DayPauseSpan>,
}

/// Builds a truthful chronological [`DayTimeline`] from caller-filtered daily recordings.
#[must_use]
pub fn build_day_timeline(records: &[&ProductRecord]) -> DayTimeline {
    let mut live: Vec<&ProductRecord> = records.iter().copied().filter(|r| r.is_live()).collect();
    if live.is_empty() {
        return DayTimeline::default();
    }
    live.sort_by_key(|r| {
        (
            r.aggregate.created_at_epoch_sec,
            r.all_day.as_ref().map_or(0, |s| s.ordinal),
            r.aggregate.recording_id.as_str(),
        )
    });

    let mut timeline = DayTimeline::default();
    let mut current: Option<EventAccumulator<'_>> = None;

    for record in live {
        let duration_ms = effective_duration_ms(record);
        let start_sec = record.aggregate.created_at_epoch_sec;
        let end_sec = start_sec.saturating_add(duration_ms.div_ceil(1_000));
        let run_id = record.all_day.as_ref().map(|s| s.run_id.as_str());
        let pauses = extract_intra_record_pauses(record);
        timeline.total_recorded_ms = timeline.total_recorded_ms.saturating_add(duration_ms);

        if let Some(acc) = current.as_mut().filter(|acc| {
            acc.run_id.is_some()
                && acc.run_id == run_id
                && acc.pauses.is_empty()
                && start_sec.saturating_sub(acc.end_epoch_sec) <= ADJOINING_EVENT_MERGE_GAP_SEC
        }) {
            acc.end_epoch_sec = acc.end_epoch_sec.max(end_sec);
            acc.duration_ms = acc.duration_ms.saturating_add(duration_ms);
            acc.slices.push(record);
            acc.pauses.extend(pauses);
            continue;
        }

        if let Some(acc) = current.take() {
            let prev_end = acc.end_epoch_sec;
            flush_accumulator(acc, &mut timeline);
            let gap_sec = start_sec.saturating_sub(prev_end);
            if gap_sec >= MIN_UNRECORDED_GAP_SEC {
                timeline.gap_count += 1;
                timeline
                    .spans
                    .push(DayTimelineSpan::UnrecordedGap(DayUnrecordedGap {
                        start_epoch_sec: prev_end,
                        end_epoch_sec: start_sec,
                        duration_ms: gap_sec.saturating_mul(1_000),
                    }));
            }
        }

        current = Some(EventAccumulator {
            run_id,
            start_epoch_sec: start_sec,
            end_epoch_sec: end_sec,
            duration_ms,
            slices: vec![record],
            pauses,
        });
    }

    if let Some(acc) = current {
        flush_accumulator(acc, &mut timeline);
    }
    timeline
}

fn flush_accumulator(acc: EventAccumulator<'_>, timeline: &mut DayTimeline) {
    let first = acc.slices[0];
    let record_ids = acc
        .slices
        .iter()
        .map(|r| r.aggregate.recording_id.clone())
        .collect();
    let first_segment = acc.slices.iter().find_map(|r| {
        r.aggregate.spine.segments().first().map(|seg| SourceRef {
            record_id: r.aggregate.recording_id.clone(),
            segment_id: seg.id,
        })
    });
    let preview = acc
        .slices
        .iter()
        .flat_map(|r| r.aggregate.spine.segments())
        .map(|seg| seg.text.trim())
        .find(|text| !text.is_empty())
        .map(|text| truncate_chars(text, 120))
        .unwrap_or_default();

    let (mut speakers, mut seen_speakers) = (Vec::new(), BTreeSet::new());
    let (mut summary_points, mut seen_points) = (Vec::new(), BTreeSet::new());
    let mut segment_count = 0usize;

    for slice in &acc.slices {
        segment_count += slice.aggregate.spine.len();
        for sp in slice.distinct_speakers() {
            if seen_speakers.insert(sp.name.clone()) {
                speakers.push(sp.name);
            }
        }
        if !slice.is_minutes_stale() {
            if let Some(minutes) = &slice.aggregate.minutes {
                let ov = minutes.overview.trim();
                if !ov.is_empty() && seen_points.insert(ov.to_string()) {
                    summary_points.push(ov.to_string());
                }
                for topic in &minutes.topics {
                    let pt = match (topic.title.trim(), topic.summary.trim()) {
                        (t, s) if !t.is_empty() && !s.is_empty() => format!("{t}：{s}"),
                        (t, "") if !t.is_empty() => t.to_string(),
                        ("", s) if !s.is_empty() => s.to_string(),
                        _ => continue,
                    };
                    if seen_points.insert(pt.clone()) {
                        summary_points.push(pt);
                    }
                }
            }
        }
    }

    timeline.event_count += 1;
    timeline.spans.push(DayTimelineSpan::Event(DayEventBlock {
        id: format!("event-{}", first.aggregate.recording_id),
        title: select_event_title(&acc.slices, first),
        start_epoch_sec: acc.start_epoch_sec,
        end_epoch_sec: acc.end_epoch_sec,
        duration_ms: acc.duration_ms,
        record_ids,
        first_segment,
        preview,
        summary_points,
        speakers,
        segment_count,
    }));
    for pause in acc.pauses {
        timeline.pause_count += 1;
        timeline.spans.push(DayTimelineSpan::Pause(pause));
    }
}

fn effective_duration_ms(record: &ProductRecord) -> u64 {
    if record.aggregate.duration_ms > 0 {
        return record.aggregate.duration_ms;
    }
    record
        .aggregate
        .spine
        .segments()
        .iter()
        .map(|s| s.end_ms)
        .max()
        .unwrap_or(0)
}

fn extract_intra_record_pauses(record: &ProductRecord) -> Vec<DayPauseSpan> {
    let base_sec = record.aggregate.created_at_epoch_sec;
    let (mut seen, mut pauses) = (BTreeSet::new(), Vec::new());
    for lane in &record.capture_lanes {
        let Some(rate) = lane.sample_rate.filter(|&r| r > 0) else {
            continue;
        };
        for pair in lane.timeline.windows(2) {
            let Some(prev_end_ns) = pair[0].end_ns(rate) else {
                continue;
            };
            let gap_ms = pair[1].start_ns.saturating_sub(prev_end_ns) / 1_000_000;
            if gap_ms >= MIN_INTRA_RECORD_PAUSE_MS {
                let start_epoch_sec = base_sec.saturating_add(prev_end_ns / 1_000_000_000);
                let end_epoch_sec = start_epoch_sec.saturating_add(gap_ms.div_ceil(1_000));
                if seen.insert((start_epoch_sec, end_epoch_sec, gap_ms)) {
                    pauses.push(DayPauseSpan {
                        record_id: record.aggregate.recording_id.clone(),
                        start_epoch_sec,
                        end_epoch_sec,
                        duration_ms: gap_ms,
                    });
                }
            }
        }
    }
    pauses.sort_by_key(|p| (p.start_epoch_sec, p.end_epoch_sec));
    pauses
}

fn select_event_title(slices: &[&ProductRecord], fallback: &ProductRecord) -> String {
    if let Some(custom) = slices.iter().map(|r| r.title.trim()).find(|t| !is_generic_title(t)) {
        return custom.to_string();
    }
    for minutes in slices
        .iter()
        .filter(|r| !r.is_minutes_stale())
        .filter_map(|r| r.aggregate.minutes.as_ref())
    {
        if !is_generic_title(&minutes.title) {
            return minutes.title.trim().to_string();
        }
        if let Some(topic) = minutes.topics.iter().map(|t| t.title.trim()).find(|t| !t.is_empty()) {
            return topic.to_string();
        }
    }
    slices
        .iter()
        .flat_map(|r| r.aggregate.spine.segments())
        .filter_map(|seg| seg.text.lines().map(str::trim).find(|l| !l.is_empty()))
        .next()
        .map_or_else(|| fallback.title.clone(), |line| truncate_chars(line, 28))
}

fn is_generic_title(title: &str) -> bool {
    let t = title.trim();
    t.is_empty()
        || t == "录音"
        || t.starts_with("录音 ")
        || t.starts_with("全天听记")
        || t == "Mac 麦克风录音"
        || t == "Mac 双路录音"
}

fn truncate_chars(text: &str, max_chars: usize) -> String {
    let mut chars = text.chars();
    let head: String = chars.by_ref().take(max_chars).collect();
    if chars.next().is_some() {
        format!("{head}…")
    } else {
        head
    }
}
