//! Stateful D3200 transport session state machine (`01/01` telemetry, `2E/01` ECDH
//! handshake verification, `1A/01`–`1B/0E` offline catalog, `1A/07` encrypted file
//! head, `1A/08` 166-byte slice decryptor & mark accumulator, and `1A/0A` Ogg Opus/WAV
//! finalizer).
//!
//! # Examples
//!
//! ```
//! use koe_engine::session::TransportSession;
//!
//! let mut session = TransportSession::new();
//! let finalized = session.simulate_realtime_pipeline(1_700_000_000);
//! assert_eq!(finalized.entry.id, 20261107);
//! assert_eq!(finalized.entry.marks_ms, vec![300, 900]);
//! assert!(finalized.ogg_opus_bytes.starts_with(b"OggS"));
//! assert!(finalized.preview_wav_bytes.is_empty()); // No decoder was supplied.
//! ```

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::commands::DeviceCommands;
use crate::crypto::{AesCtrStreamDecrypt, AudioFileSecretKey, DeviceCrypto};
use crate::frame::{FrameReassembler, ProtocolFrame, RX_MAGIC, read_u32_le};
use crate::hash::is_valid_sha256_hex;
use crate::library::RecordingEntry;
use crate::models::{DeviceInfoModel, OfflineFileEntry, OfflineFileList};
use crate::ogg_opus::OggOpus;
use crate::slice_marks::SliceMark;
use crate::transport::{
    OPUS_FRAME_BYTES, OpenedFileHead, SLICE_RECORD_BYTES, TransportSliceProcessor,
    UNFINISHED_FILE_SIZE,
};
use crate::wav::{
    ASR_SAMPLE_RATE, OpusDecoderFactory, OpusStreamDecoder, OpusWave, WAV_SAMPLE_RATE,
    default_opus_decoder_factory,
};
use crate::wifi::{
    WIFI_KEEPALIVE_INTERVAL_MS, WIFI_KEEPALIVE_PAYLOAD, WIFI_WS_FINISH_TEXT, WifiBatchPhase,
    WifiBatchProgress, WifiEndpoint, normalize_wifi_chunk,
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
    /// Whether the transfer was a realtime stream (`true`) or an offline pull (`false`).
    pub is_realtime: bool,
    /// Base slice offset when resuming an open stream mid-file.
    pub base_slice_offset: u32,
}

/// Durable disk `fsync` custody receipt required before hardware file deletion (`0x1A/0x10`),
/// modeled after `BasedHardware/omi` `PENDANT_RING_CUSTODY.md`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CustodyReceipt {
    /// D3200 hardware file identifier (`file_id`).
    pub file_id: u32,
    /// Verified `.opus` byte count flushed to local storage.
    pub byte_count: u32,
    /// Lowercase 64-character hex SHA-256 digest of the persisted `.opus` container.
    pub sha256_hex: String,
    /// Unix epoch timestamp (seconds) when `fsync` completed.
    pub fsynced_at_epoch_sec: u64,
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
    /// The device explicitly reported that recording stopped.
    pub recording_stopped: bool,
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

/// Ordered capture events keep audio attached to its device file across batched notifications.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CaptureEvent {
    /// A realtime stream has started or switched to `file_id`.
    Started {
        /// Device file identity at stream start.
        file_id: u32,
    },
    /// Decoded realtime audio, before a possible file switch in the same notification.
    Audio {
        /// Device file identity at decode time.
        file_id: u32,
        /// 16 kHz mono PCM16 little-endian samples.
        pcm16: Vec<u8>,
    },
    /// A finalized artifact is now available in the finalized recording queue.
    Finished {
        /// Device file identity at finalization time.
        file_id: u32,
    },
}

/// Pure protocol-level companion signal emitted in slice order without I/O.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RawCompanionSignal {
    /// Device recording state changed (`0` = stopped, `1` = recording, `2` = paused).
    RecordingStateChanged {
        /// D3200 recording state (`0`, `1`, or `2`).
        state: u8,
        /// Active or announced bean `file_id`, if known.
        file_id: Option<u32>,
    },
    /// Front housing double-tap mark (`flags & 0x01`) on a 20 ms realtime audio slice.
    FrontDoubleTap {
        /// Active bean `file_id`.
        file_id: u32,
        /// Zero-based 20 ms slice sequence number.
        slice_seq: u32,
        /// Millisecond offset (`slice_seq * 20`).
        offset_ms: u64,
    },
    /// Single 20 ms frame (`320` samples at `16 kHz` mono) of decoded realtime PCM16 audio.
    LivePcm16 {
        /// Active bean `file_id`.
        file_id: u32,
        /// Zero-based 20 ms slice sequence number.
        slice_seq: u32,
        /// Decoded 16 kHz mono signed 16-bit PCM samples.
        samples: Vec<i16>,
    },
    /// Hardware file deletion response (`0x1A 0x10`).
    DeleteFileAck {
        /// Whether deletion succeeded.
        success: bool,
    },
}

const MAX_COMPANION_SIGNALS: usize = 4_096;

/// Current phase of multi-page offline file catalog retrieval (`0x1B 0x0E`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CatalogLoadPhase {
    /// No catalog listing in flight.
    #[default]
    Idle,
    /// Page 0 request dispatched, awaiting initial batch of file entries.
    AwaitingFirstPage,
    /// Chaining sequential catalog pages (`page 1+`).
    Paginating {
        /// Next 0-based page index to query.
        next_page: u16,
    },
}

/// Stateful D3200 transport session engine.
pub struct TransportSession {
    capture_events: VecDeque<CaptureEvent>,
    companion_signals: VecDeque<RawCompanionSignal>,
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
    /// All deduplicated offline file entries from the most recent completed listing, including zero-duration entries.
    pub raw_catalog: Vec<OfflineFileEntry>,
    /// Snapshot of raw catalog entries captured at realtime recording start.
    pub pre_start_entries: BTreeMap<u32, OfflineFileEntry>,
    /// Current phase of multi-page offline catalog retrieval (`0x1B 0x0E`).
    pub catalog_load_phase: CatalogLoadPhase,
    /// Elapsed milliseconds since the current catalog page request was dispatched.
    pub catalog_page_elapsed_ms: u64,
    /// In-flight catalog entries accumulated across pages before pagination completes.
    pub staged_catalog_entries: Vec<OfflineFileEntry>,
    /// Active transport timestamp announced in a catalog page header, if present.
    pub staged_transport_timestamp: Option<u32>,
    /// Whether the in-flight catalog listing was queried with end-time metadata (`0x1B 0x0E`).
    pub staged_with_end_time: bool,
    /// Whether at least one full catalog listing with end-time metadata (`0x1B 0x0E`) has completed.
    pub has_complete_catalog: bool,
    /// Whether the most recent catalog query timed out before all pages were received.
    pub catalog_timed_out: bool,
    /// Number of consecutive 3-second timeout retries attempted for the initial catalog.
    pub catalog_timeout_retries: u8,
    /// Whether a catalog refresh request was deferred while a previous catalog query was in flight.
    pub catalog_refresh_queued: bool,
    /// Whether the active catalog listing was triggered to resolve a pending realtime stream subscription.
    pub catalog_started_for_subscribe: bool,
    /// Raw wire file IDs encountered across pages during the current catalog pagination.
    pub staged_seen_wire_ids: BTreeSet<u32>,
    /// The first wire file ID observed on page 0 of the current catalog pagination.
    pub staged_first_page_head: Option<u32>,
    /// Whether to skip existing audio slices when resuming an open stream at start.
    pub skip_existing_slices_on_start: bool,
    /// Base slice offset when resuming an open stream mid-file.
    pub stream_base_slices: u32,
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
    /// Whether the recording bean hardware is currently recording (`01/01`, `18/81`, `18/82`, or `1A/06` state `1`).
    pub device_recording_active: bool,
    /// Whether the session is awaiting the next `1A/0E` or `1B/0E` catalog response to subscribe to the newest active file in realtime mode.
    pub pending_realtime_subscribe: bool,
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
    /// Verified disk `fsync` custody receipts keyed by D3200 `file_id`, guarding `0x1A/0x10` deletion.
    pub custody_receipts: BTreeMap<u32, CustodyReceipt>,
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
            capture_events: self.capture_events.clone(),
            companion_signals: self.companion_signals.clone(),
            reassembler: self.reassembler.clone(),
            connection_phase: self.connection_phase,
            telemetry: self.telemetry.clone(),
            ecdh_private_key: self.ecdh_private_key,
            session_key: self.session_key,
            catalog: self.catalog.clone(),
            raw_catalog: self.raw_catalog.clone(),
            pre_start_entries: self.pre_start_entries.clone(),
            catalog_load_phase: self.catalog_load_phase,
            catalog_page_elapsed_ms: self.catalog_page_elapsed_ms,
            staged_catalog_entries: self.staged_catalog_entries.clone(),
            staged_transport_timestamp: self.staged_transport_timestamp,
            staged_with_end_time: self.staged_with_end_time,
            has_complete_catalog: self.has_complete_catalog,
            catalog_timed_out: self.catalog_timed_out,
            catalog_timeout_retries: self.catalog_timeout_retries,
            catalog_refresh_queued: self.catalog_refresh_queued,
            catalog_started_for_subscribe: self.catalog_started_for_subscribe,
            staged_seen_wire_ids: self.staged_seen_wire_ids.clone(),
            staged_first_page_head: self.staged_first_page_head,
            skip_existing_slices_on_start: self.skip_existing_slices_on_start,
            stream_base_slices: self.stream_base_slices,
            transfer: self.transfer,
            runtime_state: self.runtime_state.clone(),
            active_file_id: self.active_file_id,
            active_file_key: self.active_file_key,
            active_nonce: self.active_nonce,
            active_is_realtime: self.active_is_realtime,
            device_recording_active: self.device_recording_active,
            pending_realtime_subscribe: self.pending_realtime_subscribe,
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
            custody_receipts: self.custody_receipts.clone(),
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
            .field("raw_catalog_len", &self.raw_catalog.len())
            .field("catalog_load_phase", &self.catalog_load_phase)
            .field("has_complete_catalog", &self.has_complete_catalog)
            .field("catalog_timed_out", &self.catalog_timed_out)
            .field("catalog_refresh_queued", &self.catalog_refresh_queued)
            .field("stream_base_slices", &self.stream_base_slices)
            .field("transfer", &self.transfer)
            .field("runtime_state", &self.runtime_state)
            .field("active_file_id", &self.active_file_id)
            .field("active_file_key", &self.active_file_key)
            .field("active_nonce", &self.active_nonce)
            .field("active_is_realtime", &self.active_is_realtime)
            .field("device_recording_active", &self.device_recording_active)
            .field(
                "pending_realtime_subscribe",
                &self.pending_realtime_subscribe,
            )
            .field("opus_buffer_len", &self.opus_buffer.len())
            .field("marks_ms", &self.marks_ms)
            .field("last_finalized", &self.last_finalized)
            .field("finalized_queue_len", &self.finalized_queue.len())
            .field("companion_signals_len", &self.companion_signals.len())
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
            capture_events: VecDeque::new(),
            companion_signals: VecDeque::new(),
            reassembler: FrameReassembler::default(),
            connection_phase: ConnectionPhaseTag::Disconnected,
            telemetry: None,
            ecdh_private_key: None,
            session_key: None,
            catalog: Vec::new(),
            raw_catalog: Vec::new(),
            pre_start_entries: BTreeMap::new(),
            catalog_load_phase: CatalogLoadPhase::Idle,
            catalog_page_elapsed_ms: 0,
            staged_catalog_entries: Vec::new(),
            staged_transport_timestamp: None,
            staged_with_end_time: false,
            has_complete_catalog: false,
            catalog_timed_out: false,
            catalog_timeout_retries: 0,
            catalog_refresh_queued: false,
            catalog_started_for_subscribe: false,
            staged_seen_wire_ids: BTreeSet::new(),
            staged_first_page_head: None,
            skip_existing_slices_on_start: false,
            stream_base_slices: 0,
            transfer: TransferProgress::default(),
            runtime_state: TransferRuntimeState::Idle,
            active_file_id: None,
            active_file_key: None,
            active_nonce: None,
            active_is_realtime: false,
            device_recording_active: false,
            pending_realtime_subscribe: false,
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
            custody_receipts: BTreeMap::new(),
            decoder_factory: factory,
            live_decoder_16k: None,
        }
    }

    /// Records a verified disk `fsync` [`CustodyReceipt`] for `receipt.file_id`.
    /// Returns `false` if `file_id == 0`, `byte_count == 0`, or `sha256_hex` is not a valid 64-hex SHA-256 digest.
    pub fn confirm_disk_custody(&mut self, receipt: CustodyReceipt) -> bool {
        if receipt.file_id == 0
            || receipt.byte_count == 0
            || !is_valid_sha256_hex(&receipt.sha256_hex)
        {
            return false;
        }
        self.custody_receipts.insert(receipt.file_id, receipt);
        true
    }

    /// Returns `true` if a verified disk `fsync` [`CustodyReceipt`] has been recorded for `file_id`.
    #[must_use]
    pub fn has_disk_custody(&self, file_id: u32) -> bool {
        self.custody_receipts.contains_key(&file_id)
    }

    /// Builds a D3200 `0x1A/0x10` hardware file deletion command ONLY if a verified
    /// disk `fsync` [`CustodyReceipt`] exists for `file_id` (enforcing Omi's `PendantRingCustody` invariant).
    pub fn request_reclaim_bean_file(&self, file_id: u32) -> Result<Vec<u8>, &'static str> {
        if !self.has_disk_custody(file_id) {
            return Err(
                "refusing to delete D3200 hardware file 0x1A/0x10 before disk fsync custody receipt",
            );
        }
        Ok(DeviceCommands::delete_file(file_id))
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

    /// Drains audio and finalization events in protocol order.
    pub fn take_capture_events(&mut self) -> VecDeque<CaptureEvent> {
        std::mem::take(&mut self.capture_events)
    }

    /// Drains ordered companion signals accumulated since the previous call.
    pub fn take_companion_signals(&mut self) -> Vec<RawCompanionSignal> {
        self.companion_signals.drain(..).collect()
    }

    fn push_companion_signal(&mut self, signal: RawCompanionSignal) {
        if self.companion_signals.len() >= MAX_COMPANION_SIGNALS {
            self.companion_signals.pop_front();
        }
        self.companion_signals.push_back(signal);
    }

    /// Returns the number of complete 160-byte Opus slices currently buffered for the active file.
    #[must_use]
    pub fn received_slice_count(&self) -> u32 {
        (self.opus_buffer.len() / OPUS_FRAME_BYTES) as u32
    }

    /// Returns the total slice offset for the active realtime stream (`base + received`).
    #[must_use]
    pub fn total_slice_offset(&self) -> u32 {
        self.stream_base_slices
            .saturating_add(self.received_slice_count())
    }

    /// Returns `true` if catalog retrieval (first page or subsequent pages) is actively in flight.
    #[must_use]
    pub fn is_catalog_loading(&self) -> bool {
        self.catalog_load_phase != CatalogLoadPhase::Idle
    }

    /// Returns `true` if at least one complete multi-page catalog listing with end-time metadata has finished.
    #[must_use]
    pub fn has_complete_catalog(&self) -> bool {
        self.has_complete_catalog
    }

    /// Returns the set of all known file IDs in the raw catalog, including zero-duration entries.
    #[must_use]
    pub fn raw_catalog_file_ids(&self) -> std::collections::BTreeSet<u32> {
        self.raw_catalog.iter().map(|f| f.file_id).collect()
    }

    /// Removes a file entry from both the public catalog and raw catalog by `file_id`.
    pub fn remove_catalog_entry(&mut self, fid: u32) {
        if fid == 0 {
            return;
        }
        self.catalog.retain(|f| f.file_id != fid);
        self.raw_catalog.retain(|f| f.file_id != fid);
    }

    /// Computes the number of 20 ms audio slices already recorded in flash for `fid`.
    pub fn known_base_slices_for(&self, fid: u32) -> u32 {
        if !self.skip_existing_slices_on_start {
            return 0;
        }
        let entry = self
            .pre_start_entries
            .get(&fid)
            .or_else(|| self.raw_catalog.iter().find(|f| f.file_id == fid));
        match entry {
            Some(entry) if entry.has_duration() => {
                (entry.duration_ms / 20).min(u32::MAX / (SLICE_RECORD_BYTES as u32))
            }
            _ => 0,
        }
    }

    /// Resets catalog pagination state and returns a `0x1B 0x0E` page-0 query frame.
    pub fn request_full_catalog(&mut self) -> Vec<u8> {
        if self.is_catalog_loading() {
            self.catalog_refresh_queued = true;
            return Vec::new();
        }
        self.catalog_load_phase = CatalogLoadPhase::AwaitingFirstPage;
        self.catalog_page_elapsed_ms = 0;
        self.staged_catalog_entries.clear();
        self.staged_seen_wire_ids.clear();
        self.staged_first_page_head = None;
        self.staged_transport_timestamp = None;
        self.staged_with_end_time = true;
        DeviceCommands::list_files_with_end_time(0)
    }

    /// Starts a realtime recording, optionally skipping existing slices if resuming an open stream.
    pub fn start_realtime_recording_with_options(
        &mut self,
        file_id: Option<u32>,
        now_epoch_ms: u64,
        skip_existing_slices: bool,
    ) -> SessionIngestOutcome {
        self.skip_existing_slices_on_start = skip_existing_slices;
        self.start_realtime_recording(file_id, now_epoch_ms)
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
        self.stream_base_slices = 0;
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
        self.device_recording_active = false;
        self.pending_realtime_subscribe = false;
        self.pre_start_entries.clear();
        self.catalog_load_phase = CatalogLoadPhase::Idle;
        self.catalog_page_elapsed_ms = 0;
        self.staged_catalog_entries.clear();
        self.staged_seen_wire_ids.clear();
        self.staged_first_page_head = None;
        self.staged_transport_timestamp = None;
        self.staged_with_end_time = false;
        self.has_complete_catalog = false;
        self.catalog_timed_out = false;
        self.catalog_timeout_retries = 0;
        self.catalog_refresh_queued = false;
        self.catalog_started_for_subscribe = false;
        self.skip_existing_slices_on_start = false;
        self.companion_signals.clear();
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
        self.catalog_load_phase = CatalogLoadPhase::Idle;
        self.catalog_page_elapsed_ms = 0;
        self.staged_catalog_entries.clear();
        self.staged_seen_wire_ids.clear();
        self.staged_first_page_head = None;
        self.staged_transport_timestamp = None;
        self.staged_with_end_time = false;
        self.has_complete_catalog = false;
        self.catalog_timed_out = false;
        self.catalog_timeout_retries = 0;
        self.catalog_refresh_queued = false;
        self.catalog_started_for_subscribe = false;
        self.skip_existing_slices_on_start = false;
        self.pre_start_entries.clear();
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
                self.transfer.received_wire_bytes = self
                    .received_slice_count()
                    .saturating_mul(SLICE_RECORD_BYTES as u32);
                self.transfer.quiet_draining = false;
            }
            TransferRuntimeState::Failed { .. } => {
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
                (
                    fid,
                    self.transfer.expected_wire_bytes,
                    self.transfer.retry_count,
                )
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
        Some(DeviceCommands::start_transport_audio_file(
            file_id, offset, 0,
        ))
    }

    fn finalize_staged_catalog(&mut self, now_epoch_sec: u64, outcome: &mut SessionIngestOutcome) {
        self.catalog_load_phase = CatalogLoadPhase::Idle;
        self.catalog_page_elapsed_ms = 0;
        self.catalog_timed_out = false;
        self.catalog_timeout_retries = 0;
        if self.staged_with_end_time {
            self.has_complete_catalog = true;
        }
        self.raw_catalog = std::mem::take(&mut self.staged_catalog_entries);
        self.catalog = self
            .raw_catalog
            .iter()
            .filter(|f| f.has_duration())
            .cloned()
            .collect();
        outcome.catalog_updated = true;

        if self.pending_realtime_subscribe
            || (self.device_recording_active && self.active_file_id.is_none())
        {
            let candidate_fid = if self.staged_with_end_time {
                let open_new = self
                    .raw_catalog
                    .iter()
                    .filter(|f| {
                        f.file_id > 0
                            && f.end_time == Some(0)
                            && !self.pre_start_entries.contains_key(&f.file_id)
                    })
                    .map(|f| f.file_id)
                    .max();
                let open_any = open_new.or_else(|| {
                    self.raw_catalog
                        .iter()
                        .filter(|f| f.file_id > 0 && f.end_time == Some(0))
                        .map(|f| f.file_id)
                        .max()
                });
                open_any.or_else(|| {
                    self.staged_transport_timestamp.filter(|&ts| {
                        ts > 0
                            && !self
                                .raw_catalog
                                .iter()
                                .any(|f| f.file_id == ts && f.end_time.is_some_and(|et| et > 0))
                    })
                })
            } else {
                let unstarted = self
                    .raw_catalog
                    .iter()
                    .filter(|f| f.file_id > 0 && !self.pre_start_entries.contains_key(&f.file_id))
                    .map(|f| f.file_id)
                    .max();
                unstarted
                    .or_else(|| self.staged_transport_timestamp.filter(|&id| id > 0))
                    .or_else(|| {
                        self.raw_catalog
                            .iter()
                            .map(|f| f.file_id)
                            .max()
                            .filter(|&id| id > 0)
                    })
            };

            let has_fresh_open_candidate = candidate_fid.is_some_and(|fid| {
                !self.pre_start_entries.contains_key(&fid)
                    && self
                        .raw_catalog
                        .iter()
                        .any(|f| f.file_id == fid && f.end_time == Some(0))
            });

            if self.catalog_refresh_queued && !has_fresh_open_candidate {
                self.catalog_refresh_queued = false;
                self.catalog_started_for_subscribe = self.pending_realtime_subscribe;
                let tx = self.request_full_catalog();
                if !tx.is_empty() {
                    outcome.outbound_tx_frames.push(tx);
                }
                return;
            }
            self.catalog_refresh_queued = false;

            if let Some(fid) = candidate_fid {
                let base_slices = self.known_base_slices_for(fid);
                if let Some(tx) =
                    self.enter_or_resume_realtime_stream_at(fid, base_slices, now_epoch_sec)
                {
                    outcome.outbound_tx_frames.push(tx);
                    outcome.transfer_updated = true;
                }
            } else if self.active_file_id.is_none()
                && !matches!(self.transfer.phase, TransferPhaseTag::Failed)
            {
                self.runtime_state = TransferRuntimeState::Idle;
                self.transfer.phase = TransferPhaseTag::Idle;
            }
            self.pre_start_entries.clear();
        } else {
            if self.catalog_refresh_queued {
                self.catalog_refresh_queued = false;
                let tx = self.request_full_catalog();
                if !tx.is_empty() {
                    outcome.outbound_tx_frames.push(tx);
                }
            }
            if self.active_file_id.is_none()
                && !matches!(self.transfer.phase, TransferPhaseTag::Failed)
            {
                self.runtime_state = TransferRuntimeState::Idle;
                self.transfer.phase = TransferPhaseTag::Idle;
            }
            self.pre_start_entries.clear();
        }
    }

    /// Resumes a realtime stream at an explicit slice offset, returning the `1A/07` TX frame.
    pub fn enter_or_resume_realtime_stream_at(
        &mut self,
        file_id: u32,
        base_slices: u32,
        now_epoch_sec: u64,
    ) -> Option<Vec<u8>> {
        if file_id == 0 {
            return None;
        }
        let is_new_stream = self.active_file_id != Some(file_id) || !self.active_is_realtime;
        if self.active_file_id != Some(file_id) {
            if self.active_is_realtime
                && self.active_file_id.is_some()
                && !self.opus_buffer.is_empty()
            {
                let _ = self.finalize_active_transfer(now_epoch_sec);
            }
            self.active_file_key = None;
            self.active_nonce = None;
            self.opus_buffer.clear();
            self.marks_ms.clear();
            self.live_pcm16_16khz.clear();
            if let Some(dec) = self.live_decoder_16k.as_mut() {
                dec.reset();
            }
            self.stream_base_slices = base_slices;
        } else if self.opus_buffer.is_empty() && base_slices > self.stream_base_slices {
            self.stream_base_slices = base_slices;
        }
        if is_new_stream {
            self.capture_events
                .push_back(CaptureEvent::Started { file_id });
            self.push_companion_signal(RawCompanionSignal::RecordingStateChanged {
                state: 1,
                file_id: Some(file_id),
            });
        }
        let offset = self
            .total_slice_offset()
            .saturating_mul(SLICE_RECORD_BYTES as u32);
        self.active_file_id = Some(file_id);
        self.active_is_realtime = true;
        self.device_recording_active = true;
        self.pending_realtime_subscribe = false;
        self.runtime_state = TransferRuntimeState::StreamingRealtime {
            file_id,
            quiet_drain_elapsed_ms: None,
        };
        self.transfer = TransferProgress {
            phase: TransferPhaseTag::StreamingRealtime,
            file_id,
            received_wire_bytes: offset,
            expected_wire_bytes: 0,
            mark_count: self.marks_ms.len() as u32,
            error_code: 0,
            retry_count: 0,
            quiet_draining: false,
        };
        Some(DeviceCommands::start_transport_audio_file(
            file_id, offset, 1,
        ))
    }

    fn enter_or_resume_realtime_stream(
        &mut self,
        file_id: u32,
        now_epoch_sec: u64,
    ) -> Option<Vec<u8>> {
        self.enter_or_resume_realtime_stream_at(file_id, 0, now_epoch_sec)
    }

    /// Starts an app-initiated realtime bean recording (`0x18 0x81 [0x01]` + `0x18 0x82 [0x01]`).
    ///
    /// When `file_id` is `Some(fid)` (`fid > 0`), immediately subscribes to `1A/07` (`realtime_flag = 1`);
    /// otherwise queues `1B/0E` (`list_files_with_end_time(0)`) and sets `pending_realtime_subscribe = true`
    /// so the session subscribes as soon as the catalog or `1A/06` reports the active `file_id`.
    pub fn start_realtime_recording(
        &mut self,
        file_id: Option<u32>,
        now_epoch_ms: u64,
    ) -> SessionIngestOutcome {
        let mut outcome = SessionIngestOutcome::default();
        let now_epoch_sec = (now_epoch_ms / 1_000).max(1);
        self.device_recording_active = true;
        outcome
            .outbound_tx_frames
            .push(DeviceCommands::start_realtime_record_81());
        outcome
            .outbound_tx_frames
            .push(DeviceCommands::start_app_recording());
        if let Some(fid) = file_id.filter(|&id| id > 0) {
            let base_slices = self.known_base_slices_for(fid);
            if let Some(tx) =
                self.enter_or_resume_realtime_stream_at(fid, base_slices, now_epoch_sec)
            {
                outcome.outbound_tx_frames.push(tx);
                outcome.transfer_updated = true;
            }
        } else {
            self.pre_start_entries = self
                .raw_catalog
                .iter()
                .map(|f| (f.file_id, f.clone()))
                .collect();
            self.pending_realtime_subscribe = true;
            if self.is_catalog_loading() {
                self.catalog_refresh_queued = true;
                self.catalog_started_for_subscribe = false;
            } else {
                self.catalog_started_for_subscribe = true;
                let tx = self.request_full_catalog();
                if !tx.is_empty() {
                    outcome.outbound_tx_frames.push(tx);
                }
            }
            outcome.transfer_updated = true;
        }
        if file_id.is_none() {
            let signal_fid = self.active_file_id.filter(|&id| id > 0);
            self.push_companion_signal(RawCompanionSignal::RecordingStateChanged {
                state: 1,
                file_id: signal_fid,
            });
        }
        outcome
    }

    /// Explicitly subscribes to or resumes a realtime audio stream (`1A/07` with `realtime_flag = 1`)
    /// for `file_id` from `received_slice_count() * 166` wire bytes.
    pub fn request_realtime_stream(&mut self, file_id: u32) -> Option<Vec<u8>> {
        self.enter_or_resume_realtime_stream(file_id, 0)
    }

    /// Stops/pauses an active realtime bean recording (`0x18 0x82 [0x02]`) and enters the
    /// 2,000 ms quiet-drain window before finalization.
    pub fn stop_realtime_recording(&mut self) -> SessionIngestOutcome {
        let mut outcome = SessionIngestOutcome::default();
        self.device_recording_active = false;
        self.pending_realtime_subscribe = false;
        self.pre_start_entries.clear();
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
        self.push_companion_signal(RawCompanionSignal::RecordingStateChanged {
            state: 2,
            file_id: self.active_file_id.filter(|&id| id > 0),
        });
        outcome
    }

    /// Advances the 5,000 ms offline pull watchdog (up to 2 retries per file), the 2,000 ms
    /// realtime post-stop quiet-drain timer, and the 2,000 ms Wi-Fi SoftAP UDP `:32003` keepalive
    /// timer by `elapsed_ms`.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now_epoch_sec: u64) -> SessionIngestOutcome {
        let mut outcome = SessionIngestOutcome::default();
        if self.is_catalog_loading() {
            self.catalog_page_elapsed_ms = self.catalog_page_elapsed_ms.saturating_add(elapsed_ms);
            if self.catalog_page_elapsed_ms >= 3_000 {
                self.catalog_load_phase = CatalogLoadPhase::Idle;
                self.catalog_page_elapsed_ms = 0;
                self.catalog_timed_out = true;
                for entry in std::mem::take(&mut self.staged_catalog_entries) {
                    if let Some(existing) = self
                        .raw_catalog
                        .iter_mut()
                        .find(|f| f.file_id == entry.file_id)
                    {
                        *existing = entry;
                    } else {
                        self.raw_catalog.push(entry);
                    }
                }
                self.catalog = self
                    .raw_catalog
                    .iter()
                    .filter(|f| f.has_duration())
                    .cloned()
                    .collect();
                outcome.catalog_updated = true;

                if !self.has_complete_catalog && self.catalog_timeout_retries < 2 {
                    self.catalog_timeout_retries += 1;
                    let retry_tx = self.request_full_catalog();
                    if !retry_tx.is_empty() {
                        outcome.outbound_tx_frames.push(retry_tx);
                    }
                }
            }
        }
        if self.wifi_batch_phase == WifiBatchPhase::Transferring {
            self.wifi_keepalive_elapsed_ms =
                self.wifi_keepalive_elapsed_ms.saturating_add(elapsed_ms);
            while self.wifi_keepalive_elapsed_ms >= WIFI_KEEPALIVE_INTERVAL_MS {
                self.wifi_keepalive_elapsed_ms -= WIFI_KEEPALIVE_INTERVAL_MS;
                self.wifi_outbound_udp
                    .push_back(WIFI_KEEPALIVE_PAYLOAD.to_vec());
                outcome.transfer_updated = true;
            }
            if matches!(self.runtime_state, TransferRuntimeState::Idle) {
                return outcome;
            }
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
                        self.active_file_id = None;
                        self.active_is_realtime = false;
                        self.active_file_key = None;
                        self.active_nonce = None;
                        self.opus_buffer.clear();
                        self.marks_ms.clear();
                        self.stream_base_slices = 0;
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
                    }
                    outcome.transfer_updated = true;
                    outcome
                        .outbound_tx_frames
                        .push(DeviceCommands::list_files_with_end_time(0));
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
        self.wifi_finalized_count = 0;
        self.wifi_salvaged_count = 0;
        self.wifi_skipped_count = 0;
        self.wifi_outbound_ws.clear();
        self.wifi_outbound_udp.clear();
        self.wifi_keepalive_elapsed_ms = 0;
        self.wifi_batch_phase = WifiBatchPhase::Idle;
        self.wifi_endpoint = None;
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
        let can_salvage = expected > 0
            && received >= (expected.saturating_mul(95)) / 100
            && !self.opus_buffer.is_empty();
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
    pub fn ingest_wifi_chunk(&mut self, chunk: &[u8], now_epoch_sec: u64) -> SessionIngestOutcome {
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
        let derived = DeviceCrypto::hkdf_sha256(computed_shared_secret, &[1, 2, 3], &[1, 2, 3], 32);
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
        self.stream_base_slices = 0;
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
                            if let Some(shared) = DeviceCrypto::p256_ecdh_shared_secret(
                                &priv_key,
                                &pkt.payload[0..65],
                            ) {
                                if self.accept_ecdh_reply(&pkt.payload, &shared) {
                                    outcome.session_key_established = true;
                                    if self.telemetry.is_some()
                                        && self.connection_phase == ConnectionPhaseTag::Handshaking
                                    {
                                        self.connection_phase = ConnectionPhaseTag::Connected;
                                    } else if self.telemetry.is_none() {
                                        outcome
                                            .outbound_tx_frames
                                            .push(DeviceCommands::get_device_info());
                                    }
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
                    let is_rec = info.recording();
                    let rec_state = info.recording_status;
                    self.device_recording_active = is_rec;
                    if is_rec {
                        if !self.active_is_realtime || self.active_file_id.is_none() {
                            self.pending_realtime_subscribe = true;
                        }
                    } else {
                        self.pending_realtime_subscribe = false;
                        if self.active_is_realtime {
                            if let Some(fid) = self.active_file_id.filter(|&id| id > 0) {
                                self.runtime_state = TransferRuntimeState::StreamingRealtime {
                                    file_id: fid,
                                    quiet_drain_elapsed_ms: Some(0),
                                };
                                self.transfer.quiet_draining = true;
                                outcome.transfer_updated = true;
                            }
                        }
                    }
                    if rec_state <= 2 {
                        self.push_companion_signal(RawCompanionSignal::RecordingStateChanged {
                            state: rec_state,
                            file_id: self.active_file_id.filter(|&id| id > 0),
                        });
                    }
                    self.telemetry = Some(info);
                    if self.ecdh_private_key.is_some() && self.session_key.is_none() {
                        self.connection_phase = ConnectionPhaseTag::Handshaking;
                    } else {
                        self.connection_phase = ConnectionPhaseTag::Connected;
                    }
                    outcome.telemetry_updated = true;
                    let tx = self.request_full_catalog();
                    if !tx.is_empty() {
                        outcome.outbound_tx_frames.push(tx);
                    }
                    if self.is_offline_pull_suspended() && self.session_key.is_some() {
                        if let Some(resume_tx) = self.resume_offline_pull() {
                            outcome.outbound_tx_frames.push(resume_tx);
                            outcome.transfer_updated = true;
                        }
                    }
                }
                (0x18, 0x81) | (0x18, 0x82) => {
                    if !pkt.payload.is_empty() {
                        let (fid, state) = if pkt.cmd_id == 0x81
                            && pkt.payload.len() >= 5
                            && read_u32_le(&pkt.payload, 0) > 2
                            && pkt.payload[4] <= 2
                        {
                            (read_u32_le(&pkt.payload, 0), pkt.payload[4])
                        } else if pkt.cmd_id == 0x81 && pkt.payload.len() == 4 {
                            (read_u32_le(&pkt.payload, 0), 1)
                        } else {
                            (0, pkt.payload[0])
                        };
                        if state == 1 {
                            self.device_recording_active = true;
                            if fid > 0 {
                                let base_slices = self.known_base_slices_for(fid);
                                if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                                    fid,
                                    base_slices,
                                    now_epoch_sec,
                                ) {
                                    outcome.outbound_tx_frames.push(tx);
                                    outcome.transfer_updated = true;
                                }
                            } else if let Some(active_fid) = self
                                .active_file_id
                                .filter(|&id| id > 0 && self.active_is_realtime)
                            {
                                if self.is_realtime_quiet_draining() {
                                    let base_slices = self.known_base_slices_for(active_fid);
                                    if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                                        active_fid,
                                        base_slices,
                                        now_epoch_sec,
                                    ) {
                                        outcome.outbound_tx_frames.push(tx);
                                        outcome.transfer_updated = true;
                                    }
                                }
                            } else {
                                self.pending_realtime_subscribe = true;
                                if self.is_catalog_loading() {
                                    if !self.catalog_started_for_subscribe {
                                        self.catalog_refresh_queued = true;
                                    }
                                } else {
                                    self.catalog_started_for_subscribe = true;
                                    let tx = self.request_full_catalog();
                                    if !tx.is_empty() {
                                        outcome.outbound_tx_frames.push(tx);
                                    }
                                }
                                outcome.transfer_updated = true;
                            }
                        } else if state == 0 || state == 2 {
                            self.device_recording_active = false;
                            outcome.recording_stopped = true;
                            self.pending_realtime_subscribe = false;
                            if self.active_is_realtime {
                                if let Some(active_fid) = self.active_file_id.filter(|&id| id > 0) {
                                    self.runtime_state = TransferRuntimeState::StreamingRealtime {
                                        file_id: active_fid,
                                        quiet_drain_elapsed_ms: Some(0),
                                    };
                                    self.transfer.quiet_draining = true;
                                }
                            }
                            if state == 0 {
                                if self.is_catalog_loading() {
                                    self.catalog_refresh_queued = true;
                                } else {
                                    outcome
                                        .outbound_tx_frames
                                        .push(DeviceCommands::list_files_with_end_time(0));
                                }
                            }
                            outcome.transfer_updated = true;
                        }
                        if state <= 2 {
                            self.push_companion_signal(RawCompanionSignal::RecordingStateChanged {
                                state,
                                file_id: (fid > 0)
                                    .then_some(fid)
                                    .or_else(|| self.active_file_id.filter(|&id| id > 0)),
                            });
                        }
                    }
                }
                (0x1A, 0x01) | (0x1A, 0x0D) | (0x1A, 0x0E) | (0x1B, 0x0E) => {
                    let with_end_time =
                        pkt.cmd_id == 0x0D || (pkt.cmd_type == 0x1B && pkt.cmd_id == 0x0E);
                    let page = OfflineFileList::parse(&pkt.payload, with_end_time);
                    match self.catalog_load_phase {
                        CatalogLoadPhase::Idle => {
                            if self.catalog_timed_out {
                                self.staged_catalog_entries = self.raw_catalog.clone();
                                self.staged_seen_wire_ids =
                                    self.raw_catalog.iter().map(|f| f.file_id).collect();
                                self.staged_first_page_head =
                                    self.raw_catalog.first().map(|f| f.file_id);
                            } else {
                                self.staged_catalog_entries.clear();
                                self.staged_seen_wire_ids.clear();
                                self.staged_first_page_head = page.wire_ids.first().copied();
                            }
                            self.staged_transport_timestamp = None;
                            self.staged_with_end_time = with_end_time;
                            self.catalog_page_elapsed_ms = 0;
                        }
                        CatalogLoadPhase::AwaitingFirstPage => {
                            self.staged_catalog_entries.clear();
                            self.staged_seen_wire_ids.clear();
                            self.staged_first_page_head = page.wire_ids.first().copied();
                            self.staged_transport_timestamp = None;
                            self.staged_with_end_time = with_end_time;
                            self.catalog_page_elapsed_ms = 0;
                        }
                        CatalogLoadPhase::Paginating { .. } => {
                            if !page.wire_ids.is_empty()
                                && page
                                    .wire_ids
                                    .iter()
                                    .all(|id| self.staged_seen_wire_ids.contains(id))
                                && self.staged_first_page_head == page.wire_ids.first().copied()
                                && page.file_count as usize == page.wire_ids.len()
                            {
                                continue;
                            }
                        }
                    }

                    let mut new_wire_id_seen = false;
                    for &wid in &page.wire_ids {
                        if self.staged_seen_wire_ids.insert(wid) {
                            new_wire_id_seen = true;
                        }
                    }
                    for file in page.files {
                        if let Some(existing) = self
                            .staged_catalog_entries
                            .iter_mut()
                            .find(|f| f.file_id == file.file_id)
                        {
                            *existing = file;
                        } else {
                            self.staged_catalog_entries.push(file);
                        }
                    }
                    if let Some(ts) = page.current_transport_timestamp.filter(|&id| id > 0) {
                        self.staged_transport_timestamp = Some(ts);
                    }

                    let current_page = match self.catalog_load_phase {
                        CatalogLoadPhase::Idle | CatalogLoadPhase::AwaitingFirstPage => 0,
                        CatalogLoadPhase::Paginating { next_page } => next_page.saturating_sub(1),
                    };
                    let next_page = current_page + 1;
                    if with_end_time && page.file_count >= 10 && new_wire_id_seen && next_page < 128
                    {
                        self.catalog_load_phase = CatalogLoadPhase::Paginating {
                            next_page: next_page + 1,
                        };
                        self.catalog_page_elapsed_ms = 0;
                        outcome
                            .outbound_tx_frames
                            .push(DeviceCommands::list_files_with_end_time(next_page));
                    } else {
                        self.finalize_staged_catalog(now_epoch_sec, &mut outcome);
                    }
                }
                (0x1A, 0x05) => {
                    if let Some(ep) = WifiEndpoint::parse_config_response(&pkt.raw) {
                        self.wifi_endpoint = Some(ep);
                        outcome.transfer_updated = true;
                    }
                }
                (0x1A, 0x06) => {
                    if pkt.payload.len() >= 4 {
                        let fid = read_u32_le(&pkt.payload, 0);
                        let state = if pkt.payload.len() == 5 && pkt.payload[4] <= 2 {
                            pkt.payload[4]
                        } else if fid > 0 {
                            1
                        } else {
                            0
                        };
                        if state == 1 {
                            self.device_recording_active = true;
                            if fid > 0 {
                                let base_slices = self.known_base_slices_for(fid);
                                if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                                    fid,
                                    base_slices,
                                    now_epoch_sec,
                                ) {
                                    outcome.outbound_tx_frames.push(tx);
                                    outcome.transfer_updated = true;
                                }
                            } else if let Some(active_fid) = self
                                .active_file_id
                                .filter(|&id| id > 0 && self.active_is_realtime)
                            {
                                let base_slices = self.known_base_slices_for(active_fid);
                                if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                                    active_fid,
                                    base_slices,
                                    now_epoch_sec,
                                ) {
                                    outcome.outbound_tx_frames.push(tx);
                                    outcome.transfer_updated = true;
                                }
                            } else {
                                self.pending_realtime_subscribe = true;
                                if self.is_catalog_loading() {
                                    if !self.catalog_started_for_subscribe {
                                        self.catalog_refresh_queued = true;
                                    }
                                } else {
                                    self.catalog_started_for_subscribe = true;
                                    let tx = self.request_full_catalog();
                                    if !tx.is_empty() {
                                        outcome.outbound_tx_frames.push(tx);
                                    }
                                }
                                outcome.transfer_updated = true;
                            }
                        } else if state == 0 || state == 2 {
                            self.device_recording_active = false;
                            outcome.recording_stopped = true;
                            self.pending_realtime_subscribe = false;
                            if self.active_is_realtime {
                                if let Some(active_fid) =
                                    self.active_file_id.or_else(|| (fid > 0).then_some(fid))
                                {
                                    self.runtime_state = TransferRuntimeState::StreamingRealtime {
                                        file_id: active_fid,
                                        quiet_drain_elapsed_ms: Some(0),
                                    };
                                    self.transfer.quiet_draining = true;
                                }
                            }
                            if state == 0 {
                                if self.is_catalog_loading() {
                                    self.catalog_refresh_queued = true;
                                } else {
                                    outcome
                                        .outbound_tx_frames
                                        .push(DeviceCommands::list_files_with_end_time(0));
                                }
                            }
                            outcome.transfer_updated = true;
                        }
                        if state <= 2 {
                            self.push_companion_signal(RawCompanionSignal::RecordingStateChanged {
                                state,
                                file_id: (fid > 0)
                                    .then_some(fid)
                                    .or_else(|| self.active_file_id.filter(|&id| id > 0)),
                            });
                        }
                    } else if pkt.payload.len() == 1 {
                        let state = pkt.payload[0];
                        if state == 1 {
                            self.device_recording_active = true;
                            if let Some(fid) = self
                                .active_file_id
                                .filter(|&id| id > 0 && self.active_is_realtime)
                            {
                                if let Some(tx) =
                                    self.enter_or_resume_realtime_stream(fid, now_epoch_sec)
                                {
                                    outcome.outbound_tx_frames.push(tx);
                                    outcome.transfer_updated = true;
                                }
                            } else {
                                self.pending_realtime_subscribe = true;
                                outcome.outbound_tx_frames.push(self.request_full_catalog());
                                outcome.transfer_updated = true;
                            }
                        } else if state == 0 || state == 2 {
                            self.device_recording_active = false;
                            outcome.recording_stopped = true;
                            self.pending_realtime_subscribe = false;
                            if self.active_is_realtime {
                                if let Some(fid) = self.active_file_id {
                                    self.runtime_state = TransferRuntimeState::StreamingRealtime {
                                        file_id: fid,
                                        quiet_drain_elapsed_ms: Some(0),
                                    };
                                    self.transfer.quiet_draining = true;
                                }
                            }
                            if state == 0 {
                                outcome.outbound_tx_frames.push(self.request_full_catalog());
                            }
                            outcome.transfer_updated = true;
                        }
                        if state <= 2 {
                            self.push_companion_signal(RawCompanionSignal::RecordingStateChanged {
                                state,
                                file_id: self.active_file_id.filter(|&id| id > 0),
                            });
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
                            self.active_file_id = None;
                            self.active_is_realtime = false;
                            self.active_file_key = None;
                            self.active_nonce = None;
                            self.opus_buffer.clear();
                            self.marks_ms.clear();
                            self.stream_base_slices = 0;
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
                            self.active_file_id = None;
                            self.active_is_realtime = false;
                            self.active_file_key = None;
                            self.active_nonce = None;
                            self.opus_buffer.clear();
                            self.marks_ms.clear();
                            self.stream_base_slices = 0;
                            self.transfer.phase = TransferPhaseTag::Failed;
                            self.transfer.error_code = err;
                            if self.wifi_batch_phase == WifiBatchPhase::Transferring {
                                self.wifi_batch_phase = WifiBatchPhase::Failed;
                            }
                            outcome.transfer_updated = true;
                            continue;
                        }

                        let was_realtime_for_file = self.active_is_realtime
                            && self.active_file_id == Some(head.secret.file_id);
                        let starting_realtime_for_file = self.device_recording_active
                            && (self.active_file_id == Some(head.secret.file_id)
                                || self.pending_realtime_subscribe);
                        let is_offline_pull =
                            matches!(self.transfer.phase, TransferPhaseTag::PullingOffline)
                                || (self.active_file_id.is_some() && !self.active_is_realtime);
                        if is_offline_pull && head.unfinished {
                            self.reset_active_transfer();
                            if self.wifi_batch_phase == WifiBatchPhase::Transferring {
                                self.wifi_skipped_count = self.wifi_skipped_count.saturating_add(1);
                                self.advance_wifi_batch();
                            }
                            outcome.transfer_updated = true;
                            continue;
                        }

                        let is_resuming_same_file = self.active_file_id
                            == Some(head.secret.file_id)
                            && !self.opus_buffer.is_empty();
                        if !is_resuming_same_file
                            && self.active_file_id != Some(head.secret.file_id)
                        {
                            self.stream_base_slices = 0;
                        }
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
                            if self.active_is_realtime
                                && self.active_file_id.is_some()
                                && self.active_file_id != Some(head.secret.file_id)
                                && !self.opus_buffer.is_empty()
                            {
                                if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                                    outcome.finalized = Some(fin);
                                }
                            }
                            self.opus_buffer.clear();
                            self.marks_ms.clear();
                            self.live_pcm16_16khz.clear();
                            if let Some(dec) = self.live_decoder_16k.as_mut() {
                                dec.reset();
                            }
                        }
                        let is_realtime =
                            head.unfinished || was_realtime_for_file || starting_realtime_for_file;
                        if is_realtime && !was_realtime_for_file {
                            if self.catalog_started_for_subscribe {
                                self.catalog_load_phase = CatalogLoadPhase::Idle;
                                self.catalog_started_for_subscribe = false;
                                self.catalog_refresh_queued = false;
                            }
                            self.capture_events.push_back(CaptureEvent::Started {
                                file_id: head.secret.file_id,
                            });
                            if self.active_file_id != Some(head.secret.file_id) {
                                self.push_companion_signal(
                                    RawCompanionSignal::RecordingStateChanged {
                                        state: 1,
                                        file_id: Some(head.secret.file_id),
                                    },
                                );
                            }
                        }
                        self.active_file_id = Some(head.secret.file_id);
                        self.active_file_key = head.file_key;
                        self.active_nonce = if head.file_key.is_some() {
                            Some(head.secret.nonce)
                        } else {
                            None
                        };
                        self.active_is_realtime = is_realtime;
                        let received_wire = if is_realtime {
                            self.total_slice_offset()
                                .saturating_mul(SLICE_RECORD_BYTES as u32)
                        } else {
                            self.received_slice_count()
                                .saturating_mul(SLICE_RECORD_BYTES as u32)
                        };
                        if is_realtime {
                            self.pending_realtime_subscribe = false;
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
                    let Some(fid) = self.active_file_id else {
                        continue;
                    };
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
                    let min_seq = if self.active_is_realtime {
                        self.total_slice_offset()
                    } else {
                        self.received_slice_count()
                    };
                    let (batch, slice_sequences) =
                        TransportSliceProcessor::unpack_frame_with_sequences(
                            &pkt.raw,
                            dec.as_ref(),
                            min_seq,
                        );
                    if batch.slice_count > 0 {
                        self.opus_buffer.extend_from_slice(&batch.opus_bytes);
                        let mut newly_marked_seqs = Vec::new();
                        for seq in batch.marked_sequences {
                            let rel_seq = seq.saturating_sub(if self.active_is_realtime {
                                self.stream_base_slices
                            } else {
                                0
                            });
                            let ms = SliceMark::position_ms(rel_seq);
                            if !self.marks_ms.contains(&ms) {
                                self.marks_ms.push(ms);
                                outcome.new_marks_ms.push(ms);
                                newly_marked_seqs.push(seq);
                            }
                        }
                        self.marks_ms.sort_unstable();
                        if self.live_decoder_16k.is_none() {
                            if let Some(factory) =
                                self.decoder_factory.or_else(default_opus_decoder_factory)
                            {
                                self.live_decoder_16k = factory(ASR_SAMPLE_RATE);
                            }
                        }
                        let start_len = outcome.live_pcm16_16khz.len();
                        let mut companion_batch = Vec::new();
                        for (frame_idx, frame) in batch
                            .opus_bytes
                            .as_chunks::<OPUS_FRAME_BYTES>()
                            .0
                            .iter()
                            .enumerate()
                        {
                            let slice_seq = slice_sequences
                                .get(frame_idx)
                                .copied()
                                .unwrap_or_else(|| min_seq.saturating_add(frame_idx as u32));
                            if self.active_is_realtime && newly_marked_seqs.contains(&slice_seq) {
                                let rel_seq = slice_seq.saturating_sub(self.stream_base_slices);
                                companion_batch.push(RawCompanionSignal::FrontDoubleTap {
                                    file_id: fid,
                                    slice_seq,
                                    offset_ms: SliceMark::position_ms(rel_seq),
                                });
                            }
                            if let Some(live_dec) = self.live_decoder_16k.as_mut() {
                                let frame_start = outcome.live_pcm16_16khz.len();
                                let _ = OpusWave::decode_frame_into(
                                    live_dec.as_mut(),
                                    frame,
                                    &mut outcome.live_pcm16_16khz,
                                );
                                if self.active_is_realtime
                                    && outcome.live_pcm16_16khz.len() > frame_start
                                {
                                    let samples: Vec<i16> = outcome.live_pcm16_16khz[frame_start..]
                                        .as_chunks::<2>()
                                        .0
                                        .iter()
                                        .copied()
                                        .map(i16::from_le_bytes)
                                        .collect();
                                    if !samples.is_empty() {
                                        companion_batch.push(RawCompanionSignal::LivePcm16 {
                                            file_id: fid,
                                            slice_seq,
                                            samples,
                                        });
                                    }
                                }
                            }
                        }
                        for signal in companion_batch {
                            self.push_companion_signal(signal);
                        }
                        if outcome.live_pcm16_16khz.len() > start_len {
                            self.live_pcm16_16khz
                                .extend_from_slice(&outcome.live_pcm16_16khz[start_len..]);
                            if self.active_is_realtime {
                                self.capture_events.push_back(CaptureEvent::Audio {
                                    file_id: fid,
                                    pcm16: outcome.live_pcm16_16khz[start_len..].to_vec(),
                                });
                            }
                        }
                        let new_received = if self.active_is_realtime {
                            self.total_slice_offset()
                                .saturating_mul(SLICE_RECORD_BYTES as u32)
                        } else {
                            self.received_slice_count()
                                .saturating_mul(SLICE_RECORD_BYTES as u32)
                        };
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
                            self.wifi_finalized_count = self.wifi_finalized_count.saturating_add(1);
                            self.advance_wifi_batch();
                        }
                    }
                }
                (0x1A, 0x10) | (0x1B, 0x10) => {
                    let success = pkt.is_success();
                    self.push_companion_signal(RawCompanionSignal::DeleteFileAck { success });
                    let deleted_fid = if pkt.payload.len() >= 4 {
                        read_u32_le(&pkt.payload, 0)
                    } else {
                        0
                    };
                    if success {
                        if deleted_fid > 0 {
                            self.remove_catalog_entry(deleted_fid);
                            outcome.catalog_updated = true;
                        } else if !self.device_recording_active
                            && self.active_file_id.is_none()
                            && !self.is_catalog_loading()
                        {
                            let tx = self.request_full_catalog();
                            if !tx.is_empty() {
                                outcome.outbound_tx_frames.push(tx);
                            }
                            outcome.transfer_updated = true;
                        }
                    }
                }
                _ => {}
            }
        }

        outcome
    }

    /// Seals the buffered part of a realtime stream without stopping its producer.
    /// Subsequent slices retain their absolute transfer sequence and start a new bounded part.
    pub fn checkpoint_realtime_segment(
        &mut self,
        now_epoch_sec: u64,
    ) -> Option<FinalizedRecording> {
        if !self.active_is_realtime || self.opus_buffer.is_empty() {
            return None;
        }
        let file_id = self.active_file_id?;
        let slice_count = self.received_slice_count();
        let duration_ms = u64::from(slice_count) * 20;
        let marks_ms = std::mem::take(&mut self.marks_ms);
        let opus = std::mem::take(&mut self.opus_buffer);
        let ogg_opus_bytes = OggOpus::mux_raw_frames(&opus);
        let preview_wav_bytes = OpusWave::decode_raw_frames_to_wav(
            &opus,
            WAV_SAMPLE_RATE,
            &marks_ms,
            self.decoder_factory,
        )
        .unwrap_or_default();
        let recording = FinalizedRecording {
            entry: RecordingEntry {
                id: file_id,
                bean_file_id: file_id,
                created_at_epoch_sec: now_epoch_sec,
                duration_ms,
                byte_count: ogg_opus_bytes.len() as u32,
                marks_ms,
            },
            ogg_opus_bytes,
            preview_wav_bytes,
            is_realtime: true,
            base_slice_offset: self.stream_base_slices,
        };
        self.stream_base_slices = self.stream_base_slices.saturating_add(slice_count);
        Some(recording)
    }

    /// Finalizes the active Opus stream into an Ogg Opus container and 48 kHz mono
    /// preview WAV with 880 Hz mark chimes, appends it to `finalized_queue` and
    /// `last_finalized`, and resets the active transfer state to `Idle`.
    pub fn finalize_active_transfer(&mut self, now_epoch_sec: u64) -> Option<FinalizedRecording> {
        let fid = self.active_file_id?;
        if self.opus_buffer.is_empty() {
            self.capture_events
                .push_back(CaptureEvent::Finished { file_id: fid });
            self.reset_active_transfer();
            return None;
        }
        let ogg_opus_bytes = OggOpus::mux_raw_frames(&self.opus_buffer);
        let slice_count = (self.opus_buffer.len() / OPUS_FRAME_BYTES) as u64;
        let pcm_duration_ms = slice_count * 20;
        let duration_ms = pcm_duration_ms.max(400);
        let mut marks_ms: Vec<u64> = self
            .marks_ms
            .iter()
            .map(|&m| m.min(pcm_duration_ms))
            .collect();
        marks_ms.sort_unstable();
        marks_ms.dedup();
        let preview_wav_bytes = OpusWave::decode_raw_frames_to_wav(
            &self.opus_buffer,
            WAV_SAMPLE_RATE,
            &marks_ms,
            self.decoder_factory,
        )
        .unwrap_or_default();

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
            is_realtime: self.active_is_realtime,
            base_slice_offset: self.stream_base_slices,
        };
        self.finalized_queue.push_back(finalized.clone());
        self.capture_events
            .push_back(CaptureEvent::Finished { file_id: fid });
        self.last_finalized = Some(finalized.clone());
        let retained_live_pcm = std::mem::take(&mut self.live_pcm16_16khz);
        self.reset_active_transfer();
        self.live_pcm16_16khz = retained_live_pcm;
        Some(finalized)
    }

    /// Runs a deterministic closed-loop `01/01` telemetry, `1A/07` encrypted file head,
    /// 60-slice `1A/08` stream (with double-tap marks at sequence 15 and 45), and
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
            let flags = if seq == 15 || seq == 45 {
                0x01u8
            } else {
                0x00u8
            };
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
                let sample = self
                    .frames_seen
                    .saturating_mul(10)
                    .saturating_add((i % 64) as i16);
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
        assert_eq!(session.connection_phase, ConnectionPhaseTag::Connected);
        assert_eq!(session.telemetry.as_ref().unwrap().battery, Some(90));
        assert_eq!(fin.entry.id, 20_261_107);
        assert_eq!(fin.entry.duration_ms, 1200);
        assert_eq!(fin.entry.marks_ms, vec![300, 900]);
        assert!(fin.ogg_opus_bytes.starts_with(b"OggS"));
        assert!(fin.preview_wav_bytes.is_empty());
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
        let fin = fin_step
            .finalized
            .expect("offline pull must finalize on 1A/0A");
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
        assert_eq!(
            stop_out.outbound_tx_frames,
            vec![DeviceCommands::pause_record()]
        );
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
        let fin = t3
            .finalized
            .expect("2,000 ms quiet drain after late slice must finalize");
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

        let wifi_cfg =
            TransportSession::build_rx_frame(0x1A, 0x05, &[0x01, 0x2B, 0xA8, 0xC0, 0x02, 0x7D]);
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

    fn build_telemetry_frame_with_recording_status(recording_status: u8) -> Vec<u8> {
        let mut payload = Vec::with_capacity(56);
        payload.push(1);
        payload.push(8);
        payload.push(0);
        payload.extend_from_slice(b"1.4.8");
        payload.extend_from_slice(b"D3200NATIVE639D0");
        payload.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
        payload.extend_from_slice(&(58u32 * 1024 * 1024).to_le_bytes());
        payload.push(0);
        payload.extend_from_slice(b"2.1.0");
        payload.push(9);
        payload.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
        payload.extend_from_slice(&[0u8; 5]);
        payload.push(recording_status);
        payload.extend_from_slice(b"1.0.0");
        TransportSession::build_rx_frame(0x01, 0x01, &payload)
    }

    #[test]
    fn telemetry_recording_active_auto_subscribes_latest_catalog_file_on_1b_0e() {
        let mut session = TransportSession::new();
        let tel = build_telemetry_frame_with_recording_status(1);
        let tel_out = session.ingest_ble_chunk(&tel, 1_700_000_700);
        assert!(tel_out.telemetry_updated);
        assert_eq!(
            session.telemetry.as_ref().map(|t| t.recording_status),
            Some(1)
        );
        assert_eq!(
            tel_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );

        let mut list_payload = Vec::new();
        list_payload.extend_from_slice(&2u16.to_le_bytes());
        list_payload.extend_from_slice(&1000u32.to_le_bytes());
        list_payload.extend_from_slice(&1010u32.to_le_bytes());
        list_payload.extend_from_slice(&10_000u32.to_le_bytes());
        list_payload.extend_from_slice(&2050u32.to_le_bytes());
        list_payload.extend_from_slice(&0u32.to_le_bytes());
        list_payload.extend_from_slice(&4_000u32.to_le_bytes());
        let list_rx = TransportSession::build_rx_frame(0x1B, 0x0E, &list_payload);

        let cat_out = session.ingest_ble_chunk(&list_rx, 1_700_000_701);
        assert!(cat_out.catalog_updated);
        assert_eq!(
            cat_out.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(2050, 0, 1)]
        );
        assert_eq!(session.active_file_id, Some(2050));
        assert!(session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::StreamingRealtime);
    }

    #[test]
    fn record_status_1a_06_starts_realtime_transport_for_5byte_and_4byte_payloads() {
        let mut session = TransportSession::new();
        let mut payload_5b = Vec::with_capacity(5);
        payload_5b.extend_from_slice(&3001u32.to_le_bytes());
        payload_5b.push(1);
        let rx_5b = TransportSession::build_rx_frame(0x1A, 0x06, &payload_5b);

        let out_5b = session.ingest_ble_chunk(&rx_5b, 1_700_000_710);
        assert!(out_5b.transfer_updated);
        assert_eq!(
            out_5b.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(3001, 0, 1)]
        );
        assert_eq!(session.active_file_id, Some(3001));
        assert!(session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::StreamingRealtime);

        let mut session_4b = TransportSession::new();
        let rx_4b = TransportSession::build_rx_frame(0x1A, 0x06, &3002u32.to_le_bytes());
        let out_4b = session_4b.ingest_ble_chunk(&rx_4b, 1_700_000_711);
        assert!(out_4b.transfer_updated);
        assert_eq!(
            out_4b.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(3002, 0, 1)]
        );
        assert_eq!(session_4b.active_file_id, Some(3002));
        assert!(session_4b.active_is_realtime);
        assert_eq!(
            session_4b.transfer.phase,
            TransferPhaseTag::StreamingRealtime
        );
    }

    #[test]
    fn realtime_1a_07_head_for_same_file_preserves_buffered_slices_marks_and_live_pcm() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x21u8; 32];
        let fk = [0x22u8; 32];
        let fn_iv = [0x23u8; 16];
        session.set_session_key(sk);

        let head = build_test_head_frame(&sk, 4001, u32::MAX, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_720);
        let slices = build_test_slice_frame(&fk, &fn_iv, &[(0, 0x00), (1, 0x01)]);
        let _ = session.ingest_ble_chunk(&slices, 1_700_000_721);
        assert_eq!(session.received_slice_count(), 2);
        assert_eq!(session.marks_ms, vec![20]);
        assert_eq!(session.live_pcm16_16khz.len(), 2 * 320 * 2);

        let repeated_head = build_test_head_frame(&sk, 4001, u32::MAX, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&repeated_head, 1_700_000_722);
        assert_eq!(session.received_slice_count(), 2);
        assert_eq!(session.marks_ms, vec![20]);
        assert_eq!(session.live_pcm16_16khz.len(), 2 * 320 * 2);
        assert_eq!(session.transfer.received_wire_bytes, 2 * 166);
    }

    #[test]
    fn start_realtime_recording_queues_81_82_and_subscribes_known_or_pending_file() {
        let mut session = TransportSession::new();
        let out_pending = session.start_realtime_recording(None, 1_700_000_800_000);
        assert!(session.device_recording_active);
        assert!(session.pending_realtime_subscribe);
        assert_eq!(
            out_pending.outbound_tx_frames,
            vec![
                DeviceCommands::start_realtime_record_81(),
                DeviceCommands::start_app_recording(),
                DeviceCommands::list_files_with_end_time(0),
            ]
        );

        let mut session_known = TransportSession::new();
        let out_known = session_known.start_realtime_recording(Some(8801), 1_700_000_800_000);
        assert!(session_known.device_recording_active);
        assert!(!session_known.pending_realtime_subscribe);
        assert_eq!(session_known.active_file_id, Some(8801));
        assert!(session_known.active_is_realtime);
        assert_eq!(
            out_known.outbound_tx_frames,
            vec![
                DeviceCommands::start_realtime_record_81(),
                DeviceCommands::start_app_recording(),
                DeviceCommands::start_transport_audio_file(8801, 0, 1),
            ]
        );
    }

    #[test]
    fn repro_1a_06_stop_while_pending_realtime_subscribe_leaves_session_recording_active() {
        let mut session = TransportSession::new();
        let rx_start = TransportSession::build_rx_frame(0x1A, 0x06, &[0x01]);
        let _ = session.ingest_ble_chunk(&rx_start, 1_700_000_900);
        assert!(session.device_recording_active);
        assert!(session.pending_realtime_subscribe);
        assert!(!session.active_is_realtime);

        let rx_stop = TransportSession::build_rx_frame(0x1A, 0x06, &[0x00]);
        let _ = session.ingest_ble_chunk(&rx_stop, 1_700_000_901);

        assert!(
            !session.device_recording_active,
            "1A/06 stop (state=0) failed to clear device_recording_active because active_is_realtime was false"
        );
        assert!(
            !session.pending_realtime_subscribe,
            "1A/06 stop (state=0) failed to clear pending_realtime_subscribe because active_is_realtime was false"
        );
    }

    #[test]
    fn repro_1a_06_start_during_offline_pull_hijacks_offline_file_id_for_realtime() {
        let mut session = TransportSession::new();
        let _ = session.begin_offline_pull(5001, 10_000);
        assert_eq!(session.active_file_id, Some(5001));
        assert!(!session.active_is_realtime);

        let rx_start = TransportSession::build_rx_frame(0x1A, 0x06, &[0x01]);
        let outcome = session.ingest_ble_chunk(&rx_start, 1_700_000_910);

        assert_ne!(
            outcome.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(5001, 0, 1)],
            "1A/06 start erroneously hijacked active offline file_id 5001 for realtime stream instead of querying catalog"
        );
        assert_eq!(
            outcome.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );
    }

    #[test]
    fn omi_pendant_custody_blocks_hardware_file_deletion_until_disk_fsync_receipt() {
        let mut session = TransportSession::new();
        assert!(!session.has_disk_custody(20_261_109));
        assert!(session.request_reclaim_bean_file(20_261_109).is_err());

        assert!(!session.confirm_disk_custody(CustodyReceipt {
            file_id: 20_261_109,
            byte_count: 0,
            sha256_hex: "a".repeat(64),
            fsynced_at_epoch_sec: 1_775_000_000,
        }));
        assert!(!session.confirm_disk_custody(CustodyReceipt {
            file_id: 20_261_109,
            byte_count: 9818,
            sha256_hex: "not-a-sha".to_string(),
            fsynced_at_epoch_sec: 1_775_000_000,
        }));

        assert!(session.confirm_disk_custody(CustodyReceipt {
            file_id: 20_261_109,
            byte_count: 9818,
            sha256_hex:
                "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855".to_string(),
            fsynced_at_epoch_sec: 1_775_000_000,
        }));
        assert!(session.has_disk_custody(20_261_109));
        let delete_cmd = session
            .request_reclaim_bean_file(20_261_109)
            .expect("custody verified must permit 0x1A/0x10 delete command");
        assert_eq!(delete_cmd, DeviceCommands::delete_file(20_261_109));
    }

    #[test]
    fn realtime_lifecycle_emits_started_finished_preserves_stream_on_head_and_refreshes_catalog_on_stop()
     {
        let mut session = TransportSession::new();
        let sk = [0x51u8; 32];
        let fk = [0x52u8; 32];
        let fn_iv = [0x53u8; 16];
        session.set_session_key(sk);

        let start_rx = TransportSession::build_rx_frame(0x1A, 0x06, &7001u32.to_le_bytes());
        let _ = session.ingest_ble_chunk(&start_rx, 1_700_001_000);
        assert_eq!(
            Vec::from(session.take_capture_events()),
            vec![CaptureEvent::Started { file_id: 7001 }]
        );

        let head_finite = build_test_head_frame(&sk, 7001, 10 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head_finite, 1_700_001_001);
        assert!(session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::StreamingRealtime);
        assert!(session.take_capture_events().is_empty());

        let stop_rx = TransportSession::build_rx_frame(0x18, 0x82, &[0x00]);
        let stop_out = session.ingest_ble_chunk(&stop_rx, 1_700_001_002);
        assert!(stop_out.transfer_updated);
        assert_eq!(
            stop_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );
        assert!(session.is_realtime_quiet_draining());

        let drain_out = session.poll_timers(REALTIME_QUIET_DRAIN_MS, 1_700_001_004);
        assert!(drain_out.transfer_updated);
        assert_eq!(
            drain_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(0)]
        );
        assert_eq!(
            Vec::from(session.take_capture_events()),
            vec![CaptureEvent::Finished { file_id: 7001 }]
        );
    }

    #[test]
    fn companion_signals_emit_recording_states_and_double_tap_before_slice_pcm() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x61u8; 32];
        let fk = [0x62u8; 32];
        let fn_iv = [0x63u8; 16];
        session.set_session_key(sk);

        let _ = session.start_realtime_recording(Some(8801), 1_775_000_000_000);
        assert_eq!(
            session.take_companion_signals(),
            vec![RawCompanionSignal::RecordingStateChanged {
                state: 1,
                file_id: Some(8801),
            }]
        );

        let head = build_test_head_frame(&sk, 8801, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_775_000_000);

        let dec = AesCtrStreamDecrypt::new(&fk, &fn_iv).unwrap();
        let mut payload = Vec::with_capacity(3 * SLICE_RECORD_BYTES);
        for seq in 0..3u32 {
            payload.extend_from_slice(&seq.to_le_bytes());
            payload.push(if seq == 1 { 0x01 } else { 0x00 });
            let mut opus = [0u8; OPUS_FRAME_BYTES];
            opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            dec.decrypt_contiguous_in_place(&mut opus, seq);
            payload.extend_from_slice(&opus);
            payload.push(0);
        }
        let slices_rx = TransportSession::build_rx_frame(0x1A, 0x08, &payload);
        let outcome = session.ingest_ble_chunk(&slices_rx, 1_775_000_001);
        assert_eq!(outcome.new_marks_ms, vec![20]);
        assert_eq!(outcome.live_pcm16_16khz.len(), 3 * 320 * 2);

        let signals = session.take_companion_signals();
        assert_eq!(signals.len(), 4);
        assert!(matches!(
            &signals[0],
            RawCompanionSignal::LivePcm16 { file_id: 8801, slice_seq: 0, samples } if samples.len() == 320
        ));
        assert_eq!(
            signals[1],
            RawCompanionSignal::FrontDoubleTap {
                file_id: 8801,
                slice_seq: 1,
                offset_ms: 20,
            }
        );
        assert!(matches!(
            &signals[2],
            RawCompanionSignal::LivePcm16 { file_id: 8801, slice_seq: 1, samples } if samples.len() == 320
        ));
        assert!(matches!(
            &signals[3],
            RawCompanionSignal::LivePcm16 { file_id: 8801, slice_seq: 2, samples } if samples.len() == 320
        ));

        let _ = session.stop_realtime_recording();
        assert_eq!(
            session.take_companion_signals(),
            vec![RawCompanionSignal::RecordingStateChanged {
                state: 2,
                file_id: Some(8801),
            }]
        );

        let rx_state_zero = TransportSession::build_rx_frame(0x18, 0x82, &[0x00]);
        let _ = session.ingest_ble_chunk(&rx_state_zero, 1_775_000_002);
        session.on_disconnected();
        assert!(session.take_companion_signals().is_empty());

        let _ = session.begin_offline_pull(8802, 1_000);
        let offline_head = build_test_head_frame(&sk, 8802, 3 * 166, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&offline_head, 1_775_000_003);
        let _ = session.ingest_ble_chunk(&slices_rx, 1_775_000_004);
        assert!(session.take_companion_signals().is_empty());
    }

    #[test]
    fn realtime_transfer_clamps_out_of_range_marks_to_duration() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x71u8; 32];
        let fk = [0x72u8; 32];
        let fn_iv = [0x73u8; 16];
        session.set_session_key(sk);

        let _ = session.start_realtime_recording(Some(9901), 1_775_000_000_000);
        let head = build_test_head_frame(&sk, 9901, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_775_000_000);

        let dec = AesCtrStreamDecrypt::new(&fk, &fn_iv).unwrap();
        let mut payload = Vec::with_capacity(3 * SLICE_RECORD_BYTES);
        for i in 0..3u32 {
            let seq = if i == 2 { 50 } else { i };
            payload.extend_from_slice(&seq.to_le_bytes());
            payload.push(if i == 2 { 0x01 } else { 0x00 });
            let mut opus = [0u8; OPUS_FRAME_BYTES];
            opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            dec.decrypt_contiguous_in_place(&mut opus, seq);
            payload.extend_from_slice(&opus);
            payload.push(0);
        }
        let slices_rx = TransportSession::build_rx_frame(0x1A, 0x08, &payload);
        let outcome = session.ingest_ble_chunk(&slices_rx, 1_775_000_001);
        assert_eq!(outcome.new_marks_ms, vec![1000]);

        let finalized = session
            .finalize_active_transfer(1_775_000_002)
            .expect("must produce finalized recording");
        assert_eq!(finalized.entry.duration_ms, 400);
        assert_eq!(finalized.entry.marks_ms, vec![60]);
    }

    fn build_1b0e_page(count: u16, files: &[(u32, u32, Option<u32>)]) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&count.to_le_bytes());
        for &(fid, dur, et) in files {
            payload.extend_from_slice(&fid.to_le_bytes());
            payload.extend_from_slice(&et.unwrap_or(0).to_le_bytes());
            payload.extend_from_slice(&dur.to_le_bytes());
        }
        TransportSession::build_rx_frame(0x1B, 0x0E, &payload)
    }

    #[test]
    fn multipage_catalog_pagination_selects_new_open_file_on_second_page() {
        let mut session = TransportSession::new();
        let sk = [0x41u8; 32];
        session.set_session_key(sk);

        let initial_files: Vec<(u32, u32, Option<u32>)> = (101..=110)
            .map(|id| {
                if id == 105 {
                    (id, 0, Some(0))
                } else {
                    (id, 2_000, Some(1_700_000_000 + id))
                }
            })
            .collect();

        let initial_page = build_1b0e_page(10, &initial_files);
        let _ = session.ingest_ble_chunk(&initial_page, 1_700_000_100);
        let initial_end = build_1b0e_page(0, &[]);
        let _ = session.ingest_ble_chunk(&initial_end, 1_700_000_100);
        assert_eq!(session.raw_catalog.len(), 10);

        let start_out = session.start_realtime_recording(None, 1_700_000_100_000);
        assert!(
            start_out
                .outbound_tx_frames
                .iter()
                .any(|f| f.len() >= 7 && f[5] == 0x18 && f[6] == 0x81)
        );
        assert!(
            start_out
                .outbound_tx_frames
                .iter()
                .any(|f| f.len() >= 7 && f[5] == 0x1B && f[6] == 0x0E)
        );

        let page0_files = initial_files.clone();
        let page0_rx = build_1b0e_page(10, &page0_files);
        let p0_out = session.ingest_ble_chunk(&page0_rx, 1_700_000_101);
        assert!(session.is_catalog_loading());
        assert_eq!(
            session.catalog_load_phase,
            CatalogLoadPhase::Paginating { next_page: 2 }
        );
        assert_eq!(
            p0_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(1)]
        );
        assert_eq!(session.active_file_id, None);

        let page1_files = vec![(111, 0, Some(0))];
        let page1_rx = build_1b0e_page(1, &page1_files);
        let p1_out = session.ingest_ble_chunk(&page1_rx, 1_700_000_102);
        assert!(!session.is_catalog_loading());
        assert_eq!(session.active_file_id, Some(111));
        assert_eq!(session.stream_base_slices, 0);
        assert_eq!(
            p1_out.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(111, 0, 1)]
        );
    }

    #[test]
    fn resumed_open_file_computes_slice_offset_and_relative_marks() {
        let mut session = TransportSession::with_decoder_factory(Some(test_decoder_factory));
        let sk = [0x51u8; 32];
        let fk = [0x52u8; 32];
        let fn_iv = [0x53u8; 16];
        session.set_session_key(sk);

        let files = vec![(201, 1_000, Some(0))];
        let initial_page = build_1b0e_page(1, &files);
        let _ = session.ingest_ble_chunk(&initial_page, 1_700_000_200);

        let _ = session.start_realtime_recording_with_options(None, 1_700_000_200_000, true);
        let resume_page = build_1b0e_page(1, &files);
        let resume_out = session.ingest_ble_chunk(&resume_page, 1_700_000_201);

        assert_eq!(session.active_file_id, Some(201));
        assert_eq!(session.stream_base_slices, 50);
        let expected_wire_offset = 50 * SLICE_RECORD_BYTES as u32;
        assert_eq!(
            resume_out.outbound_tx_frames,
            vec![DeviceCommands::start_transport_audio_file(
                201,
                expected_wire_offset,
                1
            )]
        );

        let head = build_test_head_frame(&sk, 201, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let _ = session.ingest_ble_chunk(&head, 1_700_000_202);

        let dec = AesCtrStreamDecrypt::new(&fk, &fn_iv).unwrap();
        let mut slice_payload = Vec::with_capacity(SLICE_RECORD_BYTES);
        let seq = 51u32;
        slice_payload.extend_from_slice(&seq.to_le_bytes());
        slice_payload.push(0x01);
        let mut opus = [0u8; OPUS_FRAME_BYTES];
        opus[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        dec.decrypt_contiguous_in_place(&mut opus, seq);
        slice_payload.extend_from_slice(&opus);
        slice_payload.push(0);

        let slice_rx = TransportSession::build_rx_frame(0x1A, 0x08, &slice_payload);
        let outcome = session.ingest_ble_chunk(&slice_rx, 1_700_000_203);
        assert_eq!(outcome.new_marks_ms, vec![20]);
        assert_eq!(session.marks_ms, vec![20]);

        let companion_signals = session.take_companion_signals();
        assert!(companion_signals.iter().any(|s| matches!(
            s,
            RawCompanionSignal::FrontDoubleTap {
                file_id: 201,
                slice_seq: 51,
                offset_ms: 20,
            }
        )));
    }

    #[test]
    fn offline_pull_error_code_clears_active_file_id_and_sets_failed_phase() {
        let mut session = TransportSession::new();
        let sk = [0x61u8; 32];
        let fk = [0x62u8; 32];
        let fn_iv = [0x63u8; 16];
        session.set_session_key(sk);

        let _ = session.begin_offline_pull(301, 2_000);
        assert_eq!(session.active_file_id, Some(301));
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);

        let err_head = build_test_head_frame_with_err(&sk, 301, 2_000, &fk, &fn_iv, 1);

        let outcome = session.ingest_ble_chunk(&err_head, 1_700_000_300);
        assert!(outcome.transfer_updated);
        assert_eq!(session.active_file_id, None);
        assert!(!session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Failed);
        assert_eq!(session.transfer.file_id, 301);
        assert_eq!(session.transfer.error_code, 1);
    }

    #[test]
    fn offline_pull_unfinished_head_aborts_to_idle_without_flipping_to_realtime() {
        let mut session = TransportSession::new();
        let sk = [0x71u8; 32];
        let fk = [0x72u8; 32];
        let fn_iv = [0x73u8; 16];
        session.set_session_key(sk);

        let _ = session.begin_offline_pull(401, 2_000);
        assert_eq!(session.active_file_id, Some(401));
        assert_eq!(session.transfer.phase, TransferPhaseTag::PullingOffline);

        let head = build_test_head_frame(&sk, 401, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let outcome = session.ingest_ble_chunk(&head, 1_700_000_400);

        assert!(outcome.transfer_updated);
        assert_eq!(session.active_file_id, None);
        assert!(!session.active_is_realtime);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Idle);
    }

    fn build_1b0e_page_with_tail(
        count: u16,
        files: &[(u32, u32, Option<u32>)],
        transport_timestamp: Option<u32>,
        transport_duration: Option<u32>,
    ) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&count.to_le_bytes());
        for &(fid, dur, et) in files {
            payload.extend_from_slice(&fid.to_le_bytes());
            payload.extend_from_slice(&et.unwrap_or(0).to_le_bytes());
            payload.extend_from_slice(&dur.to_le_bytes());
        }
        if let (Some(ts), Some(dur)) = (transport_timestamp, transport_duration) {
            payload.extend_from_slice(&ts.to_le_bytes());
            payload.extend_from_slice(&dur.to_le_bytes());
        }
        TransportSession::build_rx_frame(0x1B, 0x0E, &payload)
    }

    #[test]
    fn duplicate_page0_and_1882_ack_do_not_abort_multi_page_pagination() {
        let mut session = TransportSession::new();
        let sk = [0x42u8; 32];
        session.set_session_key(sk);

        let page0_files: Vec<(u32, u32, Option<u32>)> = (1001..=1010)
            .map(|id| (id, 60_000, Some(1_700_000_000 + id)))
            .collect();

        let start_out = session.start_realtime_recording(None, 1_700_000_100_000);
        assert!(
            start_out
                .outbound_tx_frames
                .iter()
                .any(|f| f.len() >= 7 && f[5] == 0x1B && f[6] == 0x0E)
        );
        assert!(session.is_catalog_loading());

        let page0_rx = build_1b0e_page_with_tail(10, &page0_files, Some(1793860020), Some(60_000));
        let p0_out = session.ingest_ble_chunk(&page0_rx, 1_700_000_101);
        assert_eq!(
            p0_out.outbound_tx_frames,
            vec![DeviceCommands::list_files_with_end_time(1)]
        );
        assert!(session.is_catalog_loading());

        let ack_rx = TransportSession::build_rx_frame(0x18, 0x82, &[0x01]);
        let _ = session.ingest_ble_chunk(&ack_rx, 1_700_000_102);
        assert!(session.is_catalog_loading());

        let _ = session.ingest_ble_chunk(&page0_rx, 1_700_000_103);
        assert!(session.is_catalog_loading());

        let page1_files = vec![(1794015297, 9_480, Some(0))];
        let page1_rx = build_1b0e_page_with_tail(1, &page1_files, Some(1794015297), Some(9_480));
        let p1_out = session.ingest_ble_chunk(&page1_rx, 1_700_000_104);

        assert!(!session.is_catalog_loading());
        assert!(session.has_complete_catalog());
        assert_eq!(session.raw_catalog.len(), 11);
        assert_eq!(session.active_file_id, Some(1794015297));
        assert!(
            p1_out
                .outbound_tx_frames
                .iter()
                .any(|f| f == &DeviceCommands::start_transport_audio_file(1794015297, 0, 1))
        );
    }

    #[test]
    fn wifi_batch_skips_unfinished_253_and_advances() {
        let mut session = TransportSession::new();
        let sk = [0x81u8; 32];
        let fk = [0x82u8; 32];
        let fn_iv = [0x83u8; 16];
        session.set_session_key(sk);

        session.begin_wifi_batch(&[9001, 9002]);
        assert_eq!(session.wifi_batch_phase, WifiBatchPhase::Transferring);
        assert_eq!(session.active_file_id, Some(9001));

        let unfinished_head = build_test_head_frame(&sk, 9001, UNFINISHED_FILE_SIZE, &fk, &fn_iv);
        let outcome = session.ingest_ble_chunk(&unfinished_head, 1_700_000_500);

        assert!(outcome.transfer_updated);
        assert_eq!(session.wifi_skipped_count, 1);
        assert_eq!(session.wifi_current_index, 1);
        assert_eq!(session.active_file_id, Some(9002));
        assert_eq!(session.wifi_batch_phase, WifiBatchPhase::Transferring);
    }

    #[test]
    fn orphan_slice_without_active_file_id_is_ignored_and_never_creates_phantom_file() {
        let mut session = TransportSession::new();
        let sk = [0x42u8; 32];
        session.set_session_key(sk);

        assert_eq!(session.active_file_id, None);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Idle);

        let mut slice_payload = Vec::new();
        slice_payload.extend_from_slice(&0u32.to_le_bytes());
        slice_payload.push(0);
        slice_payload.extend_from_slice(&[0xAA; 160]);
        slice_payload.push(0);
        let slice_rx = TransportSession::build_rx_frame(0x1A, 0x08, &slice_payload);

        let outcome = session.ingest_ble_chunk(&slice_rx, 1_700_000_100);
        assert!(!outcome.transfer_updated);
        assert_eq!(session.active_file_id, None);
        assert_eq!(session.transfer.phase, TransferPhaseTag::Idle);
        assert_eq!(session.transfer.received_wire_bytes, 0);
        assert!(session.opus_buffer.is_empty());
    }
}
