//! Local recording library persistence, durable `NativeAnalysisQueue`, native JSON-RPC 2.0
//! MCP (`2025-11-25`) & ACP (`2026-01-01`) server (`mcp_acp`), and personal context /
//! Google Workspace service projections.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::path::PathBuf;

pub mod analysis_queue;
pub mod mcp_acp;
pub mod product_store;
pub mod recording_assets;

pub use analysis_queue::{
    AnalysisJob, AnalysisJobPhase, AnalysisRecipeSnapshot, NativeAnalysisQueue,
    TranscriptWindowCheckpoint, CHECKPOINT_WINDOW_DURATION_MS, CHECKPOINT_WINDOW_OVERLAP_MS,
    MAX_ANALYSIS_QUEUE_JOBS,
};
pub use koe_engine::context::{
    build_morning_brief, compute_project_progress, filter_open_mine_todos, format_coarse_place,
    pack_context_source_lines, select_focus_project, sort_context_timeline, sort_todos,
    ContextEvent, ContextOutcome, ContextReducer, ContextSearchIndex, ContextState, DiaryDraft,
    DiaryEntry, DiaryPeriod, MorningBrief, Project, ProjectProgress, ProjectStatus, ScoringMode,
    SourceLine, SourcePointer, TimelineEntry,
};
pub use koe_engine::library::{RecordingEntry, RecordingLibrary};
pub use koe_engine::slice_marks::SliceMark;
pub use mcp_acp::{
    build_openai_tools_json, compute_pack_sync_delta, constant_time_eq, format_epoch_sec_iso8601,
    is_supported_mcp_tool, AcpAgentCard, AcpTaskPhase, AcpTaskRecord, LiveLeaseValidator,
    LivePublicationLease, McpAcpEvent, McpAcpOutcome, McpAcpReducer, McpAcpState,
    McpAcpWorkspaceView, McpPairingMode, McpToolError, McpToolSpec, PackSyncDelta, PairingTicket,
    QwennoteCatalog, SyncPackSummary, ACP_PROTOCOL_VERSION, KOE_ACP_METHODS, KOE_MCP_TOOLS,
    LIVE_LEASE_DEFAULT_TTL_SEC, LIVE_LEASE_MAX_REMAINING_SEC, MAX_ACP_TASK_LOGS,
    MAX_JSONRPC_REQUEST_BYTES, MAX_JSONRPC_RESPONSE_BYTES, MCP_PROTOCOL_VERSION,
    PAIRING_TICKET_PREFIX,
};

/// Direction for hardware double-tap mark navigation (`Previous` or `Next`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkJumpDirection {
    /// Jump to the previous mark before the 50 ms hysteresis window.
    Previous,
    /// Jump to the next mark after the 50 ms hysteresis window.
    Next,
}

impl From<bool> for MarkJumpDirection {
    fn from(next: bool) -> Self {
        if next {
            Self::Next
        } else {
            Self::Previous
        }
    }
}

/// Value snapshot of the local recording library state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibrarySnapshot {
    /// Total number of active recordings in the library.
    pub entry_count: usize,
    /// Currently selected recording identifier, if any.
    pub selected_id: Option<u32>,
    /// Current playback cursor position in milliseconds.
    pub position_ms: u64,
    /// Whether playback is currently active.
    pub is_playing: bool,
    /// Most recently trashed recording identifier available for one-step undo.
    pub last_trashed_id: Option<u32>,
}

/// Metadata and on-disk file paths for a recording exported by Koe.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopExportedRecording {
    /// Recording metadata and hardware double-tap mark timestamps in milliseconds.
    pub entry: RecordingEntry,
    /// Path to the exported Ogg Opus container (`{id}.opus`).
    pub opus_path: PathBuf,
    /// Path to the exported 48 kHz mono PCM16 preview WAV (`{id}.wav`).
    pub wav_path: PathBuf,
}

/// Extension trait providing deterministic highlight window calculation on [`SliceMark`].
pub trait SliceMarkHighlightExt {
    /// Computes the `(start_ms, end_ms)` highlight window around `mark_ms` with `half_window_ms` radius,
    /// clamped to `[0, duration_ms]` when `duration_ms > 0`.
    #[must_use]
    fn highlight_window(mark_ms: u64, half_window_ms: u64, duration_ms: u64) -> (u64, u64);
}

impl SliceMarkHighlightExt for SliceMark {
    fn highlight_window(mark_ms: u64, half_window_ms: u64, duration_ms: u64) -> (u64, u64) {
        let start_ms = mark_ms.saturating_sub(half_window_ms);
        let raw_end_ms = mark_ms.saturating_add(half_window_ms);
        let end_ms = if duration_ms > 0 {
            raw_end_ms.min(duration_ms.max(mark_ms))
        } else {
            raw_end_ms
        };
        (start_ms, end_ms)
    }
}

/// Value snapshot of a Google Task item for UI projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleTaskSnapshot {
    /// Task identifier in Google Tasks (`gtask-...`).
    pub id: String,
    /// Task list identifier (`"@default"`).
    pub tasklist_id: String,
    /// Task display title.
    pub title: String,
    /// Task notes or grounded `[S#]` citation details.
    pub notes: String,
    /// Whether the task is marked completed.
    pub completed: bool,
    /// Optional Koe local todo identifier linked for bidirectional sync.
    pub linked_koe_todo_id: Option<String>,
    /// Last updated timestamp in Unix epoch seconds.
    pub updated_at_epoch_sec: u64,
}

/// Value snapshot of a Gemini NotebookLM notebook for UI projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleNotebookSnapshot {
    /// Notebook identifier.
    pub id: String,
    /// Notebook display title.
    pub title: String,
    /// Number of grounded sources attached to the notebook.
    pub source_count: usize,
    /// Whether the Audio Overview is ready for playback.
    pub audio_overview_ready: bool,
    /// Total number of Q&A turns recorded in this notebook.
    pub qa_count: usize,
    /// Latest grounded Q&A answer or audio overview preview text.
    pub latest_qa_preview: Option<String>,
    /// Last updated timestamp in Unix epoch seconds.
    pub updated_at_epoch_sec: u64,
}

/// Value snapshot of a Google Keep note for UI projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleKeepNoteSnapshot {
    /// Keep note identifier.
    pub id: String,
    /// Note display title.
    pub title: String,
    /// Body text preview.
    pub body_preview: String,
    /// Total checklist items in the note.
    pub checklist_total: usize,
    /// Completed checklist items in the note.
    pub checklist_checked: usize,
    /// Interactive checklist items `(index, text, checked)`.
    pub checklist_items: Vec<(usize, String, bool)>,
    /// Whether the note is pinned.
    pub pinned: bool,
    /// Last updated timestamp in Unix epoch seconds.
    pub updated_at_epoch_sec: u64,
}
