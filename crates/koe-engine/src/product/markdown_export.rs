//! Raw-first Markdown export for single recordings and All-Day daily timelines.

use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{SegmentId, UtteranceSegment};

use super::{DayTimeline, DayTimelineSpan, ItemKind, ProductRecord, ReviewState, SourcedItem};

/// Formatting flags for customizable Markdown export.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MarkdownExportOptions {
    /// Whether to emit AI minutes, decisions, and review items after `## 原文`.
    pub include_analysis: bool,
    /// Whether to append `[S1]` citation tags in AI sections.
    pub include_sources: bool,
}

impl Default for MarkdownExportOptions {
    fn default() -> Self {
        Self {
            include_analysis: true,
            include_sources: true,
        }
    }
}

/// Renders a single recording as raw-first Markdown (`## 原文` before `## AI 整理`).
#[must_use]
pub fn format_record_markdown(
    record: &ProductRecord,
    items: &[&SourcedItem],
    options: MarkdownExportOptions,
) -> String {
    let rec_id = record.aggregate.recording_id.as_str();
    let mut out = format!(
        "# {}\n\n- 模式：{}\n",
        sanitize_middle_dots(&record.title),
        record.mode.label_zh()
    );
    if let Some(project) = &record.project {
        out.push_str(&format!("- 项目：{}\n", sanitize_middle_dots(project)));
    }
    out.push_str("\n## 原文\n\n");
    for segment in record.aggregate.spine.segments() {
        append_raw_segment(&mut out, segment);
    }

    if !options.include_analysis {
        return out;
    }

    let matching_items: Vec<&SourcedItem> = items
        .iter()
        .copied()
        .filter(|item| {
            item.review != ReviewState::Dismissed
                && item.sources.iter().any(|src| src.record_id == rec_id)
        })
        .collect();

    if record.aggregate.minutes.is_none() && matching_items.is_empty() {
        return out;
    }

    out.push_str("## AI 整理\n\n");
    if record.aggregate.minutes.is_some() && record.is_minutes_stale() {
        out.push_str("> 注：原文已变更，以下纪要待重新整理。\n\n");
    }

    if let Some(minutes) = &record.aggregate.minutes {
        let overview = clean_ai_text(&minutes.overview, options.include_sources);
        if !overview.is_empty() {
            out.push_str(&format!("{overview}\n\n"));
        }
        for topic in &minutes.topics {
            let cites = format_citations(&topic.citations, options.include_sources);
            let title = clean_ai_text(&topic.title, options.include_sources);
            out.push_str(&format!("### {title}{cites}\n\n"));
            let summary = clean_ai_text(&topic.summary, options.include_sources);
            if !summary.is_empty() {
                out.push_str(&format!("{summary}\n\n"));
            }
            if !topic.points.is_empty() {
                for pt in &topic.points {
                    let pt_cites = format_citations(&pt.citations, options.include_sources);
                    let claim = clean_ai_text(&pt.claim, options.include_sources);
                    out.push_str(&format!("- {claim}{pt_cites}\n"));
                }
                out.push('\n');
            }
        }
        if !minutes.decisions.is_empty() {
            out.push_str("### 决策\n\n");
            for dec in &minutes.decisions {
                let dec_cites = format_citations(&dec.citations, options.include_sources);
                let claim = clean_ai_text(&dec.claim, options.include_sources);
                out.push_str(&format!("- {claim}{dec_cites}\n"));
            }
            out.push('\n');
        }
    }

    if !matching_items.is_empty() {
        out.push_str("### 待办与记忆\n\n");
        for item in matching_items {
            let kind_label = match item.kind {
                ItemKind::Task => "待办",
                ItemKind::Memory => "记忆",
            };
            let item_seg_ids: Vec<SegmentId> = item
                .sources
                .iter()
                .filter(|src| src.record_id == rec_id)
                .map(|src| src.segment_id)
                .collect();
            let cites = format_citations(&item_seg_ids, options.include_sources);
            let text = clean_ai_text(&item.text, options.include_sources);
            out.push_str(&format!("- [{kind_label}] {text}{cites}\n"));
        }
        out.push('\n');
    }

    out
}

/// Renders an All-Day date timeline with raw segments, explicit pauses/gaps, and optional review sections.
#[must_use]
pub fn format_day_markdown(
    date_label: &str,
    timeline: &DayTimeline,
    records: &[&ProductRecord],
    items: &[&SourcedItem],
    options: MarkdownExportOptions,
) -> String {
    let record_by_id: BTreeMap<&str, &ProductRecord> = records
        .iter()
        .copied()
        .filter(|r| r.is_live())
        .map(|r| (r.aggregate.recording_id.as_str(), r))
        .collect();
    let known_ids: BTreeSet<&str> = record_by_id.keys().copied().collect();

    let mut out = format!(
        "# 全天听记 {}\n\n## 原文时间线\n\n",
        sanitize_middle_dots(date_label.trim())
    );

    for span in &timeline.spans {
        match span {
            DayTimelineSpan::Event(event) => {
                out.push_str(&format!("### {}\n\n", sanitize_middle_dots(&event.title)));
                for rid in &event.record_ids {
                    if let Some(rec) = record_by_id.get(rid.as_str()) {
                        for segment in rec.aggregate.spine.segments() {
                            append_raw_segment(&mut out, segment);
                        }
                    }
                }
                if options.include_analysis && !event.summary_points.is_empty() {
                    for pt in &event.summary_points {
                        out.push_str(&format!(
                            "- {}\n",
                            clean_ai_text(pt, options.include_sources)
                        ));
                    }
                    out.push('\n');
                }
            }
            DayTimelineSpan::Pause(pause) => {
                let secs = (pause.duration_ms / 1_000).max(1);
                out.push_str(&format!("- 已暂停（{secs} 秒）\n\n"));
            }
            DayTimelineSpan::UnrecordedGap(gap) => {
                let mins = (gap.duration_ms / 60_000).max(1);
                out.push_str(&format!("- 未录音空档（{mins} 分钟）\n\n"));
            }
        }
    }

    if !options.include_analysis {
        return out;
    }

    let day_items: Vec<&SourcedItem> = items
        .iter()
        .copied()
        .filter(|item| {
            item.review != ReviewState::Dismissed
                && item
                    .sources
                    .iter()
                    .any(|src| known_ids.contains(src.record_id.as_str()))
        })
        .collect();

    let mut decisions: Vec<(&ProductRecord, &crate::domain::MinutePoint)> = Vec::new();
    let mut overviews: Vec<(&ProductRecord, &str)> = Vec::new();
    for rec in records.iter().copied().filter(|r| r.is_live()) {
        if rec.is_minutes_stale() {
            continue;
        }
        if let Some(minutes) = &rec.aggregate.minutes {
            for dec in &minutes.decisions {
                decisions.push((rec, dec));
            }
            let ov = minutes.overview.trim();
            if !ov.is_empty() {
                overviews.push((rec, ov));
            }
        }
    }

    if !day_items.is_empty() || !decisions.is_empty() {
        out.push_str("## 当日行动与记忆\n\n");
        for item in day_items {
            let kind_label = match item.kind {
                ItemKind::Task => "待办",
                ItemKind::Memory => "记忆",
            };
            let segs: Vec<SegmentId> = item
                .sources
                .iter()
                .filter(|src| known_ids.contains(src.record_id.as_str()))
                .map(|src| src.segment_id)
                .collect();
            let cites = format_citations(&segs, options.include_sources);
            let text = clean_ai_text(&item.text, options.include_sources);
            out.push_str(&format!("- [{kind_label}] {text}{cites}\n"));
        }
        for (_, dec) in decisions {
            let cites = format_citations(&dec.citations, options.include_sources);
            let claim = clean_ai_text(&dec.claim, options.include_sources);
            out.push_str(&format!("- [决策] {claim}{cites}\n"));
        }
        out.push('\n');
    }

    if !overviews.is_empty() {
        out.push_str("## 当日回顾\n\n");
        for (rec, ov) in overviews {
            let summary = clean_ai_text(ov, options.include_sources);
            if options.include_sources {
                out.push_str(&format!(
                    "- {}：{summary}\n",
                    sanitize_middle_dots(&rec.title)
                ));
            } else {
                out.push_str(&format!("- {summary}\n"));
            }
        }
        out.push('\n');
    }

    out
}

fn append_raw_segment(out: &mut String, segment: &UtteranceSegment) {
    if let Some(sp) = segment.speaker.as_deref().filter(|s| !s.is_empty()) {
        out.push_str(&format!("[{}] {}：{}\n\n", segment.id, sp, segment.text));
    } else {
        out.push_str(&format!("[{}] {}\n\n", segment.id, segment.text));
    }
}

fn format_citations(citations: &[SegmentId], include_sources: bool) -> String {
    if !include_sources || citations.is_empty() {
        return String::new();
    }
    let mut seen = BTreeSet::new();
    let mut rendered = String::from(" ");
    for &id in citations {
        if seen.insert(id) {
            rendered.push_str(&format!("[{id}]"));
        }
    }
    rendered
}

fn clean_ai_text(raw: &str, include_sources: bool) -> String {
    let base = sanitize_middle_dots(raw.trim());
    if include_sources {
        return base;
    }
    strip_inline_citations(&base)
}

fn sanitize_middle_dots(text: &str) -> String {
    if text.contains('·') {
        text.replace('·', " ")
    } else {
        text.to_string()
    }
}

fn strip_inline_citations(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(open) = rest.find('[') {
        out.push_str(&rest[..open]);
        let after_open = &rest[open + 1..];
        if let Some(close) = after_open.find(']') {
            let token = &after_open[..close];
            if SegmentId::parse_citation(token).is_some() {
                rest = &after_open[close + 1..];
                continue;
            }
        }
        out.push('[');
        rest = after_open;
    }
    out.push_str(rest);
    out.split_whitespace().collect::<Vec<_>>().join(" ")
}
