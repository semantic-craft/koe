//! Desktop host bridge connecting `koe_core` (`koe_protocol_kernel`) to the
//! GPUI desktop application, atomic `.opus`/`.wav` disk export, and local
//! recording library state machine.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

pub use koe_protocol_kernel::cicada::{
    pending_translation_segments, CicadaEvent, CicadaOutcome, CicadaReducer, CicadaState,
    RollingMinutesScheduler, CICADA_MAX_CALLS_PER_HOUR, CICADA_ROLLING_CHAR_THRESHOLD,
    CICADA_ROLLING_INTERVAL_SEC, CICADA_SILENCE_AUTO_STOP_MS,
};
pub use koe_protocol_kernel::commands::DeviceCommands;
pub use koe_protocol_kernel::context::{
    filter_open_mine_todos, sort_context_timeline, ContextEvent, ContextOutcome, ContextReducer,
    ContextSearchIndex, ContextState, ScoringMode,
};
pub use koe_protocol_kernel::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
pub use koe_protocol_kernel::domain::{
    AiProviderCommand, ContextItem, ContextKind, ContextSource, MeetingMinutesV2, MinuteCause,
    MinuteCustomSection, MinuteFishbone, MinutePoint, MinuteTerm, MinuteTermAdoption, MinuteTopic,
    SegmentId, TodoItem, TodoKind, TodoStatus, UtteranceSegment, UtteranceSpine,
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
    contains_calculation_phrase, contains_percentage, validate_calculation_grounding,
    validate_minutes_grounding, JsonValue, MinutesEvent, MinutesOutcome, MinutesReducer,
    MinutesState, MinutesValidationError, BUILTIN_MINUTE_TEMPLATES,
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
}

/// Stateful desktop host controller combining [`TransportSession`], [`RecordingLibrary`],
/// and atomic `.opus`/`.wav` disk export.
#[derive(Debug, Clone)]
pub struct DesktopBeanHost {
    session: TransportSession,
    library: RecordingLibrary,
    spine: UtteranceSpine,
    minutes: MinutesState,
    cicada: CicadaState,
    rolling_scheduler: RollingMinutesScheduler,
    context: ContextState,
    search_index: ContextSearchIndex,
    mcp_acp: McpAcpState,
    export_dir: PathBuf,
    exported_files: Vec<DesktopExportedRecording>,
}

impl DesktopBeanHost {
    /// Creates a new desktop bean host backed by `export_dir`.
    #[must_use]
    pub fn new(export_dir: impl Into<PathBuf>) -> Self {
        Self::with_decoder_factory(export_dir, None)
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
            rolling_scheduler: RollingMinutesScheduler::new("desktop-default"),
            context: ContextState::default(),
            search_index: ContextSearchIndex::new(),
            mcp_acp: McpAcpState::new(),
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

    /// Appends a finalized utterance segment and indexes it across `spine`, `rolling_scheduler`, `context`, and `search_index`.
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
        let _ = self.rolling_scheduler.append_segment(
            &seg_id.to_string(),
            &text_str,
            now_epoch_sec.saturating_mul(1_000),
        );
        let _ = self.search_index.add_document(&text_str);
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
        Some(seg_id)
    }

    /// Applies a [`MinutesEvent`] to the host's [`MinutesState`] against `self.spine`.
    pub fn reduce_minutes(&mut self, event: MinutesEvent) -> MinutesOutcome {
        MinutesState::reduce(&mut self.minutes, &self.spine, event)
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
        Ok(summary)
    }

    /// Scans `export_dir` for `*.koepack` files and registers valid archives into `mcp_acp`.
    pub fn load_existing_packs(&mut self) -> std::io::Result<usize> {
        if !self.export_dir.exists() {
            return Ok(0);
        }
        let mut loaded = 0usize;
        for dir_entry in fs::read_dir(&self.export_dir)? {
            let dir_entry = dir_entry?;
            let path = dir_entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("koepack") {
                continue;
            }
            let Some(stem) = path.file_stem().and_then(|s| s.to_str()) else {
                continue;
            };
            let bytes = fs::read(&path)?;
            if self.mcp_acp.put_sync_pack(stem, &bytes).is_ok() {
                loaded += 1;
            }
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
        self.mcp_acp
            .dispatch_jsonrpc(&mut view, raw_json, now_epoch_sec)
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

    /// Sends `01/05` pause/stop and enters the 2,000 ms realtime quiet-drain window.
    pub fn stop_realtime_recording(&mut self) -> SessionIngestOutcome {
        self.session.stop_realtime_recording()
    }

    /// Ingests a raw BLE notification chunk and atomically persists any finalized recordings.
    pub fn ingest_ble_chunk(&mut self, chunk: &[u8], now_epoch_sec: u64) -> SessionIngestOutcome {
        let outcome = self.session.ingest_ble_chunk(chunk, now_epoch_sec);
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
        self.drain_finalized_to_disk()
            .into_iter()
            .last()
            .expect("simulated realtime pipeline must export recording")
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

    /// Captures a value snapshot of the transport, Wi-Fi batch, and local library state.
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
        }
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
        let _ = fs::create_dir_all(&self.export_dir);
        let id = fin.entry.id;
        let opus_path = self.export_dir.join(format!("{id}.opus"));
        let wav_path = self.export_dir.join(format!("{id}.wav"));
        Self::write_atomic(&opus_path, &fin.ogg_opus_bytes);
        Self::write_atomic(&wav_path, &fin.preview_wav_bytes);
        self.library.ingest(fin.entry.clone());
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

        let (pack_summary, pack_path) = host
            .export_koepack_v2_to_disk("海外渠道合同", "2026-11-07T18:00:00Z")
            .unwrap();
        assert!(pack_path.exists());

        let mut fresh_host = DesktopBeanHost::new(&dir);
        assert_eq!(fresh_host.load_existing_packs().unwrap(), 1);
        assert_eq!(fresh_host.snapshot().pack_count, 1);

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
}
