use super::*;
use crate::domain::RecordingLifecyclePhase;

/// Maximum Unicode scalar value count for a normalized speaker label.
pub const MAX_SPEAKER_NAME_CHARS: usize = 40;

/// Maximum Unicode scalar value count for a single edited utterance segment.
pub const MAX_SEGMENT_TEXT_CHARS: usize = 20_000;

fn strip_speaker_colons(raw: &str) -> &str {
    let mut normalized = raw.trim();
    while let Some(stripped) = normalized.strip_suffix([':', '：']) {
        normalized = stripped.trim();
    }
    normalized
}

/// Lossily normalizes historical or persisted speaker strings by stripping control characters,
/// trimming surrounding whitespace and trailing colons, and truncating to [`MAX_SPEAKER_NAME_CHARS`].
#[must_use]
pub fn sanitize_speaker_lossy(raw: &str) -> Option<String> {
    let filtered: String = raw.chars().filter(|c| !c.is_control()).collect();
    let trimmed = strip_speaker_colons(&filtered);
    if trimmed.is_empty() {
        return None;
    }
    let truncated: String = trimmed.chars().take(MAX_SPEAKER_NAME_CHARS).collect();
    let final_clean = strip_speaker_colons(&truncated);
    (!final_clean.is_empty()).then(|| final_clean.to_string())
}

/// Validated, colon-stripped speaker label (`1..=40` scalar chars, zero control chars).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SpeakerName(String);

impl SpeakerName {
    /// Lossily normalizes historical or persisted speaker strings into a valid speaker label.
    #[must_use]
    pub fn sanitize_lossy(raw: &str) -> Option<String> {
        sanitize_speaker_lossy(raw)
    }

    /// Parses a required speaker label (`1..=40` chars, no control characters, trailing colons stripped).
    pub fn parse(raw: &str) -> Result<Self, ProductError> {
        Self::parse_optional(Some(raw))?
            .ok_or_else(|| ProductError::InvalidInput("说话人名称不能为空".to_string()))
    }

    /// Parses an optional speaker label, returning `Ok(None)` when absent or empty after normalization.
    pub fn parse_optional(raw: Option<&str>) -> Result<Option<Self>, ProductError> {
        let Some(raw) = raw else {
            return Ok(None);
        };
        if raw.chars().any(char::is_control) {
            return Err(ProductError::InvalidInput(
                "说话人名称不能包含控制字符".to_string(),
            ));
        }
        let normalized = strip_speaker_colons(raw);
        if normalized.is_empty() {
            return Ok(None);
        }
        if normalized.chars().count() > MAX_SPEAKER_NAME_CHARS {
            return Err(ProductError::InvalidInput(format!(
                "说话人名称不能超过 {MAX_SPEAKER_NAME_CHARS} 个字符"
            )));
        }
        Ok(Some(Self(normalized.to_string())))
    }

    /// Borrowed normalized speaker label.
    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

/// Distinct speaker roll-up in first-appearance order across a recording's spine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpeakerSummary {
    /// Normalized speaker display name.
    pub name: String,
    /// Number of segments attributed to `name`.
    pub segment_count: usize,
    /// First segment where `name` appears.
    pub first_segment_id: SegmentId,
}

/// Freshness of `aggregate.minutes` relative to `ProductRecord::content_revision`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MinutesFreshness {
    /// No structured minutes have been committed for this recording.
    Absent,
    /// Structured minutes match the current `content_revision`.
    Fresh {
        /// Content revision covered by the current minutes.
        input_revision: u64,
    },
    /// Transcript text or speaker labels changed after `minutes_revision`.
    Stale {
        /// Content revision when the retained minutes were generated.
        minutes_revision: u64,
        /// Current recording content revision (`> minutes_revision`).
        current_revision: u64,
    },
}

/// Outcome of an utterance edit or speaker attribution command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TranscriptEditReceipt {
    /// Target recording identifier.
    pub record_id: RecordId,
    /// Number of spine segments modified (`0` when idempotent).
    pub updated_segments: usize,
    /// Resulting recording content revision.
    pub content_revision: u64,
    /// Resulting structured minutes freshness.
    pub minutes_freshness: MinutesFreshness,
}

impl ProductRecord {
    /// Revision of `content_revision` at which `aggregate.minutes` was generated, if present.
    #[must_use]
    pub const fn minutes_revision(&self) -> Option<u64> {
        self.minutes_revision
    }

    /// Computes whether structured minutes are absent, fresh, or stale relative to `content_revision`.
    #[must_use]
    pub const fn minutes_freshness(&self) -> MinutesFreshness {
        if self.aggregate.minutes.is_none() {
            return MinutesFreshness::Absent;
        }
        match self.minutes_revision {
            None => MinutesFreshness::Absent,
            Some(rev) if rev < self.content_revision => MinutesFreshness::Stale {
                minutes_revision: rev,
                current_revision: self.content_revision,
            },
            Some(rev) => MinutesFreshness::Fresh {
                input_revision: rev,
            },
        }
    }

    /// Returns `true` when retained structured minutes lag behind `content_revision`.
    #[must_use]
    pub const fn is_minutes_stale(&self) -> bool {
        matches!(self.minutes_freshness(), MinutesFreshness::Stale { .. })
    }

    /// Builds a [`TranscriptEditReceipt`] reflecting current revision and minutes freshness.
    #[must_use]
    pub fn edit_receipt(&self, record_id: &str, updated_segments: usize) -> TranscriptEditReceipt {
        TranscriptEditReceipt {
            record_id: record_id.to_string(),
            updated_segments,
            content_revision: self.content_revision,
            minutes_freshness: self.minutes_freshness(),
        }
    }

    /// Lists distinct speaker labels in first-appearance order across `aggregate.spine`.
    #[must_use]
    pub fn distinct_speakers(&self) -> Vec<SpeakerSummary> {
        let mut summaries: Vec<SpeakerSummary> = Vec::new();
        for seg in self.aggregate.spine.segments() {
            let Some(speaker) = seg.speaker.as_deref().map(str::trim).filter(|s| !s.is_empty())
            else {
                continue;
            };
            if let Some(existing) = summaries.iter_mut().find(|item| item.name == speaker) {
                existing.segment_count += 1;
            } else {
                summaries.push(SpeakerSummary {
                    name: speaker.to_string(),
                    segment_count: 1,
                    first_segment_id: seg.id,
                });
            }
        }
        summaries
    }

    /// Rejects transcript/speaker edits on trashed, archived, copying, or transcribing records.
    pub fn ensure_transcript_editable(&self) -> Result<(), ProductError> {
        self.ensure_live()?;
        if self.is_archived() {
            return Err(ProductError::RecordArchived);
        }
        if self.aggregate.phase == RecordingLifecyclePhase::Copying
            || matches!(
                self.analysis,
                AnalysisState::Pending {
                    stage: AnalysisStage::Transcribing,
                    ..
                }
            )
        {
            return Err(ProductError::Busy);
        }
        Ok(())
    }

    pub(super) fn mark_transcript_edited(&mut self) {
        self.content_revision = self.content_revision.saturating_add(1);
        if !self.aggregate.visual_cards.is_empty() {
            self.aggregate.synthesize_visual_cards();
        }
        if matches!(
            self.analysis,
            AnalysisState::Pending {
                stage: AnalysisStage::Summarizing,
                ..
            }
        ) {
            if let Some(input_revision) = self.minutes_revision {
                self.analysis = AnalysisState::Ready { input_revision };
                self.aggregate.phase = RecordingLifecyclePhase::Ready;
            } else {
                self.analysis = AnalysisState::Idle;
                self.aggregate.phase = RecordingLifecyclePhase::Local;
            }
        }
    }
}

impl ProductWorkspace {
    /// Edits the text of one segment while retaining `original_text` ASR provenance.
    pub fn edit_segment_text(
        &mut self,
        source: &SourceRef,
        text: &str,
    ) -> Result<TranscriptEditReceipt, ProductError> {
        let record = self
            .records
            .get_mut(&source.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_transcript_editable()?;
        if text
            .chars()
            .any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t'))
        {
            return Err(ProductError::InvalidInput(
                "片段内容不能包含控制字符".to_string(),
            ));
        }
        let normalized = if text.contains('\r') {
            text.replace("\r\n", "\n").replace('\r', "\n")
        } else {
            text.to_string()
        };
        let clean = normalized.trim();
        if clean.is_empty() {
            return Err(ProductError::InvalidInput("片段内容不能为空".to_string()));
        }
        if clean.chars().count() > MAX_SEGMENT_TEXT_CHARS {
            return Err(ProductError::InvalidInput(format!(
                "片段内容不能超过 {MAX_SEGMENT_TEXT_CHARS} 个字符"
            )));
        }
        let seg = record
            .aggregate
            .spine
            .get(source.segment_id)
            .ok_or(ProductError::SegmentNotFound)?;
        if seg.text == clean {
            return Ok(record.edit_receipt(&source.record_id, 0));
        }
        let updated = record
            .aggregate
            .spine
            .update_segment_text(source.segment_id, clean);
        debug_assert!(updated);
        record.mark_transcript_edited();
        let receipt = record.edit_receipt(&source.record_id, 1);
        self.changed();
        Ok(receipt)
    }

    /// Sets or clears the speaker label on one segment.
    pub fn set_segment_speaker(
        &mut self,
        source: &SourceRef,
        speaker: Option<&str>,
    ) -> Result<TranscriptEditReceipt, ProductError> {
        let record = self
            .records
            .get_mut(&source.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_transcript_editable()?;
        let parsed = SpeakerName::parse_optional(speaker)?;
        let next_speaker = parsed.as_ref().map(SpeakerName::as_str);
        let seg = record
            .aggregate
            .spine
            .get(source.segment_id)
            .ok_or(ProductError::SegmentNotFound)?;
        if seg.speaker.as_deref() == next_speaker {
            return Ok(record.edit_receipt(&source.record_id, 0));
        }
        let updated = record
            .aggregate
            .spine
            .set_speaker(source.segment_id, next_speaker.map(ToOwned::to_owned));
        debug_assert!(updated);
        record.mark_transcript_edited();
        let receipt = record.edit_receipt(&source.record_id, 1);
        self.changed();
        Ok(receipt)
    }

    /// Imports a historical or migrated speaker label using lossy normalization without
    /// advancing `content_revision` or rejecting legacy formatting.
    pub fn import_segment_speaker(
        &mut self,
        source: &SourceRef,
        speaker: Option<&str>,
    ) -> Result<(), ProductError> {
        let record = self
            .records
            .get_mut(&source.record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record
            .aggregate
            .spine
            .get(source.segment_id)
            .ok_or(ProductError::SegmentNotFound)?;
        let normalized = speaker.and_then(sanitize_speaker_lossy);
        if record
            .aggregate
            .spine
            .set_speaker(source.segment_id, normalized)
        {
            self.changed();
        }
        Ok(())
    }

    /// Renames or merges all segments matching `from_speaker` into `to_speaker`.
    pub fn rename_speaker(
        &mut self,
        record_id: &str,
        from_speaker: &str,
        to_speaker: &str,
    ) -> Result<TranscriptEditReceipt, ProductError> {
        let record = self
            .records
            .get_mut(record_id)
            .ok_or(ProductError::UnknownRecord)?;
        record.ensure_transcript_editable()?;
        let from = SpeakerName::parse(from_speaker)?;
        let to = SpeakerName::parse(to_speaker)?;
        let count = record
            .aggregate
            .spine
            .replace_speaker_name(from.as_str(), to.as_str());
        if count == 0 {
            if from == to
                && record
                    .aggregate
                    .spine
                    .segments()
                    .iter()
                    .any(|seg| seg.speaker.as_deref() == Some(from.as_str()))
            {
                return Ok(record.edit_receipt(record_id, 0));
            }
            return Err(ProductError::InvalidInput("未找到该说话人".to_string()));
        }
        record.mark_transcript_edited();
        let receipt = record.edit_receipt(record_id, count);
        self.changed();
        Ok(receipt)
    }
}
