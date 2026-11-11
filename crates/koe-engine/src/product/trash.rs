use std::collections::BTreeSet;
use std::num::NonZeroU64;

use super::*;
use crate::context::{relabel_citations, SourceLine};

/// Retention window for soft-deleted recordings in milliseconds (30 days).
pub const TRASH_RETENTION_MS: u64 = 30 * 86_400_000;

/// Exclusive retention and accidental-deletion protection state of a recording.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum RecordRetention {
    /// Normal live recording visible across workspace views and search.
    #[default]
    Active,
    /// Live recording locked against soft-delete and permanent purge.
    Archived,
    /// Soft-deleted recording held in the 30-day trash.
    Trashed {
        /// Non-zero soft-deletion timestamp in Unix milliseconds.
        trashed_at_ms: NonZeroU64,
    },
}

impl RecordRetention {
    /// Constructs a validated retention state from persisted boundary values.
    pub fn from_persisted(
        archived: bool,
        trashed_at_ms: Option<u64>,
    ) -> Result<Self, ProductError> {
        match (archived, trashed_at_ms) {
            (false, None) => Ok(Self::Active),
            (true, None) => Ok(Self::Archived),
            (false, Some(ms)) => NonZeroU64::new(ms)
                .map(|trashed_at_ms| Self::Trashed { trashed_at_ms })
                .ok_or(ProductError::InvalidEvidence),
            (true, Some(_)) => Err(ProductError::InvalidEvidence),
        }
    }

    /// Returns `true` when the recording is `Active` or `Archived`.
    #[must_use]
    pub const fn is_live(self) -> bool {
        !matches!(self, Self::Trashed { .. })
    }

    /// Returns `true` when archive protection is enabled.
    #[must_use]
    pub const fn is_archived(self) -> bool {
        matches!(self, Self::Archived)
    }

    /// Returns `true` when the recording is currently in the 30-day trash.
    #[must_use]
    pub const fn is_trashed(self) -> bool {
        matches!(self, Self::Trashed { .. })
    }

    /// Returns the soft-deletion timestamp in Unix milliseconds if trashed.
    #[must_use]
    pub const fn trashed_at_ms(self) -> Option<u64> {
        match self {
            Self::Trashed { trashed_at_ms } => Some(trashed_at_ms.get()),
            Self::Active | Self::Archived => None,
        }
    }

    /// Returns the Unix millisecond timestamp when 30-day trash retention expires.
    #[must_use]
    pub const fn expires_at_ms(self) -> Option<u64> {
        match self {
            Self::Trashed { trashed_at_ms } => {
                Some(trashed_at_ms.get().saturating_add(TRASH_RETENTION_MS))
            }
            Self::Active | Self::Archived => None,
        }
    }

    /// Returns `true` when the recording is trashed and `now_ms >= expires_at_ms`.
    #[must_use]
    pub const fn is_expired_at(self, now_ms: u64) -> bool {
        match self.expires_at_ms() {
            Some(expires_at_ms) => now_ms >= expires_at_ms,
            None => false,
        }
    }
}

/// Pure outcome of permanently purging zero or more recordings from `ProductWorkspace`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PurgeReceipt {
    /// Recording identifiers permanently removed in this transaction.
    pub purged_record_ids: BTreeSet<RecordId>,
}

impl ProductRecord {
    /// Current retention state of this recording.
    #[must_use]
    pub const fn retention(&self) -> RecordRetention {
        self.retention
    }

    /// Returns `true` when this recording is not in the trash.
    #[must_use]
    pub const fn is_live(&self) -> bool {
        self.retention.is_live()
    }

    /// Returns `true` when this recording is locked by archive protection.
    #[must_use]
    pub const fn is_archived(&self) -> bool {
        self.retention.is_archived()
    }

    /// Returns `true` when this recording is in the 30-day trash.
    #[must_use]
    pub const fn is_trashed(&self) -> bool {
        self.retention.is_trashed()
    }

    /// Restores validated retention state during workspace reconstruction.
    pub fn restore_retention(&mut self, retention: RecordRetention) {
        self.retention = retention;
    }

    /// Rejects live mutations when this recording is in the trash.
    pub fn ensure_live(&self) -> Result<(), ProductError> {
        if self.is_trashed() {
            Err(ProductError::RecordTrashed)
        } else {
            Ok(())
        }
    }

    /// Returns all candidate audio basenames owned by this recording.
    #[must_use]
    pub fn owned_audio_filenames(&self) -> BTreeSet<String> {
        let mut files = BTreeSet::new();
        let id = &self.aggregate.recording_id;
        files.insert(format!("{id}.wav"));
        files.insert(format!("{id}.opus"));
        for lane in &self.capture_lanes {
            if let Some(asset_id) = &lane.asset_id {
                files.insert(format!("{asset_id}.wav"));
            }
        }
        files
    }
}

impl ProductWorkspace {
    /// Enables or clears accidental-deletion archive protection on a live recording.
    pub fn set_record_archived(&mut self, id: &str, archived: bool) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        let target = if archived {
            RecordRetention::Archived
        } else {
            RecordRetention::Active
        };
        if record.retention != target {
            record.retention = target;
            self.changed();
        }
        Ok(())
    }

    /// Soft-deletes a non-archived recording into the 30-day trash at `now_ms`.
    pub fn trash_record(&mut self, id: &str, now_ms: u64) -> Result<(), ProductError> {
        let trashed_at_ms = NonZeroU64::new(now_ms)
            .ok_or_else(|| ProductError::InvalidInput("删除时间无效".to_string()))?;
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        if record.is_trashed() {
            return Ok(());
        }
        if record.is_archived() {
            return Err(ProductError::RecordArchived);
        }
        if matches!(record.analysis, AnalysisState::Pending { .. })
            || pending_ask_references(&self.pending_ask, id)
        {
            return Err(ProductError::Busy);
        }
        record.retention = RecordRetention::Trashed { trashed_at_ms };
        if matches!(&self.ask_scope, SearchScope::Record(rid) if rid == id) {
            self.ask_scope = SearchScope::All;
        }
        self.changed();
        Ok(())
    }

    /// Restores a soft-deleted recording to `RecordRetention::Active`.
    pub fn restore_record(&mut self, id: &str) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        if record.is_trashed() {
            record.retention = RecordRetention::Active;
            self.changed();
        }
        Ok(())
    }

    /// Permanently purges one trashed recording and reconciles all workspace references.
    pub fn purge_record(&mut self, id: &str) -> Result<PurgeReceipt, ProductError> {
        let record = self.records.get(id).ok_or(ProductError::UnknownRecord)?;
        match record.retention {
            RecordRetention::Archived => return Err(ProductError::RecordArchived),
            RecordRetention::Active => return Err(ProductError::InvalidTransition),
            RecordRetention::Trashed { .. } => {}
        }
        if matches!(record.analysis, AnalysisState::Pending { .. })
            || pending_ask_references(&self.pending_ask, id)
        {
            return Err(ProductError::Busy);
        }
        Ok(self.reconcile_purged_records(BTreeSet::from([id.to_string()])))
    }

    /// Permanently purges all trashed recordings when none have pending work.
    pub fn empty_trash(&mut self) -> Result<PurgeReceipt, ProductError> {
        let mut trashed_ids = BTreeSet::new();
        for (id, record) in &self.records {
            if record.is_trashed() {
                if matches!(record.analysis, AnalysisState::Pending { .. })
                    || pending_ask_references(&self.pending_ask, id)
                {
                    return Err(ProductError::Busy);
                }
                trashed_ids.insert(id.clone());
            }
        }
        if trashed_ids.is_empty() {
            return Ok(PurgeReceipt::default());
        }
        Ok(self.reconcile_purged_records(trashed_ids))
    }

    /// Permanently purges all expired trashed recordings that have no pending work.
    pub fn purge_expired_trash(&mut self, now_ms: u64) -> Result<PurgeReceipt, ProductError> {
        let expired_ids: BTreeSet<RecordId> = self
            .records
            .iter()
            .filter(|(id, record)| {
                record.retention.is_expired_at(now_ms)
                    && !matches!(record.analysis, AnalysisState::Pending { .. })
                    && !pending_ask_references(&self.pending_ask, id)
            })
            .map(|(id, _)| id.clone())
            .collect();
        if expired_ids.is_empty() {
            return Ok(PurgeReceipt::default());
        }
        Ok(self.reconcile_purged_records(expired_ids))
    }

    /// Returns `true` when at least one non-busy trashed recording is expired at `now_ms`.
    #[must_use]
    pub fn has_expired_trash(&self, now_ms: u64) -> bool {
        self.records.iter().any(|(id, record)| {
            record.retention.is_expired_at(now_ms)
                && !matches!(record.analysis, AnalysisState::Pending { .. })
                && !pending_ask_references(&self.pending_ask, id)
        })
    }

    /// Returns all audio basenames referenced by surviving live or trashed recordings.
    #[must_use]
    pub fn referenced_audio_filenames(&self) -> BTreeSet<String> {
        self.records
            .values()
            .flat_map(ProductRecord::owned_audio_filenames)
            .collect()
    }

    /// Returns durable hardware Bean `file_id` tombstones.
    #[must_use]
    pub fn purged_bean_file_ids(&self) -> &BTreeSet<u32> {
        &self.purged_bean_file_ids
    }

    /// Returns `true` when `file_id` has been permanently purged and should not auto-pull.
    #[must_use]
    pub fn is_bean_file_purged(&self, file_id: u32) -> bool {
        file_id != 0 && self.purged_bean_file_ids.contains(&file_id)
    }

    /// Clears a Bean `file_id` tombstone before an explicit download.
    pub fn clear_purged_bean_file_id(&mut self, file_id: u32) {
        if self.purged_bean_file_ids.remove(&file_id) {
            self.changed();
        }
    }

    /// Marks a temporary or reclaimed Bean `file_id` as purged and clears any pending scratch entry.
    pub fn record_purged_bean_file_id(&mut self, file_id: u32) {
        if file_id == 0 {
            return;
        }
        let removed_scratch = self.standby_scratch_file_ids.remove(&file_id);
        let inserted_tombstone = self.purged_bean_file_ids.insert(file_id);
        if removed_scratch || inserted_tombstone {
            self.changed();
        }
    }

    /// Resolves a source only when its owning recording is live.
    pub fn resolve_live_source(&self, source: &SourceRef) -> Result<Evidence, ProductError> {
        let record = self
            .records
            .get(&source.record_id)
            .ok_or(ProductError::InvalidSource)?;
        record.ensure_live()?;
        self.resolve_source(source)
    }

    fn reconcile_purged_records(&mut self, purged_ids: BTreeSet<RecordId>) -> PurgeReceipt {
        let mut removed_ids = BTreeSet::new();
        let mut candidate_bean_file_ids = BTreeSet::new();

        for id in &purged_ids {
            if let Some(record) = self.records.remove(id) {
                if record.origin == RecordOrigin::Bean && record.aggregate.file_id > 0 {
                    candidate_bean_file_ids.insert(record.aggregate.file_id);
                }
                removed_ids.insert(id.clone());
            }
        }
        if removed_ids.is_empty() {
            return PurgeReceipt::default();
        }

        for file_id in candidate_bean_file_ids {
            let shared_by_survivor = self.records.values().any(|record| {
                record.origin == RecordOrigin::Bean && record.aggregate.file_id == file_id
            });
            if !shared_by_survivor {
                self.purged_bean_file_ids.insert(file_id);
            }
        }

        for item in self.items.values_mut() {
            item.sources
                .retain(|source| !removed_ids.contains(&source.record_id));
        }
        self.items.retain(|_, item| !item.sources.is_empty());

        for receipt in &mut self.migrations {
            receipt.record_ids.retain(|id| !removed_ids.contains(id));
            receipt
                .summaries
                .retain(|summary| !removed_ids.contains(&summary.record_id));
        }

        if matches!(&self.ask_scope, SearchScope::Record(id) if removed_ids.contains(id)) {
            self.ask_scope = SearchScope::All;
        }

        for message in &mut self.ask_session.messages {
            let touches_purged = message
                .sources
                .iter()
                .any(|line| removed_ids.contains(&line.source.recording_key));
            if !touches_purged {
                continue;
            }
            let old_sources = message.sources.clone();
            let new_sources: Vec<SourceLine> = old_sources
                .iter()
                .filter(|line| !removed_ids.contains(&line.source.recording_key))
                .enumerate()
                .map(|(index, line)| SourceLine {
                    label: format!("S{}", index + 1),
                    title: line.title.clone(),
                    text: line.text.clone(),
                    source: line.source.clone(),
                    at_epoch_sec: line.at_epoch_sec,
                })
                .collect();
            let relabeled = relabel_citations(&message.text, &old_sources, &new_sources);
            message.text = if relabeled.trim().is_empty() {
                "（引用的记录已被清除）".to_string()
            } else {
                relabeled
            };
            message.grounded = !new_sources.is_empty();
            message.sources = new_sources;
        }

        self.changed();
        PurgeReceipt {
            purged_record_ids: removed_ids,
        }
    }
}

fn pending_ask_references(pending_ask: &Option<AskRequest>, id: &str) -> bool {
    pending_ask.as_ref().is_some_and(|request| {
        matches!(&request.scope, SearchScope::Record(rid) if rid == id)
            || request.evidence.iter().any(|e| e.source.record_id == id)
    })
}
