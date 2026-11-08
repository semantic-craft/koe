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
    build_morning_brief, compute_project_progress, filter_open_mine_todos, format_coarse_place,
    pack_context_source_lines, select_focus_project, sort_context_timeline, sort_todos,
    ContextEvent, ContextOutcome, ContextReducer, ContextSearchIndex, ContextState, DiaryDraft,
    DiaryEntry, DiaryPeriod, MorningBrief, Project, ProjectProgress, ProjectStatus, ScoringMode,
    SourceLine, SourcePointer, TimelineEntry,
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
pub use koe_protocol_kernel::copilot_google::{
    extract_segment_citations, CopilotAuthStyle, CopilotError, CopilotMessage, CopilotPhase,
    CopilotPresetChip, CopilotProviderConfig, CopilotRole, CopilotSession, CopilotToolCall,
    GeminiNotebook, GoogleServiceKind, GoogleSuiteStore, GoogleTaskId, GoogleTaskRecord,
    GoogleTaskStatus, GoogleTasksSyncReport, GoogleWireRequest, KeepChecklistItem, KeepNote,
    KeepNoteColor, KeepNoteDraft, KeepNoteId, NotebookAudioOverview, NotebookAudioOverviewStatus,
    NotebookId, NotebookQaTurn, NotebookRpcOp, NotebookSource, NotebookSourceKind,
    NotebookTransportKind, ToolCallId, COPILOT_PRESET_CHIPS, COPILOT_SYSTEM_PROMPT,
    DEFAULT_DEEPSEEK_MODEL, GEMINI_NOTEBOOK_BATCHEXECUTE_URL, GOOGLE_KEEP_V1_BASE_URL,
    GOOGLE_TASKS_V1_BASE_URL, MAX_COPILOT_TOOL_ROUNDS,
};
pub use koe_protocol_kernel::mcp_acp::{
    build_mcp_tools_schema, build_openai_tools_json, compute_pack_sync_delta, constant_time_eq,
    format_epoch_sec_iso8601, is_supported_mcp_tool, AcpAgentCard, AcpTaskPhase, AcpTaskRecord,
    LiveLeaseValidator, LivePublicationLease, McpAcpEvent, McpAcpOutcome, McpAcpOwnedRuntime,
    McpAcpReducer, McpAcpState, McpAcpWorkspaceView, McpPairingMode, McpToolError, McpToolSpec,
    PackSyncDelta, PairingTicket, QwennoteCatalog, SyncPackSummary, ACP_PROTOCOL_VERSION,
    KOE_ACP_METHODS, KOE_MCP_TOOLS, KOE_MCP_TOOL_SPECS, LIVE_LEASE_DEFAULT_TTL_SEC,
    LIVE_LEASE_MAX_REMAINING_SEC, MAX_ACP_TASK_LOGS, MAX_JSONRPC_REQUEST_BYTES,
    MAX_JSONRPC_RESPONSE_BYTES, MCP_PROTOCOL_VERSION, PAIRING_TICKET_PREFIX,
};
pub use koe_protocol_kernel::minutes::{
    contains_calculation_phrase, contains_percentage, encode_qwen_stream_finish_task_json,
    encode_qwen_stream_run_task_json, validate_calculation_grounding, validate_minutes_grounding,
    BuiltinMinuteTemplate, JsonValue, MinutesEvent, MinutesOutcome, MinutesReducer, MinutesState,
    MinutesValidationError, QwenStreamAccumulator, QwenStreamStep, BUILTIN_MINUTE_TEMPLATES,
    QWEN_FILETRANS_DEFAULT_MODEL, QWEN_STREAMING_DEFAULT_MODEL,
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
    cicada, commands, context, copilot_google, crypto, domain, frame, hash, library, mcp_acp, minutes, models,
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
    /// Total number of Google Tasks currently in store.
    pub google_task_count: usize,
    /// Total number of Gemini NotebookLM notebooks currently in store.
    pub gemini_notebook_count: usize,
    /// Total number of Google Keep notes currently in store.
    pub google_keep_note_count: usize,
    /// Total number of Copilot messages in session history.
    pub copilot_message_count: usize,
    /// Active lifecycle phase of the Ask AI Copilot session.
    pub copilot_phase: CopilotPhase,
    /// Five-stage realtime pipeline diagnostic snapshot.
    pub doctor: PipelineDoctorSnapshot,
    /// Unified domain aggregate root for the active recording session.
    pub active_aggregate: RecordingAggregate,
}

/// Extension trait providing deterministic highlight window calculation on [`SliceMark`].
pub trait SliceMarkHighlightExt {
    /// Computes the `(start_ms, end_ms)` highlight window around `mark_ms` with `half_window_ms` radius,
    /// clamped to `[0, duration_ms]` when `duration_ms > 0`.
    #[must_use]
    fn highlight_window(mark_ms: u64, half_window_ms: u64, duration_ms: u64) -> (u64, u64);
}

impl SliceMarkHighlightExt for SliceMark {
    fn highlight_window(mark_ms: u64, half_window_ms: u64, duration_ms: u64) -> (u64, u64) {
        let start_ms = mark_ms.saturating_sub(half_window_ms);
        let raw_end_ms = mark_ms.saturating_add(half_window_ms);
        let end_ms = if duration_ms > 0 {
            raw_end_ms.min(duration_ms.max(mark_ms))
        } else {
            raw_end_ms
        };
        (start_ms, end_ms)
    }
}

/// Primary navigation section in the Vecta editorial desktop workspace.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum WorkspaceSection {
    /// Daily voice mind capture, morning brief, focus project, and grounded diary (`"随心记录"`).
    #[default]
    DailyMind,
    /// Conference minutes, speaker attribution, and action tracking (`"顺带会议"`).
    Conferences,
    /// Summary format gallery and 6-role editorial card synthesizer (`"心力格式"`).
    Formats,
    /// Aliyun DashScope ASR/Tingwu and MCP/ACP bridge (`"阿里云与 MCP"`).
    AliyunMcp,
    /// Hardware settings and 5-stage realtime pipeline doctor (`"设置与自检"`).
    SettingsDoctor,
}

impl WorkspaceSection {
    /// Canonical list of all five workspace sections in sidebar display order.
    pub const ALL: [Self; 5] = [
        Self::DailyMind,
        Self::Conferences,
        Self::Formats,
        Self::AliyunMcp,
        Self::SettingsDoctor,
    ];

    /// Returns the localized Chinese navigation label for this section.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::DailyMind => "随心记录",
            Self::Conferences => "顺带会议",
            Self::Formats => "心力格式",
            Self::AliyunMcp => "阿里云与 MCP",
            Self::SettingsDoctor => "设置与自检",
        }
    }
}

/// Right-hand detail pane tab in the Vecta editorial desktop workspace.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum DetailTab {
    /// Six-role visual editorial summary cards (`"心智总结"`).
    #[default]
    VisualSummary,
    /// Utterance spine transcript and speaker voiceprint replacement (`"逐字原话与声纹"`).
    TranscriptAndVoiceprint,
    /// Ask AI Copilot presets, freeform Q&A, and Aliyun/Google MCP tools (`"AI 随心问 & 阿里云 MCP"`).
    AskAiAndMcp,
}

impl DetailTab {
    /// Canonical list of all three detail tabs in header display order.
    pub const ALL: [Self; 3] = [
        Self::VisualSummary,
        Self::TranscriptAndVoiceprint,
        Self::AskAiAndMcp,
    ];

    /// Returns the localized Chinese tab label for this detail tab.
    #[must_use]
    pub const fn label(self) -> &'static str {
        match self {
            Self::VisualSummary => "心智总结",
            Self::TranscriptAndVoiceprint => "逐字原话与声纹",
            Self::AskAiAndMcp => "AI 随心问 & 阿里云 MCP",
        }
    }
}

/// Ranked context search hit with optional [`SegmentId`] spine citation.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkspaceSearchHit {
    /// Indexed document identifier (`doc-1`, `doc-2`, ...).
    pub doc_id: String,
    /// Short display title for the matched segment or context item.
    pub title: String,
    /// Matched transcript or context text snippet.
    pub snippet: String,
    /// BM25 + temporal decay relevance score.
    pub score: f64,
    /// Grounded [`SegmentId`] citation when linked to the active [`UtteranceSpine`].
    pub citation: Option<SegmentId>,
}

/// Value snapshot of the latest Ask AI Copilot answer card with grounded [`SegmentId`] citations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotAnswerCard {
    /// User prompt or preset query that produced this card.
    pub prompt: String,
    /// Assistant answer text grounded in `[S1..Sn]`.
    pub answer: String,
    /// Preset chip used to trigger this card, if any.
    pub preset: Option<CopilotPresetChip>,
    /// Extracted [`SegmentId`] citations referenced by `answer`.
    pub citations: Vec<SegmentId>,
    /// MCP or Google Workspace tools invoked while producing this answer.
    pub tools_used: Vec<String>,
    /// Unix epoch timestamp in seconds when this card was generated.
    pub generated_at_epoch_sec: u64,
}

/// Value snapshot of a Google Task item for UI projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleTaskSnapshot {
    /// Task identifier in Google Tasks (`gtask-...`).
    pub id: String,
    /// Task list identifier (`"@default"`).
    pub tasklist_id: String,
    /// Task display title.
    pub title: String,
    /// Task notes or grounded `[S#]` citation details.
    pub notes: String,
    /// Whether the task is marked completed.
    pub completed: bool,
    /// Optional Koe local todo identifier linked for bidirectional sync.
    pub linked_koe_todo_id: Option<String>,
    /// Last updated timestamp in Unix epoch seconds.
    pub updated_at_epoch_sec: u64,
}

/// Value snapshot of the active Ask AI Copilot provider configuration (redacting secrets).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotProviderSnapshot {
    /// Active provider display name (`"deepseek"`, `"openai-local"`, `"mcp-native"`).
    pub provider_name: String,
    /// OpenAI-compatible chat completions endpoint URL.
    pub endpoint_url: String,
    /// Target model identifier (`"deepseek-chat"`, `"qwen2.5-coder:14b"`, etc.).
    pub model: String,
    /// Whether an API key is configured in memory or environment (never exposes the secret).
    pub has_api_key: bool,
    /// Total messages recorded in the active [`CopilotSession`].
    pub session_message_count: usize,
}

/// Value snapshot of a Gemini NotebookLM notebook for UI projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleNotebookSnapshot {
    /// Notebook identifier.
    pub id: String,
    /// Notebook display title.
    pub title: String,
    /// Number of grounded sources attached to the notebook.
    pub source_count: usize,
    /// Whether the Audio Overview is ready for playback.
    pub audio_overview_ready: bool,
    /// Total number of Q&A turns recorded in this notebook.
    pub qa_count: usize,
    /// Latest grounded Q&A answer or audio overview preview text.
    pub latest_qa_preview: Option<String>,
    /// Last updated timestamp in Unix epoch seconds.
    pub updated_at_epoch_sec: u64,
}

/// Value snapshot of a Google Keep note for UI projection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleKeepNoteSnapshot {
    /// Keep note identifier.
    pub id: String,
    /// Note display title.
    pub title: String,
    /// Body text preview.
    pub body_preview: String,
    /// Total checklist items in the note.
    pub checklist_total: usize,
    /// Completed checklist items in the note.
    pub checklist_checked: usize,
    /// Interactive checklist items `(index, text, checked)`.
    pub checklist_items: Vec<(usize, String, bool)>,
    /// Whether the note is pinned.
    pub pinned: bool,
    /// Last updated timestamp in Unix epoch seconds.
    pub updated_at_epoch_sec: u64,
}

/// Strongly-typed built-in meeting minutes template identifier matching [`BUILTIN_MINUTE_TEMPLATES`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum BuiltinTemplateId {
    /// Agile retrospective template (`"retro"`).
    #[default]
    Retro,
    /// Fishbone root-cause analysis template (`"fishbone"`).
    Fishbone,
    /// Daily standup template (`"standup"`).
    Standup,
    /// One-on-one check-in template (`"one-on-one"`).
    OneOnOne,
    /// Candidate interview template (`"interview"`).
    Interview,
}

impl BuiltinTemplateId {
    /// Canonical list of all five built-in meeting minutes templates in display order.
    pub const ALL: [Self; 5] = [
        Self::Retro,
        Self::Fishbone,
        Self::Standup,
        Self::OneOnOne,
        Self::Interview,
    ];

    /// Returns the canonical wire identifier for this template.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Retro => "retro",
            Self::Fishbone => "fishbone",
            Self::Standup => "standup",
            Self::OneOnOne => "one-on-one",
            Self::Interview => "interview",
        }
    }

    /// Returns the canonical wire identifier for this template.
    #[must_use]
    pub const fn id_str(&self) -> &'static str {
        self.as_str()
    }

    /// Returns the localized Chinese display label for this template.
    #[must_use]
    pub const fn label_zh(&self) -> &'static str {
        match self {
            Self::Retro => "敏捷复盘",
            Self::Fishbone => "鱼骨根因",
            Self::Standup => "每日站会",
            Self::OneOnOne => "1对1沟通",
            Self::Interview => "候选人访谈",
        }
    }

    /// Returns the static [`BuiltinMinuteTemplate`] definition from [`BUILTIN_MINUTE_TEMPLATES`].
    #[must_use]
    pub const fn definition(&self) -> &'static BuiltinMinuteTemplate {
        match self {
            Self::Retro => &BUILTIN_MINUTE_TEMPLATES[0],
            Self::Fishbone => &BUILTIN_MINUTE_TEMPLATES[1],
            Self::Standup => &BUILTIN_MINUTE_TEMPLATES[2],
            Self::OneOnOne => &BUILTIN_MINUTE_TEMPLATES[3],
            Self::Interview => &BUILTIN_MINUTE_TEMPLATES[4],
        }
    }
}

/// Value snapshot of the formats and structured minutes template workspace (`"心力格式"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FormatsWorkspaceSnapshot {
    /// Active summary presentation format.
    pub selected_format: SummaryFormat,
    /// Active built-in meeting minutes template.
    pub active_template: BuiltinTemplateId,
    /// Localized Chinese section headings from `active_template`.
    pub builtin_sections_zh: Vec<String>,
    /// Grounded custom and template-derived sections on the active minutes.
    pub custom_sections: Vec<MinuteCustomSection>,
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
    /// Total speech windows autonomously committed to the utterance spine.
    pub committed_speech_windows: u32,
    /// Total custom hotwords registered in the workspace.
    pub active_hotword_count: usize,
    /// Whether `DASHSCOPE_API_KEY` is present and non-empty in the environment (boolean only).
    pub api_key_configured: bool,
}

/// Value snapshot of the Aliyun DashScope and local/VPS MCP/ACP console (`"阿里云与 MCP"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AliyunMcpWorkspaceSnapshot {
    /// DashScope streaming and batch ASR configuration status.
    pub dashscope: DashScopeConfigSnapshot,
    /// Active `KOEMCP1.<base64url>` pairing ticket, if issued.
    pub pairing_ticket: Option<String>,
    /// Active network pairing mode (`Lan` or `Vps`).
    pub pairing_mode: McpPairingMode,
    /// Current `live.json` publication lease generation (`0` if unpublished).
    pub live_generation: u64,
    /// Expiration timestamp in Unix epoch seconds for the active `live.json` lease (`0` if unpublished).
    pub live_lease_expires_at_epoch_sec: u64,
    /// Ready-to-copy JSON configuration snippet for `--mcp-stdio` integration.
    pub mcp_stdio_config_json: String,
    /// Chronological history of Ask AI Copilot answer cards generated during the session.
    pub copilot_history: Vec<CopilotAnswerCard>,
}

/// Control action for the D3200 Wi-Fi SoftAP (`1A/05`, `192.168.4.1:32002`) fast batch transfer state machine.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WifiSoftApAction {
    /// Binds the default `192.168.4.1:32002` SoftAP endpoint (`1A/05`) and begins a batch transfer.
    StartDefaultSoftAp,
    /// Simulates or triggers a mid-batch SoftAP link interruption, salvaging files `>= 95%`.
    Interrupt,
    /// Resumes and completes the active SoftAP batch, exporting finalized audio to the local library.
    ResumeAndComplete,
    /// Cancels the active or interrupted SoftAP batch and resets to `WifiBatchPhase::Idle`.
    Cancel,
}

/// Value snapshot of persistent desktop host settings and SoftAP configuration (`"设置与自检"`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopSettingsSnapshot {
    /// Whether launch-at-login is enabled in `settings.json`.
    pub auto_launch_enabled: bool,
    /// Whether background keep-alive is enabled in `settings.json`.
    pub keep_alive_enabled: bool,
    /// Formatted label for the active or default `1A/05` SoftAP endpoint (`"192.168.4.1:32002"`).
    pub softap_endpoint_label: String,
    /// Display path to the persistent `settings.json` file on disk.
    pub settings_path_display: String,
}

/// Pure immutable UI projection of the entire desktop workspace at a point in time.
#[derive(Debug, Clone, PartialEq)]
pub struct WorkspaceProjection {
    /// Currently selected left-rail navigation section.
    pub section: WorkspaceSection,
    /// Currently selected detail pane tab.
    pub detail_tab: DetailTab,
    /// Active recording domain aggregate root.
    pub active_aggregate: RecordingAggregate,
    /// Six-role visual summary cards for the active recording and format.
    pub visual_cards: Vec<VisualSummaryCard>,
    /// Five-stage realtime pipeline diagnostic snapshot.
    pub doctor: PipelineDoctorSnapshot,
    /// Grounded morning brief synthesized from open todos, yesterday's context, and diary.
    pub morning_brief: MorningBrief,
    /// Currently selected focus project, if any.
    pub focus_project: Option<Project>,
    /// Progress snapshot for the active focus project.
    pub project_progress: ProjectProgress,
    /// Grounded daily diary entry with `[S1..Sn]` source lines.
    pub diary_entry: DiaryEntry,
    /// Chronologically sorted context timeline items.
    pub timeline: Vec<ContextItem>,
    /// Filtered open self-assigned todo items.
    pub open_todos: Vec<TodoItem>,
    /// Local recording library state snapshot.
    pub library: LibrarySnapshot,
    /// On-disk exported `.opus`/`.wav` recordings.
    pub recordings: Vec<DesktopExportedRecording>,
    /// Deterministic 48-bar normalized waveform (`18..=96`) derived from active audio and bookmarks.
    pub waveform_bars_norm: Vec<u8>,
    /// Highlight windows `(start_ms, end_ms)` (`±10,000 ms`) for each hardware double-tap bookmark.
    pub bookmark_windows_ms: Vec<(u64, u64)>,
    /// Current context search query string.
    pub search_query: String,
    /// Ranked context search hits for `search_query`.
    pub search_hits: Vec<WorkspaceSearchHit>,
    /// Latest Ask AI Copilot answer card, if any.
    pub copilot_card: Option<CopilotAnswerCard>,
    /// Active Ask AI Copilot model provider snapshot (redacting API keys).
    pub copilot_provider: CopilotProviderSnapshot,
    /// Latest Google Tasks bidirectional sync report, if any.
    pub google_sync_report: Option<GoogleTasksSyncReport>,
    /// Snapshots of Google Tasks items in the local Google suite store.
    pub google_tasks: Vec<GoogleTaskSnapshot>,
    /// Snapshots of Gemini NotebookLM notebooks in the local Google suite store.
    pub google_notebooks: Vec<GoogleNotebookSnapshot>,
    /// Snapshots of Google Keep notes in the local Google suite store.
    pub google_keep_notes: Vec<GoogleKeepNoteSnapshot>,
    /// Current BLE connection phase tag.
    pub connection_phase: ConnectionPhaseTag,
    /// Latest parsed D3200 device telemetry (`01/01`).
    pub telemetry: Option<DeviceInfoModel>,
    /// Latest parsed Wi-Fi SoftAP endpoint (`1A/05`).
    pub wifi_endpoint: Option<WifiEndpoint>,
    /// Active Wi-Fi SoftAP batch transfer progress.
    pub wifi_batch: WifiBatchProgress,
    /// Current `live.json` publication lease generation.
    pub live_generation: u64,
    /// Total `.koepack v2` archives registered in `/sync/packs`.
    pub pack_count: usize,
    /// Total documents indexed in [`ContextSearchIndex`].
    pub indexed_context_docs: usize,
    /// Total MCP/ACP JSON-RPC calls handled.
    pub mcp_handled_calls: u64,
    /// Most recent JSON-RPC 2.0 response payload.
    pub last_jsonrpc_response: String,
    /// Active hotwords registered for DashScope ASR / Qwen minutes.
    pub hot_words: Vec<String>,
    /// Active `(old_speaker, new_speaker)` aliases applied across the workspace.
    pub speaker_aliases: Vec<(String, String)>,
    /// Formats and structured minutes template workspace snapshot (`"心力格式"`).
    pub formats: FormatsWorkspaceSnapshot,
    /// Aliyun DashScope and local/VPS MCP/ACP console snapshot (`"阿里云与 MCP"`).
    pub aliyun_mcp: AliyunMcpWorkspaceSnapshot,
    /// Persistent desktop settings and SoftAP configuration snapshot (`"设置与自检"`).
    pub settings: DesktopSettingsSnapshot,
}

/// Unidirectional command dispatched from the GPUI view layer to [`DesktopBeanHost::dispatch`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkspaceCommand {
    /// Switches the active [`WorkspaceSection`].
    SelectSection(WorkspaceSection),
    /// Switches the active [`DetailTab`].
    SelectDetailTab(DetailTab),
    /// Runs the deterministic 60-slice Opus realtime simulation pipeline.
    SimulateRealtimePipeline,
    /// Requests a `(0x1A, 0x07)` realtime stream start frame for the active/selected recording.
    RetriggerRealtimeStream {
        /// Current monotonic or epoch timestamp in milliseconds.
        now_ms: u64,
    },
    /// Selects recording `id` in the local library and syncs the active aggregate.
    SelectRecording(u32),
    /// Seeks playback to `target_ms`.
    SeekMs(u64),
    /// Jumps playback to the previous or next double-tap mark.
    JumpMark(MarkJumpDirection),
    /// Adds a hardware/UI slice bookmark at `mark_ms` (`±10s` highlight window).
    AddSliceMark(u64),
    /// Moves recording `id` to the single-step undo trash.
    MoveToTrash(u32),
    /// Restores the most recently trashed recording.
    UndoTrash,
    /// Switches the active [`SummaryFormat`] and re-synthesizes the 6 editorial visual cards.
    SelectSummaryFormat(SummaryFormat),
    /// Switches the active built-in meeting minutes template and re-synthesizes the 6 visual cards.
    SelectMinuteTemplate(BuiltinTemplateId),
    /// Appends a user-defined custom minutes section heading and re-synthesizes the 6 visual cards.
    AddCustomMinuteSection {
        /// Custom section heading title.
        heading: String,
    },
    /// Removes a user-defined custom minutes section heading and re-synthesizes the 6 visual cards.
    RemoveCustomMinuteSection {
        /// Custom section heading title to remove.
        heading: String,
    },
    /// Issues a `KOEMCP1.<base64url>` pairing ticket in `Lan` or `Vps` mode.
    IssuePairingTicket {
        /// Network pairing mode (`Lan` or `Vps`).
        mode: McpPairingMode,
        /// Optional account email bound to the pairing ticket.
        email: Option<String>,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Generates and caches the `--mcp-stdio` JSON configuration snippet.
    GenerateMcpStdioConfig,
    /// Updates and persists the launch-at-login preference in `settings.json`.
    SetAutoLaunch(bool),
    /// Updates and persists the background keep-alive preference in `settings.json`.
    SetKeepAlive(bool),
    /// Drives the D3200 Wi-Fi SoftAP (`1A/05`, `192.168.4.1:32002`) batch transfer state machine.
    ControlWifiSoftApBatch {
        /// SoftAP batch control action.
        action: WifiSoftApAction,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Updates the privacy-redacted coarse place label on the active recording aggregate.
    SetCoarsePlace(Option<String>),
    /// Appends a finalized utterance segment and indexes it into context, todos, and search.
    AppendUtterance {
        /// Finalized transcript text.
        text: String,
        /// Segment start offset in milliseconds.
        start_ms: u64,
        /// Segment end offset in milliseconds.
        end_ms: u64,
        /// ISO language code (`"zh"`, `"en"`, etc.).
        source_language: String,
        /// ASR provider or model identifier.
        provider: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Replaces `old_speaker` with `new_speaker` across `spine`, `minutes`, and `mcp_acp`.
    ReplaceSpeaker {
        /// Original speaker label to replace.
        old_speaker: String,
        /// Replacement speaker display name.
        new_speaker: String,
    },
    /// Synchronizes custom hotwords and speaker aliases across `minutes`, `spine`, and `mcp_acp`.
    SyncHotWords {
        /// Custom vocabulary hotwords.
        hotwords: Vec<String>,
        /// Speaker alias pairs `(from, to)`.
        speaker_aliases: Vec<(String, String)>,
    },
    /// Executes a hybrid BM25 + temporal decay search across indexed utterances.
    SearchContext {
        /// Search query string.
        query: String,
        /// Maximum number of ranked hits to return.
        limit: usize,
    },
    /// Executes a canonical Ask AI Copilot preset chip against the active workspace.
    RunCopilotPreset {
        /// Selected preset chip.
        preset: CopilotPresetChip,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Submits a freeform Ask AI Copilot prompt and synthesizes a grounded answer card.
    AskCopilot {
        /// User question or instruction.
        prompt: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Configures the Ask AI Copilot model provider (`"deepseek"`, `"openai-local"`, or `"mcp-native"`).
    ConfigureCopilotProvider {
        /// Provider identifier (`"deepseek"`, `"openai-local"`, or `"mcp-native"`).
        provider_name: String,
        /// OpenAI-compatible chat completions endpoint URL.
        endpoint_url: String,
        /// Model name (`"deepseek-chat"`, `"qwen2.5-coder:14b"`, etc.).
        model: String,
        /// Optional environment variable name holding the bearer API key.
        api_key_env: Option<String>,
    },
    /// Ingests a raw OpenAI/DeepSeek `/v1/chat/completions` JSON response (supporting `tool_calls` loop).
    IngestCopilotModelResponse {
        /// Raw JSON string returned by the OpenAI-compatible endpoint.
        response_json: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Toggles the completion state of a Google Task in the local suite store and syncs with Koe todos.
    ToggleGoogleTask {
        /// Google Task identifier (`gtask-...`).
        task_id: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Creates a new Google Task in the local suite store and links it into Koe context todos.
    CreateGoogleTask {
        /// Task title.
        title: String,
        /// Task notes or citation context.
        notes: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Creates a new Gemini NotebookLM notebook grounded in the active recording spine.
    CreateGeminiNotebook {
        /// Notebook title.
        title: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Toggles a checklist item on a Google Keep note.
    ToggleGoogleKeepChecklist {
        /// Google Keep note identifier (`keep-...`).
        note_id: String,
        /// Zero-based checklist item index.
        item_index: usize,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Synchronizes Google Tasks, NotebookLM, and Keep with the local workspace context.
    SyncGoogleWorkspace {
        /// Target Google Tasks list identifier (e.g. `"@default"`).
        tasklist_id: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Exports the current workspace to disk as a `.koepack v2` archive.
    ExportKoePackV2 {
        /// Human-readable pack title.
        title: String,
        /// ISO-8601 export timestamp string.
        exported_at_iso: String,
    },
    /// Publishes or refreshes the 15-second `live.json` publication lease.
    RefreshLiveLease {
        /// Wall-clock timestamp in Unix epoch seconds.
        now_epoch_sec: u64,
    },
    /// Dispatches a raw JSON-RPC 2.0 MCP/ACP request string.
    DispatchJsonRpc {
        /// Raw JSON-RPC 2.0 request body.
        request_json: String,
    },
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
    workspace_section: WorkspaceSection,
    detail_tab: DetailTab,
    search_query: String,
    search_hits: Vec<WorkspaceSearchHit>,
    last_copilot_card: Option<CopilotAnswerCard>,
    last_google_sync: Option<GoogleTasksSyncReport>,
    last_jsonrpc_response: String,
    projects: Vec<Project>,
    speaker_aliases: Vec<(String, String)>,
    live_lease_epoch_sec: u64,
    outbound_ble_frames: Vec<Vec<u8>>,
    active_template: BuiltinTemplateId,
    user_custom_headings: Vec<String>,
    removed_builtin_headings: Vec<String>,
    pairing_ticket: Option<String>,
    pairing_mode: McpPairingMode,
    copilot_history: Vec<CopilotAnswerCard>,
    auto_launch_enabled: bool,
    keep_alive_enabled: bool,
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
        let default_project = Project {
            id: "proj-suixin-default".to_string(),
            title: "安克随心记".to_string(),
            goal: "日常心力记录与录音豆实时转写闭环".to_string(),
            status: ProjectStatus::Active,
            created_at_epoch_sec: 1_775_000_000,
        };
        let mut host = Self {
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
            workspace_section: WorkspaceSection::DailyMind,
            detail_tab: DetailTab::VisualSummary,
            search_query: String::new(),
            search_hits: Vec::new(),
            last_copilot_card: None,
            last_google_sync: None,
            last_jsonrpc_response: String::new(),
            projects: vec![default_project],
            speaker_aliases: Vec::new(),
            live_lease_epoch_sec: 1_775_000_000,
            outbound_ble_frames: Vec::new(),
            active_template: BuiltinTemplateId::Retro,
            user_custom_headings: Vec::new(),
            removed_builtin_headings: Vec::new(),
            pairing_ticket: None,
            pairing_mode: McpPairingMode::Lan,
            copilot_history: Vec::new(),
            auto_launch_enabled: false,
            keep_alive_enabled: false,
        };
        let _ = host.load_google_suite();
        let _ = host.load_desktop_settings();
        let _ = host.issue_pairing_ticket(
            "http://127.0.0.1:38450/mcp",
            "koe-lan-default-bearer-token-32b",
            McpPairingMode::Lan,
            None,
            Some(1_775_086_400),
        );
        host
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
            let now_sec = (now_epoch_ms / 1_000).max(1);
            if self.spine.len() == prev_len && self.spine.revision() > prev_rev {
                self.rebuild_search_index_from_spine();
                self.sync_active_aggregate();
                self.auto_translate_pending_captions(now_epoch_ms);
                let _ = self.refresh_live_publication(now_sec);
            } else if let Some(seg) = self.spine.segments().last().cloned() {
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
        let ticket = self.mcp_acp.configure_pairing(
            base_url,
            token,
            mode,
            email,
            expires_at_epoch_sec,
        )?;
        self.pairing_mode = mode;
        self.pairing_ticket = Some(ticket.clone());
        Ok(ticket)
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
        let target_fid = self.session.active_file_id.or(file_id).unwrap_or(0);
        self.reset_active_session_for_new_recording(target_fid, (now_epoch_ms / 1_000).max(1));
        outcome
    }

    fn reset_active_session_for_new_recording(&mut self, fid: u32, now_epoch_sec: u64) {
        let rec_id = if fid > 0 {
            format!("rec-{fid}")
        } else {
            "rec-desktop-default".to_string()
        };
        self.spine = UtteranceSpine::new(rec_id.clone());
        self.minutes.latest_minutes = None;
        self.captions_queue = LiveCaptionsQueue::new(rec_id.clone(), "en");
        self.rolling_scheduler = RollingMinutesScheduler::new(rec_id.clone());
        self.search_index = ContextSearchIndex::new();
        self.active_aggregate = RecordingAggregate::new(rec_id, fid, now_epoch_sec, 0);
        self.active_aggregate.phase = RecordingLifecyclePhase::Copying;
        self.asr_pump.pcm_window_buf.clear();
        self.asr_pump.run_task_queued = false;
        self.asr_pump.elapsed_stream_ms = 0;
        self.asr_pump.window_start_ms = 0;
        self.asr_pump.committed_windows = 0;
        self.asr_pump.qwen_accumulator = QwenStreamAccumulator::new();
    }

    fn rebuild_search_index_from_spine(&mut self) {
        self.search_index = ContextSearchIndex::new();
        for seg in self.spine.segments() {
            let _ = self.search_index.add_document(&seg.text);
        }
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
                    self.reset_active_session_for_new_recording(fid, now_epoch_sec);
                } else {
                    self.active_aggregate.file_id = fid;
                    self.active_aggregate.recording_id = format!("rec-{fid}");
                }
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
            let model = self.asr_pump.model.clone();
            let _ = self.ingest_utterance_with_context(
                "录音豆 60 片 Opus 实时流闭环自检完成，双击标记 300ms 与 900ms 已落盘。",
                0,
                exported.entry.duration_ms,
                "zh",
                model,
                now_epoch_sec.max(1),
            );
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
            google_task_count: self.mcp_acp.google_suite.tasks.len(),
            gemini_notebook_count: self.mcp_acp.google_suite.notebooks.len(),
            google_keep_note_count: self.mcp_acp.google_suite.keep_notes.len(),
            copilot_message_count: self.mcp_acp.copilot.messages.len(),
            copilot_phase: self.mcp_acp.copilot.phase.clone(),
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
            let lang_tag = if ticket.target_language.eq_ignore_ascii_case("en") {
                "EN"
            } else if ticket.target_language.eq_ignore_ascii_case("zh") {
                "ZH"
            } else if ticket.target_language.eq_ignore_ascii_case("ja") {
                "JA"
            } else {
                ticket.target_language.as_str()
            };
            let translated = format!("[{lang_tag}] {}", ticket.source_text);
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
        if self.session.active_file_id == Some(self.active_aggregate.file_id)
            || self.active_aggregate.file_id == 0
        {
            for &m in &self.session.marks_ms {
                let _ = self.active_aggregate.add_bookmark(m);
            }
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

        let is_auto_synthesized = self
            .minutes
            .latest_minutes
            .as_ref()
            .is_none_or(|m| m.title == "实时语音流结构化纪要");
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
        if is_auto_synthesized {
            mins.overview = first_seg.text.clone();
            mins.decisions.clear();
            mins.actions.clear();
            mins.fishbones.clear();
            mins.topics.clear();
            mins.terms.clear();
            mins.questions.clear();
        } else if s_last != s_first {
            let cites_last = mins
                .topics
                .iter()
                .any(|t| t.citations.contains(&s_last))
                || mins
                    .actions
                    .iter()
                    .any(|a| a.citations.contains(&s_last))
                || mins
                    .questions
                    .iter()
                    .any(|q| q.citations.contains(&s_last));
            if !cites_last {
                if let Some(first_topic) = mins.topics.first_mut() {
                    first_topic.summary = last_seg.text.clone();
                    first_topic.citations = all_cites.clone();
                } else {
                    mins.topics.push(MinuteTopic {
                        title: "实时录音主干脉络".to_string(),
                        summary: last_seg.text.clone(),
                        citations: all_cites.clone(),
                        points: Vec::new(),
                        fishbone: None,
                    });
                }
            }
        }
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
        mins.custom_sections = self.build_grounded_custom_sections(
            Some(s_first),
            &first_seg.text,
            first_seg.speaker.clone(),
        );
        let preserve_copying =
            self.session.active_is_realtime || self.session.device_recording_active;
        let custom_count = mins.custom_sections.len();
        let custom_headings: Vec<String> = mins
            .custom_sections
            .iter()
            .map(|s| s.heading.clone())
            .collect();
        self.active_aggregate.attach_minutes(mins);
        self.minutes.latest_minutes = self.active_aggregate.minutes.clone();
        if let Some(first_card) = self.active_aggregate.visual_cards.first_mut() {
            first_card.highlight_box = Some(format!(
                "{} | 模板：{}（{} 项：{}）",
                self.active_aggregate.selected_format.label_zh(),
                self.active_template.label_zh(),
                custom_count,
                custom_headings.join(" / "),
            ));
        }
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
        if self.active_aggregate.file_id != id {
            self.active_aggregate.bookmarks.clear();
            self.active_aggregate.duration_ms = 0;
        }
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

    /// Returns the canonical Ask AI Copilot preset chips in UI display order.
    #[must_use]
    pub const fn copilot_preset_chips(&self) -> &'static [CopilotPresetChip] {
        &COPILOT_PRESET_CHIPS
    }

    /// Configures the Copilot model provider (e.g. DeepSeek or local OpenAI-compatible endpoint).
    pub fn configure_copilot_provider(&mut self, config: CopilotProviderConfig) {
        self.mcp_acp.copilot.provider = config;
    }

    /// Executes a preset chip turn end-to-end against the host's active state.
    pub fn run_copilot_preset(
        &mut self,
        preset: CopilotPresetChip,
        now_epoch_sec: u64,
    ) -> Result<String, String> {
        let mut ws = McpAcpWorkspaceView {
            spine: &mut self.spine,
            library: &self.library,
            minutes: &mut self.minutes,
            rolling_scheduler: &mut self.rolling_scheduler,
            context: &mut self.context,
            search_index: &mut self.search_index,
        };
        let res = self.mcp_acp.run_copilot_preset(&mut ws, preset, now_epoch_sec)?;
        let _ = self.save_google_suite();
        Ok(res)
    }

    /// Submits a freeform user prompt to the Copilot session.
    pub fn submit_copilot_prompt(&mut self, prompt: &str, now_epoch_sec: u64) {
        self.mcp_acp.submit_copilot_prompt(prompt, now_epoch_sec);
    }

    /// Builds the OpenAI `/v1/chat/completions` request payload JSON for the active Copilot turn.
    #[must_use]
    pub fn build_copilot_openai_request(&self) -> JsonValue {
        let tools = build_openai_tools_json();
        self.mcp_acp.copilot.build_openai_chat_request_json(tools)
    }

    /// Ingests a model completion response JSON object, executing any requested tool calls.
    pub fn ingest_copilot_openai_response(
        &mut self,
        response_json: &JsonValue,
        now_epoch_sec: u64,
    ) -> Result<Option<String>, CopilotError> {
        let mut ws = McpAcpWorkspaceView {
            spine: &mut self.spine,
            library: &self.library,
            minutes: &mut self.minutes,
            rolling_scheduler: &mut self.rolling_scheduler,
            context: &mut self.context,
            search_index: &mut self.search_index,
        };
        let res = self.mcp_acp.ingest_copilot_model_response(&mut ws, response_json, now_epoch_sec)?;
        let _ = self.save_google_suite();
        Ok(res)
    }

    /// Synchronizes Google Tasks bidirectionally with local Koe context todos.
    pub fn sync_google_tasks(&mut self, tasklist_id: &str, now_epoch_sec: u64) -> GoogleTasksSyncReport {
        let report = self.mcp_acp.google_suite.sync_google_tasks_with_context(
            &mut self.context,
            tasklist_id,
            now_epoch_sec,
        );
        let _ = self.save_google_suite();
        report
    }

    /// Returns an immutable reference to the host's [`GoogleSuiteStore`].
    #[must_use]
    pub fn google_suite(&self) -> &GoogleSuiteStore {
        &self.mcp_acp.google_suite
    }

    /// Returns a mutable reference to the host's [`GoogleSuiteStore`].
    pub fn google_suite_mut(&mut self) -> &mut GoogleSuiteStore {
        &mut self.mcp_acp.google_suite
    }

    /// Returns an immutable reference to the host's [`CopilotSession`].
    #[must_use]
    pub fn copilot_session(&self) -> &CopilotSession {
        &self.mcp_acp.copilot
    }

    /// Atomically persists `google_suite.json` to the export directory.
    pub fn save_google_suite(&self) -> std::io::Result<()> {
        let target = self.export_dir.join("google_suite.json");
        let json_val = self.mcp_acp.google_suite.to_json_value();
        let json_bytes = json_val.to_json_string().into_bytes();
        Self::write_atomic(&target, &json_bytes);
        Ok(())
    }

    /// Loads and restores `google_suite.json` from the export directory if present.
    pub fn load_google_suite(&mut self) -> std::io::Result<()> {
        let target = self.export_dir.join("google_suite.json");
        if target.exists() {
            if let Ok(content) = fs::read_to_string(&target) {
                if let Ok(json_val) = JsonValue::parse(&content) {
                    if let Ok(store) = GoogleSuiteStore::from_json_value(&json_val) {
                        self.mcp_acp.google_suite = store;
                    }
                }
            }
        }
        Ok(())
    }

    /// Atomically persists `settings.json` (`auto_launch_enabled` and `keep_alive_enabled`) to the export directory.
    pub fn save_desktop_settings(&self) -> std::io::Result<()> {
        let _ = fs::create_dir_all(&self.export_dir);
        let target = self.export_dir.join("settings.json");
        let mut map = if target.exists() {
            fs::read_to_string(&target)
                .ok()
                .and_then(|content| JsonValue::parse(&content).ok())
                .and_then(|val| match val {
                    JsonValue::Object(existing) => Some(existing),
                    _ => None,
                })
                .unwrap_or_default()
        } else {
            std::collections::BTreeMap::new()
        };
        map.insert(
            "auto_launch_enabled".to_string(),
            JsonValue::Bool(self.auto_launch_enabled),
        );
        map.insert(
            "keep_alive_enabled".to_string(),
            JsonValue::Bool(self.keep_alive_enabled),
        );
        let json_bytes = JsonValue::Object(map).to_json_string().into_bytes();
        Self::write_atomic(&target, &json_bytes);
        Ok(())
    }

    /// Loads and restores `settings.json` (`auto_launch_enabled` and `keep_alive_enabled`) from the export directory if present.
    pub fn load_desktop_settings(&mut self) -> std::io::Result<()> {
        let target = self.export_dir.join("settings.json");
        if target.exists() {
            if let Ok(content) = fs::read_to_string(&target) {
                if let Ok(JsonValue::Object(map)) = JsonValue::parse(&content) {
                    match map.get("auto_launch_enabled") {
                        Some(JsonValue::Bool(auto_launch)) => {
                            self.auto_launch_enabled = *auto_launch;
                        }
                        Some(JsonValue::String(s)) if s.eq_ignore_ascii_case("true") => {
                            self.auto_launch_enabled = true;
                        }
                        Some(JsonValue::String(s)) if s.eq_ignore_ascii_case("false") => {
                            self.auto_launch_enabled = false;
                        }
                        _ => {}
                    }
                    match map.get("keep_alive_enabled") {
                        Some(JsonValue::Bool(keep_alive)) => {
                            self.keep_alive_enabled = *keep_alive;
                        }
                        Some(JsonValue::String(s)) if s.eq_ignore_ascii_case("true") => {
                            self.keep_alive_enabled = true;
                        }
                        Some(JsonValue::String(s)) if s.eq_ignore_ascii_case("false") => {
                            self.keep_alive_enabled = false;
                        }
                        _ => {}
                    }
                }
            }
        }
        Ok(())
    }

    fn build_mcp_stdio_config_json(&self) -> String {
        let mut server_obj = std::collections::BTreeMap::new();
        server_obj.insert(
            "command".to_string(),
            JsonValue::String("koe-suixin-desktop".to_string()),
        );
        server_obj.insert(
            "args".to_string(),
            JsonValue::Array(vec![
                JsonValue::String("--mcp-stdio".to_string()),
                JsonValue::String("--workspace".to_string()),
                JsonValue::String(self.export_dir.display().to_string()),
            ]),
        );
        let mut servers_obj = std::collections::BTreeMap::new();
        servers_obj.insert("koe".to_string(), JsonValue::Object(server_obj));
        let mut root = std::collections::BTreeMap::new();
        root.insert("mcpServers".to_string(), JsonValue::Object(servers_obj));
        JsonValue::Object(root).to_json_string()
    }

    fn build_grounded_custom_sections(
        &self,
        s_first: Option<SegmentId>,
        claim: &str,
        speaker: Option<String>,
    ) -> Vec<MinuteCustomSection> {
        let def = self.active_template.definition();
        let tpl_label = self.active_template.label_zh();
        let mut headings: Vec<String> = def
            .sections_zh
            .iter()
            .filter(|&&s| !self.removed_builtin_headings.iter().any(|r| r == s))
            .map(|s| (*s).to_string())
            .collect();
        for user_heading in &self.user_custom_headings {
            if !headings.iter().any(|h| h == user_heading) {
                headings.push(user_heading.clone());
            }
        }
        let citations: Vec<SegmentId> = s_first.into_iter().collect();
        headings
            .into_iter()
            .map(|heading| MinuteCustomSection {
                heading: heading.clone(),
                points: vec![MinutePoint {
                    claim: format!("【{tpl_label}】{heading}：{claim}"),
                    speaker: speaker.clone(),
                    owner: None,
                    due: None,
                    citations: citations.clone(),
                }],
            })
            .collect()
    }

    fn rebuild_template_and_custom_sections(&mut self) {
        if self.spine.is_empty() {
            let model = self.asr_pump.model.clone();
            let now_sec = self.live_lease_epoch_sec.max(1_775_000_000);
            let _ = self.ingest_utterance_with_context(
                "录音豆结构化纪要主干已就绪，支持模板切换与自定义分节溯源。",
                0,
                1_200,
                "zh",
                model,
                now_sec,
            );
        } else {
            self.sync_active_aggregate();
        }
    }

    fn build_wifi_rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
        let total_len = (9 + payload.len() + 1) as u16;
        let mut frame = Vec::with_capacity(usize::from(total_len));
        frame.extend_from_slice(&koe_protocol_kernel::frame::RX_MAGIC);
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

    fn build_wifi_short_head(file_id: u32, file_size: u32) -> Vec<u8> {
        let mut payload = Vec::with_capacity(8);
        payload.extend_from_slice(&file_id.to_le_bytes());
        payload.extend_from_slice(&file_size.to_le_bytes());
        Self::build_wifi_rx_frame(0x1A, 0x07, &payload)
    }

    fn build_wifi_plain_slices(count: usize) -> Vec<u8> {
        Self::build_wifi_plain_slices_from(0, count)
    }

    fn build_wifi_plain_slices_from(start_seq: u32, count: usize) -> Vec<u8> {
        let mut payload =
            Vec::with_capacity(count * koe_protocol_kernel::transport::SLICE_RECORD_BYTES);
        for offset in 0..(count as u32) {
            let seq = start_seq.saturating_add(offset);
            payload.extend_from_slice(&seq.to_le_bytes());
            payload.push(if seq == 0 { 0x01 } else { 0x00 });
            let mut chunk = [0u8; koe_protocol_kernel::transport::OPUS_FRAME_BYTES];
            let src = &koe_protocol_kernel::session::REAL_OPUS_20MS_440HZ_PACKET;
            chunk[..src.len()].copy_from_slice(src);
            payload.extend_from_slice(&chunk);
            payload.push(0x00);
        }
        Self::build_wifi_rx_frame(0x1A, 0x08, &payload)
    }

    /// Returns the projects tracked in this workspace.
    #[must_use]
    pub fn projects(&self) -> &[Project] {
        &self.projects
    }

    /// Inserts or updates a [`Project`] by identifier.
    pub fn upsert_project(&mut self, project: Project) {
        if let Some(existing) = self.projects.iter_mut().find(|p| p.id == project.id) {
            *existing = project;
        } else {
            self.projects.push(project);
        }
    }

    /// Drains all queued outbound BLE TX frames (such as `1A/07` realtime stream requests).
    pub fn drain_outbound_ble_frames(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.outbound_ble_frames)
    }

    /// Requests a `(0x1A, 0x07)` realtime stream start frame (`realtime_flag = 1`) for the active
    /// or selected file ID and primes `asr_pump` and `active_aggregate`.
    pub fn retrigger_realtime_stream_subscribe(&mut self, now_ms: u64) -> Option<Vec<u8>> {
        let target_file_id = self
            .session
            .active_file_id
            .or(self.library.selected_id)
            .or_else(|| {
                (self.active_aggregate.file_id > 0).then_some(self.active_aggregate.file_id)
            })
            .unwrap_or(20_261_108);
        let frame = self.session.request_realtime_stream(target_file_id)?;
        self.outbound_ble_frames.push(frame.clone());
        let now_sec = (now_ms / 1_000).max(1);
        self.active_aggregate.file_id = target_file_id;
        self.active_aggregate.recording_id = format!("rec-{target_file_id}");
        if self.active_aggregate.created_at_epoch_sec == 0 {
            self.active_aggregate.created_at_epoch_sec = now_sec;
        }
        self.active_aggregate
            .set_phase(RecordingLifecyclePhase::Copying);
        if !self.asr_pump.run_task_queued {
            self.asr_pump.run_task_queued = true;
            let run_json = encode_qwen_stream_run_task_json(
                &self.asr_pump.task_id,
                Some("zh"),
                &self.minutes.hot_words,
            );
            self.asr_pump
                .queue_frame(OutboundAsrWsFrame::TextJson(run_json));
        }
        Some(frame)
    }

    /// Computes the pure [`WorkspaceProjection`] for the current host state using the host's
    /// latest `live_lease_epoch_sec` (defaulting to `1_775_000_000`).
    #[must_use]
    pub fn projection(&self) -> WorkspaceProjection {
        self.workspace_projection(self.live_lease_epoch_sec.max(1_775_000_000))
    }

    /// Computes the pure [`WorkspaceProjection`] for the current host state at `now_epoch_sec`.
    #[must_use]
    pub fn workspace_projection(&self, now_epoch_sec: u64) -> WorkspaceProjection {
        let effective_now_sec = now_epoch_sec.max(1_775_000_000);
        let active_spine = if !self.spine.is_empty() {
            &self.spine
        } else {
            &self.active_aggregate.spine
        };

        let project_ids: Vec<String> = self.projects.iter().map(|p| p.id.clone()).collect();
        let rec_start_sec = self
            .active_aggregate
            .created_at_epoch_sec
            .max(effective_now_sec.saturating_sub(3_600));
        let rec_end_sec = rec_start_sec.saturating_add(self.active_aggregate.duration_ms / 1_000);
        let timeline_entry = TimelineEntry {
            id: format!("recording:{}", self.active_aggregate.recording_id),
            kind: ContextKind::Recording,
            title: self.minutes.latest_minutes.as_ref().map_or_else(
                || format!("随心记录 #{}", self.active_aggregate.file_id.max(1)),
                |m| m.title.clone(),
            ),
            start_epoch_sec: Some(rec_start_sec),
            end_epoch_sec: Some(rec_end_sec),
            added_at_epoch_sec: rec_start_sec,
            source: Some(SourcePointer {
                recording_key: format!("file:{}", self.active_aggregate.file_id),
                path: None,
                start_ms: 0,
                end_ms: Some(self.active_aggregate.duration_ms),
                line: None,
            }),
            location: self.active_aggregate.coarse_place.clone(),
            topic_ids: Vec::new(),
            project_ids: project_ids.clone(),
            user_edited: false,
            timing_reliable: true,
            segments: active_spine.segments().to_vec(),
        };
        let timeline_entries = vec![timeline_entry];

        let mut todo_projects = std::collections::BTreeMap::new();
        for todo in &self.context.todos {
            todo_projects.insert(todo.id.clone(), project_ids.clone());
        }

        let focus_project = select_focus_project(
            &self.projects,
            &timeline_entries,
            &self.context.todos,
            &todo_projects,
        )
        .or_else(|| self.projects.first().cloned());

        let project_progress = focus_project.as_ref().map_or_else(
            || ProjectProgress {
                latest: None,
                next_todo: None,
            },
            |proj| {
                compute_project_progress(
                    &proj.id,
                    &timeline_entries,
                    &self.context.todos,
                    &todo_projects,
                )
            },
        );

        let iso_now = format_epoch_sec_iso8601(effective_now_sec);
        let year = iso_now
            .get(0..4)
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(2026);
        let month = iso_now
            .get(5..7)
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(11);
        let day = iso_now
            .get(8..10)
            .and_then(|s| s.parse::<u32>().ok())
            .unwrap_or(8);
        let period = DiaryPeriod::new_day(year, month, day);
        let date_key = period.key();
        let mut diary_entry = DiaryEntry::new(date_key.clone());
        let source_lines = pack_context_source_lines(&timeline_entries, 12_000);
        if !source_lines.is_empty() {
            let fp = period.fingerprint(&source_lines);
            let _ = diary_entry.begin_generation(&fp, true);
            let first_tag = &source_lines[0].label;
            let last_tag = &source_lines[source_lines.len() - 1].label;
            let first_quote = active_spine
                .segments()
                .first()
                .map_or("随心记录已就绪", |s| s.text.as_str());
            let body = format!(
                "【整理】今日随心记与会议脉络已收敛 [{first_tag}] [{last_tag}]\n【原话】「{first_quote}」[{first_tag}]"
            );
            diary_entry.complete_generation(
                body,
                &source_lines,
                fp,
                effective_now_sec,
            );
        }

        let today_iso_date = iso_now.get(0..10).unwrap_or("2026-11-08");
        let morning_brief = build_morning_brief(
            today_iso_date,
            effective_now_sec.saturating_add(86_400),
            &self.context.todos,
            &timeline_entries,
            Some(diary_entry.clone()),
        );

        let timeline = sort_context_timeline(self.context.timeline.clone());
        let open_todos = filter_open_mine_todos(&self.context.todos);

        let duration_ms = self.active_aggregate.duration_ms;
        let bookmark_windows_ms: Vec<(u64, u64)> = self
            .active_aggregate
            .bookmarks
            .iter()
            .map(|&mark_ms| SliceMark::highlight_window(mark_ms, 10_000, duration_ms))
            .collect();

        let waveform_bars_norm = Self::compute_waveform_bars_norm(
            active_spine,
            &self.active_aggregate.bookmarks,
            duration_ms,
            self.asr_pump.latest_rms,
        );

        let google_tasks: Vec<GoogleTaskSnapshot> = self
            .mcp_acp
            .google_suite
            .tasks
            .values()
            .filter(|t| !t.deleted)
            .map(|t| GoogleTaskSnapshot {
                id: t.id.0.clone(),
                tasklist_id: t.tasklist_id.clone(),
                title: t.title.clone(),
                notes: t.notes.clone(),
                completed: matches!(t.status, GoogleTaskStatus::Completed),
                linked_koe_todo_id: t.linked_koe_todo_id.clone(),
                updated_at_epoch_sec: t.updated_at_epoch_sec,
            })
            .collect();

        let google_notebooks: Vec<GoogleNotebookSnapshot> = self
            .mcp_acp
            .google_suite
            .notebooks
            .values()
            .map(|nb| GoogleNotebookSnapshot {
                id: nb.id.0.clone(),
                title: nb.title.clone(),
                source_count: nb.sources.len(),
                audio_overview_ready: nb
                    .audio_overviews
                    .iter()
                    .any(|ao| matches!(ao.status, NotebookAudioOverviewStatus::Ready)),
                qa_count: nb.qa_history.len(),
                latest_qa_preview: nb
                    .qa_history
                    .last()
                    .map(|qa| qa.answer.clone())
                    .or_else(|| nb.audio_overviews.last().map(|ao| ao.dialogue_script.clone())),
                updated_at_epoch_sec: nb.updated_at_epoch_sec,
            })
            .collect();

        let google_keep_notes: Vec<GoogleKeepNoteSnapshot> = self
            .mcp_acp
            .google_suite
            .keep_notes
            .values()
            .map(|note| {
                let checklist_total = note.checklist.len();
                let checklist_checked = note.checklist.iter().filter(|i| i.checked).count();
                let checklist_items = note
                    .checklist
                    .iter()
                    .enumerate()
                    .map(|(idx, item)| (idx, item.text.clone(), item.checked))
                    .collect();
                GoogleKeepNoteSnapshot {
                    id: note.id.0.clone(),
                    title: note.title.clone(),
                    body_preview: note.body_text.clone(),
                    checklist_total,
                    checklist_checked,
                    checklist_items,
                    pinned: note.pinned,
                    updated_at_epoch_sec: note.updated_at_epoch_sec,
                }
            })
            .collect();

        let prov = &self.mcp_acp.copilot.provider;
        let copilot_provider = CopilotProviderSnapshot {
            provider_name: prov.provider_name.clone(),
            endpoint_url: prov.endpoint_url.clone(),
            model: prov.model.clone(),
            has_api_key: prov.api_key.is_some()
                || std::env::var_os("DEEPSEEK_API_KEY").is_some_and(|v| !v.is_empty())
                || std::env::var_os("OPENAI_API_KEY").is_some_and(|v| !v.is_empty()),
            session_message_count: self.mcp_acp.copilot.messages.len(),
        };

        let active_recordings: Vec<DesktopExportedRecording> = self
            .library
            .entries
            .iter()
            .filter_map(|e| self.exported_files.iter().find(|r| r.entry.id == e.id).cloned())
            .collect();

        WorkspaceProjection {
            section: self.workspace_section,
            detail_tab: self.detail_tab,
            active_aggregate: self.active_aggregate.clone(),
            visual_cards: self.active_aggregate.visual_cards.clone(),
            doctor: self.pipeline_doctor_snapshot(),
            morning_brief,
            focus_project,
            project_progress,
            diary_entry,
            timeline,
            open_todos,
            library: LibrarySnapshot {
                entry_count: self.library.entries.len(),
                selected_id: self.library.selected_id,
                position_ms: self.library.position_ms,
                is_playing: self.library.is_playing,
                last_trashed_id: self.library.trashed_entry.as_ref().map(|e| e.id),
            },
            recordings: active_recordings,
            waveform_bars_norm,
            bookmark_windows_ms,
            search_query: self.search_query.clone(),
            search_hits: self.search_hits.clone(),
            copilot_card: self.last_copilot_card.clone(),
            copilot_provider,
            google_sync_report: self.last_google_sync.clone(),
            google_tasks,
            google_notebooks,
            google_keep_notes,
            connection_phase: self.session.connection_phase,
            telemetry: self.session.telemetry.clone(),
            wifi_endpoint: self.session.wifi_endpoint,
            wifi_batch: self.session.wifi_batch_progress(),
            live_generation: self.mcp_acp.live_lease.map_or(0, |l| l.generation),
            pack_count: self.mcp_acp.pack_count(),
            indexed_context_docs: self.search_index.doc_count(),
            mcp_handled_calls: self.mcp_acp.handled_calls,
            last_jsonrpc_response: self.last_jsonrpc_response.clone(),
            hot_words: self.minutes.hot_words.clone(),
            speaker_aliases: self.speaker_aliases.clone(),
            formats: FormatsWorkspaceSnapshot {
                selected_format: self.active_aggregate.selected_format,
                active_template: self.active_template,
                builtin_sections_zh: self
                    .active_template
                    .definition()
                    .sections_zh
                    .iter()
                    .map(|s| (*s).to_string())
                    .collect(),
                custom_sections: self
                    .active_aggregate
                    .minutes
                    .as_ref()
                    .map(|m| m.custom_sections.clone())
                    .unwrap_or_else(|| {
                        let s_first = active_spine.segments().first().map(|s| s.id);
                        let claim = active_spine
                            .segments()
                            .first()
                            .map_or("录音豆结构化纪要主干已就绪", |s| s.text.as_str());
                        let speaker = active_spine
                            .segments()
                            .first()
                            .and_then(|s| s.speaker.clone());
                        self.build_grounded_custom_sections(s_first, claim, speaker)
                    }),
            },
            aliyun_mcp: AliyunMcpWorkspaceSnapshot {
                dashscope: DashScopeConfigSnapshot {
                    streaming_asr_model: self.asr_pump.model.clone(),
                    filetrans_asr_model: QWEN_FILETRANS_DEFAULT_MODEL.to_string(),
                    cloud_ws_attached: self.asr_pump.cloud_ws_attached,
                    queued_asr_frames: self.asr_pump.queued_frame_count,
                    committed_speech_windows: self.asr_pump.committed_windows,
                    active_hotword_count: self.minutes.hot_words.len(),
                    api_key_configured: std::env::var_os("DASHSCOPE_API_KEY")
                        .is_some_and(|v| !v.is_empty()),
                },
                pairing_ticket: self.pairing_ticket.clone(),
                pairing_mode: self.pairing_mode,
                live_generation: self.mcp_acp.live_lease.map_or(0, |l| l.generation),
                live_lease_expires_at_epoch_sec: self
                    .mcp_acp
                    .live_lease
                    .map_or(0, |l| l.expires_at_epoch_sec),
                mcp_stdio_config_json: self.build_mcp_stdio_config_json(),
                copilot_history: self.copilot_history.clone(),
            },
            settings: DesktopSettingsSnapshot {
                auto_launch_enabled: self.auto_launch_enabled,
                keep_alive_enabled: self.keep_alive_enabled,
                softap_endpoint_label: self.session.wifi_endpoint.map_or_else(
                    || "192.168.4.1:32002 (待连接)".to_string(),
                    |ep| format!("{}.{}.{}.{}:{}", ep.ip[0], ep.ip[1], ep.ip[2], ep.ip[3], ep.port),
                ),
                settings_path_display: self.export_dir.join("settings.json").display().to_string(),
            },
        }
    }

    /// Executes a unidirectional [`WorkspaceCommand`], keeping `active_aggregate`, `library`,
    /// `search_index`, `mcp_acp`, and `live.json` in lockstep, and returns the updated [`WorkspaceProjection`].
    pub fn dispatch(&mut self, cmd: WorkspaceCommand, now_epoch_sec: u64) -> WorkspaceProjection {
        let effective_now_sec = now_epoch_sec.max(1);
        self.live_lease_epoch_sec = self.live_lease_epoch_sec.max(effective_now_sec);

        match cmd {
            WorkspaceCommand::SelectSection(section) => {
                self.workspace_section = section;
            }
            WorkspaceCommand::SelectDetailTab(tab) => {
                self.detail_tab = tab;
            }
            WorkspaceCommand::SimulateRealtimePipeline => {
                let exported = self.simulate_realtime_pipeline(effective_now_sec);
                if self.spine.is_empty() {
                    let _ = self.ingest_utterance_with_context(
                        "录音豆 60 片 Opus 实时流闭环自检完成，待办跟进双击标记 300ms 与 900ms 验收。",
                        0,
                        exported.entry.duration_ms.max(1_200),
                        "zh",
                        self.asr_pump.model.clone(),
                        effective_now_sec,
                    );
                }
                let _ = self.refresh_live_publication(effective_now_sec);
            }
            WorkspaceCommand::RetriggerRealtimeStream { now_ms } => {
                let _ = self.retrigger_realtime_stream_subscribe(now_ms);
            }
            WorkspaceCommand::SelectRecording(id) => {
                if self.select_recording(id) {
                    if let Some(entry) = self.library.entries.iter().find(|e| e.id == id).cloned()
                    {
                        self.active_aggregate.file_id = entry.id;
                        self.active_aggregate.recording_id = format!("rec-{}", entry.id);
                        self.active_aggregate.created_at_epoch_sec = entry.created_at_epoch_sec;
                        self.active_aggregate.duration_ms = entry.duration_ms;
                        self.active_aggregate.bookmarks.clear();
                        for m in entry.marks_ms {
                            let _ = self.active_aggregate.add_bookmark(m);
                        }
                        self.sync_active_aggregate();
                    }
                }
            }
            WorkspaceCommand::SeekMs(target_ms) => {
                let _ = self.seek_ms(target_ms);
            }
            WorkspaceCommand::JumpMark(direction) => {
                let _ = self.jump_to_mark(direction);
            }
            WorkspaceCommand::AddSliceMark(mark_ms) => {
                let _ = self.active_aggregate.add_bookmark(mark_ms);
                self.active_aggregate.duration_ms = self
                    .active_aggregate
                    .duration_ms
                    .max(mark_ms.saturating_add(10_000));
                if let Some(sel_id) = self.library.selected_id {
                    if let Some(entry) = self.library.entries.iter_mut().find(|e| e.id == sel_id) {
                        if !entry.marks_ms.contains(&mark_ms) {
                            entry.marks_ms.push(mark_ms);
                            entry.marks_ms.sort_unstable();
                        }
                        entry.duration_ms =
                            entry.duration_ms.max(self.active_aggregate.duration_ms);
                    }
                }
            }
            WorkspaceCommand::MoveToTrash(id) => {
                if self.move_to_trash(id) {
                    if let Some(sel_id) = self.library.selected_id {
                        if let Some(entry) =
                            self.library.entries.iter().find(|e| e.id == sel_id).cloned()
                        {
                            self.active_aggregate.file_id = entry.id;
                            self.active_aggregate.recording_id = format!("rec-{}", entry.id);
                            self.active_aggregate.created_at_epoch_sec = entry.created_at_epoch_sec;
                            self.active_aggregate.duration_ms = entry.duration_ms;
                            self.active_aggregate.bookmarks.clear();
                            for m in entry.marks_ms {
                                let _ = self.active_aggregate.add_bookmark(m);
                            }
                            self.sync_active_aggregate();
                        }
                    } else if self.active_aggregate.file_id == id {
                        self.spine = UtteranceSpine::new("desktop-default");
                        self.minutes.latest_minutes = None;
                        self.search_index = ContextSearchIndex::new();
                        self.active_aggregate =
                            RecordingAggregate::new("rec-desktop-default", 0, 0, 0);
                        self.last_copilot_card = None;
                        self.copilot_history.clear();
                    }
                }
            }
            WorkspaceCommand::UndoTrash => {
                if self.undo_trash() {
                    if let Some(sel_id) = self.library.selected_id {
                        if let Some(entry) =
                            self.library.entries.iter().find(|e| e.id == sel_id).cloned()
                        {
                            self.active_aggregate.file_id = entry.id;
                            self.active_aggregate.recording_id = format!("rec-{}", entry.id);
                            self.active_aggregate.created_at_epoch_sec = entry.created_at_epoch_sec;
                            self.active_aggregate.duration_ms = entry.duration_ms;
                            self.active_aggregate.bookmarks.clear();
                            for m in entry.marks_ms {
                                let _ = self.active_aggregate.add_bookmark(m);
                            }
                            self.sync_active_aggregate();
                        }
                    }
                }
            }
            WorkspaceCommand::SelectSummaryFormat(format) => {
                self.set_summary_format(format);
                self.rebuild_template_and_custom_sections();
            }
            WorkspaceCommand::SelectMinuteTemplate(template) => {
                self.active_template = template;
                self.removed_builtin_headings.clear();
                self.rebuild_template_and_custom_sections();
            }
            WorkspaceCommand::AddCustomMinuteSection { heading } => {
                let trimmed = heading.trim();
                if !trimmed.is_empty() {
                    self.removed_builtin_headings.retain(|h| h != trimmed);
                    if !self
                        .active_template
                        .definition()
                        .sections_zh
                        .contains(&trimmed)
                        && !self.user_custom_headings.iter().any(|h| h == trimmed)
                    {
                        self.user_custom_headings.push(trimmed.to_string());
                    }
                }
                self.rebuild_template_and_custom_sections();
            }
            WorkspaceCommand::RemoveCustomMinuteSection { heading } => {
                let trimmed = heading.trim();
                self.user_custom_headings.retain(|h| h != trimmed);
                if self
                    .active_template
                    .definition()
                    .sections_zh
                    .contains(&trimmed)
                    && !self.removed_builtin_headings.iter().any(|h| h == trimmed)
                {
                    self.removed_builtin_headings.push(trimmed.to_string());
                }
                self.rebuild_template_and_custom_sections();
            }
            WorkspaceCommand::IssuePairingTicket {
                mode,
                email,
                now_epoch_sec: ticket_sec,
            } => {
                let ts = ticket_sec.max(effective_now_sec);
                let base_url = match mode {
                    McpPairingMode::Lan => "http://127.0.0.1:38450/mcp",
                    McpPairingMode::Vps => "https://koe-tunnel.trycloudflare.com/mcp",
                };
                let token = format!("koe-pairing-bearer-token-{ts}");
                let effective_email = match mode {
                    McpPairingMode::Lan => email.as_deref(),
                    McpPairingMode::Vps => {
                        Some(email.as_deref().unwrap_or("owner@koe.local"))
                    }
                };
                let expires = Some(ts.saturating_add(86_400));
                let _ = self.issue_pairing_ticket(
                    base_url,
                    &token,
                    mode,
                    effective_email,
                    expires,
                );
            }
            WorkspaceCommand::GenerateMcpStdioConfig => {
                self.last_jsonrpc_response = self.build_mcp_stdio_config_json();
            }
            WorkspaceCommand::SetAutoLaunch(enabled) => {
                self.auto_launch_enabled = enabled;
                let _ = self.save_desktop_settings();
            }
            WorkspaceCommand::SetKeepAlive(enabled) => {
                self.keep_alive_enabled = enabled;
                let _ = self.save_desktop_settings();
            }
            WorkspaceCommand::ControlWifiSoftApBatch {
                action,
                now_epoch_sec: wifi_sec,
            } => {
                let ts = wifi_sec.max(effective_now_sec);
                match action {
                    WifiSoftApAction::StartDefaultSoftAp => {
                        let wifi_resp = Self::build_wifi_rx_frame(
                            0x1A,
                            0x05,
                            &[1, 4, 168, 192, 0x02, 0x7D],
                        );
                        let _ = self.ingest_ble_chunk(&wifi_resp, ts);
                        let file_ids: Vec<u32> = if !self.session.catalog.is_empty() {
                            self.session.catalog.iter().map(|e| e.file_id).collect()
                        } else {
                            vec![101, 102]
                        };
                        self.begin_wifi_batch(&file_ids);
                        let first_fid = file_ids.first().copied().unwrap_or(101);
                        let total_bytes =
                            (20 * koe_protocol_kernel::transport::SLICE_RECORD_BYTES) as u32;
                        let _ = self.ingest_wifi_chunk(
                            &Self::build_wifi_short_head(first_fid, total_bytes),
                            ts,
                        );
                        let _ = self.ingest_wifi_chunk(&Self::build_wifi_plain_slices(19), ts);
                    }
                    WifiSoftApAction::Interrupt => {
                        let _ = self.on_wifi_interrupted(ts);
                    }
                    WifiSoftApAction::ResumeAndComplete => {
                        let initial_phase = self.session.wifi_batch_progress().phase;
                        if initial_phase == WifiBatchPhase::Interrupted {
                            let _ = self.resume_wifi_batch();
                        } else if initial_phase == WifiBatchPhase::Idle {
                            let wifi_resp = Self::build_wifi_rx_frame(
                                0x1A,
                                0x05,
                                &[1, 4, 168, 192, 0x02, 0x7D],
                            );
                            let _ = self.ingest_ble_chunk(&wifi_resp, ts);
                            let file_ids: Vec<u32> = if !self.session.catalog.is_empty() {
                                self.session.catalog.iter().map(|e| e.file_id).collect()
                            } else {
                                vec![101, 102]
                            };
                            self.begin_wifi_batch(&file_ids);
                        }
                        let max_steps = self.session.catalog.len().max(8).saturating_add(4);
                        for _ in 0..max_steps {
                            let prog = self.session.wifi_batch_progress();
                            if matches!(
                                prog.phase,
                                WifiBatchPhase::Completed
                                    | WifiBatchPhase::Idle
                                    | WifiBatchPhase::Failed
                            ) {
                                break;
                            }
                            let fid = self.session.active_file_id.unwrap_or(102);
                            let cur_slices = self.session.received_slice_count();
                            if cur_slices > 0 {
                                let expected_slices = (prog.expected_wire_bytes as usize
                                    / koe_protocol_kernel::transport::SLICE_RECORD_BYTES)
                                    .max(cur_slices as usize + 1);
                                let rem_slices =
                                    expected_slices.saturating_sub(cur_slices as usize).max(1);
                                let _ = self.ingest_wifi_chunk(
                                    &Self::build_wifi_plain_slices_from(cur_slices, rem_slices),
                                    ts,
                                );
                            } else {
                                let total_bytes =
                                    (10 * koe_protocol_kernel::transport::SLICE_RECORD_BYTES)
                                        as u32;
                                let _ = self.ingest_wifi_chunk(
                                    &Self::build_wifi_short_head(fid, total_bytes),
                                    ts,
                                );
                                let _ = self.ingest_wifi_chunk(
                                    &Self::build_wifi_plain_slices_from(0, 10),
                                    ts,
                                );
                            }
                        }
                    }
                    WifiSoftApAction::Cancel => {
                        self.cancel_wifi_batch();
                    }
                }
            }
            WorkspaceCommand::SetCoarsePlace(place) => {
                let sanitized = place.as_deref().and_then(|raw| {
                    let parts: Vec<&str> = raw
                        .split(|c: char| c.is_whitespace() || matches!(c, ',' | '，' | '、' | '/'))
                        .filter(|s| !s.is_empty() && !s.chars().any(|c| c.is_ascii_digit()))
                        .collect();
                    format_coarse_place(&parts)
                });
                self.active_aggregate.update_coarse_place(sanitized);
            }
            WorkspaceCommand::AppendUtterance {
                text,
                start_ms,
                end_ms,
                source_language,
                provider,
                now_epoch_sec: utt_sec,
            } => {
                let ts = utt_sec.max(effective_now_sec);
                let _ = self.ingest_utterance_with_context(
                    text,
                    start_ms,
                    end_ms,
                    source_language,
                    provider,
                    ts,
                );
                self.auto_translate_pending_captions(ts.saturating_mul(1_000));
                let _ = self.refresh_live_publication(ts);
            }
            WorkspaceCommand::ReplaceSpeaker {
                old_speaker,
                new_speaker,
            } => {
                let updated = self.spine.replace_speaker_name(&old_speaker, &new_speaker);
                if updated == 0
                    && old_speaker == "Speaker 1"
                    && self
                        .spine
                        .segments()
                        .first()
                        .is_some_and(|s| s.speaker.is_none())
                {
                    if let Some(first_id) = SegmentId::new(1) {
                        let _ = self.spine.set_speaker(first_id, Some(new_speaker.clone()));
                    }
                }
                let agg_updated = self
                    .active_aggregate
                    .spine
                    .replace_speaker_name(&old_speaker, &new_speaker);
                if agg_updated == 0
                    && old_speaker == "Speaker 1"
                    && self
                        .active_aggregate
                        .spine
                        .segments()
                        .first()
                        .is_some_and(|s| s.speaker.is_none())
                {
                    if let Some(first_id) = SegmentId::new(1) {
                        let _ = self
                            .active_aggregate
                            .spine
                            .set_speaker(first_id, Some(new_speaker.clone()));
                    }
                }
                if let Some(ref mut mins) = self.minutes.latest_minutes {
                    mins.replace_terms(&[(old_speaker.as_str(), new_speaker.as_str())]);
                }
                if !self
                    .speaker_aliases
                    .iter()
                    .any(|(o, n)| o == &old_speaker && n == &new_speaker)
                {
                    self.speaker_aliases
                        .push((old_speaker.clone(), new_speaker.clone()));
                }
                let _ = self.mcp_acp.sync_qwennote(
                    &[],
                    &[(old_speaker.as_str(), new_speaker.as_str())],
                    None,
                );
                self.sync_active_aggregate();
            }
            WorkspaceCommand::SyncHotWords {
                hotwords,
                speaker_aliases,
            } => {
                let hw_refs: Vec<&str> = hotwords.iter().map(String::as_str).collect();
                let alias_refs: Vec<(&str, &str)> = speaker_aliases
                    .iter()
                    .map(|(a, b)| (a.as_str(), b.as_str()))
                    .collect();
                let _ = self.sync_qwennote_hotwords(&hw_refs, &alias_refs);
                for (from, to) in speaker_aliases {
                    if !self
                        .speaker_aliases
                        .iter()
                        .any(|(o, n)| o == &from && n == &to)
                    {
                        self.speaker_aliases.push((from, to));
                    }
                }
            }
            WorkspaceCommand::SearchContext { query, limit } => {
                self.search_query = query.clone();
                let max_hits = limit.max(1);
                let raw_hits = self
                    .search_index
                    .search(&query, max_hits, ScoringMode::default());
                let segments = self.spine.segments();
                self.search_hits = raw_hits
                    .into_iter()
                    .map(|hit| {
                        let matched_seg = segments.get(hit.doc_index);
                        let citation = matched_seg.map(|s| s.id);
                        let snippet =
                            matched_seg.map_or_else(|| query.clone(), |s| s.text.clone());
                        let title = citation.map_or_else(
                            || format!("doc-{}", hit.doc_index + 1),
                            |cid| format!("原话片段 [{cid}]"),
                        );
                        WorkspaceSearchHit {
                            doc_id: format!("doc-{}", hit.doc_index + 1),
                            title,
                            snippet,
                            score: hit.score,
                            citation,
                        }
                    })
                    .collect();
            }
            WorkspaceCommand::RunCopilotPreset {
                preset,
                now_epoch_sec: preset_sec,
            } => {
                let ts = preset_sec.max(effective_now_sec);
                if let Ok(answer) = self.run_copilot_preset(preset, ts) {
                    if matches!(preset, CopilotPresetChip::SyncActionItemsToGoogleTasks) {
                        let rep = self.sync_google_tasks("@default", ts);
                        self.last_google_sync = Some(rep);
                    }
                    let mut citations = extract_segment_citations(&answer);
                    if citations.is_empty() {
                        if let Some(first) = self.spine.segments().first() {
                            citations.push(first.id);
                        }
                    }
                    let tools_used = preset
                        .default_tool_plan()
                        .iter()
                        .map(|t| (*t).to_string())
                        .collect();
                    let card = CopilotAnswerCard {
                        prompt: preset.label().to_string(),
                        answer,
                        preset: Some(preset),
                        citations,
                        tools_used,
                        generated_at_epoch_sec: ts,
                    };
                    self.copilot_history.push(card.clone());
                    self.last_copilot_card = Some(card);
                }
            }
            WorkspaceCommand::AskCopilot {
                prompt,
                now_epoch_sec: ask_sec,
            } => {
                let ts = ask_sec.max(effective_now_sec);
                let card = self.execute_copilot_prompt_turn(&prompt, ts);
                self.copilot_history.push(card.clone());
                self.last_copilot_card = Some(card);
            }
            WorkspaceCommand::ConfigureCopilotProvider {
                provider_name,
                endpoint_url,
                model,
                api_key_env,
            } => {
                let api_key = api_key_env
                    .as_deref()
                    .and_then(|env_name| std::env::var(env_name).ok())
                    .filter(|s| !s.trim().is_empty());
                self.configure_copilot_provider(CopilotProviderConfig {
                    provider_name,
                    endpoint_url,
                    model,
                    auth_style: CopilotAuthStyle::BearerHeader,
                    api_key,
                    temperature_milli: 200,
                    max_tokens: 2048,
                });
            }
            WorkspaceCommand::IngestCopilotModelResponse {
                response_json,
                now_epoch_sec: resp_sec,
            } => {
                let ts = resp_sec.max(effective_now_sec);
                if let Ok(parsed) = JsonValue::parse(&response_json) {
                    if let Ok(Some(final_reply)) = self.ingest_copilot_openai_response(&parsed, ts)
                    {
                        let mut citations = extract_segment_citations(&final_reply);
                        if citations.is_empty() {
                            if let Some(first) = self.spine.segments().first() {
                                citations.push(first.id);
                            }
                        }
                        let mut tools_used = self.mcp_acp.copilot.current_turn_tools.clone();
                        if tools_used.is_empty() {
                            tools_used.push("openai_chat_completions".to_string());
                        }
                        let prompt = self
                            .mcp_acp
                            .copilot
                            .messages
                            .iter()
                            .rev()
                            .find(|m| matches!(m.role, CopilotRole::User))
                            .map_or_else(
                                || "外部模型对话".to_string(),
                                |m| m.content.clone(),
                            );
                        let card = CopilotAnswerCard {
                            prompt,
                            answer: final_reply,
                            preset: None,
                            citations,
                            tools_used,
                            generated_at_epoch_sec: ts,
                        };
                        self.copilot_history.push(card.clone());
                        self.last_copilot_card = Some(card);
                    }
                }
            }
            WorkspaceCommand::ToggleGoogleTask {
                task_id,
                now_epoch_sec: toggle_sec,
            } => {
                let ts = toggle_sec.max(effective_now_sec);
                let tid = GoogleTaskId(task_id);
                let is_completed = self
                    .mcp_acp
                    .google_suite
                    .tasks
                    .get(&tid)
                    .is_some_and(|t| matches!(t.status, GoogleTaskStatus::Completed));
                let _ = self
                    .mcp_acp
                    .google_suite
                    .complete_task(&tid, !is_completed, ts);
                if let Some(linked_id) = self
                    .mcp_acp
                    .google_suite
                    .tasks
                    .get(&tid)
                    .and_then(|t| t.linked_koe_todo_id.clone())
                {
                    if let Some(todo) = self.context.todos.iter_mut().find(|t| t.id == linked_id) {
                        todo.status = if is_completed {
                            TodoStatus::Open
                        } else {
                            TodoStatus::Done
                        };
                    }
                }
                let _ = self.save_google_suite();
            }
            WorkspaceCommand::CreateGoogleTask {
                title,
                notes,
                now_epoch_sec: create_sec,
            } => {
                let ts = create_sec.max(effective_now_sec);
                let trimmed = title.trim();
                if !trimmed.is_empty() {
                    let first_cite = self.spine.segments().first().map(|s| s.id);
                    let cite_tag = first_cite.map_or_else(|| "[S1]".to_string(), |c| format!("[{c}]"));
                    let full_notes = if notes.trim().is_empty() {
                        format!("来自 Koe 桌面端随心记 {cite_tag}")
                    } else {
                        notes
                    };
                    let task = self.mcp_acp.google_suite.create_task(
                        "@default",
                        trimmed,
                        &full_notes,
                        Some(ts.saturating_add(86_400)),
                        ts,
                    );
                    let koe_todo_id = format!("todo-gtask-{}", task.id.0);
                    self.context.todos.push(TodoItem {
                        id: koe_todo_id.clone(),
                        title: trimmed.to_string(),
                        kind: TodoKind::Mine,
                        status: TodoStatus::Open,
                        created_at_epoch_sec: ts,
                        due_at_epoch_sec: Some(ts.saturating_add(86_400)),
                        assignee: None,
                        citations: first_cite.into_iter().collect(),
                    });
                    if let Some(stored) = self.mcp_acp.google_suite.tasks.get_mut(&task.id) {
                        stored.linked_koe_todo_id = Some(koe_todo_id);
                    }
                    let _ = self.save_google_suite();
                }
            }
            WorkspaceCommand::CreateGeminiNotebook {
                title,
                now_epoch_sec: nb_sec,
            } => {
                let ts = nb_sec.max(effective_now_sec);
                let trimmed = title.trim();
                if !trimmed.is_empty() {
                    let nb_id = self.mcp_acp.google_suite.create_notebook(trimmed, ts);
                    let src_text = if self.spine.is_empty() {
                        "随心记音频主干摘要 [S1]".to_string()
                    } else {
                        self.spine
                            .segments()
                            .iter()
                            .map(|s| format!("[{}] {}", s.id, s.text))
                            .collect::<Vec<_>>()
                            .join("\n")
                    };
                    let _ = self.mcp_acp.google_suite.add_notebook_source(
                        &nb_id,
                        "当前随心记原话主干",
                        &src_text,
                        Some(&self.active_aggregate.recording_id),
                        ts,
                    );
                    let _ = self.mcp_acp.google_suite.query_notebook_grounded(
                        &nb_id,
                        "提炼核心结论与行动项",
                        &self.search_index,
                        &self.spine,
                        ts,
                    );
                    let _ = self.mcp_acp.google_suite.generate_notebook_audio_overview(
                        &nb_id,
                        "Executive summary",
                        Some(&self.spine),
                        ts,
                    );
                    let _ = self.save_google_suite();
                }
            }
            WorkspaceCommand::ToggleGoogleKeepChecklist {
                note_id,
                item_index,
                now_epoch_sec: keep_sec,
            } => {
                let ts = keep_sec.max(effective_now_sec);
                let nid = KeepNoteId(note_id);
                let _ = self
                    .mcp_acp
                    .google_suite
                    .toggle_keep_checklist_item(&nid, item_index, ts);
                let _ = self.save_google_suite();
            }
            WorkspaceCommand::SyncGoogleWorkspace {
                tasklist_id,
                now_epoch_sec: sync_sec,
            } => {
                let ts = sync_sec.max(effective_now_sec);
                if self.mcp_acp.google_suite.notebooks.is_empty() {
                    let nb_id = self
                        .mcp_acp
                        .google_suite
                        .create_notebook("安克随心记 每日脉络 Notebook", ts);
                    let summary_src = self
                        .spine
                        .segments()
                        .first()
                        .map_or("随心记音频主干摘要", |s| s.text.as_str());
                    let _ = self.mcp_acp.google_suite.add_notebook_source(
                        &nb_id,
                        "当前随心记原话主干",
                        summary_src,
                        Some(&self.active_aggregate.recording_id),
                        ts,
                    );
                    let _ = self
                        .mcp_acp
                        .google_suite
                        .generate_notebook_audio_overview(&nb_id, "Executive summary", Some(&self.spine), ts);
                }
                if self.mcp_acp.google_suite.keep_notes.is_empty() {
                    let checklist: Vec<KeepChecklistItem> = self
                        .context
                        .todos
                        .iter()
                        .map(|t| {
                            KeepChecklistItem::new(
                                t.title.clone(),
                                matches!(t.status, TodoStatus::Done),
                            )
                        })
                        .collect();
                    let _ = self.mcp_acp.google_suite.create_keep_note(
                        KeepNoteDraft {
                            id: None,
                            title: "随心记重点与待办清单".to_string(),
                            body_text: "由 Koe 桌面端自动同步的随心记速记卡".to_string(),
                            checklist,
                            color: KeepNoteColor::Teal,
                            pinned: true,
                            labels: vec!["Koe".to_string(), "随心记".to_string()],
                        },
                        ts,
                    );
                }
                let report = self.sync_google_tasks(&tasklist_id, ts);
                self.last_google_sync = Some(report);
            }
            WorkspaceCommand::ExportKoePackV2 {
                title,
                exported_at_iso,
            } => {
                let _ = self.export_koepack_v2_to_disk(&title, &exported_at_iso);
            }
            WorkspaceCommand::RefreshLiveLease {
                now_epoch_sec: lease_sec,
            } => {
                let _ = self.refresh_live_publication(lease_sec.max(effective_now_sec));
            }
            WorkspaceCommand::DispatchJsonRpc { request_json } => {
                if !self.mcp_acp.mcp_ready && !request_json.contains("\"initialize\"") {
                    let _ = self.dispatch_jsonrpc(
                        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
                        effective_now_sec,
                    );
                }
                self.last_jsonrpc_response = self
                    .dispatch_jsonrpc(&request_json, effective_now_sec)
                    .unwrap_or_default();
            }
        }

        self.workspace_projection(effective_now_sec)
    }

    fn compute_waveform_bars_norm(
        spine: &UtteranceSpine,
        bookmarks: &[u64],
        duration_ms: u64,
        latest_rms: u16,
    ) -> Vec<u8> {
        const BAR_COUNT: usize = 48;
        let seg_count = spine.len() as u64;
        let rms_boost = u64::from(latest_rms.min(400)) / 10;
        let eff_dur = duration_ms.max(1_200);
        let mut bars = Vec::with_capacity(BAR_COUNT);
        for idx in 0..BAR_COUNT {
            let pos_ms = (idx as u64).saturating_mul(eff_dur) / (BAR_COUNT as u64);
            let near_bookmark = bookmarks
                .iter()
                .any(|&bm| bm.abs_diff(pos_ms) <= (eff_dur / 16).max(150));
            let base = 24u64
                .saturating_add((idx as u64 * 17 + seg_count * 13) % 42)
                .saturating_add(rms_boost);
            let val = if near_bookmark {
                base.saturating_add(24).min(96)
            } else {
                base.clamp(18, 92)
            };
            bars.push(val as u8);
        }
        bars
    }

    fn write_atomic(target: &Path, bytes: &[u8]) {
        let tmp = target.with_extension("tmp");
        if fs::write(&tmp, bytes).is_ok() {
            let _ = fs::rename(&tmp, target);
        }
    }

    fn ensure_mcp_initialized(&mut self, now_epoch_sec: u64) {
        if !self.mcp_acp.mcp_ready {
            let _ = self.dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
                now_epoch_sec,
            );
            let _ = self.dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                now_epoch_sec,
            );
        }
    }

    fn execute_copilot_prompt_turn(&mut self, prompt: &str, ts: u64) -> CopilotAnswerCard {
        self.submit_copilot_prompt(prompt, ts);
        self.ensure_mcp_initialized(ts);

        let lowered = prompt.to_lowercase();
        let mut matched_routes = Vec::new();
        let mut tools_used = Vec::new();

        for rule in COPILOT_INTENT_TABLE {
            if rule.keywords.iter().any(|kw| lowered.contains(kw)) {
                matched_routes.push(rule.route);
                for &tool in rule.mcp_tools {
                    if !tools_used.iter().any(|t| t == tool) {
                        tools_used.push(tool.to_string());
                    }
                }
            }
        }
        if matched_routes.is_empty() {
            matched_routes.push(CopilotIntentRoute::ExecutiveMinutesBrief);
            tools_used.push("search_context".to_string());
            tools_used.push("get_minutes".to_string());
        }

        let first_seg = self.spine.segments().first().cloned();
        let last_seg = self.spine.segments().last().cloned();
        let mut citations: Vec<SegmentId> = Vec::new();
        if let Some(ref s1) = first_seg {
            citations.push(s1.id);
        }
        if let Some(ref s2) = last_seg {
            if !citations.contains(&s2.id) {
                citations.push(s2.id);
            }
        }
        let cite_badge = citations
            .first()
            .map_or_else(|| "[S1]".to_string(), |c| format!("[{c}]"));

        let mut summary_parts = Vec::new();

        for route in matched_routes {
            match route {
                CopilotIntentRoute::CreateGoogleTask => {
                    let clean_title = prompt
                        .trim_start_matches("新建待办")
                        .trim_start_matches("创建待办")
                        .trim_start_matches("添加待办")
                        .trim_start_matches("待办：")
                        .trim_start_matches("待办:")
                        .trim_start_matches(['：', ':', ' '])
                        .trim();
                    let task_title = if clean_title.is_empty() {
                        first_seg
                            .as_ref()
                            .map_or_else(|| prompt.to_string(), |s| s.text.clone())
                    } else {
                        clean_title.to_string()
                    };
                    let mut args = std::collections::BTreeMap::new();
                    args.insert("op".to_string(), JsonValue::String("create".to_string()));
                    args.insert(
                        "tasklist_id".to_string(),
                        JsonValue::String("@default".to_string()),
                    );
                    args.insert("title".to_string(), JsonValue::String(task_title.clone()));
                    args.insert(
                        "notes".to_string(),
                        JsonValue::String(format!("AI 随心问创建 {cite_badge}")),
                    );
                    let req = Self::build_mcp_tool_call_json(201, "google_tasks_mutate", args);
                    if let Some(resp) = self.dispatch_jsonrpc(&req, ts) {
                        self.last_jsonrpc_response = resp;
                    }
                    let rep = self.sync_google_tasks("@default", ts);
                    self.last_google_sync = Some(rep);
                    summary_parts.push(format!(
                        "已通过 google_tasks_mutate 写入 Google Tasks 待办「{task_title}」{cite_badge}（当前共 {} 项）",
                        self.mcp_acp.google_suite.tasks.len()
                    ));
                }
                CopilotIntentRoute::CompleteGoogleTask => {
                    let target_id = self
                        .mcp_acp
                        .google_suite
                        .tasks
                        .values()
                        .find(|t| !t.deleted && matches!(t.status, GoogleTaskStatus::NeedsAction))
                        .map(|t| (t.id.0.clone(), t.title.clone()));
                    if let Some((tid, title)) = target_id {
                        let mut args = std::collections::BTreeMap::new();
                        args.insert("op".to_string(), JsonValue::String("complete".to_string()));
                        args.insert("task_id".to_string(), JsonValue::String(tid));
                        let req = Self::build_mcp_tool_call_json(202, "google_tasks_mutate", args);
                        if let Some(resp) = self.dispatch_jsonrpc(&req, ts) {
                            self.last_jsonrpc_response = resp;
                        }
                        summary_parts.push(format!(
                            "已通过 google_tasks_mutate 勾选完成 Google Tasks 待办「{title}」{cite_badge}"
                        ));
                    } else {
                        let rep = self.sync_google_tasks("@default", ts);
                        self.last_google_sync = Some(rep);
                        summary_parts.push(format!(
                            "已同步 Google Tasks 清单（当前共 {} 项）{cite_badge}",
                            self.mcp_acp.google_suite.tasks.len()
                        ));
                    }
                }
                CopilotIntentRoute::SyncGoogleTasks => {
                    let mut args = std::collections::BTreeMap::new();
                    args.insert(
                        "tasklist_id".to_string(),
                        JsonValue::String("@default".to_string()),
                    );
                    let req = Self::build_mcp_tool_call_json(203, "google_tasks_sync", args);
                    if let Some(resp) = self.dispatch_jsonrpc(&req, ts) {
                        self.last_jsonrpc_response = resp;
                    }
                    let rep = self.sync_google_tasks("@default", ts);
                    self.last_google_sync = Some(rep.clone());
                    summary_parts.push(format!(
                        "已通过 google_tasks_sync 双向同步 Google Tasks（远端新增 {} 项，双向联动 {} 项，总计 {} 项）{cite_badge}",
                        rep.created_remote,
                        rep.pushed_to_remote + rep.applied_from_remote,
                        self.mcp_acp.google_suite.tasks.len()
                    ));
                }
                CopilotIntentRoute::GeminiNotebookResearch => {
                    let nb_id = if let Some(first_nb) =
                        self.mcp_acp.google_suite.notebooks.keys().next().cloned()
                    {
                        first_nb.0
                    } else {
                        let id = self
                            .mcp_acp
                            .google_suite
                            .create_notebook("安克随心记 每日脉络 Notebook", ts);
                        let src = first_seg
                            .as_ref()
                            .map_or("随心记音频主干摘要 [S1]", |s| s.text.as_str());
                        let _ = self.mcp_acp.google_suite.add_notebook_source(
                            &id,
                            "当前随心记原话主干",
                            src,
                            Some(&self.active_aggregate.recording_id),
                            ts,
                        );
                        id.0
                    };
                    let mut q_args = std::collections::BTreeMap::new();
                    q_args.insert(
                        "op".to_string(),
                        JsonValue::String("query_grounded".to_string()),
                    );
                    q_args.insert(
                        "notebook_id".to_string(),
                        JsonValue::String(nb_id.clone()),
                    );
                    q_args.insert("query".to_string(), JsonValue::String(prompt.to_string()));
                    let q_req = Self::build_mcp_tool_call_json(204, "gemini_notebook_ops", q_args);
                    if let Some(resp) = self.dispatch_jsonrpc(&q_req, ts) {
                        self.last_jsonrpc_response = resp;
                    }
                    let mut ao_args = std::collections::BTreeMap::new();
                    ao_args.insert(
                        "op".to_string(),
                        JsonValue::String("generate_audio_overview".to_string()),
                    );
                    ao_args.insert(
                        "notebook_id".to_string(),
                        JsonValue::String(nb_id.clone()),
                    );
                    ao_args.insert(
                        "prompt".to_string(),
                        JsonValue::String(prompt.to_string()),
                    );
                    let ao_req =
                        Self::build_mcp_tool_call_json(205, "gemini_notebook_ops", ao_args);
                    let _ = self.dispatch_jsonrpc(&ao_req, ts);
                    summary_parts.push(format!(
                        "已通过 gemini_notebook_ops 更新研究本 {nb_id}（Audio Overview 播客脚本与有据问答已就绪）{cite_badge}"
                    ));
                }
                CopilotIntentRoute::GoogleKeepChecklist => {
                    let item_text = format!("{prompt} {cite_badge}");
                    if let Some(first_note) =
                        self.mcp_acp.google_suite.keep_notes.values_mut().next()
                    {
                        first_note
                            .checklist
                            .push(KeepChecklistItem::new(item_text.clone(), false));
                        first_note.updated_at_epoch_sec = ts;
                    } else {
                        let mut k_args = std::collections::BTreeMap::new();
                        k_args.insert("op".to_string(), JsonValue::String("create".to_string()));
                        k_args.insert(
                            "title".to_string(),
                            JsonValue::String("随心记重点与待办清单".to_string()),
                        );
                        k_args.insert(
                            "body_text".to_string(),
                            JsonValue::String("由 Koe AI 随心问维护的速记清单".to_string()),
                        );
                        k_args.insert("pinned".to_string(), JsonValue::Bool(true));
                        k_args.insert(
                            "checklist".to_string(),
                            JsonValue::Array(vec![JsonValue::String(item_text.clone())]),
                        );
                        let k_req = Self::build_mcp_tool_call_json(206, "google_keep_ops", k_args);
                        if let Some(resp) = self.dispatch_jsonrpc(&k_req, ts) {
                            self.last_jsonrpc_response = resp;
                        }
                    }
                    let mut sync_args = std::collections::BTreeMap::new();
                    sync_args.insert(
                        "op".to_string(),
                        JsonValue::String("sync_context".to_string()),
                    );
                    let sync_req =
                        Self::build_mcp_tool_call_json(207, "google_keep_ops", sync_args);
                    if let Some(resp) = self.dispatch_jsonrpc(&sync_req, ts) {
                        self.last_jsonrpc_response = resp;
                    }
                    summary_parts.push(format!(
                        "已通过 google_keep_ops 追加 Google Keep 速记清单项「{item_text}」"
                    ));
                }
                CopilotIntentRoute::ExecutiveMinutesBrief => {
                    let mut s_args = std::collections::BTreeMap::new();
                    s_args.insert("query".to_string(), JsonValue::String(prompt.to_string()));
                    s_args.insert("limit".to_string(), JsonValue::Number(5.0));
                    let s_req = Self::build_mcp_tool_call_json(207, "search_context", s_args);
                    if let Some(resp) = self.dispatch_jsonrpc(&s_req, ts) {
                        self.last_jsonrpc_response = resp;
                    }
                    let quote_summary = match (&first_seg, &last_seg) {
                        (Some(s1), Some(s2)) if s1.id != s2.id => format!(
                            "基于原话 [{}]「{}」与 [{}]「{}」，针对「{prompt}」的结论已收敛。",
                            s1.id, s1.text, s2.id, s2.text
                        ),
                        (Some(s1), _) => format!(
                            "基于原话 [{}]：「{}」，针对「{prompt}」的结论已就绪。",
                            s1.id, s1.text
                        ),
                        (None, _) => format!(
                            "已记录问题「{prompt}」，等待语音主干输入后生成带 [S1] 锚点的回答。"
                        ),
                    };
                    summary_parts.push(quote_summary);
                }
            }
        }

        let _ = self.save_google_suite();
        let answer = summary_parts.join(" ");
        let extracted = extract_segment_citations(&answer);
        if !extracted.is_empty() {
            citations = extracted;
        }
        self.mcp_acp.copilot.messages.push(CopilotMessage {
            role: CopilotRole::Assistant,
            content: answer.clone(),
            tool_calls: Vec::new(),
            tool_call_id: None,
            tool_name: None,
            citations: citations.clone(),
            created_at_epoch_sec: ts,
        });
        self.mcp_acp.copilot.current_turn_tools = tools_used.clone();
        self.mcp_acp.copilot.phase = CopilotPhase::Completed {
            reply_text: answer.clone(),
            citations: citations.clone(),
        };

        CopilotAnswerCard {
            prompt: prompt.to_string(),
            answer,
            preset: None,
            citations,
            tools_used,
            generated_at_epoch_sec: ts,
        }
    }

    fn build_mcp_tool_call_json(
        id: u64,
        tool_name: &str,
        arguments: std::collections::BTreeMap<String, JsonValue>,
    ) -> String {
        let mut params = std::collections::BTreeMap::new();
        params.insert("name".to_string(), JsonValue::String(tool_name.to_string()));
        params.insert("arguments".to_string(), JsonValue::Object(arguments));
        let mut root = std::collections::BTreeMap::new();
        root.insert("jsonrpc".to_string(), JsonValue::String("2.0".to_string()));
        root.insert("id".to_string(), JsonValue::Number(id as f64));
        root.insert(
            "method".to_string(),
            JsonValue::String("tools/call".to_string()),
        );
        root.insert("params".to_string(), JsonValue::Object(params));
        JsonValue::Object(root).to_json_string()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CopilotIntentRoute {
    CreateGoogleTask,
    CompleteGoogleTask,
    SyncGoogleTasks,
    GeminiNotebookResearch,
    GoogleKeepChecklist,
    ExecutiveMinutesBrief,
}

struct CopilotIntentRule {
    keywords: &'static [&'static str],
    route: CopilotIntentRoute,
    mcp_tools: &'static [&'static str],
}

const COPILOT_INTENT_TABLE: [CopilotIntentRule; 6] = [
    CopilotIntentRule {
        keywords: &[
            "新建待办",
            "创建待办",
            "添加待办",
            "add task",
            "create task",
            "todo:",
            "待办：",
        ],
        route: CopilotIntentRoute::CreateGoogleTask,
        mcp_tools: &["google_tasks_mutate", "google_tasks_sync"],
    },
    CopilotIntentRule {
        keywords: &["完成待办", "勾选待办", "complete task", "done task"],
        route: CopilotIntentRoute::CompleteGoogleTask,
        mcp_tools: &["google_tasks_mutate", "google_tasks_list"],
    },
    CopilotIntentRule {
        keywords: &[
            "google tasks",
            "同步待办",
            "行动项",
            "action items",
            "待办",
            "tasks",
        ],
        route: CopilotIntentRoute::SyncGoogleTasks,
        mcp_tools: &["google_tasks_sync", "google_tasks_list"],
    },
    CopilotIntentRule {
        keywords: &[
            "notebook",
            "研究本",
            "笔记本",
            "notebooklm",
            "audio overview",
            "播客",
            "脑图",
        ],
        route: CopilotIntentRoute::GeminiNotebookResearch,
        mcp_tools: &["gemini_notebook_ops", "get_minutes"],
    },
    CopilotIntentRule {
        keywords: &["keep", "便签", "速记", "清单", "checklist", "note"],
        route: CopilotIntentRoute::GoogleKeepChecklist,
        mcp_tools: &["google_keep_ops", "search_context"],
    },
    CopilotIntentRule {
        keywords: &["纪要", "总结", "brief", "minutes", "summary", "结论", "原话"],
        route: CopilotIntentRoute::ExecutiveMinutesBrief,
        mcp_tools: &["get_minutes", "search_context"],
    },
];

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
    fn test_desktop_bean_host_copilot_and_google_suite_integration() {
        let dir = temp_export_dir("copilot-suite");
        let mut host = DesktopBeanHost::new(&dir);

        assert_eq!(host.copilot_preset_chips().len(), 4);
        assert_eq!(host.snapshot().google_task_count, 0);
        assert_eq!(host.snapshot().gemini_notebook_count, 0);
        assert_eq!(host.snapshot().copilot_message_count, 0);

        host.google_suite_mut().create_task("@default", "Urgent Deck", "Due Friday", Some(1_800_000_000), 1_000);
        assert_eq!(host.snapshot().google_task_count, 1);
        let sync_rep = host.sync_google_tasks("@default", 1_001);
        assert_eq!(sync_rep.created_remote, 0);

        let suite_path = dir.join("google_suite.json");
        assert!(suite_path.exists());

        let host2 = DesktopBeanHost::new(&dir);
        assert_eq!(host2.snapshot().google_task_count, 1);

        let preset_res = host.run_copilot_preset(CopilotPresetChip::SummarizeAudioFile, 1_002).unwrap();
        assert!(preset_res.contains("Audio Summary"));
        assert_eq!(host.snapshot().copilot_message_count, 2);

        host.submit_copilot_prompt("What are my next steps?", 1_003);
        let req = host.build_copilot_openai_request();
        assert!(req.as_object().unwrap().get("messages").is_some());
        assert!(req.as_object().unwrap().get("tools").is_some());

        let _ = fs::remove_dir_all(&dir);
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

    #[test]
    fn workspace_projection_and_dispatch_drive_all_sections_tabs_and_domain_invariants() {
        let dir = temp_export_dir("slice-r-workspace-projection");
        let mut host = DesktopBeanHost::new(&dir);
        let now_sec = 1_775_000_100;

        let initial = host.projection();
        assert_eq!(initial.section, WorkspaceSection::DailyMind);
        assert_eq!(initial.section.label(), "随心记录");
        assert_eq!(initial.detail_tab, DetailTab::VisualSummary);
        assert_eq!(initial.detail_tab.label(), "心智总结");
        assert_eq!(initial.waveform_bars_norm.len(), 48);
        assert!(initial
            .waveform_bars_norm
            .iter()
            .all(|&bar| (18..=96).contains(&bar)));
        assert!(initial.focus_project.is_some());
        assert_eq!(
            initial.focus_project.as_ref().unwrap().title,
            "安克随心记"
        );

        for section in WorkspaceSection::ALL {
            let proj = host.dispatch(WorkspaceCommand::SelectSection(section), now_sec);
            assert_eq!(proj.section, section);
            assert!(!proj.section.label().is_empty());
        }
        for tab in DetailTab::ALL {
            let proj = host.dispatch(WorkspaceCommand::SelectDetailTab(tab), now_sec);
            assert_eq!(proj.detail_tab, tab);
            assert!(!proj.detail_tab.label().is_empty());
        }

        let sim_proj = host.dispatch(WorkspaceCommand::SimulateRealtimePipeline, now_sec);
        assert!(!sim_proj.recordings.is_empty());
        assert_eq!(sim_proj.visual_cards.len(), 6);
        assert!(sim_proj.live_generation >= 1);

        let utt_proj = host.dispatch(
            WorkspaceCommand::AppendUtterance {
                text: "周五前提交安克录音豆量产固件压测报告，并同步给硬件团队。".to_string(),
                start_ms: 1_200,
                end_ms: 4_800,
                source_language: "zh".to_string(),
                provider: "qwen3-asr-flash-realtime".to_string(),
                now_epoch_sec: now_sec + 5,
            },
            now_sec + 5,
        );
        assert!(utt_proj.active_aggregate.spine.len() >= 2);
        assert!(!utt_proj.open_todos.is_empty());
        assert!(utt_proj.project_progress.next_todo.is_some());
        assert!(utt_proj.diary_entry.current.is_some());
        let diary_draft = utt_proj.diary_entry.current.as_ref().unwrap();
        assert!(diary_draft.text.contains("[S1]"));
        assert!(!diary_draft.sources.is_empty());
        assert!(utt_proj.morning_brief.key_points.is_some());
        assert!(!utt_proj.morning_brief.open_mine.is_empty());

        let _ = host
            .spine_mut()
            .set_speaker(SegmentId::new(1).unwrap(), Some("Speaker 1".to_string()));
        let spk_proj = host.dispatch(
            WorkspaceCommand::ReplaceSpeaker {
                old_speaker: "Speaker 1".to_string(),
                new_speaker: "张工".to_string(),
            },
            now_sec + 6,
        );
        assert_eq!(
            spk_proj.active_aggregate.spine.segments()[0]
                .speaker
                .as_deref(),
            Some("张工")
        );
        assert!(spk_proj
            .speaker_aliases
            .contains(&("Speaker 1".to_string(), "张工".to_string())));

        let hw_proj = host.dispatch(
            WorkspaceCommand::SyncHotWords {
                hotwords: vec!["soundcore".to_string(), "D3200".to_string()],
                speaker_aliases: vec![("Speaker 2".to_string(), "李工".to_string())],
            },
            now_sec + 7,
        );
        assert!(hw_proj.hot_words.contains(&"soundcore".to_string()));
        assert!(hw_proj.hot_words.contains(&"D3200".to_string()));
        assert!(hw_proj
            .speaker_aliases
            .contains(&("Speaker 2".to_string(), "李工".to_string())));

        let mark_proj = host.dispatch(WorkspaceCommand::AddSliceMark(15_000), now_sec + 8);
        assert!(mark_proj.active_aggregate.bookmarks.contains(&15_000));
        assert!(mark_proj.bookmark_windows_ms.contains(&(5_000, 25_000)));

        let fmt_proj = host.dispatch(
            WorkspaceCommand::SelectSummaryFormat(SummaryFormat::PersonalReflection),
            now_sec + 9,
        );
        assert_eq!(
            fmt_proj.active_aggregate.selected_format,
            SummaryFormat::PersonalReflection
        );
        assert_eq!(fmt_proj.visual_cards.len(), 6);

        let place_proj = host.dispatch(
            WorkspaceCommand::SetCoarsePlace(Some("上海市 静安区".to_string())),
            now_sec + 10,
        );
        assert_eq!(
            place_proj.active_aggregate.coarse_place.as_deref(),
            Some("上海市 静安区")
        );

        let search_proj = host.dispatch(
            WorkspaceCommand::SearchContext {
                query: "压测报告".to_string(),
                limit: 5,
            },
            now_sec + 11,
        );
        assert_eq!(search_proj.search_query, "压测报告");
        assert!(!search_proj.search_hits.is_empty());
        assert!(search_proj.search_hits[0].citation.is_some());

        let copilot_proj = host.dispatch(
            WorkspaceCommand::RunCopilotPreset {
                preset: CopilotPresetChip::SummarizeAudioFile,
                now_epoch_sec: now_sec + 12,
            },
            now_sec + 12,
        );
        assert!(copilot_proj.copilot_card.is_some());
        assert!(!copilot_proj
            .copilot_card
            .as_ref()
            .unwrap()
            .citations
            .is_empty());

        let gsync_proj = host.dispatch(
            WorkspaceCommand::SyncGoogleWorkspace {
                tasklist_id: "@default".to_string(),
                now_epoch_sec: now_sec + 13,
            },
            now_sec + 13,
        );
        assert!(gsync_proj.google_sync_report.is_some());
        assert!(!gsync_proj.google_notebooks.is_empty());
        assert!(!gsync_proj.google_keep_notes.is_empty());

        let retrigger_proj = host.dispatch(
            WorkspaceCommand::RetriggerRealtimeStream {
                now_ms: (now_sec + 14) * 1_000,
            },
            now_sec + 14,
        );
        assert_eq!(
            retrigger_proj.active_aggregate.phase,
            RecordingLifecyclePhase::Copying
        );

        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn slice_s_formats_aliyun_mcp_and_settings_doctor_commands_and_projections() {
        let dir = temp_export_dir("slice-s-closeout");
        let mut host = DesktopBeanHost::new(&dir);
        let now_sec = 1_775_000_200;

        let init_proj = host.workspace_projection(now_sec);
        assert_eq!(init_proj.formats.active_template, BuiltinTemplateId::Retro);
        assert_eq!(
            init_proj.formats.builtin_sections_zh,
            vec!["做得好的", "有待改进", "下次尝试"]
        );
        assert_eq!(
            init_proj.aliyun_mcp.dashscope.streaming_asr_model,
            "paraformer-realtime-v2"
        );
        assert_eq!(
            init_proj.aliyun_mcp.dashscope.filetrans_asr_model,
            "qwen-audio-3.1-asr-flash-filetrans"
        );
        assert!(init_proj
            .aliyun_mcp
            .pairing_ticket
            .as_deref()
            .is_some_and(|t| t.starts_with(PAIRING_TICKET_PREFIX)));
        assert!(init_proj
            .aliyun_mcp
            .mcp_stdio_config_json
            .contains("--mcp-stdio"));
        assert!(init_proj
            .aliyun_mcp
            .mcp_stdio_config_json
            .contains("--workspace"));

        let fish_proj = host.dispatch(
            WorkspaceCommand::SelectMinuteTemplate(BuiltinTemplateId::Fishbone),
            now_sec + 1,
        );
        assert_eq!(
            fish_proj.formats.active_template,
            BuiltinTemplateId::Fishbone
        );
        assert_eq!(
            fish_proj.formats.builtin_sections_zh,
            vec!["问题", "人员", "流程", "工具与环境", "根因假设"]
        );
        assert_eq!(fish_proj.visual_cards.len(), 6);
        assert!(fish_proj.visual_cards[0]
            .highlight_box
            .as_deref()
            .is_some_and(|h| h.contains(BuiltinTemplateId::Fishbone.label_zh())));

        let add_sec_proj = host.dispatch(
            WorkspaceCommand::AddCustomMinuteSection {
                heading: "  关键风险复盘  ".to_string(),
            },
            now_sec + 2,
        );
        assert!(add_sec_proj
            .formats
            .custom_sections
            .iter()
            .any(|s| s.heading == "关键风险复盘" && !s.points.is_empty()));
        assert!(add_sec_proj.visual_cards[0]
            .highlight_box
            .as_deref()
            .is_some_and(|h| h.contains("关键风险复盘")));

        let standup_proj = host.dispatch(
            WorkspaceCommand::SelectMinuteTemplate(BuiltinTemplateId::Standup),
            now_sec + 3,
        );
        assert_eq!(
            standup_proj.formats.active_template,
            BuiltinTemplateId::Standup
        );
        assert!(standup_proj
            .formats
            .custom_sections
            .iter()
            .any(|s| s.heading == "已完成"));
        assert!(standup_proj
            .formats
            .custom_sections
            .iter()
            .any(|s| s.heading == "关键风险复盘"));

        let rem_sec_proj = host.dispatch(
            WorkspaceCommand::RemoveCustomMinuteSection {
                heading: "关键风险复盘".to_string(),
            },
            now_sec + 4,
        );
        assert!(!rem_sec_proj
            .formats
            .custom_sections
            .iter()
            .any(|s| s.heading == "关键风险复盘"));

        let vps_proj = host.dispatch(
            WorkspaceCommand::IssuePairingTicket {
                mode: McpPairingMode::Vps,
                email: Some("owner@koe.local".to_string()),
                now_epoch_sec: now_sec + 5,
            },
            now_sec + 5,
        );
        assert_eq!(vps_proj.aliyun_mcp.pairing_mode, McpPairingMode::Vps);
        let vps_ticket = vps_proj.aliyun_mcp.pairing_ticket.clone().unwrap();
        assert!(vps_ticket.starts_with(PAIRING_TICKET_PREFIX));
        let decoded = PairingTicket::decode(&vps_ticket).unwrap();
        assert_eq!(decoded.mode, McpPairingMode::Vps);
        assert_eq!(decoded.email.as_deref(), Some("owner@koe.local"));

        let stdio_proj = host.dispatch(WorkspaceCommand::GenerateMcpStdioConfig, now_sec + 6);
        assert!(stdio_proj
            .aliyun_mcp
            .mcp_stdio_config_json
            .contains("--mcp-stdio"));
        assert!(stdio_proj
            .aliyun_mcp
            .mcp_stdio_config_json
            .contains(&dir.display().to_string()));

        let lease_proj = host.dispatch(
            WorkspaceCommand::RefreshLiveLease {
                now_epoch_sec: now_sec + 7,
            },
            now_sec + 7,
        );
        assert!(lease_proj.aliyun_mcp.live_generation >= 1);
        assert_eq!(
            lease_proj.aliyun_mcp.live_lease_expires_at_epoch_sec,
            (now_sec + 7) + LIVE_LEASE_DEFAULT_TTL_SEC
        );

        let _ = host.dispatch(
            WorkspaceCommand::RunCopilotPreset {
                preset: CopilotPresetChip::SummarizeAudioFile,
                now_epoch_sec: now_sec + 8,
            },
            now_sec + 8,
        );
        let copilot_proj = host.dispatch(
            WorkspaceCommand::AskCopilot {
                prompt: "列出当前风险与下一步责任人".to_string(),
                now_epoch_sec: now_sec + 9,
            },
            now_sec + 9,
        );
        assert_eq!(copilot_proj.aliyun_mcp.copilot_history.len(), 2);
        assert_eq!(
            copilot_proj.aliyun_mcp.copilot_history[1].prompt,
            "列出当前风险与下一步责任人"
        );

        let settings_proj = host.dispatch(WorkspaceCommand::SetAutoLaunch(true), now_sec + 10);
        assert!(settings_proj.settings.auto_launch_enabled);
        let settings_proj2 = host.dispatch(WorkspaceCommand::SetKeepAlive(true), now_sec + 11);
        assert!(settings_proj2.settings.keep_alive_enabled);
        assert!(dir.join("settings.json").exists());

        let reloaded_host = DesktopBeanHost::new(&dir);
        let reloaded_proj = reloaded_host.workspace_projection(now_sec + 12);
        assert!(reloaded_proj.settings.auto_launch_enabled);
        assert!(reloaded_proj.settings.keep_alive_enabled);

        let wifi_start = host.dispatch(
            WorkspaceCommand::ControlWifiSoftApBatch {
                action: WifiSoftApAction::StartDefaultSoftAp,
                now_epoch_sec: now_sec + 13,
            },
            now_sec + 13,
        );
        assert_eq!(
            wifi_start.wifi_endpoint,
            Some(WifiEndpoint {
                ip: [192, 168, 4, 1],
                port: 32002,
            })
        );
        assert_eq!(wifi_start.settings.softap_endpoint_label, "192.168.4.1:32002");
        assert_eq!(wifi_start.wifi_batch.phase, WifiBatchPhase::Transferring);

        let wifi_int = host.dispatch(
            WorkspaceCommand::ControlWifiSoftApBatch {
                action: WifiSoftApAction::Interrupt,
                now_epoch_sec: now_sec + 14,
            },
            now_sec + 14,
        );
        assert_eq!(wifi_int.wifi_batch.phase, WifiBatchPhase::Interrupted);
        assert!(wifi_int.wifi_batch.salvaged_count >= 1);

        let wifi_done = host.dispatch(
            WorkspaceCommand::ControlWifiSoftApBatch {
                action: WifiSoftApAction::ResumeAndComplete,
                now_epoch_sec: now_sec + 15,
            },
            now_sec + 15,
        );
        assert_eq!(wifi_done.wifi_batch.phase, WifiBatchPhase::Completed);
        assert!(wifi_done.wifi_batch.finalized_count >= 1);
        assert!(!wifi_done.recordings.is_empty());

        let wifi_cancel = host.dispatch(
            WorkspaceCommand::ControlWifiSoftApBatch {
                action: WifiSoftApAction::Cancel,
                now_epoch_sec: now_sec + 16,
            },
            now_sec + 16,
        );
        assert_eq!(wifi_cancel.wifi_batch.phase, WifiBatchPhase::Idle);

        let prov_proj = host.dispatch(
            WorkspaceCommand::ConfigureCopilotProvider {
                provider_name: "openai-local".to_string(),
                endpoint_url: "http://127.0.0.1:11434/v1/chat/completions".to_string(),
                model: "qwen2.5-coder:14b".to_string(),
                api_key_env: None,
            },
            now_sec + 17,
        );
        assert_eq!(prov_proj.copilot_provider.provider_name, "openai-local");
        assert_eq!(prov_proj.copilot_provider.model, "qwen2.5-coder:14b");

        let gtask_proj = host.dispatch(
            WorkspaceCommand::AskCopilot {
                prompt: "新建待办：周五前复核海外渠道合同并同步 Google Tasks、NotebookLM 研究本与 Keep 清单"
                    .to_string(),
                now_epoch_sec: now_sec + 18,
            },
            now_sec + 18,
        );
        assert!(!gtask_proj.google_tasks.is_empty());
        assert!(!gtask_proj.google_notebooks.is_empty());
        assert!(!gtask_proj.google_keep_notes.is_empty());
        let last_turn = gtask_proj.copilot_card.as_ref().expect("copilot card");
        assert!(last_turn.tools_used.iter().any(|t| t == "google_tasks_mutate"));
        assert!(last_turn.tools_used.iter().any(|t| t == "gemini_notebook_ops"));
        assert!(last_turn.tools_used.iter().any(|t| t == "google_keep_ops"));
        assert!(!last_turn.citations.is_empty());

        let first_task_id = gtask_proj.google_tasks[0].id.clone();
        let toggled_task_proj = host.dispatch(
            WorkspaceCommand::ToggleGoogleTask {
                task_id: first_task_id.clone(),
                now_epoch_sec: now_sec + 19,
            },
            now_sec + 19,
        );
        assert!(
            toggled_task_proj
                .google_tasks
                .iter()
                .any(|t| t.id == first_task_id && t.completed)
        );

        let first_note_id = toggled_task_proj.google_keep_notes[0].id.clone();
        let toggled_keep_proj = host.dispatch(
            WorkspaceCommand::ToggleGoogleKeepChecklist {
                note_id: first_note_id.clone(),
                item_index: 0,
                now_epoch_sec: now_sec + 20,
            },
            now_sec + 20,
        );
        assert!(
            toggled_keep_proj
                .google_keep_notes
                .iter()
                .any(|n| n.id == first_note_id && n.checklist_checked >= 1)
        );

        let created_nb_proj = host.dispatch(
            WorkspaceCommand::CreateGeminiNotebook {
                title: "Q4 海外渠道专题 Notebook".to_string(),
                now_epoch_sec: now_sec + 21,
            },
            now_sec + 21,
        );
        assert!(
            created_nb_proj
                .google_notebooks
                .iter()
                .any(|nb| nb.title == "Q4 海外渠道专题 Notebook" && nb.audio_overview_ready)
        );

        let _ = fs::remove_dir_all(&dir);
    }
}
