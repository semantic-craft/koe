//! Recording-owned product state shared by native hosts and the CLI.

mod ask;
mod provider;
pub use provider::{
    CredentialBinding, MeetingAudioPolicy, ProviderConfiguration, SpeechEngine, valid_reference,
};
mod migration;
pub use migration::{ImportedSummary, MigrationReceipt};
mod capture;
mod record;
pub use capture::CaptureLaneRecord;
mod capture_timeline;
pub use capture_timeline::{CaptureSpan, place_capture_span};
mod state;
mod transcript_edit;
pub use transcript_edit::{
    MAX_SEGMENT_TEXT_CHARS, MAX_SPEAKER_NAME_CHARS, MinutesFreshness, SpeakerName, SpeakerSummary,
    TranscriptEditReceipt, sanitize_speaker_lossy,
};
mod trash;
pub use trash::{PurgeReceipt, RecordRetention, TRASH_RETENTION_MS};

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use crate::context::{AskSession, ContextSearchIndex, ScoringMode};
use crate::domain::{RecordingAggregate, SegmentId};

/// Stable recording identity independent of selection and file names.
pub type RecordId = String;

/// Origin of a real recording or explicit text input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecordOrigin {
    /// Native Mac microphone audio.
    Microphone,
    /// D3200 recording.
    Bean,
    /// User-imported audio.
    ImportedAudio,
    /// User-imported text.
    ImportedText,
    /// User-created text note.
    Note,
}

/// Routing policy for D3200 collar-microphone companion streaming.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum CompanionRoutingMode {
    /// Standard meeting recorder mode; companion streaming disabled.
    #[default]
    Disabled,
    /// Typeless-style collar standby: auto-starts silent realtime stream on BLE connect without creating meeting records.
    CollarStandby,
    /// Retains full Koe meeting records while also exposing double-tap and PCM16 capture to companion subscribers.
    MeetingAndCollar,
}

impl CompanionRoutingMode {
    /// Stable snake_case wire and storage identifier.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Disabled => "disabled",
            Self::CollarStandby => "collar_standby",
            Self::MeetingAndCollar => "meeting_and_collar",
        }
    }

    /// Parses a snake_case companion routing mode identifier.
    #[must_use]
    pub fn parse(value: &str) -> Option<Self> {
        match value.trim() {
            "disabled" => Some(Self::Disabled),
            "collar_standby" => Some(Self::CollarStandby),
            "meeting_and_collar" => Some(Self::MeetingAndCollar),
            _ => None,
        }
    }
}

/// A source in exactly one recording's utterance spine.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct SourceRef {
    /// Owning recording.
    pub record_id: String,
    /// Stable utterance identifier inside that recording.
    pub segment_id: SegmentId,
}

/// Resolved evidence suitable for display and source navigation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Evidence {
    /// Original source identity.
    pub source: SourceRef,
    /// Current recording title.
    pub title: String,
    /// Actual utterance text.
    pub quote: String,
    /// Original offset in milliseconds.
    pub start_ms: u64,
}

/// User-selected search corpus.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum SearchScope {
    /// All stored recordings.
    #[default]
    All,
    /// One existing recording.
    Record(String),
}

/// Type of a source-backed review item.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemKind {
    /// Action that can be completed after acceptance.
    Task,
    /// Personal memory retained after acceptance.
    Memory,
}

/// Durable user review state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReviewState {
    /// Suggested, not yet adopted.
    Proposed,
    /// Explicitly adopted by the user.
    Accepted,
    /// Explicitly dismissed by the user.
    Dismissed,
}

/// Intent to change the review state.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReviewDecision {
    /// Adopt the item.
    Accept,
    /// Dismiss the item.
    Dismiss,
    /// Undo the review decision.
    Reset,
}

/// Durable task or memory whose sources are validated by the workspace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourcedItem {
    /// Stable item identity.
    pub id: String,
    /// Task or memory.
    pub kind: ItemKind,
    /// User-facing text, editable without modifying original evidence.
    pub text: String,
    /// Supporting original utterances.
    pub sources: Vec<SourceRef>,
    /// Explicit review decision.
    pub review: ReviewState,
    /// Whether an accepted task was completed.
    pub completed: bool,
    /// Optional human-readable due date.
    pub due: Option<String>,
}

/// An analysis request's stable ownership and input version.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestKey {
    /// Recording receiving the result, independent of the visible page.
    pub record_id: String,
    /// Monotonically allocated operation identifier.
    pub attempt: u64,
    /// Recording content revision at request creation.
    pub input_revision: u64,
}

/// Stage of an actual analysis attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnalysisStage {
    /// Producing transcript finals.
    Transcribing,
    /// Producing structured minutes from an immutable transcript revision.
    Summarizing,
}

/// The sole authoritative product analysis state for a recording.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum AnalysisState {
    /// No analysis attempt is in flight.
    #[default]
    Idle,
    /// A persisted attempt is in flight.
    Pending {
        /// Ownership and input version.
        key: RequestKey,
        /// Actual provider stage.
        stage: AnalysisStage,
    },
    /// Structured minutes were committed for this revision.
    Ready {
        /// Content revision covered by the minutes.
        input_revision: u64,
    },
    /// Provider returned a known error.
    Failed {
        /// Failed attempt.
        key: RequestKey,
        /// User-facing error without credentials.
        message: String,
    },
    /// A process restart interrupted an attempt whose external outcome is unknown.
    Interrupted {
        /// Interrupted attempt, retained for audit and explicit retry.
        key: RequestKey,
    },
}

/// Membership of an ordinary record in an all-day capture run.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AllDaySegment {
    /// Stable run identity shared by independently persisted records.
    pub run_id: String,
    /// One-based segment order.
    pub ordinal: u64,
}

/// One recording's content and processing state. Mutations belong to ProductWorkspace.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductRecord {
    /// Existing canonical utterance/minutes aggregate.
    pub aggregate: RecordingAggregate,
    /// User-facing title.
    pub title: String,
    /// Actual capture/import source.
    pub origin: RecordOrigin,
    /// Authoritative analysis state.
    pub analysis: AnalysisState,
    /// Independent minutes refresh while transcription continues.
    pub live_summary: AnalysisState,
    /// Content revision, preserved across storage reconstruction.
    pub content_revision: u64,
    pub(super) minutes_revision: Option<u64>,
    /// Explicit highlighted utterances, including text with no audio timestamp.
    pub highlighted_segments: BTreeSet<SegmentId>,
    /// Expected native lanes, including explicitly interrupted or empty lanes.
    pub capture_lanes: Vec<CaptureLaneRecord>,
    /// Grouping of bounded all-day capture segments.
    pub all_day: Option<AllDaySegment>,
    /// Engine bound to the most recent speech request, used for safe local recovery.
    pub speech_engine: Option<SpeechEngine>,
    retention: RecordRetention,
    final_keys: BTreeMap<String, SegmentId>,
    completed_request: Option<RequestKey>,
}

/// An immutable, source-scoped provider request produced by a question.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AskRequest {
    /// Monotonically allocated request identity.
    pub operation: u64,
    /// Exact permitted corpus.
    pub scope: SearchScope,
    /// User question.
    pub question: String,
    /// Grounding rules for the model.
    pub system_prompt: String,
    /// Numbered evidence rendered by the existing AskSession.
    pub source_text: String,
    /// Contextualized question including previous turns.
    pub instruction: String,
    /// Allowed evidence in S1..Sn order, including original text for stale detection.
    pub evidence: Vec<Evidence>,
}

/// Domain rejection; storage and network failures belong to their respective boundaries.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProductError {
    /// Recording ID does not exist.
    UnknownRecord,
    /// Item ID does not exist.
    UnknownItem,
    /// Record or utterance in a source is missing.
    InvalidSource,
    /// Segment ID does not exist in the addressed recording's spine.
    SegmentNotFound,
    /// Request belongs to an older attempt or input revision.
    StaleRequest,
    /// An attempt is already pending.
    Busy,
    /// Invalid explicit input.
    InvalidInput(String),
    /// Operation is not valid for this state.
    InvalidTransition,
    /// Generated response is not supported by the allowed sources.
    InvalidEvidence,
    /// Recording is locked by archive protection and cannot have its transcript/speakers edited or be trashed/purged.
    RecordArchived,
    /// Recording is in the trash and must be restored before live operations.
    RecordTrashed,
}

impl fmt::Display for ProductError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::UnknownRecord => "记录不存在",
            Self::UnknownItem => "待办或记忆不存在",
            Self::InvalidSource => "来源不存在",
            Self::SegmentNotFound => "原文片段不存在",
            Self::StaleRequest => "内容或请求已变化，旧结果未写入",
            Self::Busy => "请求仍在处理中",
            Self::InvalidInput(message) => message,
            Self::InvalidTransition => "当前状态不支持此操作",
            Self::InvalidEvidence => "回答包含缺失、无效或已变化的来源",
            Self::RecordArchived => "记录已开启归档保护，请先取消归档后再修改或移入回收站",
            Self::RecordTrashed => "记录已在回收站中，恢复后才能继续操作",
        };
        f.write_str(message)
    }
}

impl std::error::Error for ProductError {}

/// Pure serializable value state used by the persistence boundary, not a wire schema.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceState {
    /// Non-sensitive provider configuration.
    pub provider_configuration: ProviderConfiguration,
    /// Whether BLE auto-connect to paired D3200 devices is enabled.
    pub ble_auto_connect: bool,
    /// Durable collar-microphone companion routing mode.
    pub companion_mode: CompanionRoutingMode,
    /// Temporary D3200 `file_id`s created during collar standby awaiting flash deletion.
    pub standby_scratch_file_ids: BTreeSet<u32>,
    /// Standby D3200 `file_id`s whose flash deletion was issued and must be re-verified on reconnect.
    pub reclaimed_standby_file_ids: BTreeSet<u32>,
    /// Completed imports, including preserved material that has not been mapped.
    pub migrations: Vec<MigrationReceipt>,
    /// Hardware Bean `file_id` tombstones preventing automatic re-pull after purge.
    pub purged_bean_file_ids: BTreeSet<u32>,
    /// Committed revision.
    pub revision: u64,
    /// Next operation identity.
    pub next_operation: u64,
    /// Owned recordings.
    pub records: Vec<ProductRecord>,
    /// Durable review items.
    pub items: Vec<SourcedItem>,
    /// Existing conversation state machine.
    pub ask_session: AskSession,
    /// Selected question scope.
    pub ask_scope: SearchScope,
    /// Pending immutable evidence request.
    pub pending_ask: Option<AskRequest>,
    /// Last accepted reply identity for idempotent delivery.
    pub last_ask_operation: Option<u64>,
}

/// Single owner of recording content, sourced review items, and conversation state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProductWorkspace {
    provider_configuration: ProviderConfiguration,
    ble_auto_connect: bool,
    companion_mode: CompanionRoutingMode,
    standby_scratch_file_ids: BTreeSet<u32>,
    reclaimed_standby_file_ids: BTreeSet<u32>,
    migrations: Vec<MigrationReceipt>,
    purged_bean_file_ids: BTreeSet<u32>,
    revision: u64,
    next_operation: u64,
    records: BTreeMap<RecordId, ProductRecord>,
    items: BTreeMap<String, SourcedItem>,
    ask_session: AskSession,
    ask_scope: SearchScope,
    pending_ask: Option<AskRequest>,
    last_ask_operation: Option<u64>,
}

impl Default for ProductWorkspace {
    fn default() -> Self {
        Self::new()
    }
}

impl ProductWorkspace {
    /// Creates an empty workspace with no examples or invented content.
    #[must_use]
    pub fn new() -> Self {
        Self {
            provider_configuration: ProviderConfiguration::default(),
            ble_auto_connect: true,
            companion_mode: CompanionRoutingMode::Disabled,
            standby_scratch_file_ids: BTreeSet::new(),
            reclaimed_standby_file_ids: BTreeSet::new(),
            migrations: Vec::new(),
            purged_bean_file_ids: BTreeSet::new(),
            revision: 0,
            next_operation: 1,
            records: BTreeMap::new(),
            items: BTreeMap::new(),
            ask_session: AskSession::new("product-ask", 0),
            ask_scope: SearchScope::All,
            pending_ask: None,
            last_ask_operation: None,
        }
    }

    /// Whether the host should automatically scan and reconnect to D3200 peripherals.
    #[must_use]
    pub fn ble_auto_connect(&self) -> bool {
        self.ble_auto_connect
    }

    /// Updates durable BLE auto-connect preference.
    pub fn set_ble_auto_connect(&mut self, enabled: bool) {
        if self.ble_auto_connect != enabled {
            self.ble_auto_connect = enabled;
            self.changed();
        }
    }

    /// Active collar-microphone companion routing mode.
    #[must_use]
    pub fn companion_mode(&self) -> CompanionRoutingMode {
        self.companion_mode
    }

    /// Updates the durable collar-microphone companion routing mode.
    pub fn set_companion_mode(&mut self, mode: CompanionRoutingMode) {
        if self.companion_mode != mode {
            self.companion_mode = mode;
            self.changed();
        }
    }

    /// Temporary D3200 `file_id`s created during collar standby awaiting flash deletion.
    #[must_use]
    pub fn standby_scratch_file_ids(&self) -> &BTreeSet<u32> {
        &self.standby_scratch_file_ids
    }

    /// Returns `true` when `file_id` belongs to a temporary collar-standby session.
    #[must_use]
    pub fn is_standby_scratch_file(&self, file_id: u32) -> bool {
        file_id != 0 && self.standby_scratch_file_ids.contains(&file_id)
    }

    /// Records a temporary collar-standby D3200 `file_id` for deferred flash deletion.
    pub fn record_standby_scratch_file_id(&mut self, file_id: u32) {
        if file_id != 0 && self.standby_scratch_file_ids.insert(file_id) {
            self.changed();
        }
    }

    /// Clears a temporary collar-standby D3200 `file_id` after flash deletion is queued.
    pub fn clear_standby_scratch_file_id(&mut self, file_id: u32) {
        if self.standby_scratch_file_ids.remove(&file_id) {
            self.changed();
        }
    }

    /// Current mutation revision.
    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Immutable recording catalog.
    #[must_use]
    pub fn records(&self) -> &BTreeMap<RecordId, ProductRecord> {
        &self.records
    }

    /// One immutable recording.
    #[must_use]
    pub fn record(&self, id: &str) -> Option<&ProductRecord> {
        self.records.get(id)
    }

    /// Immutable task/memory catalog.
    #[must_use]
    pub fn items(&self) -> &BTreeMap<String, SourcedItem> {
        &self.items
    }

    /// Resolves exactly the addressed recording and utterance.
    pub fn resolve_source(&self, source: &SourceRef) -> Result<Evidence, ProductError> {
        let record = self
            .records
            .get(&source.record_id)
            .ok_or(ProductError::InvalidSource)?;
        let segment = record
            .aggregate
            .spine
            .get(source.segment_id)
            .ok_or(ProductError::InvalidSource)?;
        Ok(Evidence {
            source: source.clone(),
            title: record.title.clone(),
            quote: segment.text.clone(),
            start_ms: segment.start_ms,
        })
    }

    /// Creates a review candidate, preserving an existing equivalent candidate and its decision.
    pub fn propose_item(
        &mut self,
        kind: ItemKind,
        text: &str,
        sources: Vec<SourceRef>,
    ) -> Result<String, ProductError> {
        self.propose_with_due(kind, text, sources, None)
    }

    fn propose_with_due(
        &mut self,
        kind: ItemKind,
        text: &str,
        sources: Vec<SourceRef>,
        due: Option<String>,
    ) -> Result<String, ProductError> {
        let clean = nonempty(text)?;
        let sources: Vec<_> = sources
            .into_iter()
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect();
        if sources.is_empty() {
            return Err(ProductError::InvalidSource);
        }
        for source in &sources {
            self.resolve_live_source(source)?;
        }
        if let Some(item) = self
            .items
            .values()
            .find(|item| item.kind == kind && item.text == clean && item.sources == sources)
        {
            return Ok(item.id.clone());
        }
        let id = format!("item-{}", self.operation());
        self.items.insert(
            id.clone(),
            SourcedItem {
                id: id.clone(),
                kind,
                text: clean,
                sources,
                review: ReviewState::Proposed,
                completed: false,
                due: due
                    .map(|value| value.trim().to_string())
                    .filter(|value| !value.is_empty()),
            },
        );
        self.changed();
        Ok(id)
    }

    /// Applies an explicit review decision without changing the underlying recording.
    pub fn review_item(&mut self, id: &str, decision: ReviewDecision) -> Result<(), ProductError> {
        self.ensure_item_live(id)?;
        let item = self.items.get_mut(id).ok_or(ProductError::UnknownItem)?;
        let review = match decision {
            ReviewDecision::Accept => ReviewState::Accepted,
            ReviewDecision::Dismiss => ReviewState::Dismissed,
            ReviewDecision::Reset => ReviewState::Proposed,
        };
        if item.review != review {
            item.review = review;
            if review != ReviewState::Accepted {
                item.completed = false;
            }
            self.changed();
        }
        Ok(())
    }

    /// Completes or reopens an explicitly accepted task.
    pub fn complete_task(&mut self, id: &str, completed: bool) -> Result<(), ProductError> {
        self.ensure_item_live(id)?;
        let item = self.items.get_mut(id).ok_or(ProductError::UnknownItem)?;
        if item.kind != ItemKind::Task || item.review != ReviewState::Accepted {
            return Err(ProductError::InvalidTransition);
        }
        if item.completed != completed {
            item.completed = completed;
            self.changed();
        }
        Ok(())
    }

    /// Edits a task or memory while retaining its original evidence.
    pub fn edit_item(
        &mut self,
        id: &str,
        text: &str,
        due: Option<String>,
    ) -> Result<(), ProductError> {
        let clean = nonempty(text)?;
        let due = due.map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
        self.ensure_item_live(id)?;
        let item = self.items.get_mut(id).ok_or(ProductError::UnknownItem)?;
        if item.kind == ItemKind::Memory && due.is_some() {
            return Err(ProductError::InvalidTransition);
        }
        if item.text != clean || item.due != due {
            item.text = clean;
            item.due = due;
            self.changed();
        }
        Ok(())
    }

    fn ensure_item_live(&self, id: &str) -> Result<(), ProductError> {
        let item = self.items.get(id).ok_or(ProductError::UnknownItem)?;
        if !item.sources.iter().any(|s| {
            self.records
                .get(&s.record_id)
                .is_some_and(ProductRecord::is_live)
        }) {
            return Err(ProductError::RecordTrashed);
        }
        Ok(())
    }

    /// Searches real utterance text and speaker labels with the existing Chinese/Latin BM25 implementation.
    pub fn search(
        &self,
        scope: &SearchScope,
        query: &str,
        limit: usize,
    ) -> Result<Vec<Evidence>, ProductError> {
        self.validate_scope(scope)?;
        let evidence = self.corpus(scope);
        let docs: Vec<String> = evidence
            .iter()
            .map(|item| {
                self.records
                    .get(&item.source.record_id)
                    .and_then(|r| r.aggregate.spine.get(item.source.segment_id))
                    .and_then(|seg| seg.speaker.as_deref())
                    .filter(|spk| !spk.is_empty())
                    .map_or_else(|| item.quote.clone(), |spk| format!("{spk} {}", item.quote))
            })
            .collect();
        let texts: Vec<_> = docs.iter().map(String::as_str).collect();
        let index = ContextSearchIndex::build(&texts);
        Ok(index
            .search(query, limit, ScoringMode::default())
            .iter()
            .filter_map(|hit| evidence.get(hit.doc_index).cloned())
            .collect())
    }

    fn corpus(&self, scope: &SearchScope) -> Vec<Evidence> {
        self.records
            .iter()
            .filter(|(id, record)| {
                record.is_live()
                    && (matches!(scope, SearchScope::All)
                        || matches!(scope, SearchScope::Record(wanted) if *id == wanted))
            })
            .flat_map(|(id, record)| {
                record
                    .aggregate
                    .spine
                    .segments()
                    .iter()
                    .map(move |segment| Evidence {
                        source: SourceRef {
                            record_id: id.clone(),
                            segment_id: segment.id,
                        },
                        title: record.title.clone(),
                        quote: segment.text.clone(),
                        start_ms: segment.start_ms,
                    })
            })
            .collect()
    }

    fn validate_scope(&self, scope: &SearchScope) -> Result<(), ProductError> {
        if let SearchScope::Record(id) = scope {
            let record = self.records.get(id).ok_or(ProductError::UnknownRecord)?;
            record.ensure_live()?;
        }
        Ok(())
    }

    fn changed(&mut self) {
        self.revision = self.revision.saturating_add(1);
    }
    fn operation(&mut self) -> u64 {
        let id = self.next_operation;
        self.next_operation = self.next_operation.saturating_add(1);
        id
    }
}

fn nonempty(value: &str) -> Result<String, ProductError> {
    let clean = value.trim();
    if clean.is_empty() {
        Err(ProductError::InvalidInput("内容不能为空".to_string()))
    } else {
        Ok(clean.to_string())
    }
}
