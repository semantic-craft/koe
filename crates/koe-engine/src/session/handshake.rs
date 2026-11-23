use super::*;
use crate::commands::DeviceCommands;
use crate::crypto::DeviceCrypto;
use crate::frame::DecodedPacket;
use crate::models::DeviceInfoModel;
use crate::transport::SLICE_RECORD_BYTES;

impl TransportSession {
    /// Transitions the transport session into `Scanning` for D3200 BLE advertisements.
    pub fn on_scanning(&mut self) {
        self.connection_phase = ConnectionPhaseTag::Scanning;
    }

    /// Transitions the transport session into `Connecting` to a discovered D3200 peripheral.
    pub fn on_connecting(&mut self) {
        self.connection_phase = ConnectionPhaseTag::Connecting;
    }

    /// Starts the `2E/01` ECDH + `01/01` device telemetry handshake once GATT characteristics
    /// `0x7777` (write) and `0x8888` (notify) are ready, returning the outbound TX frames.
    pub fn on_gatt_ready(&mut self, private_key: [u8; 32]) -> Option<Vec<Vec<u8>>> {
        let pub_key = DeviceCrypto::p256_public_key(&private_key)?;
        self.reassembler.reset();
        self.ecdh_private_key = Some(private_key);
        self.session_key = None;
        self.clear_file_decryption();
        self.connection_phase = ConnectionPhaseTag::Handshaking;
        Some(vec![
            DeviceCommands::notify_encrypt_public_key(&pub_key),
            DeviceCommands::get_device_info(),
        ])
    }


    /// Handles explicit GATT disconnection by resetting transfer state and entering `Disconnected`.
    pub fn on_disconnected(&mut self) {
        self.reassembler.reset();
        self.ecdh_private_key = None;
        self.session_key = None;
        self.clear_file_decryption();
        self.realtime_pause = RealtimePause::Running;
        self.device_recording_active = false;
        self.pending_realtime_subscribe = false;
        self.pre_start_entries.clear();
        self.catalog_load_phase = CatalogLoadPhase::Idle;
        self.catalog_page_elapsed_ms = 0;
        self.staged_catalog_entries.clear();
        self.staged_seen_wire_ids.clear();
        self.staged_first_page_head = None;
        self.staged_transport_timestamp = None;
        self.staged_with_end_time = false;
        self.has_complete_catalog = false;
        self.catalog_timed_out = false;
        self.catalog_timeout_retries = 0;
        self.catalog_refresh_queued = false;
        self.catalog_started_for_subscribe = false;
        if self.active_is_realtime {
            let _ = self.finalize_active_transfer(0);
        } else {
            self.reset_active_transfer();
        }
        self.connection_phase = ConnectionPhaseTag::Disconnected;
    }

    /// Handles an unexpected BLE link interruption: suspends an in-flight offline pull so it can
    /// resume from `received_slice_count() * 166` upon reconnect, or salvages buffered realtime
    /// Opus slices into `finalized_queue`.
    pub fn on_transport_interrupted(&mut self) {
        self.reassembler.reset();
        self.ecdh_private_key = None;
        self.session_key = None;
        self.clear_file_decryption();
        self.realtime_pause = RealtimePause::Running;
        self.device_recording_active = false;
        self.pending_realtime_subscribe = false;
        self.connection_phase = ConnectionPhaseTag::Disconnected;
        self.catalog_load_phase = CatalogLoadPhase::Idle;
        self.catalog_page_elapsed_ms = 0;
        self.staged_catalog_entries.clear();
        self.staged_seen_wire_ids.clear();
        self.staged_first_page_head = None;
        self.staged_transport_timestamp = None;
        self.staged_with_end_time = false;
        self.has_complete_catalog = false;
        self.catalog_timed_out = false;
        self.catalog_timeout_retries = 0;
        self.catalog_refresh_queued = false;
        self.catalog_started_for_subscribe = false;
        self.pre_start_entries.clear();
        match self.runtime_state {
            TransferRuntimeState::PullingOffline {
                file_id,
                expected_wire_bytes,
                retries_used,
                ..
            }
            | TransferRuntimeState::Suspended {
                file_id,
                expected_wire_bytes,
                retries_used,
            } => {
                self.runtime_state = TransferRuntimeState::Suspended {
                    file_id,
                    expected_wire_bytes,
                    retries_used,
                };
                self.transfer.received_wire_bytes = self
                    .received_slice_count()
                    .saturating_mul(SLICE_RECORD_BYTES as u32);
                self.transfer.quiet_draining = false;
            }
            TransferRuntimeState::Failed { .. } => {
                self.transfer.quiet_draining = false;
            }
            _ if self.active_is_realtime => {
                let _ = self.finalize_active_transfer(0);
            }
            _ => {
                self.reset_active_transfer();
            }
        }
    }

    /// Advances the 5,000 ms offline pull watchdog (up to 2 retries per file) and the 2,000 ms
    /// realtime post-stop quiet-drain timer by `elapsed_ms`.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now_epoch_sec: u64) -> SessionIngestOutcome {
        let mut outcome = SessionIngestOutcome::default();
        if self.is_catalog_loading() {
            self.catalog_page_elapsed_ms = self.catalog_page_elapsed_ms.saturating_add(elapsed_ms);
            if self.catalog_page_elapsed_ms >= 3_000 {
                self.catalog_load_phase = CatalogLoadPhase::Idle;
                self.catalog_page_elapsed_ms = 0;
                self.catalog_timed_out = true;
                for entry in std::mem::take(&mut self.staged_catalog_entries) {
                    if let Some(existing) = self
                        .raw_catalog
                        .iter_mut()
                        .find(|f| f.file_id == entry.file_id)
                    {
                        *existing = entry;
                    } else {
                        self.raw_catalog.push(entry);
                    }
                }
                self.catalog = self
                    .raw_catalog
                    .iter()
                    .filter(|f| f.has_duration())
                    .cloned()
                    .collect();
                outcome.catalog_updated = true;

                if !self.has_complete_catalog && self.catalog_timeout_retries < 2 {
                    self.catalog_timeout_retries += 1;
                    let retry_tx = self.request_full_catalog();
                    if !retry_tx.is_empty() {
                        outcome.outbound_tx_frames.push(retry_tx);
                    }
                }
            }
        }
        let offset = self
            .received_slice_count()
            .saturating_mul(SLICE_RECORD_BYTES as u32);
        match &mut self.runtime_state {
            TransferRuntimeState::PullingOffline {
                file_id,
                inactivity_ms,
                retries_used,
                ..
            } => {
                *inactivity_ms = inactivity_ms.saturating_add(elapsed_ms);
                if *inactivity_ms >= OFFLINE_WATCHDOG_TIMEOUT_MS {
                    let fid = *file_id;
                    if *retries_used < OFFLINE_MAX_RETRIES {
                        *retries_used += 1;
                        *inactivity_ms = 0;
                        let retries = *retries_used;
                        self.transfer.received_wire_bytes = offset;
                        self.transfer.retry_count = retries;
                        outcome
                            .outbound_tx_frames
                            .push(DeviceCommands::start_transport_audio_file(fid, offset, 0));
                        outcome.transfer_updated = true;
                    } else {
                        let retries = *retries_used;
                        self.runtime_state = TransferRuntimeState::Failed {
                            file_id: fid,
                            error_code: TRANSFER_ERR_WATCHDOG_TIMEOUT,
                        };
                        self.active_file_id = None;
                        self.active_is_realtime = false;
                        self.active_file_key = None;
                        self.active_nonce = None;
                        self.clear_active_file_decryptor();
                        self.opus_buffer.clear();
                        self.marks_ms.clear();
                        self.stream_base_slices = 0;
                        self.transfer.phase = TransferPhaseTag::Failed;
                        self.transfer.error_code = TRANSFER_ERR_WATCHDOG_TIMEOUT;
                        self.transfer.retry_count = retries;
                        outcome.transfer_updated = true;
                    }
                }
            }
            TransferRuntimeState::StreamingRealtime {
                quiet_drain_elapsed_ms: Some(waited),
                ..
            } => {
                *waited = waited.saturating_add(elapsed_ms);
                if *waited >= REALTIME_QUIET_DRAIN_MS {
                    if let Some(fin) = self.finalize_active_transfer(now_epoch_sec) {
                        outcome.finalized = Some(fin);
                    }
                    outcome.transfer_updated = true;
                    outcome
                        .outbound_tx_frames
                        .push(DeviceCommands::list_files_with_end_time(0));
                }
            }
            _ => {}
        }
        outcome
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
        let derived = DeviceCrypto::hkdf_sha256(computed_shared_secret, &[1, 2, 3], &[1, 2, 3], 32);
        let mut sk = [0u8; 32];
        sk.copy_from_slice(&derived);
        self.set_session_key(sk);
        true
    }


    pub(super) fn handle_handshake_packet(
        &mut self,
        pkt: &DecodedPacket,
        outcome: &mut SessionIngestOutcome,
    ) {
        if pkt.payload.len() >= 97 {
            if let Some(priv_key) = self.ecdh_private_key {
                if let Some(shared) = DeviceCrypto::p256_ecdh_shared_secret(
                    &priv_key,
                    &pkt.payload[0..65],
                ) {
                    if self.accept_ecdh_reply(&pkt.payload, &shared) {
                        outcome.session_key_established = true;
                        if self.telemetry.is_some()
                            && self.connection_phase == ConnectionPhaseTag::Handshaking
                        {
                            self.connection_phase = ConnectionPhaseTag::Connected;
                        } else if self.telemetry.is_none() {
                            outcome
                                .outbound_tx_frames
                                .push(DeviceCommands::get_device_info());
                        }
                        if self.is_offline_pull_suspended()
                            && self.connection_phase == ConnectionPhaseTag::Connected
                        {
                            if let Some(resume_tx) = self.resume_offline_pull() {
                                outcome.outbound_tx_frames.push(resume_tx);
                                outcome.transfer_updated = true;
                            }
                        }
                    }
                }
            }
        }

    }

    pub(super) fn handle_device_info_packet(
        &mut self,
        pkt: &DecodedPacket,
        now_epoch_sec: u64,
        outcome: &mut SessionIngestOutcome,
    ) {
            let info = DeviceInfoModel::parse_packet(&pkt.raw);
            let continuing = self.observe_realtime_pause(info.recording_status, None, now_epoch_sec, outcome);
            let is_rec = info.recording() || continuing;
            self.device_recording_active = is_rec;
            if is_rec {
                if !self.active_is_realtime || self.active_file_id.is_none() {
                    self.pending_realtime_subscribe = true;
                }
            } else {
                self.pending_realtime_subscribe = false;
                if self.active_is_realtime {
                    if let Some(fid) = self.active_file_id.filter(|&id| id > 0) {
                        self.runtime_state = TransferRuntimeState::StreamingRealtime {
                            file_id: fid,
                            quiet_drain_elapsed_ms: Some(0),
                        };
                        self.transfer.quiet_draining = true;
                        outcome.transfer_updated = true;
                    }
                }
            }
            self.telemetry = Some(info);
            if self.ecdh_private_key.is_some() && self.session_key.is_none() {
                self.connection_phase = ConnectionPhaseTag::Handshaking;
            } else {
                self.connection_phase = ConnectionPhaseTag::Connected;
            }
            outcome.telemetry_updated = true;
            let tx = self.request_full_catalog();
            if !tx.is_empty() {
                outcome.outbound_tx_frames.push(tx);
            }
            if self.is_offline_pull_suspended() && self.session_key.is_some() {
                if let Some(resume_tx) = self.resume_offline_pull() {
                    outcome.outbound_tx_frames.push(resume_tx);
                    outcome.transfer_updated = true;
                }
            }
    }
}
