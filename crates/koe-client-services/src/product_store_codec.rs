use std::collections::{BTreeMap, BTreeSet};

use koe_engine::context::{AskMessage, AskRole, AskSession, AskStatus, SourceLine, SourcePointer};
use koe_engine::domain::{MeetingMinutes, RecordingAggregate, SegmentId, UtteranceSegment};
use koe_engine::minutes::encode_meeting_minutes_json;
use koe_engine::product::*;
use serde::ser::{SerializeMap, SerializeSeq, Serializer};
use serde::{Deserialize, Serialize};

use super::StoreError;

fn default_ble_auto_connect() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct WorkspaceDto {
    #[serde(default)]
    provider: Option<ProviderDto>,
    #[serde(default = "default_ble_auto_connect")]
    ble_auto_connect: bool,
    #[serde(default)]
    companion_mode: Option<serde::de::IgnoredAny>,
    #[serde(default)]
    standby_scratch_file_ids: Vec<u32>,
    #[serde(default)]
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ProviderDto {
    #[serde(default)]
    meeting_audio_policy: AudioPolicyDto,
    #[serde(default)]
    speech_engine: String,
    #[serde(default)]
    speech_model_id: Option<String>,
    #[serde(default)]
    asr_provider: Option<String>,
    #[serde(default)]
    asr_model: Option<String>,
    #[serde(default)]
    llm_provider: Option<String>,
    #[serde(default)]
    enable_thinking: bool,
    #[serde(default)]
    qwen_workspace_id: String,
    model: String,
    asr_endpoint: String,
    chat_endpoint: String,
    credential: BindingDto,
    #[serde(default)]
    deepseek_credential: Option<BindingDto>,
    retired_credentials: Vec<String>,
    #[serde(default)]
    pending_credentials: Vec<String>,
    #[serde(default)]
    minutes_vocabulary: Vec<String>,
}

#[derive(Default, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum AudioPolicyDto {
    CloudAllowed,
    #[default]
    LocalOnly,
}

#[derive(Deserialize)]
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

impl From<BindingDto> for CredentialBinding {
    fn from(dto: BindingDto) -> Self {
        match dto {
            BindingDto::Uninitialized => Self::Uninitialized,
            BindingDto::Saved(r) => Self::Saved(r),
            BindingDto::Cleared => Self::Cleared,
        }
    }
}

impl From<ProviderDto> for ProviderConfiguration {
    fn from(p: ProviderDto) -> Self {
        let asr_provider = p
            .asr_provider
            .as_deref()
            .and_then(CloudAsrProvider::parse)
            .unwrap_or_else(|| ProviderConfiguration::infer_asr_provider(&p.asr_endpoint));
        let raw_llm_provider = p
            .llm_provider
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty());
        let legacy_qwen_llm = raw_llm_provider.is_some_and(|raw| raw.eq_ignore_ascii_case("qwen"))
            || (raw_llm_provider.is_none()
                && ProviderConfiguration::is_legacy_qwen_chat_endpoint(&p.chat_endpoint));
        let (llm_provider, model, chat_endpoint) = if legacy_qwen_llm {
            (
                LlmProvider::DeepSeek,
                DEFAULT_TEXT_MODEL.into(),
                DEFAULT_DEEPSEEK_CHAT_URL.into(),
            )
        } else {
            let llm_provider = raw_llm_provider
                .and_then(LlmProvider::parse)
                .unwrap_or_else(|| ProviderConfiguration::infer_llm_provider(&p.chat_endpoint));
            (llm_provider, p.model, p.chat_endpoint)
        };
        let asr_model = p.asr_model.unwrap_or_else(|| {
            if asr_provider == CloudAsrProvider::DeepSeek {
                String::new()
            } else {
                DEFAULT_ASR_MODEL.into()
            }
        });
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
            asr_provider,
            asr_model,
            llm_provider,
            enable_thinking: p.enable_thinking,
            qwen_workspace_id: p.qwen_workspace_id,
            model,
            asr_endpoint: p.asr_endpoint,
            chat_endpoint,
            retired_credentials: p.retired_credentials,
            pending_credentials: p.pending_credentials,
            minutes_vocabulary: p.minutes_vocabulary,
            credential: p.credential.into(),
            deepseek_credential: p
                .deepseek_credential
                .map(Into::into)
                .unwrap_or(CredentialBinding::Uninitialized),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MigrationDto {
    fingerprint: String,
    archive: String,
    record_ids: Vec<String>,
    pending: Vec<String>,
    summaries: Vec<ImportedSummaryDto>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ImportedSummaryDto {
    record_id: String,
    slot: String,
    text: String,
}

#[derive(Deserialize)]
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
    #[serde(default)]
    minutes_revision: Option<u64>,
    segments: Vec<SegmentDto>,
    minutes: Option<String>,
    bookmarks: Vec<u64>,
    highlighted_segments: Vec<u32>,
    #[serde(default)]
    coarse_place: Option<serde::de::IgnoredAny>,
    #[serde(default)]
    selected_format: Option<serde::de::IgnoredAny>,
    analysis: AnalysisDto,
    #[serde(default)]
    live_summary: Option<AnalysisDto>,
    final_keys: BTreeMap<String, u32>,
    completed_request: Option<KeyDto>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CaptureSpanDto {
    epoch: u64,
    start_ns: u64,
    sample_offset: u64,
    sample_count: u64,
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

#[derive(Deserialize)]
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SegmentDto {
    id: u32,
    text: String,
    #[serde(default)]
    original_text: Option<String>,
    start_ms: u64,
    end_ms: u64,
    language: String,
    provider: String,
    speaker: Option<String>,
    translation: Option<String>,
    target_language: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct KeyDto {
    record_id: String,
    attempt: u64,
    input_revision: u64,
}

#[derive(Deserialize)]
#[serde(tag = "state", rename_all = "snake_case", deny_unknown_fields)]
enum AnalysisDto {
    Idle,
    Pending { key: KeyDto, stage: String },
    Ready { input_revision: u64 },
    Failed { key: KeyDto, message: String },
    Interrupted { key: KeyDto },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RefDto {
    record_id: String,
    segment_id: u32,
}

#[derive(Deserialize)]
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

#[derive(Deserialize)]
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

#[derive(Deserialize)]
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

#[derive(Deserialize)]
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

#[derive(Deserialize)]
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

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct EvidenceDto {
    source: RefDto,
    title: String,
    quote: String,
    start_ms: u64,
}

#[derive(Serialize)]
struct PersistedWorkspaceRef<'a> {
    provider: Option<ProviderRef<'a>>,
    ble_auto_connect: bool,
    migrations: MigrationsSeq<'a>,
    purged_bean_file_ids: &'a BTreeSet<u32>,
    version: u32,
    revision: u64,
    next_operation: u64,
    records: RecordsSeq<'a>,
    items: ItemsSeq<'a>,
    ask: AskRef<'a>,
}

#[derive(Serialize)]
struct ProviderRef<'a> {
    meeting_audio_policy: AudioPolicyDto,
    speech_engine: &'static str,
    speech_model_id: Option<&'a str>,
    asr_provider: Option<&'static str>,
    asr_model: Option<&'a str>,
    llm_provider: Option<&'static str>,
    enable_thinking: bool,
    qwen_workspace_id: &'a str,
    model: &'a str,
    asr_endpoint: &'a str,
    chat_endpoint: &'a str,
    credential: BindingRef<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    deepseek_credential: Option<BindingRef<'a>>,
    retired_credentials: &'a [String],
    #[serde(skip_serializing_if = "<[String]>::is_empty")]
    pending_credentials: &'a [String],
    #[serde(skip_serializing_if = "<[String]>::is_empty")]
    minutes_vocabulary: &'a [String],
}

impl<'a> ProviderRef<'a> {
    fn from_config(p: &'a ProviderConfiguration) -> Self {
        Self {
            meeting_audio_policy: match p.meeting_audio_policy {
                MeetingAudioPolicy::CloudAllowed => AudioPolicyDto::CloudAllowed,
                MeetingAudioPolicy::LocalOnly => AudioPolicyDto::LocalOnly,
            },
            speech_engine: p.speech_engine.as_str(),
            speech_model_id: match &p.speech_engine {
                SpeechEngine::Downloaded(id) => Some(id.as_str()),
                _ => None,
            },
            asr_provider: Some(p.asr_provider.as_str()),
            asr_model: Some(p.asr_model.as_str()),
            llm_provider: Some(p.llm_provider.as_str()),
            enable_thinking: p.enable_thinking,
            qwen_workspace_id: p.qwen_workspace_id.as_str(),
            model: p.model.as_str(),
            asr_endpoint: p.asr_endpoint.as_str(),
            chat_endpoint: p.chat_endpoint.as_str(),
            credential: BindingRef::from_binding(&p.credential),
            deepseek_credential: match &p.deepseek_credential {
                CredentialBinding::Uninitialized => None,
                other => Some(BindingRef::from_binding(other)),
            },
            retired_credentials: p.retired_credentials.as_slice(),
            pending_credentials: p.pending_credentials.as_slice(),
            minutes_vocabulary: p.minutes_vocabulary.as_slice(),
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "state", content = "reference", rename_all = "snake_case")]
enum BindingRef<'a> {
    Uninitialized,
    Saved(&'a str),
    Cleared,
}

impl<'a> BindingRef<'a> {
    fn from_binding(binding: &'a CredentialBinding) -> Self {
        match binding {
            CredentialBinding::Uninitialized => Self::Uninitialized,
            CredentialBinding::Saved(r) => Self::Saved(r.as_str()),
            CredentialBinding::Cleared => Self::Cleared,
        }
    }
}

struct MigrationsSeq<'a>(&'a [MigrationReceipt]);
impl Serialize for MigrationsSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for m in self.0 {
            seq.serialize_element(&MigrationRef {
                fingerprint: m.fingerprint.as_str(),
                archive: m.archive.as_str(),
                record_ids: m.record_ids.as_slice(),
                pending: m.pending.as_slice(),
                summaries: ImportedSummariesSeq(m.summaries.as_slice()),
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct MigrationRef<'a> {
    fingerprint: &'a str,
    archive: &'a str,
    record_ids: &'a [String],
    pending: &'a [String],
    summaries: ImportedSummariesSeq<'a>,
}

struct ImportedSummariesSeq<'a>(&'a [ImportedSummary]);
impl Serialize for ImportedSummariesSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for s in self.0 {
            seq.serialize_element(&ImportedSummaryRef {
                record_id: s.record_id.as_str(),
                slot: s.slot.as_str(),
                text: s.text.as_str(),
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct ImportedSummaryRef<'a> {
    record_id: &'a str,
    slot: &'a str,
    text: &'a str,
}

struct RecordsSeq<'a>(&'a BTreeMap<RecordId, ProductRecord>);
impl Serialize for RecordsSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for record in self.0.values() {
            seq.serialize_element(&RecordRef::from_record(record))?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct RecordRef<'a> {
    mode: Option<&'static str>,
    project: Option<&'a str>,
    speech_engine: Option<&'static str>,
    speech_model_id: Option<&'a str>,
    all_day_run_id: Option<&'a str>,
    all_day_ordinal: Option<u64>,
    capture_lanes: CaptureLanesSeq<'a>,
    archived: bool,
    trashed_at_ms: Option<u64>,
    id: &'a str,
    title: &'a str,
    origin: &'static str,
    file_id: u32,
    created_at: u64,
    duration_ms: u64,
    content_revision: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    minutes_revision: Option<u64>,
    segments: SegmentsSeq<'a>,
    minutes: MinutesJsonRef<'a>,
    bookmarks: &'a [u64],
    highlighted_segments: HighlightedSegmentsSeq<'a>,
    analysis: AnalysisRef<'a>,
    #[serde(skip_serializing_if = "Option::is_none")]
    live_summary: Option<AnalysisRef<'a>>,
    final_keys: FinalKeysMap<'a>,
    completed_request: Option<KeyRef<'a>>,
}

impl<'a> RecordRef<'a> {
    fn from_record(record: &'a ProductRecord) -> Self {
        let a = &record.aggregate;
        Self {
            mode: Some(record.mode.as_str()),
            project: record.project.as_deref(),
            speech_engine: record.speech_engine.as_ref().map(SpeechEngine::as_str),
            speech_model_id: match &record.speech_engine {
                Some(SpeechEngine::Downloaded(id)) => Some(id.as_str()),
                _ => None,
            },
            all_day_run_id: record.all_day.as_ref().map(|s| s.run_id.as_str()),
            all_day_ordinal: record.all_day.as_ref().map(|s| s.ordinal),
            capture_lanes: CaptureLanesSeq(record.capture_lanes.as_slice()),
            archived: record.is_archived(),
            trashed_at_ms: record.retention().trashed_at_ms(),
            id: a.recording_id.as_str(),
            title: record.title.as_str(),
            origin: match record.origin {
                RecordOrigin::Microphone => "microphone",
                RecordOrigin::Bean => "bean",
                RecordOrigin::ImportedAudio => "audio",
                RecordOrigin::ImportedText => "text",
                RecordOrigin::Note => "note",
            },
            file_id: a.file_id,
            created_at: a.created_at_epoch_sec,
            duration_ms: a.duration_ms,
            content_revision: record.content_revision,
            minutes_revision: record.minutes_revision(),
            segments: SegmentsSeq(a.spine.segments()),
            minutes: MinutesJsonRef(a.minutes.as_ref()),
            bookmarks: a.bookmarks.as_slice(),
            highlighted_segments: HighlightedSegmentsSeq(&record.highlighted_segments),
            analysis: AnalysisRef::from_analysis(&record.analysis),
            live_summary: (record.live_summary != AnalysisState::Idle)
                .then(|| AnalysisRef::from_analysis(&record.live_summary)),
            final_keys: FinalKeysMap(record.final_keys()),
            completed_request: record.completed_request().map(KeyRef::from_key),
        }
    }
}

struct CaptureLanesSeq<'a>(&'a [CaptureLaneRecord]);
impl Serialize for CaptureLanesSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for l in self.0 {
            seq.serialize_element(&CaptureLaneRef {
                lane: l.lane.as_str(),
                asset_id: l.asset_id.as_deref(),
                sample_rate: l.sample_rate,
                duration_ms: l.duration_ms,
                interruption: l.interruption.as_deref(),
                timeline: CaptureSpansSeq(l.timeline.as_slice()),
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct CaptureLaneRef<'a> {
    lane: &'a str,
    asset_id: Option<&'a str>,
    sample_rate: Option<u32>,
    duration_ms: u64,
    interruption: Option<&'a str>,
    timeline: CaptureSpansSeq<'a>,
}

struct CaptureSpansSeq<'a>(&'a [CaptureSpan]);
impl Serialize for CaptureSpansSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for s in self.0 {
            seq.serialize_element(&CaptureSpanRef {
                epoch: s.epoch,
                start_ns: s.start_ns,
                sample_offset: s.sample_offset,
                sample_count: s.sample_count,
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct CaptureSpanRef {
    epoch: u64,
    start_ns: u64,
    sample_offset: u64,
    sample_count: u64,
}

struct SegmentsSeq<'a>(&'a [UtteranceSegment]);
impl Serialize for SegmentsSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for s in self.0 {
            seq.serialize_element(&SegmentRef {
                id: s.id.ordinal(),
                text: s.text.as_str(),
                original_text: s.original_text.as_deref(),
                start_ms: s.start_ms,
                end_ms: s.end_ms,
                language: s.source_language.as_str(),
                provider: s.provider.as_str(),
                speaker: s.speaker.as_deref(),
                translation: s.translation.as_deref(),
                target_language: s.target_language.as_deref(),
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct SegmentRef<'a> {
    id: u32,
    text: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    original_text: Option<&'a str>,
    start_ms: u64,
    end_ms: u64,
    language: &'a str,
    provider: &'a str,
    speaker: Option<&'a str>,
    translation: Option<&'a str>,
    target_language: Option<&'a str>,
}

struct MinutesJsonRef<'a>(Option<&'a MeetingMinutes>);
impl Serialize for MinutesJsonRef<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        match self.0 {
            Some(minutes) => serializer.serialize_str(&encode_meeting_minutes_json(minutes)),
            None => serializer.serialize_none(),
        }
    }
}

struct HighlightedSegmentsSeq<'a>(&'a BTreeSet<SegmentId>);
impl Serialize for HighlightedSegmentsSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for s in self.0 {
            seq.serialize_element(&s.ordinal())?;
        }
        seq.end()
    }
}

struct FinalKeysMap<'a>(&'a BTreeMap<String, SegmentId>);
impl Serialize for FinalKeysMap<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(self.0.len()))?;
        for (k, v) in self.0 {
            map.serialize_entry(k.as_str(), &v.ordinal())?;
        }
        map.end()
    }
}

#[derive(Serialize)]
struct KeyRef<'a> {
    record_id: &'a str,
    attempt: u64,
    input_revision: u64,
}

impl<'a> KeyRef<'a> {
    fn from_key(key: &'a RequestKey) -> Self {
        Self {
            record_id: key.record_id.as_str(),
            attempt: key.attempt,
            input_revision: key.input_revision,
        }
    }
}

#[derive(Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum AnalysisRef<'a> {
    Idle,
    Pending { key: KeyRef<'a>, stage: &'static str },
    Ready { input_revision: u64 },
    Failed { key: KeyRef<'a>, message: &'a str },
    Interrupted { key: KeyRef<'a> },
}

impl<'a> AnalysisRef<'a> {
    fn from_analysis(a: &'a AnalysisState) -> Self {
        match a {
            AnalysisState::Idle => Self::Idle,
            AnalysisState::Pending { key, stage } => Self::Pending {
                key: KeyRef::from_key(key),
                stage: match stage {
                    AnalysisStage::Transcribing => "transcribing",
                    AnalysisStage::Summarizing => "summarizing",
                },
            },
            AnalysisState::Ready { input_revision } => Self::Ready {
                input_revision: *input_revision,
            },
            AnalysisState::Failed { key, message } => Self::Failed {
                key: KeyRef::from_key(key),
                message: message.as_str(),
            },
            AnalysisState::Interrupted { key } => Self::Interrupted {
                key: KeyRef::from_key(key),
            },
        }
    }
}

struct ItemsSeq<'a>(&'a BTreeMap<String, SourcedItem>);
impl Serialize for ItemsSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for item in self.0.values() {
            seq.serialize_element(&ItemRef {
                id: item.id.as_str(),
                kind: match item.kind {
                    ItemKind::Task => "task",
                    ItemKind::Memory => "memory",
                },
                text: item.text.as_str(),
                sources: SourcesSeq(item.sources.as_slice()),
                review: match item.review {
                    ReviewState::Proposed => "proposed",
                    ReviewState::Accepted => "accepted",
                    ReviewState::Dismissed => "dismissed",
                },
                completed: item.completed,
                due: item.due.as_deref(),
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct ItemRef<'a> {
    id: &'a str,
    kind: &'static str,
    text: &'a str,
    sources: SourcesSeq<'a>,
    review: &'static str,
    completed: bool,
    due: Option<&'a str>,
}

struct SourcesSeq<'a>(&'a [SourceRef]);
impl Serialize for SourcesSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for source in self.0 {
            seq.serialize_element(&RefRef::from_source(source))?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct RefRef<'a> {
    record_id: &'a str,
    segment_id: u32,
}

impl<'a> RefRef<'a> {
    fn from_source(source: &'a SourceRef) -> Self {
        Self {
            record_id: source.record_id.as_str(),
            segment_id: source.segment_id.ordinal(),
        }
    }
}

#[derive(Serialize)]
struct AskRef<'a> {
    id: &'a str,
    created_at: u64,
    messages: MessagesSeq<'a>,
    draft: &'a str,
    in_flight: bool,
    scope: Option<&'a str>,
    pending: Option<RequestRef<'a>>,
    last_operation: Option<u64>,
}

struct MessagesSeq<'a>(&'a [AskMessage]);
impl Serialize for MessagesSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for message in self.0 {
            seq.serialize_element(&MessageRef {
                id: message.id.as_str(),
                role: match message.role {
                    AskRole::User => "user",
                    AskRole::Koe => "assistant",
                },
                text: message.text.as_str(),
                at: message.at_epoch_sec,
                sources: LinesSeq(message.sources.as_slice()),
                status: match message.status {
                    AskStatus::Done => "done",
                    AskStatus::Pending => "pending",
                    AskStatus::Failed => "failed",
                },
                grounded: message.grounded,
                via_voice: message.via_voice,
                notice: message.notice,
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct MessageRef<'a> {
    id: &'a str,
    role: &'static str,
    text: &'a str,
    at: u64,
    sources: LinesSeq<'a>,
    status: &'static str,
    grounded: bool,
    via_voice: bool,
    notice: bool,
}

struct LinesSeq<'a>(&'a [SourceLine]);
impl Serialize for LinesSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for line in self.0 {
            seq.serialize_element(&LineRef {
                label: line.label.as_str(),
                title: line.title.as_str(),
                text: line.text.as_str(),
                record_id: line.source.recording_key.as_str(),
                start_ms: line.source.start_ms,
                end_ms: line.source.end_ms,
                line: Some(line.source.segment_id.zero_based_index()),
                at: line.at_epoch_sec,
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct LineRef<'a> {
    label: &'a str,
    title: &'a str,
    text: &'a str,
    record_id: &'a str,
    start_ms: u64,
    end_ms: Option<u64>,
    line: Option<usize>,
    at: Option<u64>,
}

#[derive(Serialize)]
struct RequestRef<'a> {
    operation: u64,
    scope: Option<&'a str>,
    question: &'a str,
    system_prompt: &'a str,
    source_text: &'a str,
    instruction: &'a str,
    evidence: EvidenceSeq<'a>,
}

impl<'a> RequestRef<'a> {
    fn from_request(request: &'a AskRequest) -> Self {
        Self {
            operation: request.operation,
            scope: encode_scope_ref(&request.scope),
            question: request.question.as_str(),
            system_prompt: request.system_prompt.as_str(),
            source_text: request.source_text.as_str(),
            instruction: request.instruction.as_str(),
            evidence: EvidenceSeq(request.evidence.as_slice()),
        }
    }
}

struct EvidenceSeq<'a>(&'a [Evidence]);
impl Serialize for EvidenceSeq<'_> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut seq = serializer.serialize_seq(Some(self.0.len()))?;
        for e in self.0 {
            seq.serialize_element(&EvidenceRef {
                source: RefRef::from_source(&e.source),
                title: e.title.as_str(),
                quote: e.quote.as_str(),
                start_ms: e.start_ms,
            })?;
        }
        seq.end()
    }
}

#[derive(Serialize)]
struct EvidenceRef<'a> {
    source: RefRef<'a>,
    title: &'a str,
    quote: &'a str,
    start_ms: u64,
}

pub(super) fn encode(workspace: &ProductWorkspace) -> Result<String, StoreError> {
    let ask_session = workspace.ask_session();
    let dto = PersistedWorkspaceRef {
        provider: Some(ProviderRef::from_config(workspace.provider_configuration())),
        ble_auto_connect: workspace.ble_auto_connect(),
        migrations: MigrationsSeq(workspace.migrations()),
        purged_bean_file_ids: workspace.purged_bean_file_ids(),
        version: 1,
        revision: workspace.revision(),
        next_operation: workspace.next_operation(),
        records: RecordsSeq(workspace.records()),
        items: ItemsSeq(workspace.items()),
        ask: AskRef {
            id: ask_session.id.as_str(),
            created_at: ask_session.created_at_epoch_sec,
            messages: MessagesSeq(ask_session.messages.as_slice()),
            draft: ask_session.draft.as_str(),
            in_flight: ask_session.in_flight,
            scope: encode_scope_ref(workspace.ask_scope()),
            pending: workspace.pending_ask().map(RequestRef::from_request),
            last_operation: workspace.last_ask_operation(),
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
    let mut purged_bean_file_ids: BTreeSet<u32> = dto.purged_bean_file_ids.into_iter().collect();
    purged_bean_file_ids.extend(
        dto.standby_scratch_file_ids
            .into_iter()
            .chain(dto.reclaimed_standby_file_ids)
            .filter(|&id| id > 0),
    );
    let state = PersistedWorkspaceState {
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
            .map(RecordDto::into_persisted_record)
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
    ProductWorkspace::restore_persisted(state).map_err(|e| invalid(e.to_string()))
}

impl RecordDto {
    fn into_persisted_record(self) -> Result<PersistedProductRecord, StoreError> {
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
        let minutes_revision = match (&self.minutes, self.minutes_revision) {
            (Some(_), None) => Some(match &analysis {
                AnalysisState::Ready { input_revision } => *input_revision,
                _ => self.content_revision,
            }),
            (_, explicit) => explicit,
        };
        for timestamp in self.bookmarks {
            a.add_bookmark(timestamp);
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
        let live_summary = self
            .live_summary
            .map(AnalysisDto::into_analysis)
            .transpose()?
            .unwrap_or_default();
        let capture_lanes = self.capture_lanes.into_iter().map(Into::into).collect();
        let speech_engine = match self.speech_engine.as_deref() {
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
        let mode = if all_day.is_some() {
            RecordMode::AllDay
        } else {
            parsed_mode.unwrap_or(RecordMode::QuickNote)
        };
        Ok(PersistedProductRecord {
            aggregate: a,
            minutes_json: self.minutes,
            title: self.title,
            origin,
            mode,
            project,
            analysis,
            live_summary,
            content_revision: self.content_revision,
            minutes_revision,
            highlighted_segments,
            capture_lanes,
            all_day,
            speech_engine,
            retention,
            final_keys,
            completed_request: self.completed_request.map(KeyDto::into_key),
        })
    }
}

impl KeyDto {
    fn into_key(self) -> RequestKey {
        RequestKey {
            record_id: self.record_id,
            attempt: self.attempt,
            input_revision: self.input_revision,
        }
    }
}

impl AnalysisDto {
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

fn encode_scope_ref(scope: &SearchScope) -> Option<&str> {
    match scope {
        SearchScope::All => None,
        SearchScope::Record(id) => Some(id.as_str()),
    }
}

fn decode_scope(scope: Option<String>) -> SearchScope {
    scope.map_or(SearchScope::All, SearchScope::Record)
}

fn invalid(message: impl Into<String>) -> StoreError {
    StoreError::InvalidData(message.into())
}
