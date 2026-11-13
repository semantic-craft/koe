use super::*;
use crate::context::{AskRole, AskStatus};
use crate::domain::RecordingLifecyclePhase;

impl ProductWorkspace {
    /// Exports owned value state for a storage codec without exposing mutable live state.
    #[must_use]
    pub fn export_state(&self) -> WorkspaceState {
        WorkspaceState {
            provider_configuration: self.provider_configuration.clone(),
            ble_auto_connect: self.ble_auto_connect,
            companion_mode: self.companion_mode,
            standby_scratch_file_ids: self.standby_scratch_file_ids.clone(),
            reclaimed_standby_file_ids: self.reclaimed_standby_file_ids.clone(),
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
        if state.purged_bean_file_ids.contains(&0)
            || state.standby_scratch_file_ids.contains(&0)
            || state.reclaimed_standby_file_ids.contains(&0)
        {
            return Err(ProductError::InvalidEvidence);
        }
        let mut records = BTreeMap::new();
        for record in state.records {
            let id = record.aggregate.recording_id.clone();
            let lanes = record.capture_lanes;
            let all_day = record.all_day;
            let speech_engine = record.speech_engine;
            let retention = record.retention;
            let live_summary = record.live_summary;
            let mut record = ProductRecord::restore(
                record.aggregate,
                record.title,
                record.origin,
                record.analysis,
                record.content_revision,
                record.minutes_revision,
                record.highlighted_segments,
                record.final_keys,
                record.completed_request,
            )?;
            record.restore_live_summary(live_summary)?;
            record.all_day = all_day;
            record.speech_engine = speech_engine;
            record.restore_capture_lanes(lanes)?;
            record.restore_retention(retention);
            if records.insert(id, record).is_some() {
                return Err(ProductError::InvalidEvidence);
            }
        }
        let mut workspace = Self {
            provider_configuration: state.provider_configuration,
            ble_auto_connect: state.ble_auto_connect,
            companion_mode: state.companion_mode,
            standby_scratch_file_ids: state.standby_scratch_file_ids,
            reclaimed_standby_file_ids: state.reclaimed_standby_file_ids,
            migrations: state.migrations,
            purged_bean_file_ids: state.purged_bean_file_ids,
            revision: state.revision,
            next_operation: state.next_operation,
            records,
            items: BTreeMap::new(),
            ask_session: state.ask_session,
            ask_scope: state.ask_scope,
            pending_ask: state.pending_ask,
            last_ask_operation: state.last_ask_operation,
        };
        for receipt in &workspace.migrations {
            workspace.validate_migration(receipt)?;
        }
        workspace.validate_scope(&workspace.ask_scope)?;
        let mut max_operation = workspace.last_ask_operation.unwrap_or(0);
        for record in workspace.records.values() {
            let key = match &record.analysis {
                AnalysisState::Pending { key, .. }
                | AnalysisState::Failed { key, .. }
                | AnalysisState::Interrupted { key } => Some(key),
                _ => None,
            };
            for key in key.into_iter().chain(record.completed_request.as_ref()) {
                max_operation = max_operation.max(key.attempt);
            }
            if let AnalysisState::Pending { key, .. }
            | AnalysisState::Failed { key, .. }
            | AnalysisState::Interrupted { key } = &record.live_summary
            {
                max_operation = max_operation.max(key.attempt);
            }
        }
        for item in state.items {
            nonempty(&item.id)?;
            nonempty(&item.text)?;
            if item.sources.is_empty()
                || (item.completed
                    && (item.kind != ItemKind::Task || item.review != ReviewState::Accepted))
                || (item.kind == ItemKind::Memory && item.due.is_some())
            {
                return Err(ProductError::InvalidEvidence);
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
                return Err(ProductError::InvalidEvidence);
            }
        }
        for message in &workspace.ask_session.messages {
            for line in &message.sources {
                workspace.resolve_source(&super::ask::source_ref(line)?)?;
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
                return Err(ProductError::InvalidEvidence);
            }
            for evidence in &request.evidence {
                workspace.resolve_live_source(&evidence.source)?;
                if matches!(&request.scope, SearchScope::Record(id) if id != &evidence.source.record_id)
                {
                    return Err(ProductError::InvalidEvidence);
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
                return Err(ProductError::InvalidEvidence);
            }
            let pending = workspace
                .ask_session
                .messages
                .last()
                .ok_or(ProductError::InvalidEvidence)?;
            if pending.sources.len() != request.evidence.len() {
                return Err(ProductError::InvalidEvidence);
            }
            for (index, (line, evidence)) in
                pending.sources.iter().zip(&request.evidence).enumerate()
            {
                if line.label != format!("S{}", index + 1)
                    || line.text != evidence.quote
                    || super::ask::source_ref(line)? != evidence.source
                {
                    return Err(ProductError::InvalidEvidence);
                }
            }
        } else if workspace.ask_session.in_flight || pending_count > 0 {
            return Err(ProductError::InvalidEvidence);
        }
        if workspace.next_operation <= max_operation {
            return Err(ProductError::InvalidEvidence);
        }
        Ok(workspace)
    }

    /// Marks requests interrupted on process restart; it never silently repeats paid work.
    pub fn interrupt_pending(&mut self) -> bool {
        let mut changed = false;
        for record in self.records.values_mut() {
            if let AnalysisState::Pending { key, .. } = &record.live_summary {
                record.live_summary = AnalysisState::Interrupted { key: key.clone() };
                changed = true;
            }
            if let AnalysisState::Pending { key, .. } = &record.analysis {
                record.analysis = AnalysisState::Interrupted { key: key.clone() };
                record.aggregate.phase = RecordingLifecyclePhase::Failed;
                changed = true;
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
