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

/// Synthetic error code when an encrypted file has no validated decryption context.
pub const TRANSFER_ERR_FILE_DECRYPTION: u8 = 0xFD;

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
    /// A stream transfer ended, indicating whether a finalized artifact entered the queue.
    Finished {
        /// Device file identity at finalization time.
        file_id: u32,
        /// Whether non-empty audio was pushed to `finalized_queue`.
        saved: bool,
    },
}

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

#[derive(Clone, Copy)]
pub(in crate::session) enum FileDecryption {
    AwaitingKey,
    Ready { key: [u8; 32], nonce: [u8; 16] },
}
