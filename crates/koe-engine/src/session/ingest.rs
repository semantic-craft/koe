use super::*;
use crate::commands::{DeviceCommands, RxCmd};
use crate::crypto::AesCtrStreamDecrypt;
use crate::frame::{read_u32_le, DecodedPacket};
use crate::slice_marks::SliceMark;
use crate::transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES, TransportSliceProcessor};
use crate::wav::OpusWave;

impl TransportSession {
    pub(super) fn handle_audio_control_packet(
        &mut self,
        pkt: &DecodedPacket,
        now_epoch_sec: u64,
        outcome: &mut SessionIngestOutcome,
    ) {
            if !pkt.payload.is_empty() {
                let (fid, state) = if pkt.cmd_id == RxCmd::AUDIO_REALTIME_START_ID
                    && pkt.payload.len() >= 5
                    && read_u32_le(&pkt.payload, 0) > 2
                    && pkt.payload[4] <= 2
                {
                    (read_u32_le(&pkt.payload, 0), pkt.payload[4])
                } else if pkt.cmd_id == RxCmd::AUDIO_REALTIME_START_ID
                    && pkt.payload.len() == 4
                {
                    (read_u32_le(&pkt.payload, 0), 1)
                } else {
                    (0, pkt.payload[0])
                };
                if state == 1 {
                    self.device_recording_active = true;
                    if fid > 0 {
                        if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                            fid,
                            0,
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
                            if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                                active_fid,
                                0,
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
            }

    }

    pub(super) fn handle_record_status_packet(
        &mut self,
        pkt: &DecodedPacket,
        now_epoch_sec: u64,
        outcome: &mut SessionIngestOutcome,
    ) {
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
                        if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                            fid,
                            0,
                            now_epoch_sec,
                        ) {
                            outcome.outbound_tx_frames.push(tx);
                            outcome.transfer_updated = true;
                        }
                    } else if let Some(active_fid) = self
                        .active_file_id
                        .filter(|&id| id > 0 && self.active_is_realtime)
                    {
                        if let Some(tx) = self.enter_or_resume_realtime_stream_at(
                            active_fid,
                            0,
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
            } else if pkt.payload.len() == 1 {
                let state = pkt.payload[0];
                if state == 1 {
                    self.device_recording_active = true;
                    if let Some(fid) = self
                        .active_file_id
                        .filter(|&id| id > 0 && self.active_is_realtime)
                    {
                        if let Some(tx) =
                            self.enter_or_resume_realtime_stream_at(fid, 0, now_epoch_sec)
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
            }

    }

    pub(super) fn handle_file_head_packet(
        &mut self,
        pkt: &DecodedPacket,
        now_epoch_sec: u64,
        outcome: &mut SessionIngestOutcome,
    ) {
            if let Some(head) = self.parse_any_file_head(&pkt.raw) {
                let err = head.secret.error_code;
                if self.active_is_realtime && err != 0 && err != 0xFF {
                    self.transfer.error_code = err;
                    outcome.transfer_updated = true;
                    return;
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
                    outcome.transfer_updated = true;
                    return;
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
                    outcome.transfer_updated = true;
                    return;
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
                    {
                        if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                            outcome.finalized = Some(fin);
                        }
                    }
                    self.opus_buffer.clear();
                    self.marks_ms.clear();
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
                }
                self.active_file_id = Some(head.secret.file_id);
                if let Some(key) = head.file_key {
                    self.file_decryption.insert(
                        head.secret.file_id,
                        FileDecryption::Ready {
                            key,
                            nonce: head.secret.nonce,
                        },
                    );
                } else if !head.secret.encrypted_file_key.is_empty() {
                    self.file_decryption
                        .entry(head.secret.file_id)
                        .or_insert(FileDecryption::AwaitingKey);
                }
                self.bind_file_decryption(head.secret.file_id);
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
                if matches!(
                    self.file_decryption.get(&head.secret.file_id),
                    Some(FileDecryption::AwaitingKey)
                ) {
                    self.transfer.error_code = TRANSFER_ERR_FILE_DECRYPTION;
                    if !is_realtime {
                        self.runtime_state = TransferRuntimeState::Failed {
                            file_id: head.secret.file_id,
                            error_code: TRANSFER_ERR_FILE_DECRYPTION,
                        };
                        self.transfer.phase = TransferPhaseTag::Failed;
                    }
                }
                outcome.transfer_updated = true;
            }

    }

    pub(super) fn handle_file_slice_packet(
        &mut self,
        pkt: &DecodedPacket,
        outcome: &mut SessionIngestOutcome,
    ) {
            let Some(fid) = self.active_file_id else {
                return;
            };
            if matches!(
                self.file_decryption.get(&fid),
                Some(FileDecryption::AwaitingKey)
            ) {
                return;
            }
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
            let batch = TransportSliceProcessor::unpack_frame_from(
                &pkt.raw,
                dec.as_ref(),
                min_seq,
            );
            if batch.slice_count > 0 {
                self.opus_buffer.extend_from_slice(&batch.opus_bytes);
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
                    }
                }
                self.marks_ms.sort_unstable();
                if self.active_is_realtime {
                    if self.live_decoder_16k.is_none() {
                        if let Some(factory) = self.decoder_factory {
                            self.live_decoder_16k = factory(ASR_SAMPLE_RATE);
                        }
                    }
                    if let Some(live_dec) = self.live_decoder_16k.as_mut() {
                        let mut pcm16 = Vec::new();
                        for frame in batch.opus_bytes.as_chunks::<OPUS_FRAME_BYTES>().0 {
                            let _ = OpusWave::decode_frame_into(
                                live_dec.as_mut(),
                                frame,
                                &mut pcm16,
                            );
                        }
                        if !pcm16.is_empty() {
                            self.capture_events.push_back(CaptureEvent::Audio {
                                file_id: fid,
                                pcm16,
                            });
                        }
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
                    let expected = self.transfer.expected_wire_bytes.max(new_received);
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
                }
                outcome.slices_unpacked_count = outcome
                    .slices_unpacked_count
                    .saturating_add(batch.slice_count as u32);
                outcome.transfer_updated = true;
            }

    }

    pub(super) fn handle_file_done_packet(
        &mut self,
        now_epoch_sec: u64,
        outcome: &mut SessionIngestOutcome,
    ) {
            if !self.active_is_realtime
                && self.transfer.expected_wire_bytes > 0
                && self.transfer.received_wire_bytes < self.transfer.expected_wire_bytes
            {
                return;
            }
            if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                outcome.finalized = Some(fin);
                outcome.transfer_updated = true;
            }

    }

    pub(super) fn handle_delete_packet(
        &mut self,
        pkt: &DecodedPacket,
        outcome: &mut SessionIngestOutcome,
    ) {
            let success = pkt.is_success();
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
}
