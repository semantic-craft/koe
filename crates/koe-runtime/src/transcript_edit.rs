use koe_engine::hash::sha256_hex;

use super::*;

impl KoeRuntime {
    pub(super) fn record_custody_busy_reason(&self, id: &str) -> Option<&'static str> {
        if self.microphone.as_ref().is_some_and(|m| m.owns_id(id)) {
            return Some("录音仍在进行或等待保存，完成后才能");
        }
        let in_captures = self.captures.active.values().any(|rid| rid == id)
            || self
                .captures
                .records_by_file_id
                .values()
                .any(|rid| rid == id)
            || self.captures.sessions.contains_key(id)
            || self.captures.targets.iter().any(|(_, rid)| rid == id);
        if in_captures {
            return Some("这条录音正在同步或保存中，请等待完成后再");
        }
        if let Some((fid_str, suffix)) = id.strip_prefix("bean-").and_then(|s| s.split_once('-')) {
            if suffix.len() == 16 {
                if let Ok(fid) = fid_str.parse::<u32>() {
                    if self.device.finalized.iter().any(|r| {
                        r.entry.id == fid && &sha256_hex(&r.ogg_opus_bytes)[..16] == suffix
                    }) {
                        return Some("这条录音正在同步或保存中，请等待完成后再");
                    }
                }
            }
        }
        let bean_file_id = self
            .workspace()
            .record(id)
            .filter(|r| r.origin == RecordOrigin::Bean && r.aggregate.file_id > 0)
            .map(|r| r.aggregate.file_id);
        if let Some(fid) = bean_file_id {
            let transfer_busy = self.device.session.is_file_in_flight(fid);
            let capture_busy = self.captures.active.contains_key(&fid)
                || self.captures.records_by_file_id.contains_key(&fid);
            let finalized_busy = self.device.finalized.iter().any(|r| r.entry.id == fid);
            if transfer_busy || capture_busy || finalized_busy {
                return Some("这条录音正在同步或保存中，请等待完成后再");
            }
        }
        None
    }

    pub(super) fn ensure_record_editable(&self, id: &str) -> Result<(), String> {
        if self.is_quitting() {
            return Err("应用正在保存并退出，暂不接受编辑".into());
        }
        if self.store.requires_reopen() {
            return Err("保存结果尚未确认，请重新打开工作区".into());
        }
        if let Some(prefix) = self.record_custody_busy_reason(id) {
            return Err(format!("{prefix}编辑原文"));
        }
        let record = self
            .workspace()
            .record(id)
            .ok_or_else(|| ProductError::UnknownRecord.to_string())?;
        record
            .ensure_transcript_editable()
            .map_err(|e| e.to_string())?;
        let transcription_pending = self
            .pending
            .values()
            .any(|work| matches!(work, PendingWork::Transcription(key) if key.record_id == id))
            || self.completed.iter().any(|event| {
                event.record_id == id
                    && matches!(
                        self.pending.get(&event.operation_id),
                        Some(PendingWork::Transcription(_))
                    )
            })
            || self.auto_transcribe.contains(id);
        if transcription_pending {
            return Err("这条录音正在转写中，请等待完成后再编辑原文".into());
        }
        Ok(())
    }

    pub(super) fn can_edit_record(&self, id: &str) -> bool {
        self.ensure_record_editable(id).is_ok()
    }

    pub(super) fn edit_segment_text(
        &mut self,
        record_id: &str,
        segment_id: &str,
        text: &str,
    ) -> Result<(), String> {
        self.ensure_record_editable(record_id)?;
        let source = source_ref(record_id, segment_id)?;
        let receipt = self.commit(|w| w.edit_segment_text(&source, text))?;
        self.error = None;
        if receipt.updated_segments > 0 {
            let _ = self.reclaim_stale_summaries();
            self.drive_analysis_queue();
            self.notice = Some("已更新原文片段".into());
        }
        Ok(())
    }

    pub(super) fn set_segment_speaker(
        &mut self,
        record_id: &str,
        segment_id: &str,
        speaker: Option<&str>,
    ) -> Result<(), String> {
        self.ensure_record_editable(record_id)?;
        let source = source_ref(record_id, segment_id)?;
        let receipt = self.commit(|w| w.set_segment_speaker(&source, speaker))?;
        self.error = None;
        if receipt.updated_segments > 0 {
            let _ = self.reclaim_stale_summaries();
            self.drive_analysis_queue();
            self.notice = Some("已更新说话人".into());
        }
        Ok(())
    }

    pub(super) fn rename_speaker(
        &mut self,
        record_id: &str,
        from_speaker: &str,
        to_speaker: &str,
    ) -> Result<TranscriptEditReceipt, String> {
        self.ensure_record_editable(record_id)?;
        let target = SpeakerName::parse(to_speaker).map_err(|e| e.to_string())?;
        let receipt = self.commit(|w| w.rename_speaker(record_id, from_speaker, target.as_str()))?;
        self.error = None;
        if receipt.updated_segments > 0 {
            let _ = self.reclaim_stale_summaries();
            self.drive_analysis_queue();
            self.notice = Some(format!(
                "已将 {} 段说话人更新为 {}",
                receipt.updated_segments,
                target.as_str()
            ));
        }
        Ok(receipt)
    }
}
