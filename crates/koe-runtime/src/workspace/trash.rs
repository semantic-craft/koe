use std::collections::BTreeSet;

use koe_engine::hash::sha256_hex;

use crate::*;

pub(crate) const UNDO_TRASH_WINDOW_MS: u64 = 8_000;

pub(crate) struct UndoTrashBanner {
    pub record_id: String,
    pub title: String,
    pub record_ids: Vec<String>,
    pub remaining_ms: u64,
}

fn dedup_record_ids(record_ids: &[String]) -> Vec<String> {
    let mut seen = BTreeSet::new();
    let mut out = Vec::with_capacity(record_ids.len());
    for id in record_ids {
        let trimmed = id.trim();
        if !trimmed.is_empty() && seen.insert(trimmed.to_owned()) {
            out.push(trimmed.to_owned());
        }
    }
    out
}

impl KoeRuntime {
    pub(crate) fn ensure_record_deletable(&self, id: &str) -> Result<(), String> {
        if let Some(prefix) = self.record_custody_busy_reason(id) {
            return Err(format!("{prefix}删除"));
        }
        let ask_cites_id = |op: Option<u64>| -> bool {
            self.workspace().pending_ask().is_some_and(|req| {
                op.is_none_or(|wanted| req.operation == wanted)
                    && (matches!(&req.scope, SearchScope::Record(rid) if rid == id)
                        || req.evidence.iter().any(|e| e.source.record_id == id))
            })
        };
        let record_pending = self
            .workspace()
            .record(id)
            .is_some_and(ProductRecord::has_pending_analysis);
        let pending_work_busy = self.pending.values().any(|work| match work {
            PendingWork::Transcription(key)
            | PendingWork::Summary(key)
            | PendingWork::LiveSummary { key, .. } => key.record_id == id,
            PendingWork::Ask(op) => ask_cites_id(Some(*op)),
        });
        let completed_busy = self.completed.iter().any(|event| {
            event.record_id == id
                || (event.record_id == "ask"
                    && match self.pending.get(&event.operation_id) {
                        Some(PendingWork::Ask(op)) => ask_cites_id(Some(*op)),
                        _ => ask_cites_id(None),
                    })
        });
        if record_pending || ask_cites_id(None) || pending_work_busy || completed_busy {
            return Err("这条记录仍在云端处理中，请等待完成后再删除".into());
        }
        Ok(())
    }

    pub(crate) fn active_runtime_audio_filenames(&self) -> BTreeSet<String> {
        let mut files = BTreeSet::new();
        if let Some(m) = self.active_capture.microphone() {
            files.extend(m.audio_filenames());
        }
        for id in self
            .captures
            .active
            .values()
            .chain(self.captures.sessions.keys())
            .chain(self.captures.targets.iter().map(|(_, rid)| rid))
        {
            files.insert(format!("{id}.wav"));
            files.insert(format!("{id}.opus"));
        }
        for finalized in &self.device.finalized {
            let digest = sha256_hex(&finalized.ogg_opus_bytes);
            let id = format!("bean-{}-{}", finalized.entry.id, &digest[..16]);
            files.insert(format!("{id}.wav"));
            files.insert(format!("{id}.opus"));
        }
        files
    }

    pub(crate) fn clear_undo_trash_for(&mut self, id: &str) {
        self.clear_undo_trash_in(&BTreeSet::from([id.to_string()]));
    }

    pub(crate) fn clear_undo_trash_in(&mut self, ids: &BTreeSet<String>) {
        let next_primary = {
            let Some(banner) = &mut self.undo_trash else {
                return;
            };
            banner.record_ids.retain(|rid| !ids.contains(rid));
            if banner.record_ids.is_empty() {
                self.undo_trash = None;
                return;
            }
            if ids.contains(&banner.record_id) {
                banner.record_id = banner.record_ids[0].clone();
                Some(banner.record_id.clone())
            } else {
                None
            }
        };
        if let Some(primary_id) = next_primary {
            let title = self
                .workspace()
                .record(&primary_id)
                .map(|r| r.title.clone());
            if let (Some(banner), Some(title)) = (&mut self.undo_trash, title) {
                banner.title = title;
            }
        }
    }

    pub(crate) fn detach_records_from_session(&mut self, removed_ids: &BTreeSet<String>) {
        if removed_ids.is_empty() {
            return;
        }
        for id in removed_ids {
            self.auto_transcribe.remove(id);
            self.auto_summarize.remove(id);
        }
        {
            let workspace = self.store.workspace();
            self.selection.detach_records(removed_ids, workspace);
            let purged_bean_ids = workspace.purged_bean_file_ids();
            if !purged_bean_ids.is_empty() {
                self.device
                    .session
                    .retain_custody_receipts(|fid| !purged_bean_ids.contains(&fid));
            }
        }
    }

    pub(crate) fn handle_set_record_archived(
        &mut self,
        record_id: &str,
        archived: bool,
    ) -> Result<(), String> {
        self.commit(|w| w.set_record_archived(record_id, archived))?;
        self.notice = Some(
            if archived {
                "已开启归档保护"
            } else {
                "已取消归档保护"
            }
            .into(),
        );
        Ok(())
    }

    pub(crate) fn handle_batch_set_record_archived(
        &mut self,
        record_ids: &[String],
        archived: bool,
    ) -> Result<(), String> {
        let ids = dedup_record_ids(record_ids);
        if ids.is_empty() {
            return Err("请先选择至少一条记录".into());
        }
        let live_ids: Vec<String> = ids
            .into_iter()
            .filter(|id| self.workspace().record(id).is_some_and(|r| r.is_live()))
            .collect();
        if live_ids.is_empty() {
            return Err("所选记录不存在或已在回收站中".into());
        }
        let count = live_ids.len();
        self.commit(|w| {
            for id in &live_ids {
                w.set_record_archived(id, archived)?;
            }
            Ok(())
        })?;
        self.notice = Some(if archived {
            format!("已批量开启归档保护（{count} 条）")
        } else {
            format!("已批量取消归档保护（{count} 条）")
        });
        Ok(())
    }

    pub(crate) fn handle_trash_record(&mut self, record_id: &str, now: u64) -> Result<(), String> {
        let _ = self.reclaim_stale_summaries();
        self.ensure_record_deletable(record_id)?;
        let now_ms = now.max(1).saturating_mul(1000);
        let title = self.commit(|w| {
            w.trash_record(record_id, now_ms)?;
            Ok(w.record(record_id)
                .map(|r| r.title.clone())
                .unwrap_or_default())
        })?;
        self.detach_records_from_session(&BTreeSet::from([record_id.to_string()]));
        self.undo_trash = Some(UndoTrashBanner {
            record_id: record_id.to_string(),
            title,
            record_ids: vec![record_id.to_string()],
            remaining_ms: UNDO_TRASH_WINDOW_MS,
        });
        Ok(())
    }

    pub(crate) fn handle_batch_trash_records(
        &mut self,
        record_ids: &[String],
        now: u64,
    ) -> Result<(), String> {
        let ids = dedup_record_ids(record_ids);
        if ids.is_empty() {
            return Err("请先选择至少一条记录".into());
        }
        let _ = self.reclaim_stale_summaries();
        let mut deletable = Vec::new();
        let mut skipped_protected = 0usize;
        for id in &ids {
            let Some(record) = self.workspace().record(id) else {
                continue;
            };
            if record.is_trashed() {
                continue;
            }
            if record.is_archived() || self.ensure_record_deletable(id).is_err() {
                skipped_protected += 1;
                continue;
            }
            deletable.push(id.clone());
        }
        if deletable.is_empty() {
            return Err(if skipped_protected > 0 {
                "选中的记录均已开启归档保护或正在处理，无法移入回收站".into()
            } else {
                "没有可移入回收站的记录".into()
            });
        }
        let now_ms = now.max(1).saturating_mul(1000);
        let first_title = self.commit(|w| {
            for id in &deletable {
                w.trash_record(id, now_ms)?;
            }
            Ok(w.record(&deletable[0])
                .map(|r| r.title.clone())
                .unwrap_or_default())
        })?;
        let trashed_set: BTreeSet<String> = deletable.iter().cloned().collect();
        self.detach_records_from_session(&trashed_set);
        let trashed_count = deletable.len();
        self.undo_trash = Some(UndoTrashBanner {
            record_id: deletable[0].clone(),
            title: first_title,
            record_ids: deletable,
            remaining_ms: UNDO_TRASH_WINDOW_MS,
        });
        if skipped_protected > 0 {
            self.notice = Some(format!(
                "已将 {trashed_count} 条记录移入回收站（已跳过 {skipped_protected} 条受保护或处理中记录）"
            ));
        } else if trashed_count > 1 {
            self.notice = Some(format!("已将 {trashed_count} 条记录移入回收站"));
        }
        Ok(())
    }

    pub(crate) fn handle_restore_record(&mut self, record_id: &str) -> Result<(), String> {
        self.commit(|w| w.restore_record(record_id))?;
        self.clear_undo_trash_for(record_id);
        self.clear_error();
        self.notice = Some("已从回收站恢复记录".into());
        Ok(())
    }

    pub(crate) fn handle_batch_restore_records(
        &mut self,
        record_ids: &[String],
    ) -> Result<(), String> {
        let ids = dedup_record_ids(record_ids);
        if ids.is_empty() {
            return Err("请先选择要恢复的记录".into());
        }
        let restorable: Vec<String> = ids
            .into_iter()
            .filter(|id| self.workspace().record(id).is_some_and(|r| r.is_trashed()))
            .collect();
        if restorable.is_empty() {
            return Err("所选记录不在回收站中".into());
        }
        let count = restorable.len();
        self.commit(|w| {
            for id in &restorable {
                w.restore_record(id)?;
            }
            Ok(())
        })?;
        let restored_set: BTreeSet<String> = restorable.into_iter().collect();
        self.clear_undo_trash_in(&restored_set);
        self.clear_error();
        self.notice = Some(if count == 1 {
            "已从回收站恢复记录".into()
        } else {
            format!("已从回收站恢复 {count} 条记录")
        });
        Ok(())
    }

    pub(crate) fn handle_purge_record(&mut self, record_id: &str) -> Result<(), String> {
        let _ = self.reclaim_stale_summaries();
        self.ensure_record_deletable(record_id)?;
        let receipt = self.commit(|w| w.purge_record(record_id))?;
        self.detach_records_from_session(&receipt.purged_record_ids);
        self.clear_undo_trash_in(&receipt.purged_record_ids);
        if let Err(e) = self.try_reconcile_orphan_audio() {
            return Err(format!("记录已移除，音频文件稍后自动重试清理：{e}"));
        }
        self.notice = Some("记录已永久删除".into());
        Ok(())
    }

    pub(crate) fn handle_empty_trash(&mut self) -> Result<(), String> {
        let _ = self.reclaim_stale_summaries();
        let trashed_ids: Vec<String> = self
            .workspace()
            .records()
            .iter()
            .filter(|(_, r)| r.is_trashed())
            .map(|(id, _)| id.clone())
            .collect();
        for id in &trashed_ids {
            self.ensure_record_deletable(id)?;
        }
        let receipt = self.commit(|w| w.empty_trash())?;
        self.detach_records_from_session(&receipt.purged_record_ids);
        self.clear_undo_trash_in(&receipt.purged_record_ids);
        if let Err(e) = self.try_reconcile_orphan_audio() {
            return Err(format!("记录已移除，音频文件稍后自动重试清理：{e}"));
        }
        if !receipt.purged_record_ids.is_empty() {
            self.notice = Some("回收站已清空".into());
        }
        Ok(())
    }

    pub(crate) fn handle_dismiss_undo_trash(&mut self) {
        let _ = self.undo_trash.take();
    }

    pub(crate) fn tick_undo_trash(&mut self, elapsed_ms: u64) -> bool {
        let Some(banner) = &mut self.undo_trash else {
            return false;
        };
        banner.remaining_ms = banner.remaining_ms.saturating_sub(elapsed_ms);
        if banner.remaining_ms == 0 {
            self.undo_trash = None;
            return true;
        }
        false
    }

    pub(crate) fn reconcile_expired_trash(&mut self, now_epoch_sec: u64) -> bool {
        if now_epoch_sec == 0 || self.store.requires_reopen() {
            return false;
        }
        let now_ms = now_epoch_sec.saturating_mul(1000);
        if !self.workspace().has_expired_trash(now_ms) {
            return false;
        }
        let mut deletable_expired = Vec::new();
        let mut any_runtime_blocked = false;
        for (id, record) in self.workspace().records() {
            if record.retention().is_expired_at(now_ms) {
                if self.ensure_record_deletable(id).is_ok() {
                    deletable_expired.push(id.clone());
                } else {
                    any_runtime_blocked = true;
                }
            }
        }
        if deletable_expired.is_empty() {
            return false;
        }
        let commit_res = if !any_runtime_blocked {
            self.commit(|w| w.purge_expired_trash(now_ms))
        } else {
            self.commit(|w| {
                let mut merged = PurgeReceipt::default();
                for id in &deletable_expired {
                    let receipt = w.purge_record(id)?;
                    merged.purged_record_ids.extend(receipt.purged_record_ids);
                }
                Ok(merged)
            })
        };
        let receipt = match commit_res {
            Ok(receipt) => receipt,
            Err(error) => {
                self.set_error(error);
                return true;
            }
        };
        if receipt.purged_record_ids.is_empty() {
            return false;
        }
        self.detach_records_from_session(&receipt.purged_record_ids);
        self.clear_undo_trash_in(&receipt.purged_record_ids);
        if let Err(e) = self.try_reconcile_orphan_audio() {
            self.set_error(format!("记录已移除，音频文件稍后自动重试清理：{e}"));
        }
        true
    }

    pub(crate) fn try_reconcile_orphan_audio(&mut self) -> Result<usize, String> {
        let mut retained = self.workspace().referenced_audio_filenames();
        retained.extend(self.active_runtime_audio_filenames());
        let result = recording_assets::reconcile_audio_directory(&self.root, &retained);
        self.refresh_audio_storage_summary();
        result
    }

    pub(crate) fn reconcile_orphan_audio(&mut self) {
        if let Err(error) = self.try_reconcile_orphan_audio() {
            self.set_error(error);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct Sandbox(PathBuf);
    impl Sandbox {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(1);
            let path = std::env::temp_dir().join(format!(
                "koe-trash-unit-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn batch_trash_skips_record_with_pending_live_summary_and_trashes_siblings() {
        let dir = Sandbox::new();
        let mut runtime = KoeRuntime::open(&dir.0).unwrap();
        let now = 1_800_000_000u64;

        runtime
            .commit(|w| {
                w.insert_record(
                    "rec-busy".into(),
                    "Busy Live Summary".into(),
                    RecordOrigin::Microphone,
                    0,
                    now,
                    1_000,
                )?;
                w.append_transcript("rec-busy", "live summary text", 0, 1_000, "asr")?;
                let _ = w.begin_live_summary("rec-busy")?;
                w.insert_record(
                    "rec-idle".into(),
                    "Idle Sibling".into(),
                    RecordOrigin::Note,
                    0,
                    now + 1,
                    0,
                )?;
                Ok(())
            })
            .unwrap();

        assert!(runtime.ensure_record_deletable("rec-busy").is_err());

        let snap: Value = serde_json::from_str(&runtime.dispatch_json(
            &json!({
                "type": "batch_trash_records",
                "recordIds": ["rec-busy", "rec-idle"]
            })
            .to_string(),
            now + 2,
        ))
        .unwrap();
        assert!(snap["error"].is_null(), "{}", snap["error"]);
        assert!(runtime.workspace().record("rec-busy").unwrap().is_live());
        assert!(runtime.workspace().record("rec-idle").unwrap().is_trashed());
    }
}
