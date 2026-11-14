//! Metadata for saved local audio recordings.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

/// Metadata and hardware double-tap mark list for a saved local recording.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordingEntry {
    /// Numeric recording identifier.
    pub id: u32,
    /// Originating D3200 device file ID (`0` if local-only).
    pub bean_file_id: u32,
    /// Creation timestamp in Unix epoch seconds.
    pub created_at_epoch_sec: u64,
    /// Playback duration in milliseconds.
    pub duration_ms: u64,
    /// Size of the `.opus` container on disk in bytes.
    pub byte_count: u32,
    /// Sorted, deduplicated double-tap mark positions in milliseconds.
    pub marks_ms: Vec<u64>,
}
