use super::*;
use koe_client_base::{hash::sha256_hex, write_atomic};
use koe_engine::{
    commands::DeviceCommands,
    session::{CustodyReceipt, TransferPhaseTag},
};
use std::fs;

impl KoeRuntime {
    pub(super) fn recover_local_captures(&mut self) -> Result<(), String> {
        let ids: Vec<_> = self
            .workspace()
            .records()
            .values()
            .filter(|record| record.is_live())
            .map(|r| r.aggregate.recording_id.clone())
            .collect();
        for id in ids {
            if let Some(duration) =
                koe_client_services::capture_asset::CaptureAsset::recover(&self.root, &id)?
            {
                self.commit(|w| w.finish_capture(&id, duration, &[]))?;
                koe_client_services::capture_asset::CaptureAsset::release_recovered(
                    &self.root, &id,
                )?;
            }
        }
        self.auto_transcribe.extend(
            self.workspace()
                .records()
                .values()
                .filter(|r| {
                    matches!(r.analysis, AnalysisState::Interrupted { .. })
                        && matches!(
                            r.speech_engine,
                            Some(SpeechEngine::AppleSpeech | SpeechEngine::Downloaded(_))
                        )
                        && recording_assets::audio_path(&self.root, &r.aggregate.recording_id)
                            .is_ok_and(|p| p.is_file())
                })
                .map(|r| r.aggregate.recording_id.clone())
                .collect::<Vec<_>>(),
        );
        Ok(())
    }
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
        if (self.active_companion_mode() == CompanionRoutingMode::CollarStandby
            && !self.companion.standby_suppressed_for_connection)
            || self.companion.standby_stream_owned
            || self.companion.pending_standby_stop
            || !self.device.is_connected()
            || self.device.awaiting_stop
            || self.device.session.device_recording_active
            || self.device.session.pending_realtime_subscribe
            || self.device.session.active_file_id.is_some()
            || !matches!(self.device.session.transfer.phase, TransferPhaseTag::Idle)
            || self.device.session.is_offline_pull_suspended()
            || self.device.session.is_catalog_loading()
            || self.current_companion_recording_state() != 0
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
                    && !self.is_standby_file(entry.file_id)
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
            let entry_id = self.device.finalized[0].entry.id;
            let is_realtime = self.device.finalized[0].is_realtime;
            let is_standby_recording = !self.is_known_bean_record(entry_id)
                && (self.is_standby_file(entry_id)
                    || (is_realtime
                        && (self.companion.standby_stream_owned
                            || self.companion.pending_standby_stop)));
            if is_standby_recording {
                self.device.finalized.remove(0);
                if is_realtime
                    && self
                        .captures
                        .targets
                        .front()
                        .is_some_and(|(fid, _)| *fid == entry_id)
                {
                    self.captures.targets.pop_front();
                }
                self.captures.active.remove(&entry_id);
                self.captures.records_by_file_id.remove(&entry_id);
                if self.companion.active_standby_file_id == Some(entry_id) {
                    self.companion.active_standby_file_id = None;
                }
                if !self.can_own_as_standby_scratch(entry_id) {
                    continue;
                }
                if self.device.is_connected() && self.current_companion_recording_state() == 0 {
                    if self.companion.deleted_in_connection.insert(entry_id) {
                        self.device
                            .outbound
                            .push(DeviceCommands::delete_file(entry_id));
                    }
                    self.device.session.remove_catalog_entry(entry_id);
                    self.companion.standby_file_ids.insert(entry_id);
                    self.commit(|w| {
                        w.record_purged_bean_file_id(entry_id);
                        Ok(())
                    })?;
                } else {
                    self.mark_standby_scratch_file(entry_id)?;
                }
                continue;
            }
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
                fs::create_dir_all(self.root.join("audio")).map_err(|e| e.to_string())?;
                write_atomic(&opus_path, &recording.ogg_opus_bytes)
                    .map_err(|e| format!("原始录音保存失败：{e}"))?;
                fs::File::open(self.root.join("audio"))
                    .and_then(|f| f.sync_all())
                    .map_err(|e| format!("录音尚未完成落盘：{e}"))?;
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

    pub(super) fn export_record(&mut self, id: &str, path: &Path) -> Result<(), String> {
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        let mut output = format!("# {}\n\n", record.title);
        if let Some(minutes) = &record.aggregate.minutes {
            if record.is_minutes_stale() {
                output.push_str("> 注：原文已变更，以下纪要待重新整理。\n\n");
            }
            output.push_str(&format!("{}\n\n", minutes.overview));
            for topic in &minutes.topics {
                output.push_str(&format!("## {}\n\n{}\n\n", topic.title, topic.summary));
            }
        }
        output.push_str("## 原文\n\n");
        for segment in record.aggregate.spine.segments() {
            if let Some(sp) = segment.speaker.as_deref().filter(|s| !s.is_empty()) {
                output.push_str(&format!("[{}] {}：{}\n\n", segment.id, sp, segment.text));
            } else {
                output.push_str(&format!("[{}] {}\n\n", segment.id, segment.text));
            }
        }
        write_atomic(path, output.as_bytes()).map_err(|e| format!("导出失败：{e}"))?;
        self.notice = Some("已导出 Markdown".into());
        Ok(())
    }
}
