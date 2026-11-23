use super::*;
use crate::commands::{DeviceCommands, RxCmd};
use crate::crypto::AudioFileSecretKey;
use crate::frame::{read_u32_le, DecodedPacket};
use crate::models::OfflineFileList;
use crate::transport::{OpenedFileHead, TransportSliceProcessor, UNFINISHED_FILE_SIZE};

impl TransportSession {
    /// Resets catalog pagination state and returns a `0x1B 0x0E` page-0 query frame.
    pub fn request_full_catalog(&mut self) -> Vec<u8> {
        if self.is_catalog_loading() {
            self.catalog_refresh_queued = true;
            return Vec::new();
        }
        self.catalog_load_phase = CatalogLoadPhase::AwaitingFirstPage;
        self.catalog_page_elapsed_ms = 0;
        self.staged_catalog_entries.clear();
        self.staged_seen_wire_ids.clear();
        self.staged_first_page_head = None;
        self.staged_transport_timestamp = None;
        self.staged_with_end_time = true;
        DeviceCommands::list_files_with_end_time(0)
    }


    pub(super) fn finalize_staged_catalog(&mut self, now_epoch_sec: u64, outcome: &mut SessionIngestOutcome) {
        self.catalog_load_phase = CatalogLoadPhase::Idle;
        self.catalog_page_elapsed_ms = 0;
        self.catalog_timed_out = false;
        self.catalog_timeout_retries = 0;
        if self.staged_with_end_time {
            self.has_complete_catalog = true;
        }
        self.raw_catalog = std::mem::take(&mut self.staged_catalog_entries);
        self.catalog = self
            .raw_catalog
            .iter()
            .filter(|f| f.has_duration())
            .cloned()
            .collect();
        outcome.catalog_updated = true;

        if self.pending_realtime_subscribe
            || (self.device_recording_active
                && self.active_file_id.is_none()
                && !matches!(self.transfer.phase, TransferPhaseTag::Failed))
        {
            let candidate_fid = if self.staged_with_end_time {
                let open_new = self
                    .raw_catalog
                    .iter()
                    .filter(|f| {
                        f.file_id > 0
                            && f.end_time == Some(0)
                            && !self.pre_start_entries.contains_key(&f.file_id)
                    })
                    .map(|f| f.file_id)
                    .max();
                let open_any = open_new.or_else(|| {
                    self.raw_catalog
                        .iter()
                        .filter(|f| f.file_id > 0 && f.end_time == Some(0))
                        .map(|f| f.file_id)
                        .max()
                });
                open_any.or_else(|| {
                    self.staged_transport_timestamp.filter(|&ts| {
                        ts > 0
                            && !self
                                .raw_catalog
                                .iter()
                                .any(|f| f.file_id == ts && f.end_time.is_some_and(|et| et > 0))
                    })
                })
            } else {
                let unstarted = self
                    .raw_catalog
                    .iter()
                    .filter(|f| f.file_id > 0 && !self.pre_start_entries.contains_key(&f.file_id))
                    .map(|f| f.file_id)
                    .max();
                unstarted
                    .or_else(|| self.staged_transport_timestamp.filter(|&id| id > 0))
                    .or_else(|| {
                        self.raw_catalog
                            .iter()
                            .map(|f| f.file_id)
                            .max()
                            .filter(|&id| id > 0)
                    })
            };

            let has_fresh_open_candidate = candidate_fid.is_some_and(|fid| {
                !self.pre_start_entries.contains_key(&fid)
                    && self
                        .raw_catalog
                        .iter()
                        .any(|f| f.file_id == fid && f.end_time == Some(0))
            });

            if self.catalog_refresh_queued && !has_fresh_open_candidate {
                self.catalog_refresh_queued = false;
                self.catalog_started_for_subscribe = self.pending_realtime_subscribe;
                let tx = self.request_full_catalog();
                if !tx.is_empty() {
                    outcome.outbound_tx_frames.push(tx);
                }
                return;
            }
            self.catalog_refresh_queued = false;

            if let Some(fid) = candidate_fid {
                if let Some(tx) =
                    self.enter_or_resume_realtime_stream_at(fid, 0, now_epoch_sec)
                {
                    outcome.outbound_tx_frames.push(tx);
                    outcome.transfer_updated = true;
                }
            } else if self.active_file_id.is_none()
                && !matches!(self.transfer.phase, TransferPhaseTag::Failed)
            {
                self.runtime_state = TransferRuntimeState::Idle;
                self.transfer.phase = TransferPhaseTag::Idle;
            }
            self.pre_start_entries.clear();
        } else {
            if self.catalog_refresh_queued {
                self.catalog_refresh_queued = false;
                let tx = self.request_full_catalog();
                if !tx.is_empty() {
                    outcome.outbound_tx_frames.push(tx);
                }
            }
            if self.active_file_id.is_none()
                && !matches!(self.transfer.phase, TransferPhaseTag::Failed)
            {
                self.runtime_state = TransferRuntimeState::Idle;
                self.transfer.phase = TransferPhaseTag::Idle;
            }
            self.pre_start_entries.clear();
        }
    }


    pub(super) fn parse_any_file_head(&self, raw: &[u8]) -> Option<OpenedFileHead> {
        let sk_slice = self.session_key.as_ref().map(|k| k.as_slice());
        if let Some(head) = TransportSliceProcessor::open_file_head(raw, sk_slice) {
            return Some(head);
        }
        if raw.len() < 18 {
            return None;
        }
        let file_id = read_u32_le(raw, 9);
        let file_size = read_u32_le(raw, 13);
        let error_code = if raw.len() > 95 {
            raw[95]
        } else if raw.len() >= 19 {
            raw[17]
        } else {
            0
        };
        Some(OpenedFileHead {
            secret: AudioFileSecretKey {
                file_id,
                file_size,
                nonce: [0u8; 16],
                encrypted_file_key: Vec::new(),
                session_nonce: [0u8; 16],
                error_code,
            },
            unfinished: file_size == UNFINISHED_FILE_SIZE,
            file_key: None,
        })
    }


    pub(super) fn handle_catalog_page_packet(
        &mut self,
        pkt: &DecodedPacket,
        now_epoch_sec: u64,
        outcome: &mut SessionIngestOutcome,
    ) {
            let with_end_time = pkt.cmd_id == RxCmd::FILE_LIST_NO_END_ID
                || (pkt.cmd_type == RxCmd::TRANSPORT_TYPE_ALT
                    && pkt.cmd_id == RxCmd::FILE_LIST_ID);
            let page = OfflineFileList::parse(&pkt.payload, with_end_time);
            match self.catalog_load_phase {
                CatalogLoadPhase::Idle => {
                    if self.catalog_timed_out {
                        self.staged_catalog_entries = self.raw_catalog.clone();
                        self.staged_seen_wire_ids =
                            self.raw_catalog.iter().map(|f| f.file_id).collect();
                        self.staged_first_page_head =
                            self.raw_catalog.first().map(|f| f.file_id);
                    } else {
                        self.staged_catalog_entries.clear();
                        self.staged_seen_wire_ids.clear();
                        self.staged_first_page_head = page.wire_ids.first().copied();
                    }
                    self.staged_transport_timestamp = None;
                    self.staged_with_end_time = with_end_time;
                    self.catalog_page_elapsed_ms = 0;
                }
                CatalogLoadPhase::AwaitingFirstPage => {
                    self.staged_catalog_entries.clear();
                    self.staged_seen_wire_ids.clear();
                    self.staged_first_page_head = page.wire_ids.first().copied();
                    self.staged_transport_timestamp = None;
                    self.staged_with_end_time = with_end_time;
                    self.catalog_page_elapsed_ms = 0;
                }
                CatalogLoadPhase::Paginating { .. } => {
                    if !page.wire_ids.is_empty()
                        && page
                            .wire_ids
                            .iter()
                            .all(|id| self.staged_seen_wire_ids.contains(id))
                        && self.staged_first_page_head == page.wire_ids.first().copied()
                        && page.file_count as usize == page.wire_ids.len()
                    {
                        return;
                    }
                }
            }

            let mut new_wire_id_seen = false;
            for &wid in &page.wire_ids {
                if self.staged_seen_wire_ids.insert(wid) {
                    new_wire_id_seen = true;
                }
            }
            for file in page.files {
                if let Some(existing) = self
                    .staged_catalog_entries
                    .iter_mut()
                    .find(|f| f.file_id == file.file_id)
                {
                    *existing = file;
                } else {
                    self.staged_catalog_entries.push(file);
                }
            }
            if let Some(ts) = page.current_transport_timestamp.filter(|&id| id > 0) {
                self.staged_transport_timestamp = Some(ts);
            }

            let current_page = match self.catalog_load_phase {
                CatalogLoadPhase::Idle | CatalogLoadPhase::AwaitingFirstPage => 0,
                CatalogLoadPhase::Paginating { next_page } => next_page.saturating_sub(1),
            };
            let next_page = current_page + 1;
            if with_end_time && page.file_count >= 10 && new_wire_id_seen && next_page < 128
            {
                self.catalog_load_phase = CatalogLoadPhase::Paginating {
                    next_page: next_page + 1,
                };
                self.catalog_page_elapsed_ms = 0;
                outcome
                    .outbound_tx_frames
                    .push(DeviceCommands::list_files_with_end_time(next_page));
            } else {
                self.finalize_staged_catalog(now_epoch_sec, outcome);
            }
    }
}
