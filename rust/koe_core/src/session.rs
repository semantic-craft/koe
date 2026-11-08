//! Stateful D3200 transport session state machine (`01/01` telemetry, `2E/01` ECDH
//! handshake verification, `1A/01`–`1B/0E` offline catalog, `1A/07` encrypted file
//! head, `1A/08` 166-byte slice decryptor & mark accumulator, and `1A/0A` Ogg Opus/WAV
//! finalizer).
//!
//! # Examples
//!
//! ```
//! use koe_core::session::TransportSession;
//!
//! let mut session = TransportSession::new();
//! let finalized = session.simulate_realtime_pipeline(1_700_000_000);
//! assert_eq!(finalized.entry.id, 20261107);
//! assert_eq!(finalized.entry.marks_ms, vec![300, 900]);
//! assert!(finalized.ogg_opus_bytes.starts_with(b"OggS"));
//! assert!(finalized.preview_wav_bytes.starts_with(b"RIFF"));
//! ```

use std::collections::VecDeque;

use crate::commands::DeviceCommands;
use crate::crypto::{AesCtrStreamDecrypt, AudioFileSecretKey, DeviceCrypto};
use crate::frame::{read_u32_le, FrameReassembler, ProtocolFrame, RX_MAGIC};
use crate::library::RecordingEntry;
use crate::models::{DeviceInfoModel, OfflineFileEntry, OfflineFileList};
use crate::ogg_opus::OggOpus;
use crate::slice_marks::SliceMark;
use crate::transport::{
    OpenedFileHead, TransportSliceProcessor, OPUS_FRAME_BYTES, SLICE_RECORD_BYTES,
    UNFINISHED_FILE_SIZE,
};
use crate::wav::{
    default_opus_decoder_factory, OpusDecoderFactory, OpusStreamDecoder, OpusWave,
    ASR_SAMPLE_RATE, WAV_SAMPLE_RATE,
};
use crate::wifi::{
    normalize_wifi_chunk, WifiBatchPhase, WifiBatchProgress, WifiEndpoint, WIFI_KEEPALIVE_INTERVAL_MS,
    WIFI_KEEPALIVE_PAYLOAD, WIFI_WS_FINISH_TEXT,
};

/// Canonical 20 ms mono Opus packet (`libopus` 1.5.2, 440 Hz sine, 24 kbps VoIP, 94 bytes).
///
/// Decodes to 320 samples (640 bytes) at 16 kHz with sample 130 equal to `-4130` (`±16`),
/// and 960 samples (1920 bytes) at 48 kHz.
pub const REAL_OPUS_20MS_440HZ_PACKET: [u8; 94] = [
    0x78, 0x81, 0xa7, 0x5d, 0x6c, 0x9e, 0x99, 0xac, 0x00, 0x00, 0x06, 0x7e, 0x56, 0x39, 0xf7, 0x3b,
    0x1e, 0xa2, 0xdc, 0x31, 0x0f, 0x52, 0x38, 0x39, 0x39, 0x3e, 0xa3, 0xd0, 0x84, 0x47, 0xcb, 0xe1,
    0xb6, 0xb8, 0xff, 0x44, 0x14, 0x3d, 0x76, 0x21, 0xaf, 0x07, 0x34, 0xdd, 0x07, 0x87, 0xec, 0x99,
    0xfe, 0xc0, 0xf5, 0x44, 0x18, 0x9d, 0x5f, 0x48, 0x29, 0x42, 0xde, 0xd8, 0x2f, 0x85, 0xb6, 0x18,
    0xf4, 0x3b, 0x64, 0x92, 0xde, 0x94, 0x70, 0x50, 0xe0, 0x97, 0x68, 0x7d, 0x6c, 0x10, 0xd0, 0xaf,
    0x63, 0x85, 0x53, 0xa2, 0x71, 0x65, 0xe7, 0x91, 0x29, 0x01, 0x80, 0x53, 0x15, 0x04,
];

/// Per-frame inactivity timeout in milliseconds before the offline pull watchdog retries.
pub const OFFLINE_WATCHDOG_TIMEOUT_MS: u64 = 5_000;

/// Maximum number of watchdog retries allowed per offline file transfer.
pub const OFFLINE_MAX_RETRIES: u8 = 2;

/// Post-stop quiet-drain window in milliseconds before finalizing a realtime stream.
pub const REALTIME_QUIET_DRAIN_MS: u64 = 2_000;

/// Synthetic error code reported when an offline pull exhausts its watchdog retries.
pub const TRANSFER_ERR_WATCHDOG_TIMEOUT: u8 = 0xFE;

/// Connection phase of the D3200 transport session.
#[repr(u8)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ConnectionPhaseTag {
    /// Not connected to a recording bean.
    #[default]
    Disconnected = 0,
    /// Scanning for D3200 advertisements.
    Scanning = 1,
    /// Connecting to a discovered peripheral.
    Connecting = 2,
    /// Performing `2E/01` ECDH + `01/01` handshake.
    Handshaking = 3,
    /// Connected with device telemetry.
    Connected = 4,
}

/// Active file transfer phase on the D3200 transport session.
#[repr(u8)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum TransferPhaseTag {
    /// No active transfer.
    #[default]
    Idle = 0,
    /// Querying offline file catalog (`1A/01`).
    QueryingCatalog = 1,
    /// Pulling an offline recording from the bean.
    PullingOffline = 2,
    /// Receiving a live recording stream (`file_size == 0xFFFFFFFF`).
    StreamingRealtime = 3,
    /// Transfer failed.
    Failed = 4,
}

/// Algebraic internal state machine governing transfer timers, retries, and suspension.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum TransferRuntimeState {
    /// No transfer in flight.
    #[default]
    Idle,
    /// Waiting for an offline catalog response (`1A/01`–`1B/0E`).
    QueryingCatalog,
    /// Actively pulling an offline recording with watchdog supervision.
    PullingOffline {
        /// Active D3200 file identifier.
        file_id: u32,
        /// Expected wire bytes (`slices * 166`).
        expected_wire_bytes: u32,
        /// Elapsed milliseconds since the last received slice packet.
        inactivity_ms: u64,
        /// Number of watchdog retries used (`0..=2`).
        retries_used: u8,
    },
    /// Offline pull paused across a transient BLE link drop, preserving partial slices.
    Suspended {
        /// Active D3200 file identifier.
        file_id: u32,
        /// Expected wire bytes (`slices * 166`).
        expected_wire_bytes: u32,
        /// Number of watchdog retries used prior to suspension.
        retries_used: u8,
    },
    /// Receiving a live recording stream (`file_size == 0xFFFFFFFF`).
    StreamingRealtime {
        /// Active D3200 file identifier.
        file_id: u32,
        /// `Some(elapsed_ms)` once stop/pause enters the 2,000 ms quiet-drain window.
        quiet_drain_elapsed_ms: Option<u64>,
    },
    /// Transfer failed with a device or watchdog error code.
    Failed {
        /// D3200 file identifier that failed.
        file_id: u32,
        /// Device or watchdog error code (`0xFE` on timeout).
        error_code: u8,
    },
}

/// Snapshot of active transfer progress.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct TransferProgress {
    /// Current transfer phase tag.
    pub phase: TransferPhaseTag,
    /// Active D3200 file ID (`0` when idle).
    pub file_id: u32,
    /// Wire record bytes received (`slices * 166`).
    pub received_wire_bytes: u32,
    /// Expected wire bytes (`0` for live stream).
    pub expected_wire_bytes: u32,
    /// Number of unique hardware double-tap marks accumulated.
    pub mark_count: u32,
    /// Device error code when `phase == Failed`.
    pub error_code: u8,
    /// Number of watchdog retries used (`0..=2`) for the active offline file.
    pub retry_count: u8,
    /// Whether the realtime stream is in its 2,000 ms post-stop quiet-drain window.
    pub quiet_draining: bool,
}

/// Complete finalized recording artifacts produced when `1A/0A` or explicit
/// finalization completes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FinalizedRecording {
    /// Recording metadata and sorted mark positions in milliseconds.
    pub entry: RecordingEntry,
    /// Complete Ogg Opus container bytes (`OggS...`).
    pub ogg_opus_bytes: Vec<u8>,
    /// Complete 48 kHz mono PCM16 preview WAV bytes (`RIFF...`) with 880 Hz mark chimes.
    pub preview_wav_bytes: Vec<u8>,
}

/// Coarse batch outcome of ingesting a BLE notification chunk into `TransportSession`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SessionIngestOutcome {
    /// Number of complete checksum-verified RX frames decoded from the chunk.
    pub frames_decoded: u32,
    /// Whether `01/01` telemetry was updated during this step.
    pub telemetry_updated: bool,
    /// Whether `2E/01` session key was established during this step.
    pub session_key_established: bool,
    /// Whether `1A/01`/`1A/0D`/`1B/0E` catalog was updated during this step.
    pub catalog_updated: bool,
    /// Whether active transfer progress changed during this step.
    pub transfer_updated: bool,
    /// Number of 160-byte Opus slices unpacked during this step.
    pub slices_unpacked_count: u32,
    /// Newly observed mark positions in milliseconds during this step.
    pub new_marks_ms: Vec<u64>,
    /// Newly decoded 16 kHz mono PCM16 LE bytes produced during this step.
    pub live_pcm16_16khz: Vec<u8>,
    /// Finalized recording if `1A/0A` completed during this step.
    pub finalized: Option<FinalizedRecording>,
    /// Outbound TX command frames queued by protocol transitions.
    pub outbound_tx_frames: Vec<Vec<u8>>,
}

/// Stateful D3200 transport session engine.
pub struct TransportSession {
    /// Streaming packet reassembler.
    pub reassembler: FrameReassembler,
    /// Current connection phase.
    pub connection_phase: ConnectionPhaseTag,
    /// Latest parsed device telemetry (`01/01`).
    pub telemetry: Option<DeviceInfoModel>,
    /// Ephemeral 32-byte NIST P-256 private scalar for the active `2E/01` ECDH handshake.
    pub ecdh_private_key: Option<[u8; 32]>,
    /// Unwrapped 32-byte HKDF session key (`2E/01`).
    pub session_key: Option<[u8; 32]>,
    /// Latest offline catalog entries (`1A/01`/`1A/0D`/`1B/0E`).
    pub catalog: Vec<OfflineFileEntry>,
    /// Current transfer progress snapshot.
    pub transfer: TransferProgress,
    /// Algebraic runtime state governing transfer supervision, retries, and suspension.
    pub runtime_state: TransferRuntimeState,
    /// Active file ID being transferred or streamed.
    pub active_file_id: Option<u32>,
    /// Unwrapped 32-byte per-file AES-256 key (`1A/07`).
    pub active_file_key: Option<[u8; 32]>,
    /// 16-byte per-file AES-CTR nonce (`1A/07`).
    pub active_nonce: Option<[u8; 16]>,
    /// Whether the active transfer is a live stream (`unfinished == true`).
    pub active_is_realtime: bool,
    /// Accumulated decrypted 160-byte Opus frames.
    pub opus_buffer: Vec<u8>,
    /// Sorted, deduplicated double-tap mark positions in milliseconds.
    pub marks_ms: Vec<u64>,
    /// Most recently finalized recording artifact ready for FFI retrieval.
    pub last_finalized: Option<FinalizedRecording>,
    /// FIFO queue of finalized recordings produced during multi-file batches.
    pub finalized_queue: VecDeque<FinalizedRecording>,
    /// Accumulated 16 kHz mono PCM16 LE bytes ready to drain via `take_live_pcm16`.
    pub live_pcm16_16khz: Vec<u8>,
    /// Latest parsed `1A/05` Wi-Fi SoftAP endpoint (`ip:port`).
    pub wifi_endpoint: Option<WifiEndpoint>,
    /// Ordered queue of D3200 file IDs scheduled for Wi-Fi SoftAP batch export.
    pub wifi_queue: Vec<u32>,
    /// Zero-based index of the active file inside `wifi_queue`.
    pub wifi_current_index: usize,
    /// Current Wi-Fi SoftAP batch lifecycle phase.
    pub wifi_batch_phase: WifiBatchPhase,
    /// Number of files completed normally during the current Wi-Fi batch.
    pub wifi_finalized_count: u32,
    /// Number of files (`>= 95%` wire bytes) salvaged upon Wi-Fi interruption.
    pub wifi_salvaged_count: u32,
    /// Number of files skipped due to `1A/07` error code `1` or `3`.
    pub wifi_skipped_count: u32,
    /// Outbound WebSocket text frames (`1A/07` 36-char hex, `"FINISH"`, `1A/0A` 22-char hex).
    pub wifi_outbound_ws: VecDeque<String>,
    /// Outbound UDP `:32003` keepalive datagrams (`"soundcore-keep-alive-unicast"`).
    pub wifi_outbound_udp: VecDeque<Vec<u8>>,
    /// Elapsed milliseconds since the last UDP `:32003` keepalive datagram was queued.
    pub wifi_keepalive_elapsed_ms: u64,
    decoder_factory: Option<OpusDecoderFactory>,
    live_decoder_16k: Option<Box<dyn OpusStreamDecoder>>,
}

impl Default for TransportSession {
    fn default() -> Self {
        Self::with_decoder_factory(None)
    }
}

impl Clone for TransportSession {
    fn clone(&self) -> Self {
        Self {
            reassembler: self.reassembler.clone(),
            connection_phase: self.connection_phase,
            telemetry: self.telemetry.clone(),
            ecdh_private_key: self.ecdh_private_key,
            session_key: self.session_key,
            catalog: self.catalog.clone(),
            transfer: self.transfer,
            runtime_state: self.runtime_state.clone(),
            active_file_id: self.active_file_id,
            active_file_key: self.active_file_key,
            active_nonce: self.active_nonce,
            active_is_realtime: self.active_is_realtime,
            opus_buffer: self.opus_buffer.clone(),
            marks_ms: self.marks_ms.clone(),
            last_finalized: self.last_finalized.clone(),
            finalized_queue: self.finalized_queue.clone(),
            live_pcm16_16khz: self.live_pcm16_16khz.clone(),
            wifi_endpoint: self.wifi_endpoint,
            wifi_queue: self.wifi_queue.clone(),
            wifi_current_index: self.wifi_current_index,
            wifi_batch_phase: self.wifi_batch_phase,
            wifi_finalized_count: self.wifi_finalized_count,
            wifi_salvaged_count: self.wifi_salvaged_count,
            wifi_skipped_count: self.wifi_skipped_count,
            wifi_outbound_ws: self.wifi_outbound_ws.clone(),
            wifi_outbound_udp: self.wifi_outbound_udp.clone(),
            wifi_keepalive_elapsed_ms: self.wifi_keepalive_elapsed_ms,
            decoder_factory: self.decoder_factory,
            live_decoder_16k: None,
        }
    }
}

impl core::fmt::Debug for TransportSession {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        f.debug_struct("TransportSession")
            .field("reassembler", &self.reassembler)
            .field("connection_phase", &self.connection_phase)
            .field("telemetry", &self.telemetry)
            .field("has_ecdh_private_key", &self.ecdh_private_key.is_some())
            .field("session_key", &self.session_key)
            .field("catalog", &self.catalog)
            .field("transfer", &self.transfer)
            .field("runtime_state", &self.runtime_state)
            .field("active_file_id", &self.active_file_id)
            .field("active_file_key", &self.active_file_key)
            .field("active_nonce", &self.active_nonce)
            .field("active_is_realtime", &self.active_is_realtime)
            .field("opus_buffer_len", &self.opus_buffer.len())
            .field("marks_ms", &self.marks_ms)
            .field("last_finalized", &self.last_finalized)
            .field("finalized_queue_len", &self.finalized_queue.len())
            .field("live_pcm16_16khz_len", &self.live_pcm16_16khz.len())
            .field("wifi_endpoint", &self.wifi_endpoint)
            .field("wifi_batch_phase", &self.wifi_batch_phase)
            .field("wifi_current_index", &self.wifi_current_index)
            .field("wifi_queue_len", &self.wifi_queue.len())
            .field("has_decoder_factory", &self.decoder_factory.is_some())
            .field("has_live_decoder_16k", &self.live_decoder_16k.is_some())
            .finish()
    }
}

impl TransportSession {
    /// Creates an idle transport session.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates an idle transport session with an explicit `OpusDecoderFactory`.
    #[must_use]
    pub fn with_decoder_factory(factory: Option<OpusDecoderFactory>) -> Self {
        Self {
            reassembler: FrameReassembler::default(),
            connection_phase: ConnectionPhaseTag::Disconnected,
            telemetry: None,
            ecdh_private_key: None,
            session_key: None,
            catalog: Vec::new(),
            transfer: TransferProgress::default(),
            runtime_state: TransferRuntimeState::Idle,
            active_file_id: None,
            active_file_key: None,
            active_nonce: None,
            active_is_realtime: false,
            opus_buffer: Vec::new(),
            marks_ms: Vec::new(),
            last_finalized: None,
            finalized_queue: VecDeque::new(),
            live_pcm16_16khz: Vec::new(),
            wifi_endpoint: None,
            wifi_queue: Vec::new(),
            wifi_current_index: 0,
            wifi_batch_phase: WifiBatchPhase::Idle,
            wifi_finalized_count: 0,
            wifi_salvaged_count: 0,
            wifi_skipped_count: 0,
            wifi_outbound_ws: VecDeque::new(),
            wifi_outbound_udp: VecDeque::new(),
            wifi_keepalive_elapsed_ms: 0,
            decoder_factory: factory,
            live_decoder_16k: None,
        }
    }

    /// Pops and returns the next finalized recording from the FIFO queue, updating `last_finalized`.
    pub fn take_next_finalized(&mut self) -> Option<FinalizedRecording> {
        if let Some(next) = self.finalized_queue.pop_front() {
            self.last_finalized = self.finalized_queue.front().cloned();
            Some(next)
        } else {
            self.last_finalized.take()
        }
    }

    /// Returns `true` when at least one finalized recording is available to drain.
    #[must_use]
    pub fn has_finalized_recording(&self) -> bool {
        !self.finalized_queue.is_empty() || self.last_finalized.is_some()
    }

    /// Drains and returns all buffered 16 kHz mono PCM16 LE bytes decoded during `ingest_ble_chunk`.
    pub fn take_live_pcm16(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.live_pcm16_16khz)
    }

    /// Returns the number of complete 160-byte Opus slices currently buffered for the active file.
    #[must_use]
    pub fn received_slice_count(&self) -> u32 {
        (self.opus_buffer.len() / OPUS_FRAME_BYTES) as u32
    }

    /// Returns `true` when the active realtime stream is in its post-stop 2-second quiet-drain window.
    #[must_use]
    pub fn is_realtime_quiet_draining(&self) -> bool {
        matches!(
            self.runtime_state,
            TransferRuntimeState::StreamingRealtime {
                quiet_drain_elapsed_ms: Some(_),
                ..
            }
        )
    }

    /// Returns `true` when an offline file pull is suspended across a BLE disconnect and ready to resume.
    #[must_use]
    pub fn is_offline_pull_suspended(&self) -> bool {
        matches!(self.runtime_state, TransferRuntimeState::Suspended { .. })
    }

    /// Sets the 32-byte session key explicitly.
    pub fn set_session_key(&mut self, key: [u8; 32]) {
        self.session_key = Some(key);
    }

    /// Transitions the transport session into `Scanning` for D3200 BLE advertisements.
    pub fn on_scanning(&mut self) {
        self.connection_phase = ConnectionPhaseTag::Scanning;
    }

    /// Transitions the transport session into `Connecting` to a discovered D3200 peripheral.
    pub fn on_connecting(&mut self) {
        self.connection_phase = ConnectionPhaseTag::Connecting;
    }

    /// Starts the `2E/01` ECDH + `01/01` device telemetry handshake once GATT characteristics
    /// `0x7777` (write) and `0x8888` (notify) are ready, returning the outbound TX frames.
    pub fn on_gatt_ready(&mut self, private_key: [u8; 32]) -> Option<Vec<Vec<u8>>> {
        let pub_key = DeviceCrypto::p256_public_key(&private_key)?;
        self.reassembler.reset();
        self.ecdh_private_key = Some(private_key);
        self.session_key = None;
        self.connection_phase = ConnectionPhaseTag::Handshaking;
        Some(vec![
            DeviceCommands::notify_encrypt_public_key(&pub_key),
            DeviceCommands::get_device_info(),
        ])
    }

    /// Resets any active file transfer and clears partial buffers.
    pub fn reset_active_transfer(&mut self) {
        self.active_file_id = None;
        self.active_file_key = None;
        self.active_nonce = None;
        self.active_is_realtime = false;
        self.opus_buffer.clear();
        self.marks_ms.clear();
        self.live_pcm16_16khz.clear();
        if let Some(dec) = self.live_decoder_16k.as_mut() {
            dec.reset();
        }
        self.runtime_state = TransferRuntimeState::Idle;
        self.transfer = TransferProgress::default();
    }

    /// Handles explicit GATT disconnection by resetting transfer state and entering `Disconnected`.
    pub fn on_disconnected(&mut self) {
        self.reassembler.reset();
        self.ecdh_private_key = None;
        self.session_key = None;
        self.reset_active_transfer();
        self.connection_phase = ConnectionPhaseTag::Disconnected;
    }

    /// Handles an unexpected BLE link interruption: suspends an in-flight offline pull so it can
    /// resume from `received_slice_count() * 166` upon reconnect, or salvages buffered realtime
    /// Opus slices into `last_finalized`.
    pub fn on_transport_interrupted(&mut self) {
        self.reassembler.reset();
        self.ecdh_private_key = None;
        self.session_key = None;
        self.connection_phase = ConnectionPhaseTag::Disconnected;
        match self.runtime_state {
            TransferRuntimeState::PullingOffline {
                file_id,
                expected_wire_bytes,
                retries_used,
                ..
            }
            | TransferRuntimeState::Suspended {
                file_id,
                expected_wire_bytes,
                retries_used,
            } => {
                self.runtime_state = TransferRuntimeState::Suspended {
                    file_id,
                    expected_wire_bytes,
                    retries_used,
                };
                self.transfer.received_wire_bytes =
                    self.received_slice_count().saturating_mul(SLICE_RECORD_BYTES as u32);
                self.transfer.quiet_draining = false;
            }
            _ if self.active_is_realtime && !self.opus_buffer.is_empty() => {
                let _ = self.finalize_active_transfer(0);
            }
            _ => {
                self.reset_active_transfer();
            }
        }
    }

    /// Resumes a suspended or active offline pull from `received_slice_count() * 166` wire bytes,
    /// returning the `1A/07` TX frame when an offline file is active.
    pub fn resume_offline_pull(&mut self) -> Option<Vec<u8>> {
        if self.active_is_realtime {
            return None;
        }
        let (file_id, expected_wire_bytes, retries_used) = match self.runtime_state {
            TransferRuntimeState::Suspended {
                file_id,
                expected_wire_bytes,
                retries_used,
            }
            | TransferRuntimeState::PullingOffline {
                file_id,
                expected_wire_bytes,
                retries_used,
                ..
            } => (file_id, expected_wire_bytes, retries_used),
            _ => {
                let fid = self.active_file_id?;
                (fid, self.transfer.expected_wire_bytes, self.transfer.retry_count)
            }
        };
        let offset = self
            .received_slice_count()
            .saturating_mul(SLICE_RECORD_BYTES as u32);
        let expected = expected_wire_bytes.max(offset);
        self.active_file_id = Some(file_id);
        self.runtime_state = TransferRuntimeState::PullingOffline {
            file_id,
            expected_wire_bytes: expected,
            inactivity_ms: 0,
            retries_used,
        };
        self.transfer = TransferProgress {
            phase: TransferPhaseTag::PullingOffline,
            file_id,
            received_wire_bytes: offset,
            expected_wire_bytes: expected,
            mark_count: self.marks_ms.len() as u32,
            error_code: 0,
            retry_count: retries_used,
            quiet_draining: false,
        };
        Some(DeviceCommands::start_transport_audio_file(file_id, offset, 0))
    }

    /// Stops/pauses an active realtime bean recording (`0x18 0x82 [0x02]`) and enters the
    /// 2,000 ms quiet-drain window before finalization.
    pub fn stop_realtime_recording(&mut self) -> SessionIngestOutcome {
        let mut outcome = SessionIngestOutcome::default();
        outcome
            .outbound_tx_frames
            .push(DeviceCommands::pause_record());
        if self.active_is_realtime {
            if let Some(fid) = self.active_file_id {
                self.runtime_state = TransferRuntimeState::StreamingRealtime {
                    file_id: fid,
                    quiet_drain_elapsed_ms: Some(0),
                };
                self.transfer.quiet_draining = true;
                outcome.transfer_updated = true;
            }
        }
        outcome
    }

    /// Advances the 5,000 ms offline pull watchdog (up to 2 retries per file), the 2,000 ms
    /// realtime post-stop quiet-drain timer, and the 2,000 ms Wi-Fi SoftAP UDP `:32003` keepalive
    /// timer by `elapsed_ms`.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now_epoch_sec: u64) -> SessionIngestOutcome {
        let mut outcome = SessionIngestOutcome::default();
        if self.wifi_batch_phase == WifiBatchPhase::Transferring {
            self.wifi_keepalive_elapsed_ms =
                self.wifi_keepalive_elapsed_ms.saturating_add(elapsed_ms);
            while self.wifi_keepalive_elapsed_ms >= WIFI_KEEPALIVE_INTERVAL_MS {
                self.wifi_keepalive_elapsed_ms -= WIFI_KEEPALIVE_INTERVAL_MS;
                self.wifi_outbound_udp
                    .push_back(WIFI_KEEPALIVE_PAYLOAD.to_vec());
                outcome.transfer_updated = true;
            }
            return outcome;
        }
        let offset = self
            .received_slice_count()
            .saturating_mul(SLICE_RECORD_BYTES as u32);
        match &mut self.runtime_state {
            TransferRuntimeState::PullingOffline {
                file_id,
                inactivity_ms,
                retries_used,
                ..
            } => {
                *inactivity_ms = inactivity_ms.saturating_add(elapsed_ms);
                if *inactivity_ms >= OFFLINE_WATCHDOG_TIMEOUT_MS {
                    let fid = *file_id;
                    if *retries_used < OFFLINE_MAX_RETRIES {
                        *retries_used += 1;
                        *inactivity_ms = 0;
                        let retries = *retries_used;
                        self.transfer.received_wire_bytes = offset;
                        self.transfer.retry_count = retries;
                        outcome
                            .outbound_tx_frames
                            .push(DeviceCommands::start_transport_audio_file(fid, offset, 0));
                        outcome.transfer_updated = true;
                    } else {
                        let retries = *retries_used;
                        self.runtime_state = TransferRuntimeState::Failed {
                            file_id: fid,
                            error_code: TRANSFER_ERR_WATCHDOG_TIMEOUT,
                        };
                        self.transfer.phase = TransferPhaseTag::Failed;
                        self.transfer.error_code = TRANSFER_ERR_WATCHDOG_TIMEOUT;
                        self.transfer.retry_count = retries;
                        outcome.transfer_updated = true;
                    }
                }
            }
            TransferRuntimeState::StreamingRealtime {
                quiet_drain_elapsed_ms: Some(waited),
                ..
            } => {
                *waited = waited.saturating_add(elapsed_ms);
                if *waited >= REALTIME_QUIET_DRAIN_MS {
                    if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                        outcome.finalized = Some(fin);
                        outcome.transfer_updated = true;
                    }
                }
            }
            _ => {}
        }
        outcome
    }

    /// Starts a Wi-Fi SoftAP high-speed batch transfer for `file_ids`, queuing the initial
    /// 36-char hex `1A/07` WebSocket request and 28-byte UDP `:32003` keepalive datagram.
    pub fn begin_wifi_batch(&mut self, file_ids: &[u32]) {
        self.wifi_outbound_ws.clear();
        self.wifi_outbound_udp.clear();
        self.finalized_queue.clear();
        self.last_finalized = None;
        self.reset_active_transfer();
        self.wifi_queue = file_ids.to_vec();
        self.wifi_current_index = 0;
        self.wifi_finalized_count = 0;
        self.wifi_salvaged_count = 0;
        self.wifi_skipped_count = 0;
        self.wifi_keepalive_elapsed_ms = 0;

        if file_ids.is_empty() {
            self.wifi_batch_phase = WifiBatchPhase::Completed;
            return;
        }

        self.wifi_batch_phase = WifiBatchPhase::Transferring;
        self.start_wifi_file(file_ids[0], 0);
        self.wifi_outbound_udp
            .push_back(WIFI_KEEPALIVE_PAYLOAD.to_vec());
    }

    /// Resumes an interrupted Wi-Fi SoftAP batch from the remaining queue and current slice offset.
    pub fn resume_wifi_batch(&mut self) -> bool {
        if self.wifi_batch_phase != WifiBatchPhase::Interrupted
            || self.wifi_current_index >= self.wifi_queue.len()
        {
            return false;
        }
        let fid = self.wifi_queue[self.wifi_current_index];
        let offset = self
            .received_slice_count()
            .saturating_mul(SLICE_RECORD_BYTES as u32);
        self.wifi_batch_phase = WifiBatchPhase::Transferring;
        self.wifi_keepalive_elapsed_ms = 0;
        self.start_wifi_file(fid, offset);
        self.wifi_outbound_udp
            .push_back(WIFI_KEEPALIVE_PAYLOAD.to_vec());
        true
    }

    /// Cancels any active or interrupted Wi-Fi SoftAP batch and clears outbound queues.
    pub fn cancel_wifi_batch(&mut self) {
        self.wifi_queue.clear();
        self.wifi_current_index = 0;
        self.wifi_outbound_ws.clear();
        self.wifi_outbound_udp.clear();
        self.wifi_keepalive_elapsed_ms = 0;
        self.wifi_batch_phase = WifiBatchPhase::Idle;
        self.reset_active_transfer();
    }

    /// Pops the next outbound WebSocket text message (`1A/07` hex, `"FINISH"`, or `1A/0A` hex).
    pub fn pop_outbound_wifi_ws(&mut self) -> Option<String> {
        self.wifi_outbound_ws.pop_front()
    }

    /// Pops the next outbound UDP `:32003` datagram (`"soundcore-keep-alive-unicast"`).
    pub fn pop_outbound_wifi_udp(&mut self) -> Option<Vec<u8>> {
        self.wifi_outbound_udp.pop_front()
    }

    /// Returns a snapshot of the current Wi-Fi SoftAP batch transfer progress.
    #[must_use]
    pub fn wifi_batch_progress(&self) -> WifiBatchProgress {
        let total_files = self.wifi_queue.len() as u32;
        let current_file_index = (self.wifi_current_index as u32).min(total_files);
        let remaining_count = self
            .wifi_queue
            .len()
            .saturating_sub(self.wifi_current_index) as u32;
        let active_file_id = match self.wifi_batch_phase {
            WifiBatchPhase::Idle | WifiBatchPhase::Completed => 0,
            _ => self
                .active_file_id
                .or_else(|| self.wifi_queue.get(self.wifi_current_index).copied())
                .unwrap_or(0),
        };
        WifiBatchProgress {
            phase: self.wifi_batch_phase,
            error_code: self.transfer.error_code,
            current_file_index,
            total_files,
            active_file_id,
            received_wire_bytes: self.transfer.received_wire_bytes,
            expected_wire_bytes: self.transfer.expected_wire_bytes,
            finalized_count: self.wifi_finalized_count,
            salvaged_count: self.wifi_salvaged_count,
            skipped_count: self.wifi_skipped_count,
            remaining_count,
        }
    }

    /// Handles a sudden SoftAP hotspot / WebSocket disconnect mid-batch.
    ///
    /// If the active file has received at least `95%` of its announced `expected_wire_bytes`,
    /// it is salvaged into `finalized_queue`, `wifi_salvaged_count` is incremented, and
    /// `wifi_current_index` advances to the next file (returning `true`). Otherwise partial
    /// buffers for the active file are cleared and `wifi_current_index` stays on the interrupted
    /// file (returning `false`).
    pub fn on_wifi_interrupted(&mut self, now_epoch_sec: u64) -> bool {
        self.reassembler.reset();
        if self.wifi_batch_phase != WifiBatchPhase::Transferring {
            return false;
        }
        let expected = self.transfer.expected_wire_bytes;
        let received = self.transfer.received_wire_bytes;
        let can_salvage =
            expected > 0 && received >= (expected.saturating_mul(95)) / 100 && !self.opus_buffer.is_empty();
        if can_salvage && self.finalize_active_transfer(now_epoch_sec).is_some() {
            self.wifi_salvaged_count = self.wifi_salvaged_count.saturating_add(1);
            self.wifi_current_index = self.wifi_current_index.saturating_add(1);
            self.wifi_batch_phase = WifiBatchPhase::Interrupted;
            return true;
        }
        self.reset_active_transfer();
        self.wifi_batch_phase = WifiBatchPhase::Interrupted;
        false
    }

    /// Normalizes a WebSocket message or UDP `:32003` datagram and ingests it into the session.
    pub fn ingest_wifi_chunk(
        &mut self,
        chunk: &[u8],
        now_epoch_sec: u64,
    ) -> SessionIngestOutcome {
        let Some(normalized) = normalize_wifi_chunk(chunk) else {
            return SessionIngestOutcome::default();
        };
        self.ingest_ble_chunk(&normalized, now_epoch_sec)
    }

    fn start_wifi_file(&mut self, fid: u32, offset_wire_bytes: u32) {
        if offset_wire_bytes == 0 {
            self.reset_active_transfer();
        }
        let expected = self.transfer.expected_wire_bytes.max(offset_wire_bytes);
        self.active_file_id = Some(fid);
        self.active_is_realtime = false;
        self.runtime_state = TransferRuntimeState::PullingOffline {
            file_id: fid,
            expected_wire_bytes: expected,
            inactivity_ms: 0,
            retries_used: 0,
        };
        self.transfer = TransferProgress {
            phase: TransferPhaseTag::PullingOffline,
            file_id: fid,
            received_wire_bytes: offset_wire_bytes,
            expected_wire_bytes: expected,
            mark_count: self.marks_ms.len() as u32,
            error_code: 0,
            retry_count: 0,
            quiet_draining: false,
        };
        self.wifi_outbound_ws
            .push_back(DeviceCommands::build_wifi_file_request_hex(
                fid,
                offset_wire_bytes,
            ));
    }

    fn advance_wifi_batch(&mut self) {
        self.wifi_current_index = self.wifi_current_index.saturating_add(1);
        if self.wifi_current_index < self.wifi_queue.len() {
            let next_fid = self.wifi_queue[self.wifi_current_index];
            self.start_wifi_file(next_fid, 0);
        } else {
            self.wifi_batch_phase = WifiBatchPhase::Completed;
            self.wifi_outbound_ws
                .push_back(WIFI_WS_FINISH_TEXT.to_string());
            self.wifi_outbound_ws
                .push_back(DeviceCommands::wifi_transfer_complete_hex());
        }
    }

    fn parse_any_file_head(&self, raw: &[u8]) -> Option<OpenedFileHead> {
        let sk_slice = self.session_key.as_ref().map(|k| k.as_slice());
        if let Some(head) = TransportSliceProcessor::open_file_head(raw, sk_slice) {
            return Some(head);
        }
        if raw.len() < 18 {
            return None;
        }
        let file_id = read_u32_le(raw, 9);
        let file_size = read_u32_le(raw, 13);
        let error_code = if raw.len() > 95 {
            raw[95]
        } else if raw.len() >= 19 {
            raw[17]
        } else {
            0
        };
        Some(OpenedFileHead {
            secret: AudioFileSecretKey {
                file_id,
                file_size,
                nonce: [0u8; 16],
                encrypted_file_key: Vec::new(),
                session_nonce: [0u8; 16],
                error_code,
            },
            unfinished: file_size == UNFINISHED_FILE_SIZE,
            file_key: None,
        })
    }

    /// Verifies the device's `2E/01` ECDH reply (`payload[65..97] == computed_shared_secret`)
    /// and derives the 32-byte session key via `DeviceCrypto::hkdf_sha256`.
    pub fn accept_ecdh_reply(
        &mut self,
        ecdh_reply_payload: &[u8],
        computed_shared_secret: &[u8],
    ) -> bool {
        if ecdh_reply_payload.len() < 97 || computed_shared_secret.len() != 32 {
            return false;
        }
        if &ecdh_reply_payload[65..97] != computed_shared_secret {
            return false;
        }
        let derived =
            DeviceCrypto::hkdf_sha256(computed_shared_secret, &[1, 2, 3], &[1, 2, 3], 32);
        let mut sk = [0u8; 32];
        sk.copy_from_slice(&derived);
        self.session_key = Some(sk);
        true
    }

    /// Prepares an offline file pull for `file_id` and returns the encoded `1A/07` TX frame.
    pub fn begin_offline_pull(&mut self, file_id: u32, duration_ms: u32) -> Vec<u8> {
        let estimated_wire = ((duration_ms / 20).max(1)).saturating_mul(SLICE_RECORD_BYTES as u32);
        self.active_file_id = Some(file_id);
        self.active_file_key = None;
        self.active_nonce = None;
        self.active_is_realtime = false;
        self.opus_buffer.clear();
        self.marks_ms.clear();
        self.live_pcm16_16khz.clear();
        if let Some(dec) = self.live_decoder_16k.as_mut() {
            dec.reset();
        }
        self.runtime_state = TransferRuntimeState::PullingOffline {
            file_id,
            expected_wire_bytes: estimated_wire,
            inactivity_ms: 0,
            retries_used: 0,
        };
        self.transfer = TransferProgress {
            phase: TransferPhaseTag::PullingOffline,
            file_id,
            received_wire_bytes: 0,
            expected_wire_bytes: estimated_wire,
            mark_count: 0,
            error_code: 0,
            retry_count: 0,
            quiet_draining: false,
        };
        DeviceCommands::start_transport_audio_file(file_id, 0, 0)
    }

    /// Ingests a raw BLE notification chunk, reassembles verified frames, and advances
    /// the `01/01`, `1A/01`–`1B/0E`, `1A/05`, `1A/06`, `1A/07`, `1A/08`, and `1A/0A` state machines.
    pub fn ingest_ble_chunk(&mut self, chunk: &[u8], now_epoch_sec: u64) -> SessionIngestOutcome {
        let packets = self.reassembler.ingest(chunk);
        let mut outcome = SessionIngestOutcome {
            frames_decoded: packets.len() as u32,
            ..SessionIngestOutcome::default()
        };

        for pkt in packets {
            match (pkt.cmd_type, pkt.cmd_id) {
                (0x2E, 0x01) => {
                    if pkt.payload.len() >= 97 {
                        if let Some(priv_key) = self.ecdh_private_key {
                            if let Some(shared) =
                                DeviceCrypto::p256_ecdh_shared_secret(&priv_key, &pkt.payload[0..65])
                            {
                                if self.accept_ecdh_reply(&pkt.payload, &shared) {
                                    outcome.session_key_established = true;
                                    if self.is_offline_pull_suspended()
                                        && self.connection_phase == ConnectionPhaseTag::Connected
                                    {
                                        if let Some(resume_tx) = self.resume_offline_pull() {
                                            outcome.outbound_tx_frames.push(resume_tx);
                                            outcome.transfer_updated = true;
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                (0x01, 0x01) => {
                    let info = DeviceInfoModel::parse_packet(&pkt.raw);
                    self.telemetry = Some(info);
                    self.connection_phase = ConnectionPhaseTag::Connected;
                    outcome.telemetry_updated = true;
                    outcome
                        .outbound_tx_frames
                        .push(DeviceCommands::list_files_with_end_time(0));
                    if self.is_offline_pull_suspended() && self.session_key.is_some() {
                        if let Some(resume_tx) = self.resume_offline_pull() {
                            outcome.outbound_tx_frames.push(resume_tx);
                            outcome.transfer_updated = true;
                        }
                    }
                }
                (0x1A, 0x01) | (0x1A, 0x0D) | (0x1A, 0x0E) | (0x1B, 0x0E) => {
                    let with_end_time = pkt.cmd_id == 0x0D || (pkt.cmd_type == 0x1B && pkt.cmd_id == 0x0E);
                    let page = OfflineFileList::parse(&pkt.payload, with_end_time);
                    self.catalog = page.files;
                    outcome.catalog_updated = true;
                    if self.active_file_id.is_none() {
                        self.runtime_state = TransferRuntimeState::Idle;
                        self.transfer.phase = TransferPhaseTag::Idle;
                    }
                }
                (0x1A, 0x05) => {
                    if let Some(ep) = WifiEndpoint::parse_config_response(&pkt.raw) {
                        self.wifi_endpoint = Some(ep);
                        outcome.transfer_updated = true;
                    }
                }
                (0x1A, 0x06) => {
                    if pkt.payload.len() >= 5
                        && (pkt.payload[4] == 0 || pkt.payload[4] == 2)
                        && self.active_is_realtime
                    {
                        if let Some(fid) = self.active_file_id {
                            self.runtime_state = TransferRuntimeState::StreamingRealtime {
                                file_id: fid,
                                quiet_drain_elapsed_ms: Some(0),
                            };
                            self.transfer.quiet_draining = true;
                            outcome.transfer_updated = true;
                        }
                    }
                }
                (0x1A, 0x07) | (0x1B, 0x07) => {
                    if let Some(head) = self.parse_any_file_head(&pkt.raw) {
                        let err = head.secret.error_code;
                        if err == 1 || err == 3 {
                            if self.wifi_batch_phase == WifiBatchPhase::Transferring {
                                self.wifi_skipped_count = self.wifi_skipped_count.saturating_add(1);
                                self.advance_wifi_batch();
                                self.transfer.error_code = err;
                                outcome.transfer_updated = true;
                                continue;
                            }
                            self.runtime_state = TransferRuntimeState::Failed {
                                file_id: head.secret.file_id,
                                error_code: err,
                            };
                            self.transfer.phase = TransferPhaseTag::Failed;
                            self.transfer.error_code = err;
                            outcome.transfer_updated = true;
                            continue;
                        }
                        if err != 0 && err != 0xFF {
                            self.runtime_state = TransferRuntimeState::Failed {
                                file_id: head.secret.file_id,
                                error_code: err,
                            };
                            self.transfer.phase = TransferPhaseTag::Failed;
                            self.transfer.error_code = err;
                            if self.wifi_batch_phase == WifiBatchPhase::Transferring {
                                self.wifi_batch_phase = WifiBatchPhase::Failed;
                            }
                            outcome.transfer_updated = true;
                            continue;
                        }

                        let is_resuming_same_file = !head.unfinished
                            && self.active_file_id == Some(head.secret.file_id)
                            && !self.opus_buffer.is_empty();
                        let retries_used = if is_resuming_same_file {
                            match self.runtime_state {
                                TransferRuntimeState::PullingOffline { retries_used, .. }
                                | TransferRuntimeState::Suspended { retries_used, .. } => {
                                    retries_used
                                }
                                _ => self.transfer.retry_count,
                            }
                        } else {
                            0
                        };
                        if !is_resuming_same_file {
                            self.opus_buffer.clear();
                            self.marks_ms.clear();
                            self.live_pcm16_16khz.clear();
                            if let Some(dec) = self.live_decoder_16k.as_mut() {
                                dec.reset();
                            }
                        }
                        self.active_file_id = Some(head.secret.file_id);
                        self.active_file_key = head.file_key;
                        self.active_nonce = if head.file_key.is_some() {
                            Some(head.secret.nonce)
                        } else {
                            None
                        };
                        self.active_is_realtime = head.unfinished;
                        let received_wire = self
                            .received_slice_count()
                            .saturating_mul(SLICE_RECORD_BYTES as u32);
                        if head.unfinished {
                            self.runtime_state = TransferRuntimeState::StreamingRealtime {
                                file_id: head.secret.file_id,
                                quiet_drain_elapsed_ms: None,
                            };
                            self.transfer = TransferProgress {
                                phase: TransferPhaseTag::StreamingRealtime,
                                file_id: head.secret.file_id,
                                received_wire_bytes: received_wire,
                                expected_wire_bytes: 0,
                                mark_count: self.marks_ms.len() as u32,
                                error_code: 0,
                                retry_count: 0,
                                quiet_draining: false,
                            };
                        } else {
                            let expected = head.secret.file_size.max(received_wire);
                            self.runtime_state = TransferRuntimeState::PullingOffline {
                                file_id: head.secret.file_id,
                                expected_wire_bytes: expected,
                                inactivity_ms: 0,
                                retries_used,
                            };
                            self.transfer = TransferProgress {
                                phase: TransferPhaseTag::PullingOffline,
                                file_id: head.secret.file_id,
                                received_wire_bytes: received_wire,
                                expected_wire_bytes: expected,
                                mark_count: self.marks_ms.len() as u32,
                                error_code: 0,
                                retry_count: retries_used,
                                quiet_draining: false,
                            };
                        }
                        outcome.transfer_updated = true;
                    }
                }
                (0x1A, 0x08) | (0x1A, 0x12) | (0x1B, 0x08) | (0x1B, 0x12) => {
                    if let TransferRuntimeState::PullingOffline { inactivity_ms, .. } =
                        &mut self.runtime_state
                    {
                        *inactivity_ms = 0;
                    }
                    if let TransferRuntimeState::StreamingRealtime {
                        quiet_drain_elapsed_ms: Some(waited),
                        ..
                    } = &mut self.runtime_state
                    {
                        *waited = 0;
                    }
                    let dec = self
                        .active_file_key
                        .as_ref()
                        .zip(self.active_nonce.as_ref())
                        .and_then(|(fk, n)| AesCtrStreamDecrypt::new(fk, n));
                    let min_seq = self.received_slice_count();
                    let batch =
                        TransportSliceProcessor::unpack_frame_from(&pkt.raw, dec.as_ref(), min_seq);
                    if batch.slice_count > 0 {
                        let fid = self.active_file_id.unwrap_or(1);
                        self.active_file_id = Some(fid);
                        self.opus_buffer.extend_from_slice(&batch.opus_bytes);
                        if self.live_decoder_16k.is_none() {
                            if let Some(factory) =
                                self.decoder_factory.or_else(default_opus_decoder_factory)
                            {
                                self.live_decoder_16k = factory(ASR_SAMPLE_RATE);
                            }
                        }
                        if let Some(live_dec) = self.live_decoder_16k.as_mut() {
                            let start_len = outcome.live_pcm16_16khz.len();
                            for frame in batch.opus_bytes.chunks_exact(OPUS_FRAME_BYTES) {
                                let _ = OpusWave::decode_frame_into(
                                    live_dec.as_mut(),
                                    frame,
                                    &mut outcome.live_pcm16_16khz,
                                );
                            }
                            if outcome.live_pcm16_16khz.len() > start_len {
                                self.live_pcm16_16khz
                                    .extend_from_slice(&outcome.live_pcm16_16khz[start_len..]);
                            }
                        }
                        let new_received = self
                            .received_slice_count()
                            .saturating_mul(SLICE_RECORD_BYTES as u32);
                        for seq in batch.marked_sequences {
                            let ms = SliceMark::position_ms(seq);
                            if !self.marks_ms.contains(&ms) {
                                self.marks_ms.push(ms);
                                outcome.new_marks_ms.push(ms);
                            }
                        }
                        self.marks_ms.sort_unstable();
                        if self.active_is_realtime {
                            let drain = if self.is_realtime_quiet_draining() {
                                Some(0)
                            } else {
                                None
                            };
                            self.runtime_state = TransferRuntimeState::StreamingRealtime {
                                file_id: fid,
                                quiet_drain_elapsed_ms: drain,
                            };
                            self.transfer = TransferProgress {
                                phase: TransferPhaseTag::StreamingRealtime,
                                file_id: fid,
                                received_wire_bytes: new_received,
                                expected_wire_bytes: 0,
                                mark_count: self.marks_ms.len() as u32,
                                error_code: 0,
                                retry_count: 0,
                                quiet_draining: drain.is_some(),
                            };
                        } else {
                            let prev_expected = self.transfer.expected_wire_bytes;
                            let expected = prev_expected.max(new_received);
                            self.runtime_state = TransferRuntimeState::PullingOffline {
                                file_id: fid,
                                expected_wire_bytes: expected,
                                inactivity_ms: 0,
                                retries_used: 0,
                            };
                            self.transfer = TransferProgress {
                                phase: TransferPhaseTag::PullingOffline,
                                file_id: fid,
                                received_wire_bytes: new_received,
                                expected_wire_bytes: expected,
                                mark_count: self.marks_ms.len() as u32,
                                error_code: 0,
                                retry_count: 0,
                                quiet_draining: false,
                            };
                            if self.wifi_batch_phase == WifiBatchPhase::Transferring
                                && prev_expected > 0
                                && new_received >= prev_expected
                            {
                                if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                                    self.wifi_finalized_count =
                                        self.wifi_finalized_count.saturating_add(1);
                                    outcome.finalized = Some(fin);
                                    self.advance_wifi_batch();
                                }
                            }
                        }
                        outcome.slices_unpacked_count = outcome
                            .slices_unpacked_count
                            .saturating_add(batch.slice_count as u32);
                        outcome.transfer_updated = true;
                    }
                }
                (0x1A, 0x0A) | (0x1B, 0x0A) => {
                    if self.wifi_batch_phase == WifiBatchPhase::Transferring
                        && self.opus_buffer.is_empty()
                    {
                        continue;
                    }
                    if !self.active_is_realtime
                        && self.transfer.expected_wire_bytes > 0
                        && self.transfer.received_wire_bytes < self.transfer.expected_wire_bytes
                    {
                        continue;
                    }
                    if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                        outcome.finalized = Some(fin);
                        outcome.transfer_updated = true;
                        if self.wifi_batch_phase == WifiBatchPhase::Transferring {
                            self.wifi_finalized_count =
                                self.wifi_finalized_count.saturating_add(1);
                            self.advance_wifi_batch();
                        }
                    }
                }
                _ => {}
            }
        }

        outcome
    }

    /// Finalizes the active Opus stream into an Ogg Opus container and 48 kHz mono
    /// preview WAV with 880 Hz mark chimes, appends it to `finalized_queue` and
    /// `last_finalized`, and resets the active transfer state to `Idle`.
    pub fn finalize_active_transfer(&mut self, now_epoch_sec: u64) -> Option<FinalizedRecording> {
        let fid = self.active_file_id?;
        if self.opus_buffer.is_empty() {
            self.reset_active_transfer();
            return None;
        }
        let ogg_opus_bytes = OggOpus::mux_raw_frames(&self.opus_buffer);
        let slice_count = (self.opus_buffer.len() / OPUS_FRAME_BYTES) as u64;
        let duration_ms = (slice_count * 20).max(400);
        let marks_ms = self.marks_ms.clone();
        let preview_wav_bytes = OpusWave::decode_raw_frames_to_wav(
            &self.opus_buffer,
            WAV_SAMPLE_RATE,
            &marks_ms,
            self.decoder_factory,
        )
        .unwrap_or_else(|| OpusWave::build_audible_preview_wav(duration_ms, &marks_ms));

        let entry = RecordingEntry {
            id: fid,
            bean_file_id: fid,
            created_at_epoch_sec: now_epoch_sec,
            duration_ms,
            byte_count: ogg_opus_bytes.len() as u32,
            marks_ms,
        };
        let finalized = FinalizedRecording {
            entry,
            ogg_opus_bytes,
            preview_wav_bytes,
        };
        self.finalized_queue.push_back(finalized.clone());
        self.last_finalized = Some(finalized.clone());
        let retained_live_pcm = std::mem::take(&mut self.live_pcm16_16khz);
        self.reset_active_transfer();
        self.live_pcm16_16khz = retained_live_pcm;
        Some(finalized)
    }

    /// Runs a deterministic closed-loop `01/01` telemetry + `1A/07` encrypted file head
    /// + 60-slice `1A/08` stream (with double-tap marks at sequence 15 and 45) +
    /// finalization pipeline entirely inside Rust.
    pub fn simulate_realtime_pipeline(&mut self, now_epoch_sec: u64) -> FinalizedRecording {
        let ikm = [0x42u8; 32];
        let sk_vec = DeviceCrypto::hkdf_sha256(&ikm, &[1, 2, 3], &[1, 2, 3], 32);
        let mut sk = [0u8; 32];
        sk.copy_from_slice(&sk_vec);
        self.session_key = Some(sk);

        let mut tel_pkt = Vec::from(RX_MAGIC);
        tel_pkt.extend_from_slice(&[0x01, 0x01, 0x01, 0x00, 0x00]);
        tel_pkt.push(1);
        tel_pkt.push(8);
        tel_pkt.push(1);
        tel_pkt.extend_from_slice(b"1.4.8");
        tel_pkt.extend_from_slice(b"D3200NATIVE639D0");
        tel_pkt.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
        tel_pkt.extend_from_slice(&(58u32 * 1024 * 1024).to_le_bytes());
        tel_pkt.push(0);
        tel_pkt.extend_from_slice(b"2.1.0");
        tel_pkt.push(9);
        tel_pkt.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
        let tel_len = (tel_pkt.len() + 1) as u16;
        tel_pkt[7] = (tel_len & 0xFF) as u8;
        tel_pkt[8] = ((tel_len >> 8) & 0xFF) as u8;
        let tel_csum = ProtocolFrame::checksum(&tel_pkt);
        tel_pkt.push(tel_csum);
        let _ = self.ingest_ble_chunk(&tel_pkt, now_epoch_sec);

        let mut plain_key_mat = Vec::with_capacity(46);
        plain_key_mat.extend_from_slice(b"soundcored3200");
        let mut file_key = [0u8; 32];
        for (i, b) in file_key.iter_mut().enumerate() {
            *b = ((i * 7 + 13) & 0xFF) as u8;
        }
        plain_key_mat.extend_from_slice(&file_key);
        let mut session_nonce = [0u8; 16];
        for (i, b) in session_nonce.iter_mut().enumerate() {
            *b = ((i * 3 + 5) & 0xFF) as u8;
        }
        let enc_file_key = DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, &sk, &session_nonce)
            .expect("32-byte session key must encrypt file key material");

        let mut file_nonce = [0u8; 16];
        for (i, b) in file_nonce.iter_mut().enumerate() {
            *b = ((i * 11 + 19) & 0xFF) as u8;
        }
        let demo_fid: u32 = 20_261_107;
        let mut head_payload = Vec::with_capacity(87);
        head_payload.extend_from_slice(&demo_fid.to_le_bytes());
        head_payload.extend_from_slice(&u32::MAX.to_le_bytes());
        head_payload.extend_from_slice(&file_nonce);
        head_payload.extend_from_slice(&enc_file_key);
        head_payload.extend_from_slice(&session_nonce);
        head_payload.push(0);
        let head_rx = Self::build_rx_frame(0x1A, 0x07, &head_payload);
        let _ = self.ingest_ble_chunk(&head_rx, now_epoch_sec);

        let decryptor = AesCtrStreamDecrypt::new(&file_key, &file_nonce)
            .expect("32-byte file key must construct stream decryptor");
        let mut slice_payload = Vec::with_capacity(60 * SLICE_RECORD_BYTES);
        for seq in 0..60u32 {
            slice_payload.extend_from_slice(&seq.to_le_bytes());
            let flags = if seq == 15 || seq == 45 { 0x01u8 } else { 0x00u8 };
            slice_payload.push(flags);
            let mut chunk = [0u8; OPUS_FRAME_BYTES];
            chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()]
                .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            decryptor.decrypt_contiguous_in_place(&mut chunk, seq);
            slice_payload.extend_from_slice(&chunk);
            slice_payload.push(0x00);
        }
        let slices_rx = Self::build_rx_frame(0x1A, 0x08, &slice_payload);
        let _ = self.ingest_ble_chunk(&slices_rx, now_epoch_sec);

        self.finalize_active_transfer(now_epoch_sec)
            .expect("simulated 60-slice stream must produce a FinalizedRecording")
    }

    fn build_rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
        let total_len = (9 + payload.len() + 1) as u16;
        let mut frame = Vec::with_capacity(total_len as usize);
        frame.extend_from_slice(&RX_MAGIC);
        frame.push(0x01);
        frame.push(cmd_type);
        frame.push(cmd_id);
        frame.push((total_len & 0xFF) as u8);
        frame.push(((total_len >> 8) & 0xFF) as u8);
        frame.extend_from_slice(payload);
        let csum = ProtocolFrame::checksum(&frame);
        frame.push(csum);
        frame
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct DeterministicTestDecoder {
        sample_rate: u32,
        frames_seen: i16,
    }

    impl OpusStreamDecoder for DeterministicTestDecoder {
        fn sample_rate(&self) -> u32 {
            self.sample_rate
        }

        fn decode_trimmed_packet(&mut self, packet: &[u8], out_pcm16_le: &mut Vec<u8>) -> bool {
            if packet != REAL_OPUS_20MS_440HZ_PACKET {
                return false;
            }
            self.frames_seen = self.frames_seen.saturating_add(1);
            let samples_20ms = (self.sample_rate as usize) / 50;
            out_pcm16_le.reserve(samples_20ms * 2);
            for i in 0..samples_20ms {
                let sample = self.frames_seen.saturating_mul(10).saturating_add((i % 64) as i16);
                out_pcm16_le.extend_from_slice(&sample.to_le_bytes());
            }
            true
        }

        fn reset(&mut self) {
            self.frames_seen = 0;
        }
    }

    fn test_decoder_factory(sample_rate: u32) -> Option<Box<dyn OpusStreamDecoder>> {
        if !OpusWave::is_valid_sample_rate(sample_rate) {
            return None;
        }
        Some(Box::new(DeterministicTestDecoder {
            sample_rate,
            frames_seen: 0,
        }))
    }

    #[test]
    fn simulated_realtime_pipeline_decodes_telemetry_head_and_60_slices() {
        let mut session = TransportSession::new();
        let fin = session.simulate_realtime_pipeline(1_700_000_000);
        assert_eq!(
            session.connection_phase,
            ConnectionPhaseTag::Connected
        );
        assert_eq!(session.telemetry.as_ref().unwrap().battery, Some(90));
        assert_eq!(fin.entry.id, 20_261_107);
        assert_eq!(fin.entry.duration_ms, 1200);
        assert_eq!(fin.entry.marks_ms, vec![300, 900]);
        assert!(fin.ogg_opus_bytes.starts_with(b"OggS"));
        assert!(fin.preview_wav_bytes.starts_with(b"RIFF"));
    }

    #[test]
    fn session_with_decoder_factory_streams_16khz_pcm_and_finalizes_48khz_wav() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let fin = session.simulate_realtime_pipeline(1_700_000_000);
        assert_eq!(fin.preview_wav_bytes.len(), 44 + 60 * 960 * 2);
        let live_pcm = session.take_live_pcm16();
        assert_eq!(live_pcm.len(), 60 * 320 * 2);
        assert!(session.take_live_pcm16().is_empty());
    }

    fn build_test_head_frame(
        session_key: &[u8; 32],
        file_id: u32,
        file_size: u32,
        file_key: &[u8; 32],
        file_nonce: &[u8; 16],
    ) -> Vec<u8> {
        let mut plain_key_mat = Vec::with_capacity(46);
        plain_key_mat.extend_from_slice(b"soundcored3200");
        plain_key_mat.extend_from_slice(file_key);
        let session_nonce = [0x33u8; 16];
        let enc_file_key =
            DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, session_key, &session_nonce).unwrap();
        let mut head_payload = Vec::with_capacity(87);
        head_payload.extend_from_slice(&file_id.to_le_bytes());
        head_payload.extend_from_slice(&file_size.to_le_bytes());
        head_payload.extend_from_slice(file_nonce);
        head_payload.extend_from_slice(&enc_file_key);
        head_payload.extend_from_slice(&session_nonce);
        head_payload.push(0);
        TransportSession::build_rx_frame(0x1A, 0x07, &head_payload)
    }

    fn build_test_slice_frame(
        file_key: &[u8; 32],
        file_nonce: &[u8; 16],
        sequences: &[(u32, u8)],
    ) -> Vec<u8> {
        let decryptor = AesCtrStreamDecrypt::new(file_key, file_nonce).unwrap();
        let mut payload = Vec::with_capacity(sequences.len() * SLICE_RECORD_BYTES);
        for &(seq, flags) in sequences {
            payload.extend_from_slice(&seq.to_le_bytes());
            payload.push(flags);
            let mut chunk = [0u8; OPUS_FRAME_BYTES];
            chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()]
                .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            decryptor.decrypt_contiguous_in_place(&mut chunk, seq);
            payload.extend_from_slice(&chunk);
            payload.push(0x00);
        }
        TransportSession::build_rx_frame(0x1A, 0x08, &payload)
    }

    #[test]
    fn offline_pull_watchdog_retries_with_byte_offset_and_deduplicates_overlapping_slices() {
        let mut session = TransportSession::new();
        let sk = [0x77u8; 32];
        let fk = [0x88u8; 32];
        let fn_iv = [0x99u8; 16];
        session.set_session_key(sk);

        let start_tx = session.begin_offline_pull(555, 80);
        assert_eq!(&start_tx[9..13], &0u32.to_le_bytes());
        assert_eq!(&start_tx[13..17], &555u32.to_le_bytes());

        let head = build_test_head_frame(&sk, 555, 4 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_100);

        let batch1 = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let step1 = session.ingest_ble_chunk(&batch1, 1_700_000_100);
        assert_eq!(step1.slices_unpacked_count, 2);
        assert_eq!(session.transfer.received_wire_bytes, 332);

        let w1 = session.poll_timers(4_999, 1_700_000_104);
        assert!(w1.outbound_tx_frames.is_empty());
        assert_eq!(session.transfer.retry_count, 0);

        let w2 = session.poll_timers(1, 1_700_000_105);
        assert_eq!(w2.outbound_tx_frames.len(), 1);
        assert_eq!(session.transfer.retry_count, 1);
        let retry_tx = &w2.outbound_tx_frames[0];
        assert_eq!(&retry_tx[9..13], &332u32.to_le_bytes());
        assert_eq!(&retry_tx[13..17], &555u32.to_le_bytes());

        let _ = session.ingest_ble_chunk(&head, 1_700_000_106);
        assert_eq!(session.received_slice_count(), 2);
        assert_eq!(session.transfer.retry_count, 1);

        let batch2 = build_test_slice_frame(&fk, &fn_iv, &[(1, 0x01), (2, 0x00), (3, 0x01)]);
        let step2 = session.ingest_ble_chunk(&batch2, 1_700_000_106);
        assert_eq!(step2.slices_unpacked_count, 2);
        assert_eq!(session.received_slice_count(), 4);
        assert_eq!(session.transfer.received_wire_bytes, 664);
        assert_eq!(session.transfer.retry_count, 0);

        let done = TransportSession::build_rx_frame(0x1A, 0x0A, &555u32.to_le_bytes());
        let fin_step = session.ingest_ble_chunk(&done, 1_700_000_107);
        let fin = fin_step.finalized.expect("offline pull must finalize on 1A/0A");
        assert_eq!(fin.entry.id, 555);
        assert_eq!(fin.entry.marks_ms, vec![20, 60]);
    }

    #[test]
    fn offline_pull_watchdog_fails_after_two_retries() {
        let mut session = TransportSession::new();
        let _ = session.begin_offline_pull(777, 1_000);

        let r1 = session.poll_timers(OFFLINE_WATCHDOG_TIMEOUT_MS, 10);
        assert_eq!(r1.outbound_tx_frames.len(), 1);
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);
        assert_eq!(session.transfer.retry_count, 1);

        let r2 = session.poll_timers(OFFLINE_WATCHDOG_TIMEOUT_MS, 15);
        assert_eq!(r2.outbound_tx_frames.len(), 1);
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);
        assert_eq!(session.transfer.retry_count, 2);

        let r3 = session.poll_timers(OFFLINE_WATCHDOG_TIMEOUT_MS, 20);
        assert!(r3.outbound_tx_frames.is_empty());
        assert_eq!(session.transfer.phase, TransferPhaseTag::Failed);
        assert_eq!(session.transfer.error_code, TRANSFER_ERR_WATCHDOG_TIMEOUT);
        assert_eq!(session.transfer.retry_count, 2);
    }

    #[test]
    fn realtime_stop_enters_2s_quiet_drain_and_late_slices_extend_deadline() {
        let mut session = TransportSession::new();
        let sk = [0x12u8; 32];
        let fk = [0x34u8; 32];
        let fn_iv = [0x56u8; 16];
        session.set_session_key(sk);

        let head = build_test_head_frame(&sk, 9001, u32::MAX, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_200);
        let slice0 = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let _ = session.ingest_ble_chunk(&slice0, 1_700_000_200);

        let stop_out = session.stop_realtime_recording();
        assert_eq!(stop_out.outbound_tx_frames, vec![DeviceCommands::pause_record()]);
        assert!(session.is_realtime_quiet_draining());
        assert!(session.transfer.quiet_draining);

        let t1 = session.poll_timers(1_500, 1_700_000_201);
        assert!(t1.finalized.is_none());

        let late_slice = build_test_slice_frame(&fk, &fn_iv, &[(2, 0x01)]);
        let _ = session.ingest_ble_chunk(&late_slice, 1_700_000_201);
        assert!(session.is_realtime_quiet_draining());

        let t2 = session.poll_timers(1_500, 1_700_000_203);
        assert!(t2.finalized.is_none());

        let t3 = session.poll_timers(500, 1_700_000_204);
        let fin = t3.finalized.expect("2,000 ms quiet drain after late slice must finalize");
        assert_eq!(fin.entry.id, 9001);
        assert_eq!(fin.entry.marks_ms, vec![20, 40]);
        assert!(!session.is_realtime_quiet_draining());
    }

    #[test]
    fn transport_interrupted_suspends_offline_pull_and_resumes_on_reconnect() {
        let mut session = TransportSession::new();
        let sk = [0x44u8; 32];
        let fk = [0x55u8; 32];
        let fn_iv = [0x66u8; 16];
        session.set_session_key(sk);

        let _ = session.begin_offline_pull(321, 100);
        let head = build_test_head_frame(&sk, 321, 5 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_300);
        let first_three = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01), (2, 0x00)]);
        let _ = session.ingest_ble_chunk(&first_three, 1_700_000_300);
        assert_eq!(session.received_slice_count(), 3);

        session.on_transport_interrupted();
        assert!(session.is_offline_pull_suspended());
        assert_eq!(session.connection_phase, ConnectionPhaseTag::Disconnected);
        assert_eq!(session.received_slice_count(), 3);

        let idle_poll = session.poll_timers(10_000, 1_700_000_310);
        assert!(idle_poll.outbound_tx_frames.is_empty());
        assert!(session.is_offline_pull_suspended());

        session.set_session_key(sk);
        let mut tel_pkt = Vec::from(RX_MAGIC);
        tel_pkt.extend_from_slice(&[0x01, 0x01, 0x01, 0x00, 0x00, 1, 7, 0]);
        tel_pkt.extend_from_slice(b"1.4.8");
        tel_pkt.extend_from_slice(b"D3200NATIVE639D0");
        tel_pkt.extend_from_slice(&1024u32.to_le_bytes());
        tel_pkt.extend_from_slice(&512u32.to_le_bytes());
        let tel_len = (tel_pkt.len() + 1) as u16;
        tel_pkt[7] = (tel_len & 0xFF) as u8;
        tel_pkt[8] = ((tel_len >> 8) & 0xFF) as u8;
        let csum = ProtocolFrame::checksum(&tel_pkt);
        tel_pkt.push(csum);

        let reconn_out = session.ingest_ble_chunk(&tel_pkt, 1_700_000_311);
        assert_eq!(reconn_out.outbound_tx_frames.len(), 2);
        let resume_tx = &reconn_out.outbound_tx_frames[1];
        assert_eq!(&resume_tx[9..13], &(3u32 * 166).to_le_bytes());
        assert_eq!(&resume_tx[13..17], &321u32.to_le_bytes());
        assert!(!session.is_offline_pull_suspended());
    }

    fn build_test_head_frame_with_err(
        session_key: &[u8; 32],
        file_id: u32,
        file_size: u32,
        file_key: &[u8; 32],
        file_nonce: &[u8; 16],
        error_code: u8,
    ) -> Vec<u8> {
        let mut plain_key_mat = Vec::with_capacity(46);
        plain_key_mat.extend_from_slice(b"soundcored3200");
        plain_key_mat.extend_from_slice(file_key);
        let session_nonce = [0x33u8; 16];
        let enc_file_key =
            DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, session_key, &session_nonce).unwrap();
        let mut head_payload = Vec::with_capacity(87);
        head_payload.extend_from_slice(&file_id.to_le_bytes());
        head_payload.extend_from_slice(&file_size.to_le_bytes());
        head_payload.extend_from_slice(file_nonce);
        head_payload.extend_from_slice(&enc_file_key);
        head_payload.extend_from_slice(&session_nonce);
        head_payload.push(error_code);
        TransportSession::build_rx_frame(0x1A, 0x07, &head_payload)
    }

    #[test]
    fn wifi_batch_completes_on_byte_target_ignores_stale_done_skips_missing_and_sends_finish() {
        let mut session = TransportSession::new();
        let sk = [0x42u8; 32];
        let fk = [0x53u8; 32];
        let fn_iv = [0x64u8; 16];
        session.set_session_key(sk);

        let wifi_cfg = TransportSession::build_rx_frame(
            0x1A,
            0x05,
            &[0x01, 0x2B, 0xA8, 0xC0, 0x02, 0x7D],
        );
        let cfg_out = session.ingest_ble_chunk(&wifi_cfg, 1_700_000_400);
        assert!(cfg_out.transfer_updated);
        assert_eq!(
            session.wifi_endpoint,
            Some(WifiEndpoint {
                ip: [192, 168, 43, 1],
                port: 32002
            })
        );

        session.begin_wifi_batch(&[1001, 1002, 1003]);
        assert_eq!(
            session.pop_outbound_wifi_ws().as_deref(),
            Some(DeviceCommands::build_wifi_file_request_hex(1001, 0).as_str())
        );
        assert_eq!(
            session.pop_outbound_wifi_udp().as_deref(),
            Some(WIFI_KEEPALIVE_PAYLOAD.as_slice())
        );

        let head1 = build_test_head_frame(&sk, 1001, 2 * 166, &fk, &fn_iv);
        let slices1 = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let _ = session.ingest_wifi_chunk(&head1, 1_700_000_401);
        let out1 = session.ingest_wifi_chunk(&slices1, 1_700_000_401);
        assert!(out1.finalized.is_some());
        assert_eq!(session.wifi_batch_progress().finalized_count, 1);
        assert_eq!(session.wifi_batch_progress().current_file_index, 1);
        assert_eq!(
            session.pop_outbound_wifi_ws().as_deref(),
            Some(DeviceCommands::build_wifi_file_request_hex(1002, 0).as_str())
        );

        let head2 = build_test_head_frame(&sk, 1002, 4 * 166, &fk, &fn_iv);
        let slices2_part1 = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x00)]);
        let stale_done = TransportSession::build_rx_frame(0x1A, 0x0A, &[0x01]);
        let _ = session.ingest_wifi_chunk(&head2, 1_700_000_402);
        let _ = session.ingest_wifi_chunk(&slices2_part1, 1_700_000_402);
        let stale_out = session.ingest_wifi_chunk(&stale_done, 1_700_000_402);
        assert!(stale_out.finalized.is_none());
        assert_eq!(session.wifi_batch_progress().current_file_index, 1);
        assert_eq!(session.wifi_batch_progress().received_wire_bytes, 2 * 166);

        let slices2_part2 = build_test_slice_frame(&fk, &fn_iv, &[(2, 0x01), (3, 0x00)]);
        let out2 = session.ingest_wifi_chunk(&slices2_part2, 1_700_000_403);
        assert!(out2.finalized.is_some());
        assert_eq!(session.wifi_batch_progress().finalized_count, 2);
        assert_eq!(
            session.pop_outbound_wifi_ws().as_deref(),
            Some(DeviceCommands::build_wifi_file_request_hex(1003, 0).as_str())
        );

        let head3_missing = build_test_head_frame_with_err(&sk, 1003, 0, &fk, &fn_iv, 1);
        let _ = session.ingest_wifi_chunk(&head3_missing, 1_700_000_404);
        let prog = session.wifi_batch_progress();
        assert_eq!(prog.phase, WifiBatchPhase::Completed);
        assert_eq!(prog.skipped_count, 1);
        assert_eq!(prog.remaining_count, 0);
        assert_eq!(
            session.pop_outbound_wifi_ws().as_deref(),
            Some(WIFI_WS_FINISH_TEXT)
        );
        assert_eq!(
            session.pop_outbound_wifi_ws().as_deref(),
            Some(DeviceCommands::wifi_transfer_complete_hex().as_str())
        );

        let f1 = session.take_next_finalized().unwrap();
        let f2 = session.take_next_finalized().unwrap();
        assert_eq!(f1.entry.id, 1001);
        assert_eq!(f2.entry.id, 1002);
        assert!(session.take_next_finalized().is_none());
    }

    #[test]
    fn wifi_interrupted_salvages_95_percent_file_and_resumes_remaining_queue() {
        let mut session = TransportSession::new();
        let sk = [0x31u8; 32];
        let fk = [0x32u8; 32];
        let fn_iv = [0x33u8; 16];
        session.set_session_key(sk);

        session.begin_wifi_batch(&[2001, 2002]);
        let _ = session.pop_outbound_wifi_ws();
        let _ = session.pop_outbound_wifi_udp();

        let head1 = build_test_head_frame(&sk, 2001, 20 * 166, &fk, &fn_iv);
        let _ = session.ingest_wifi_chunk(&head1, 1_700_000_500);
        let seqs_19: Vec<(u32, u8)> = (0..19u32).map(|s| (s, 0x00)).collect();
        let slices_19 = build_test_slice_frame(&fk, &fn_iv, &seqs_19);
        let _ = session.ingest_wifi_chunk(&slices_19, 1_700_000_501);

        assert!(session.on_wifi_interrupted(1_700_000_502));
        let prog = session.wifi_batch_progress();
        assert_eq!(prog.phase, WifiBatchPhase::Interrupted);
        assert_eq!(prog.salvaged_count, 1);
        assert_eq!(prog.remaining_count, 1);
        assert_eq!(prog.current_file_index, 1);
        assert_eq!(session.take_next_finalized().unwrap().entry.id, 2001);

        assert!(session.resume_wifi_batch());
        assert_eq!(
            session.pop_outbound_wifi_ws().as_deref(),
            Some(DeviceCommands::build_wifi_file_request_hex(2002, 0).as_str())
        );
        assert_eq!(
            session.pop_outbound_wifi_udp().as_deref(),
            Some(WIFI_KEEPALIVE_PAYLOAD.as_slice())
        );
    }

    #[test]
    fn wifi_poll_timers_queues_2000ms_udp_keepalive_packets() {
        let mut session = TransportSession::new();
        session.begin_wifi_batch(&[3001]);
        assert_eq!(
            session.pop_outbound_wifi_udp().as_deref(),
            Some(WIFI_KEEPALIVE_PAYLOAD.as_slice())
        );
        assert!(session.pop_outbound_wifi_udp().is_none());

        let _ = session.poll_timers(1_999, 1_700_000_600);
        assert!(session.pop_outbound_wifi_udp().is_none());

        let _ = session.poll_timers(2_001, 1_700_000_604);
        assert_eq!(
            session.pop_outbound_wifi_udp().as_deref(),
            Some(WIFI_KEEPALIVE_PAYLOAD.as_slice())
        );
        assert_eq!(
            session.pop_outbound_wifi_udp().as_deref(),
            Some(WIFI_KEEPALIVE_PAYLOAD.as_slice())
        );
        assert!(session.pop_outbound_wifi_udp().is_none());
    }
}
