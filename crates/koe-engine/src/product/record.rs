use super::*;
use crate::domain::{MeetingMinutes, RecordingLifecyclePhase};
use crate::minutes::validate_minutes_grounding;

impl ProductWorkspace {
    /// Updates factual duration and marks after a capture has been safely persisted.
    pub fn finish_capture(
        &mut self,
        id: &str,
        duration_ms: u64,
        bookmarks: &[u64],
    ) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        record.aggregate.duration_ms = record.aggregate.duration_ms.max(duration_ms);
        for &mark in bookmarks {
            record.aggregate.add_bookmark(mark);
        }
        self.changed();
        Ok(())
    }

    /// Restores or names a speaker on one original segment without changing its text.
    pub fn name_speaker(
        &mut self,
        source: &SourceRef,
        speaker: Option<String>,
    ) -> Result<(), ProductError> {
        self.resolve_live_source(source)?;
        let record = self
            .records
            .get_mut(&source.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record
            .aggregate
            .spine
            .set_speaker(source.segment_id, speaker);
        self.changed();
        Ok(())
    }
    /// Registers factual recording metadata without replacing an existing record's content.
    pub fn insert_record(
        &mut self,
        id: String,
        title: String,
        origin: RecordOrigin,
        file_id: u32,
        created_at: u64,
        duration_ms: u64,
    ) -> Result<(), ProductError> {
        let id = nonempty(&id)?;
        let title = nonempty(&title)?;
        if self.records.contains_key(&id) {
            if origin == RecordOrigin::Bean
                && file_id > 0
                && self.purged_bean_file_ids.remove(&file_id)
            {
                self.changed();
            }
            return Ok(());
        }
        if origin == RecordOrigin::Bean && file_id > 0 {
            self.purged_bean_file_ids.remove(&file_id);
        }
        let mut aggregate = RecordingAggregate::new(id.clone(), file_id, created_at, duration_ms);
        aggregate.phase = RecordingLifecyclePhase::Local;
        self.records.insert(
            id,
            ProductRecord {
                aggregate,
                title,
                origin,
                analysis: AnalysisState::Idle,
                content_revision: 0,
                highlighted_segments: BTreeSet::new(),
                capture_lanes: Vec::new(),
                retention: RecordRetention::Active,
                final_keys: BTreeMap::new(),
                completed_request: None,
            },
        );
        self.changed();
        Ok(())
    }

    /// Appends explicit local text to the addressed recording, never to a UI selection.
    pub fn append_transcript(
        &mut self,
        id: &str,
        text: &str,
        start_ms: u64,
        end_ms: u64,
        provider: &str,
    ) -> Result<SegmentId, ProductError> {
        let clean = nonempty(text)?;
        if end_ms < start_ms {
            return Err(ProductError::InvalidInput(
                "片段结束时间早于开始时间".to_string(),
            ));
        }
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        let segment = record
            .aggregate
            .spine
            .append_segment(clean, start_ms, end_ms, "auto", provider)
            .ok_or_else(|| ProductError::InvalidInput("无法保存文字片段".to_string()))?;
        record.aggregate.duration_ms = record.aggregate.duration_ms.max(end_ms);
        record.content_changed();
        self.changed();
        Ok(segment)
    }

    /// Renames only the addressed recording.
    pub fn rename_record(&mut self, id: &str, title: &str) -> Result<(), ProductError> {
        let title = nonempty(title)?;
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if record.title != title {
            record.title = title;
            self.changed();
        }
        Ok(())
    }

    /// Marks the original utterance's timestamp as a highlight.
    pub fn add_highlight(&mut self, source: SourceRef) -> Result<(), ProductError> {
        let evidence = self.resolve_live_source(&source)?;
        let record = self
            .records
            .get_mut(&source.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        let added = record.highlighted_segments.insert(source.segment_id);
        if record
            .aggregate
            .spine
            .get(source.segment_id)
            .is_some_and(|s| s.end_ms > s.start_ms)
        {
            record.aggregate.add_bookmark(evidence.start_ms);
        }
        if added {
            self.changed();
        }
        Ok(())
    }

    /// Creates one persisted analysis attempt; callers start I/O only after this is committed.
    pub fn begin_analysis(
        &mut self,
        id: &str,
        stage: AnalysisStage,
    ) -> Result<RequestKey, ProductError> {
        let record = self.records.get(id).ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if matches!(record.analysis, AnalysisState::Pending { .. }) {
            return Err(ProductError::Busy);
        }
        if stage == AnalysisStage::Summarizing && record.aggregate.spine.is_empty() {
            return Err(ProductError::InvalidInput(
                "记录还没有可整理的文字".to_string(),
            ));
        }
        let input_revision = record.content_revision;
        let key = RequestKey {
            record_id: id.to_string(),
            attempt: self.operation(),
            input_revision,
        };
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.analysis = AnalysisState::Pending {
            key: key.clone(),
            stage,
        };
        record.aggregate.phase = RecordingLifecyclePhase::Transcribing;
        self.changed();
        Ok(key)
    }

    /// Commits a provider final to its fixed recording/attempt, deduplicating delivery IDs.
    pub fn accept_transcript(
        &mut self,
        key: &RequestKey,
        final_id: &str,
        text: &str,
        start_ms: u64,
        end_ms: u64,
        provider: &str,
    ) -> Result<SegmentId, ProductError> {
        let final_id = nonempty(final_id)?;
        let clean = nonempty(text)?;
        if end_ms < start_ms {
            return Err(ProductError::InvalidInput(
                "片段结束时间早于开始时间".to_string(),
            ));
        }
        let record = self
            .records
            .get_mut(&key.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        record.require_pending(key, AnalysisStage::Transcribing)?;
        let delivery = format!("{}:{final_id}", key.attempt);
        let segment =
            if let Some(&id) = record.final_keys.get(&delivery) {
                if record.aggregate.spine.get(id).is_some_and(|s| {
                    s.text == clean && s.start_ms == start_ms && s.end_ms == end_ms
                }) {
                    return Ok(id);
                }
                if !record
                    .aggregate
                    .spine
                    .update_segment(id, clean, start_ms, end_ms)
                {
                    return Err(ProductError::InvalidSource);
                }
                id
            } else {
                let id = record
                    .aggregate
                    .spine
                    .append_segment(clean, start_ms, end_ms, "auto", provider)
                    .ok_or_else(|| ProductError::InvalidInput("无法保存文字片段".to_string()))?;
                record.final_keys.insert(delivery, id);
                id
            };
        record.aggregate.duration_ms = record.aggregate.duration_ms.max(end_ms);
        record.content_changed();
        self.changed();
        Ok(segment)
    }

    /// Completes transcription only after the provider's final completion event.
    pub fn finish_transcription(&mut self, key: &RequestKey) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(&key.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if record.completed_request.as_ref() == Some(key)
            && matches!(record.analysis, AnalysisState::Idle)
        {
            return Ok(());
        }
        record.require_pending(key, AnalysisStage::Transcribing)?;
        record.analysis = AnalysisState::Idle;
        record.aggregate.phase = RecordingLifecyclePhase::Local;
        record.completed_request = Some(key.clone());
        self.changed();
        Ok(())
    }

    /// Commits grounded minutes only to the request's original unchanged recording.
    pub fn complete_summary(
        &mut self,
        key: &RequestKey,
        minutes: MeetingMinutes,
    ) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(&key.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if record.content_revision != key.input_revision {
            return Err(ProductError::StaleRequest);
        }
        if record.completed_request.as_ref() == Some(key)
            && matches!(record.analysis, AnalysisState::Ready { .. })
        {
            return if record.aggregate.minutes.as_ref() == Some(&minutes) {
                Ok(())
            } else {
                Err(ProductError::StaleRequest)
            };
        }
        record.require_pending(key, AnalysisStage::Summarizing)?;
        validate_minutes_grounding(&minutes, &record.aggregate.spine)
            .map_err(|_| ProductError::InvalidEvidence)?;
        let candidates: Vec<_> = minutes
            .actions
            .iter()
            .map(|p| {
                (
                    ItemKind::Task,
                    p.claim.clone(),
                    p.citations.clone(),
                    p.due.clone(),
                )
            })
            .chain(
                minutes
                    .decisions
                    .iter()
                    .map(|p| (ItemKind::Memory, p.claim.clone(), p.citations.clone(), None)),
            )
            .collect();
        record.aggregate.minutes = Some(minutes);
        record.aggregate.visual_cards.clear();
        record.aggregate.phase = RecordingLifecyclePhase::Ready;
        record.analysis = AnalysisState::Ready {
            input_revision: key.input_revision,
        };
        record.completed_request = Some(key.clone());
        for (kind, text, citations, due) in candidates {
            if citations.is_empty() || text.trim().is_empty() {
                continue;
            }
            let sources = citations
                .into_iter()
                .map(|segment_id| SourceRef {
                    record_id: key.record_id.clone(),
                    segment_id,
                })
                .collect();
            self.propose_with_due(kind, &text, sources, due)?;
        }
        self.changed();
        Ok(())
    }

    /// Records an error against the matching pending attempt.
    pub fn fail_analysis(&mut self, key: &RequestKey, message: &str) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(&key.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if !matches!(&record.analysis, AnalysisState::Pending { key: current, .. } if current == key)
        {
            return Err(ProductError::StaleRequest);
        }
        record.analysis = AnalysisState::Failed {
            key: key.clone(),
            message: nonempty(message)?,
        };
        record.aggregate.phase = RecordingLifecyclePhase::Failed;
        self.changed();
        Ok(())
    }
}

impl ProductRecord {
    fn require_pending(&self, key: &RequestKey, stage: AnalysisStage) -> Result<(), ProductError> {
        if matches!(&self.analysis, AnalysisState::Pending { key: current, stage: actual } if current == key && *actual == stage)
        {
            Ok(())
        } else {
            Err(ProductError::StaleRequest)
        }
    }

    fn content_changed(&mut self) {
        self.content_revision = self.content_revision.saturating_add(1);
        self.aggregate.minutes = None;
        self.aggregate.visual_cards.clear();
        if let AnalysisState::Pending {
            key,
            stage: AnalysisStage::Summarizing,
        } = &self.analysis
        {
            self.analysis = AnalysisState::Failed {
                key: key.clone(),
                message: "原文已变化，请重新整理".to_string(),
            };
            self.aggregate.phase = RecordingLifecyclePhase::Failed;
        } else if !matches!(self.analysis, AnalysisState::Pending { .. }) {
            self.analysis = AnalysisState::Idle;
            self.aggregate.phase = RecordingLifecyclePhase::Local;
        }
    }

    /// Delivery identities for faithful persistence of deduplication state.
    #[must_use]
    pub fn final_keys(&self) -> &BTreeMap<String, SegmentId> {
        &self.final_keys
    }

    /// Last successfully completed attempt, used for idempotent completion delivery.
    #[must_use]
    pub fn completed_request(&self) -> Option<&RequestKey> {
        self.completed_request.as_ref()
    }

    /// Reconstructs a pure record from persisted values, validating all local references.
    #[allow(clippy::too_many_arguments)]
    pub fn restore(
        aggregate: RecordingAggregate,
        title: String,
        origin: RecordOrigin,
        analysis: AnalysisState,
        content_revision: u64,
        highlighted_segments: BTreeSet<SegmentId>,
        final_keys: BTreeMap<String, SegmentId>,
        completed_request: Option<RequestKey>,
    ) -> Result<Self, ProductError> {
        nonempty(&aggregate.recording_id)?;
        let title = nonempty(&title)?;
        if aggregate.recording_id != aggregate.spine.session_id()
            || content_revision < aggregate.spine.len() as u64
        {
            return Err(ProductError::InvalidEvidence);
        }
        if final_keys
            .values()
            .any(|id| !aggregate.spine.validate_citation(*id))
        {
            return Err(ProductError::InvalidSource);
        }
        if highlighted_segments
            .iter()
            .any(|id| !aggregate.spine.validate_citation(*id))
        {
            return Err(ProductError::InvalidSource);
        }
        if let Some(minutes) = &aggregate.minutes {
            validate_minutes_grounding(minutes, &aggregate.spine)
                .map_err(|_| ProductError::InvalidEvidence)?;
        }
        let request = match &analysis {
            AnalysisState::Pending { key, .. }
            | AnalysisState::Failed { key, .. }
            | AnalysisState::Interrupted { key } => Some(key),
            _ => None,
        };
        if request
            .into_iter()
            .chain(completed_request.as_ref())
            .any(|key| {
                key.record_id != aggregate.recording_id
                    || key.attempt == 0
                    || key.input_revision > content_revision
            })
        {
            return Err(ProductError::InvalidEvidence);
        }
        if let AnalysisState::Ready { input_revision } = analysis {
            if input_revision != content_revision || aggregate.minutes.is_none() {
                return Err(ProductError::InvalidEvidence);
            }
        }
        Ok(Self {
            aggregate,
            title,
            origin,
            analysis,
            content_revision,
            highlighted_segments,
            capture_lanes: Vec::new(),
            retention: RecordRetention::Active,
            final_keys,
            completed_request,
        })
    }
}
