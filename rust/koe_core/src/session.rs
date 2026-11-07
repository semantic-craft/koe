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
use crate::wav::{
    default_opus_decoder_factory, OpusDecoderFactory, OpusStreamDecoder, OpusWave,
    ASR_SAMPLE_RATE, WAV_SAMPLE_RATE,
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
    /// Accumulated 16 kHz mono PCM16 LE bytes ready to drain via `take_live_pcm16`.
    pub live_pcm16_16khz: Vec<u8>,
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
            session_key: self.session_key,
            catalog: self.catalog.clone(),
            transfer: self.transfer,
            active_file_id: self.active_file_id,
            active_file_key: self.active_file_key,
            active_nonce: self.active_nonce,
            active_is_realtime: self.active_is_realtime,
            opus_buffer: self.opus_buffer.clone(),
            marks_ms: self.marks_ms.clone(),
            last_finalized: self.last_finalized.clone(),
            live_pcm16_16khz: self.live_pcm16_16khz.clone(),
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
            .field("session_key", &self.session_key)
            .field("catalog", &self.catalog)
            .field("transfer", &self.transfer)
            .field("active_file_id", &self.active_file_id)
            .field("active_file_key", &self.active_file_key)
            .field("active_nonce", &self.active_nonce)
            .field("active_is_realtime", &self.active_is_realtime)
            .field("opus_buffer_len", &self.opus_buffer.len())
            .field("marks_ms", &self.marks_ms)
            .field("last_finalized", &self.last_finalized)
            .field("live_pcm16_16khz_len", &self.live_pcm16_16khz.len())
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
            session_key: None,
            catalog: Vec::new(),
            transfer: TransferProgress::default(),
            active_file_id: None,
            active_file_key: None,
            active_nonce: None,
            active_is_realtime: false,
            opus_buffer: Vec::new(),
            marks_ms: Vec::new(),
            last_finalized: None,
            live_pcm16_16khz: Vec::new(),
            decoder_factory: factory,
            live_decoder_16k: None,
        }
    }

    /// Drains and returns all buffered 16 kHz mono PCM16 LE bytes decoded during `ingest_ble_chunk`.
    pub fn take_live_pcm16(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.live_pcm16_16khz)
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
        self.live_pcm16_16khz.clear();
        if let Some(dec) = self.live_decoder_16k.as_mut() {
            dec.reset();
        }
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
        self.live_pcm16_16khz.clear();
        if let Some(dec) = self.live_decoder_16k.as_mut() {
            dec.reset();
        }
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
                        self.live_pcm16_16khz.clear();
                        if let Some(dec) = self.live_decoder_16k.as_mut() {
                            dec.reset();
                        }
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
}
