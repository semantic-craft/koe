pub(crate) mod all_day;
pub(crate) mod live_minutes;
pub(crate) mod mode_workspaces;

use std::borrow::Cow;

use crate::capture::live_minutes::{SourceView, TranscriptLine};
use crate::*;
use chrono::{DateTime, Local};
use koe_engine::{
    context::{AskRole, AskStatus},
    session::TransferPhaseTag,
    transport::OPUS_FRAME_BYTES,
};
use serde::Serialize;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct LiveRecordRowDto<'a> {
    id: &'a str,
    title: &'a str,
    created_at_epoch_sec: u64,
    duration_ms: u64,
    source: String,
    mode: &'static str,
    project: Option<&'a str>,
    run_id: Option<&'a str>,
    ordinal: Option<u64>,
    status: &'static str,
    segment_count: usize,
    preview: String,
    archived: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SourcedItemRowDto<'a> {
    id: &'a str,
    text: &'a str,
    state: &'static str,
    completed: bool,
    due: Option<&'a str>,
    sources: Vec<SourceView<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AskMessageDto<'a> {
    id: &'a str,
    role: &'static str,
    text: &'a str,
    mode: &'static str,
    sources: Vec<SourceView<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct AskSnapshotDto<'a> {
    scope: &'static str,
    record_id: Option<&'a str>,
    phase: &'static str,
    messages: Vec<AskMessageDto<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProviderSnapshotDto<'a> {
    meeting_audio_policy: &'static str,
    meeting_audio_policy_error: Option<&'a str>,
    meeting_audio_status: Option<String>,
    configured: bool,
    qwen_configured: bool,
    deepseek_configured: bool,
    asr_configured: bool,
    asr_is_realtime: bool,
    asr_provider: &'static str,
    asr_model: &'a str,
    llm_provider: &'static str,
    model: &'a str,
    enable_thinking: bool,
    qwen_workspace_id: &'a str,
    asr_endpoint: &'a str,
    chat_endpoint: &'a str,
    credential_state: &'static str,
    deepseek_credential_state: &'static str,
    isolated: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TrashRecordRowDto<'a> {
    id: &'a str,
    title: &'a str,
    created_at_epoch_sec: u64,
    duration_ms: u64,
    source: String,
    segment_count: usize,
    preview: String,
    trashed_at_ms: u64,
    expires_at_ms: u64,
    remaining_days: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct UndoTrashDto<'a> {
    record_id: &'a str,
    title: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    record_ids: Option<&'a [String]>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SpeakerSummaryDto {
    name: String,
    segment_count: usize,
    first_segment_id: String,
}

#[derive(Serialize)]
struct DetailSummarySectionDto<'a> {
    title: Cow<'a, str>,
    text: &'a str,
    sources: Vec<SourceView<'a>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CaptureSpanDto {
    epoch: u64,
    start_ns: u64,
    sample_offset: u64,
    sample_count: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CaptureLaneDto<'a> {
    lane: &'a str,
    audio_path: Option<String>,
    sample_rate: Option<u32>,
    duration_ms: u64,
    interruption: Option<&'a str>,
    timeline: Vec<CaptureSpanDto>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RecordDetailDto<'a> {
    id: &'a str,
    title: &'a str,
    created_at_epoch_sec: u64,
    duration_ms: u64,
    source: String,
    mode: &'static str,
    project: Option<&'a str>,
    run_id: Option<&'a str>,
    ordinal: Option<u64>,
    status: &'static str,
    archived: bool,
    segments: Vec<TranscriptLine<'a>>,
    speakers: Vec<SpeakerSummaryDto>,
    minutes_stale: bool,
    can_edit_transcript: bool,
    capture_lanes: Vec<CaptureLaneDto<'a>>,
    summary: Vec<DetailSummarySectionDto<'a>>,
    highlights: Vec<SourceView<'a>>,
    audio_path: Option<String>,
    can_retranscribe: bool,
    is_processing: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct SnapshotDto<'a> {
    platform: Value,
    speech: Value,
    lifecycle: Value,
    active_capture: Value,
    microphone: Value,
    capture: Value,
    version: u32,
    generation: u64,
    section: Page,
    can_go_back: bool,
    selected_record_id: Option<&'a str>,
    focus_segment_id: Option<&'a str>,
    records: Vec<LiveRecordRowDto<'a>>,
    trash_records: Vec<TrashRecordRowDto<'a>>,
    undo_trash: Option<UndoTrashDto<'a>>,
    detail: Option<RecordDetailDto<'a>>,
    tasks: Vec<SourcedItemRowDto<'a>>,
    memories: Vec<SourcedItemRowDto<'a>>,
    workspaces: Value,
    ask: AskSnapshotDto<'a>,
    device: Value,
    live_caption: Value,
    app_update: Value,
    provider: ProviderSnapshotDto<'a>,
    playback: Value,
    error: Option<&'a str>,
    notice: Option<&'a str>,
}

fn serialize_value<T: Serialize>(value: T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

impl KoeRuntime {
    pub(crate) fn sorted_records(&self) -> Vec<&ProductRecord> {
        let mut records: Vec<_> = self.workspace().records().values().collect();
        records.sort_by(|a, b| {
            b.aggregate
                .created_at_epoch_sec
                .cmp(&a.aggregate.created_at_epoch_sec)
                .then_with(|| b.aggregate.recording_id.cmp(&a.aggregate.recording_id))
        });
        records
    }

    fn live_record_row_dto<'a>(
        &self,
        record: &'a ProductRecord,
        live_record_id: Option<&str>,
        live_duration_ms: u64,
    ) -> LiveRecordRowDto<'a> {
        let is_live = Some(record.aggregate.recording_id.as_str()) == live_record_id;
        let duration_ms = if is_live {
            record.aggregate.duration_ms.max(live_duration_ms)
        } else {
            record.aggregate.duration_ms
        };
        let preview = if is_live {
            record
                .aggregate
                .spine
                .segments()
                .last()
                .map(|s| s.text.as_str())
        } else {
            record
                .aggregate
                .spine
                .segments()
                .first()
                .map(|s| s.text.as_str())
        }
        .or_else(|| {
            self.captures
                .sessions
                .get(&record.aggregate.recording_id)
                .and_then(|s| s.drafts().next())
        })
        .map(|text| text.chars().take(100).collect::<String>())
        .unwrap_or_default();
        LiveRecordRowDto {
            id: &record.aggregate.recording_id,
            title: &record.title,
            created_at_epoch_sec: record.aggregate.created_at_epoch_sec,
            duration_ms,
            source: self.origin_label(record.origin),
            mode: record.mode.as_str(),
            project: record.project.as_deref(),
            run_id: record.all_day.as_ref().map(|s| s.run_id.as_str()),
            ordinal: record.all_day.as_ref().map(|s| s.ordinal),
            status: status(record),
            segment_count: record.aggregate.spine.len(),
            preview,
            archived: record.is_archived(),
        }
    }

    pub(crate) fn live_record_row_json(
        &self,
        record: &ProductRecord,
        live_record_id: Option<&str>,
        live_duration_ms: u64,
    ) -> Value {
        serialize_value(self.live_record_row_dto(record, live_record_id, live_duration_ms))
    }

    fn tasks_and_memories_dtos(&self) -> (Vec<SourcedItemRowDto<'_>>, Vec<SourcedItemRowDto<'_>>) {
        let mut tasks = Vec::new();
        let mut memories = Vec::new();
        for item in self.workspace().items().values() {
            let sources: Vec<_> = item
                .sources
                .iter()
                .filter_map(|s| self.source_view(&s.record_id, s.segment_id))
                .collect();
            if sources.is_empty() {
                continue;
            }
            let state = match item.review {
                ReviewState::Proposed => "proposed",
                ReviewState::Accepted => "accepted",
                ReviewState::Dismissed => "dismissed",
            };
            let row = SourcedItemRowDto {
                id: &item.id,
                text: &item.text,
                state,
                completed: item.completed,
                due: item.due.as_deref(),
                sources,
            };
            if item.kind == ItemKind::Task {
                tasks.push(row);
            } else {
                memories.push(row);
            }
        }
        (tasks, memories)
    }

    pub(crate) fn tasks_and_memories_json(&self) -> (Vec<Value>, Vec<Value>) {
        let (tasks, memories) = self.tasks_and_memories_dtos();
        (
            tasks.into_iter().map(serialize_value).collect(),
            memories.into_iter().map(serialize_value).collect(),
        )
    }

    pub(crate) fn ask_phase(&self) -> &'static str {
        let ask = self.workspace().ask_session();
        if ask.in_flight {
            "pending"
        } else if ask
            .messages
            .last()
            .is_some_and(|m| m.status == AskStatus::Failed)
        {
            "failed"
        } else if ask.messages.is_empty() {
            "idle"
        } else {
            "ready"
        }
    }

    fn ask_dto(&self) -> AskSnapshotDto<'_> {
        let ask = self.workspace().ask_session();
        let messages: Vec<_> = ask
            .messages
            .iter()
            .map(|m| {
                let sources: Vec<_> = m
                    .sources
                    .iter()
                    .filter_map(|line| {
                        self.source_view(&line.source.recording_key, line.source.segment_id)
                    })
                    .collect();
                AskMessageDto {
                    id: &m.id,
                    role: if m.role == AskRole::User {
                        "user"
                    } else {
                        "assistant"
                    },
                    text: &m.text,
                    mode: if m.notice { "retrieval" } else { "answer" },
                    sources,
                }
            })
            .collect();
        let (scope, record_id) = match self.workspace().ask_scope() {
            SearchScope::All => ("all", None),
            SearchScope::Record(id) => ("record", Some(id.as_str())),
        };
        AskSnapshotDto {
            scope,
            record_id,
            phase: self.ask_phase(),
            messages,
        }
    }

    pub(crate) fn ask_json(&self) -> Value {
        serialize_value(self.ask_dto())
    }

    fn provider_dto(&self) -> ProviderSnapshotDto<'_> {
        let config = self.workspace().provider_configuration();
        ProviderSnapshotDto {
            meeting_audio_policy: config.meeting_audio_policy.as_str(),
            meeting_audio_policy_error: self.audio_policy_error.as_deref(),
            meeting_audio_status: if config.meeting_audio_policy == MeetingAudioPolicy::LocalOnly {
                Some("音频只保存在本机；云端语音上传已关闭。".to_string())
            } else {
                self.ensure_meeting_audio_upload().err()
            },
            configured: self.text_provider_configured(),
            qwen_configured: self.settings.qwen.is_ready(),
            deepseek_configured: self.settings.deepseek.is_ready(),
            asr_configured: self.cloud_asr_configured(),
            asr_is_realtime: config.is_realtime_cloud_asr(),
            asr_provider: config.asr_provider.as_str(),
            asr_model: &config.asr_model,
            llm_provider: config.llm_provider.as_str(),
            model: &config.model,
            enable_thinking: config.enable_thinking,
            qwen_workspace_id: &config.qwen_workspace_id,
            asr_endpoint: &config.asr_endpoint,
            chat_endpoint: &config.chat_endpoint,
            credential_state: self.credential_state(),
            deepseek_credential_state: self.deepseek_credential_state(),
            isolated: self.credentials.isolated(),
        }
    }

    pub(crate) fn provider_json(&self) -> Value {
        serialize_value(self.provider_dto())
    }

    pub(crate) fn project(&self, now: u64) -> Value {
        let records = self.sorted_records();
        let (live_record_id, live_duration_ms) = self.live_bean_capture_progress();
        let now = if now > 0 { now } else { self.last_now_sec };
        let rows: Vec<_> = records
            .iter()
            .copied()
            .filter(|r| r.is_live())
            .map(|record| self.live_record_row_dto(record, live_record_id, live_duration_ms))
            .collect();
        let mut trashed_records: Vec<_> = self
            .workspace()
            .records()
            .values()
            .filter(|r| r.is_trashed())
            .collect();
        trashed_records.sort_by(|a, b| {
            b.retention()
                .trashed_at_ms()
                .cmp(&a.retention().trashed_at_ms())
                .then_with(|| {
                    b.aggregate
                        .created_at_epoch_sec
                        .cmp(&a.aggregate.created_at_epoch_sec)
                })
                .then_with(|| a.aggregate.recording_id.cmp(&b.aggregate.recording_id))
        });
        let trash_rows: Vec<_> = trashed_records
            .iter()
            .filter_map(|record| {
                let trashed_at_ms = record.retention().trashed_at_ms()?;
                let expires_at_ms = record.retention().expires_at_ms()?;
                let remaining_days = trash_remaining_days(record, now)?;
                let preview = record
                    .aggregate
                    .spine
                    .segments()
                    .first()
                    .map(|s| s.text.chars().take(100).collect::<String>())
                    .unwrap_or_default();
                Some(TrashRecordRowDto {
                    id: &record.aggregate.recording_id,
                    title: &record.title,
                    created_at_epoch_sec: record.aggregate.created_at_epoch_sec,
                    duration_ms: record.aggregate.duration_ms,
                    source: self.origin_label(record.origin),
                    segment_count: record.aggregate.spine.len(),
                    preview,
                    trashed_at_ms,
                    expires_at_ms,
                    remaining_days,
                })
            })
            .collect();
        let undo_trash = self.undo_trash.as_ref().map(|b| UndoTrashDto {
            record_id: &b.record_id,
            title: &b.title,
            record_ids: (b.record_ids.len() > 1).then_some(b.record_ids.as_slice()),
        });
        let detail = self
            .selection
            .location
            .record
            .as_deref()
            .and_then(|id| self.workspace().record(id))
            .filter(|r| r.is_live())
            .map(|r| self.detail_dto(r, live_record_id, live_duration_ms));
        let (tasks, memories) = self.tasks_and_memories_dtos();
        let ask = self.ask_dto();
        let device = self.device_json_with_live(live_record_id, live_duration_ms);
        let microphone = self.microphone_status();
        let capture_selection = self.capture_selection();
        let workspaces = self.mode_workspaces_json(
            now,
            &records,
            live_record_id,
            live_duration_ms,
            microphone.as_ref(),
            &capture_selection,
        );
        serialize_value(SnapshotDto {
            platform: self.platform.to_json(),
            speech: self.speech_json(),
            lifecycle: self.lifecycle_json(),
            active_capture: self.active_capture_json(microphone.as_ref(), live_duration_ms),
            microphone: self.microphone_json(microphone.as_ref()),
            capture: self.capture_studio_json(&capture_selection),
            version: KOE_HOST_SNAPSHOT_VERSION,
            generation: self.generation,
            section: self.selection.location.page,
            can_go_back: !self.selection.back.is_empty(),
            selected_record_id: self.selection.location.record.as_deref(),
            focus_segment_id: self.selection.location.segment.as_deref(),
            records: rows,
            trash_records: trash_rows,
            undo_trash,
            detail,
            tasks,
            memories,
            workspaces,
            ask,
            device,
            live_caption: self.live_caption_json(),
            app_update: self.app_update_json(),
            provider: self.provider_dto(),
            playback: self.playback_json(),
            error: self.error_str(),
            notice: self.notice.as_deref(),
        })
    }

    fn detail_dto<'a>(
        &'a self,
        record: &'a ProductRecord,
        live_record_id: Option<&str>,
        live_duration_ms: u64,
    ) -> RecordDetailDto<'a> {
        let aggregate = &record.aggregate;
        let duration_ms = if Some(aggregate.recording_id.as_str()) == live_record_id {
            aggregate.duration_ms.max(live_duration_ms)
        } else {
            aggregate.duration_ms
        };
        let segments: Vec<_> = aggregate
            .spine
            .segments()
            .iter()
            .map(TranscriptLine::from)
            .collect();
        let speakers: Vec<_> = record
            .distinct_speakers()
            .into_iter()
            .map(|sp| SpeakerSummaryDto {
                name: sp.name,
                segment_count: sp.segment_count,
                first_segment_id: sp.first_segment_id.to_string(),
            })
            .collect();
        let mut summary = Vec::new();
        for imported in self
            .workspace()
            .migrations()
            .iter()
            .flat_map(|m| &m.summaries)
            .filter(|s| s.record_id == aggregate.recording_id)
        {
            summary.push(DetailSummarySectionDto {
                title: Cow::Owned(format!("旧版纪要（未验证来源） {}", imported.slot)),
                text: &imported.text,
                sources: Vec::new(),
            });
        }
        summary.extend(self.minutes_sections(record).into_iter().map(|section| {
            DetailSummarySectionDto {
                title: Cow::Borrowed(section.title),
                text: section.text,
                sources: section.sources,
            }
        }));
        let mut highlighted = record.highlighted_segments.clone();
        for mark in &aggregate.bookmarks {
            if let Some(segment) = aggregate
                .spine
                .segments()
                .iter()
                .find(|s| s.start_ms <= *mark && *mark <= s.end_ms)
            {
                highlighted.insert(segment.id);
            }
        }
        let highlights: Vec<_> = highlighted
            .iter()
            .filter_map(|s| self.source_view(&aggregate.recording_id, *s))
            .collect();
        let audio = recording_assets::audio_path(&self.root, &aggregate.recording_id)
            .ok()
            .filter(|p| p.exists());
        let capture_lanes: Vec<_> = record
            .capture_lanes
            .iter()
            .map(|l| {
                let path = l
                    .asset_id
                    .as_ref()
                    .and_then(|id| recording_assets::audio_path(&self.root, id).ok())
                    .filter(|p| p.is_file());
                CaptureLaneDto {
                    lane: &l.lane,
                    audio_path: path.map(|p| p.to_string_lossy().into_owned()),
                    sample_rate: l.sample_rate,
                    duration_ms: l.duration_ms,
                    interruption: l.interruption.as_deref(),
                    timeline: l
                        .timeline
                        .iter()
                        .map(|s| CaptureSpanDto {
                            epoch: s.epoch,
                            start_ns: s.start_ns,
                            sample_offset: s.sample_offset,
                            sample_count: s.sample_count,
                        })
                        .collect(),
                }
            })
            .collect();
        let can_retranscribe = audio.is_some()
            && matches!(
                record.analysis,
                AnalysisState::Failed { .. } | AnalysisState::Interrupted { .. }
            );
        RecordDetailDto {
            id: &aggregate.recording_id,
            title: &record.title,
            created_at_epoch_sec: aggregate.created_at_epoch_sec,
            duration_ms,
            source: self.origin_label(record.origin),
            mode: record.mode.as_str(),
            project: record.project.as_deref(),
            run_id: record.all_day.as_ref().map(|s| s.run_id.as_str()),
            ordinal: record.all_day.as_ref().map(|s| s.ordinal),
            status: status(record),
            archived: record.is_archived(),
            segments,
            speakers,
            minutes_stale: record.is_minutes_stale(),
            can_edit_transcript: self.can_edit_record(&aggregate.recording_id),
            capture_lanes,
            summary,
            highlights,
            audio_path: audio.map(|p| p.to_string_lossy().to_string()),
            can_retranscribe,
            is_processing: matches!(record.analysis, AnalysisState::Pending { .. }),
        }
    }

    pub(crate) fn origin_label(&self, source: RecordOrigin) -> String {
        match source {
            RecordOrigin::Microphone => self.platform.mic_label(),
            RecordOrigin::Bean => "录音豆".into(),
            RecordOrigin::ImportedAudio => "导入音频".into(),
            RecordOrigin::ImportedText => "导入文字".into(),
            RecordOrigin::Note => "随手记".into(),
        }
    }

    pub(crate) fn live_bean_capture_progress(&self) -> (Option<&str>, u64) {
        let device = &self.device.session;
        let live_record_id = device
            .active_file_id
            .and_then(|fid| self.captures.active.get(&fid))
            .or_else(|| self.captures.active.values().next())
            .map(String::as_str);
        let live_duration_ms = if device.device_recording_active
            || matches!(device.transfer.phase, TransferPhaseTag::StreamingRealtime)
        {
            let opus_ms = ((device.opus_buffer.len() / OPUS_FRAME_BYTES) as u64) * 20;
            let pcm_ms = live_record_id
                .and_then(|id| self.captures.sessions.get(id))
                .map_or(0, |c| c.captured_pcm_bytes / 32);
            let record_ms = live_record_id
                .and_then(|id| self.workspace().record(id))
                .map_or(0, |r| r.aggregate.duration_ms);
            opus_ms.max(pcm_ms).max(record_ms)
        } else {
            0
        };
        (live_record_id, live_duration_ms)
    }

    pub(crate) fn record_detail_json(&self, id: &str) -> Result<Value, String> {
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        let (live_record_id, live_duration_ms) = self.live_bean_capture_progress();
        Ok(serialize_value(self.detail_dto(
            record,
            live_record_id,
            live_duration_ms,
        )))
    }

    pub(crate) fn source_json(&self, source: &SourceRef) -> Option<Value> {
        self.source_view(&source.record_id, source.segment_id)
            .map(serialize_value)
    }
}

pub(crate) fn local_date(epoch: u64) -> Option<chrono::NaiveDate> {
    i64::try_from(epoch)
        .ok()
        .and_then(|n| DateTime::from_timestamp(n, 0))
        .map(|d| d.with_timezone(&Local).date_naive())
}

pub(crate) fn trash_remaining_days(record: &ProductRecord, now_sec: u64) -> Option<u64> {
    let trashed_at_ms = record.retention().trashed_at_ms()?;
    let expires_at_ms = record.retention().expires_at_ms()?;
    let reference_now_ms = if now_sec > 0 {
        now_sec.saturating_mul(1000)
    } else {
        trashed_at_ms
    };
    Some(if reference_now_ms < expires_at_ms {
        expires_at_ms
            .saturating_sub(reference_now_ms)
            .div_ceil(86_400_000)
            .clamp(1, 30)
    } else {
        0
    })
}

pub(crate) fn origin_slug(source: RecordOrigin) -> &'static str {
    match source {
        RecordOrigin::Microphone => "microphone",
        RecordOrigin::Bean => "bean",
        RecordOrigin::ImportedAudio => "imported_audio",
        RecordOrigin::ImportedText => "imported_text",
        RecordOrigin::Note => "note",
    }
}

pub(crate) fn status(record: &ProductRecord) -> &'static str {
    match &record.analysis {
        AnalysisState::Pending {
            stage: AnalysisStage::Transcribing,
            ..
        } => "转写中",
        AnalysisState::Pending {
            stage: AnalysisStage::Summarizing,
            ..
        } => "整理中",
        AnalysisState::Failed { .. } => "处理失败",
        AnalysisState::Interrupted { .. } => "处理已中断",
        _ if record
            .capture_lanes
            .iter()
            .any(|l| l.interruption.is_some()) =>
        {
            "采集不完整"
        }
        _ if record.aggregate.spine.is_empty() => "等待转写",
        _ if record.is_minutes_stale() => "原文已变更待重算",
        _ if record.aggregate.minutes.is_some() => "已整理",
        _ => "已有文字",
    }
}
