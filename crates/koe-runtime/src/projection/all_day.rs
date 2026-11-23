use crate::{
    capture::{
        live_minutes::SourceView,
        microphone::{MicrophoneStatus, Phase},
        studio::CaptureSelection,
    },
    projection::local_date,
    *,
};
use chrono::NaiveDate;
use std::collections::BTreeSet;

impl KoeRuntime {
    pub(super) fn all_day_dates_and_selection(
        &self,
        now: u64,
        records: &[&ProductRecord],
    ) -> (String, Vec<String>, Option<NaiveDate>) {
        let today = (now > 0).then(|| local_date(now)).flatten();
        let mut date_set: BTreeSet<NaiveDate> = BTreeSet::new();
        if let Some(t) = today {
            date_set.insert(t);
        }
        for rec in records {
            if rec.is_live() && rec.mode == RecordMode::AllDay {
                if let Some(d) = local_date(rec.aggregate.created_at_epoch_sec) {
                    date_set.insert(d);
                }
            }
        }
        if let Some(sel) = &self.selection.selected_all_day_date {
            if let Ok(parsed) = NaiveDate::parse_from_str(sel, "%Y-%m-%d") {
                date_set.insert(parsed);
            }
        }
        let available_dates: Vec<String> = date_set
            .iter()
            .rev()
            .map(|d| d.format("%Y-%m-%d").to_string())
            .collect();
        let selected_date = self
            .selection
            .selected_all_day_date
            .clone()
            .or_else(|| today.map(|d| d.format("%Y-%m-%d").to_string()))
            .or_else(|| available_dates.first().cloned())
            .unwrap_or_else(|| "1970-01-01".to_string());
        let parsed_selected = NaiveDate::parse_from_str(&selected_date, "%Y-%m-%d").ok();
        (selected_date, available_dates, parsed_selected)
    }

    pub(super) fn all_day_workspace_json(
        &self,
        now: u64,
        records: &[&ProductRecord],
        microphone: Option<&MicrophoneStatus<'_>>,
        capture_selection: &CaptureSelection,
    ) -> Value {
        let can_control = !self.is_quitting() && !self.store.requires_reopen();
        let is_active = self.active_capture.all_day_run().is_some();
        let is_paused = is_active
            && self
                .active_capture
                .microphone()
                .is_some_and(|m| m.phase == Phase::Paused);
        let can_pause = can_control
            && is_active
            && self
                .active_capture
                .microphone()
                .is_some_and(|m| m.can_pause());
        let can_resume = can_control && is_paused;
        let source_label = if is_active {
            if self.active_capture.all_day_is_microphone() {
                microphone.map_or_else(|| capture_selection.label.clone(), |m| m.input_label.clone())
            } else {
                self.device
                    .device_name
                    .clone()
                    .unwrap_or_else(|| "Soundcore Work".into())
            }
        } else {
            capture_selection.label.clone()
        };

        let (selected_date, available_dates, parsed_selected) =
            self.all_day_dates_and_selection(now, records);

        let mut day_records: Vec<&ProductRecord> = records
            .iter()
            .copied()
            .filter(|r| {
                r.is_live()
                    && r.mode == RecordMode::AllDay
                    && parsed_selected.is_some()
                    && local_date(r.aggregate.created_at_epoch_sec) == parsed_selected
            })
            .collect();
        day_records.sort_by_key(|r| {
            (
                r.aggregate.created_at_epoch_sec,
                r.all_day.as_ref().map_or(0, |s| s.ordinal),
                r.aggregate.recording_id.as_str(),
            )
        });

        let timeline = build_day_timeline(&day_records);
        let spans: Vec<Value> = timeline
            .spans
            .iter()
            .enumerate()
            .map(|(idx, span)| match span {
                DayTimelineSpan::Event(ev) => json!({
                    "kind": "event",
                    "id": ev.id,
                    "title": ev.title,
                    "startEpochSec": ev.start_epoch_sec,
                    "endEpochSec": ev.end_epoch_sec,
                    "durationMs": ev.duration_ms,
                    "recordIds": ev.record_ids,
                    "primaryRecordId": ev.record_ids.first(),
                    "firstSegment": ev.first_segment.as_ref().and_then(|s| self.source_view(&s.record_id, s.segment_id)),
                    "preview": ev.preview,
                    "summaryPoints": ev.summary_points,
                    "speakers": ev.speakers,
                    "segmentCount": ev.segment_count,
                }),
                DayTimelineSpan::Pause(p) => json!({
                    "kind": "pause",
                    "id": format!("pause-{}-{}-{}", p.record_id, p.start_epoch_sec, idx),
                    "recordId": p.record_id,
                    "startEpochSec": p.start_epoch_sec,
                    "endEpochSec": p.end_epoch_sec,
                    "durationMs": p.duration_ms,
                }),
                DayTimelineSpan::UnrecordedGap(g) => json!({
                    "kind": "unrecorded_gap",
                    "id": format!("gap-{}-{}-{}", g.start_epoch_sec, g.end_epoch_sec, idx),
                    "startEpochSec": g.start_epoch_sec,
                    "endEpochSec": g.end_epoch_sec,
                    "durationMs": g.duration_ms,
                }),
            })
            .collect();

        let day_record_ids: BTreeSet<&str> = day_records
            .iter()
            .map(|r| r.aggregate.recording_id.as_str())
            .collect();

        let mut review_tasks = Vec::new();
        let mut review_memories = Vec::new();
        for item in self.workspace().items().values() {
            if !item
                .sources
                .iter()
                .any(|s| day_record_ids.contains(s.record_id.as_str()))
            {
                continue;
            }
            let Some(val) = self.sourced_item_json(item) else {
                continue;
            };
            if item.kind == ItemKind::Task {
                review_tasks.push(val);
            } else {
                review_memories.push(val);
            }
        }

        let (review_decisions, daily_review) = self.build_daily_review_and_decisions(&day_records);

        json!({
            "isActive": is_active,
            "canStart": can_control && self.can_start_capture_mode(capture_selection),
            "isPaused": is_paused,
            "canPause": can_pause,
            "canResume": can_resume,
            "sourceLabel": source_label,
            "selectedDate": selected_date,
            "availableDates": available_dates,
            "totalRecordedMs": timeline.total_recorded_ms,
            "eventCount": timeline.event_count,
            "pauseCount": timeline.pause_count,
            "gapCount": timeline.gap_count,
            "spans": spans,
            "reviewTasks": review_tasks,
            "reviewMemories": review_memories,
            "reviewDecisions": review_decisions,
            "dailyReview": daily_review,
        })
    }

    fn build_daily_review_and_decisions(
        &self,
        day_records: &[&ProductRecord],
    ) -> (Vec<Value>, Value) {
        let mut review_decisions = Vec::new();
        let mut overviews = Vec::new();
        let mut highlights = Vec::new();
        let mut seen_sources = BTreeSet::new();
        let mut review_sources = Vec::new();

        for rec in day_records {
            if rec.is_minutes_stale() {
                continue;
            }
            let Some(minutes) = &rec.aggregate.minutes else {
                continue;
            };
            let rec_id = rec.aggregate.recording_id.as_str();
            let ov = minutes.overview.trim();
            if !ov.is_empty() && !overviews.iter().any(|existing: &String| existing == ov) {
                overviews.push(ov.to_owned());
            }
            for topic in &minutes.topics {
                let bullet = if topic.summary.trim().is_empty() {
                    topic.title.trim().to_owned()
                } else {
                    format!("{}：{}", topic.title.trim(), topic.summary.trim())
                };
                if !bullet.is_empty() && !highlights.contains(&bullet) {
                    highlights.push(bullet);
                }
                for &sid in &topic.citations {
                    if seen_sources.insert((rec_id, sid)) {
                        if let Some(sv) = self.source_view(rec_id, sid) {
                            review_sources.push(sv);
                        }
                    }
                }
            }
            for (dec_idx, dec) in minutes.decisions.iter().enumerate() {
                let claim = dec.claim.trim();
                if !claim.is_empty() {
                    let dec_sources: Vec<SourceView<'_>> = dec
                        .citations
                        .iter()
                        .filter_map(|sid| self.source_view(rec_id, *sid))
                        .collect();
                    review_decisions.push(json!({
                        "id": format!("decision-{rec_id}-{dec_idx}"),
                        "recordId": rec_id,
                        "text": claim,
                        "sources": dec_sources,
                    }));
                    if !highlights.iter().any(|h| h == claim) {
                        highlights.push(claim.to_owned());
                    }
                }
                for &sid in &dec.citations {
                    if seen_sources.insert((rec_id, sid)) {
                        if let Some(sv) = self.source_view(rec_id, sid) {
                            review_sources.push(sv);
                        }
                    }
                }
            }
        }

        let daily_review = if overviews.is_empty() && highlights.is_empty() {
            Value::Null
        } else {
            let overview = if !overviews.is_empty() {
                overviews.join("；")
            } else {
                highlights[0].clone()
            };
            json!({
                "overview": overview,
                "highlights": highlights,
                "sources": review_sources,
            })
        };

        (review_decisions, daily_review)
    }
}
