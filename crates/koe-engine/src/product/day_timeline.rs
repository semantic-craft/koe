use std::collections::BTreeSet;

use crate::domain::UtteranceSegment;

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

impl DayTimelineSpan {
    /// Inclusive start timestamp of this timeline entry in Unix seconds.
    #[must_use]
    pub const fn start_epoch_sec(&self) -> u64 {
        match self {
            Self::Event(e) => e.start_epoch_sec,
            Self::Pause(p) => p.start_epoch_sec,
            Self::UnrecordedGap(g) => g.start_epoch_sec,
        }
    }

    /// Exclusive/inclusive end timestamp of this timeline entry in Unix seconds.
    #[must_use]
    pub const fn end_epoch_sec(&self) -> u64 {
        match self {
            Self::Event(e) => e.end_epoch_sec,
            Self::Pause(p) => p.end_epoch_sec,
            Self::UnrecordedGap(g) => g.end_epoch_sec,
        }
    }
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

struct SliceEntry<'a> {
    record: &'a ProductRecord,
    start_sec: u64,
    end_sec: u64,
}

struct EventAccumulator<'a> {
    run_id: Option<&'a str>,
    start_epoch_sec: u64,
    end_epoch_sec: u64,
    duration_ms: u64,
    slices: Vec<SliceEntry<'a>>,
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
        let active_ms = effective_duration_ms(record);
        let wall_ms = wall_clock_duration_ms(record, active_ms);
        let start_sec = record.aggregate.created_at_epoch_sec;
        let end_sec = start_sec.saturating_add(wall_ms.div_ceil(1_000));
        let run_id = record.all_day.as_ref().map(|s| s.run_id.as_str());
        let pauses = extract_intra_record_pauses(record, end_sec);
        timeline.total_recorded_ms = timeline.total_recorded_ms.saturating_add(active_ms);

        if let Some(acc) = current.as_mut().filter(|acc| {
            acc.run_id.is_some()
                && acc.run_id == run_id
                && start_sec.saturating_sub(acc.end_epoch_sec) <= ADJOINING_EVENT_MERGE_GAP_SEC
        }) {
            acc.end_epoch_sec = acc.end_epoch_sec.max(end_sec);
            acc.duration_ms = acc.duration_ms.saturating_add(active_ms);
            acc.slices.push(SliceEntry {
                record,
                start_sec,
                end_sec,
            });
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
            duration_ms: active_ms,
            slices: vec![SliceEntry {
                record,
                start_sec,
                end_sec,
            }],
            pauses,
        });
    }

    if let Some(acc) = current {
        flush_accumulator(acc, &mut timeline);
    }
    timeline
}

fn flush_accumulator(mut acc: EventAccumulator<'_>, timeline: &mut DayTimeline) {
    if acc.pauses.is_empty() {
        let slice_refs: Vec<&ProductRecord> = acc.slices.iter().map(|s| s.record).collect();
        let all_segs: Vec<(&ProductRecord, &UtteranceSegment)> = slice_refs
            .iter()
            .flat_map(|r| r.aggregate.spine.segments().iter().map(move |seg| (*r, seg)))
            .collect();
        timeline.event_count += 1;
        timeline.spans.push(DayTimelineSpan::Event(build_event_block(
            format!("event-{}", slice_refs[0].aggregate.recording_id),
            acc.start_epoch_sec,
            acc.end_epoch_sec,
            acc.duration_ms,
            &slice_refs,
            &slice_refs,
            &all_segs,
        )));
        return;
    }

    acc.pauses
        .sort_by_key(|p| (p.start_epoch_sec, p.end_epoch_sec));
    let mut merged_pauses: Vec<DayPauseSpan> = Vec::with_capacity(acc.pauses.len());
    for mut p in acc.pauses {
        p.start_epoch_sec = p.start_epoch_sec.clamp(acc.start_epoch_sec, acc.end_epoch_sec);
        p.end_epoch_sec = p.end_epoch_sec.clamp(p.start_epoch_sec, acc.end_epoch_sec);
        if let Some(last) = merged_pauses.last_mut() {
            if p.start_epoch_sec < last.end_epoch_sec {
                last.end_epoch_sec = last.end_epoch_sec.max(p.end_epoch_sec);
                last.duration_ms = last
                    .duration_ms
                    .max(last.end_epoch_sec.saturating_sub(last.start_epoch_sec) * 1_000);
                continue;
            }
        }
        merged_pauses.push(p);
    }

    enum PendingEntry {
        SubEvent(u64, u64),
        Pause(DayPauseSpan),
    }

    let mut entries = Vec::new();
    let mut cursor = acc.start_epoch_sec;
    for pause in merged_pauses {
        if cursor < pause.start_epoch_sec {
            entries.push(PendingEntry::SubEvent(cursor, pause.start_epoch_sec));
        }
        cursor = cursor.max(pause.end_epoch_sec);
        entries.push(PendingEntry::Pause(pause));
    }
    if cursor < acc.end_epoch_sec
        || !entries
            .iter()
            .any(|e| matches!(e, PendingEntry::SubEvent(_, _)))
    {
        let start = cursor.min(acc.end_epoch_sec);
        entries.push(PendingEntry::SubEvent(start, acc.end_epoch_sec));
    }

    let sub_intervals: Vec<(u64, u64)> = entries
        .iter()
        .filter_map(|e| match e {
            PendingEntry::SubEvent(s, end) => Some((*s, *end)),
            PendingEntry::Pause(_) => None,
        })
        .collect();
    let total_sub_sec: u64 = sub_intervals
        .iter()
        .map(|(s, e)| e.saturating_sub(*s).max(1))
        .sum::<u64>()
        .max(1);

    let all_timed_segs: Vec<(&ProductRecord, &UtteranceSegment, u64)> = acc
        .slices
        .iter()
        .flat_map(|s| {
            s.record
                .aggregate
                .spine
                .segments()
                .iter()
                .map(move |seg| (s.record, seg, segment_wall_epoch_sec(s.record, seg)))
        })
        .collect();
    let mut consumed_segs: BTreeSet<(&str, crate::domain::SegmentId)> = BTreeSet::new();
    let mut summarized_slices: BTreeSet<&str> = BTreeSet::new();
    let first_record = acc.slices[0].record;
    let mut remaining_ms = acc.duration_ms;
    let mut sub_idx = 0usize;

    for entry in entries {
        match entry {
            PendingEntry::Pause(pause) => {
                timeline.pause_count += 1;
                timeline.spans.push(DayTimelineSpan::Pause(pause));
            }
            PendingEntry::SubEvent(sub_start, sub_end) => {
                let is_last = sub_idx + 1 == sub_intervals.len();
                let sub_dur_ms = if is_last {
                    remaining_ms
                } else {
                    let share = acc
                        .duration_ms
                        .saturating_mul(sub_end.saturating_sub(sub_start).max(1))
                        / total_sub_sec;
                    let bounded = share.min(remaining_ms);
                    remaining_ms = remaining_ms.saturating_sub(bounded);
                    bounded
                };

                let mut sub_slices: Vec<&ProductRecord> = acc
                    .slices
                    .iter()
                    .filter(|s| s.start_sec <= sub_end && s.end_sec >= sub_start)
                    .map(|s| s.record)
                    .collect();
                if sub_slices.is_empty() {
                    sub_slices.push(first_record);
                }

                let mut summary_slices = Vec::new();
                for &rec in &sub_slices {
                    if summarized_slices.insert(rec.aggregate.recording_id.as_str()) {
                        summary_slices.push(rec);
                    }
                }

                let mut sub_segs = Vec::new();
                for &(rec, seg, wall_sec) in &all_timed_segs {
                    let key = (rec.aggregate.recording_id.as_str(), seg.id);
                    if consumed_segs.contains(&key) {
                        continue;
                    }
                    if is_last || wall_sec < sub_end {
                        consumed_segs.insert(key);
                        sub_segs.push((rec, seg));
                    }
                }

                let block_id = if sub_idx == 0 {
                    format!("event-{}", first_record.aggregate.recording_id)
                } else {
                    format!("event-{}-{}", first_record.aggregate.recording_id, sub_idx + 1)
                };
                timeline.event_count += 1;
                timeline.spans.push(DayTimelineSpan::Event(build_event_block(
                    block_id,
                    sub_start,
                    sub_end,
                    sub_dur_ms,
                    &sub_slices,
                    &summary_slices,
                    &sub_segs,
                )));
                sub_idx += 1;
            }
        }
    }
}

fn build_event_block(
    id: String,
    start_epoch_sec: u64,
    end_epoch_sec: u64,
    duration_ms: u64,
    slices: &[&ProductRecord],
    summary_slices: &[&ProductRecord],
    segments: &[(&ProductRecord, &UtteranceSegment)],
) -> DayEventBlock {
    let fallback = slices[0];
    let record_ids = slices
        .iter()
        .map(|r| r.aggregate.recording_id.clone())
        .collect();
    let first_segment = segments.first().map(|(rec, seg)| SourceRef {
        record_id: rec.aggregate.recording_id.clone(),
        segment_id: seg.id,
    });
    let preview = segments
        .iter()
        .map(|(_, seg)| seg.text.trim())
        .find(|text| !text.is_empty())
        .map(|text| truncate_chars(text, 120))
        .unwrap_or_default();

    let (mut speakers, mut seen_speakers) = (Vec::new(), BTreeSet::new());
    for (_, seg) in segments {
        if let Some(sp) = seg.speaker.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            if seen_speakers.insert(sp.to_string()) {
                speakers.push(sp.to_string());
            }
        }
    }

    let (mut summary_points, mut seen_points) = (Vec::new(), BTreeSet::new());
    for slice in summary_slices {
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

    DayEventBlock {
        id,
        title: select_event_title(slices, summary_slices, segments, fallback),
        start_epoch_sec,
        end_epoch_sec,
        duration_ms,
        record_ids,
        first_segment,
        preview,
        summary_points,
        speakers,
        segment_count: segments.len(),
    }
}

pub(super) fn segment_wall_epoch_sec(record: &ProductRecord, segment: &UtteranceSegment) -> u64 {
    let base_sec = record.aggregate.created_at_epoch_sec;
    for lane in &record.capture_lanes {
        let Some(rate) = lane.sample_rate.filter(|&r| r > 0) else {
            continue;
        };
        if lane.timeline.is_empty() {
            continue;
        }
        let target_sample = segment.start_ms.saturating_mul(u64::from(rate)) / 1_000;
        let Some(span) = lane
            .timeline
            .iter()
            .find(|s| target_sample < s.sample_offset.saturating_add(s.sample_count))
            .or_else(|| lane.timeline.last())
        else {
            continue;
        };
        let delta_samples = target_sample
            .saturating_sub(span.sample_offset)
            .min(span.sample_count);
        let wall_ns = span
            .start_ns
            .saturating_add(delta_samples.saturating_mul(1_000_000_000) / u64::from(rate));
        return base_sec.saturating_add(wall_ns / 1_000_000_000);
    }
    base_sec.saturating_add(segment.start_ms / 1_000)
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

fn wall_clock_duration_ms(record: &ProductRecord, active_duration_ms: u64) -> u64 {
    let lane_elapsed_ms = record
        .capture_lanes
        .iter()
        .filter_map(|lane| {
            let rate = lane.sample_rate.filter(|&r| r > 0)?;
            let end_ns = lane.timeline.last()?.end_ns(rate)?;
            Some(end_ns.div_ceil(1_000_000))
        })
        .max()
        .unwrap_or(0);
    active_duration_ms.max(lane_elapsed_ms)
}

fn extract_intra_record_pauses(record: &ProductRecord, record_end_sec: u64) -> Vec<DayPauseSpan> {
    let base_sec = record.aggregate.created_at_epoch_sec;
    let min_pause_ns = MIN_INTRA_RECORD_PAUSE_MS.saturating_mul(1_000_000);
    let mut raw_intervals: Vec<(u64, u64)> = Vec::new();
    for lane in &record.capture_lanes {
        let Some(rate) = lane.sample_rate.filter(|&r| r > 0) else {
            continue;
        };
        for pair in lane.timeline.windows(2) {
            let Some(prev_end_ns) = pair[0].end_ns(rate) else {
                continue;
            };
            let next_start_ns = pair[1].start_ns;
            if next_start_ns.saturating_sub(prev_end_ns) >= min_pause_ns {
                raw_intervals.push((prev_end_ns, next_start_ns));
            }
        }
    }
    if raw_intervals.is_empty() {
        return Vec::new();
    }
    raw_intervals.sort_unstable();
    let mut merged_ns: Vec<(u64, u64)> = Vec::with_capacity(raw_intervals.len());
    for (start_ns, end_ns) in raw_intervals {
        if let Some(cur) = merged_ns.last_mut() {
            if start_ns <= cur.1 {
                cur.1 = cur.1.max(end_ns);
                continue;
            }
        }
        merged_ns.push((start_ns, end_ns));
    }

    merged_ns
        .into_iter()
        .filter_map(|(start_ns, end_ns)| {
            let duration_ms = end_ns.saturating_sub(start_ns) / 1_000_000;
            if duration_ms < MIN_INTRA_RECORD_PAUSE_MS {
                return None;
            }
            let start_epoch_sec = base_sec
                .saturating_add(start_ns / 1_000_000_000)
                .min(record_end_sec);
            let rounded_end_offset_sec = end_ns.saturating_add(500_000_000) / 1_000_000_000;
            let end_epoch_sec = base_sec
                .saturating_add(rounded_end_offset_sec)
                .max(start_epoch_sec.saturating_add(1))
                .min(record_end_sec)
                .max(start_epoch_sec);
            Some(DayPauseSpan {
                record_id: record.aggregate.recording_id.clone(),
                start_epoch_sec,
                end_epoch_sec,
                duration_ms,
            })
        })
        .collect()
}

fn select_event_title(
    slices: &[&ProductRecord],
    summary_slices: &[&ProductRecord],
    segments: &[(&ProductRecord, &UtteranceSegment)],
    fallback: &ProductRecord,
) -> String {
    if let Some(custom) = summary_slices
        .iter()
        .map(|r| r.title.trim())
        .find(|t| !is_generic_title(t))
    {
        return custom.to_string();
    }
    for minutes in summary_slices
        .iter()
        .filter(|r| !r.is_minutes_stale())
        .filter_map(|r| r.aggregate.minutes.as_ref())
    {
        if !is_generic_title(&minutes.title) {
            return minutes.title.trim().to_string();
        }
        if let Some(topic) = minutes
            .topics
            .iter()
            .map(|t| t.title.trim())
            .find(|t| !t.is_empty())
        {
            return topic.to_string();
        }
    }
    if let Some(line) = segments
        .iter()
        .filter_map(|(_, seg)| seg.text.lines().map(str::trim).find(|l| !l.is_empty()))
        .next()
    {
        return truncate_chars(line, 28);
    }
    if let Some(custom) = slices
        .iter()
        .map(|r| r.title.trim())
        .find(|t| !is_generic_title(t))
    {
        return custom.to_string();
    }
    fallback.title.clone()
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
