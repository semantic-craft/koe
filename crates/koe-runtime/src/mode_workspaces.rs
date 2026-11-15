use super::*;
use crate::{
    capture_studio::CaptureSelection,
    command::CaptureMode,
    live_minutes::{SourceView, TranscriptLine},
    microphone::{MicrophoneStatus, Phase},
    projection::{local_date, origin, status},
};
use chrono::NaiveDate;
use koe_client_base::write_atomic;
use std::collections::BTreeMap;

pub(super) const QUICK_NOTE_MCP_READ_NOTE: &str =
    "外部 Agent 可通过只读 MCP 检索已保存闪记原文与已采纳行动，不会自动改写记录。";

impl KoeRuntime {
    pub(super) fn set_record_project(
        &mut self,
        record_id: &str,
        project: Option<&str>,
    ) -> Result<(), String> {
        self.commit(|w| w.set_record_project(record_id, project))?;
        self.notice = Some("已更新项目归类".into());
        Ok(())
    }

    pub(super) fn select_quick_note_record(
        &mut self,
        record_id: Option<String>,
    ) -> Result<(), String> {
        if let Some(id) = &record_id {
            let record = self.workspace().record(id).ok_or("记录不存在")?;
            if !record.is_live() {
                return Err("记录不存在".into());
            }
        }
        self.selected_quick_note_record = record_id;
        Ok(())
    }

    pub(super) fn select_all_day_date(&mut self, date: &str) -> Result<(), String> {
        let trimmed = date.trim();
        NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
            .map_err(|_| "日期格式无效".to_string())?;
        self.selected_all_day_date = Some(trimmed.to_owned());
        Ok(())
    }

    pub(super) fn select_live_minutes_record(
        &mut self,
        record_id: Option<String>,
    ) -> Result<(), String> {
        if let Some(id) = &record_id {
            let record = self.workspace().record(id).ok_or("记录不存在")?;
            if !record.is_live() {
                return Err("记录不存在".into());
            }
        }
        self.selected_live_minutes_record = record_id;
        Ok(())
    }

    pub(super) fn export_workspace_markdown(
        &mut self,
        record_id: Option<&str>,
        date: Option<&str>,
        path: &Path,
        include_analysis: bool,
        include_sources: bool,
    ) -> Result<(), String> {
        let options = MarkdownExportOptions {
            include_analysis,
            include_sources,
        };
        let live_items = self.live_sourced_items();
        if let Some(id) = record_id {
            let record = self.workspace().record(id).ok_or("记录不存在")?;
            record.ensure_live().map_err(|e| e.to_string())?;
            let output = format_record_markdown(record, &live_items, options);
            write_atomic(path, output.as_bytes()).map_err(|e| format!("导出失败：{e}"))?;
            self.notice = Some("已导出 Markdown".into());
            Ok(())
        } else if let Some(d) = date {
            let trimmed = d.trim();
            let parsed = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
                .map_err(|_| "日期格式无效".to_string())?;
            let day_records: Vec<&ProductRecord> = self
                .workspace()
                .records()
                .values()
                .filter(|r| {
                    r.is_live()
                        && r.mode == RecordMode::AllDay
                        && local_date(r.aggregate.created_at_epoch_sec) == Some(parsed)
                })
                .collect();
            let timeline = build_day_timeline(&day_records);
            let output = format_day_markdown(trimmed, &timeline, &day_records, &live_items, options);
            write_atomic(path, output.as_bytes()).map_err(|e| format!("导出失败：{e}"))?;
            self.notice = Some("已导出当日记录 Markdown".into());
            Ok(())
        } else {
            Err("缺少导出目标".into())
        }
    }

    pub(super) fn active_capture_mode_tag(&self) -> Option<CaptureMode> {
        if self.all_day.run.is_some() {
            Some(CaptureMode::AllDay)
        } else if let Some(mic) = &self.microphone {
            Some(mic.mode.unwrap_or(CaptureMode::QuickNote))
        } else if self.bean_capture_mode.is_some() || self.is_bean_meeting_recording() {
            Some(self.bean_capture_mode.unwrap_or(CaptureMode::QuickNote))
        } else {
            None
        }
    }

    pub(super) fn live_sourced_items(&self) -> Vec<&SourcedItem> {
        self.workspace()
            .items()
            .values()
            .filter(|item| {
                item.sources
                    .iter()
                    .any(|s| self.source_view(&s.record_id, s.segment_id).is_some())
            })
            .collect()
    }

    pub(super) fn sourced_item_json(&self, item: &SourcedItem) -> Option<Value> {
        if item.review == ReviewState::Dismissed {
            return None;
        }
        let sources: Vec<_> = item
            .sources
            .iter()
            .filter_map(|s| self.source_view(&s.record_id, s.segment_id))
            .collect();
        if sources.is_empty() {
            return None;
        }
        let state = match item.review {
            ReviewState::Proposed => "proposed",
            ReviewState::Accepted => "accepted",
            ReviewState::Dismissed => "dismissed",
        };
        let kind = match item.kind {
            ItemKind::Task => "task",
            ItemKind::Memory => "memory",
        };
        Some(json!({
            "id": item.id,
            "kind": kind,
            "text": item.text,
            "state": state,
            "completed": item.completed,
            "due": item.due,
            "sources": sources,
        }))
    }

    pub(super) fn mode_workspaces_json(
        &self,
        now: u64,
        records: &[&ProductRecord],
        live_record_id: Option<&str>,
        live_duration_ms: u64,
        microphone: Option<&MicrophoneStatus<'_>>,
        capture_selection: &CaptureSelection,
    ) -> Value {
        let active_mode = self.active_capture_mode_tag();
        let quick_note = self.quick_note_workspace_json(
            records,
            active_mode,
            live_record_id,
            live_duration_ms,
            microphone,
            capture_selection,
        );
        let all_day = self.all_day_workspace_json(now, records, microphone, capture_selection);
        let live_minutes = self.live_minutes_workspace_json(
            records,
            live_record_id,
            live_duration_ms,
            microphone,
            capture_selection,
        );
        let voice_input = self.voice_input_workspace_json();
        let picker = self.mode_picker_json(
            now,
            records,
            active_mode,
            capture_selection,
            quick_note["inboxCount"].as_u64().unwrap_or(0) as usize,
            quick_note["totalCount"].as_u64().unwrap_or(0) as usize,
            live_minutes["pastMeetings"].as_array().map_or(0, Vec::len),
        );
        json!({
            "picker": picker,
            "quickNote": quick_note,
            "allDay": all_day,
            "liveMinutes": live_minutes,
            "voiceInput": voice_input,
        })
    }

    #[allow(clippy::too_many_arguments)]
    fn mode_picker_json(
        &self,
        now: u64,
        records: &[&ProductRecord],
        active_mode: Option<CaptureMode>,
        capture_selection: &CaptureSelection,
        inbox_count: usize,
        quick_note_total: usize,
        past_meeting_count: usize,
    ) -> Value {
        let can_control = !self.is_quitting() && !self.store.requires_reopen();
        let can_start = self.can_start_capture_mode(capture_selection);
        let today = local_date(now);
        let today_all_day: Vec<&ProductRecord> = records
            .iter()
            .copied()
            .filter(|r| {
                r.is_live()
                    && r.mode == RecordMode::AllDay
                    && local_date(r.aggregate.created_at_epoch_sec) == today
            })
            .collect();
        let today_timeline = build_day_timeline(&today_all_day);

        let notes_active = active_mode == Some(CaptureMode::QuickNote);
        let all_day_active = self.all_day.run.is_some() || active_mode == Some(CaptureMode::AllDay);
        let all_day_paused = self.all_day.run.is_some()
            && self
                .microphone
                .as_ref()
                .is_some_and(|m| m.phase == Phase::Paused);
        let meeting_active = active_mode == Some(CaptureMode::Meeting);
        let voice_active = self.workspace().companion_mode() == CompanionRoutingMode::CollarStandby;
        let device_name = self
            .device
            .device_name
            .as_deref()
            .unwrap_or("Soundcore Work");

        let cards = json!([
            {
                "id": "notes",
                "mode": "quick_note",
                "title": "随心闪记",
                "subtitle": "想到就记，原文优先，收件箱与项目自由归类",
                "isSessionActive": notes_active,
                "canToggleSession": can_control && (notes_active || can_start),
                "statusBadge": if notes_active {
                    "记录中".to_string()
                } else if inbox_count > 0 {
                    format!("收件箱 {inbox_count}")
                } else {
                    "就绪".to_string()
                },
                "metricText": format!("共 {quick_note_total} 条闪记，收件箱 {inbox_count} 条"),
            },
            {
                "id": "all_day",
                "mode": "all_day",
                "title": "全天听记",
                "subtitle": "按事件回看全天对话，自动标记暂停与未录音空档",
                "isSessionActive": all_day_active,
                "canToggleSession": can_control && (all_day_active || can_start),
                "statusBadge": if all_day_paused {
                    "已暂停".to_string()
                } else if all_day_active {
                    "听记中".to_string()
                } else {
                    "待开启".to_string()
                },
                "metricText": format!(
                    "今日 {} 个事件，已录 {} 分钟",
                    today_timeline.event_count,
                    today_timeline.total_recorded_ms / 60_000
                ),
            },
            {
                "id": "live_minutes",
                "mode": "meeting",
                "title": "实时纪要",
                "subtitle": "边听边整理议题与待办，会后核对完整纪要",
                "isSessionActive": meeting_active,
                "canToggleSession": can_control && (meeting_active || can_start),
                "statusBadge": if meeting_active {
                    "会议中".to_string()
                } else if past_meeting_count > 0 {
                    "可回看".to_string()
                } else {
                    "就绪".to_string()
                },
                "metricText": format!("往期会议 {past_meeting_count} 场"),
            },
            {
                "id": "voice_input",
                "mode": "dictation",
                "title": "语音输入",
                "subtitle": "录音豆待命流桥接光标听写，一步步检查可用状态",
                "isSessionActive": voice_active,
                "canToggleSession": can_control && (voice_active || self.ensure_voice_input_available().is_ok()),
                "statusBadge": if voice_active {
                    if self.is_standby_ready() {
                        "待命就绪".to_string()
                    } else {
                        "已开启待连接".to_string()
                    }
                } else {
                    "未开启".to_string()
                },
                "metricText": if self.device.is_connected() {
                    format!("{device_name} 已连接")
                } else {
                    "等待录音豆连接".to_string()
                },
            }
        ]);

        json!({
            "sourceLabel": capture_selection.label,
            "sourceBadge": capture_selection.badge,
            "cards": cards,
        })
    }

    fn quick_note_workspace_json(
        &self,
        records: &[&ProductRecord],
        active_mode: Option<CaptureMode>,
        live_record_id: Option<&str>,
        live_duration_ms: u64,
        microphone: Option<&MicrophoneStatus<'_>>,
        capture_selection: &CaptureSelection,
    ) -> Value {
        let is_active = active_mode == Some(CaptureMode::QuickNote);
        let source_label = if is_active {
            if let Some(m) = microphone {
                m.input_label.clone()
            } else {
                self.device
                    .device_name
                    .clone()
                    .unwrap_or_else(|| capture_selection.label.clone())
            }
        } else {
            capture_selection.label.clone()
        };

        let quick_records: Vec<&ProductRecord> = records
            .iter()
            .copied()
            .filter(|r| r.is_live() && r.mode == RecordMode::QuickNote)
            .collect();
        let inbox_count = quick_records
            .iter()
            .filter(|r| r.is_quick_note_inbox())
            .count();

        let mut project_counts: BTreeMap<&str, usize> = BTreeMap::new();
        for rec in &quick_records {
            if let Some(proj) = rec.project.as_deref() {
                *project_counts.entry(proj).or_insert(0) += 1;
            }
        }
        let projects: Vec<Value> = project_counts
            .into_iter()
            .map(|(name, count)| json!({ "name": name, "count": count }))
            .collect();

        let selected_record_id = self
            .selected_quick_note_record
            .as_deref()
            .filter(|id| {
                quick_records
                    .iter()
                    .any(|r| r.aggregate.recording_id == *id)
            })
            .map(str::to_owned)
            .or_else(|| {
                quick_records
                    .first()
                    .map(|r| r.aggregate.recording_id.clone())
            });

        let configured = self.text_provider_configured();
        let cards: Vec<Value> = quick_records
            .iter()
            .map(|record| {
                let rec_id = record.aggregate.recording_id.as_str();
                let duration_ms = if Some(rec_id) == live_record_id {
                    record.aggregate.duration_ms.max(live_duration_ms)
                } else {
                    record.aggregate.duration_ms
                };
                let segments: Vec<_> = record
                    .aggregate
                    .spine
                    .segments()
                    .iter()
                    .map(TranscriptLine::from)
                    .collect();
                let gist = record
                    .aggregate
                    .minutes
                    .as_ref()
                    .map(|m| m.overview.trim())
                    .filter(|s| !s.is_empty());
                let topics: Vec<Value> = record
                    .aggregate
                    .minutes
                    .as_ref()
                    .map(|m| {
                        m.topics
                            .iter()
                            .map(|topic| {
                                let sources: Vec<SourceView<'_>> = topic
                                    .citations
                                    .iter()
                                    .filter_map(|sid| self.source_view(rec_id, *sid))
                                    .collect();
                                json!({
                                    "title": topic.title,
                                    "summary": topic.summary,
                                    "sources": sources,
                                })
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let next_steps: Vec<Value> = self
                    .workspace()
                    .items()
                    .values()
                    .filter(|item| item.sources.iter().any(|s| s.record_id == rec_id))
                    .filter_map(|item| self.sourced_item_json(item))
                    .collect();
                let can_summarize = !record.aggregate.spine.is_empty()
                    && configured
                    && !matches!(record.analysis, AnalysisState::Pending { .. });
                json!({
                    "id": rec_id,
                    "title": record.title,
                    "createdAtEpochSec": record.aggregate.created_at_epoch_sec,
                    "durationMs": duration_ms,
                    "source": origin(record.origin),
                    "status": status(record),
                    "archived": record.is_archived(),
                    "project": record.project,
                    "isInbox": record.is_quick_note_inbox(),
                    "minutesStale": record.is_minutes_stale(),
                    "canSummarize": can_summarize,
                    "segments": segments,
                    "gist": gist,
                    "topics": topics,
                    "nextSteps": next_steps,
                })
            })
            .collect();

        json!({
            "isActive": is_active,
            "sourceLabel": source_label,
            "inboxCount": inbox_count,
            "totalCount": quick_records.len(),
            "projects": projects,
            "selectedRecordId": selected_record_id,
            "mcpReadNote": QUICK_NOTE_MCP_READ_NOTE,
            "cards": cards,
        })
    }
}
