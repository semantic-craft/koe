//! Double-tap slice mark detection and stateful transition probing (`PROTOCOL.md`).

use crate::commands::RxCmd;
use crate::frame::{read_u32_le, DecodedPacket};

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

/// A detected transition in slice command identifier or flags byte.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SliceMarkTransition {
    /// Packet command identifier (such as `0x08`).
    pub cmd_id: u8,
    /// Slice sequence number where the transition occurred.
    pub sequence: u32,
    /// New flags byte on that slice.
    pub flags: u8,
}

/// Stateful detector that logs only when `(cmd_id, flags)` changes across 166-byte slice records.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SliceMarkProbe {
    last: (u8, u8),
}

impl Default for SliceMarkProbe {
    fn default() -> Self {
        Self::new()
    }
}

impl SliceMarkProbe {
    /// Creates a probe initialized to `(RxCmd::FILE_SLICE_ID, 0)`.
    #[must_use]
    pub const fn new() -> Self {
        Self {
            last: (RxCmd::FILE_SLICE_ID, 0),
        }
    }

    /// Inspects a decoded RX packet and returns any `(cmd_id, flags)` transitions.
    pub fn inspect_transitions(&mut self, packet: &DecodedPacket) -> Vec<SliceMarkTransition> {
        let raw = &packet.raw;
        let mut out = Vec::new();
        let mut i = 9usize;
        while raw.len().saturating_sub(i) >= 165 {
            let sequence = read_u32_le(raw, i);
            let flags = raw[i + 4];
            let sig = (packet.cmd_id, flags);
            if sig != self.last {
                self.last = sig;
                out.push(SliceMarkTransition {
                    cmd_id: packet.cmd_id,
                    sequence,
                    flags,
                });
            }
            i += 165;
            if i < raw.len() {
                i += 1;
            }
        }
        out
    }

    /// Formats transition log lines matching Dart's `SliceMarkProbe.inspect(packet, at: ...)`.
    pub fn inspect(&mut self, packet: &DecodedPacket, iso_timestamp: &str) -> Vec<String> {
        self.inspect_transitions(packet)
            .into_iter()
            .map(|t| {
                format!(
                    "标记线索 cmd=0x{:02X} seq={} flags=0x{:02X} at={}",
                    t.cmd_id, t.sequence, t.flags, iso_timestamp
                )
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::ProtocolFrame;

    #[test]
    fn slice_mark_probe_detects_flag_transitions() {
        let mut payload = vec![0u8; 166 * 2];
        // Slice 0: seq = 7, flags = 1
        payload[0..4].copy_from_slice(&7u32.to_le_bytes());
        payload[4] = 0x01;
        // Slice 1: seq = 8, flags = 0
        payload[166..170].copy_from_slice(&8u32.to_le_bytes());
        payload[170] = 0x00;

        let mut raw = vec![0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x08];
        let total_len = (10 + payload.len()) as u16;
        raw.extend_from_slice(&total_len.to_le_bytes());
        raw.extend_from_slice(&payload);
        let csum = ProtocolFrame::checksum(&raw);
        raw.push(csum);

        let pkt = DecodedPacket::from_bytes(&raw);
        let mut probe = SliceMarkProbe::new();
        let lines = probe.inspect(&pkt, "2026-11-07T00:00:00.000Z");
        assert_eq!(
            lines,
            vec![
                "标记线索 cmd=0x08 seq=7 flags=0x01 at=2026-11-07T00:00:00.000Z",
                "标记线索 cmd=0x08 seq=8 flags=0x00 at=2026-11-07T00:00:00.000Z",
            ]
        );
    }
}
