use super::*;
use crate::domain::{MeetingMinutes, UtteranceSpine};
use crate::minutes::{
    parse_persisted_meeting_minutes_json, validate_minutes_citations, validate_minutes_grounding,
};

/// Finalized provider transcript segment accepted into a pending transcription attempt.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TranscriptFinal<'a> {
    /// Provider delivery identifier deduplicated within the transcription attempt.
    pub final_id: &'a str,
    /// Transcript text content.
    pub text: &'a str,
    /// Segment start offset in milliseconds.
    pub start_ms: u64,
    /// Segment end offset in milliseconds.
    pub end_ms: u64,
    /// Speech provider identifier.
    pub provider: &'a str,
    /// Optional diarized speaker label.
    pub speaker: Option<&'a str>,
}

/// Persisted fields used to reconstruct and validate a [`ProductRecord`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RestoredProductRecord {
    /// Core recording aggregate containing identity, spine, minutes, and bookmarks.
    pub aggregate: RecordingAggregate,
    /// Display title of the record.
    pub title: String,
    /// Source origin of the record.
    pub origin: RecordOrigin,
    /// Persisted analysis lifecycle state.
    pub analysis: AnalysisState,
    /// Monotonic revision of transcript and content mutations.
    pub content_revision: u64,
    /// Content revision at which persisted minutes were generated, if any.
    pub minutes_revision: Option<u64>,
    /// Highlighted segment identifiers validated against the spine.
    pub highlighted_segments: BTreeSet<SegmentId>,
    /// Deduplicated delivery-key to segment-id map.
    pub final_keys: BTreeMap<String, SegmentId>,
    /// Most recently completed request key, if any.
    pub completed_request: Option<RequestKey>,
}

/// Persisted record fields decoded at the storage boundary for single-pass validation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistedProductRecord {
    /// Core recording aggregate with `minutes == None`; raw minutes JSON lives in `minutes_json`.
    pub aggregate: RecordingAggregate,
    /// Raw serialized meeting minutes JSON awaiting single-pass parse and validation, if present.
    pub minutes_json: Option<String>,
    /// Display title of the record.
    pub title: String,
    /// Source origin of the record.
    pub origin: RecordOrigin,
    /// Workspace mode attributed to the record.
    pub mode: RecordMode,
    /// Optional trimmed project name.
    pub project: Option<String>,
    /// Persisted analysis lifecycle state.
    pub analysis: AnalysisState,
    /// Persisted live summary lifecycle state.
    pub live_summary: AnalysisState,
    /// Monotonic revision of transcript and content mutations.
    pub content_revision: u64,
    /// Content revision at which persisted minutes were generated, if any.
    pub minutes_revision: Option<u64>,
    /// Highlighted segment identifiers validated against the spine.
    pub highlighted_segments: BTreeSet<SegmentId>,
    /// Persisted native capture lanes.
    pub capture_lanes: Vec<CaptureLaneRecord>,
    /// Optional all-day capture grouping.
    pub all_day: Option<AllDaySegment>,
    /// Optional bound speech engine.
    pub speech_engine: Option<SpeechEngine>,
    /// Persisted archive/trash retention state.
    pub retention: RecordRetention,
    /// Deduplicated delivery-key to segment-id map.
    pub final_keys: BTreeMap<String, SegmentId>,
    /// Most recently completed request key, if any.
    pub completed_request: Option<RequestKey>,
}

enum RestoreMinutes {
    PreParsed,
    PersistedJson(Option<String>),
}

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
        if record.aggregate.duration_ms > 0 {
            for m in &mut record.aggregate.bookmarks {
                *m = (*m).min(record.aggregate.duration_ms);
            }
            record.aggregate.bookmarks.sort_unstable();
            record.aggregate.bookmarks.dedup();
        }
        for &mark in bookmarks {
            record.aggregate.add_bookmark(mark);
        }
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
        let aggregate = RecordingAggregate::new(id.clone(), file_id, created_at, duration_ms);
        self.records.insert(
            id,
            ProductRecord {
                aggregate,
                title,
                origin,
                mode: RecordMode::QuickNote,
                project: None,
                analysis: AnalysisState::Idle,
                live_summary: AnalysisState::Idle,
                content_revision: 0,
                minutes_revision: None,
                highlighted_segments: BTreeSet::new(),
                capture_lanes: Vec::new(),
                all_day: None,
                speech_engine: None,
                retention: RecordRetention::Active,
                final_keys: BTreeMap::new(),
                completed_request: None,
            },
        );
        self.changed();
        Ok(())
    }

    /// Binds a speech attempt to its execution engine in the same durable transaction.
    pub fn bind_speech_engine(
        &mut self,
        id: &str,
        engine: SpeechEngine,
    ) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        record.speech_engine = Some(engine);
        self.changed();
        Ok(())
    }
    /// Assigns an immutable all-day run and segment order.
    pub fn group_all_day(&mut self, id: &str, segment: AllDaySegment) -> Result<(), ProductError> {
        nonempty(&segment.run_id)?;
        if segment.ordinal == 0 {
            return Err(ProductError::InvalidInput("全天听记分段序号无效".into()));
        }
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if record.all_day.as_ref().is_some_and(|s| s != &segment) {
            return Err(ProductError::InvalidTransition);
        }
        record.all_day = Some(segment);
        record.mode = RecordMode::AllDay;
        self.changed();
        Ok(())
    }

    /// Updates the workspace mode attributed to a live recording.
    pub fn set_record_mode(&mut self, id: &str, mode: RecordMode) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if record.all_day.is_some() && mode != RecordMode::AllDay {
            return Err(ProductError::InvalidTransition);
        }
        if record.mode != mode {
            record.mode = mode;
            self.changed();
        }
        Ok(())
    }

    /// Assigns or clears the normalized QuickNote project name on a live recording.
    pub fn set_record_project(
        &mut self,
        id: &str,
        project: Option<&str>,
    ) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        let normalized = normalize_project(project)?;
        if record.project != normalized {
            record.project = normalized;
            self.changed();
        }
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
        if stage == AnalysisStage::Summarizing {
            record.live_summary = AnalysisState::Idle;
        }
        record.analysis = AnalysisState::Pending {
            key: key.clone(),
            stage,
        };
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
        self.accept_transcript_with_speaker(
            key,
            TranscriptFinal {
                final_id,
                text,
                start_ms,
                end_ms,
                provider,
                speaker: None,
            },
        )
    }

    /// Commits a provider final with an optional diarized speaker label to its fixed recording/attempt.
    pub fn accept_transcript_with_speaker(
        &mut self,
        key: &RequestKey,
        input: TranscriptFinal<'_>,
    ) -> Result<SegmentId, ProductError> {
        let final_id = nonempty(input.final_id)?;
        let clean = nonempty(input.text)?;
        if input.end_ms < input.start_ms {
            return Err(ProductError::InvalidInput(
                "片段结束时间早于开始时间".to_string(),
            ));
        }
        let sanitized_speaker = input.speaker.and_then(super::sanitize_speaker_lossy);
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
                    s.text == clean
                        && s.start_ms == input.start_ms
                        && s.end_ms == input.end_ms
                        && (sanitized_speaker.is_none() || s.speaker == sanitized_speaker)
                }) {
                    return Ok(id);
                }
                if !record.aggregate.spine.update_segment(
                    id,
                    clean,
                    input.start_ms,
                    input.end_ms,
                ) {
                    return Err(ProductError::InvalidSource);
                }
                if let Some(sp) = sanitized_speaker {
                    record.aggregate.spine.set_speaker(id, Some(sp));
                }
                record.aggregate.minutes = None;
                record.minutes_revision = None;
                if matches!(record.live_summary, AnalysisState::Ready { .. }) {
                    record.live_summary = AnalysisState::Idle;
                }
                id
            } else {
                let id = record
                    .aggregate
                    .spine
                    .append_segment(clean, input.start_ms, input.end_ms, "auto", input.provider)
                    .ok_or_else(|| ProductError::InvalidInput("无法保存文字片段".to_string()))?;
                if let Some(sp) = sanitized_speaker {
                    record.aggregate.spine.set_speaker(id, Some(sp));
                }
                record.final_keys.insert(delivery, id);
                id
            };
        record.aggregate.duration_ms = record.aggregate.duration_ms.max(input.end_ms);
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
        record.completed_request = Some(key.clone());
        self.changed();
        Ok(())
    }

    /// Starts a durable minutes request without taking ownership of transcription.
    pub fn begin_live_summary(&mut self, id: &str) -> Result<RequestKey, ProductError> {
        let record = self.records.get(id).ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if matches!(record.live_summary, AnalysisState::Pending { .. }) {
            return Err(ProductError::Busy);
        }
        if record.aggregate.spine.is_empty() {
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
        record.live_summary = AnalysisState::Pending {
            key: key.clone(),
            stage: AnalysisStage::Summarizing,
        };
        self.changed();
        Ok(key)
    }

    /// Commits a grounded prefix snapshot while allowing newer transcript appends.
    pub fn complete_live_summary(
        &mut self,
        key: &RequestKey,
        snapshot: &UtteranceSpine,
        minutes: MeetingMinutes,
    ) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(&key.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if !matches!(&record.live_summary, AnalysisState::Pending { key: current, stage: AnalysisStage::Summarizing } if current == key)
            || snapshot.session_id() != key.record_id
            || snapshot.is_empty()
            || !record
                .aggregate
                .spine
                .segments()
                .starts_with(snapshot.segments())
            || record
                .minutes_revision
                .is_some_and(|revision| key.input_revision < revision)
        {
            return Err(ProductError::StaleRequest);
        }
        validate_minutes_grounding(&minutes, snapshot)
            .map_err(|_| ProductError::InvalidEvidence)?;
        record.aggregate.minutes = Some(minutes);
        record.minutes_revision = Some(key.input_revision);
        record.live_summary = AnalysisState::Ready {
            input_revision: key.input_revision,
        };
        self.changed();
        Ok(())
    }

    /// Records a known minutes failure without changing transcription ownership.
    pub fn fail_live_summary(
        &mut self,
        key: &RequestKey,
        message: &str,
    ) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(&key.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_live()?;
        if !matches!(&record.live_summary, AnalysisState::Pending { key: current, stage: AnalysisStage::Summarizing } if current == key)
        {
            return Err(ProductError::StaleRequest);
        }
        record.live_summary = AnalysisState::Failed {
            key: key.clone(),
            message: nonempty(message)?,
            stage: Some(AnalysisStage::Summarizing),
        };
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
        record.minutes_revision = Some(key.input_revision);
        record.analysis = AnalysisState::Ready {
            input_revision: key.input_revision,
        };
        record.live_summary = AnalysisState::Idle;
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
        let AnalysisState::Pending {
            key: current,
            stage,
        } = &record.analysis
        else {
            return Err(ProductError::StaleRequest);
        };
        if current != key {
            return Err(ProductError::StaleRequest);
        }
        let stage = *stage;
        record.analysis = AnalysisState::Failed {
            key: key.clone(),
            message: nonempty(message)?,
            stage: Some(stage),
        };
        self.changed();
        Ok(())
    }
}

impl ProductRecord {
    /// Returns `true` when any analysis slot on this recording has an in-flight request.
    #[must_use]
    pub fn has_pending_analysis(&self) -> bool {
        self.analysis_slots()
            .into_iter()
            .any(|slot| matches!(slot, AnalysisState::Pending { .. }))
    }

    pub(crate) fn analysis_slots(&self) -> [&AnalysisState; 2] {
        let Self {
            analysis,
            live_summary,
            aggregate: _,
            title: _,
            origin: _,
            mode: _,
            project: _,
            content_revision: _,
            minutes_revision: _,
            highlighted_segments: _,
            capture_lanes: _,
            all_day: _,
            speech_engine: _,
            retention: _,
            final_keys: _,
            completed_request: _,
        } = self;
        [analysis, live_summary]
    }

    pub(crate) fn analysis_slots_mut(&mut self) -> [&mut AnalysisState; 2] {
        let Self {
            analysis,
            live_summary,
            aggregate: _,
            title: _,
            origin: _,
            mode: _,
            project: _,
            content_revision: _,
            minutes_revision: _,
            highlighted_segments: _,
            capture_lanes: _,
            all_day: _,
            speech_engine: _,
            retention: _,
            final_keys: _,
            completed_request: _,
        } = self;
        [analysis, live_summary]
    }

    /// Returns `true` when this recording is a live, non-archived `QuickNote` in the inbox (`project.is_none()`).
    #[must_use]
    pub const fn is_quick_note_inbox(&self) -> bool {
        matches!(self.mode, RecordMode::QuickNote)
            && self.project.is_none()
            && self.is_live()
            && !self.is_archived()
    }

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
        if let AnalysisState::Pending {
            key,
            stage: AnalysisStage::Summarizing,
        } = &self.analysis
        {
            self.analysis = AnalysisState::Failed {
                key: key.clone(),
                message: "原文已变化，请重新整理".to_string(),
                stage: Some(AnalysisStage::Summarizing),
            };
        } else if !matches!(self.analysis, AnalysisState::Pending { .. }) {
            self.analysis = AnalysisState::Idle;
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

    /// Validates the independently persisted live minutes state.
    pub fn restore_live_summary(&mut self, state: AnalysisState) -> Result<(), ProductError> {
        let key = match &state {
            AnalysisState::Pending {
                key,
                stage: AnalysisStage::Summarizing,
            }
            | AnalysisState::Failed {
                key,
                stage: None | Some(AnalysisStage::Summarizing),
                ..
            }
            | AnalysisState::Interrupted {
                key,
                stage: None | Some(AnalysisStage::Summarizing),
            } => Some(key),
            AnalysisState::Pending { .. }
            | AnalysisState::Failed { .. }
            | AnalysisState::Interrupted { .. } => {
                return Err(ProductError::InvalidPersistedState);
            }
            AnalysisState::Ready { input_revision }
                if self.minutes_revision != Some(*input_revision) =>
            {
                return Err(ProductError::InvalidPersistedState);
            }
            AnalysisState::Idle | AnalysisState::Ready { .. } => None,
        };
        if key.is_some_and(|key| {
            key.record_id != self.aggregate.recording_id
                || key.attempt == 0
                || key.input_revision == 0
                || key.input_revision > self.content_revision
        }) {
            return Err(ProductError::InvalidPersistedState);
        }
        self.live_summary = state;
        Ok(())
    }

    /// Reconstructs a pure record from persisted values, validating all local references.
    pub fn restore(state: RestoredProductRecord) -> Result<Self, ProductError> {
        Self::restore_inner(state, RestoreMinutes::PreParsed)
    }

    pub(super) fn restore_persisted_record(
        input: PersistedProductRecord,
    ) -> Result<Self, ProductError> {
        let project = validate_persisted_project(input.project)?;
        let mut record = Self::restore_inner(
            RestoredProductRecord {
                aggregate: input.aggregate,
                title: input.title,
                origin: input.origin,
                analysis: input.analysis,
                content_revision: input.content_revision,
                minutes_revision: input.minutes_revision,
                highlighted_segments: input.highlighted_segments,
                final_keys: input.final_keys,
                completed_request: input.completed_request,
            },
            RestoreMinutes::PersistedJson(input.minutes_json),
        )?;
        record.restore_live_summary(input.live_summary)?;
        record.mode = if input.all_day.is_some() {
            RecordMode::AllDay
        } else {
            input.mode
        };
        record.project = project;
        record.all_day = input.all_day;
        record.speech_engine = input.speech_engine;
        record.restore_capture_lanes(input.capture_lanes)?;
        record.restore_retention(input.retention);
        Ok(record)
    }

    fn restore_inner(
        state: RestoredProductRecord,
        minutes_mode: RestoreMinutes,
    ) -> Result<Self, ProductError> {
        let RestoredProductRecord {
            mut aggregate,
            title,
            origin,
            analysis,
            content_revision,
            minutes_revision,
            highlighted_segments,
            final_keys,
            completed_request,
        } = state;
        nonempty(&aggregate.recording_id)?;
        let title = nonempty(&title)?;
        let has_minutes = match &minutes_mode {
            RestoreMinutes::PreParsed => aggregate.minutes.is_some(),
            RestoreMinutes::PersistedJson(raw) => {
                if aggregate.minutes.is_some() {
                    return Err(ProductError::InvalidPersistedState);
                }
                raw.is_some()
            }
        };
        if aggregate.recording_id != aggregate.spine.session_id()
            || content_revision < aggregate.spine.len() as u64
            || has_minutes != minutes_revision.is_some()
        {
            return Err(ProductError::InvalidPersistedState);
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
        match minutes_mode {
            RestoreMinutes::PreParsed => {
                if let (Some(minutes), Some(min_rev)) = (&aggregate.minutes, minutes_revision) {
                    if min_rev == 0 || min_rev > content_revision || aggregate.spine.is_empty() {
                        return Err(ProductError::InvalidPersistedState);
                    }
                    let valid = if min_rev == content_revision {
                        validate_minutes_grounding(minutes, &aggregate.spine)
                    } else {
                        validate_minutes_citations(minutes, &aggregate.spine)
                    };
                    valid.map_err(|_| ProductError::InvalidPersistedState)?;
                }
            }
            RestoreMinutes::PersistedJson(Some(raw)) => {
                let min_rev = minutes_revision.ok_or(ProductError::InvalidPersistedState)?;
                if min_rev == 0 || min_rev > content_revision || aggregate.spine.is_empty() {
                    return Err(ProductError::InvalidPersistedState);
                }
                let parsed = parse_persisted_meeting_minutes_json(
                    &raw,
                    &aggregate.spine,
                    min_rev == content_revision,
                )
                .map_err(|e| ProductError::InvalidInput(format!("invalid minutes: {e:?}")))?;
                aggregate.minutes = Some(parsed);
            }
            RestoreMinutes::PersistedJson(None) => {}
        }
        let request = match &analysis {
            AnalysisState::Pending { key, .. }
            | AnalysisState::Failed { key, .. }
            | AnalysisState::Interrupted { key, .. } => Some(key),
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
            return Err(ProductError::InvalidPersistedState);
        }
        if let AnalysisState::Ready { input_revision } = analysis {
            if minutes_revision != Some(input_revision) || input_revision > content_revision {
                return Err(ProductError::InvalidPersistedState);
            }
        }
        Ok(Self {
            aggregate,
            title,
            origin,
            mode: RecordMode::QuickNote,
            project: None,
            analysis,
            live_summary: AnalysisState::Idle,
            content_revision,
            minutes_revision,
            highlighted_segments,
            capture_lanes: Vec::new(),
            all_day: None,
            speech_engine: None,
            retention: RecordRetention::Active,
            final_keys,
            completed_request,
        })
    }
}

pub(super) fn validate_persisted_project(
    project: Option<String>,
) -> Result<Option<String>, ProductError> {
    match project {
        None => Ok(None),
        Some(raw) => {
            let trimmed = raw.trim();
            if trimmed.is_empty()
                || trimmed != raw
                || raw.chars().any(char::is_control)
                || trimmed.chars().count() > MAX_PROJECT_NAME_CHARS
            {
                return Err(ProductError::InvalidPersistedState);
            }
            Ok(Some(raw))
        }
    }
}
