use super::*;
use koe_engine::hash::sha256_hex;
use koe_engine::session::{CustodyReceipt, TransferPhaseTag};

impl KoeRuntime {
    pub(crate) fn is_device_file_synced(&self, file_id: u32) -> bool {
        if file_id == 0 {
            return false;
        }
        if self.device.session.has_disk_custody(file_id) {
            return true;
        }
        let has_asset = |id: &str| {
            recording_assets::audio_path(&self.root, id).is_ok_and(|p| p.exists())
                || recording_assets::opus_path(&self.root, id).is_ok_and(|p| p.exists())
        };
        if let Some(id) = self.captures.records_by_file_id.get(&file_id) {
            if has_asset(id)
                && self
                    .workspace()
                    .record(id)
                    .is_some_and(|r| r.all_day.is_none())
            {
                return true;
            }
        }
        self.workspace().records().values().any(|record| {
            record.origin == RecordOrigin::Bean
                && record.all_day.is_none()
                && record.aggregate.file_id == file_id
                && has_asset(&record.aggregate.recording_id)
        })
    }

    pub(crate) fn maybe_start_auto_offline_pull(&mut self) -> bool {
        if !self.device.is_connected()
            || self.device.awaiting_stop
            || self.device.session.device_recording_active
            || self.device.session.pending_realtime_subscribe
            || self.device.session.active_file_id.is_some()
            || !matches!(self.device.session.transfer.phase, TransferPhaseTag::Idle)
            || self.device.session.is_offline_pull_suspended()
            || self.device.session.is_catalog_loading()
        {
            return false;
        }
        let next = self
            .device
            .session
            .catalog
            .iter()
            .find(|entry| {
                (!self.is_quitting()
                    || self
                        .captures
                        .records_by_file_id
                        .contains_key(&entry.file_id))
                    && entry.has_duration()
                    && entry.end_time != Some(0)
                    && !self.device.auto_pull_attempted.contains(&entry.file_id)
                    && !self.workspace().is_bean_file_purged(entry.file_id)
                    && !self.is_device_file_synced(entry.file_id)
            })
            .map(|entry| (entry.file_id, entry.duration_ms));
        if let Some((file_id, duration_ms)) = next {
            self.device.auto_pull_attempted.insert(file_id);
            let frame = self.device.session.begin_offline_pull(file_id, duration_ms);
            self.device.outbound.push(frame);
            return true;
        }
        false
    }

    pub(super) fn save_device_recordings(&mut self, now: u64) -> Result<(), String> {
        while !self.device.finalized.is_empty() {
            let is_realtime = self.device.finalized[0].is_realtime;
            let recording = &self.device.finalized[0];
            let entry = recording.entry.clone();
            let digest = sha256_hex(&recording.ogg_opus_bytes);
            let capture_id = if is_realtime {
                self.captures
                    .targets
                    .front()
                    .filter(|(fid, _)| *fid == entry.id)
                    .map(|(_, rid)| rid.clone())
                    .or_else(|| self.captures.records_by_file_id.get(&entry.id).cloned())
                    .or_else(|| self.captures.active.get(&entry.id).cloned())
            } else {
                self.captures.records_by_file_id.get(&entry.id).cloned()
            };
            let id = capture_id
                .clone()
                .unwrap_or_else(|| format!("bean-{}-{}", entry.id, &digest[..16]));
            let is_new = self.workspace().record(&id).is_none();
            let has_audio = !recording.preview_wav_bytes.is_empty();
            let opus_path = recording_assets::opus_path(&self.root, &id)?;
            let should_skip_custody = recording.base_slice_offset > 0 && opus_path.exists();

            if !should_skip_custody {
                if has_audio {
                    recording_assets::save_audio(&self.root, &id, &recording.preview_wav_bytes)?;
                }
                recording_assets::save_opus(&self.root, &id, &recording.ogg_opus_bytes)
                    .map_err(|e| format!("原始录音保存失败：{e}"))?;
            }
            let byte_count = recording.ogg_opus_bytes.len() as u32;
            let receipt = CustodyReceipt {
                file_id: entry.id,
                byte_count,
                sha256_hex: digest,
                fsynced_at_epoch_sec: now,
            };
            let was_trashed = self
                .workspace()
                .record(&id)
                .is_some_and(ProductRecord::is_trashed);
            let realtime_group = (is_new && is_realtime)
                .then(|| self.all_day_group("bean"))
                .flatten();
            let realtime_mode = (is_new && is_realtime).then_some(self.bean_capture_mode).flatten();
            self.commit(|w| {
                w.insert_record(
                    id.clone(),
                    format!("录音 {}", entry.id),
                    RecordOrigin::Bean,
                    entry.id,
                    entry.created_at_epoch_sec,
                    entry.duration_ms,
                )?;
                if w.record(&id).is_some_and(ProductRecord::is_trashed) {
                    w.restore_record(&id)?;
                }
                if let Some(group) = realtime_group {
                    w.group_all_day(&id, group)?;
                } else if let Some(cm) = realtime_mode {
                    w.set_record_mode(&id, cm.to_record_mode())?;
                }
                w.finish_capture(&id, entry.duration_ms, &entry.marks_ms)
            })?;
            if was_trashed {
                self.clear_undo_trash_for(&id);
            }
            if !should_skip_custody
                && self
                    .workspace()
                    .record(&id)
                    .is_none_or(|r| r.all_day.is_none())
            {
                self.device.session.confirm_disk_custody(receipt);
            }
            self.device.finalized.remove(0);
            if is_realtime
                && self
                    .captures
                    .targets
                    .front()
                    .is_some_and(|(fid, _)| *fid == entry.id)
            {
                self.captures.targets.pop_front();
            }
            if !self.captures.active.contains_key(&entry.id)
                && !self.captures.targets.iter().any(|(fid, _)| *fid == entry.id)
            {
                self.captures.records_by_file_id.remove(&entry.id);
            }
            self.error = None;
            self.notice = Some(
                if has_audio {
                    "录音已取回并保存"
                } else {
                    "原始录音已保留，音频解码失败，暂时无法播放或转写"
                }
                .into(),
            );
            let had_live = self.capture_saved(&id);
            if has_audio && !had_live && (is_new || capture_id.is_some()) {
                self.auto_transcribe.insert(id);
            }
        }
        Ok(())
    }
}
