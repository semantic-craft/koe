//! Local recording library persistence and personal context projections.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::path::PathBuf;

pub mod capture_asset;
pub mod product_store;
pub mod recording_assets;

pub use koe_engine::context::{
    build_morning_brief, compute_project_progress, filter_open_mine_todos, format_coarse_place,
    pack_context_source_lines, select_focus_project, sort_context_timeline, sort_todos,
    ContextEvent, ContextOutcome, ContextReducer, ContextSearchIndex, ContextState, DiaryDraft,
    DiaryEntry, DiaryPeriod, MorningBrief, Project, ProjectProgress, ProjectStatus, ScoringMode,
    SourceLine, SourcePointer, TimelineEntry,
};
pub use koe_engine::library::{RecordingEntry, RecordingLibrary};
pub use koe_engine::slice_marks::SliceMark;

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
