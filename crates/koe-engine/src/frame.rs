//! Binary framing and packet reassembly for the soundcore Work / D3200 recorder.
//!
//! Matches `lib/protocol/frame.dart` and `PROTOCOL.md` section 4:
//! - TX frame layout: `08 EE 00 00 00 | cmd_type | cmd_id | len_lo | len_hi | payload | checksum`
//! - RX frame layout: `09 FF 00 00 | status | cmd_type | cmd_id | len_lo | len_hi | payload | checksum`
//!
//! # Examples
//!
//! ```
//! use koe_engine::frame::ProtocolFrame;
//!
//! let tx = ProtocolFrame::encode(0x18, 0x82, &[0x01]);
//! assert_eq!(tx[0..2], [0x08, 0xEE]);
//! assert!(ProtocolFrame::verify_checksum(&tx));
//! ```

/// Magic prefix for outbound commands sent from the host to the D3200 device.
pub const TX_MAGIC: [u8; 5] = [0x08, 0xEE, 0x00, 0x00, 0x00];

/// Magic prefix for inbound packets received from the D3200 device.
pub const RX_MAGIC: [u8; 4] = [0x09, 0xFF, 0x00, 0x00];

/// Stateless framing encoder, checksum verifier, and streaming RX reassembler.
#[derive(Debug, Clone, Copy)]
pub struct ProtocolFrame;

impl ProtocolFrame {
    /// Encodes a host-to-device command frame with trailing 8-bit additive checksum.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::frame::ProtocolFrame;
    ///
    /// let frame = ProtocolFrame::encode(0x01, 0x01, &[]);
    /// assert_eq!(frame.len(), 10);
    /// assert!(ProtocolFrame::verify_checksum(&frame));
    /// ```
    #[must_use]
    pub fn encode(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
        let body_len = 5 + 2 + 2 + payload.len() + 1;
        let mut out = Vec::with_capacity(body_len);
        out.extend_from_slice(&TX_MAGIC);
        out.push(cmd_type);
        out.push(cmd_id);
        out.push((body_len & 0xFF) as u8);
        out.push(((body_len >> 8) & 0xFF) as u8);
        out.extend_from_slice(payload);
        let csum = Self::checksum(&out);
        out.push(csum);
        out
    }

    /// Computes the 8-bit wrapping sum over `data`.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::frame::ProtocolFrame;
    ///
    /// assert_eq!(ProtocolFrame::checksum(&[0x10, 0x20, 0xD5]), 0x05);
    /// ```
    #[must_use]
    pub fn checksum(data: &[u8]) -> u8 {
        let mut sum: u8 = 0;
        for &b in data {
            sum = sum.wrapping_add(b);
        }
        sum
    }

    /// Verifies that `packet` has at least 2 bytes and its final byte matches
    /// the additive checksum of the preceding slice without allocating.
    #[must_use]
    pub fn verify_checksum(packet: &[u8]) -> bool {
        if packet.len() < 2 {
            return false;
        }
        let last_idx = packet.len() - 1;
        Self::checksum(&packet[..last_idx]) == packet[last_idx]
    }

    /// Checks whether `data[offset..]` starts with the 4-byte `RX_MAGIC` header.
    #[must_use]
    pub fn is_rx_header(data: &[u8], offset: usize) -> bool {
        data.len() >= offset.saturating_add(4) && data[offset..offset + 4] == RX_MAGIC
    }

    /// Scans `buffer` for complete RX packets, removes consumed bytes from the front
    /// of `buffer`, and returns all checksum-verified packets in arrival order.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::frame::ProtocolFrame;
    ///
    /// let body = [0x09u8, 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x0A, 0x00];
    /// let csum = ProtocolFrame::checksum(&body);
    /// let mut buf = vec![0xAA];
    /// buf.extend_from_slice(&body);
    /// buf.push(csum);
    ///
    /// let packets = ProtocolFrame::process_buffer(&mut buf);
    /// assert_eq!(packets.len(), 1);
    /// assert!(packets[0].is_success());
    /// assert!(buf.is_empty());
    /// ```
    pub fn process_buffer(buffer: &mut Vec<u8>) -> Vec<DecodedPacket> {
        let mut results = Vec::new();
        let mut i = 0usize;
        while i + 10 <= buffer.len() {
            let mut found: Option<usize> = None;
            let limit = buffer.len() - 10;
            for j in i..=limit {
                if Self::is_rx_header(buffer, j) {
                    found = Some(j);
                    break;
                }
            }
            let Some(header_pos) = found else {
                break;
            };
            i = header_pos;
            if i + 9 > buffer.len() {
                break;
            }
            let total_len = read_u16_le(buffer, i + 7) as usize;
            if total_len < 10 {
                i += 1;
                continue;
            }
            if i + total_len > buffer.len() {
                break;
            }
            let slice = &buffer[i..i + total_len];
            if Self::verify_checksum(slice) {
                results.push(DecodedPacket::from_bytes(slice));
            }
            i += total_len;
        }
        if i > 0 && i <= buffer.len() {
            buffer.drain(0..i);
        }
        results
    }
}

/// Stateful streaming RX frame reassembler for arbitrary BLE and Wi-Fi byte chunks.
///
/// # Examples
///
/// ```
/// use koe_engine::frame::{FrameReassembler, ProtocolFrame};
///
/// let body = [0x09u8, 0xFF, 0x00, 0x00, 0x01, 0x01, 0x01, 0x0A, 0x00];
/// let csum = ProtocolFrame::checksum(&body);
/// let mut pkt = vec![0xDE, 0xAD];
/// pkt.extend_from_slice(&body);
/// pkt.push(csum);
///
/// let mut reassembler = FrameReassembler::new();
/// assert!(reassembler.ingest(&pkt[..6]).is_empty());
/// let decoded = reassembler.ingest(&pkt[6..]);
/// assert_eq!(decoded.len(), 1);
/// assert_eq!(decoded[0].cmd_type, 0x01);
/// assert_eq!(decoded[0].cmd_id, 0x01);
/// ```
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct FrameReassembler {
    buffer: Vec<u8>,
}

impl FrameReassembler {
    /// Creates an empty reassembler.
    #[must_use]
    pub const fn new() -> Self {
        Self { buffer: Vec::new() }
    }

    /// Appends `chunk` to the internal stream buffer, extracts all complete
    /// checksum-verified `09 FF 00 00` packets in arrival order, and compacts
    /// consumed prefix bytes.
    pub fn ingest(&mut self, chunk: &[u8]) -> Vec<DecodedPacket> {
        if !chunk.is_empty() {
            self.buffer.extend_from_slice(chunk);
        }
        ProtocolFrame::process_buffer(&mut self.buffer)
    }

    /// Returns the number of unconsumed partial bytes currently buffered.
    #[must_use]
    pub fn buffered_len(&self) -> usize {
        self.buffer.len()
    }

    /// Clears any partial trailing bytes.
    pub fn reset(&mut self) {
        self.buffer.clear();
    }
}

/// Decoded inbound RX packet from the D3200 device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedPacket {
    /// Complete wire bytes of the packet including header and checksum.
    pub raw: Vec<u8>,
    /// Status byte at offset 4.
    pub status_byte: u8,
    /// Command group identifier at offset 5.
    pub cmd_type: u8,
    /// Sub-command identifier at offset 6.
    pub cmd_id: u8,
    /// Packet payload slice (`raw[9..raw.len() - 1]`).
    pub payload: Vec<u8>,
}

impl DecodedPacket {
    /// Parses a verified RX packet slice (`len >= 10`) into a `DecodedPacket`.
    #[must_use]
    pub fn from_bytes(bytes: &[u8]) -> Self {
        let payload = if bytes.len() > 10 {
            bytes[9..bytes.len() - 1].to_vec()
        } else {
            Vec::new()
        };
        Self {
            raw: bytes.to_vec(),
            status_byte: bytes[4],
            cmd_type: bytes[5],
            cmd_id: bytes[6],
            payload,
        }
    }

    /// Low nibble of `status_byte`.
    #[must_use]
    pub const fn success_flag(&self) -> u8 {
        self.status_byte & 0x0F
    }

    /// High nibble of `status_byte`.
    #[must_use]
    pub const fn high_nibble(&self) -> u8 {
        (self.status_byte & 0xF0) >> 4
    }

    /// Whether the status byte indicates command success (`low_nibble == 1`).
    #[must_use]
    pub const fn is_success(&self) -> bool {
        self.success_flag() == 1 || self.status_byte == 1
    }
}

/// Reads a 16-bit little-endian unsigned integer from `b[offset..offset + 2]`.
#[must_use]
pub const fn read_u16_le(b: &[u8], offset: usize) -> u16 {
    (b[offset] as u16) | ((b[offset + 1] as u16) << 8)
}

/// Reads a 32-bit little-endian unsigned integer from `b[offset..offset + 4]`.
#[must_use]
pub const fn read_u32_le(b: &[u8], offset: usize) -> u32 {
    (b[offset] as u32)
        | ((b[offset + 1] as u32) << 8)
        | ((b[offset + 2] as u32) << 16)
        | ((b[offset + 3] as u32) << 24)
}

/// Encodes `v` as a 2-byte little-endian array.
#[must_use]
pub const fn u16_le(v: u16) -> [u8; 2] {
    v.to_le_bytes()
}

/// Encodes `v` as a 4-byte little-endian array.
#[must_use]
pub const fn u32_le(v: u32) -> [u8; 4] {
    v.to_le_bytes()
}

/// Formats `bytes` as uppercase space-separated two-digit hex bytes (`"08 EE 00"`).
#[must_use]
pub fn to_hex(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }
    let mut out = String::with_capacity(bytes.len() * 3 - 1);
    for (i, &b) in bytes.iter().enumerate() {
        if i > 0 {
            out.push(' ');
        }
        let hi = char::from_digit(u32::from(b >> 4), 16)
            .unwrap_or('0')
            .to_ascii_uppercase();
        let lo = char::from_digit(u32::from(b & 0x0F), 16)
            .unwrap_or('0')
            .to_ascii_uppercase();
        out.push(hi);
        out.push(lo);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::prng::SplitMix64;

    #[test]
    fn encode_and_verify_roundtrip() {
        let mut rng = SplitMix64::new(99);
        for _ in 0..100 {
            let cmd_type = rng.next_byte();
            let cmd_id = rng.next_byte();
            let len = (rng.next_byte() as usize) % 128;
            let payload = rng.next_bytes(len);
            let frame = ProtocolFrame::encode(cmd_type, cmd_id, &payload);
            assert!(ProtocolFrame::verify_checksum(&frame));
            assert_eq!(read_u16_le(&frame, 7) as usize, frame.len());
        }
    }

    #[test]
    fn process_buffer_skips_garbage_and_preserves_partial_tail() {
        let body = [
            0x09u8, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x0C, 0x00, 0x42, 0x43,
        ];
        let csum = ProtocolFrame::checksum(&body);
        let mut stream = vec![0xDE, 0xAD, 0xBE, 0xEF];
        stream.extend_from_slice(&body);
        stream.push(csum);
        stream.extend_from_slice(&[0x09, 0xFF, 0x00]);
        let pkts = ProtocolFrame::process_buffer(&mut stream);
        assert_eq!(pkts.len(), 1);
        assert_eq!(pkts[0].payload, vec![0x42, 0x43]);
        assert_eq!(stream, vec![0x09, 0xFF, 0x00]);
    }
}
