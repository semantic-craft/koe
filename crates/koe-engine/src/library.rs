//! Pure state machine for the local recording library, playback cursor,
//! hardware double-tap mark navigation, and single-step reversible trash.
//!
//! # Examples
//!
//! ```
//! use koe_engine::library::{RecordingEntry, RecordingLibrary};
//!
//! let mut lib = RecordingLibrary::new();
//! lib.ingest(RecordingEntry {
//!     id: 20261107,
//!     bean_file_id: 20261107,
//!     created_at_epoch_sec: 1_700_000_000,
//!     duration_ms: 1200,
//!     byte_count: 9818,
//!     marks_ms: vec![300, 900],
//! });
//! assert_eq!(lib.jump_to_mark(true), 300);
//! assert_eq!(lib.jump_to_mark(true), 900);
//! assert_eq!(lib.jump_to_mark(false), 300);
//! assert!(lib.move_to_trash(20261107));
//! assert!(lib.entries.is_empty());
//! assert!(lib.undo_trash());
//! assert_eq!(lib.entries.len(), 1);
//! ```

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

/// Pure value-state machine managing the local recording catalog, active selection,
/// playback cursor, 50 ms hysteresis mark navigation, and non-modal trash undo.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct RecordingLibrary {
    /// Ordered recordings (newest first).
    pub entries: Vec<RecordingEntry>,
    /// Currently selected recording ID.
    pub selected_id: Option<u32>,
    /// Most recently trashed recording available for one-step undo.
    pub trashed_entry: Option<RecordingEntry>,
    /// Current playback position in milliseconds.
    pub position_ms: u64,
    /// Whether playback is currently active.
    pub is_playing: bool,
}

impl RecordingLibrary {
    /// Creates an empty recording library.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            entries: Vec::new(),
            selected_id: None,
            trashed_entry: None,
            position_ms: 0,
            is_playing: false,
        }
    }

    /// Inserts or replaces `entry` at index 0 and selects it.
    pub fn ingest(&mut self, mut entry: RecordingEntry) {
        entry.marks_ms.sort_unstable();
        entry.marks_ms.dedup();
        self.entries.retain(|e| e.id != entry.id);
        let id = entry.id;
        self.entries.insert(0, entry);
        self.selected_id = Some(id);
        self.position_ms = 0;
        self.is_playing = false;
    }

    /// Ingests an existing `.opus` file discovered on disk during directory scan,
    /// preserving descending `created_at_epoch_sec` order.
    pub fn ingest_disk_file(
        &mut self,
        id: u32,
        byte_count: u32,
        created_at_epoch_sec: u64,
        default_marks_ms: &[u64],
    ) {
        if self.entries.iter().any(|e| e.id == id) {
            return;
        }
        let estimated_slices = (u64::from(byte_count) / 80).max(1);
        let duration_ms = estimated_slices * 20;
        let mut marks = default_marks_ms.to_vec();
        marks.sort_unstable();
        marks.dedup();
        self.entries.push(RecordingEntry {
            id,
            bean_file_id: id,
            created_at_epoch_sec,
            duration_ms,
            byte_count,
            marks_ms: marks,
        });
        self.entries.sort_by(|a, b| {
            b.created_at_epoch_sec
                .cmp(&a.created_at_epoch_sec)
                .then(b.id.cmp(&a.id))
        });
        if self.selected_id.is_none() {
            self.selected_id = self.entries.first().map(|e| e.id);
        }
    }

    /// Returns a reference to the currently selected recording, falling back to the first entry.
    #[must_use]
    pub fn selected_entry(&self) -> Option<&RecordingEntry> {
        if let Some(id) = self.selected_id {
            self.entries.iter().find(|e| e.id == id)
        } else {
            self.entries.first()
        }
    }

    /// Selects `id` if present in `entries` and resets `position_ms` to `0`.
    pub fn select(&mut self, id: u32) -> bool {
        if self.entries.iter().any(|e| e.id == id) {
            self.selected_id = Some(id);
            self.position_ms = 0;
            self.is_playing = false;
            true
        } else {
            false
        }
    }

    /// Clamps `target_ms` to the selected recording's duration and updates `position_ms`.
    pub fn seek_ms(&mut self, target_ms: u64) -> u64 {
        let Some(rec) = self.selected_entry() else {
            self.position_ms = 0;
            return 0;
        };
        let clamped = target_ms.min(rec.duration_ms);
        self.position_ms = clamped;
        clamped
    }

    /// Jumps to the next (`next == true`) or previous (`next == false`) hardware
    /// double-tap mark on the selected recording using a 50 ms hysteresis window
    /// and wrap-around semantics.
    pub fn jump_to_mark(&mut self, next: bool) -> u64 {
        let Some(rec) = self.selected_entry() else {
            return self.position_ms;
        };
        if rec.marks_ms.is_empty() {
            return self.position_ms;
        }
        let cur = self.position_ms;
        let target = if next {
            rec.marks_ms
                .iter()
                .copied()
                .find(|&m| m > cur.saturating_add(50))
                .unwrap_or(rec.marks_ms[0])
        } else {
            rec.marks_ms
                .iter()
                .rev()
                .copied()
                .find(|&m| m.saturating_add(50) < cur)
                .unwrap_or(*rec.marks_ms.last().unwrap_or(&0))
        };
        self.seek_ms(target)
    }

    /// Moves the recording with `id` into `trashed_entry` without confirmation modal.
    pub fn move_to_trash(&mut self, id: u32) -> bool {
        let Some(idx) = self.entries.iter().position(|e| e.id == id) else {
            return false;
        };
        let removed = self.entries.remove(idx);
        self.trashed_entry = Some(removed);
        if self.selected_id == Some(id) {
            self.selected_id = self.entries.first().map(|e| e.id);
            self.position_ms = 0;
            self.is_playing = false;
        }
        true
    }

    /// Restores `trashed_entry` back to index 0 and selects it.
    pub fn undo_trash(&mut self) -> bool {
        let Some(restored) = self.trashed_entry.take() else {
            return false;
        };
        self.ingest(restored);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_mark_jump_hysteresis_and_wraparound() {
        let mut lib = RecordingLibrary::new();
        lib.ingest(RecordingEntry {
            id: 42,
            bean_file_id: 42,
            created_at_epoch_sec: 100,
            duration_ms: 1200,
            byte_count: 9600,
            marks_ms: vec![900, 300, 300],
        });
        assert_eq!(lib.selected_entry().unwrap().marks_ms, vec![300, 900]);
        assert_eq!(lib.jump_to_mark(true), 300);
        assert_eq!(lib.jump_to_mark(true), 900);
        assert_eq!(lib.jump_to_mark(true), 300);
        assert_eq!(lib.jump_to_mark(false), 900);
        assert_eq!(lib.jump_to_mark(false), 300);
    }

    #[test]
    fn library_trash_and_undo_restores_selection() {
        let mut lib = RecordingLibrary::new();
        lib.ingest_disk_file(10, 8000, 1000, &[300, 900]);
        lib.ingest_disk_file(20, 8000, 2000, &[300, 900]);
        assert_eq!(lib.selected_id, Some(10));
        assert_eq!(lib.entries[0].id, 20);
        assert!(lib.move_to_trash(10));
        assert_eq!(lib.selected_id, Some(20));
        assert!(lib.undo_trash());
        assert_eq!(lib.selected_id, Some(10));
        assert_eq!(lib.entries.len(), 2);
    }
}
