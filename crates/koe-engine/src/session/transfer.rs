use super::*;
use crate::commands::DeviceCommands;
use crate::ogg_opus::OggOpus;
use crate::transport::{OPUS_FRAME_BYTES, SLICE_RECORD_BYTES};
use crate::wav::{OpusWave, WAV_SAMPLE_RATE};

impl TransportSession {
    /// Resets any active file transfer and clears partial buffers.
    pub fn reset_active_transfer(&mut self) {
        self.active_file_id = None;
        self.active_file_key = None;
        self.active_nonce = None;
        self.active_is_realtime = false;
        self.stream_base_slices = 0;
        self.opus_buffer.clear();
        self.marks_ms.clear();
        if let Some(dec) = self.live_decoder_16k.as_mut() {
            dec.reset();
        }
        self.runtime_state = TransferRuntimeState::Idle;
        self.transfer = TransferProgress::default();
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
            if self.active_is_realtime && self.active_file_id.is_some() {
                let _ = self.finalize_active_transfer(now_epoch_sec);
            }
            self.bind_file_decryption(file_id);
            self.opus_buffer.clear();
            self.marks_ms.clear();
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
            if let Some(tx) =
                self.enter_or_resume_realtime_stream_at(fid, 0, now_epoch_sec)
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
        outcome
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
        outcome
    }


    /// Prepares an offline file pull for `file_id` and returns the encoded `1A/07` TX frame.
    pub fn begin_offline_pull(&mut self, file_id: u32, duration_ms: u32) -> Vec<u8> {
        let estimated_wire = ((duration_ms / 20).max(1)).saturating_mul(SLICE_RECORD_BYTES as u32);
        self.active_file_id = Some(file_id);
        self.bind_file_decryption(file_id);
        self.active_is_realtime = false;
        self.stream_base_slices = 0;
        self.opus_buffer.clear();
        self.marks_ms.clear();
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
    /// preview WAV with 880 Hz mark chimes, appends it to `finalized_queue`,
    /// and resets the active transfer state to `Idle`.
    pub fn finalize_active_transfer(&mut self, now_epoch_sec: u64) -> Option<FinalizedRecording> {
        let fid = self.active_file_id?;
        if self.opus_buffer.is_empty() {
            self.capture_events.push_back(CaptureEvent::Finished {
                file_id: fid,
                saved: false,
            });
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
        self.capture_events.push_back(CaptureEvent::Finished {
            file_id: fid,
            saved: true,
        });
        self.reset_active_transfer();
        Some(finalized)
    }

    /// Returns `true` when `file_id` is currently active, suspended, or streaming in this session.
    #[must_use]
    pub fn is_file_in_flight(&self, file_id: u32) -> bool {
        self.active_file_id == Some(file_id)
            || matches!(
                self.runtime_state,
                TransferRuntimeState::PullingOffline { file_id: fid, .. }
                    | TransferRuntimeState::Suspended { file_id: fid, .. }
                    | TransferRuntimeState::StreamingRealtime { file_id: fid, .. }
                    if fid == file_id
            )
            || (matches!(
                self.transfer.phase,
                TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
            ) && self.transfer.file_id == file_id)
    }


}
