//! Stateful D3200 transport session state machine (`01/01` telemetry, `2E/01` ECDH
//! handshake verification, `1A/01`–`1B/0E` offline catalog, `1A/07` encrypted file
//! head, `1A/08` 166-byte slice decryptor & mark accumulator, and `1A/0A` Ogg Opus/WAV
//! finalizer).

mod catalog;
mod handshake;
mod ingest;
mod transfer;
mod types;
#[cfg(test)]
mod tests;

pub use types::*;

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use crate::commands::{DeviceCommands, RxCmd};
use crate::frame::FrameReassembler;
use crate::models::{DeviceInfoModel, OfflineFileEntry};
use crate::transport::OPUS_FRAME_BYTES;
use crate::wav::{ASR_SAMPLE_RATE, OpusDecoderFactory, OpusStreamDecoder};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
enum RealtimePause {
    #[default]
    Running,
    Requested,
    Paused,
}

/// Stateful D3200 transport session engine.
pub struct TransportSession {
    pub(in crate::session) capture_events: VecDeque<CaptureEvent>,
    pub(in crate::session) file_decryption: BTreeMap<u32, FileDecryption>,
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
    realtime_pause: RealtimePause,
    /// Whether the session is awaiting the next `1A/0E` or `1B/0E` catalog response to subscribe to the newest active file in realtime mode.
    pub pending_realtime_subscribe: bool,
    /// Accumulated decrypted 160-byte Opus frames.
    pub opus_buffer: Vec<u8>,
    /// Sorted, deduplicated double-tap mark positions in milliseconds.
    pub marks_ms: Vec<u64>,
    /// FIFO queue of finalized recordings produced during multi-file batches.
    pub finalized_queue: VecDeque<FinalizedRecording>,
    custody_receipts: BTreeMap<u32, VerifiedCustodyReceipt>,
    pub(super) decoder_factory: Option<OpusDecoderFactory>,
    pub(super) live_decoder_16k: Option<Box<dyn OpusStreamDecoder>>,
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
            file_decryption: self.file_decryption.clone(),
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
            stream_base_slices: self.stream_base_slices,
            transfer: self.transfer,
            runtime_state: self.runtime_state.clone(),
            active_file_id: self.active_file_id,
            active_file_key: self.active_file_key,
            active_nonce: self.active_nonce,
            active_is_realtime: self.active_is_realtime,
            device_recording_active: self.device_recording_active,
            realtime_pause: self.realtime_pause,
            pending_realtime_subscribe: self.pending_realtime_subscribe,
            opus_buffer: self.opus_buffer.clone(),
            marks_ms: self.marks_ms.clone(),
            finalized_queue: self.finalized_queue.clone(),
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
            .field("has_session_key", &self.session_key.is_some())
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
            .field("has_active_file_key", &self.active_file_key.is_some())
            .field("active_nonce", &self.active_nonce)
            .field("active_is_realtime", &self.active_is_realtime)
            .field("device_recording_active", &self.device_recording_active)
            .field(
                "pending_realtime_subscribe",
                &self.pending_realtime_subscribe,
            )
            .field("opus_buffer_len", &self.opus_buffer.len())
            .field("marks_ms", &self.marks_ms)
            .field("finalized_queue_len", &self.finalized_queue.len())
            .field("has_decoder_factory", &self.decoder_factory.is_some())
            .field("has_live_decoder_16k", &self.live_decoder_16k.is_some())
            .finish()
    }
}


impl TransportSession {
    /// Creates an idle transport session without an Opus decoder factory.
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates an idle transport session with an explicit `OpusDecoderFactory`.
    #[must_use]
    pub fn with_decoder_factory(factory: Option<OpusDecoderFactory>) -> Self {
        Self {
            capture_events: VecDeque::new(),
            file_decryption: BTreeMap::new(),
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
            stream_base_slices: 0,
            transfer: TransferProgress::default(),
            runtime_state: TransferRuntimeState::Idle,
            active_file_id: None,
            active_file_key: None,
            active_nonce: None,
            active_is_realtime: false,
            device_recording_active: false,
            realtime_pause: RealtimePause::Running,
            pending_realtime_subscribe: false,
            opus_buffer: Vec::new(),
            marks_ms: Vec::new(),
            finalized_queue: VecDeque::new(),
            custody_receipts: BTreeMap::new(),
            decoder_factory: factory,
            live_decoder_16k: None,
        }
    }

    /// Records a verified disk `fsync` [`CustodyReceipt`] for `receipt.file_id`.
    /// Returns `false` if `file_id == 0`, `byte_count == 0`, or `sha256_hex` is not a valid 64-hex SHA-256 digest.
    pub fn confirm_disk_custody(&mut self, receipt: CustodyReceipt) -> bool {
        let Some(verified) = receipt.verify() else {
            return false;
        };
        self.custody_receipts.insert(verified.file_id(), verified);
        true
    }

    /// Returns the verified disk `fsync` [`VerifiedCustodyReceipt`] for `file_id`, if recorded.
    #[must_use]
    pub fn custody_receipt(&self, file_id: u32) -> Option<&VerifiedCustodyReceipt> {
        self.custody_receipts.get(&file_id)
    }

    /// Drops verified custody receipts that fail `keep` without permitting unverified insertion.
    pub fn retain_custody_receipts(&mut self, mut keep: impl FnMut(u32) -> bool) {
        self.custody_receipts.retain(|&file_id, _| keep(file_id));
    }

    /// Returns `true` if a verified disk `fsync` [`CustodyReceipt`] has been recorded for `file_id`.
    #[must_use]
    pub fn has_disk_custody(&self, file_id: u32) -> bool {
        self.custody_receipts.contains_key(&file_id)
    }

    /// Builds a D3200 `0x1A/0x10` hardware file deletion command ONLY if a verified
    /// disk `fsync` [`CustodyReceipt`] exists for `file_id` (enforcing Omi's `PendantRingCustody` invariant).
    pub fn request_reclaim_bean_file(&self, file_id: u32) -> Result<Vec<u8>, &'static str> {
        let Some(receipt) = self.custody_receipt(file_id) else {
            return Err(
                "refusing to delete D3200 hardware file 0x1A/0x10 before disk fsync custody receipt",
            );
        };
        Ok(DeviceCommands::delete_file(receipt))
    }

    /// Pops and returns the next finalized recording from the FIFO queue.
    pub fn take_next_finalized(&mut self) -> Option<FinalizedRecording> {
        self.finalized_queue.pop_front()
    }

    /// Drains audio and finalization events in protocol order.
    pub fn take_capture_events(&mut self) -> VecDeque<CaptureEvent> {
        std::mem::take(&mut self.capture_events)
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
        if self.session_key != Some(key) {
            self.clear_file_decryption();
        }
        self.session_key = Some(key);
    }

    fn clear_file_decryption(&mut self) {
        self.file_decryption.clear();
        self.active_file_key = None;
        self.active_nonce = None;
    }

    fn bind_file_decryption(&mut self, file_id: u32) {
        let context = self.file_decryption.get(&file_id).copied();
        let (key, nonce) = match context {
            Some(FileDecryption::Ready { key, nonce }) => (Some(key), Some(nonce)),
            _ => (None, None),
        };
        self.active_file_key = key;
        self.active_nonce = nonce;
    }


    #[cfg(test)]
    fn build_rx_frame(cmd_type: u8, cmd_id: u8, payload: &[u8]) -> Vec<u8> {
        let total_len = (9 + payload.len() + 1) as u16;
        let mut frame = Vec::with_capacity(total_len as usize);
        frame.extend_from_slice(&crate::frame::RX_MAGIC);
        frame.push(0x01);
        frame.push(cmd_type);
        frame.push(cmd_id);
        frame.push((total_len & 0xFF) as u8);
        frame.push(((total_len >> 8) & 0xFF) as u8);
        frame.extend_from_slice(payload);
        let csum = crate::frame::ProtocolFrame::checksum(&frame);
        frame.push(csum);
        frame
    }

    /// Ingests a raw BLE notification chunk, reassembles verified frames, and advances
    /// the `01/01`, `1A/01`–`1B/0E`, `1A/06`, `1A/07`, `1A/08`, and `1A/0A` state machines.
    pub fn ingest_ble_chunk(&mut self, chunk: &[u8], now_epoch_sec: u64) -> SessionIngestOutcome {
        let packets = self.reassembler.ingest(chunk);
        let mut outcome = SessionIngestOutcome {
            frames_decoded: packets.len() as u32,
            ..SessionIngestOutcome::default()
        };

        for pkt in packets {
            match (pkt.cmd_type, pkt.cmd_id) {
                (RxCmd::ENCRYPT_TYPE, RxCmd::ENCRYPT_HANDSHAKE_ID) => {
                    self.handle_handshake_packet(&pkt, &mut outcome);
                }
                (RxCmd::DEVICE_INFO_TYPE, RxCmd::DEVICE_INFO_ID) => {
                    self.handle_device_info_packet(&pkt, now_epoch_sec, &mut outcome);
                }
                (RxCmd::AUDIO_TYPE, RxCmd::AUDIO_REALTIME_START_ID)
                | (RxCmd::AUDIO_TYPE, RxCmd::AUDIO_CONTROL_ID) => {
                    self.handle_audio_control_packet(&pkt, now_epoch_sec, &mut outcome);
                }
                (RxCmd::TRANSPORT_TYPE, RxCmd::FILE_LIST_LEGACY_ID)
                | (RxCmd::TRANSPORT_TYPE, RxCmd::FILE_LIST_NO_END_ID)
                | (RxCmd::TRANSPORT_TYPE, RxCmd::FILE_LIST_ID)
                | (RxCmd::TRANSPORT_TYPE_ALT, RxCmd::FILE_LIST_ID) => {
                    self.handle_catalog_page_packet(&pkt, now_epoch_sec, &mut outcome);
                }
                (RxCmd::TRANSPORT_TYPE, RxCmd::RECORD_STATUS_ID) => {
                    self.handle_record_status_packet(&pkt, now_epoch_sec, &mut outcome);
                }
                (RxCmd::TRANSPORT_TYPE, RxCmd::FILE_HEAD_ID)
                | (RxCmd::TRANSPORT_TYPE_ALT, RxCmd::FILE_HEAD_ID) => {
                    self.handle_file_head_packet(&pkt, now_epoch_sec, &mut outcome);
                }
                (RxCmd::TRANSPORT_TYPE, RxCmd::FILE_SLICE_ID)
                | (RxCmd::TRANSPORT_TYPE, RxCmd::FILE_SLICE_MARK_ID)
                | (RxCmd::TRANSPORT_TYPE_ALT, RxCmd::FILE_SLICE_ID)
                | (RxCmd::TRANSPORT_TYPE_ALT, RxCmd::FILE_SLICE_MARK_ID) => {
                    self.handle_file_slice_packet(&pkt, &mut outcome);
                }
                (RxCmd::TRANSPORT_TYPE, RxCmd::FILE_DONE_ID)
                | (RxCmd::TRANSPORT_TYPE_ALT, RxCmd::FILE_DONE_ID) => {
                    self.handle_file_done_packet(now_epoch_sec, &mut outcome);
                }
                (RxCmd::TRANSPORT_TYPE, RxCmd::DELETE_ID)
                | (RxCmd::TRANSPORT_TYPE_ALT, RxCmd::DELETE_ID) => {
                    self.handle_delete_packet(&pkt, &mut outcome);
                }
                _ => {}
            }
        }

        outcome
    }

}
