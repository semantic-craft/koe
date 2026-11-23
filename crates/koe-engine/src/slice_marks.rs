//! Double-tap slice mark detection (`PROTOCOL.md`).

/// Constants and helpers for the D3200 double-tap bookmark flag on `0x08` audio slices.
pub struct SliceMark;

impl SliceMark {
    /// Bitflag set on the 20 ms slice recorded when the user double-taps the bean.
    pub const FLAG: u8 = 0x01;
    /// Duration in milliseconds of a single Opus slice.
    pub const SLICE_DURATION_MS: u64 = 20;
    /// Default Chinese bookmark note attached to a hardware double-tap mark.
    pub const BOOKMARK_NOTE: &'static str = "录音豆双击标记";

    /// Returns `true` when `flags` carries the double-tap mark bit.
    #[must_use]
    pub const fn is_mark(flags: u8) -> bool {
        (flags & Self::FLAG) != 0
    }

    /// Returns the recording offset in milliseconds for `sequence`.
    #[must_use]
    pub const fn position_ms(sequence: u32) -> u64 {
        (sequence as u64) * Self::SLICE_DURATION_MS
    }
}
