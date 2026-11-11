use std::collections::BTreeSet;

use koe_client_base::hash::sha256_hex;
use koe_engine::session::{TransferPhaseTag, TransferRuntimeState};

use super::*;

pub(super) const UNDO_TRASH_WINDOW_MS: u64 = 8_000;

pub(super) struct UndoTrashBanner {
    pub record_id: String,
    pub title: String,
    pub remaining_ms: u64,
}

impl KoeRuntime {
    pub(super) fn ensure_record_deletable(&self, id: &str) -> Result<(), String> {
        if self.microphone.as_ref().is_some_and(|m| m.owns_id(id)) {
            return Err("录音仍在进行或等待保存，完成后才能删除".into());
        }
        let in_captures = self.captures.active.values().any(|rid| rid == id)
            || self
                .captures
                .records_by_file_id
                .values()
                .any(|rid| rid == id)
            || self.captures.sessions.contains_key(id)
            || self.captures.targets.iter().flatten().any(|rid| rid == id);
        if in_captures {
            return Err("这条录音仍在取回或处理中，请等待完成后再删除".into());
        }
        let bean_file_id = self
            .workspace()
            .record(id)
            .filter(|r| r.origin == RecordOrigin::Bean && r.aggregate.file_id > 0)
            .map(|r| r.aggregate.file_id);
        if let Some(fid) = bean_file_id {
            let session = &self.device.session;
            let transfer_busy = session.active_file_id == Some(fid)
                || matches!(
                    session.runtime_state,
                    TransferRuntimeState::PullingOffline { file_id, .. }
                        | TransferRuntimeState::Suspended { file_id, .. }
                        | TransferRuntimeState::StreamingRealtime { file_id, .. }
                        if file_id == fid
                )
                || (matches!(
                    session.transfer.phase,
                    TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
                ) && session.transfer.file_id == fid);
            let capture_busy = self.captures.active.contains_key(&fid)
                || self.captures.records_by_file_id.contains_key(&fid);
            let finalized_busy = self.device.finalized.iter().any(|r| r.entry.id == fid);
            if transfer_busy || capture_busy || finalized_busy {
                return Err("这条录音正在同步或录制中，请等待完成后再删除".into());
            }
        }
        if self.device.finalized.iter().any(|r| {
            let digest = sha256_hex(&r.ogg_opus_bytes);
            format!("bean-{}-{}", r.entry.id, &digest[..16]) == id
        }) {
            return Err("这条录音正在保存落盘，请稍候再试".into());
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
            .is_some_and(|r| matches!(r.analysis, AnalysisState::Pending { .. }));
        let pending_work_busy = self.pending.values().any(|work| match work {
            PendingWork::Transcription(key) | PendingWork::Summary(key) => key.record_id == id,
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

    pub(super) fn active_runtime_audio_filenames(&self) -> BTreeSet<String> {
        let mut files = BTreeSet::new();
        if let Some(m) = &self.microphone {
            files.extend(m.audio_filenames());
        }
        for id in self
            .captures
            .active
            .values()
            .chain(self.captures.records_by_file_id.values())
            .chain(self.captures.sessions.keys())
            .chain(self.captures.targets.iter().flatten())
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

    pub(super) fn detach_records_from_session(&mut self, removed_ids: &BTreeSet<String>) {
        if removed_ids.is_empty() {
            return;
        }
        for id in removed_ids {
            self.auto_transcribe.remove(id);
            self.auto_summarize.remove(id);
        }
        let purged_bean_ids = self.workspace().purged_bean_file_ids().clone();
        if !purged_bean_ids.is_empty() {
            self.device
                .session
                .custody_receipts
                .retain(|fid, _| !purged_bean_ids.contains(fid));
        }
        if self
            .playback
            .record
            .as_ref()
            .is_some_and(|id| removed_ids.contains(id))
        {
            self.playback.record = None;
            self.playback.lane = None;
            self.playback.position_ms = 0;
            self.playback.playing = false;
            self.playback.request_id = self.playback.request_id.saturating_add(1);
        }
        let mut cleaned_back = Vec::with_capacity(self.back.len());
        for mut loc in std::mem::take(&mut self.back) {
            let dead_record = loc.record.as_ref().is_some_and(|id| {
                removed_ids.contains(id)
                    || !self
                        .workspace()
                        .record(id)
                        .is_some_and(ProductRecord::is_live)
            });
            if dead_record {
                if loc.page == Page::Detail {
                    continue;
                }
                loc.record = None;
                loc.segment = None;
            }
            cleaned_back.push(loc);
        }
        self.back = cleaned_back;

        if self
            .location
            .record
            .as_ref()
            .is_some_and(|id| removed_ids.contains(id))
        {
            if self.location.page == Page::Detail {
                let fallback = self.back.pop().unwrap_or(Location {
                    page: Page::Records,
                    record: None,
                    segment: None,
                });
                self.set_location(fallback);
            } else {
                self.location.record = None;
                self.location.segment = None;
            }
        }
    }

    pub(super) fn handle_set_record_archived(
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

    pub(super) fn handle_trash_record(&mut self, record_id: &str, now: u64) -> Result<(), String> {
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
            remaining_ms: UNDO_TRASH_WINDOW_MS,
        });
        Ok(())
    }

    pub(super) fn handle_restore_record(&mut self, record_id: &str) -> Result<(), String> {
        self.commit(|w| w.restore_record(record_id))?;
        if self
            .undo_trash
            .as_ref()
            .is_some_and(|u| u.record_id == record_id)
        {
            self.undo_trash = None;
        }
        self.error = None;
        self.notice = Some("已从回收站恢复记录".into());
        Ok(())
    }

    pub(super) fn handle_purge_record(&mut self, record_id: &str) -> Result<(), String> {
        self.ensure_record_deletable(record_id)?;
        let receipt = self.commit(|w| w.purge_record(record_id))?;
        self.detach_records_from_session(&receipt.purged_record_ids);
        if self
            .undo_trash
            .as_ref()
            .is_some_and(|u| receipt.purged_record_ids.contains(&u.record_id))
        {
            self.undo_trash = None;
        }
        self.try_reconcile_orphan_audio()?;
        self.notice = Some("记录已永久删除".into());
        Ok(())
    }

    pub(super) fn handle_empty_trash(&mut self) -> Result<(), String> {
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
        if self
            .undo_trash
            .as_ref()
            .is_some_and(|u| receipt.purged_record_ids.contains(&u.record_id))
        {
            self.undo_trash = None;
        }
        self.try_reconcile_orphan_audio()?;
        if !receipt.purged_record_ids.is_empty() {
            self.notice = Some("回收站已清空".into());
        }
        Ok(())
    }

    pub(super) fn handle_dismiss_undo_trash(&mut self) {
        let _ = self.undo_trash.take();
    }

    pub(super) fn tick_undo_trash(&mut self, elapsed_ms: u64) -> bool {
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

    pub(super) fn reconcile_expired_trash(&mut self, now_epoch_sec: u64) -> bool {
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
                    merged
                        .unlinked_audio_filenames
                        .extend(receipt.unlinked_audio_filenames);
                }
                Ok(merged)
            })
        };
        let receipt = match commit_res {
            Ok(receipt) => receipt,
            Err(error) => {
                self.error = Some(error);
                return true;
            }
        };
        if receipt.purged_record_ids.is_empty() {
            return false;
        }
        self.detach_records_from_session(&receipt.purged_record_ids);
        if self
            .undo_trash
            .as_ref()
            .is_some_and(|u| receipt.purged_record_ids.contains(&u.record_id))
        {
            self.undo_trash = None;
        }
        self.reconcile_orphan_audio();
        true
    }

    pub(super) fn try_reconcile_orphan_audio(&self) -> Result<usize, String> {
        let mut retained = self.workspace().referenced_audio_filenames();
        retained.extend(self.active_runtime_audio_filenames());
        recording_assets::reconcile_audio_directory(&self.root, &retained)
    }

    pub(super) fn reconcile_orphan_audio(&mut self) {
        if let Err(error) = self.try_reconcile_orphan_audio() {
            self.error = Some(error);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use koe_client_providers::{ProviderEvent, ProviderOutput, TranscriptSegment};
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
    fn late_provider_results_on_trashed_or_purged_records_drop_without_drain_error() {
        let dir = Sandbox::new();
        let mut runtime = KoeRuntime::open(&dir.0).unwrap();
        let now = 1_800_000_000u64;

        runtime
            .commit(|w| {
                w.insert_record(
                    "rec-trashed".into(),
                    "Trashed Target".into(),
                    RecordOrigin::ImportedAudio,
                    0,
                    now,
                    100,
                )?;
                w.trash_record("rec-trashed", now * 1000)?;
                w.insert_record(
                    "rec-purged".into(),
                    "Purged Target".into(),
                    RecordOrigin::ImportedAudio,
                    0,
                    now,
                    100,
                )?;
                w.trash_record("rec-purged", now * 1000)?;
                w.purge_record("rec-purged")?;
                Ok(())
            })
            .unwrap();

        let trashed_key = RequestKey {
            record_id: "rec-trashed".into(),
            attempt: 1,
            input_revision: 0,
        };
        let purged_key = RequestKey {
            record_id: "rec-purged".into(),
            attempt: 2,
            input_revision: 0,
        };

        runtime
            .pending
            .insert(101, PendingWork::Transcription(trashed_key.clone()));
        runtime.completed.push_back(ProviderEvent {
            operation_id: 101,
            record_id: "rec-trashed".into(),
            result: Ok(ProviderOutput::Transcript {
                segments: vec![TranscriptSegment {
                    start_ms: 0,
                    end_ms: 50,
                    text: "late transcript".into(),
                }],
            }),
        });

        runtime
            .pending
            .insert(102, PendingWork::Summary(purged_key.clone()));
        runtime.completed.push_back(ProviderEvent {
            operation_id: 102,
            record_id: "rec-purged".into(),
            result: Ok(ProviderOutput::Chat {
                text: r#"{"overview":"summary"}"#.into(),
            }),
        });

        runtime
            .pending
            .insert(103, PendingWork::Transcription(trashed_key));
        runtime.completed.push_back(ProviderEvent {
            operation_id: 103,
            record_id: "rec-trashed".into(),
            result: Err("network timeout".into()),
        });

        runtime
            .pending
            .insert(104, PendingWork::Summary(purged_key));
        runtime.completed.push_back(ProviderEvent {
            operation_id: 104,
            record_id: "rec-purged".into(),
            result: Err("network timeout".into()),
        });

        runtime.poll_timers(0, now);
        assert!(runtime.pending.is_empty());
        assert!(runtime.completed.is_empty());
        assert!(runtime.drain_error.is_none());

        let quit: Value = serde_json::from_str(
            &runtime.dispatch_json(&json!({"type": "request_quit"}).to_string(), now),
        )
        .unwrap();
        assert_eq!(quit["lifecycle"]["quitPhase"], "ready");
        assert_eq!(quit["lifecycle"]["keepAwake"], false);
    }
}
