//! Provider transport contracts, RFC 6455 client-masked WebSocket frame codec,
//! DashScope streaming ASR frame pump, and credential readiness snapshots for Koe.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::collections::VecDeque;

pub mod offline_speech;
pub use offline_speech::{
    offline_speech_models, OfflineSpeechEvent, OfflineSpeechModel, OfflineSpeechSegment,
    OfflineSpeechWorker,
};

mod network;
pub use network::{
    LiveEvent, LiveTranscription, ProviderConfig, ProviderEvent, ProviderOutput, ProviderRequest,
    ProviderTask, ProviderWorker, TranscriptSegment, DASHSCOPE_ASR_ENDPOINT, DASHSCOPE_ASR_MODEL,
    DASHSCOPE_CHAT_ENDPOINT, DASHSCOPE_CHAT_MODEL,
};

pub use koe_engine::minutes::{
    encode_qwen_stream_finish_task_json, encode_qwen_stream_run_task_json, QwenStreamAccumulator,
    QwenStreamStep, QWEN_FILETRANS_DEFAULT_MODEL, QWEN_STREAMING_DEFAULT_MODEL,
};

/// Default speech window size in bytes (`3,200` bytes = 100 ms of 16 kHz mono PCM16 LE across 5 slices).
pub const ASR_SPEECH_WINDOW_PCM_BYTES: usize = 3_200;

/// Default RMS energy threshold above which a 16 kHz PCM16 frame is treated as active speech.
pub const ASR_DEFAULT_RMS_THRESHOLD: u16 = 120;

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

/// Outbound DashScope WebSocket frame queued by [`StreamingAsrPump`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OutboundAsrWsFrame {
    /// UTF-8 JSON control message (`run-task` or `finish-task`).
    TextJson(String),
    /// Binary 16 kHz mono PCM16 LE audio payload.
    BinaryPcm16(Vec<u8>),
}

impl OutboundAsrWsFrame {
    /// Encodes this outbound ASR frame into an RFC 6455 client-masked WebSocket wire frame.
    #[must_use]
    pub fn to_masked_wire_bytes(&self, mask_key: [u8; 4]) -> Vec<u8> {
        match self {
            Self::TextJson(text) => {
                encode_masked_ws_frame(WsFrameOpcode::Text, text.as_bytes(), mask_key)
            }
            Self::BinaryPcm16(pcm) => encode_masked_ws_frame(WsFrameOpcode::Binary, pcm, mask_key),
        }
    }
}

/// Completed 16 kHz speech energy window detected by [`StreamingAsrPump`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpeechWindowCommit {
    /// 1-based monotonic window index within the active recording session.
    pub window_index: u32,
    /// Start offset in milliseconds relative to the stream start.
    pub start_ms: u64,
    /// End offset in milliseconds relative to the stream start.
    pub end_ms: u64,
    /// Latest RMS energy computed for this window.
    pub rms: u16,
}

/// Self-driving streaming ASR pump that consumes 16 kHz mono PCM16 LE frames,
/// computes RMS voice activity, queues DashScope `run-task` + binary PCM frames,
/// and accumulates cloud WebSocket `result-generated` events.
///
/// Speech windows without an attached cloud WebSocket are tracked strictly as
/// offline buffered speech windows without ever fabricating fake Chinese sentences.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamingAsrPump {
    /// Streaming ASR model identifier (defaults to `"paraformer-realtime-v2"`).
    pub model: String,
    /// Active DashScope streaming task identifier.
    pub task_id: String,
    /// Whether an external cloud WebSocket client is attached and feeding `result-generated` JSON events.
    pub cloud_ws_attached: bool,
    /// PCM16 byte threshold per speech window (`3,200` bytes = 100 ms at 16 kHz mono).
    pub speech_window_bytes: usize,
    /// Minimum RMS energy threshold required to accumulate speech bytes (`120`).
    pub rms_threshold: u16,
    /// DashScope WebSocket `result-generated` stateful accumulator.
    pub qwen_accumulator: QwenStreamAccumulator,
    pcm_window_buf: Vec<u8>,
    total_pcm_bytes: u64,
    elapsed_stream_ms: u64,
    window_start_ms: u64,
    latest_rms: u16,
    committed_windows: u32,
    run_task_queued: bool,
    outbound_ws: VecDeque<OutboundAsrWsFrame>,
    queued_frame_count: u64,
}

impl Default for StreamingAsrPump {
    fn default() -> Self {
        Self::new("koe-suixin-live-task")
    }
}

impl StreamingAsrPump {
    /// Creates a new [`StreamingAsrPump`] for `task_id`.
    #[must_use]
    pub fn new(task_id: impl Into<String>) -> Self {
        Self {
            model: "paraformer-realtime-v2".to_string(),
            task_id: task_id.into(),
            cloud_ws_attached: false,
            speech_window_bytes: ASR_SPEECH_WINDOW_PCM_BYTES,
            rms_threshold: ASR_DEFAULT_RMS_THRESHOLD,
            qwen_accumulator: QwenStreamAccumulator::new(),
            pcm_window_buf: Vec::new(),
            total_pcm_bytes: 0,
            elapsed_stream_ms: 0,
            window_start_ms: 0,
            latest_rms: 0,
            committed_windows: 0,
            run_task_queued: false,
            outbound_ws: VecDeque::new(),
            queued_frame_count: 0,
        }
    }

    /// Resets transient window and accumulator state for a new recording session.
    pub fn reset_for_new_recording(&mut self) {
        self.task_id = uuid::Uuid::new_v4().to_string();
        self.cloud_ws_attached = false;
        self.outbound_ws.clear();
        self.queued_frame_count = 0;
        self.total_pcm_bytes = 0;
        self.latest_rms = 0;
        self.pcm_window_buf.clear();
        self.run_task_queued = false;
        self.elapsed_stream_ms = 0;
        self.window_start_ms = 0;
        self.committed_windows = 0;
        self.qwen_accumulator = QwenStreamAccumulator::new();
    }

    /// Computes the root-mean-square (RMS) energy of a 16-bit little-endian mono PCM buffer.
    #[must_use]
    pub fn compute_pcm16_rms(pcm16_le: &[u8]) -> u16 {
        let sample_count = pcm16_le.len() / 2;
        if sample_count == 0 {
            return 0;
        }
        let mut sum_sq: u128 = 0;
        for &pair in pcm16_le.as_chunks::<2>().0 {
            let sample = i16::from_le_bytes(pair) as i64;
            sum_sq += (sample * sample) as u128;
        }
        let mean_sq = (sum_sq / (sample_count as u128)) as f64;
        mean_sq.sqrt().round().min(f64::from(u16::MAX)) as u16
    }

    /// Pops the next outbound DashScope WebSocket frame (`TextJson` or `BinaryPcm16`).
    pub fn pop_outbound_ws_frame(&mut self) -> Option<OutboundAsrWsFrame> {
        self.outbound_ws.pop_front()
    }

    /// Returns 16 kHz mono PCM16 LE bytes processed within the current recording.
    #[must_use]
    pub const fn total_pcm_bytes(&self) -> u64 {
        self.total_pcm_bytes
    }

    /// Updates cumulative 16 kHz mono PCM16 LE bytes to at least `min_bytes`.
    pub fn ensure_total_pcm_bytes(&mut self, min_bytes: u64) {
        self.total_pcm_bytes = self.total_pcm_bytes.max(min_bytes);
    }

    /// Sets the latest RMS energy value directly.
    pub fn set_latest_rms(&mut self, rms: u16) {
        self.latest_rms = rms;
    }

    /// Returns the most recent RMS energy value computed from incoming 16 kHz PCM16 frames.
    #[must_use]
    pub const fn latest_rms(&self) -> u16 {
        self.latest_rms
    }

    /// Returns the elapsed stream duration in milliseconds.
    #[must_use]
    pub const fn elapsed_stream_ms(&self) -> u64 {
        self.elapsed_stream_ms
    }

    /// Returns the number of outbound WebSocket ASR frames queued within the current recording.
    #[must_use]
    pub const fn queued_frame_count(&self) -> u64 {
        self.queued_frame_count
    }

    /// Returns the number of speech windows committed by the pump.
    #[must_use]
    pub const fn committed_windows(&self) -> u32 {
        self.committed_windows
    }

    /// Returns `true` if a `run-task` frame is currently active or buffered PCM data is pending flush.
    #[must_use]
    pub fn has_pending_task(&self) -> bool {
        self.run_task_queued || !self.pcm_window_buf.is_empty()
    }

    /// Ensures the initial DashScope `run-task` frame is queued for the current recording session.
    pub fn ensure_run_task_queued(&mut self, hot_words: &[String]) {
        if !self.run_task_queued {
            self.run_task_queued = true;
            let run_json = encode_qwen_stream_run_task_json(&self.task_id, Some("zh"), hot_words);
            self.queue_frame(OutboundAsrWsFrame::TextJson(run_json));
        }
    }

    /// Ingests a 16 kHz mono PCM16 LE audio chunk, queues `run-task` + `BinaryPcm16`, and returns
    /// `(rms, chunk_ms, speech_detected, completed_windows)`.
    pub fn ingest_pcm16_chunk(
        &mut self,
        pcm16_le: &[u8],
        hot_words: &[String],
    ) -> (u16, u64, bool, Vec<SpeechWindowCommit>) {
        let rms = Self::compute_pcm16_rms(pcm16_le);
        let chunk_ms = (pcm16_le.len() as u64 / 32).max(20);
        self.latest_rms = rms;
        self.total_pcm_bytes = self.total_pcm_bytes.saturating_add(pcm16_le.len() as u64);
        self.elapsed_stream_ms = self.elapsed_stream_ms.saturating_add(chunk_ms);

        let speech_detected = rms >= self.rms_threshold;
        self.ensure_run_task_queued(hot_words);
        self.queue_frame(OutboundAsrWsFrame::BinaryPcm16(pcm16_le.to_vec()));

        let mut commits = Vec::new();
        if speech_detected {
            if self.pcm_window_buf.is_empty() {
                self.window_start_ms = self.elapsed_stream_ms.saturating_sub(chunk_ms);
            }
            self.pcm_window_buf.extend_from_slice(pcm16_le);

            let win_bytes = self.speech_window_bytes.max(640);
            while !self.cloud_ws_attached && self.pcm_window_buf.len() >= win_bytes {
                self.pcm_window_buf.drain(..win_bytes);
                self.committed_windows = self.committed_windows.saturating_add(1);
                let start_ms = self.window_start_ms;
                let win_ms = (win_bytes as u64 / 32).max(20);
                let end_ms = start_ms.saturating_add(win_ms);
                self.window_start_ms = end_ms;
                commits.push(SpeechWindowCommit {
                    window_index: self.committed_windows,
                    start_ms,
                    end_ms,
                    rms,
                });
            }
        }
        (rms, chunk_ms, speech_detected, commits)
    }

    /// Flushes any remaining buffered PCM window and queues the DashScope `finish-task` JSON frame.
    pub fn flush_and_finish_task(&mut self, hot_words: &[String]) -> Option<SpeechWindowCommit> {
        let mut final_commit = None;
        if !self.pcm_window_buf.is_empty() {
            let rem_bytes = self.pcm_window_buf.len();
            self.pcm_window_buf.clear();
            if !self.cloud_ws_attached {
                self.committed_windows = self.committed_windows.saturating_add(1);
                let start_ms = self.window_start_ms;
                let win_ms = (rem_bytes as u64 / 32).max(20);
                let end_ms = start_ms.saturating_add(win_ms);
                self.window_start_ms = end_ms;
                final_commit = Some(SpeechWindowCommit {
                    window_index: self.committed_windows,
                    start_ms,
                    end_ms,
                    rms: self.latest_rms,
                });
            }
        }
        if !self.run_task_queued {
            let run_json = encode_qwen_stream_run_task_json(&self.task_id, Some("zh"), hot_words);
            self.queue_frame(OutboundAsrWsFrame::TextJson(run_json));
        }
        let finish_json = encode_qwen_stream_finish_task_json(&self.task_id);
        self.queue_frame(OutboundAsrWsFrame::TextJson(finish_json));
        self.run_task_queued = false;
        final_commit
    }

    fn queue_frame(&mut self, frame: OutboundAsrWsFrame) {
        self.outbound_ws.push_back(frame);
        self.queued_frame_count = self.queued_frame_count.saturating_add(1);
    }
}

/// Value snapshot of the Aliyun DashScope ASR and Qwen minutes configuration.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DashScopeConfigSnapshot {
    /// Active streaming ASR model identifier (`"paraformer-realtime-v2"`).
    pub streaming_asr_model: String,
    /// Active batch file transcription model identifier (`"qwen-audio-3.1-asr-flash-filetrans"`).
    pub filetrans_asr_model: String,
    /// Whether a cloud WebSocket ASR stream is currently attached.
    pub cloud_ws_attached: bool,
    /// Total outbound WebSocket ASR frames queued by the pump.
    pub queued_asr_frames: u64,
    /// Total speech windows committed by the pump.
    pub committed_speech_windows: u32,
    /// Total custom hotwords registered in the workspace.
    pub active_hotword_count: usize,
    /// Whether `DASHSCOPE_API_KEY` is present and non-empty in the environment (boolean only).
    pub api_key_configured: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rfc6455_masked_ws_frame_roundtrips_short_and_extended_payloads() {
        let mask = [0x37, 0xFA, 0x21, 0x3D];
        let text_frame =
            OutboundAsrWsFrame::TextJson("{\"header\":{\"action\":\"run-task\"}}".into());
        let wire = text_frame.to_masked_wire_bytes(mask);
        assert_eq!(wire[0], 0x81);
        assert_ne!(wire[1] & 0x80, 0);
        let (decoded, consumed) = decode_ws_frame(&wire).expect("decode short text frame");
        assert_eq!(consumed, wire.len());
        assert!(decoded.fin);
        assert!(decoded.masked);
        assert_eq!(decoded.opcode, WsFrameOpcode::Text);
        assert_eq!(
            String::from_utf8(decoded.payload).expect("utf8"),
            "{\"header\":{\"action\":\"run-task\"}}"
        );

        let pcm = vec![0x5Au8; 640];
        let bin_frame = OutboundAsrWsFrame::BinaryPcm16(pcm.clone());
        let bin_wire = bin_frame.to_masked_wire_bytes(mask);
        assert_eq!(bin_wire[0], 0x82);
        assert_eq!(bin_wire[1], 0x80 | 126);
        let (decoded_bin, consumed_bin) =
            decode_ws_frame(&bin_wire).expect("decode 16-bit extended binary frame");
        assert_eq!(consumed_bin, bin_wire.len());
        assert_eq!(decoded_bin.opcode, WsFrameOpcode::Binary);
        assert_eq!(decoded_bin.payload, pcm);
    }
}
