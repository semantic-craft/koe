use super::record::validate_persisted_project;
use super::*;
use crate::context::{AskRole, AskStatus};

/// Persisted workspace fields decoded at the storage boundary for single-pass validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedWorkspaceState {
    /// Non-sensitive provider configuration.
    pub provider_configuration: ProviderConfiguration,
    /// Whether BLE auto-connect to paired D3200 devices is enabled.
    pub ble_auto_connect: bool,
    /// Completed imports, including preserved material that has not been mapped.
    pub migrations: Vec<MigrationReceipt>,
    /// Hardware Bean `file_id` tombstones preventing automatic re-pull after purge.
    pub purged_bean_file_ids: BTreeSet<u32>,
    /// Committed revision.
    pub revision: u64,
    /// Next operation identity.
    pub next_operation: u64,
    /// Decoded recordings awaiting single-pass domain validation.
    pub records: Vec<PersistedProductRecord>,
    /// Durable review items.
    pub items: Vec<SourcedItem>,
    /// Existing conversation state machine.
    pub ask_session: AskSession,
    /// Selected question scope.
    pub ask_scope: SearchScope,
    /// Pending immutable evidence request.
    pub pending_ask: Option<AskRequest>,
    /// Last accepted reply identity for idempotent delivery.
    pub last_ask_operation: Option<u64>,
}

struct WorkspaceTail {
    provider_configuration: ProviderConfiguration,
    ble_auto_connect: bool,
    migrations: Vec<MigrationReceipt>,
    purged_bean_file_ids: BTreeSet<u32>,
    revision: u64,
    next_operation: u64,
    items: Vec<SourcedItem>,
    ask_session: AskSession,
    ask_scope: SearchScope,
    pending_ask: Option<AskRequest>,
    last_ask_operation: Option<u64>,
}

impl ProductWorkspace {
    /// Monotonic next operation identifier used by storage codecs without cloning workspace state.
    #[must_use]
    pub const fn next_operation(&self) -> u64 {
        self.next_operation
    }

    /// Last accepted ask operation identifier for idempotent persistence without cloning workspace state.
    #[must_use]
    pub const fn last_ask_operation(&self) -> Option<u64> {
        self.last_ask_operation
    }

    /// Returns `true` if any recording or ask session has an in-flight request needing restart interruption.
    #[must_use]
    pub fn has_pending_work(&self) -> bool {
        self.pending_ask.is_some()
            || self
                .records
                .values()
                .any(ProductRecord::has_pending_analysis)
    }

    /// Exports owned value state for a storage codec without exposing mutable live state.
    #[must_use]
    pub fn export_state(&self) -> WorkspaceState {
        WorkspaceState {
            provider_configuration: self.provider_configuration.clone(),
            ble_auto_connect: self.ble_auto_connect,
            migrations: self.migrations.clone(),
            purged_bean_file_ids: self.purged_bean_file_ids.clone(),
            revision: self.revision,
            next_operation: self.next_operation,
            records: self.records.values().cloned().collect(),
            items: self.items.values().cloned().collect(),
            ask_session: self.ask_session.clone(),
            ask_scope: self.ask_scope.clone(),
            pending_ask: self.pending_ask.clone(),
            last_ask_operation: self.last_ask_operation,
        }
    }

    /// Restores validated value state; malformed identities or references are rejected.
    pub fn restore(state: WorkspaceState) -> Result<Self, ProductError> {
        state.provider_configuration.validate()?;
        if state.purged_bean_file_ids.contains(&0) {
            return Err(ProductError::InvalidPersistedState);
        }
        let mut records = BTreeMap::new();
        for record in state.records {
            let id = record.aggregate.recording_id.clone();
            let mode = record.mode;
            let project = validate_persisted_project(record.project)?;
            let lanes = record.capture_lanes;
            let all_day = record.all_day;
            let speech_engine = record.speech_engine;
            let retention = record.retention;
            let live_summary = record.live_summary;
            let mut record = ProductRecord::restore(RestoredProductRecord {
                aggregate: record.aggregate,
                title: record.title,
                origin: record.origin,
                analysis: record.analysis,
                content_revision: record.content_revision,
                minutes_revision: record.minutes_revision,
                highlighted_segments: record.highlighted_segments,
                final_keys: record.final_keys,
                completed_request: record.completed_request,
            })?;
            record.restore_live_summary(live_summary)?;
            record.mode = if all_day.is_some() {
                RecordMode::AllDay
            } else {
                mode
            };
            record.project = project;
            record.all_day = all_day;
            record.speech_engine = speech_engine;
            record.restore_capture_lanes(lanes)?;
            record.restore_retention(retention);
            if records.insert(id, record).is_some() {
                return Err(ProductError::InvalidPersistedState);
            }
        }
        Self::restore_from_validated_records(
            records,
            WorkspaceTail {
                provider_configuration: state.provider_configuration,
                ble_auto_connect: state.ble_auto_connect,
                migrations: state.migrations,
                purged_bean_file_ids: state.purged_bean_file_ids,
                revision: state.revision,
                next_operation: state.next_operation,
                items: state.items,
                ask_session: state.ask_session,
                ask_scope: state.ask_scope,
                pending_ask: state.pending_ask,
                last_ask_operation: state.last_ask_operation,
            },
        )
    }

    /// Restores persisted boundary records in a single validation pass without redundant minutes checks.
    pub fn restore_persisted(state: PersistedWorkspaceState) -> Result<Self, ProductError> {
        state.provider_configuration.validate()?;
        if state.purged_bean_file_ids.contains(&0) {
            return Err(ProductError::InvalidPersistedState);
        }
        let mut records = BTreeMap::new();
        for input in state.records {
            let id = input.aggregate.recording_id.clone();
            let record = ProductRecord::restore_persisted_record(input)?;
            if records.insert(id, record).is_some() {
                return Err(ProductError::InvalidPersistedState);
            }
        }
        Self::restore_from_validated_records(
            records,
            WorkspaceTail {
                provider_configuration: state.provider_configuration,
                ble_auto_connect: state.ble_auto_connect,
                migrations: state.migrations,
                purged_bean_file_ids: state.purged_bean_file_ids,
                revision: state.revision,
                next_operation: state.next_operation,
                items: state.items,
                ask_session: state.ask_session,
                ask_scope: state.ask_scope,
                pending_ask: state.pending_ask,
                last_ask_operation: state.last_ask_operation,
            },
        )
    }

    fn restore_from_validated_records(
        records: BTreeMap<RecordId, ProductRecord>,
        tail: WorkspaceTail,
    ) -> Result<Self, ProductError> {
        let mut workspace = Self {
            provider_configuration: tail.provider_configuration,
            ble_auto_connect: tail.ble_auto_connect,
            migrations: tail.migrations,
            purged_bean_file_ids: tail.purged_bean_file_ids,
            revision: tail.revision,
            next_operation: tail.next_operation,
            records,
            items: BTreeMap::new(),
            ask_session: tail.ask_session,
            ask_scope: tail.ask_scope,
            pending_ask: tail.pending_ask,
            last_ask_operation: tail.last_ask_operation,
        };
        for receipt in &workspace.migrations {
            workspace.validate_migration(receipt)?;
        }
        workspace.validate_scope(&workspace.ask_scope)?;
        let mut max_operation = workspace.last_ask_operation.unwrap_or(0);
        for record in workspace.records.values() {
            for slot in record.analysis_slots() {
                if let AnalysisState::Pending { key, .. }
                | AnalysisState::Failed { key, .. }
                | AnalysisState::Interrupted { key } = slot
                {
                    max_operation = max_operation.max(key.attempt);
                }
            }
            if let Some(key) = &record.completed_request {
                max_operation = max_operation.max(key.attempt);
            }
        }
        for item in tail.items {
            nonempty(&item.id)?;
            nonempty(&item.text)?;
            if item.sources.is_empty()
                || (item.completed
                    && (item.kind != ItemKind::Task || item.review != ReviewState::Accepted))
                || (item.kind == ItemKind::Memory && item.due.is_some())
            {
                return Err(ProductError::InvalidPersistedState);
            }
            for source in &item.sources {
                workspace.resolve_source(source)?;
            }
            if let Some(n) = item
                .id
                .strip_prefix("item-")
                .and_then(|s| s.parse::<u64>().ok())
            {
                max_operation = max_operation.max(n);
            }
            if workspace.items.insert(item.id.clone(), item).is_some() {
                return Err(ProductError::InvalidPersistedState);
            }
        }
        for message in &workspace.ask_session.messages {
            for line in &message.sources {
                workspace.resolve_source(&super::ask::source_ref(line))?;
            }
        }
        let pending_count = workspace
            .ask_session
            .messages
            .iter()
            .filter(|m| m.status == AskStatus::Pending)
            .count();
        if let Some(request) = &workspace.pending_ask {
            workspace.validate_scope(&request.scope)?;
            if request.operation == 0 || request.evidence.is_empty() {
                return Err(ProductError::InvalidPersistedState);
            }
            for evidence in &request.evidence {
                workspace.resolve_live_source(&evidence.source)?;
                if matches!(&request.scope, SearchScope::Record(id) if id != &evidence.source.record_id)
                {
                    return Err(ProductError::InvalidPersistedState);
                }
            }
            max_operation = max_operation.max(request.operation);
            if !workspace.ask_session.in_flight
                || pending_count != 1
                || !workspace
                    .ask_session
                    .messages
                    .last()
                    .is_some_and(|m| m.role == AskRole::Koe && m.status == AskStatus::Pending)
            {
                return Err(ProductError::InvalidPersistedState);
            }
            let pending = workspace
                .ask_session
                .messages
                .last()
                .ok_or(ProductError::InvalidPersistedState)?;
            if pending.sources.len() != request.evidence.len() {
                return Err(ProductError::InvalidPersistedState);
            }
            for (index, (line, evidence)) in
                pending.sources.iter().zip(&request.evidence).enumerate()
            {
                if line.label != format!("S{}", index + 1)
                    || line.text != evidence.quote
                    || super::ask::source_ref(line) != evidence.source
                {
                    return Err(ProductError::InvalidPersistedState);
                }
            }
        } else if workspace.ask_session.in_flight || pending_count > 0 {
            return Err(ProductError::InvalidPersistedState);
        }
        if workspace.next_operation <= max_operation {
            return Err(ProductError::InvalidPersistedState);
        }
        Ok(workspace)
    }

    /// Marks requests interrupted on process restart; it never silently repeats paid work.
    pub fn interrupt_pending(&mut self) -> bool {
        let mut changed = false;
        for record in self.records.values_mut() {
            for slot in record.analysis_slots_mut() {
                if let AnalysisState::Pending { key, .. } = slot {
                    *slot = AnalysisState::Interrupted { key: key.clone() };
                    changed = true;
                }
            }
        }
        if self.pending_ask.take().is_some() {
            self.ask_session.fail_answer(Some(
                "上次请求被中断，服务端结果未知。问题已保留，可手动重试。",
            ));
            changed = true;
        }
        if changed {
            self.changed();
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::minutes::{
        encode_meeting_minutes_json, parse_meeting_minutes_json, reset_validation_pass_count,
        validation_pass_count,
    };

    #[test]
    fn restore_persisted_validates_minutes_once_per_record_and_preserves_invariants() {
        let mut ws = ProductWorkspace::new();
        ws.insert_record("fresh".into(), "Fresh".into(), RecordOrigin::Note, 0, 100, 1_000)
            .unwrap();
        ws.append_transcript("fresh", "alpha launch plan confirmed", 0, 1_000, "manual")
            .unwrap();
        let key = ws
            .begin_analysis("fresh", AnalysisStage::Summarizing)
            .unwrap();
        let fresh_minutes = parse_meeting_minutes_json(
            r#"{"schemaVersion":2,"title":"Fresh","overview":"alpha launch plan confirmed","topics":[{"text":"alpha launch","summary":"alpha launch plan confirmed","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}"#,
            &ws.record("fresh").unwrap().aggregate.spine,
        )
        .unwrap();
        ws.complete_summary(&key, fresh_minutes).unwrap();

        ws.insert_record("stale".into(), "Stale".into(), RecordOrigin::Note, 0, 200, 2_000)
            .unwrap();
        ws.append_transcript("stale", "beta roadmap review", 0, 1_000, "manual")
            .unwrap();
        let stale_key = ws
            .begin_analysis("stale", AnalysisStage::Summarizing)
            .unwrap();
        let stale_minutes = parse_meeting_minutes_json(
            r#"{"schemaVersion":2,"title":"Stale","overview":"beta roadmap review","topics":[{"text":"beta roadmap","summary":"beta roadmap review","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}"#,
            &ws.record("stale").unwrap().aggregate.spine,
        )
        .unwrap();
        ws.complete_summary(&stale_key, stale_minutes).unwrap();
        ws.append_transcript("stale", "extra follow up sentence", 1_000, 2_000, "manual")
            .unwrap();

        let state = ws.export_state();
        let persisted_records: Vec<PersistedProductRecord> = state
            .records
            .into_iter()
            .map(|mut rec| {
                let minutes_json = rec.aggregate.minutes.take().map(|m| encode_meeting_minutes_json(&m));
                let retention = rec.retention();
                let minutes_revision = rec.minutes_revision();
                let final_keys = rec.final_keys().clone();
                let completed_request = rec.completed_request().cloned();
                PersistedProductRecord {
                    aggregate: rec.aggregate,
                    minutes_json,
                    title: rec.title,
                    origin: rec.origin,
                    mode: rec.mode,
                    project: rec.project,
                    analysis: rec.analysis,
                    live_summary: rec.live_summary,
                    content_revision: rec.content_revision,
                    minutes_revision,
                    highlighted_segments: rec.highlighted_segments,
                    capture_lanes: rec.capture_lanes,
                    all_day: rec.all_day,
                    speech_engine: rec.speech_engine,
                    retention,
                    final_keys,
                    completed_request,
                }
            })
            .collect();
        let persisted = PersistedWorkspaceState {
            provider_configuration: state.provider_configuration,
            ble_auto_connect: state.ble_auto_connect,
            migrations: state.migrations,
            purged_bean_file_ids: state.purged_bean_file_ids,
            revision: state.revision,
            next_operation: state.next_operation,
            records: persisted_records,
            items: state.items,
            ask_session: state.ask_session,
            ask_scope: state.ask_scope,
            pending_ask: state.pending_ask,
            last_ask_operation: state.last_ask_operation,
        };

        reset_validation_pass_count();
        let restored = ProductWorkspace::restore_persisted(persisted.clone()).unwrap();
        assert_eq!(restored.record("fresh"), ws.record("fresh"));
        assert!(restored.record("stale").unwrap().is_minutes_stale());
        assert_eq!(
            restored.record("stale").unwrap().minutes_revision(),
            Some(1)
        );
        assert_eq!(
            validation_pass_count(),
            2,
            "2 records with minutes must run minutes validation once per record (not 3x)"
        );

        let mut bad_ungrounded = persisted.clone();
        bad_ungrounded.records[0].minutes_json = Some(
            r#"{"schemaVersion":2,"title":"Fresh","overview":"alpha launch plan confirmed","topics":[{"text":"alpha launch","summary":"completion reached 85%","sources":["S1"]}],"decisions":[],"actions":[],"questions":[]}"#
                .to_string(),
        );
        assert!(ProductWorkspace::restore_persisted(bad_ungrounded).is_err());

        let mut bad_citation = persisted;
        bad_citation.records[1].minutes_json = Some(
            r#"{"schemaVersion":2,"title":"Stale","overview":"beta roadmap review","topics":[{"text":"beta roadmap","summary":"beta roadmap review","sources":["S99"]}],"decisions":[],"actions":[],"questions":[]}"#
                .to_string(),
        );
        assert!(ProductWorkspace::restore_persisted(bad_citation).is_err());
    }
}
