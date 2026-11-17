use std::collections::BTreeMap;

use koe_engine::context::{AskMessage, AskRole, AskSession, AskStatus, SourceLine, SourcePointer};
use koe_engine::domain::{RecordingAggregate, SegmentId};
use koe_engine::minutes::{encode_meeting_minutes_json, parse_persisted_meeting_minutes_json};
use koe_engine::product::*;
use serde::{Deserialize, Serialize};

use super::StoreError;

fn default_ble_auto_connect() -> bool {
    true
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkspaceDto {
    #[serde(default)]
    provider: Option<ProviderDto>,
    #[serde(default = "default_ble_auto_connect")]
    ble_auto_connect: bool,
    #[serde(default, skip_serializing)]
    companion_mode: Option<serde::de::IgnoredAny>,
    #[serde(default, skip_serializing)]
    standby_scratch_file_ids: Vec<u32>,
    #[serde(default, skip_serializing)]
    reclaimed_standby_file_ids: Vec<u32>,
    #[serde(default)]
    migrations: Vec<MigrationDto>,
    #[serde(default)]
    purged_bean_file_ids: Vec<u32>,
    version: u32,
    revision: u64,
    next_operation: u64,
    records: Vec<RecordDto>,
    items: Vec<ItemDto>,
    ask: AskDto,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderDto {
    #[serde(default)]
    meeting_audio_policy: AudioPolicyDto,
    #[serde(default)]
    speech_engine: String,
    #[serde(default)]
    speech_model_id: Option<String>,
    model: String,
    asr_endpoint: String,
    chat_endpoint: String,
    credential: BindingDto,
    retired_credentials: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pending_credentials: Vec<String>,
}
#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AudioPolicyDto {
    CloudAllowed,
    #[default]
    LocalOnly,
}
#[derive(Serialize, Deserialize)]
#[serde(
    tag = "state",
    content = "reference",
    rename_all = "snake_case",
    deny_unknown_fields
)]
enum BindingDto {
    Uninitialized,
    Saved(String),
    Cleared,
}
impl From<ProviderConfiguration> for ProviderDto {
    fn from(p: ProviderConfiguration) -> Self {
        Self {
            meeting_audio_policy: match p.meeting_audio_policy {
                MeetingAudioPolicy::CloudAllowed => AudioPolicyDto::CloudAllowed,
                MeetingAudioPolicy::LocalOnly => AudioPolicyDto::LocalOnly,
            },
            speech_engine: p.speech_engine.as_str().into(),
            speech_model_id: match p.speech_engine {
                SpeechEngine::Downloaded(id) => Some(id),
                _ => None,
            },
            model: p.model,
            asr_endpoint: p.asr_endpoint,
            chat_endpoint: p.chat_endpoint,
            retired_credentials: p.retired_credentials,
            pending_credentials: p.pending_credentials,
            credential: match p.credential {
                CredentialBinding::Uninitialized => BindingDto::Uninitialized,
                CredentialBinding::Saved(r) => BindingDto::Saved(r),
                CredentialBinding::Cleared => BindingDto::Cleared,
            },
        }
    }
}
impl From<ProviderDto> for ProviderConfiguration {
    fn from(p: ProviderDto) -> Self {
        Self {
            meeting_audio_policy: match p.meeting_audio_policy {
                AudioPolicyDto::CloudAllowed => MeetingAudioPolicy::CloudAllowed,
                AudioPolicyDto::LocalOnly => MeetingAudioPolicy::LocalOnly,
            },
            speech_engine: match p.speech_engine.as_str() {
                "cloud" => SpeechEngine::Cloud,
                "downloaded" => SpeechEngine::Downloaded(p.speech_model_id.unwrap_or_default()),
                _ => SpeechEngine::AppleSpeech,
            },
            model: p.model,
            asr_endpoint: p.asr_endpoint,
            chat_endpoint: p.chat_endpoint,
            retired_credentials: p.retired_credentials,
            pending_credentials: p.pending_credentials,
            credential: match p.credential {
                BindingDto::Uninitialized => CredentialBinding::Uninitialized,
                BindingDto::Saved(r) => CredentialBinding::Saved(r),
                BindingDto::Cleared => CredentialBinding::Cleared,
            },
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MigrationDto {
    fingerprint: String,
    archive: String,
    record_ids: Vec<String>,
    pending: Vec<String>,
    summaries: Vec<ImportedSummaryDto>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportedSummaryDto {
    record_id: String,
    slot: String,
    text: String,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RecordDto {
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    project: Option<String>,
    #[serde(default)]
    speech_engine: Option<String>,
    #[serde(default)]
    speech_model_id: Option<String>,
    #[serde(default)]
    all_day_run_id: Option<String>,
    #[serde(default)]
    all_day_ordinal: Option<u64>,
    #[serde(default)]
    capture_lanes: Vec<CaptureLaneDto>,
    #[serde(default)]
    archived: bool,
    #[serde(default)]
    trashed_at_ms: Option<u64>,
    id: String,
    title: String,
    origin: String,
    file_id: u32,
    created_at: u64,
    duration_ms: u64,
    content_revision: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    minutes_revision: Option<u64>,
    segments: Vec<SegmentDto>,
    minutes: Option<String>,
    bookmarks: Vec<u64>,
    highlighted_segments: Vec<u32>,
    #[serde(default, skip_serializing)]
    coarse_place: Option<serde::de::IgnoredAny>,
    #[serde(default, skip_serializing)]
    selected_format: Option<serde::de::IgnoredAny>,
    analysis: AnalysisDto,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    live_summary: Option<AnalysisDto>,
    final_keys: BTreeMap<String, u32>,
    completed_request: Option<KeyDto>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CaptureSpanDto {
    epoch: u64,
    start_ns: u64,
    sample_offset: u64,
    sample_count: u64,
}
impl From<&CaptureSpan> for CaptureSpanDto {
    fn from(s: &CaptureSpan) -> Self {
        Self {
            epoch: s.epoch,
            start_ns: s.start_ns,
            sample_offset: s.sample_offset,
            sample_count: s.sample_count,
        }
    }
}
impl From<CaptureSpanDto> for CaptureSpan {
    fn from(s: CaptureSpanDto) -> Self {
        Self {
            epoch: s.epoch,
            start_ns: s.start_ns,
            sample_offset: s.sample_offset,
            sample_count: s.sample_count,
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct CaptureLaneDto {
    lane: String,
    asset_id: Option<String>,
    sample_rate: Option<u32>,
    duration_ms: u64,
    interruption: Option<String>,
    #[serde(default)]
    timeline: Vec<CaptureSpanDto>,
}
impl From<&CaptureLaneRecord> for CaptureLaneDto {
    fn from(l: &CaptureLaneRecord) -> Self {
        Self {
            lane: l.lane.clone(),
            asset_id: l.asset_id.clone(),
            sample_rate: l.sample_rate,
            duration_ms: l.duration_ms,
            interruption: l.interruption.clone(),
            timeline: l.timeline.iter().map(Into::into).collect(),
        }
    }
}
impl From<CaptureLaneDto> for CaptureLaneRecord {
    fn from(l: CaptureLaneDto) -> Self {
        Self {
            lane: l.lane,
            asset_id: l.asset_id,
            sample_rate: l.sample_rate,
            duration_ms: l.duration_ms,
            interruption: l.interruption,
            timeline: l.timeline.into_iter().map(Into::into).collect(),
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct SegmentDto {
    id: u32,
    text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    original_text: Option<String>,
    start_ms: u64,
    end_ms: u64,
    language: String,
    provider: String,
    speaker: Option<String>,
    translation: Option<String>,
    target_language: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyDto {
    record_id: String,
    attempt: u64,
    input_revision: u64,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", deny_unknown_fields)]
enum AnalysisDto {
    Idle,
    Pending { key: KeyDto, stage: String },
    Ready { input_revision: u64 },
    Failed { key: KeyDto, message: String },
    Interrupted { key: KeyDto },
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RefDto {
    record_id: String,
    segment_id: u32,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ItemDto {
    id: String,
    kind: String,
    text: String,
    sources: Vec<RefDto>,
    review: String,
    completed: bool,
    due: Option<String>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct AskDto {
    id: String,
    created_at: u64,
    messages: Vec<MessageDto>,
    draft: String,
    in_flight: bool,
    scope: Option<String>,
    pending: Option<RequestDto>,
    last_operation: Option<u64>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct MessageDto {
    id: String,
    role: String,
    text: String,
    at: u64,
    sources: Vec<LineDto>,
    status: String,
    grounded: bool,
    via_voice: bool,
    notice: bool,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct LineDto {
    label: String,
    title: String,
    text: String,
    record_id: String,
    start_ms: u64,
    end_ms: Option<u64>,
    line: Option<usize>,
    at: Option<u64>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct RequestDto {
    operation: u64,
    scope: Option<String>,
    question: String,
    system_prompt: String,
    source_text: String,
    instruction: String,
    evidence: Vec<EvidenceDto>,
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct EvidenceDto {
    source: RefDto,
    title: String,
    quote: String,
    start_ms: u64,
}

pub(super) fn encode(workspace: &ProductWorkspace) -> Result<String, StoreError> {
    let state = workspace.export_state();
    let dto = WorkspaceDto {
        provider: Some(state.provider_configuration.into()),
        ble_auto_connect: state.ble_auto_connect,
        companion_mode: None,
        standby_scratch_file_ids: Vec::new(),
        reclaimed_standby_file_ids: Vec::new(),
        migrations: state
            .migrations
            .iter()
            .map(|m| MigrationDto {
                fingerprint: m.fingerprint.clone(),
                archive: m.archive.clone(),
                record_ids: m.record_ids.clone(),
                pending: m.pending.clone(),
                summaries: m
                    .summaries
                    .iter()
                    .map(|s| ImportedSummaryDto {
                        record_id: s.record_id.clone(),
                        slot: s.slot.clone(),
                        text: s.text.clone(),
                    })
                    .collect(),
            })
            .collect(),
        purged_bean_file_ids: state.purged_bean_file_ids.iter().copied().collect(),
        version: 1,
        revision: state.revision,
        next_operation: state.next_operation,
        records: state.records.iter().map(RecordDto::from_record).collect(),
        items: state
            .items
            .iter()
            .map(|item| ItemDto {
                id: item.id.clone(),
                kind: match item.kind {
                    ItemKind::Task => "task",
                    ItemKind::Memory => "memory",
                }
                .to_string(),
                text: item.text.clone(),
                sources: item.sources.iter().map(RefDto::from_source).collect(),
                review: match item.review {
                    ReviewState::Proposed => "proposed",
                    ReviewState::Accepted => "accepted",
                    ReviewState::Dismissed => "dismissed",
                }
                .to_string(),
                completed: item.completed,
                due: item.due.clone(),
            })
            .collect(),
        ask: AskDto {
            id: state.ask_session.id,
            created_at: state.ask_session.created_at_epoch_sec,
            messages: state
                .ask_session
                .messages
                .iter()
                .map(MessageDto::from_message)
                .collect(),
            draft: state.ask_session.draft,
            in_flight: state.ask_session.in_flight,
            scope: encode_scope(&state.ask_scope),
            pending: state.pending_ask.as_ref().map(RequestDto::from_request),
            last_operation: state.last_ask_operation,
        },
    };
    serde_json::to_string(&dto).map_err(|e| invalid(e.to_string()))
}

pub(super) fn decode(raw: &str) -> Result<ProductWorkspace, StoreError> {
    let dto: WorkspaceDto = serde_json::from_str(raw).map_err(|e| invalid(e.to_string()))?;
    if dto.version != 1 {
        return Err(invalid("unsupported workspace version"));
    }
    let _ = dto.companion_mode;
    let mut purged_bean_file_ids: std::collections::BTreeSet<u32> =
        dto.purged_bean_file_ids.into_iter().collect();
    purged_bean_file_ids.extend(
        dto.standby_scratch_file_ids
            .into_iter()
            .chain(dto.reclaimed_standby_file_ids)
            .filter(|&id| id > 0),
    );
    let state = WorkspaceState {
        provider_configuration: dto.provider.map(Into::into).unwrap_or_default(),
        ble_auto_connect: dto.ble_auto_connect,
        migrations: dto
            .migrations
            .into_iter()
            .map(|m| MigrationReceipt {
                fingerprint: m.fingerprint,
                archive: m.archive,
                record_ids: m.record_ids,
                pending: m.pending,
                summaries: m
                    .summaries
                    .into_iter()
                    .map(|s| ImportedSummary {
                        record_id: s.record_id,
                        slot: s.slot,
                        text: s.text,
                    })
                    .collect(),
            })
            .collect(),
        purged_bean_file_ids,
        revision: dto.revision,
        next_operation: dto.next_operation,
        records: dto
            .records
            .into_iter()
            .map(RecordDto::into_record)
            .collect::<Result<_, _>>()?,
        items: dto
            .items
            .into_iter()
            .map(ItemDto::into_item)
            .collect::<Result<_, _>>()?,
        ask_session: AskSession {
            id: dto.ask.id,
            created_at_epoch_sec: dto.ask.created_at,
            draft: dto.ask.draft,
            in_flight: dto.ask.in_flight,
            messages: dto
                .ask
                .messages
                .into_iter()
                .map(MessageDto::into_message)
                .collect::<Result<_, _>>()?,
        },
        ask_scope: decode_scope(dto.ask.scope),
        pending_ask: dto.ask.pending.map(RequestDto::into_request).transpose()?,
        last_ask_operation: dto.ask.last_operation,
    };
    ProductWorkspace::restore(state).map_err(|e| invalid(e.to_string()))
}

impl RecordDto {
    fn from_record(record: &ProductRecord) -> Self {
        let a = &record.aggregate;
        Self {
            mode: Some(record.mode.as_str().to_owned()),
            project: record.project.clone(),
            speech_engine: record.speech_engine.as_ref().map(|e| e.as_str().into()),
            speech_model_id: match &record.speech_engine {
                Some(SpeechEngine::Downloaded(id)) => Some(id.clone()),
                _ => None,
            },
            all_day_run_id: record.all_day.as_ref().map(|s| s.run_id.clone()),
            all_day_ordinal: record.all_day.as_ref().map(|s| s.ordinal),
            capture_lanes: record.capture_lanes.iter().map(Into::into).collect(),
            archived: record.is_archived(),
            trashed_at_ms: record.retention().trashed_at_ms(),
            id: a.recording_id.clone(),
            title: record.title.clone(),
            origin: match record.origin {
                RecordOrigin::Microphone => "microphone",
                RecordOrigin::Bean => "bean",
                RecordOrigin::ImportedAudio => "audio",
                RecordOrigin::ImportedText => "text",
                RecordOrigin::Note => "note",
            }
            .to_string(),
            file_id: a.file_id,
            created_at: a.created_at_epoch_sec,
            duration_ms: a.duration_ms,
            content_revision: record.content_revision,
            minutes_revision: record.minutes_revision(),
            segments: a
                .spine
                .segments()
                .iter()
                .map(|s| SegmentDto {
                    id: s.id.ordinal(),
                    text: s.text.clone(),
                    original_text: s.original_text.clone(),
                    start_ms: s.start_ms,
                    end_ms: s.end_ms,
                    language: s.source_language.clone(),
                    provider: s.provider.clone(),
                    speaker: s.speaker.clone(),
                    translation: s.translation.clone(),
                    target_language: s.target_language.clone(),
                })
                .collect(),
            minutes: a.minutes.as_ref().map(encode_meeting_minutes_json),
            bookmarks: a.bookmarks.clone(),
            coarse_place: None,
            selected_format: None,
            analysis: AnalysisDto::from_analysis(&record.analysis),
            live_summary: (record.live_summary != AnalysisState::Idle)
                .then(|| AnalysisDto::from_analysis(&record.live_summary)),
            highlighted_segments: record
                .highlighted_segments
                .iter()
                .map(|s| s.ordinal())
                .collect(),
            final_keys: record
                .final_keys()
                .iter()
                .map(|(k, v)| (k.clone(), v.ordinal()))
                .collect(),
            completed_request: record.completed_request().map(KeyDto::from_key),
        }
    }

    fn into_record(self) -> Result<ProductRecord, StoreError> {
        let _ = (self.coarse_place, self.selected_format);
        let retention = RecordRetention::from_persisted(self.archived, self.trashed_at_ms)
            .map_err(|e| invalid(e.to_string()))?;
        let origin = match self.origin.as_str() {
            "microphone" => RecordOrigin::Microphone,
            "bean" => RecordOrigin::Bean,
            "audio" => RecordOrigin::ImportedAudio,
            "text" => RecordOrigin::ImportedText,
            "note" => RecordOrigin::Note,
            _ => return Err(invalid("invalid recording origin")),
        };
        let mut a =
            RecordingAggregate::new(self.id, self.file_id, self.created_at, self.duration_ms);
        for (index, segment) in self.segments.into_iter().enumerate() {
            if segment.id as usize != index + 1
                || segment.end_ms < segment.start_ms
                || segment.end_ms > a.duration_ms
            {
                return Err(invalid("invalid transcript sequence or duration"));
            }
            let id = a
                .spine
                .append_segment(
                    segment.text,
                    segment.start_ms,
                    segment.end_ms,
                    segment.language,
                    segment.provider,
                )
                .ok_or_else(|| invalid("empty transcript segment"))?;
            if let Some(orig) = segment.original_text {
                if !a.spine.restore_original_text(id, orig) {
                    return Err(invalid("invalid segment original_text"));
                }
            }
            if let Some(speaker) = segment.speaker.as_deref().and_then(sanitize_speaker_lossy) {
                a.spine.set_speaker(id, Some(speaker));
            }
            if let Some(translation) = segment.translation {
                a.spine.set_translation(
                    id,
                    translation,
                    segment.target_language.unwrap_or_default(),
                );
            }
        }
        let analysis = self.analysis.into_analysis()?;
        let minutes_revision = match self.minutes {
            Some(raw) => {
                let rev = self.minutes_revision.unwrap_or(match &analysis {
                    AnalysisState::Ready { input_revision } => *input_revision,
                    _ => self.content_revision,
                });
                a.minutes = Some(
                    parse_persisted_meeting_minutes_json(
                        &raw,
                        &a.spine,
                        rev == self.content_revision,
                    )
                    .map_err(|e| invalid(format!("invalid minutes: {e:?}")))?,
                );
                Some(rev)
            }
            None => self.minutes_revision,
        };
        for timestamp in self.bookmarks {
            a.add_bookmark(if a.duration_ms > 0 {
                timestamp.min(a.duration_ms)
            } else {
                timestamp
            });
        }
        let final_keys = self
            .final_keys
            .into_iter()
            .map(|(key, id)| {
                Ok((
                    key,
                    SegmentId::new(id).ok_or_else(|| invalid("invalid final segment id"))?,
                ))
            })
            .collect::<Result<_, StoreError>>()?;
        let highlighted_segments = self
            .highlighted_segments
            .into_iter()
            .map(|id| SegmentId::new(id).ok_or_else(|| invalid("invalid highlight segment id")))
            .collect::<Result<_, _>>()?;
        let mut record = ProductRecord::restore(
            a,
            self.title,
            origin,
            analysis,
            self.content_revision,
            minutes_revision,
            highlighted_segments,
            final_keys,
            self.completed_request.map(KeyDto::into_key),
        )
        .map_err(|e| invalid(e.to_string()))?;
        record
            .restore_live_summary(
                self.live_summary
                    .map(AnalysisDto::into_analysis)
                    .transpose()?
                    .unwrap_or_default(),
            )
            .map_err(|e| invalid(e.to_string()))?;
        record
            .restore_capture_lanes(self.capture_lanes.into_iter().map(Into::into).collect())
            .map_err(|e| invalid(e.to_string()))?;
        record.speech_engine = match self.speech_engine.as_deref() {
            Some("apple_speech") => Some(SpeechEngine::AppleSpeech),
            Some("cloud") => Some(SpeechEngine::Cloud),
            Some("downloaded") => Some(SpeechEngine::Downloaded(
                self.speech_model_id
                    .ok_or_else(|| invalid("missing speech model"))?,
            )),
            None => None,
            _ => return Err(invalid("invalid speech engine")),
        };
        let parsed_mode = match self.mode.as_deref().map(str::trim) {
            Some("dictation") => Some(RecordMode::QuickNote),
            Some(raw_mode) => {
                Some(RecordMode::parse(raw_mode).ok_or_else(|| invalid("invalid recording mode"))?)
            }
            None => None,
        };
        let project = self
            .project
            .map(|raw_project| raw_project.trim().to_owned())
            .filter(|trimmed| !trimmed.is_empty());
        let all_day = match (self.all_day_run_id, self.all_day_ordinal) {
            (Some(run_id), Some(ordinal)) if !run_id.is_empty() && ordinal > 0 => {
                Some(AllDaySegment { run_id, ordinal })
            }
            (None, None) => None,
            _ => return Err(invalid("invalid all-day grouping")),
        };
        record.mode = if all_day.is_some() {
            RecordMode::AllDay
        } else {
            parsed_mode.unwrap_or(RecordMode::QuickNote)
        };
        record.project = project;
        record.all_day = all_day;
        record.restore_retention(retention);
        Ok(record)
    }
}

impl KeyDto {
    fn from_key(key: &RequestKey) -> Self {
        Self {
            record_id: key.record_id.clone(),
            attempt: key.attempt,
            input_revision: key.input_revision,
        }
    }
    fn into_key(self) -> RequestKey {
        RequestKey {
            record_id: self.record_id,
            attempt: self.attempt,
            input_revision: self.input_revision,
        }
    }
}
impl AnalysisDto {
    fn from_analysis(a: &AnalysisState) -> Self {
        match a {
            AnalysisState::Idle => Self::Idle,
            AnalysisState::Pending { key, stage } => Self::Pending {
                key: KeyDto::from_key(key),
                stage: match stage {
                    AnalysisStage::Transcribing => "transcribing",
                    AnalysisStage::Summarizing => "summarizing",
                }
                .to_string(),
            },
            AnalysisState::Ready { input_revision } => Self::Ready {
                input_revision: *input_revision,
            },
            AnalysisState::Failed { key, message } => Self::Failed {
                key: KeyDto::from_key(key),
                message: message.clone(),
            },
            AnalysisState::Interrupted { key } => Self::Interrupted {
                key: KeyDto::from_key(key),
            },
        }
    }
    fn into_analysis(self) -> Result<AnalysisState, StoreError> {
        Ok(match self {
            Self::Idle => AnalysisState::Idle,
            Self::Pending { key, stage } => AnalysisState::Pending {
                key: key.into_key(),
                stage: match stage.as_str() {
                    "transcribing" => AnalysisStage::Transcribing,
                    "summarizing" => AnalysisStage::Summarizing,
                    _ => return Err(invalid("invalid analysis stage")),
                },
            },
            Self::Ready { input_revision } => AnalysisState::Ready { input_revision },
            Self::Failed { key, message } => AnalysisState::Failed {
                key: key.into_key(),
                message,
            },
            Self::Interrupted { key } => AnalysisState::Interrupted {
                key: key.into_key(),
            },
        })
    }
}
impl RefDto {
    fn from_source(source: &SourceRef) -> Self {
        Self {
            record_id: source.record_id.clone(),
            segment_id: source.segment_id.ordinal(),
        }
    }
    fn into_source(self) -> Result<SourceRef, StoreError> {
        Ok(SourceRef {
            record_id: self.record_id,
            segment_id: SegmentId::new(self.segment_id)
                .ok_or_else(|| invalid("invalid source segment id"))?,
        })
    }
}
impl ItemDto {
    fn into_item(self) -> Result<SourcedItem, StoreError> {
        Ok(SourcedItem {
            id: self.id,
            kind: match self.kind.as_str() {
                "task" => ItemKind::Task,
                "memory" => ItemKind::Memory,
                _ => return Err(invalid("invalid item kind")),
            },
            text: self.text,
            sources: self
                .sources
                .into_iter()
                .map(RefDto::into_source)
                .collect::<Result<_, _>>()?,
            review: match self.review.as_str() {
                "proposed" => ReviewState::Proposed,
                "accepted" => ReviewState::Accepted,
                "dismissed" => ReviewState::Dismissed,
                _ => return Err(invalid("invalid review state")),
            },
            completed: self.completed,
            due: self.due,
        })
    }
}
impl MessageDto {
    fn from_message(message: &AskMessage) -> Self {
        Self {
            id: message.id.clone(),
            role: match message.role {
                AskRole::User => "user",
                AskRole::Koe => "assistant",
            }
            .to_string(),
            text: message.text.clone(),
            at: message.at_epoch_sec,
            sources: message.sources.iter().map(LineDto::from_line).collect(),
            status: match message.status {
                AskStatus::Done => "done",
                AskStatus::Pending => "pending",
                AskStatus::Failed => "failed",
            }
            .to_string(),
            grounded: message.grounded,
            via_voice: message.via_voice,
            notice: message.notice,
        }
    }
    fn into_message(self) -> Result<AskMessage, StoreError> {
        Ok(AskMessage {
            id: self.id,
            role: match self.role.as_str() {
                "user" => AskRole::User,
                "assistant" => AskRole::Koe,
                _ => return Err(invalid("invalid message role")),
            },
            text: self.text,
            at_epoch_sec: self.at,
            sources: self
                .sources
                .into_iter()
                .map(LineDto::into_line)
                .collect::<Result<_, _>>()?,
            status: match self.status.as_str() {
                "done" => AskStatus::Done,
                "pending" => AskStatus::Pending,
                "failed" => AskStatus::Failed,
                _ => return Err(invalid("invalid message status")),
            },
            grounded: self.grounded,
            via_voice: self.via_voice,
            notice: self.notice,
        })
    }
}
impl LineDto {
    fn from_line(line: &SourceLine) -> Self {
        Self {
            label: line.label.clone(),
            title: line.title.clone(),
            text: line.text.clone(),
            record_id: line.source.recording_key.clone(),
            start_ms: line.source.start_ms,
            end_ms: line.source.end_ms,
            line: Some(line.source.segment_id.zero_based_index()),
            at: line.at_epoch_sec,
        }
    }
    fn into_line(self) -> Result<SourceLine, StoreError> {
        let segment_id = self
            .line
            .and_then(SegmentId::from_zero_based)
            .ok_or_else(|| invalid("invalid source line segment"))?;
        Ok(SourceLine {
            label: self.label,
            title: self.title,
            text: self.text,
            source: SourcePointer {
                recording_key: self.record_id,
                path: None,
                start_ms: self.start_ms,
                end_ms: self.end_ms,
                segment_id,
            },
            at_epoch_sec: self.at,
        })
    }
}
impl RequestDto {
    fn from_request(request: &AskRequest) -> Self {
        Self {
            operation: request.operation,
            scope: encode_scope(&request.scope),
            question: request.question.clone(),
            system_prompt: request.system_prompt.clone(),
            source_text: request.source_text.clone(),
            instruction: request.instruction.clone(),
            evidence: request
                .evidence
                .iter()
                .map(|e| EvidenceDto {
                    source: RefDto::from_source(&e.source),
                    title: e.title.clone(),
                    quote: e.quote.clone(),
                    start_ms: e.start_ms,
                })
                .collect(),
        }
    }
    fn into_request(self) -> Result<AskRequest, StoreError> {
        Ok(AskRequest {
            operation: self.operation,
            scope: decode_scope(self.scope),
            question: self.question,
            system_prompt: self.system_prompt,
            source_text: self.source_text,
            instruction: self.instruction,
            evidence: self
                .evidence
                .into_iter()
                .map(|e| {
                    Ok(Evidence {
                        source: e.source.into_source()?,
                        title: e.title,
                        quote: e.quote,
                        start_ms: e.start_ms,
                    })
                })
                .collect::<Result<_, StoreError>>()?,
        })
    }
}
fn encode_scope(scope: &SearchScope) -> Option<String> {
    match scope {
        SearchScope::All => None,
        SearchScope::Record(id) => Some(id.clone()),
    }
}
fn decode_scope(scope: Option<String>) -> SearchScope {
    scope.map_or(SearchScope::All, SearchScope::Record)
}
fn invalid(message: impl Into<String>) -> StoreError {
    StoreError::InvalidData(message.into())
}
