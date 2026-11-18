//! Provider transport contracts, RFC 6455 client-masked WebSocket frame codec,
//! offline speech worker, and streaming provider workers for Koe.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod offline_speech;
pub use offline_speech::{
    offline_speech_models, OfflineSpeechEvent, OfflineSpeechModel, OfflineSpeechSegment,
    OfflineSpeechWorker,
};

mod network;
pub use network::{
    parse_release_payload, validate_update_endpoint, LiveEvent, LiveTranscription, ProviderConfig,
    ProviderEvent, ProviderLane, ProviderOutput, ProviderPool, ProviderRequest, ProviderTask,
    ReleaseAsset, RemoteRelease, TranscriptSegment, UpdateCheckOutcome, DASHSCOPE_ASR_ENDPOINT,
    DASHSCOPE_ASR_MODEL, DASHSCOPE_CHAT_ENDPOINT, DASHSCOPE_CHAT_MODEL,
};

/// RFC 6455 WebSocket frame opcode used by DashScope.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WsFrameOpcode {
    /// UTF-8 text frame (`0x1`, used for `run-task`, `finish-task`, and `result-generated` JSON).
    Text,
    /// Binary frame (`0x2`, used for 16 kHz mono PCM16 LE audio chunks).
    Binary,
    /// Connection close frame (`0x8`).
    Close,
    /// Ping control frame (`0x9`).
    Ping,
    /// Pong control frame (`0xA`).
    Pong,
}

impl WsFrameOpcode {
    /// Returns the 4-bit RFC 6455 wire opcode value.
    #[must_use]
    pub const fn to_u8(self) -> u8 {
        match self {
            Self::Text => 0x1,
            Self::Binary => 0x2,
            Self::Close => 0x8,
            Self::Ping => 0x9,
            Self::Pong => 0xA,
        }
    }

    /// Parses a 4-bit RFC 6455 wire opcode value.
    #[must_use]
    pub const fn from_u8(raw: u8) -> Option<Self> {
        match raw & 0x0F {
            0x1 => Some(Self::Text),
            0x2 => Some(Self::Binary),
            0x8 => Some(Self::Close),
            0x9 => Some(Self::Ping),
            0xA => Some(Self::Pong),
            _ => None,
        }
    }
}

/// Decoded RFC 6455 WebSocket frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecodedWsFrame {
    /// Whether the `FIN` bit (`0x80`) was set.
    pub fin: bool,
    /// Frame opcode.
    pub opcode: WsFrameOpcode,
    /// Whether the frame payload was client-masked on the wire.
    pub masked: bool,
    /// Unmasked payload bytes.
    pub payload: Vec<u8>,
}

/// Encodes an RFC 6455 client-to-server masked WebSocket frame (`FIN = 1`, `MASK = 1`).
///
///Per RFC 6455 Section 5.3, all client-to-server frames sent to DashScope
/// must set the `MASK` bit (`0x80` in byte 1) and XOR the payload with a 4-byte `mask_key`.
#[must_use]
pub fn encode_masked_ws_frame(opcode: WsFrameOpcode, payload: &[u8], mask_key: [u8; 4]) -> Vec<u8> {
    let len = payload.len();
    let header_len = if len <= 125 {
        2
    } else if len <= 65_535 {
        4
    } else {
        10
    };
    let mut out = Vec::with_capacity(header_len + 4 + len);
    out.push(0x80 | opcode.to_u8());
    if len <= 125 {
        out.push(0x80 | (len as u8));
    } else if len <= 65_535 {
        out.push(0x80 | 126);
        out.extend_from_slice(&(len as u16).to_be_bytes());
    } else {
        out.push(0x80 | 127);
        out.extend_from_slice(&(len as u64).to_be_bytes());
    }
    out.extend_from_slice(&mask_key);
    for (idx, &byte) in payload.iter().enumerate() {
        out.push(byte ^ mask_key[idx & 3]);
    }
    out
}

/// Decodes a single RFC 6455 WebSocket frame (masked or unmasked) from `wire`,
/// returning `(DecodedWsFrame, consumed_bytes)`.
pub fn decode_ws_frame(wire: &[u8]) -> Result<(DecodedWsFrame, usize), &'static str> {
    if wire.len() < 2 {
        return Err("WebSocket frame shorter than 2-byte header");
    }
    let b0 = wire[0];
    let b1 = wire[1];
    let fin = (b0 & 0x80) != 0;
    let opcode = WsFrameOpcode::from_u8(b0 & 0x0F).ok_or("unsupported WebSocket opcode")?;
    let masked = (b1 & 0x80) != 0;
    let len_code = (b1 & 0x7F) as usize;

    let (payload_len, mut cursor) = if len_code <= 125 {
        (len_code, 2usize)
    } else if len_code == 126 {
        if wire.len() < 4 {
            return Err("truncated 16-bit WebSocket extended payload length");
        }
        let ext = u16::from_be_bytes([wire[2], wire[3]]) as usize;
        (ext, 4usize)
    } else {
        if wire.len() < 10 {
            return Err("truncated 64-bit WebSocket extended payload length");
        }
        let mut arr = [0u8; 8];
        arr.copy_from_slice(&wire[2..10]);
        let ext = usize::try_from(u64::from_be_bytes(arr))
            .map_err(|_| "WebSocket payload length exceeds platform usize")?;
        (ext, 10usize)
    };

    let mask_key = if masked {
        if wire.len() < cursor + 4 {
            return Err("truncated 4-byte WebSocket masking key");
        }
        let key = [
            wire[cursor],
            wire[cursor + 1],
            wire[cursor + 2],
            wire[cursor + 3],
        ];
        cursor += 4;
        Some(key)
    } else {
        None
    };

    let end = cursor
        .checked_add(payload_len)
        .ok_or("WebSocket frame length overflow")?;
    if wire.len() < end {
        return Err("truncated WebSocket frame payload");
    }

    let mut payload = wire[cursor..end].to_vec();
    if let Some(key) = mask_key {
        for (idx, byte) in payload.iter_mut().enumerate() {
            *byte ^= key[idx & 3];
        }
    }

    Ok((
        DecodedWsFrame {
            fin,
            opcode,
            masked,
            payload,
        },
        end,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc6455_masked_ws_frame_roundtrips_short_and_extended_payloads() {
        let mask = [0x37, 0xFA, 0x21, 0x3D];
        let json_text = "{\"header\":{\"action\":\"run-task\"}}";
        let wire = encode_masked_ws_frame(WsFrameOpcode::Text, json_text.as_bytes(), mask);
        assert_eq!(wire[0], 0x81);
        assert_ne!(wire[1] & 0x80, 0);
        let (decoded, consumed) = decode_ws_frame(&wire).expect("decode short text frame");
        assert_eq!(consumed, wire.len());
        assert!(decoded.fin);
        assert!(decoded.masked);
        assert_eq!(decoded.opcode, WsFrameOpcode::Text);
        assert_eq!(String::from_utf8(decoded.payload).expect("utf8"), json_text);

        let pcm = vec![0x5Au8; 640];
        let bin_wire = encode_masked_ws_frame(WsFrameOpcode::Binary, &pcm, mask);
        assert_eq!(bin_wire[0], 0x82);
        assert_eq!(bin_wire[1], 0x80 | 126);
        let (decoded_bin, consumed_bin) =
            decode_ws_frame(&bin_wire).expect("decode 16-bit extended binary frame");
        assert_eq!(consumed_bin, bin_wire.len());
        assert_eq!(decoded_bin.opcode, WsFrameOpcode::Binary);
        assert_eq!(decoded_bin.payload, pcm);
    }
}
