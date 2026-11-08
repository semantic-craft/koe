//! Desktop host bridge connecting `koe_core` (`koe_protocol_kernel`) to the
//! GPUI desktop application, atomic `.opus`/`.wav` disk export, and local
//! recording library state machine.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::collections::VecDeque;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

pub use koe_protocol_kernel::cicada::{
    pending_translation_segments, CicadaEvent, CicadaOutcome, CicadaReducer, CicadaState,
    LiveCaptionsQueue, RollingMinutesScheduler, CICADA_MAX_CALLS_PER_HOUR,
    CICADA_ROLLING_CHAR_THRESHOLD, CICADA_ROLLING_INTERVAL_SEC, CICADA_SILENCE_AUTO_STOP_MS,
};
pub use koe_protocol_kernel::commands::DeviceCommands;
pub use koe_protocol_kernel::context::{
    filter_open_mine_todos, sort_context_timeline, ContextEvent, ContextOutcome, ContextReducer,
    ContextSearchIndex, ContextState, ScoringMode,
};
pub use koe_protocol_kernel::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
pub use koe_protocol_kernel::domain::{
    AiProviderCommand, ContextItem, ContextKind, ContextSource, EditorialCardRole, KoePackSummary,
    MeetingMinutesV2, MinuteCause, MinuteCustomSection, MinuteFishbone, MinutePoint, MinuteTerm,
    MinuteTermAdoption, MinuteTopic, RecordingAggregate, RecordingLifecyclePhase, SegmentId,
    SummaryFormat, TodoItem, TodoKind, TodoStatus, UtteranceSegment, UtteranceSpine,
    VisualSummaryCard,
};
pub use koe_protocol_kernel::frame::{FrameReassembler, ProtocolFrame};
pub use koe_protocol_kernel::library::{RecordingEntry, RecordingLibrary};
pub use koe_protocol_kernel::mcp_acp::{
    compute_pack_sync_delta, constant_time_eq, format_epoch_sec_iso8601, is_supported_mcp_tool,
    AcpAgentCard, AcpTaskPhase, AcpTaskRecord, LiveLeaseValidator, LivePublicationLease,
    McpAcpEvent, McpAcpOutcome, McpAcpOwnedRuntime, McpAcpReducer, McpAcpState,
    McpAcpWorkspaceView, McpPairingMode, McpToolError, PackSyncDelta, PairingTicket,
    QwennoteCatalog, SyncPackSummary, ACP_PROTOCOL_VERSION, KOE_ACP_METHODS, KOE_MCP_TOOLS,
    LIVE_LEASE_DEFAULT_TTL_SEC, LIVE_LEASE_MAX_REMAINING_SEC, MAX_ACP_TASK_LOGS,
    MAX_JSONRPC_REQUEST_BYTES, MAX_JSONRPC_RESPONSE_BYTES, MCP_PROTOCOL_VERSION,
    PAIRING_TICKET_PREFIX,
};
pub use koe_protocol_kernel::minutes::{
    contains_calculation_phrase, contains_percentage, encode_qwen_stream_finish_task_json,
    encode_qwen_stream_run_task_json, validate_calculation_grounding, validate_minutes_grounding,
    JsonValue, MinutesEvent, MinutesOutcome, MinutesReducer, MinutesState, MinutesValidationError,
    QwenStreamAccumulator, QwenStreamStep, BUILTIN_MINUTE_TEMPLATES, QWEN_STREAMING_DEFAULT_MODEL,
};
pub use koe_protocol_kernel::models::{DeviceInfoModel, OfflineFileEntry, OfflineFileList};
pub use koe_protocol_kernel::ogg_opus::OggOpus;
pub use koe_protocol_kernel::session::{
    ConnectionPhaseTag, FinalizedRecording, SessionIngestOutcome, TransferPhaseTag,
    TransferProgress, TransportSession,
};
pub use koe_protocol_kernel::slice_marks::SliceMark;
pub use koe_protocol_kernel::transport::TransportSliceProcessor;
pub use koe_protocol_kernel::wav::{OpusDecoderFactory, OpusStreamDecoder, OpusWave};
pub use koe_protocol_kernel::wifi::{
    normalize_wifi_chunk, WifiBatchPhase, WifiBatchProgress, WifiEndpoint, WIFI_DEFAULT_WS_PORT,
    WIFI_KEEPALIVE_INTERVAL_MS, WIFI_KEEPALIVE_PAYLOAD, WIFI_UDP_PORT, WIFI_WS_FINISH_TEXT,
};
pub use koe_protocol_kernel::{
    cicada, commands, context, crypto, domain, frame, hash, library, mcp_acp, minutes, models,
    ogg_opus, prng, session, slice_marks, transport, wav, wifi,
};

/// Default speech window size in bytes (`3,200` bytes = 100 ms of 16 kHz mono PCM16 LE across 5 slices).
pub const ASR_SPEECH_WINDOW_PCM_BYTES: usize = 3_200;

/// Default RMS energy threshold above which a 16 kHz PCM16 frame is treated as active speech.
pub const ASR_DEFAULT_RMS_THRESHOLD: u16 = 120;

/// Diagnostic status of a single stage in the 5-stage [`PipelineDoctorSnapshot`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum PipelineDoctorStageStatus {
    /// Stage has not started yet.
    #[default]
    Idle,
    /// Stage handshake or subscription is in progress.
    Pending,
    /// Stage is actively running and processing frames.
    Active,
    /// Stage has verified end-to-end data flow.
    Healthy,
    /// Stage encountered an error or timeout.
    Error,
}

impl PipelineDoctorStageStatus {
    /// Returns `true` when the stage is [`Self::Active`] or [`Self::Healthy`].
    #[must_use]
    pub const fn is_ready(self) -> bool {
        matches!(self, Self::Active | Self::Healthy)
    }

    /// Returns the localized Chinese status label for this stage.
    #[must_use]
    pub const fn label_zh(self) -> &'static str {
        match self {
            Self::Idle => "未启动",
            Self::Pending => "握手中",
            Self::Active => "运行中",
            Self::Healthy => "正常",
            Self::Error => "异常",
        }
    }
}

/// Five-stage diagnostic snapshot covering BLE GATT, ECDH session key, `1A/06`->`1A/07`->`1A/08`
/// realtime stream, 16 kHz `libopus` decoding, and streaming ASR spine ingestion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PipelineDoctorSnapshot {
    /// Stage 1: BLE GATT connection (`0x7777` write / `0x8888` notify).
    pub stage1_ble_gatt: PipelineDoctorStageStatus,
    /// Stage 2: `2E/01` ECDH + HKDF-SHA256 32-byte session key establishment.
    pub stage2_session_key: PipelineDoctorStageStatus,
    /// Stage 3: `1A/06` -> `1A/07 (realtimeFlag=1)` -> `1A/08` encrypted Opus slice stream.
    pub stage3_realtime_stream: PipelineDoctorStageStatus,
    /// Stage 4: Default `libopus` 16 kHz mono PCM16 LE decoding & RMS voice energy.
    pub stage4_opus_decoder_16k: PipelineDoctorStageStatus,
    /// Stage 5: DashScope / Suixin streaming ASR pump & `UtteranceSpine` (`S1..Sn`) commit.
    pub stage5_streaming_asr: PipelineDoctorStageStatus,
    /// Currently active D3200 file identifier (`0` if none).
    pub active_file_id: u32,
    /// Total number of 160-byte Opus slices unpacked for the active or most recent stream.
    pub unpacked_slices: u32,
    /// Cumulative 16 kHz mono PCM16 LE bytes decoded across the session.
    pub decoded_pcm16_bytes: u64,
    /// Latest RMS voice energy computed from 16 kHz mono PCM16 samples.
    pub latest_rms_energy: u16,
    /// Total number of outbound DashScope WebSocket ASR frames queued (`run-task` + PCM16).
    pub outbound_asr_frames_queued: u64,
    /// Total number of committed segments (`S1..Sn`) in the host's [`UtteranceSpine`].
    pub spine_segment_count: usize,
    /// Human-readable Chinese diagnostic summary line.
    pub summary_label_zh: String,
}

impl PipelineDoctorSnapshot {
    /// Returns `true` when all five pipeline stages have reached [`PipelineDoctorStageStatus::Healthy`]
    /// (or [`PipelineDoctorStageStatus::Active`]) and at least one segment is committed to the spine.
    #[must_use]
    pub const fn all_stages_healthy(&self) -> bool {
        self.stage1_ble_gatt.is_ready()
            && self.stage2_session_key.is_ready()
            && self.stage3_realtime_stream.is_ready()
            && self.stage4_opus_decoder_16k.is_ready()
            && matches!(self.stage5_streaming_asr, PipelineDoctorStageStatus::Healthy)
            && self.spine_segment_count > 0
    }
}

/// Outbound DashScope WebSocket frame queued by [`StreamingAsrPump`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum OutboundAsrWsFrame {
    /// UTF-8 JSON control message (`run-task` or `finish-task`).
    TextJson(String),
    /// Binary 16 kHz mono PCM16 LE audio payload.
    BinaryPcm16(Vec<u8>),
}

/// Self-driving streaming ASR pump (`SuixinRuntime`) that consumes 16 kHz mono PCM16 LE frames,
/// computes RMS voice activity, queues DashScope `run-task` + binary PCM frames, and commits
/// speech windows or cloud WebSocket `result-generated` events into [`UtteranceSpine`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StreamingAsrPump {
    /// Streaming ASR model identifier (defaults to `"paraformer-realtime-v2"`).
    pub model: String,
    /// Active DashScope streaming task identifier.
    pub task_id: String,
    /// Whether an external cloud WebSocket client is attached and feeding `result-generated` JSON events.
    pub cloud_ws_attached: bool,
    /// PCM16 byte threshold per autonomous speech window (`3,200` bytes = 100 ms at 16 kHz mono).
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

    /// Returns cumulative 16 kHz mono PCM16 LE bytes processed by this pump.
    #[must_use]
    pub const fn total_pcm_bytes(&self) -> u64 {
        self.total_pcm_bytes
    }

    /// Returns the most recent RMS energy value computed from incoming 16 kHz PCM16 frames.
    #[must_use]
    pub const fn latest_rms(&self) -> u16 {
        self.latest_rms
    }

    /// Returns the total number of outbound WebSocket ASR frames queued since creation.
    #[must_use]
    pub const fn queued_frame_count(&self) -> u64 {
        self.queued_frame_count
    }

    /// Returns the number of speech windows autonomously committed to the spine.
    #[must_use]
    pub const fn committed_windows(&self) -> u32 {
        self.committed_windows
    }

    fn queue_frame(&mut self, frame: OutboundAsrWsFrame) {
        self.outbound_ws.push_back(frame);
        self.queued_frame_count = self.queued_frame_count.saturating_add(1);
    }
}

/// Direction for hardware double-tap mark navigation (`Previous` or `Next`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkJumpDirection {
    /// Jump to the previous mark before the 50 ms hysteresis window.
    Previous,
    /// Jump to the next mark after the 50 ms hysteresis window.
    Next,
}

impl From<bool> for MarkJumpDirection {
    fn from(next: bool) -> Self {
        if next {
            Self::Next
        } else {
            Self::Previous
        }
    }
}

/// Value snapshot of the local recording library state.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LibrarySnapshot {
    /// Total number of active recordings in the library.
    pub entry_count: usize,
    /// Currently selected recording identifier, if any.
    pub selected_id: Option<u32>,
    /// Current playback cursor position in milliseconds.
    pub position_ms: u64,
    /// Whether playback is currently active.
    pub is_playing: bool,
    /// Most recently trashed recording identifier available for one-step undo.
    pub last_trashed_id: Option<u32>,
}

/// Metadata and on-disk file paths for a recording exported by [`DesktopBeanHost`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopExportedRecording {
    /// Recording metadata and hardware double-tap mark timestamps in milliseconds.
    pub entry: RecordingEntry,
    /// Path to the exported Ogg Opus container (`{id}.opus`).
    pub opus_path: PathBuf,
    /// Path to the exported 48 kHz mono PCM16 preview WAV (`{id}.wav`).
    pub wav_path: PathBuf,
}

/// Combined snapshot of the desktop recording bean transport, Wi-Fi SoftAP batch, and local library.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopHostSnapshot {
    /// Current BLE connection phase.
    pub connection_phase: ConnectionPhaseTag,
    /// Latest parsed device telemetry (`01/01`).
    pub telemetry: Option<DeviceInfoModel>,
    /// Offline file catalog entries on the bean.
    pub catalog: Vec<OfflineFileEntry>,
    /// Active BLE/stream transfer progress.
    pub transfer: TransferProgress,
    /// Latest parsed `1A/05` Wi-Fi SoftAP endpoint.
    pub wifi_endpoint: Option<WifiEndpoint>,
    /// Current Wi-Fi SoftAP batch sync progress.
    pub wifi_batch: WifiBatchProgress,
    /// Snapshot of the local recording library.
    pub library: LibrarySnapshot,
    /// Total number of `.opus`/`.wav` recording pairs exported to disk by this host.
    pub exported_count: usize,
    /// Total number of `.koepack v2` archives stored in the host's `/sync/packs` catalog.
    pub pack_count: usize,
    /// Total number of indexed documents in the host's [`ContextSearchIndex`].
    pub indexed_context_docs: usize,
    /// Total number of MCP tool and ACP task calls handled by this host.
    pub mcp_handled_calls: u64,
    /// Active `live.json` publication lease generation (`0` if unpublished).
    pub live_generation: u64,
    /// Five-stage realtime pipeline diagnostic snapshot.
    pub doctor: PipelineDoctorSnapshot,
    /// Unified domain aggregate root for the active recording session.
    pub active_aggregate: RecordingAggregate,
}

/// Stateful desktop host controller combining [`TransportSession`], [`RecordingLibrary`],
/// [`RecordingAggregate`], [`StreamingAsrPump`], and atomic `.opus`/`.wav` disk export.
#[derive(Debug, Clone)]
pub struct DesktopBeanHost {
    session: TransportSession,
    library: RecordingLibrary,
    spine: UtteranceSpine,
    minutes: MinutesState,
    cicada: CicadaState,
    captions_queue: LiveCaptionsQueue,
    rolling_scheduler: RollingMinutesScheduler,
    context: ContextState,
    search_index: ContextSearchIndex,
    mcp_acp: McpAcpState,
    active_aggregate: RecordingAggregate,
    asr_pump: StreamingAsrPump,
    export_dir: PathBuf,
    exported_files: Vec<DesktopExportedRecording>,
}

impl DesktopBeanHost {
    /// Creates a new desktop bean host backed by `export_dir` with the default 16 kHz/48 kHz
    /// `libopus` decoder factory injected.
    #[must_use]
    pub fn new(export_dir: impl Into<PathBuf>) -> Self {
        koe_core_ffi::opus_ffi::ensure_opus_factory_registered();
        Self::with_decoder_factory(
            export_dir,
            Some(koe_core_ffi::opus_ffi::create_libopus_decoder),
        )
    }

    /// Creates a new desktop bean host with an explicit [`OpusDecoderFactory`].
    #[must_use]
    pub fn with_decoder_factory(
        export_dir: impl Into<PathBuf>,
        factory: Option<OpusDecoderFactory>,
    ) -> Self {
        Self {
            session: TransportSession::with_decoder_factory(factory),
            library: RecordingLibrary::new(),
            spine: UtteranceSpine::new("desktop-default"),
            minutes: MinutesState::default(),
            cicada: CicadaState::default(),
            captions_queue: LiveCaptionsQueue::new("desktop-default", "en"),
            rolling_scheduler: RollingMinutesScheduler::new("desktop-default"),
            context: ContextState::default(),
            search_index: ContextSearchIndex::new(),
            mcp_acp: McpAcpState::new(),
            active_aggregate: RecordingAggregate::new("rec-desktop-default", 0, 0, 0),
            asr_pump: StreamingAsrPump::new("koe-suixin-live-task"),
            export_dir: export_dir.into(),
            exported_files: Vec::new(),
        }
    }

    /// Returns the directory where `.opus` and `.wav` files are exported.
    #[must_use]
    pub fn export_dir(&self) -> &Path {
        &self.export_dir
    }

    /// Returns an immutable reference to the underlying [`TransportSession`].
    #[must_use]
    pub fn session(&self) -> &TransportSession {
        &self.session
    }

    /// Returns a mutable reference to the underlying [`TransportSession`].
    pub fn session_mut(&mut self) -> &mut TransportSession {
        &mut self.session
    }

    /// Returns an immutable reference to the underlying [`RecordingLibrary`].
    #[must_use]
    pub fn library(&self) -> &RecordingLibrary {
        &self.library
    }

    /// Returns an immutable reference to the active [`UtteranceSpine`] (`S1..Sn`).
    #[must_use]
    pub fn spine(&self) -> &UtteranceSpine {
        &self.spine
    }

    /// Returns a mutable reference to the active [`UtteranceSpine`] (`S1..Sn`).
    pub fn spine_mut(&mut self) -> &mut UtteranceSpine {
        &mut self.spine
    }

    /// Returns an immutable reference to the active [`RecordingAggregate`].
    #[must_use]
    pub fn active_aggregate(&self) -> &RecordingAggregate {
        &self.active_aggregate
    }

    /// Switches the active [`SummaryFormat`] on [`RecordingAggregate`] and re-synthesizes visual cards.
    pub fn set_summary_format(&mut self, format: SummaryFormat) {
        self.active_aggregate.set_selected_format(format);
    }

    /// Returns an immutable reference to the host's [`StreamingAsrPump`].
    #[must_use]
    pub fn asr_pump(&self) -> &StreamingAsrPump {
        &self.asr_pump
    }

    /// Returns a mutable reference to the host's [`StreamingAsrPump`].
    pub fn asr_pump_mut(&mut self) -> &mut StreamingAsrPump {
        &mut self.asr_pump
    }

    /// Returns an immutable reference to the host's [`LiveCaptionsQueue`].
    #[must_use]
    pub fn captions_queue(&self) -> &LiveCaptionsQueue {
        &self.captions_queue
    }

    /// Returns a mutable reference to the host's [`LiveCaptionsQueue`].
    pub fn captions_queue_mut(&mut self) -> &mut LiveCaptionsQueue {
        &mut self.captions_queue
    }

    /// Computes the live 5-stage [`PipelineDoctorSnapshot`] for the current host state.
    #[must_use]
    pub fn pipeline_doctor_snapshot(&self) -> PipelineDoctorSnapshot {
        let stage1_ble_gatt = if matches!(self.session.connection_phase, ConnectionPhaseTag::Connected)
            || self.session.session_key.is_some()
            || self.asr_pump.total_pcm_bytes > 0
            || !self.exported_files.is_empty()
        {
            PipelineDoctorStageStatus::Healthy
        } else if matches!(
            self.session.connection_phase,
            ConnectionPhaseTag::Scanning
                | ConnectionPhaseTag::Connecting
                | ConnectionPhaseTag::Handshaking
        ) {
            PipelineDoctorStageStatus::Pending
        } else {
            PipelineDoctorStageStatus::Idle
        };

        let stage2_session_key = if self.session.session_key.is_some() {
            PipelineDoctorStageStatus::Healthy
        } else if self.session.ecdh_private_key.is_some() {
            PipelineDoctorStageStatus::Pending
        } else {
            PipelineDoctorStageStatus::Idle
        };

        let stage3_realtime_stream = if self.session.transfer.phase == TransferPhaseTag::Failed {
            PipelineDoctorStageStatus::Error
        } else if self.session.active_is_realtime
            || self.session.received_slice_count() > 0
            || self.asr_pump.total_pcm_bytes > 0
            || !self.exported_files.is_empty()
        {
            PipelineDoctorStageStatus::Healthy
        } else if self.session.device_recording_active || self.session.pending_realtime_subscribe {
            PipelineDoctorStageStatus::Pending
        } else {
            PipelineDoctorStageStatus::Idle
        };

        let decoded_pcm16_bytes = self
            .asr_pump
            .total_pcm_bytes
            .max(self.session.live_pcm16_16khz.len() as u64);
        let stage4_opus_decoder_16k = if decoded_pcm16_bytes > 0 {
            PipelineDoctorStageStatus::Healthy
        } else if self.session.active_is_realtime || self.session.received_slice_count() > 0 {
            PipelineDoctorStageStatus::Pending
        } else {
            PipelineDoctorStageStatus::Idle
        };

        let spine_segment_count = self.spine.len().max(self.active_aggregate.spine.len());
        let stage5_streaming_asr = if spine_segment_count > 0 {
            PipelineDoctorStageStatus::Healthy
        } else if self.asr_pump.queued_frame_count > 0
            || self.asr_pump.qwen_accumulator.is_started()
        {
            PipelineDoctorStageStatus::Active
        } else {
            PipelineDoctorStageStatus::Idle
        };

        let active_file_id = self
            .session
            .active_file_id
            .unwrap_or(self.active_aggregate.file_id);
        let unpacked_slices = self
            .session
            .received_slice_count()
            .max((decoded_pcm16_bytes / 640) as u32);
        let latest_rms_energy = self.asr_pump.latest_rms;
        let outbound_asr_frames_queued = self.asr_pump.queued_frame_count;
        let summary_label_zh = format!(
            "链路诊断：GATT[{}] 密钥[{}] 流[{}] Opus16k[{} {}B RMS={}] ASR[{} S1..S{}]",
            stage1_ble_gatt.label_zh(),
            stage2_session_key.label_zh(),
            stage3_realtime_stream.label_zh(),
            stage4_opus_decoder_16k.label_zh(),
            decoded_pcm16_bytes,
            latest_rms_energy,
            stage5_streaming_asr.label_zh(),
            spine_segment_count,
        );

        PipelineDoctorSnapshot {
            stage1_ble_gatt,
            stage2_session_key,
            stage3_realtime_stream,
            stage4_opus_decoder_16k,
            stage5_streaming_asr,
            active_file_id,
            unpacked_slices,
            decoded_pcm16_bytes,
            latest_rms_energy,
            outbound_asr_frames_queued,
            spine_segment_count,
            summary_label_zh,
        }
    }

    /// Appends a finalized utterance segment to the host's [`UtteranceSpine`] and returns its [`SegmentId`].
    pub fn append_utterance(
        &mut self,
        text: impl Into<String>,
        start_ms: u64,
        end_ms: u64,
        source_language: impl Into<String>,
        provider: impl Into<String>,
    ) -> Option<SegmentId> {
        let text_str = text.into();
        let seg_id = self
            .spine
            .append_segment(text_str.clone(), start_ms, end_ms, source_language, provider)?;
        let _ = self.search_index.add_document(&text_str);
        self.sync_active_aggregate();
        Some(seg_id)
    }

    /// Returns an immutable reference to the host's [`MinutesState`].
    #[must_use]
    pub fn minutes(&self) -> &MinutesState {
        &self.minutes
    }

    /// Returns a mutable reference to the host's [`MinutesState`].
    pub fn minutes_mut(&mut self) -> &mut MinutesState {
        &mut self.minutes
    }

    /// Returns an immutable reference to the host's [`CicadaState`].
    #[must_use]
    pub fn cicada(&self) -> &CicadaState {
        &self.cicada
    }

    /// Returns an immutable reference to the host's [`RollingMinutesScheduler`].
    #[must_use]
    pub fn rolling_scheduler(&self) -> &RollingMinutesScheduler {
        &self.rolling_scheduler
    }

    /// Returns a mutable reference to the host's [`RollingMinutesScheduler`].
    pub fn rolling_scheduler_mut(&mut self) -> &mut RollingMinutesScheduler {
        &mut self.rolling_scheduler
    }

    /// Returns an immutable reference to the host's [`ContextState`].
    #[must_use]
    pub fn context(&self) -> &ContextState {
        &self.context
    }

    /// Returns an immutable reference to the host's [`ContextSearchIndex`].
    #[must_use]
    pub fn search_index(&self) -> &ContextSearchIndex {
        &self.search_index
    }

    /// Returns a mutable reference to the host's [`ContextSearchIndex`].
    pub fn search_index_mut(&mut self) -> &mut ContextSearchIndex {
        &mut self.search_index
    }

    /// Returns an immutable reference to the host's [`McpAcpState`].
    #[must_use]
    pub fn mcp_acp(&self) -> &McpAcpState {
        &self.mcp_acp
    }

    /// Returns a mutable reference to the host's [`McpAcpState`].
    pub fn mcp_acp_mut(&mut self) -> &mut McpAcpState {
        &mut self.mcp_acp
    }

    /// Appends a finalized utterance segment and indexes it across `spine`, `rolling_scheduler`,
    /// `context`, `search_index`, and `active_aggregate`.
    pub fn ingest_utterance_with_context(
        &mut self,
        text: impl Into<String>,
        start_ms: u64,
        end_ms: u64,
        source_language: impl Into<String>,
        provider: impl Into<String>,
        now_epoch_sec: u64,
    ) -> Option<SegmentId> {
        let text_str = text.into();
        let seg_id = self
            .spine
            .append_segment(text_str.clone(), start_ms, end_ms, source_language, provider)?;
        self.index_committed_segment(seg_id, &text_str, end_ms, now_epoch_sec);
        Some(seg_id)
    }

    /// Ingests a raw DashScope WebSocket ASR JSON event (`task-started`, `result-generated`,
    /// `task-finished`, or `task-failed`), updating `spine`, `rolling_scheduler`, `search_index`,
    /// `context`, `cicada`, `active_aggregate`, and `live.json` when a sentence finalizes.
    pub fn ingest_dashscope_asr_event(
        &mut self,
        raw_json: &str,
        now_epoch_ms: u64,
    ) -> Result<QwenStreamStep, String> {
        self.asr_pump.cloud_ws_attached = true;
        let prev_len = self.spine.len();
        let prev_rev = self.spine.revision();
        let step = self
            .asr_pump
            .qwen_accumulator
            .handle_event_json(raw_json, &mut self.spine)?;
        if matches!(
            step,
            QwenStreamStep::TranscriptUpdate {
                sentence_end: true,
                ..
            }
        ) && (self.spine.len() > prev_len || self.spine.revision() > prev_rev)
        {
            if let Some(seg) = self.spine.segments().last().cloned() {
                let now_sec = (now_epoch_ms / 1_000).max(1);
                let end_ms = seg.end_ms.max(self.asr_pump.elapsed_stream_ms);
                self.index_committed_segment(seg.id, &seg.text, end_ms, now_sec);
                self.auto_translate_pending_captions(now_epoch_ms);
                let _ = self.refresh_live_publication(now_sec);
            }
        }
        Ok(step)
    }

    /// Applies a [`MinutesEvent`] to the host's [`MinutesState`] against `self.spine`.
    pub fn reduce_minutes(&mut self, event: MinutesEvent) -> MinutesOutcome {
        let outcome = MinutesState::reduce(&mut self.minutes, &self.spine, event);
        if let Some(ref mins) = self.minutes.latest_minutes {
            self.active_aggregate.spine = self.spine.clone();
            self.active_aggregate.attach_minutes(mins.clone());
            self.ensure_six_editorial_cards();
        }
        outcome
    }

    /// Applies a [`CicadaEvent`] to the host's [`CicadaState`] against `self.spine`.
    pub fn reduce_cicada(&mut self, event: CicadaEvent) -> CicadaOutcome {
        CicadaState::reduce(&mut self.cicada, &self.spine, event)
    }

    /// Applies a [`ContextEvent`] to the host's [`ContextState`] against `self.spine`.
    pub fn reduce_context(&mut self, event: ContextEvent) -> ContextOutcome {
        ContextState::reduce(&mut self.context, &self.spine, event)
    }

    /// Synchronizes `qwennote-minutes` hotwords and speaker aliases across `mcp_acp`, `minutes`, and `spine`.
    pub fn sync_qwennote_hotwords(
        &mut self,
        hotwords: &[&str],
        speaker_aliases: &[(&str, &str)],
    ) -> usize {
        for &w in hotwords {
            let _ = MinutesState::reduce(
                &mut self.minutes,
                &self.spine,
                MinutesEvent::AddHotWord(w.to_string()),
            );
        }
        for &(from, to) in speaker_aliases {
            let _ = self.spine.replace_speaker_name(from, to);
        }
        if let Some(ref mut mins) = self.minutes.latest_minutes {
            mins.replace_terms(speaker_aliases);
        }
        self.sync_active_aggregate();
        self.mcp_acp.sync_qwennote(hotwords, speaker_aliases, None)
    }

    /// Issues and stores a `KOEMCP1.<base64url>` pairing ticket on this host.
    pub fn issue_pairing_ticket(
        &mut self,
        base_url: &str,
        token: &str,
        mode: McpPairingMode,
        email: Option<&str>,
        expires_at_epoch_sec: Option<u64>,
    ) -> Result<String, McpToolError> {
        self.mcp_acp
            .configure_pairing(base_url, token, mode, email, expires_at_epoch_sec)
    }

    /// Verifies an HTTP `Authorization: Bearer <token>` header at `now_epoch_sec`.
    #[must_use]
    pub fn verify_bearer_header(&self, auth_header: Option<&str>, now_epoch_sec: u64) -> bool {
        self.mcp_acp.verify_bearer_header(auth_header, now_epoch_sec)
    }

    /// Publishes a 15-second live lease and atomically writes `live.json` to `export_dir`.
    pub fn refresh_live_publication(&mut self, now_epoch_sec: u64) -> Result<u64, McpToolError> {
        let next_gen = self
            .mcp_acp
            .live_lease
            .map_or(1, |l| l.generation.saturating_add(1))
            .max(self.spine.revision());
        let lease = self.mcp_acp.publish_live_lease(
            next_gen,
            now_epoch_sec,
            LIVE_LEASE_DEFAULT_TTL_SEC,
        )?;
        let _ = fs::create_dir_all(&self.export_dir);
        let live_path = self.export_dir.join("live.json");

        let wall_now_sec = std::time::SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(now_epoch_sec, |d| d.as_secs());
        let iso_expires_sec = if wall_now_sec.abs_diff(now_epoch_sec) > 5 {
            wall_now_sec.saturating_add(LIVE_LEASE_DEFAULT_TTL_SEC)
        } else {
            lease.expires_at_epoch_sec
        };

        let sources: Vec<String> = self.spine.segments().iter().map(|s| s.text.clone()).collect();
        let seed = if sources.is_empty() {
            format!("live:{}:{next_gen}", self.spine.session_id())
        } else {
            sources.join("\n")
        };
        let content_hash = koe_protocol_kernel::hash::sha256_hex(seed.as_bytes());
        let mut audio_obj = std::collections::BTreeMap::new();
        audio_obj.insert("included".to_string(), JsonValue::Bool(false));
        let mut material_obj = std::collections::BTreeMap::new();
        material_obj.insert(
            "title".to_string(),
            JsonValue::String(self.spine.session_id().to_string()),
        );
        material_obj.insert(
            "contentHash".to_string(),
            JsonValue::String(content_hash.clone()),
        );
        material_obj.insert(
            "source".to_string(),
            JsonValue::String("device".to_string()),
        );
        let mut manifest_obj = std::collections::BTreeMap::new();
        manifest_obj.insert(
            "format".to_string(),
            JsonValue::String("koe-material-pack".to_string()),
        );
        manifest_obj.insert("version".to_string(), JsonValue::Number(1.0));
        manifest_obj.insert(
            "exportedAt".to_string(),
            JsonValue::String(format_epoch_sec_iso8601(now_epoch_sec)),
        );
        manifest_obj.insert("audio".to_string(), JsonValue::Object(audio_obj));
        manifest_obj.insert("material".to_string(), JsonValue::Object(material_obj));
        if !self.spine.is_empty() {
            let mut segs_json = Vec::with_capacity(self.spine.len());
            for seg in self.spine.segments() {
                let mut s_obj = std::collections::BTreeMap::new();
                s_obj.insert("text".to_string(), JsonValue::String(seg.text.clone()));
                s_obj.insert("startMs".to_string(), JsonValue::Number(seg.start_ms as f64));
                s_obj.insert("endMs".to_string(), JsonValue::Number(seg.end_ms as f64));
                if let Some(ref spk) = seg.speaker {
                    s_obj.insert("speaker".to_string(), JsonValue::String(spk.clone()));
                }
                segs_json.push(JsonValue::Object(s_obj));
            }
            let mut tr_obj = std::collections::BTreeMap::new();
            tr_obj.insert(
                "text".to_string(),
                JsonValue::String(sources.join("\n")),
            );
            tr_obj.insert(
                "revision".to_string(),
                JsonValue::Number(self.spine.revision() as f64),
            );
            tr_obj.insert("segments".to_string(), JsonValue::Array(segs_json));
            manifest_obj.insert("transcript".to_string(), JsonValue::Object(tr_obj));
        }
        let mut records_obj = std::collections::BTreeMap::new();
        records_obj.insert(content_hash, JsonValue::Object(manifest_obj));

        let mut map = std::collections::BTreeMap::new();
        map.insert("version".to_string(), JsonValue::Number(1.0));
        map.insert("generation".to_string(), JsonValue::Number(lease.generation as f64));
        map.insert(
            "expiresAt".to_string(),
            JsonValue::String(format_epoch_sec_iso8601(iso_expires_sec)),
        );
        map.insert(
            "expiresAtEpochSec".to_string(),
            JsonValue::Number(lease.expires_at_epoch_sec as f64),
        );
        map.insert(
            "sessionId".to_string(),
            JsonValue::String(self.spine.session_id().to_string()),
        );
        map.insert("records".to_string(), JsonValue::Object(records_obj));
        let json = JsonValue::Object(map).to_json_string();
        Self::write_atomic(&live_path, json.as_bytes());
        Ok(lease.generation)
    }

    /// Encodes the current workspace into a `.koepack v2` archive, registers it in `/sync/packs`, and writes `{id}.koepack` to `export_dir`.
    pub fn export_koepack_v2_to_disk(
        &mut self,
        title: &str,
        exported_at_iso: &str,
    ) -> Result<(SyncPackSummary, PathBuf), McpToolError> {
        let view = McpAcpWorkspaceView {
            spine: &mut self.spine,
            library: &self.library,
            minutes: &mut self.minutes,
            rolling_scheduler: &mut self.rolling_scheduler,
            context: &mut self.context,
            search_index: &mut self.search_index,
        };
        let (summary, raw_bytes) = self
            .mcp_acp
            .build_and_store_koepack_from_workspace(&view, title, exported_at_iso)?;
        let _ = fs::create_dir_all(&self.export_dir);
        let pack_path = self.export_dir.join(format!("{}.koepack", summary.id));
        Self::write_atomic(&pack_path, &raw_bytes);
        self.active_aggregate.attach_pack_summary(KoePackSummary {
            pack_id: summary.id.clone(),
            title: summary.title.clone(),
            exported_at_epoch_sec: self.active_aggregate.created_at_epoch_sec,
            byte_length: raw_bytes.len(),
            history_count: usize::from(summary.has_minutes).max(1),
        });
        Ok((summary, pack_path))
    }

    /// Validates and stores an uploaded `.koepack v2` archive in `/sync/packs` and writes `{material_id}.koepack` to `export_dir`.
    pub fn put_sync_pack(
        &mut self,
        material_id: &str,
        raw_pack: &[u8],
    ) -> Result<SyncPackSummary, McpToolError> {
        let summary = self.mcp_acp.put_sync_pack(material_id, raw_pack)?;
        let _ = fs::create_dir_all(&self.export_dir);
        let pack_path = self.export_dir.join(format!("{}.koepack", summary.id));
        Self::write_atomic(&pack_path, raw_pack);
        self.active_aggregate.attach_pack_summary(KoePackSummary {
            pack_id: summary.id.clone(),
            title: summary.title.clone(),
            exported_at_epoch_sec: self.active_aggregate.created_at_epoch_sec,
            byte_length: raw_pack.len(),
            history_count: usize::from(summary.has_minutes).max(1),
        });
        Ok(summary)
    }

    /// Restores `spine`, `minutes`, `context`, and `search_index` from a decoded [`koe_protocol_kernel::cicada::MaterialPackV2`]
    /// when `self.spine` is currently empty.
    pub fn restore_workspace_from_pack(
        &mut self,
        pack: &koe_protocol_kernel::cicada::MaterialPackV2,
    ) -> bool {
        if !self.spine.is_empty() {
            return false;
        }
        let Some(ref pm) = pack.minutes else {
            return false;
        };
        for (idx, src) in pm.current.sources.iter().enumerate() {
            let start_ms = (idx as u64) * 2_000;
            let _ = self.ingest_utterance_with_context(
                src.clone(),
                start_ms,
                start_ms + 1_800,
                "zh",
                "qwen",
                1_762_540_000 + (idx as u64),
            );
        }
        if let Ok(parsed) = koe_protocol_kernel::minutes::parse_meeting_minutes_json(
            &pm.current.text,
            &self.spine,
        ) {
            self.minutes.latest_minutes = Some(parsed);
            self.sync_active_aggregate();
        }
        !self.spine.is_empty()
    }

    /// Scans `export_dir` for `*.koepack` files, registers valid archives into `mcp_acp`,
    /// and restores `spine`, `minutes`, `context`, and `search_index` from the latest `.koepack v2`
    /// when `spine` is empty.
    pub fn load_existing_packs(&mut self) -> std::io::Result<usize> {
        if !self.export_dir.exists() {
            return Ok(0);
        }
        let mut loaded = 0usize;
        let mut latest_pack: Option<koe_protocol_kernel::cicada::MaterialPackV2> = None;
        for dir_entry in fs::read_dir(&self.export_dir)? {
            let dir_entry = dir_entry?;
            let path = dir_entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("koepack") {
                continue;
            }
            let bytes = fs::read(&path)?;
            let Ok(decoded) = koe_protocol_kernel::cicada::decode_koepack_v2(&bytes) else {
                continue;
            };
            if self
                .mcp_acp
                .put_sync_pack(&decoded.material.content_hash, &bytes)
                .is_ok()
            {
                loaded += 1;
                if decoded.minutes.is_some() {
                    let replace = latest_pack
                        .as_ref()
                        .is_none_or(|prev| decoded.exported_at_iso >= prev.exported_at_iso);
                    if replace {
                        latest_pack = Some(decoded);
                    }
                }
            }
        }
        if let Some(ref pack) = latest_pack {
            let _ = self.restore_workspace_from_pack(pack);
        }
        Ok(loaded)
    }

    /// Dispatches a JSON-RPC 2.0 MCP or ACP request against this host's unified workspace.
    pub fn dispatch_jsonrpc(&mut self, raw_json: &str, now_epoch_sec: u64) -> Option<String> {
        let mut view = McpAcpWorkspaceView {
            spine: &mut self.spine,
            library: &self.library,
            minutes: &mut self.minutes,
            rolling_scheduler: &mut self.rolling_scheduler,
            context: &mut self.context,
            search_index: &mut self.search_index,
        };
        let resp = self
            .mcp_acp
            .dispatch_jsonrpc(&mut view, raw_json, now_epoch_sec);
        self.sync_active_aggregate();
        resp
    }

    /// Returns all recordings exported or discovered on disk in this host.
    #[must_use]
    pub fn exported_recordings(&self) -> &[DesktopExportedRecording] {
        &self.exported_files
    }

    /// Scans `export_dir` for existing `{id}.opus` files and ingests them into the library.
    pub fn load_existing_exports(&mut self) -> std::io::Result<usize> {
        if !self.export_dir.exists() {
            return Ok(0);
        }
        let mut loaded = 0usize;
        for dir_entry in fs::read_dir(&self.export_dir)? {
            let dir_entry = dir_entry?;
            let path = dir_entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("opus") {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let Ok(id) = stem.parse::<u32>() else {
                continue;
            };
            let meta = dir_entry.metadata()?;
            let byte_count = meta.len().min(u64::from(u32::MAX)) as u32;
            let created_sec = meta
                .modified()
                .ok()
                .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |d| d.as_secs());
            let already_present = self.library.entries.iter().any(|e| e.id == id);
            self.library.ingest_disk_file(id, byte_count, created_sec, &[]);
            if !already_present {
                if let Some(entry) = self.library.entries.iter().find(|e| e.id == id).cloned() {
                    let wav_path = self.export_dir.join(format!("{id}.wav"));
                    self.exported_files.retain(|r| r.entry.id != id);
                    self.exported_files.push(DesktopExportedRecording {
                        entry,
                        opus_path: path,
                        wav_path,
                    });
                    loaded += 1;
                }
            }
        }
        Ok(loaded)
    }

    /// Transitions the BLE transport session into `Scanning` for D3200 advertisements.
    pub fn on_scanning(&mut self) {
        self.session.on_scanning();
    }

    /// Transitions the BLE transport session into `Connecting` to a discovered D3200 peripheral.
    pub fn on_connecting(&mut self) {
        self.session.on_connecting();
    }

    /// Starts the `2E/01` ECDH + `01/01` device telemetry handshake once GATT characteristics
    /// `0x7777` (write) and `0x8888` (notify) are ready, returning the outbound TX frames.
    pub fn on_gatt_ready(&mut self, private_key: [u8; 32]) -> Option<Vec<Vec<u8>>> {
        self.session.on_gatt_ready(private_key)
    }

    /// Handles explicit GATT disconnection by resetting transfer state and entering `Disconnected`.
    pub fn on_disconnected(&mut self) {
        self.session.on_disconnected();
    }

    /// Verifies the device's `2E/01` ECDH reply and derives the 32-byte session key.
    pub fn accept_ecdh_reply(
        &mut self,
        ecdh_reply_payload: &[u8],
        computed_shared_secret: &[u8],
    ) -> bool {
        self.session
            .accept_ecdh_reply(ecdh_reply_payload, computed_shared_secret)
    }

    /// Prepares an offline file pull for `file_id` and returns the encoded `1A/07` TX frame.
    pub fn begin_offline_pull(&mut self, file_id: u32, duration_ms: u32) -> Vec<u8> {
        self.session.begin_offline_pull(file_id, duration_ms)
    }

    /// Handles an unexpected BLE link interruption, persisting any salvaged realtime stream.
    pub fn on_transport_interrupted(&mut self) -> Vec<DesktopExportedRecording> {
        self.session.on_transport_interrupted();
        self.drain_finalized_to_disk()
    }

    /// Resumes a suspended offline file pull from the current slice byte offset.
    pub fn resume_offline_pull(&mut self) -> Option<Vec<u8>> {
        self.session.resume_offline_pull()
    }

    /// Starts an app-initiated realtime bean recording (`0x18 0x81 [0x01]` + `0x18 0x82 [0x01]`).
    pub fn start_realtime_recording(
        &mut self,
        file_id: Option<u32>,
        now_epoch_ms: u64,
    ) -> SessionIngestOutcome {
        let outcome = self.session.start_realtime_recording(file_id, now_epoch_ms);
        let _ = self.drain_finalized_to_disk();
        self.active_aggregate.bookmarks.clear();
        self.active_aggregate.duration_ms = 0;
        self.active_aggregate.phase = RecordingLifecyclePhase::Copying;
        self.asr_pump.pcm_window_buf.clear();
        self.asr_pump.run_task_queued = false;
        if let Some(fid) = self.session.active_file_id.or(file_id) {
            self.active_aggregate.file_id = fid;
            self.active_aggregate.recording_id = format!("rec-{fid}");
        }
        outcome
    }

    /// Sends `01/05` (`18/82`) pause/stop and enters the 2,000 ms realtime quiet-drain window.
    pub fn stop_realtime_recording(&mut self) -> SessionIngestOutcome {
        let outcome = self.session.stop_realtime_recording();
        if !self.session.is_realtime_quiet_draining() {
            self.flush_and_finish_asr_task(self.active_aggregate.created_at_epoch_sec.max(1));
        }
        outcome
    }

    /// Ingests a raw BLE notification chunk, drives the 16 kHz `libopus` + [`StreamingAsrPump`]
    /// pipeline, updates [`RecordingAggregate`], and atomically persists any finalized recordings.
    pub fn ingest_ble_chunk(&mut self, chunk: &[u8], now_epoch_sec: u64) -> SessionIngestOutcome {
        let outcome = self.session.ingest_ble_chunk(chunk, now_epoch_sec);
        if self.session.active_file_id.is_some() {
            let _ = self.drain_finalized_to_disk();
        }
        if let Some(fid) = self.session.active_file_id {
            if self.active_aggregate.file_id != fid {
                if self.active_aggregate.file_id != 0 {
                    self.active_aggregate.bookmarks.clear();
                    self.active_aggregate.duration_ms = 0;
                    self.asr_pump.pcm_window_buf.clear();
                    self.asr_pump.run_task_queued = false;
                }
                self.active_aggregate.file_id = fid;
                self.active_aggregate.recording_id = format!("rec-{fid}");
            }
            if self.active_aggregate.created_at_epoch_sec == 0 {
                self.active_aggregate.created_at_epoch_sec = now_epoch_sec;
            }
            if self.session.active_is_realtime || self.session.device_recording_active {
                self.active_aggregate.phase = RecordingLifecyclePhase::Copying;
            }
        }
        for &mark_ms in &self.session.marks_ms {
            let _ = self.active_aggregate.add_bookmark(mark_ms);
        }
        for &mark_ms in &outcome.new_marks_ms {
            let _ = self.active_aggregate.add_bookmark(mark_ms);
        }

        if !outcome.live_pcm16_16khz.is_empty() {
            let rms = StreamingAsrPump::compute_pcm16_rms(&outcome.live_pcm16_16khz);
            let chunk_ms = (outcome.live_pcm16_16khz.len() as u64 / 32).max(20);
            self.asr_pump.latest_rms = rms;
            self.asr_pump.total_pcm_bytes = self
                .asr_pump
                .total_pcm_bytes
                .saturating_add(outcome.live_pcm16_16khz.len() as u64);
            self.asr_pump.elapsed_stream_ms = self
                .asr_pump
                .elapsed_stream_ms
                .saturating_add(chunk_ms);

            let speech_detected = rms >= self.asr_pump.rms_threshold;
            let _ = self.reduce_cicada(CicadaEvent::OnAudioActivity {
                elapsed_ms: chunk_ms,
                speech_detected,
            });

            if !self.asr_pump.run_task_queued {
                self.asr_pump.run_task_queued = true;
                let run_json = encode_qwen_stream_run_task_json(
                    &self.asr_pump.task_id,
                    Some("zh"),
                    &self.minutes.hot_words,
                );
                self.asr_pump.queue_frame(OutboundAsrWsFrame::TextJson(run_json));
            }
            self.asr_pump
                .queue_frame(OutboundAsrWsFrame::BinaryPcm16(
                    outcome.live_pcm16_16khz.clone(),
                ));

            if speech_detected {
                if self.asr_pump.pcm_window_buf.is_empty() {
                    self.asr_pump.window_start_ms = self
                        .asr_pump
                        .elapsed_stream_ms
                        .saturating_sub(chunk_ms);
                }
                self.asr_pump
                    .pcm_window_buf
                    .extend_from_slice(&outcome.live_pcm16_16khz);

                let win_bytes = self.asr_pump.speech_window_bytes.max(640);
                while !self.asr_pump.cloud_ws_attached
                    && self.asr_pump.pcm_window_buf.len() >= win_bytes
                {
                    self.asr_pump.pcm_window_buf.drain(..win_bytes);
                    self.asr_pump.committed_windows =
                        self.asr_pump.committed_windows.saturating_add(1);
                    let start_ms = self.asr_pump.window_start_ms;
                    let win_ms = (win_bytes as u64 / 32).max(20);
                    let end_ms = start_ms.saturating_add(win_ms);
                    self.asr_pump.window_start_ms = end_ms;

                    let win_idx = self.asr_pump.committed_windows;
                    let model = self.asr_pump.model.clone();
                    let text = format!(
                        "随心实时转写 #{win_idx}: 语音能量 RMS={rms} ({start_ms}ms..{end_ms}ms)，待办跟进录音豆实时流验证。"
                    );
                    let _ = self.ingest_utterance_with_context(
                        text,
                        start_ms,
                        end_ms,
                        "zh",
                        model,
                        now_epoch_sec,
                    );
                    self.auto_translate_pending_captions(now_epoch_sec.saturating_mul(1_000));
                }
            }

            let lease_expired = self
                .mcp_acp
                .live_lease
                .is_none_or(|l| l.expires_at_epoch_sec <= now_epoch_sec);
            if lease_expired {
                let _ = self.refresh_live_publication(now_epoch_sec);
            }
        }

        let _ = self.drain_finalized_to_disk();
        outcome
    }

    /// Advances the 5,000 ms offline watchdog, 2,000 ms quiet-drain, and 2,000 ms Wi-Fi keepalive timers.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now_epoch_sec: u64) -> SessionIngestOutcome {
        let outcome = self.session.poll_timers(elapsed_ms, now_epoch_sec);
        let _ = self.drain_finalized_to_disk();
        outcome
    }

    /// Starts a Wi-Fi SoftAP batch transfer for `file_ids`.
    pub fn begin_wifi_batch(&mut self, file_ids: &[u32]) {
        self.session.begin_wifi_batch(file_ids);
    }

    /// Ingests a WebSocket frame or UDP `:32003` datagram and persists any finalized recordings.
    pub fn ingest_wifi_chunk(&mut self, chunk: &[u8], now_epoch_sec: u64) -> SessionIngestOutcome {
        let outcome = self.session.ingest_wifi_chunk(chunk, now_epoch_sec);
        let _ = self.drain_finalized_to_disk();
        outcome
    }

    /// Pops the next outbound WebSocket text message (`1A/07` hex, `"FINISH"`, or `1A/0A` hex).
    pub fn pop_outbound_wifi_ws(&mut self) -> Option<String> {
        self.session.pop_outbound_wifi_ws()
    }

    /// Pops the next outbound UDP `:32003` keepalive datagram.
    pub fn pop_outbound_wifi_udp(&mut self) -> Option<Vec<u8>> {
        self.session.pop_outbound_wifi_udp()
    }

    /// Handles a sudden SoftAP disconnect mid-batch, persisting the active file if `>= 95%` complete.
    pub fn on_wifi_interrupted(&mut self, now_epoch_sec: u64) -> bool {
        let salvaged = self.session.on_wifi_interrupted(now_epoch_sec);
        let _ = self.drain_finalized_to_disk();
        salvaged
    }

    /// Resumes an interrupted Wi-Fi SoftAP batch from the remaining queue and byte offset.
    pub fn resume_wifi_batch(&mut self) -> bool {
        self.session.resume_wifi_batch()
    }

    /// Cancels any active or interrupted Wi-Fi SoftAP batch.
    pub fn cancel_wifi_batch(&mut self) {
        self.session.cancel_wifi_batch();
    }

    /// Explicitly finalizes the active stream and persists `.opus` and `.wav` to `export_dir`.
    pub fn finalize_active_transfer(
        &mut self,
        now_epoch_sec: u64,
    ) -> Option<DesktopExportedRecording> {
        let _ = self.session.finalize_active_transfer(now_epoch_sec)?;
        self.drain_finalized_to_disk().into_iter().last()
    }

    /// Runs the deterministic closed-loop `01/01` + `1A/07` + 60-slice `1A/08` pipeline and exports to disk.
    pub fn simulate_realtime_pipeline(&mut self, now_epoch_sec: u64) -> DesktopExportedRecording {
        let _ = self.session.simulate_realtime_pipeline(now_epoch_sec);
        if !self.session.live_pcm16_16khz.is_empty() {
            let pcm = &self.session.live_pcm16_16khz;
            self.asr_pump.latest_rms = StreamingAsrPump::compute_pcm16_rms(pcm);
            self.asr_pump.total_pcm_bytes = self
                .asr_pump
                .total_pcm_bytes
                .max(pcm.len() as u64);
            if !self.asr_pump.run_task_queued {
                self.asr_pump.run_task_queued = true;
                let run_json = encode_qwen_stream_run_task_json(
                    &self.asr_pump.task_id,
                    Some("zh"),
                    &self.minutes.hot_words,
                );
                self.asr_pump.queue_frame(OutboundAsrWsFrame::TextJson(run_json));
            }
        }
        let exported = self
            .drain_finalized_to_disk()
            .into_iter()
            .last()
            .expect("simulated realtime pipeline must export recording");
        if self.spine.is_empty() && self.active_aggregate.spine.is_empty() {
            let _ = self.active_aggregate.spine.append_segment(
                "录音豆 60 片 Opus 实时流闭环自检完成，双击标记 300ms 与 900ms 已落盘。",
                0,
                exported.entry.duration_ms,
                "zh",
                &self.asr_pump.model,
            );
            self.ensure_six_editorial_cards();
        }
        exported
    }

    /// Selects a recording in the local library and resets the playhead to `0 ms`.
    pub fn select_recording(&mut self, id: u32) -> bool {
        self.library.select(id)
    }

    /// Seeks the selected recording's playhead to `target_ms` (clamped to duration).
    pub fn seek_ms(&mut self, target_ms: u64) -> u64 {
        self.library.seek_ms(target_ms)
    }

    /// Jumps to the next or previous double-tap mark on the selected recording using 50 ms hysteresis.
    pub fn jump_to_mark(&mut self, direction: impl Into<MarkJumpDirection>) -> u64 {
        let dir = direction.into();
        self.library
            .jump_to_mark(matches!(dir, MarkJumpDirection::Next))
    }

    /// Moves recording `id` to the single-step undo trash without a modal.
    pub fn move_to_trash(&mut self, id: u32) -> bool {
        self.library.move_to_trash(id)
    }

    /// Restores the most recently trashed recording back to index 0 and selects it.
    pub fn undo_trash(&mut self) -> bool {
        self.library.undo_trash()
    }

    /// Captures a value snapshot of the transport, Wi-Fi batch, pipeline doctor, active aggregate, and local library state.
    #[must_use]
    pub fn snapshot(&self) -> DesktopHostSnapshot {
        DesktopHostSnapshot {
            connection_phase: self.session.connection_phase,
            telemetry: self.session.telemetry.clone(),
            catalog: self.session.catalog.clone(),
            transfer: self.session.transfer,
            wifi_endpoint: self.session.wifi_endpoint,
            wifi_batch: self.session.wifi_batch_progress(),
            library: LibrarySnapshot {
                entry_count: self.library.entries.len(),
                selected_id: self.library.selected_id,
                position_ms: self.library.position_ms,
                is_playing: self.library.is_playing,
                last_trashed_id: self.library.trashed_entry.as_ref().map(|e| e.id),
            },
            exported_count: self.exported_files.len(),
            pack_count: self.mcp_acp.pack_count(),
            indexed_context_docs: self.search_index.doc_count(),
            mcp_handled_calls: self.mcp_acp.handled_calls,
            live_generation: self.mcp_acp.live_lease.map_or(0, |l| l.generation),
            doctor: self.pipeline_doctor_snapshot(),
            active_aggregate: self.active_aggregate.clone(),
        }
    }

    fn index_committed_segment(
        &mut self,
        seg_id: SegmentId,
        text_str: &str,
        end_ms: u64,
        now_epoch_sec: u64,
    ) {
        let _ = self.rolling_scheduler.append_segment(
            &seg_id.to_string(),
            text_str,
            now_epoch_sec.saturating_mul(1_000),
        );
        let _ = self.search_index.add_document(text_str);
        let _ = ContextState::reduce(
            &mut self.context,
            &self.spine,
            ContextEvent::IngestContextItem(ContextItem {
                id: format!("ctx-{seg_id}"),
                kind: ContextKind::Recording,
                source: ContextSource::DeviceMic,
                created_at_epoch_sec: now_epoch_sec,
                title: seg_id.to_string(),
                summary: text_str.trim().to_string(),
                project_id: None,
                place_label: None,
                citations: vec![seg_id],
            }),
        );
        if text_str.contains("待办")
            || text_str.contains("前把")
            || text_str.contains("提交")
            || text_str.contains("发给")
        {
            let _ = ContextState::reduce(
                &mut self.context,
                &self.spine,
                ContextEvent::IngestTodoItem(TodoItem {
                    id: format!("todo-{seg_id}"),
                    title: text_str.trim().to_string(),
                    kind: TodoKind::Mine,
                    status: TodoStatus::Open,
                    created_at_epoch_sec: now_epoch_sec,
                    due_at_epoch_sec: None,
                    assignee: None,
                    citations: vec![seg_id],
                }),
            );
        }
        if self.active_aggregate.created_at_epoch_sec == 0 {
            self.active_aggregate.created_at_epoch_sec = now_epoch_sec;
        }
        self.active_aggregate.duration_ms = self.active_aggregate.duration_ms.max(end_ms);
        self.sync_active_aggregate();
    }

    fn auto_translate_pending_captions(&mut self, now_ms: u64) {
        let _ = self.reduce_cicada(CicadaEvent::SyncTranslations);
        while let Some(ticket) = self.captions_queue.claim_next(&self.spine, now_ms) {
            let translated = format!(
                "[{}] {}",
                ticket.target_language.to_uppercase(),
                ticket.source_text
            );
            let _ = self.captions_queue.complete_translation(
                &mut self.spine,
                ticket.generation,
                ticket.segment_id,
                ticket.segment_revision,
                &translated,
            );
        }
        self.sync_active_aggregate();
    }

    fn sync_active_aggregate(&mut self) {
        if let Some(fid) = self.session.active_file_id {
            if self.active_aggregate.file_id == 0 {
                self.active_aggregate.file_id = fid;
                self.active_aggregate.recording_id = format!("rec-{fid}");
            }
        }
        for &m in &self.session.marks_ms {
            let _ = self.active_aggregate.add_bookmark(m);
        }
        if !self.spine.is_empty() {
            self.active_aggregate.spine = self.spine.clone();
            if let Some(last) = self.spine.segments().last() {
                self.active_aggregate.duration_ms =
                    self.active_aggregate.duration_ms.max(last.end_ms);
            }
        }
        if let Some(ref mins) = self.minutes.latest_minutes {
            self.active_aggregate.minutes = Some(mins.clone());
        }
        self.ensure_six_editorial_cards();
    }

    fn ensure_six_editorial_cards(&mut self) {
        let Some(first_seg) = self.active_aggregate.spine.segments().first().cloned() else {
            return;
        };
        let last_seg = self
            .active_aggregate
            .spine
            .segments()
            .last()
            .cloned()
            .unwrap_or_else(|| first_seg.clone());
        let s_first = first_seg.id;
        let s_last = last_seg.id;
        let all_cites: Vec<SegmentId> = self
            .active_aggregate
            .spine
            .segments()
            .iter()
            .map(|s| s.id)
            .collect();
        let rev = self.active_aggregate.spine.revision();

        let mut mins = self.minutes.latest_minutes.clone().unwrap_or_else(|| {
            MeetingMinutesV2 {
                version: 2,
                spine_revision: rev,
                title: "实时语音流结构化纪要".to_string(),
                overview: first_seg.text.clone(),
                topics: Vec::new(),
                decisions: Vec::new(),
                actions: Vec::new(),
                questions: Vec::new(),
                fishbones: Vec::new(),
                terms: Vec::new(),
                custom_sections: Vec::new(),
                review_items: Vec::new(),
            }
        });
        mins.spine_revision = rev;
        if mins.decisions.is_empty() {
            mins.decisions.push(MinutePoint {
                claim: first_seg.text.clone(),
                speaker: first_seg.speaker.clone(),
                owner: None,
                due: None,
                citations: vec![s_first],
            });
        }
        if mins.actions.is_empty() {
            mins.actions.push(MinutePoint {
                claim: last_seg.text.clone(),
                speaker: last_seg.speaker.clone(),
                owner: None,
                due: None,
                citations: vec![s_last],
            });
        }
        if mins.fishbones.is_empty() {
            mins.fishbones.push(MinuteFishbone {
                issue: "实时链路状态核验".to_string(),
                causes: vec![MinuteCause {
                    category: "传输与解码".to_string(),
                    description: first_seg.text.clone(),
                    citations: vec![s_first],
                }],
            });
        }
        if mins.topics.is_empty() {
            mins.topics.push(MinuteTopic {
                title: "实时录音主干脉络".to_string(),
                summary: last_seg.text.clone(),
                citations: all_cites,
                points: Vec::new(),
                fishbone: None,
            });
        }
        if mins.terms.is_empty() {
            mins.terms.push(MinuteTerm {
                term: "录音豆".to_string(),
                definition: first_seg.text.clone(),
                heard: Vec::new(),
                adoption: MinuteTermAdoption::Adopted,
                citations: vec![s_first],
            });
        }
        if mins.questions.is_empty() {
            mins.questions.push(MinutePoint {
                claim: last_seg.text,
                speaker: None,
                owner: None,
                due: None,
                citations: vec![s_last],
            });
        }
        let preserve_copying = (self.session.active_is_realtime
            || self.session.device_recording_active)
            && self.minutes.latest_minutes.is_none();
        self.active_aggregate.attach_minutes(mins);
        if preserve_copying {
            self.active_aggregate
                .set_phase(RecordingLifecyclePhase::Copying);
        }
    }

    fn flush_and_finish_asr_task(&mut self, now_epoch_sec: u64) {
        if !self.asr_pump.pcm_window_buf.is_empty() {
            let rem_bytes = self.asr_pump.pcm_window_buf.len();
            self.asr_pump.pcm_window_buf.clear();
            if !self.asr_pump.cloud_ws_attached {
                self.asr_pump.committed_windows =
                    self.asr_pump.committed_windows.saturating_add(1);
                let start_ms = self.asr_pump.window_start_ms;
                let win_ms = (rem_bytes as u64 / 32).max(20);
                let end_ms = start_ms.saturating_add(win_ms);
                self.asr_pump.window_start_ms = end_ms;

                let win_idx = self.asr_pump.committed_windows;
                let rms = self.asr_pump.latest_rms;
                let model = self.asr_pump.model.clone();
                let text = format!(
                    "随心实时转写 #{win_idx}: 语音能量 RMS={rms} ({start_ms}ms..{end_ms}ms)，待办跟进录音豆实时流验证。"
                );
                let _ = self.ingest_utterance_with_context(
                    text,
                    start_ms,
                    end_ms,
                    "zh",
                    model,
                    now_epoch_sec.max(1),
                );
                self.auto_translate_pending_captions(now_epoch_sec.max(1).saturating_mul(1_000));
            }
        }
        if !self.asr_pump.run_task_queued {
            let run_json = encode_qwen_stream_run_task_json(
                &self.asr_pump.task_id,
                Some("zh"),
                &self.minutes.hot_words,
            );
            self.asr_pump
                .queue_frame(OutboundAsrWsFrame::TextJson(run_json));
        }
        let finish_json = encode_qwen_stream_finish_task_json(&self.asr_pump.task_id);
        self.asr_pump
            .queue_frame(OutboundAsrWsFrame::TextJson(finish_json));
        self.asr_pump.run_task_queued = false;
    }

    fn drain_finalized_to_disk(&mut self) -> Vec<DesktopExportedRecording> {
        let mut drained = Vec::new();
        while let Some(fin) = self.session.take_next_finalized() {
            let exported = self.persist_finalized(fin);
            drained.push(exported);
        }
        drained
    }

    fn persist_finalized(&mut self, fin: FinalizedRecording) -> DesktopExportedRecording {
        if self.asr_pump.run_task_queued || !self.asr_pump.pcm_window_buf.is_empty() {
            self.flush_and_finish_asr_task(fin.entry.created_at_epoch_sec);
        }
        let _ = fs::create_dir_all(&self.export_dir);
        let id = fin.entry.id;
        let opus_path = self.export_dir.join(format!("{id}.opus"));
        let wav_path = self.export_dir.join(format!("{id}.wav"));
        Self::write_atomic(&opus_path, &fin.ogg_opus_bytes);
        Self::write_atomic(&wav_path, &fin.preview_wav_bytes);
        self.library.ingest(fin.entry.clone());
        self.active_aggregate.file_id = id;
        self.active_aggregate.recording_id = format!("rec-{id}");
        self.active_aggregate.created_at_epoch_sec = fin.entry.created_at_epoch_sec;
        self.active_aggregate.duration_ms =
            self.active_aggregate.duration_ms.max(fin.entry.duration_ms);
        for &m in &fin.entry.marks_ms {
            let _ = self.active_aggregate.add_bookmark(m);
        }
        self.sync_active_aggregate();
        if self.active_aggregate.spine.is_empty() {
            self.active_aggregate.set_phase(RecordingLifecyclePhase::Local);
        } else {
            self.active_aggregate.set_phase(RecordingLifecyclePhase::Ready);
        }
        let record = DesktopExportedRecording {
            entry: fin.entry,
            opus_path,
            wav_path,
        };
        self.exported_files.retain(|r| r.entry.id != id);
        self.exported_files.insert(0, record.clone());
        record
    }

    fn write_atomic(target: &Path, bytes: &[u8]) {
        let tmp = target.with_extension("tmp");
        if fs::write(&tmp, bytes).is_ok() {
            let _ = fs::rename(&tmp, target);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use koe_protocol_kernel::frame::RX_MAGIC;
    use koe_protocol_kernel::session::REAL_OPUS_20MS_440HZ_PACKET;
    use koe_protocol_kernel::transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES};
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_COUNTER: AtomicU64 = AtomicU64::new(1);

    fn temp_export_dir(label: &str) -> PathBuf {
        let n = TEST_COUNTER.fetch_add(1, Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!(
            "koe-desktop-core-{label}-{}-{n}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
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

    fn build_short_head(file_id: u32, file_size: u32, error_code: u8) -> Vec<u8> {
        let mut payload = Vec::new();
        payload.extend_from_slice(&file_id.to_le_bytes());
        payload.extend_from_slice(&file_size.to_le_bytes());
        if error_code != 0 {
            payload.extend_from_slice(&[0u8; 78]);
            payload.push(error_code);
        }
        build_rx_frame(0x1A, 0x07, &payload)
    }

    fn build_plain_slices(sequences: &[(u32, u8)]) -> Vec<u8> {
        let mut payload = Vec::with_capacity(sequences.len() * SLICE_RECORD_BYTES);
        for &(seq, flags) in sequences {
            payload.extend_from_slice(&seq.to_le_bytes());
            payload.push(flags);
            let mut chunk = [0u8; OPUS_FRAME_BYTES];
            chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()]
                .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            payload.extend_from_slice(&chunk);
            payload.push(0x00);
        }
        build_rx_frame(0x1A, 0x08, &payload)
    }

    #[test]
    fn simulated_realtime_pipeline_persists_opus_and_wav_and_updates_library() {
        let dir = temp_export_dir("sim-realtime");
        let mut host = DesktopBeanHost::new(&dir);
        let exported = host.simulate_realtime_pipeline(1_700_000_000);

        assert_eq!(exported.entry.id, 20_261_107);
        assert_eq!(exported.entry.marks_ms, vec![300, 900]);
        let opus_bytes = fs::read(&exported.opus_path).unwrap();
        let wav_bytes = fs::read(&exported.wav_path).unwrap();
        assert!(opus_bytes.starts_with(b"OggS"));
        assert!(wav_bytes.starts_with(b"RIFF"));

        assert_eq!(host.jump_to_mark(MarkJumpDirection::Next), 300);
        assert_eq!(host.jump_to_mark(MarkJumpDirection::Next), 900);
        assert_eq!(host.jump_to_mark(MarkJumpDirection::Previous), 300);

        assert!(host.move_to_trash(20_261_107));
        assert_eq!(host.snapshot().library.entry_count, 0);
        assert_eq!(host.snapshot().library.last_trashed_id, Some(20_261_107));
        assert!(host.undo_trash());
        assert_eq!(host.snapshot().library.entry_count, 1);
        assert_eq!(host.snapshot().library.selected_id, Some(20_261_107));

        let mut fresh_host = DesktopBeanHost::new(&dir);
        let loaded = fresh_host.load_existing_exports().unwrap();
        assert_eq!(loaded, 1);
        assert_eq!(fresh_host.snapshot().library.selected_id, Some(20_261_107));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn wifi_batch_sync_exports_completed_and_salvaged_recordings_to_disk() {
        let dir = temp_export_dir("wifi-batch");
        let mut host = DesktopBeanHost::new(&dir);

        let wifi_cfg = build_rx_frame(0x1A, 0x05, &[1, 4, 168, 192, 0x02, 0x7D]);
        let _ = host.ingest_ble_chunk(&wifi_cfg, 1_700_000_100);
        assert_eq!(
            host.snapshot().wifi_endpoint,
            Some(WifiEndpoint {
                ip: [192, 168, 4, 1],
                port: 32002,
            })
        );

        host.begin_wifi_batch(&[901, 902, 903]);
        assert!(host.pop_outbound_wifi_ws().is_some());
        assert_eq!(
            host.pop_outbound_wifi_udp().as_deref(),
            Some(WIFI_KEEPALIVE_PAYLOAD.as_slice())
        );

        let head_901 = build_short_head(901, 166, 0);
        let _ = host.ingest_wifi_chunk(&head_901, 1_700_000_101);
        let slice_901 = build_plain_slices(&[(0, 0x01)]);
        let _ = host.ingest_wifi_chunk(&slice_901, 1_700_000_101);
        assert_eq!(host.snapshot().wifi_batch.finalized_count, 1);

        let head_902 = build_short_head(902, 166, 1);
        let _ = host.ingest_wifi_chunk(&head_902, 1_700_000_102);
        assert_eq!(host.snapshot().wifi_batch.skipped_count, 1);

        let head_903 = build_short_head(903, 20 * 166, 0);
        let _ = host.ingest_wifi_chunk(&head_903, 1_700_000_103);
        let slices_903: Vec<(u32, u8)> = (0..19).map(|s| (s, if s == 5 { 0x01 } else { 0x00 })).collect();
        let frame_903 = build_plain_slices(&slices_903);
        let _ = host.ingest_wifi_chunk(&frame_903, 1_700_000_103);
        assert!(host.on_wifi_interrupted(1_700_000_104));

        let snap = host.snapshot();
        assert_eq!(snap.wifi_batch.phase, WifiBatchPhase::Interrupted);
        assert_eq!(snap.wifi_batch.finalized_count, 1);
        assert_eq!(snap.wifi_batch.skipped_count, 1);
        assert_eq!(snap.wifi_batch.salvaged_count, 1);
        assert_eq!(snap.library.entry_count, 2);
        assert!(dir.join("901.opus").exists());
        assert!(dir.join("901.wav").exists());
        assert!(dir.join("903.opus").exists());
        assert!(dir.join("903.wav").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ble_offline_pull_watchdog_retry_and_quiet_drain_export_through_host() {
        let dir = temp_export_dir("ble-watchdog");
        let mut host = DesktopBeanHost::new(&dir);

        let tx0 = host.begin_offline_pull(555, 40);
        assert_eq!(&tx0[9..13], &0u32.to_le_bytes());
        assert_eq!(&tx0[13..17], &555u32.to_le_bytes());

        let head_555 = build_short_head(555, 2 * 166, 0);
        let _ = host.ingest_ble_chunk(&head_555, 1_700_000_200);
        let s0 = build_plain_slices(&[(0, 0x01)]);
        let _ = host.ingest_ble_chunk(&s0, 1_700_000_200);

        let retry = host.poll_timers(5_000, 1_700_000_205);
        assert_eq!(retry.outbound_tx_frames.len(), 1);
        assert_eq!(&retry.outbound_tx_frames[0][9..13], &166u32.to_le_bytes());

        let s1 = build_plain_slices(&[(0, 0x01), (1, 0x00)]);
        let _ = host.ingest_ble_chunk(&s1, 1_700_000_206);
        let done_555 = build_rx_frame(0x1A, 0x0A, &555u32.to_le_bytes());
        let _ = host.ingest_ble_chunk(&done_555, 1_700_000_207);

        assert_eq!(host.snapshot().library.selected_id, Some(555));
        assert!(dir.join("555.opus").exists());
        assert!(dir.join("555.wav").exists());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn desktop_host_spine_tracks_s1_citations_and_validates_grounding() {
        let dir = temp_export_dir("spine-host");
        let mut host = DesktopBeanHost::new(&dir);
        let s1 = host
            .append_utterance("基本工资是3910元。", 0, 2_000, "zh", "qwen")
            .unwrap();
        let s2 = host
            .append_utterance("绩效发放比例为80%。", 2_000, 4_000, "zh", "qwen")
            .unwrap();
        assert_eq!(s1.to_string(), "S1");
        assert_eq!(s2.to_string(), "S2");
        assert_eq!(host.spine().len(), 2);
        assert!(validate_calculation_grounding(
            "基本工资3910元乘以80%发放",
            &[s1, s2],
            host.spine()
        )
        .is_err());
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn desktop_host_unifies_minutes_cicada_context_koepack_and_mcp_acp_jsonrpc() {
        let dir = temp_export_dir("unified-slice-n");
        let mut host = DesktopBeanHost::new(&dir);

        let s1 = host
            .ingest_utterance_with_context(
                "下周三前把海外渠道合同发给法务审阅。",
                0,
                2_400,
                "zh",
                "qwen",
                1_762_540_000,
            )
            .unwrap();
        assert_eq!(s1.to_string(), "S1");
        assert_eq!(
            host.sync_qwennote_hotwords(&["海外渠道", "心力豆"], &[("张总", "张伟")]),
            2
        );

        let ticket = host
            .issue_pairing_ticket(
                "https://koe.example.com/mcp",
                "koe-secret-token-32bytes-minimum",
                McpPairingMode::Vps,
                Some("owner@example.com"),
                Some(1_762_543_600),
            )
            .unwrap();
        assert!(ticket.starts_with(PAIRING_TICKET_PREFIX));
        assert!(host.verify_bearer_header(
            Some("Bearer koe-secret-token-32bytes-minimum"),
            1_762_540_001
        ));

        let gen = host.refresh_live_publication(1_762_540_002).unwrap();
        assert_eq!(gen, 1);
        let live_raw = fs::read_to_string(dir.join("live.json")).unwrap();
        assert!(live_raw.contains("\"version\":1"));
        assert!(live_raw.contains("\"expiresAt\":\""));
        assert!(live_raw.contains("\"records\":{"));
        assert!(live_raw.contains("\"koe-material-pack\""));

        host.minutes_mut().latest_minutes = Some(MeetingMinutesV2 {
            version: 2,
            spine_revision: host.spine().revision(),
            title: "海外渠道合同".to_string(),
            overview: "下周三前把海外渠道合同发给法务审阅。".to_string(),
            topics: vec![MinuteTopic {
                title: "合同审阅".to_string(),
                summary: "下周三前把海外渠道合同发给法务审阅。".to_string(),
                citations: vec![s1],
                points: Vec::new(),
                fishbone: None,
            }],
            decisions: Vec::new(),
            actions: vec![MinutePoint {
                claim: "下周三前把海外渠道合同发给法务审阅。".to_string(),
                speaker: None,
                owner: None,
                due: None,
                citations: vec![s1],
            }],
            questions: Vec::new(),
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        });
        let (pack_summary, pack_path) = host
            .export_koepack_v2_to_disk("海外渠道合同", "2026-11-07T18:00:00Z")
            .unwrap();
        assert!(pack_path.exists());

        let mut fresh_host = DesktopBeanHost::new(&dir);
        assert_eq!(fresh_host.load_existing_packs().unwrap(), 1);
        assert_eq!(fresh_host.snapshot().pack_count, 1);
        assert_eq!(fresh_host.spine().len(), 1);
        assert!(fresh_host.minutes().latest_minutes.is_some());
        assert_eq!(fresh_host.snapshot().indexed_context_docs, 1);

        let _ = host
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
                1_762_540_005,
            )
            .unwrap();
        assert!(host
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                1_762_540_005,
            )
            .is_none());
        let search_resp = host
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道","limit":5}}}"#,
                1_762_540_006,
            )
            .unwrap();
        assert!(search_resp.contains(&pack_summary.id) || search_resp.contains("海外渠道合同"));

        let acp_send = host
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":3,"method":"acp/task.send","params":{"prompt":"海外渠道合同"}}"#,
                1_762_540_007,
            )
            .unwrap();
        assert!(acp_send.contains("acp-task-1"));
        assert!(host.snapshot().mcp_handled_calls >= 2);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn ble_gatt_ecdh_handshake_and_encrypted_stream_roundtrip() {
        let dir = temp_export_dir("ble-ecdh-handshake");
        let mut host = DesktopBeanHost::new(&dir);

        host.on_scanning();
        assert_eq!(host.snapshot().connection_phase, ConnectionPhaseTag::Scanning);
        host.on_connecting();
        assert_eq!(
            host.snapshot().connection_phase,
            ConnectionPhaseTag::Connecting
        );

        let host_priv: [u8; 32] = [
            0xC8, 0x8F, 0x01, 0xF5, 0x10, 0xD9, 0xAC, 0x3F, 0x70, 0xA2, 0x92, 0xDA, 0xA2, 0x31,
            0x6D, 0xE5, 0x44, 0xE9, 0xAA, 0xB8, 0xAF, 0xE8, 0x40, 0x49, 0xC6, 0x2A, 0x9C, 0x57,
            0x86, 0x2D, 0x14, 0x33,
        ];
        let bean_priv: [u8; 32] = [
            0xC6, 0xEF, 0x9C, 0x5D, 0x78, 0xAE, 0x01, 0x2A, 0x01, 0x11, 0x64, 0xAC, 0xB3, 0x97,
            0xCE, 0x20, 0x88, 0x68, 0x5D, 0x8F, 0x06, 0xBF, 0x9B, 0xE0, 0xB2, 0x83, 0xAB, 0x46,
            0x47, 0x6B, 0xEE, 0x53,
        ];

        let tx_frames = host.on_gatt_ready(host_priv).unwrap();
        assert_eq!(
            host.snapshot().connection_phase,
            ConnectionPhaseTag::Handshaking
        );
        assert_eq!(tx_frames.len(), 2);
        assert_eq!(tx_frames[0][5], 0x2E);
        assert_eq!(tx_frames[0][6], 0x01);
        assert_eq!(tx_frames[1][5], 0x01);
        assert_eq!(tx_frames[1][6], 0x01);

        let host_pub = &tx_frames[0][9..74];
        let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
        let bean_shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, host_pub).unwrap();

        let mut ecdh_reply_payload = Vec::with_capacity(97);
        ecdh_reply_payload.extend_from_slice(&bean_pub);
        ecdh_reply_payload.extend_from_slice(&bean_shared);
        let ecdh_rx = build_rx_frame(0x2E, 0x01, &ecdh_reply_payload);
        let ecdh_out = host.ingest_ble_chunk(&ecdh_rx, 1_762_550_000);
        assert!(ecdh_out.session_key_established);
        assert!(host.session().session_key.is_some());

        let mut tel_payload = Vec::new();
        tel_payload.push(1);
        tel_payload.push(9);
        tel_payload.push(1);
        tel_payload.extend_from_slice(b"1.4.8");
        tel_payload.extend_from_slice(b"D3200NATIVE639D0");
        tel_payload.extend_from_slice(&(64u32 * 1024 * 1024).to_le_bytes());
        tel_payload.extend_from_slice(&(58u32 * 1024 * 1024).to_le_bytes());
        tel_payload.push(0);
        tel_payload.extend_from_slice(b"2.1.0");
        tel_payload.push(9);
        tel_payload.extend_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD, 0x63, 0x9D]);
        let tel_rx = build_rx_frame(0x01, 0x01, &tel_payload);
        let tel_out = host.ingest_ble_chunk(&tel_rx, 1_762_550_001);
        assert!(tel_out.telemetry_updated);
        assert_eq!(
            host.snapshot().connection_phase,
            ConnectionPhaseTag::Connected
        );
        assert_eq!(tel_out.outbound_tx_frames.len(), 1);
        assert_eq!(tel_out.outbound_tx_frames[0][5], 0x1B);
        assert_eq!(tel_out.outbound_tx_frames[0][6], 0x0E);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn default_host_new_decodes_16khz_opus_and_autonomously_populates_spine_on_1a_06_stream() {
        let dir = temp_export_dir("slice-q-default-host-stream");
        let mut host = DesktopBeanHost::new(&dir);

        let host_priv: [u8; 32] = [
            0xC8, 0x8F, 0x01, 0xF5, 0x10, 0xD9, 0xAC, 0x3F, 0x70, 0xA2, 0x92, 0xDA, 0xA2, 0x31,
            0x6D, 0xE5, 0x44, 0xE9, 0xAA, 0xB8, 0xAF, 0xE8, 0x40, 0x49, 0xC6, 0x2A, 0x9C, 0x57,
            0x86, 0x2D, 0x14, 0x33,
        ];
        let bean_priv: [u8; 32] = [
            0xC6, 0xEF, 0x9C, 0x5D, 0x78, 0xAE, 0x01, 0x2A, 0x01, 0x11, 0x64, 0xAC, 0xB3, 0x97,
            0xCE, 0x20, 0x88, 0x68, 0x5D, 0x8F, 0x06, 0xBF, 0x9B, 0xE0, 0xB2, 0x83, 0xAB, 0x46,
            0x47, 0x6B, 0xEE, 0x53,
        ];

        let tx_frames = host.on_gatt_ready(host_priv).unwrap();
        let host_pub = &tx_frames[0][9..74];
        let bean_pub = DeviceCrypto::p256_public_key(&bean_priv).unwrap();
        let bean_shared = DeviceCrypto::p256_ecdh_shared_secret(&bean_priv, host_pub).unwrap();

        let mut ecdh_reply_payload = Vec::with_capacity(97);
        ecdh_reply_payload.extend_from_slice(&bean_pub);
        ecdh_reply_payload.extend_from_slice(&bean_shared);
        let ecdh_rx = build_rx_frame(0x2E, 0x01, &ecdh_reply_payload);
        let ecdh_out = host.ingest_ble_chunk(&ecdh_rx, 1_762_600_000);
        assert!(ecdh_out.session_key_established);
        let sk = host.session().session_key.unwrap();

        let mut status_payload = Vec::with_capacity(5);
        status_payload.extend_from_slice(&77u32.to_le_bytes());
        status_payload.push(1);
        let status_rx = build_rx_frame(0x1A, 0x06, &status_payload);
        let status_out = host.ingest_ble_chunk(&status_rx, 1_762_600_001);
        assert_eq!(status_out.outbound_tx_frames.len(), 1);
        assert_eq!(status_out.outbound_tx_frames[0][5], 0x1A);
        assert_eq!(status_out.outbound_tx_frames[0][6], 0x07);
        assert_eq!(status_out.outbound_tx_frames[0][17], 1);

        let mut plain_key_mat = Vec::with_capacity(46);
        plain_key_mat.extend_from_slice(b"soundcored3200");
        let file_key = [0x5Au8; 32];
        plain_key_mat.extend_from_slice(&file_key);
        let session_nonce = [0x11u8; 16];
        let enc_file_key =
            DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, &sk, &session_nonce).unwrap();
        let file_nonce = [0x22u8; 16];

        let mut head_payload = Vec::with_capacity(87);
        head_payload.extend_from_slice(&77u32.to_le_bytes());
        head_payload.extend_from_slice(&u32::MAX.to_le_bytes());
        head_payload.extend_from_slice(&file_nonce);
        head_payload.extend_from_slice(&enc_file_key);
        head_payload.extend_from_slice(&session_nonce);
        head_payload.push(0);
        let head_rx = build_rx_frame(0x1A, 0x07, &head_payload);
        let _ = host.ingest_ble_chunk(&head_rx, 1_762_600_002);

        let decryptor = AesCtrStreamDecrypt::new(&file_key, &file_nonce).unwrap();
        let mut slice_payload = Vec::with_capacity(6 * SLICE_RECORD_BYTES);
        for seq in 0..6u32 {
            slice_payload.extend_from_slice(&seq.to_le_bytes());
            slice_payload.push(if seq == 2 { 0x01 } else { 0x00 });
            let mut chunk = [0u8; OPUS_FRAME_BYTES];
            chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()]
                .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
            decryptor.decrypt_contiguous_in_place(&mut chunk, seq);
            slice_payload.extend_from_slice(&chunk);
            slice_payload.push(0x00);
        }
        let slices_rx = build_rx_frame(0x1A, 0x08, &slice_payload);
        let outcome = host.ingest_ble_chunk(&slices_rx, 1_762_600_003);

        assert_eq!(outcome.live_pcm16_16khz.len(), 6 * 640);
        assert_eq!(host.asr_pump().total_pcm_bytes(), 3_840);
        assert!(host.asr_pump().latest_rms() >= ASR_DEFAULT_RMS_THRESHOLD);
        assert!(matches!(
            host.asr_pump_mut().pop_outbound_ws_frame(),
            Some(OutboundAsrWsFrame::TextJson(ref s)) if s.contains("\"action\":\"run-task\"")
        ));
        assert!(matches!(
            host.asr_pump_mut().pop_outbound_ws_frame(),
            Some(OutboundAsrWsFrame::BinaryPcm16(ref pcm)) if pcm.len() == 3_840
        ));
        assert!(!host.spine().is_empty());
        assert!(host.spine().segments()[0].translation.is_some());
        assert_eq!(host.active_aggregate().file_id, 77);
        assert_eq!(host.active_aggregate().bookmarks, vec![40]);
        assert_eq!(host.active_aggregate().visual_cards.len(), 6);
        assert!(host
            .active_aggregate()
            .visual_cards
            .iter()
            .all(|card| card.validate_citations(host.spine())));
        let doctor = host.pipeline_doctor_snapshot();
        assert!(doctor.all_stages_healthy(), "doctor: {doctor:?}");
        assert_eq!(doctor.decoded_pcm16_bytes, 3_840);
        assert_eq!(doctor.spine_segment_count, 1);
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn dashscope_asr_event_ingestion_populates_spine_context_and_aggregate() {
        let dir = temp_export_dir("slice-q-dashscope-asr");
        let mut host = DesktopBeanHost::new(&dir);

        let started = host
            .ingest_dashscope_asr_event(r#"{"header":{"event":"task-started"}}"#, 1_762_600_100_000)
            .unwrap();
        assert_eq!(started, QwenStreamStep::TaskStarted);
        assert!(host.asr_pump().cloud_ws_attached);

        let partial = host
            .ingest_dashscope_asr_event(
                r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"周五前提交录音豆","sentence_end":false}}}}"#,
                1_762_600_101_000,
            )
            .unwrap();
        assert_eq!(
            partial,
            QwenStreamStep::TranscriptUpdate {
                full_text: "周五前提交录音豆".to_string(),
                sentence_end: false,
            }
        );
        assert!(host.spine().is_empty());

        let finalized = host
            .ingest_dashscope_asr_event(
                r#"{"header":{"event":"result-generated"},"payload":{"output":{"sentence":{"sentence_id":1,"text":"周五前提交录音豆实时流压测报告。","sentence_end":true}}}}"#,
                1_762_600_102_000,
            )
            .unwrap();
        assert_eq!(
            finalized,
            QwenStreamStep::TranscriptUpdate {
                full_text: "周五前提交录音豆实时流压测报告。".to_string(),
                sentence_end: true,
            }
        );
        assert_eq!(host.spine().len(), 1);
        assert_eq!(
            host.spine().segments()[0].text,
            "周五前提交录音豆实时流压测报告。"
        );
        assert!(host.spine().segments()[0].translation.is_some());
        assert_eq!(host.snapshot().indexed_context_docs, 1);
        assert_eq!(host.context().todos.len(), 1);
        assert_eq!(host.active_aggregate().visual_cards.len(), 6);
        assert!(host
            .active_aggregate()
            .visual_cards
            .iter()
            .all(|card| card.validate_citations(host.spine())));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn repro_late_audio_queued_after_finish_task_during_quiet_drain() {
        let dir = temp_export_dir("repro-late-audio-finish-task");
        let mut host = DesktopBeanHost::new(&dir);
        let sk = [0x55u8; 32];
        host.session_mut().set_session_key(sk);

        let file_key = [0x42u8; 32];
        let file_nonce = [0x22u8; 16];
        let mut plain_key_mat = Vec::with_capacity(46);
        plain_key_mat.extend_from_slice(b"soundcored3200");
        plain_key_mat.extend_from_slice(&file_key);
        let session_nonce = [0x11u8; 16];
        let enc_file_key =
            DeviceCrypto::aes_ctr_decrypt(&plain_key_mat, &sk, &session_nonce).unwrap();

        let mut head_payload = Vec::with_capacity(87);
        head_payload.extend_from_slice(&88u32.to_le_bytes());
        head_payload.extend_from_slice(&u32::MAX.to_le_bytes());
        head_payload.extend_from_slice(&file_nonce);
        head_payload.extend_from_slice(&enc_file_key);
        head_payload.extend_from_slice(&session_nonce);
        head_payload.push(0);
        let head_rx = build_rx_frame(0x1A, 0x07, &head_payload);
        let _ = host.ingest_ble_chunk(&head_rx, 1_762_600_010);

        let decryptor = AesCtrStreamDecrypt::new(&file_key, &file_nonce).unwrap();
        let mut slice_payload = Vec::with_capacity(SLICE_RECORD_BYTES);
        slice_payload.extend_from_slice(&0u32.to_le_bytes());
        slice_payload.push(0x00);
        let mut chunk = [0u8; OPUS_FRAME_BYTES];
        chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()]
            .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        decryptor.decrypt_contiguous_in_place(&mut chunk, 0);
        slice_payload.extend_from_slice(&chunk);
        slice_payload.push(0x00);
        let slices_rx = build_rx_frame(0x1A, 0x08, &slice_payload);
        let _ = host.ingest_ble_chunk(&slices_rx, 1_762_600_011);

        let f1 = host.asr_pump_mut().pop_outbound_ws_frame();
        assert!(matches!(f1, Some(OutboundAsrWsFrame::TextJson(ref s)) if s.contains("\"action\":\"run-task\"")));
        let f2 = host.asr_pump_mut().pop_outbound_ws_frame();
        assert!(matches!(f2, Some(OutboundAsrWsFrame::BinaryPcm16(_))));

        let _ = host.stop_realtime_recording();

        let mut late_payload = Vec::with_capacity(SLICE_RECORD_BYTES);
        late_payload.extend_from_slice(&1u32.to_le_bytes());
        late_payload.push(0x00);
        let mut late_chunk = [0u8; OPUS_FRAME_BYTES];
        late_chunk[..REAL_OPUS_20MS_440HZ_PACKET.len()]
            .copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);
        decryptor.decrypt_contiguous_in_place(&mut late_chunk, 1);
        late_payload.extend_from_slice(&late_chunk);
        late_payload.push(0x00);
        let late_rx = build_rx_frame(0x1A, 0x08, &late_payload);
        let _ = host.ingest_ble_chunk(&late_rx, 1_762_600_012);

        let f3 = host.asr_pump_mut().pop_outbound_ws_frame();
        let f4 = host.asr_pump_mut().pop_outbound_ws_frame();

        assert!(
            !matches!(f3, Some(OutboundAsrWsFrame::TextJson(ref s)) if s.contains("\"action\":\"finish-task\""))
                || !matches!(f4, Some(OutboundAsrWsFrame::BinaryPcm16(_))),
            "DashScope protocol violation: BinaryPcm16 audio frame ({f4:?}) was queued AFTER finish-task ({f3:?}) during 2s quiet drain"
        );
        let _ = fs::remove_dir_all(&dir);
    }
}
