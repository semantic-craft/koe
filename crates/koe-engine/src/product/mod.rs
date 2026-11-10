//! Recording-owned product state shared by native hosts and the CLI.

mod ask;
mod provider;
pub use provider::{valid_reference, CredentialBinding, MeetingAudioPolicy, ProviderConfiguration};
mod migration;
pub use migration::{ImportedSummary, MigrationReceipt};
mod capture;
mod record;
pub use capture::CaptureLaneRecord;
mod capture_timeline;
pub use capture_timeline::{place_capture_span, CaptureSpan};
mod state;

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
    /// Content revision, preserved across storage reconstruction.
    pub content_revision: u64,
    /// Explicit highlighted utterances, including text with no audio timestamp.
    pub highlighted_segments: BTreeSet<SegmentId>,
    /// Expected native lanes, including explicitly interrupted or empty lanes.
    pub capture_lanes: Vec<CaptureLaneRecord>,
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
}

impl fmt::Display for ProductError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let message = match self {
            Self::UnknownRecord => "记录不存在",
            Self::UnknownItem => "待办或记忆不存在",
            Self::InvalidSource => "来源不存在",
            Self::StaleRequest => "内容或请求已变化，旧结果未写入",
            Self::Busy => "请求仍在处理中",
            Self::InvalidInput(message) => message,
            Self::InvalidTransition => "当前状态不支持此操作",
            Self::InvalidEvidence => "回答包含缺失、无效或已变化的来源",
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
    /// Completed imports, including preserved material that has not been mapped.
    pub migrations: Vec<MigrationReceipt>,
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
    migrations: Vec<MigrationReceipt>,
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
            migrations: Vec::new(),
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
            self.resolve_source(source)?;
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

    /// Searches real utterance text with the existing Chinese/Latin BM25 implementation.
    pub fn search(
        &self,
        scope: &SearchScope,
        query: &str,
        limit: usize,
    ) -> Result<Vec<Evidence>, ProductError> {
        self.validate_scope(scope)?;
        let evidence = self.corpus(scope);
        let texts: Vec<_> = evidence.iter().map(|item| item.quote.as_str()).collect();
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
            .filter(|(id, _)| {
                matches!(scope, SearchScope::All)
                    || matches!(scope, SearchScope::Record(wanted) if *id == wanted)
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
        if matches!(scope, SearchScope::Record(id) if !self.records.contains_key(id)) {
            return Err(ProductError::UnknownRecord);
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
