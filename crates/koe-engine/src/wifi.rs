//! D3200 Wi-Fi SoftAP endpoint parser (`0x1A / 0x05`), UDP `:32003` keepalive
//! constants, WebSocket frame normalizer, and batch sync progress models.
//!
//! # Examples
//!
//! ```
//! use koe_engine::wifi::{WifiEndpoint, WIFI_KEEPALIVE_PAYLOAD};
//!
//! let raw = [
//!     0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x10, 0x00, 0x01, 0x2B, 0xA8, 0xC0, 0xBB, 0x01,
//!     0x8D,
//! ];
//! let ep = WifiEndpoint::parse_config_response(&raw).unwrap();
//! assert_eq!(ep.ip, [192, 168, 43, 1]);
//! assert_eq!(ep.port, 443);
//! assert!(WifiEndpoint::shares_ipv4_subnet(ep.ip, [192, 168, 43, 105]));
//! assert_eq!(WIFI_KEEPALIVE_PAYLOAD.len(), 28);
//! ```

use crate::frame::read_u16_le;

/// Exact 28-byte ASCII payload sent to UDP `:32003` every 2,000 ms to keep the D3200 SoftAP alive.
pub const WIFI_KEEPALIVE_PAYLOAD: &[u8; 28] = b"soundcore-keep-alive-unicast";

/// Destination UDP port on the D3200 recording bean for unicast keepalive datagrams.
pub const WIFI_UDP_PORT: u16 = 32003;

/// Default WebSocket / WSS port on the D3200 recording bean when not overridden by `1A/05`.
pub const WIFI_DEFAULT_WS_PORT: u16 = 32002;

/// Interval in milliseconds between UDP `:32003` keepalive datagrams.
pub const WIFI_KEEPALIVE_INTERVAL_MS: u64 = 2_000;

/// Text frame sent over the WebSocket prior to the `1A/0A` hex frame when closing a batch.
pub const WIFI_WS_FINISH_TEXT: &str = "FINISH";

/// IPv4 address and TCP port reported by the D3200 in its `0x1A / 0x05` SoftAP response.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct WifiEndpoint {
    /// IPv4 address octets in network order (`[a, b, c, d]`).
    pub ip: [u8; 4],
    /// TCP port for the embedded WebSocket / WSS server.
    pub port: u16,
}

impl WifiEndpoint {
    /// Parses a full `0x1A / 0x05` RX frame (`raw.len() >= 15`), extracting the reversed
    /// IPv4 octets (`raw[12..=9]`) and little-endian TCP port (`raw[13..15]`).
    #[must_use]
    pub fn parse_config_response(raw: &[u8]) -> Option<Self> {
        if raw.len() < 15 {
            return None;
        }
        if raw[5] != 0x1A || raw[6] != 0x05 {
            return None;
        }
        if (raw[4] & 0x0F) != 1 && raw[4] != 1 {
            return None;
        }
        let port = read_u16_le(raw, 13);
        if port == 0 {
            return None;
        }
        let ip = [raw[12], raw[11], raw[10], raw[9]];
        Some(Self { ip, port })
    }

    /// Returns `true` when `device_ip` and `local_ip` share the same `/24` IPv4 prefix
    /// and have distinct host octets.
    #[must_use]
    pub const fn shares_ipv4_subnet(device_ip: [u8; 4], local_ip: [u8; 4]) -> bool {
        device_ip[0] == local_ip[0]
            && device_ip[1] == local_ip[1]
            && device_ip[2] == local_ip[2]
            && device_ip[3] != local_ip[3]
    }

    /// Formats the IPv4 address as a dotted quad string (`"a.b.c.d"`).
    #[must_use]
    pub fn ip_string(&self) -> String {
        format!(
            "{}.{}.{}.{}",
            self.ip[0], self.ip[1], self.ip[2], self.ip[3]
        )
    }
}

/// Lifecycle phase of a D3200 Wi-Fi SoftAP batch transfer.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum WifiBatchPhase {
    /// No Wi-Fi batch transfer active.
    #[default]
    Idle = 0,
    /// Waiting for the SoftAP WebSocket link to connect.
    ConnectingWs = 1,
    /// Actively requesting and receiving files over WebSocket / UDP.
    Transferring = 2,
    /// Hotspot or WebSocket link dropped mid-batch; resumable via `resume_wifi_batch`.
    Interrupted = 3,
    /// All queued files have been finalized or skipped and `FINISH` + `1A/0A` queued.
    Completed = 4,
    /// Batch stopped with an unrecoverable device error.
    Failed = 5,
}

/// Snapshot of a D3200 Wi-Fi SoftAP batch sync session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct WifiBatchProgress {
    /// Current Wi-Fi batch phase.
    pub phase: WifiBatchPhase,
    /// Last device error code observed during the batch (`0` when none).
    pub error_code: u8,
    /// Zero-based index of the active file in the batch queue (`total_files` when completed).
    pub current_file_index: u32,
    /// Total number of files requested in this batch.
    pub total_files: u32,
    /// D3200 file ID currently being transferred (`0` when idle or completed).
    pub active_file_id: u32,
    /// Wire record bytes received for the active file (`slices * 166`).
    pub received_wire_bytes: u32,
    /// Expected wire record bytes for the active file from `1A/07` (`0` before header).
    pub expected_wire_bytes: u32,
    /// Number of files completed normally during this batch.
    pub finalized_count: u32,
    /// Number of nearly-complete (`>= 95%`) files salvaged on link interruption.
    pub salvaged_count: u32,
    /// Number of files skipped due to device `1A/07` error code `1` or `3`.
    pub skipped_count: u32,
    /// Number of files remaining in the queue (including the active file if unfinalized).
    pub remaining_count: u32,
}

/// Normalizes an inbound WebSocket message (binary frame or hex-encoded text frame)
/// or UDP `:32003` datagram into raw `09 FF 00 00` protocol bytes.
///
/// Short control strings (`"ACK"`, `"OK"`, `"PONG"`, or ASCII text shorter than 20 characters)
/// return `None`.
#[must_use]
pub fn normalize_wifi_chunk(chunk: &[u8]) -> Option<Vec<u8>> {
    if chunk.is_empty() {
        return None;
    }
    if chunk[0] == 0x09 {
        return Some(chunk.to_vec());
    }
    if chunk
        .iter()
        .all(|&b| b.is_ascii_graphic() || b.is_ascii_whitespace())
    {
        let text = core::str::from_utf8(chunk).ok()?.trim();
        if text.len() < 20
            || text.eq_ignore_ascii_case("ACK")
            || text.eq_ignore_ascii_case("OK")
            || text.eq_ignore_ascii_case("PONG")
        {
            return None;
        }
        if text.as_bytes().get(0..2)?.eq_ignore_ascii_case(b"09") {
            let mut hex_nybbles = Vec::with_capacity(text.len());
            for &b in text.as_bytes() {
                if b.is_ascii_whitespace() {
                    continue;
                }
                let val = match b {
                    b'0'..=b'9' => b - b'0',
                    b'a'..=b'f' => b - b'a' + 10,
                    b'A'..=b'F' => b - b'A' + 10,
                    _ => return None,
                };
                hex_nybbles.push(val);
            }
            if hex_nybbles.len() >= 20 && hex_nybbles.len() % 2 == 0 {
                let mut out = Vec::with_capacity(hex_nybbles.len() / 2);
                for pair in hex_nybbles.as_chunks::<2>().0 {
                    out.push((pair[0] << 4) | pair[1]);
                }
                return Some(out);
            }
        }
        return None;
    }
    Some(chunk.to_vec())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_config_response_reverses_ipv4_and_reads_le_port() {
        let frame = [
            0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x10, 0x00, 0x01, 0x2B, 0xA8, 0xC0, 0x02,
            0x7D, 0x00,
        ];
        let ep = WifiEndpoint::parse_config_response(&frame).unwrap();
        assert_eq!(ep.ip, [192, 168, 43, 1]);
        assert_eq!(ep.ip_string(), "192.168.43.1");
        assert_eq!(ep.port, 32002);

        let failed = [
            0x09, 0xFF, 0x00, 0x00, 0x00, 0x1A, 0x05, 0x10, 0x00, 0x01, 0x2B, 0xA8, 0xC0, 0x02,
            0x7D, 0x00,
        ];
        assert!(WifiEndpoint::parse_config_response(&failed).is_none());

        let zero_port = [
            0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x05, 0x10, 0x00, 0x01, 0x2B, 0xA8, 0xC0, 0x00,
            0x00, 0x00,
        ];
        assert!(WifiEndpoint::parse_config_response(&zero_port).is_none());
    }

    #[test]
    fn shares_ipv4_subnet_requires_matching_slash24_and_distinct_host() {
        assert!(WifiEndpoint::shares_ipv4_subnet(
            [192, 168, 43, 1],
            [192, 168, 43, 20]
        ));
        assert!(!WifiEndpoint::shares_ipv4_subnet(
            [192, 168, 43, 1],
            [192, 168, 43, 1]
        ));
        assert!(!WifiEndpoint::shares_ipv4_subnet(
            [192, 168, 43, 1],
            [192, 168, 44, 20]
        ));
    }

    #[test]
    fn normalize_wifi_chunk_handles_binary_hex_and_control_strings() {
        assert!(normalize_wifi_chunk(b"").is_none());
        assert!(normalize_wifi_chunk(b"ACK").is_none());
        assert!(normalize_wifi_chunk(b" ok \r\n").is_none());
        assert!(normalize_wifi_chunk(b"PONG").is_none());
        assert!(normalize_wifi_chunk(b"short_status").is_none());

        let hex = b"09ff0000011a0a0b000127";
        let decoded = normalize_wifi_chunk(hex).unwrap();
        assert_eq!(
            decoded,
            vec![0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x0A, 0x0B, 0x00, 0x01, 0x27]
        );

        let raw = [
            0x09, 0xFF, 0x00, 0x00, 0x01, 0x1A, 0x0A, 0x0B, 0x00, 0x01, 0x27,
        ];
        assert_eq!(normalize_wifi_chunk(&raw).unwrap(), raw);
    }
}
