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

use crate::commands::DeviceCommands;
use crate::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
use crate::frame::{FrameReassembler, ProtocolFrame, RX_MAGIC};
use crate::library::RecordingEntry;
use crate::models::{DeviceInfoModel, OfflineFileEntry, OfflineFileList};
use crate::ogg_opus::OggOpus;
use crate::slice_marks::SliceMark;
use crate::transport::{TransportSliceProcessor, OPUS_FRAME_BYTES, SLICE_RECORD_BYTES};
use crate::wav::OpusWave;

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
    /// Finalized recording if `1A/0A` completed during this step.
    pub finalized: Option<FinalizedRecording>,
    /// Outbound TX command frames queued by protocol transitions.
    pub outbound_tx_frames: Vec<Vec<u8>>,
}

/// Stateful D3200 transport session engine.
#[derive(Debug, Clone, Default)]
pub struct TransportSession {
    /// Streaming packet reassembler.
    pub reassembler: FrameReassembler,
    /// Current connection phase.
    pub connection_phase: ConnectionPhaseTag,
    /// Latest parsed device telemetry (`01/01`).
    pub telemetry: Option<DeviceInfoModel>,
    /// Unwrapped 32-byte HKDF session key (`2E/01`).
    pub session_key: Option<[u8; 32]>,
    /// Latest offline catalog entries (`1A/01`/`1A/0D`/`1B/0E`).
    pub catalog: Vec<OfflineFileEntry>,
    /// Current transfer progress snapshot.
    pub transfer: TransferProgress,
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
}

impl TransportSession {
    /// Creates an idle transport session.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Sets the 32-byte session key explicitly.
    pub fn set_session_key(&mut self, key: [u8; 32]) {
        self.session_key = Some(key);
    }

    /// Resets any active file transfer and clears partial buffers.
    pub fn reset_active_transfer(&mut self) {
        self.active_file_id = None;
        self.active_file_key = None;
        self.active_nonce = None;
        self.active_is_realtime = false;
        self.opus_buffer.clear();
        self.marks_ms.clear();
        self.transfer = TransferProgress::default();
    }

    /// Handles GATT disconnection by resetting transfer state and entering `Disconnected`.
    pub fn on_disconnected(&mut self) {
        self.reassembler.reset();
        self.reset_active_transfer();
        self.connection_phase = ConnectionPhaseTag::Disconnected;
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
        self.transfer = TransferProgress {
            phase: TransferPhaseTag::PullingOffline,
            file_id,
            received_wire_bytes: 0,
            expected_wire_bytes: estimated_wire,
            mark_count: 0,
            error_code: 0,
        };
        DeviceCommands::start_transport_audio_file(file_id, 0, 0)
    }

    /// Ingests a raw BLE notification chunk, reassembles verified frames, and advances
    /// the `01/01`, `1A/01`–`1B/0E`, `1A/07`, `1A/08`, and `1A/0A` state machines.
    pub fn ingest_ble_chunk(&mut self, chunk: &[u8], now_epoch_sec: u64) -> SessionIngestOutcome {
        let packets = self.reassembler.ingest(chunk);
        let mut outcome = SessionIngestOutcome {
            frames_decoded: packets.len() as u32,
            ..SessionIngestOutcome::default()
        };

        for pkt in packets {
            match (pkt.cmd_type, pkt.cmd_id) {
                (0x01, 0x01) => {
                    let info = DeviceInfoModel::parse_packet(&pkt.raw);
                    self.telemetry = Some(info);
                    self.connection_phase = ConnectionPhaseTag::Connected;
                    outcome.telemetry_updated = true;
                    outcome
                        .outbound_tx_frames
                        .push(DeviceCommands::list_files_with_end_time(0));
                }
                (0x1A, 0x01) | (0x1A, 0x0D) | (0x1A, 0x0E) | (0x1B, 0x0E) => {
                    let with_end_time = pkt.cmd_id == 0x0D || (pkt.cmd_type == 0x1B && pkt.cmd_id == 0x0E);
                    let page = OfflineFileList::parse(&pkt.payload, with_end_time);
                    self.catalog = page.files;
                    outcome.catalog_updated = true;
                    if self.active_file_id.is_none() {
                        self.transfer.phase = TransferPhaseTag::Idle;
                    }
                }
                (0x1A, 0x07) | (0x1B, 0x07) => {
                    let sk_slice = self.session_key.as_ref().map(|k| k.as_slice());
                    if let Some(head) = TransportSliceProcessor::open_file_head(&pkt.raw, sk_slice)
                    {
                        self.active_file_id = Some(head.secret.file_id);
                        self.active_file_key = head.file_key;
                        self.active_nonce = Some(head.secret.nonce);
                        self.active_is_realtime = head.unfinished;
                        self.opus_buffer.clear();
                        self.marks_ms.clear();
                        let phase = if head.unfinished {
                            TransferPhaseTag::StreamingRealtime
                        } else {
                            TransferPhaseTag::PullingOffline
                        };
                        let expected = if head.unfinished {
                            0
                        } else {
                            head.secret.file_size
                        };
                        self.transfer = TransferProgress {
                            phase,
                            file_id: head.secret.file_id,
                            received_wire_bytes: 0,
                            expected_wire_bytes: expected,
                            mark_count: 0,
                            error_code: 0,
                        };
                        outcome.transfer_updated = true;
                    }
                }
                (0x1A, 0x08) | (0x1A, 0x12) | (0x1B, 0x08) | (0x1B, 0x12) => {
                    let dec = self
                        .active_file_key
                        .as_ref()
                        .zip(self.active_nonce.as_ref())
                        .and_then(|(fk, n)| AesCtrStreamDecrypt::new(fk, n));
                    let batch = TransportSliceProcessor::unpack_frame(&pkt.raw, dec.as_ref());
                    if batch.slice_count > 0 {
                        let fid = self.active_file_id.unwrap_or(1);
                        self.active_file_id = Some(fid);
                        self.opus_buffer.extend_from_slice(&batch.opus_bytes);
                        let new_received = self
                            .transfer
                            .received_wire_bytes
                            .saturating_add(batch.wire_record_bytes() as u32);
                        for seq in batch.marked_sequences {
                            let ms = SliceMark::position_ms(seq);
                            if !self.marks_ms.contains(&ms) {
                                self.marks_ms.push(ms);
                                outcome.new_marks_ms.push(ms);
                            }
                        }
                        self.marks_ms.sort_unstable();
                        let phase = if self.active_is_realtime {
                            TransferPhaseTag::StreamingRealtime
                        } else {
                            TransferPhaseTag::PullingOffline
                        };
                        let expected = if self.active_is_realtime {
                            0
                        } else {
                            self.transfer.expected_wire_bytes.max(new_received)
                        };
                        self.transfer = TransferProgress {
                            phase,
                            file_id: fid,
                            received_wire_bytes: new_received,
                            expected_wire_bytes: expected,
                            mark_count: self.marks_ms.len() as u32,
                            error_code: 0,
                        };
                        outcome.slices_unpacked_count = outcome
                            .slices_unpacked_count
                            .saturating_add(batch.slice_count as u32);
                        outcome.transfer_updated = true;
                    }
                }
                (0x1A, 0x0A) | (0x1B, 0x0A) => {
                    if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                        outcome.finalized = Some(fin);
                        outcome.transfer_updated = true;
                    }
                }
                _ => {}
            }
        }

        outcome
    }

    /// Finalizes the active Opus stream into an Ogg Opus container and 48 kHz mono
    /// preview WAV with 880 Hz mark chimes, stores it in `last_finalized`, and resets
    /// the active transfer state to `Idle`.
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
        let preview_wav_bytes = OpusWave::build_audible_preview_wav(duration_ms, &marks_ms);

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
        self.last_finalized = Some(finalized.clone());
        self.reset_active_transfer();
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
            let mut chunk = [0x78u8; OPUS_FRAME_BYTES];
            chunk[1] = (seq & 0xFF) as u8;
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
}
