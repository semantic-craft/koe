use crate::{
    capture::{
        live_minutes::{SourceView, TranscriptLine},
        microphone::{MicrophoneStatus, Phase},
        studio::CaptureSelection,
    },
    command::CaptureMode,
    projection::{local_date, status},
    workspace::platform::HostPlatformKind,
    *,
};
use chrono::NaiveDate;
use koe_client_base::write_atomic;
use koe_engine::session::{ConnectionPhaseTag, TransferPhaseTag};
use std::collections::{BTreeMap, BTreeSet};

pub(crate) const QUICK_NOTE_MCP_READ_NOTE: &str =
    "外部 Agent 可通过只读 MCP 检索已保存闪记原文与已采纳行动，不会自动改写记录。";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BeanControlOwner {
    ThisDevice,
    Released,
}

struct ModePickerCounts {
    inbox_count: usize,
    quick_note_total: usize,
    past_meeting_count: usize,
}

fn sanitize_export_filename(title: &str) -> String {
    let cleaned: String = title
        .trim()
        .chars()
        .map(|ch| match ch {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' => '-',
            c if c.is_control() => ' ',
            c => c,
        })
        .collect();
    let trimmed = cleaned.trim().trim_start_matches('.').trim();
    if trimmed.is_empty() {
        "Koe 记录".to_string()
    } else {
        trimmed.chars().take(80).collect()
    }
}

impl KoeRuntime {
    pub(crate) fn set_record_project(
        &mut self,
        record_id: &str,
        project: Option<&str>,
    ) -> Result<(), String> {
        self.commit(|w| w.set_record_project(record_id, project))?;
        self.notice = Some("已更新项目归类".into());
        Ok(())
    }

    pub(crate) fn batch_set_record_project(
        &mut self,
        record_ids: &[String],
        project: Option<&str>,
    ) -> Result<(), String> {
        let mut seen = BTreeSet::new();
        let live_ids: Vec<String> = record_ids
            .iter()
            .map(|id| id.trim())
            .filter(|id| !id.is_empty() && seen.insert((*id).to_owned()))
            .filter(|id| self.workspace().record(id).is_some_and(|r| r.is_live()))
            .map(ToOwned::to_owned)
            .collect();
        if live_ids.is_empty() {
            return Err("请先选择至少一条记录".into());
        }
        let count = live_ids.len();
        self.commit(|w| {
            for id in &live_ids {
                w.set_record_project(id, project)?;
            }
            Ok(())
        })?;
        let trimmed = project.map(str::trim).filter(|s| !s.is_empty());
        self.notice = Some(match trimmed {
            Some(name) => format!("已将 {count} 条记录归类到项目「{name}」"),
            None => format!("已将 {count} 条记录移回收件箱"),
        });
        Ok(())
    }

    pub(crate) fn select_quick_note_record(
        &mut self,
        record_id: Option<String>,
    ) -> Result<(), String> {
        if let Some(id) = &record_id {
            let record = self.workspace().record(id).ok_or("记录不存在")?;
            if !record.is_live() {
                return Err("记录不存在".into());
            }
        }
        self.selection.selected_quick_note_record = record_id;
        Ok(())
    }

    pub(crate) fn select_all_day_date(&mut self, date: &str) -> Result<(), String> {
        let trimmed = date.trim();
        NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
            .map_err(|_| "日期格式无效".to_string())?;
        self.selection.selected_all_day_date = Some(trimmed.to_owned());
        Ok(())
    }

    pub(crate) fn select_live_minutes_record(
        &mut self,
        record_id: Option<String>,
    ) -> Result<(), String> {
        if let Some(id) = &record_id {
            let record = self.workspace().record(id).ok_or("记录不存在")?;
            if !record.is_live() {
                return Err("记录不存在".into());
            }
            if record.mode != RecordMode::Meeting {
                return Err("该记录不是实时纪要会议".into());
            }
        }
        self.selection.selected_live_minutes_record = record_id;
        Ok(())
    }

    fn write_exported_markdown(
        &mut self,
        path: &Path,
        output: &str,
        notice: &str,
    ) -> Result<(), String> {
        write_atomic(path, output.as_bytes()).map_err(|e| format!("导出失败：{e}"))?;
        self.notice = Some(notice.into());
        Ok(())
    }

    pub(crate) fn export_workspace_markdown(
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
            self.write_exported_markdown(path, &output, "已导出 Markdown")
        } else if let Some(d) = date {
            let trimmed = d.trim();
            let parsed = NaiveDate::parse_from_str(trimmed, "%Y-%m-%d")
                .map_err(|_| "日期格式无效".to_string())?;
            let mut day_records: Vec<&ProductRecord> = self
                .workspace()
                .records()
                .values()
                .filter(|r| {
                    r.is_live()
                        && r.mode == RecordMode::AllDay
                        && local_date(r.aggregate.created_at_epoch_sec) == Some(parsed)
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
            let output = format_day_markdown(trimmed, &timeline, &day_records, &live_items, options);
            self.write_exported_markdown(path, &output, "已导出当日记录 Markdown")
        } else {
            Err("缺少导出目标".into())
        }
    }

    pub(crate) fn export_records_markdown(
        &mut self,
        record_ids: &[String],
        directory: &Path,
        include_analysis: bool,
        include_sources: bool,
    ) -> Result<(), String> {
        if !directory.is_dir() {
            return Err("导出目录不存在或无法写入".into());
        }
        let mut seen = BTreeSet::new();
        let live_ids: Vec<String> = record_ids
            .iter()
            .map(|id| id.trim())
            .filter(|id| !id.is_empty() && seen.insert((*id).to_owned()))
            .filter(|id| self.workspace().record(id).is_some_and(|r| r.is_live()))
            .map(ToOwned::to_owned)
            .collect();
        if live_ids.is_empty() {
            return Err("请先选择至少一条要导出的记录".into());
        }
        let options = MarkdownExportOptions {
            include_analysis,
            include_sources,
        };
        let live_items = self.live_sourced_items();
        let mut used_names = BTreeSet::new();
        let mut exported = 0usize;
        for id in &live_ids {
            let record = self.workspace().record(id).ok_or("记录不存在")?;
            let output = format_record_markdown(record, &live_items, options);
            let stem = sanitize_export_filename(&record.title);
            let mut candidate_idx = 1usize;
            let path = loop {
                let name = if candidate_idx == 1 {
                    format!("{stem}.md")
                } else {
                    format!("{stem}-{candidate_idx}.md")
                };
                let key = name.to_lowercase();
                let candidate_path = directory.join(&name);
                if used_names.insert(key) && !candidate_path.exists() {
                    break candidate_path;
                }
                candidate_idx += 1;
            };
            write_atomic(&path, output.as_bytes()).map_err(|e| format!("导出失败：{e}"))?;
            exported += 1;
        }
        self.notice = Some(format!("已导出 {exported} 条记录 Markdown"));
        Ok(())
    }

    pub(super) fn active_capture_mode_tag(&self) -> Option<CaptureMode> {
        self.active_capture
            .active_capture_mode_tag(self.is_bean_meeting_recording())
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

    pub(crate) fn bean_control_owner(&self) -> BeanControlOwner {
        if !self.workspace().ble_auto_connect()
            && !self.device.is_connected()
            && matches!(
                self.device.session.connection_phase,
                ConnectionPhaseTag::Disconnected
            )
        {
            BeanControlOwner::Released
        } else {
            BeanControlOwner::ThisDevice
        }
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
        let picker = self.mode_picker_json(
            now,
            records,
            active_mode,
            capture_selection,
            ModePickerCounts {
                inbox_count: quick_note["inboxCount"].as_u64().unwrap_or(0) as usize,
                quick_note_total: quick_note["totalCount"].as_u64().unwrap_or(0) as usize,
                past_meeting_count: live_minutes["pastMeetings"].as_array().map_or(0, Vec::len),
            },
        );
        json!({
            "picker": picker,
            "quickNote": quick_note,
            "allDay": all_day,
            "liveMinutes": live_minutes,
        })
    }

    fn mode_picker_json(
        &self,
        now: u64,
        records: &[&ProductRecord],
        active_mode: Option<CaptureMode>,
        capture_selection: &CaptureSelection,
        counts: ModePickerCounts,
    ) -> Value {
        let ModePickerCounts {
            inbox_count,
            quick_note_total,
            past_meeting_count,
        } = counts;
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
        let all_day_active =
            self.active_capture.all_day_run().is_some() || active_mode == Some(CaptureMode::AllDay);
        let all_day_paused = self.active_capture.all_day_run().is_some()
            && self
                .active_capture
                .microphone()
                .is_some_and(|m| m.phase == Phase::Paused);
        let meeting_active = active_mode == Some(CaptureMode::Meeting);

        let is_pulling_offline =
            matches!(self.device.session.transfer.phase, TransferPhaseTag::PullingOffline);
        let device_busy = self.is_device_busy();
        let device_recording = self.device.session.device_recording_active;
        let owner = self.bean_control_owner();
        let can_release_to_phone = self.can_release_to_phone();

        let is_macos = self.platform.kind == HostPlatformKind::Macos;
        let (bean_badge, bean_badge_tone) = if owner == BeanControlOwner::Released {
            if is_macos {
                ("已让出给手机", "muted")
            } else {
                ("已释放蓝牙控制", "muted")
            }
        } else if !self.device.is_connected() {
            match self.device.session.connection_phase {
                ConnectionPhaseTag::Scanning => ("录音豆 查找中", "warning"),
                ConnectionPhaseTag::Connecting | ConnectionPhaseTag::Handshaking => {
                    ("录音豆 连接中", "warning")
                }
                ConnectionPhaseTag::Disconnected | ConnectionPhaseTag::Connected => {
                    ("录音豆 未连接", "muted")
                }
            }
        } else if device_recording {
            ("录音豆 录音中", "success")
        } else if device_busy {
            ("录音豆 同步中", "success")
        } else {
            ("录音豆 已连接", "success")
        };

        let can_switch_to_bean = can_control
            && self.device.is_connected()
            && !device_busy
            && capture_selection.active_source.is_none()
            && capture_selection.source != "bean";
        let can_connect_bean = can_control && !self.device.is_connected();

        let guidance_text: String = if is_pulling_offline {
            if is_macos {
                "正在从录音豆拉取离线录音，请等待完成后再切回手机，避免传输中断。".into()
            } else {
                "正在从录音豆拉取离线录音，请等待完成后再释放蓝牙控制，避免传输中断。".into()
            }
        } else if owner == BeanControlOwner::Released {
            if is_macos {
                "已释放 Mac 蓝牙占用，可在 iPhone 飞书妙记连接。若未搜到，将录音豆放入充电仓短按下方按钮。".into()
            } else {
                format!(
                    "已释放 {} 蓝牙占用，可在其他设备连接录音豆。若未搜到，将录音豆放入充电仓短按下方按钮。",
                    self.platform.host_display_name
                )
            }
        } else if capture_selection.source == "bean" {
            if !self.device.is_connected() {
                if is_macos {
                    "请先将录音豆放入充电仓长按 2 秒连接，或切换为电脑麦克风后再选模式。".into()
                } else {
                    format!(
                        "请先将录音豆放入充电仓长按 2 秒连接，或切换为 {} 后再选模式。",
                        self.platform.mic_label()
                    )
                }
            } else if device_busy {
                "录音豆正在同步或录音，完成后可开启下方模式，或单按侧键录闪记。".into()
            } else {
                "录音豆已就绪，可直接打开下方模式开关，或单按豆子侧键录闪记。".into()
            }
        } else if self.device.is_connected() && device_busy {
            if is_macos {
                "录音豆正在同步或录音，当前暂用电脑麦克风，完成后自动恢复。".into()
            } else {
                format!(
                    "录音豆正在同步或录音，当前暂用 {}，完成后自动恢复。",
                    self.platform.mic_label()
                )
            }
        } else if self.device.is_connected() {
            if is_macos {
                "当前使用电脑麦克风，如需用录音豆收音可点右侧切换为录音豆。".into()
            } else {
                format!(
                    "当前使用 {}，如需用录音豆收音可点右侧切换为录音豆。",
                    self.platform.mic_label()
                )
            }
        } else if is_macos {
            "当前使用电脑麦克风，也可将录音豆放入充电仓按键连接后再选模式。".into()
        } else {
            format!(
                "当前使用 {}，也可将录音豆放入充电仓按键连接后再选模式。",
                self.platform.mic_label()
            )
        };

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
            }
        ]);

        json!({
            "sourceLabel": capture_selection.label,
            "sourceBadge": capture_selection.badge,
            "beanBadge": bean_badge,
            "beanBadgeTone": bean_badge_tone,
            "beanControlOwner": match owner {
                BeanControlOwner::ThisDevice => "mac",
                BeanControlOwner::Released => "phone",
            },
            "beanControlState": match owner {
                BeanControlOwner::ThisDevice => "this_device",
                BeanControlOwner::Released => "released",
            },
            "guidanceText": guidance_text,
            "canSwitchToBean": can_switch_to_bean,
            "canConnectBean": can_connect_bean,
            "canReleaseToPhone": can_release_to_phone,
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
            .filter(|r| r.is_live() && !r.is_archived() && r.mode == RecordMode::QuickNote)
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
            .selection
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
        let quick_ids: BTreeSet<&str> = quick_records
            .iter()
            .map(|r| r.aggregate.recording_id.as_str())
            .collect();
        let mut items_by_record: BTreeMap<&str, Vec<Value>> = BTreeMap::new();
        for item in self.workspace().items().values() {
            let mut matched_records = BTreeSet::new();
            for source in &item.sources {
                let rid = source.record_id.as_str();
                if quick_ids.contains(rid) {
                    matched_records.insert(rid);
                }
            }
            if matched_records.is_empty() {
                continue;
            }
            if let Some(item_val) = self.sourced_item_json(item) {
                for rid in matched_records {
                    items_by_record
                        .entry(rid)
                        .or_default()
                        .push(item_val.clone());
                }
            }
        }
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
                let next_steps = items_by_record.remove(rec_id).unwrap_or_default();
                let can_summarize = !record.aggregate.spine.is_empty()
                    && configured
                    && !matches!(record.analysis, AnalysisState::Pending { .. });
                json!({
                    "id": rec_id,
                    "title": record.title,
                    "createdAtEpochSec": record.aggregate.created_at_epoch_sec,
                    "durationMs": duration_ms,
                    "source": self.origin_label(record.origin),
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
            "canStart": self.can_start_capture_mode(capture_selection),
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
