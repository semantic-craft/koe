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
    CICADA_MAX_CALLS_PER_HOUR, CICADA_ROLLING_CHAR_THRESHOLD, CICADA_ROLLING_INTERVAL_SEC,
    CICADA_SILENCE_AUTO_STOP_MS,
};
pub use koe_protocol_kernel::commands::DeviceCommands;
pub use koe_protocol_kernel::context::{
    filter_open_mine_todos, sort_context_timeline, ContextEvent, ContextOutcome, ContextReducer,
    ContextState,
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
    is_supported_mcp_tool, McpAcpEvent, McpAcpOutcome, McpAcpReducer, McpAcpState, KOE_MCP_TOOLS,
};
pub use koe_protocol_kernel::minutes::{
    contains_calculation_phrase, contains_percentage, validate_calculation_grounding,
    validate_minutes_grounding, MinutesEvent, MinutesOutcome, MinutesReducer, MinutesState,
    MinutesValidationError,
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
}

/// Stateful desktop host controller combining [`TransportSession`], [`RecordingLibrary`],
/// and atomic `.opus`/`.wav` disk export.
#[derive(Debug, Clone)]
pub struct DesktopBeanHost {
    session: TransportSession,
    library: RecordingLibrary,
    spine: UtteranceSpine,
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
        self.spine
            .append_segment(text, start_ms, end_ms, source_language, provider)
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
}
