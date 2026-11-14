//! Canonical utterance spine (`S1..Sn`), structured meeting minutes (`MeetingMinutes`),
//! and per-recording aggregate state.
//!
//! Every downstream subsystem (minutes grounding, persistence, and Q&A) reads from
//! [`UtteranceSpine`] via 1-based [`SegmentId`] citations (`S1..Sn`) instead of mutating
//! raw transcript strings.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::collections::BTreeMap;
use std::fmt;
use std::num::NonZeroU32;
use std::str::FromStr;

/// 1-based immutable segment citation identifier (`S1..Sn`).
///
/// Wraps [`NonZeroU32`] so `S0` is unrepresentable in the type system.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct SegmentId(NonZeroU32);

impl SegmentId {
    /// Creates a 1-based [`SegmentId`] from `ordinal`, returning `None` when `ordinal == 0`.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::domain::SegmentId;
    ///
    /// assert!(SegmentId::new(0).is_none());
    /// assert_eq!(SegmentId::new(1).map(|id| id.to_string()), Some("S1".to_string()));
    /// ```
    #[must_use]
    pub const fn new(ordinal: u32) -> Option<Self> {
        match NonZeroU32::new(ordinal) {
            Some(nz) => Some(Self(nz)),
            None => None,
        }
    }

    /// Creates a 1-based [`SegmentId`] from a zero-based slice index (`0 -> S1`).
    ///
    /// Returns `None` if `index` overflows `u32::MAX - 1`.
    #[must_use]
    pub fn from_zero_based(index: usize) -> Option<Self> {
        let ordinal = u32::try_from(index).ok()?.checked_add(1)?;
        Self::new(ordinal)
    }

    /// Returns the 1-based numeric ordinal (`1` for `S1`).
    #[must_use]
    pub const fn ordinal(self) -> u32 {
        self.0.get()
    }

    /// Returns the 0-based slice index (`0` for `S1`).
    #[must_use]
    pub const fn zero_based_index(self) -> usize {
        (self.0.get() - 1) as usize
    }

    /// Parses a citation token such as `"S1"`, `"s12"`, or `"[S3]"`.
    ///
    /// # Examples
    ///
    /// ```
    /// use koe_engine::domain::SegmentId;
    ///
    /// assert_eq!(SegmentId::parse_citation("S1").map(SegmentId::ordinal), Some(1));
    /// assert_eq!(SegmentId::parse_citation("[s42]").map(SegmentId::ordinal), Some(42));
    /// assert_eq!(SegmentId::parse_citation("S0"), None);
    /// ```
    #[must_use]
    pub fn parse_citation(token: &str) -> Option<Self> {
        let trimmed = token.trim();
        let inner = trimmed
            .strip_prefix('[')
            .and_then(|s| s.strip_suffix(']'))
            .unwrap_or(trimmed)
            .trim();
        let digits = inner
            .strip_prefix('S')
            .or_else(|| inner.strip_prefix('s'))?;
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let ordinal = digits.parse::<u32>().ok()?;
        Self::new(ordinal)
    }
}

impl fmt::Display for SegmentId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "S{}", self.0.get())
    }
}

impl FromStr for SegmentId {
    type Err = &'static str;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        Self::parse_citation(s).ok_or("invalid SegmentId citation")
    }
}

/// A single time-aligned, speaker-attributed utterance in [`UtteranceSpine`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UtteranceSegment {
    /// Immutable 1-based identifier (`S1..Sn`).
    pub id: SegmentId,
    /// Optional provider stream key (`"{session}#{stream_key}"`) used for idempotent deduplication.
    pub stream_key: Option<String>,
    /// Optional speaker label (such as `"发言人 1"` or `"Alice"`).
    pub speaker: Option<String>,
    /// Start offset from the beginning of the recording in milliseconds.
    pub start_ms: u64,
    /// End offset from the beginning of the recording in milliseconds (`>= start_ms`).
    pub end_ms: u64,
    /// Canonical UTF-8 source transcript text.
    pub text: String,
    /// Original finalized ASR text retained when `text` differs from its initial baseline.
    pub original_text: Option<String>,
    /// Monotonically increasing segment revision (starts at `1`, increments on text edit).
    pub revision: u32,
    /// Whether the ASR provider has finalized this utterance.
    pub is_final: bool,
    /// BCP-47 or short language code of `text` (such as `"zh"` or `"en"`).
    pub source_language: String,
    /// Optional translated text aligned to the current `revision`.
    pub translation: Option<String>,
    /// Optional target language code for `translation`.
    pub target_language: Option<String>,
    /// ASR or translation provider identifier (such as `"qwen-asr"` or `"local"`).
    pub provider: String,
}

impl UtteranceSegment {
    /// Returns the segment duration in milliseconds (`end_ms.saturating_sub(start_ms)`).
    #[must_use]
    pub const fn duration_ms(&self) -> u64 {
        self.end_ms.saturating_sub(self.start_ms)
    }

    /// Returns the baseline ASR text prior to manual editing, or `text` when unedited.
    #[must_use]
    pub fn asr_text(&self) -> &str {
        self.original_text.as_deref().unwrap_or(&self.text)
    }

    /// Returns `true` when `text` differs from its initial ASR baseline.
    #[must_use]
    pub const fn is_edited(&self) -> bool {
        self.original_text.is_some()
    }
}

/// Append-only, revision-tracked utterance spine (`S1..Sn`) for a recording or live session.
///
/// Editing a segment's text increments both the segment's `revision` and the spine's
/// `revision`, invalidates stale translations on that segment, and sets `stale = true`
/// so downstream minutes and context reducers know to re-evaluate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UtteranceSpine {
    session_id: String,
    segments: Vec<UtteranceSegment>,
    revision: u64,
    key_to_id: BTreeMap<String, SegmentId>,
    confirmed_by_connection: BTreeMap<String, String>,
    stale: bool,
}

impl Default for UtteranceSpine {
    fn default() -> Self {
        Self::new("default")
    }
}

impl UtteranceSpine {
    /// Creates an empty [`UtteranceSpine`] for `session_id`.
    #[must_use]
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            segments: Vec::new(),
            revision: 0,
            key_to_id: BTreeMap::new(),
            confirmed_by_connection: BTreeMap::new(),
            stale: false,
        }
    }

    /// Returns the owning session or recording identifier.
    #[must_use]
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Returns the monotonically increasing spine revision (`0` when newly created).
    #[must_use]
    pub const fn revision(&self) -> u64 {
        self.revision
    }

    /// Returns `true` if a manual edit or speaker replacement has invalidated derived artifacts.
    #[must_use]
    pub const fn is_stale(&self) -> bool {
        self.stale
    }

    /// Clears the stale flag after downstream minutes/context regeneration completes.
    pub fn clear_stale(&mut self) {
        self.stale = false;
    }

    /// Returns the total number of segments (`S1..Sn`).
    #[must_use]
    pub fn len(&self) -> usize {
        self.segments.len()
    }

    /// Returns `true` when the spine contains no segments.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.segments.is_empty()
    }

    /// Returns an immutable slice of all segments in `S1..Sn` order.
    #[must_use]
    pub fn segments(&self) -> &[UtteranceSegment] {
        &self.segments
    }

    /// Looks up a segment by its 1-based [`SegmentId`].
    #[must_use]
    pub fn get(&self, id: SegmentId) -> Option<&UtteranceSegment> {
        self.segments.get(id.zero_based_index())
    }

    /// Returns all segments whose time interval overlaps `[start_ms, end_ms]`.
    #[must_use]
    pub fn segments_in_range(&self, start_ms: u64, end_ms: u64) -> Vec<&UtteranceSegment> {
        let hi = end_ms.max(start_ms);
        self.segments
            .iter()
            .filter(|seg| seg.end_ms >= start_ms && seg.start_ms <= hi)
            .collect()
    }

    /// Appends a finalized utterance segment and returns its newly assigned [`SegmentId`].
    ///
    /// Blank or whitespace-only `text` is ignored and returns `None`.
    pub fn append_segment(
        &mut self,
        text: impl Into<String>,
        start_ms: u64,
        end_ms: u64,
        source_language: impl Into<String>,
        provider: impl Into<String>,
    ) -> Option<SegmentId> {
        let clean = text.into().trim().to_string();
        if clean.is_empty() {
            return None;
        }
        let id = SegmentId::from_zero_based(self.segments.len())?;
        let normalized_end = end_ms.max(start_ms);
        self.segments.push(UtteranceSegment {
            id,
            stream_key: None,
            speaker: None,
            start_ms,
            end_ms: normalized_end,
            text: clean,
            original_text: None,
            revision: 1,
            is_final: true,
            source_language: source_language.into(),
            translation: None,
            target_language: None,
            provider: provider.into(),
        });
        self.revision = self.revision.saturating_add(1);
        Some(id)
    }

    /// Accepts a finalized streaming segment keyed by `(session, stream_key)`.
    ///
    /// If the composite key `"session#stream_key"` already exists, updates that segment's
    /// text/translation in place when changed; otherwise appends a new `S{n}` segment.
    #[allow(clippy::too_many_arguments)]
    pub fn accept_final(
        &mut self,
        session: &str,
        stream_key: &str,
        text: &str,
        source_language: &str,
        translation: Option<&str>,
        target_language: Option<&str>,
        provider: &str,
    ) -> Option<SegmentId> {
        let clean = text.trim();
        if clean.is_empty() {
            return None;
        }
        let composite_key = format!("{session}#{stream_key}");
        let clean_trans = translation
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);
        let clean_target = target_language
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);

        if let Some(&existing_id) = self.key_to_id.get(&composite_key) {
            if let Some(seg) = self.segments.get_mut(existing_id.zero_based_index()) {
                let mut changed = false;
                if seg.text != clean {
                    seg.text = clean.to_string();
                    if seg.original_text.as_deref() == Some(seg.text.as_str()) {
                        seg.original_text = None;
                    }
                    seg.revision = seg.revision.saturating_add(1);
                    changed = true;
                }
                if clean_trans.is_some() && seg.translation != clean_trans {
                    seg.translation = clean_trans;
                    seg.target_language = clean_target;
                    changed = true;
                }
                if changed {
                    self.revision = self.revision.saturating_add(1);
                }
            }
            return Some(existing_id);
        }

        let id = SegmentId::from_zero_based(self.segments.len())?;
        self.segments.push(UtteranceSegment {
            id,
            stream_key: Some(composite_key.clone()),
            speaker: None,
            start_ms: 0,
            end_ms: 0,
            text: clean.to_string(),
            original_text: None,
            revision: 1,
            is_final: true,
            source_language: source_language.trim().to_string(),
            translation: clean_trans,
            target_language: clean_target,
            provider: provider.trim().to_string(),
        });
        self.key_to_id.insert(composite_key, id);
        self.revision = self.revision.saturating_add(1);
        Some(id)
    }

    /// Accepts cumulative ASR text for `connection_id`, stripping any previously confirmed
    /// prefix and appending only the newly spoken suffix as a new [`SegmentId`].
    pub fn accept_cumulative(
        &mut self,
        connection_id: &str,
        text: &str,
        source_language: &str,
        translation: Option<&str>,
        target_language: Option<&str>,
        provider: &str,
    ) -> Option<SegmentId> {
        let clean = text.trim();
        if clean.is_empty() {
            return None;
        }
        let prev = self
            .confirmed_by_connection
            .get(connection_id)
            .map_or("", String::as_str);
        if clean == prev {
            return self.segments.last().map(|s| s.id);
        }
        let delta = if !prev.is_empty() && clean.starts_with(prev) {
            clean[prev.len()..].trim()
        } else {
            clean
        };
        self.confirmed_by_connection
            .insert(connection_id.to_string(), clean.to_string());
        if delta.is_empty() {
            return self.segments.last().map(|s| s.id);
        }
        let id = self.append_segment(delta, 0, 0, source_language, provider)?;
        if let Some(tr) = translation.map(str::trim).filter(|s| !s.is_empty()) {
            let _ = self.set_translation(id, tr, target_language.unwrap_or(""));
        }
        Some(id)
    }

    /// Updates the source text of segment `id`, latching its initial unedited ASR text into
    /// `original_text` (or clearing `original_text` when reverted to that original text),
    /// increments both segment and spine revisions, clears any existing translation on that
    /// segment, and marks the spine stale.
    pub fn update_segment_text(&mut self, id: SegmentId, new_text: impl Into<String>) -> bool {
        let clean = new_text.into().trim().to_string();
        if clean.is_empty() {
            return false;
        }
        let Some(seg) = self.segments.get_mut(id.zero_based_index()) else {
            return false;
        };
        if seg.text == clean {
            return false;
        }
        let orig = seg.original_text.take().unwrap_or_else(|| seg.text.clone());
        seg.text = clean;
        seg.original_text = (seg.text != orig && !orig.is_empty()).then_some(orig);
        seg.revision = seg.revision.saturating_add(1);
        seg.translation = None;
        seg.target_language = None;
        self.revision = self.revision.saturating_add(1);
        self.stale = true;
        true
    }

    /// Restores persisted `original_text` onto segment `id` without advancing revisions,
    /// self-healing empty or redundant values matching `seg.text` back to `None`.
    pub fn restore_original_text(&mut self, id: SegmentId, original_text: String) -> bool {
        let Some(seg) = self.segments.get_mut(id.zero_based_index()) else {
            return false;
        };
        let clean = original_text.trim();
        if clean.is_empty() || seg.text == clean {
            seg.original_text = None;
            return true;
        }
        seg.original_text = Some(clean.to_string());
        true
    }

    /// Updates the source text and timestamps of segment `id`. When the source text changes,
    /// clears any existing translation on that segment. Increments segment and spine revisions
    /// and marks the spine stale whenever text, `start_ms`, or `end_ms` changes.
    pub fn update_segment(
        &mut self,
        id: SegmentId,
        new_text: impl Into<String>,
        start_ms: u64,
        end_ms: u64,
    ) -> bool {
        let clean = new_text.into().trim().to_string();
        if clean.is_empty() || end_ms < start_ms {
            return false;
        }
        let Some(seg) = self.segments.get_mut(id.zero_based_index()) else {
            return false;
        };
        let text_changed = seg.text != clean;
        let time_changed = seg.start_ms != start_ms || seg.end_ms != end_ms;
        if !text_changed && !time_changed {
            return false;
        }
        if text_changed {
            seg.text = clean;
            if seg.original_text.as_deref() == Some(seg.text.as_str()) {
                seg.original_text = None;
            }
            seg.translation = None;
            seg.target_language = None;
        }
        seg.start_ms = start_ms;
        seg.end_ms = end_ms;
        seg.revision = seg.revision.saturating_add(1);
        self.revision = self.revision.saturating_add(1);
        self.stale = true;
        true
    }

    /// Sets or clears the speaker label on segment `id`.
    pub fn set_speaker(&mut self, id: SegmentId, speaker: Option<String>) -> bool {
        let Some(seg) = self.segments.get_mut(id.zero_based_index()) else {
            return false;
        };
        let normalized = speaker
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());
        if seg.speaker == normalized {
            return false;
        }
        seg.speaker = normalized;
        seg.revision = seg.revision.saturating_add(1);
        self.revision = self.revision.saturating_add(1);
        self.stale = true;
        true
    }

    /// Attaches or updates the translated text for segment `id`.
    pub fn set_translation(
        &mut self,
        id: SegmentId,
        translation: impl Into<String>,
        target_language: impl Into<String>,
    ) -> bool {
        let clean_tr = translation.into().trim().to_string();
        if clean_tr.is_empty() {
            return false;
        }
        let clean_lang = target_language.into().trim().to_string();
        let Some(seg) = self.segments.get_mut(id.zero_based_index()) else {
            return false;
        };
        let next_lang = if clean_lang.is_empty() {
            None
        } else {
            Some(clean_lang)
        };
        if seg.translation.as_deref() == Some(clean_tr.as_str()) && seg.target_language == next_lang
        {
            return false;
        }
        seg.translation = Some(clean_tr);
        seg.target_language = next_lang;
        self.revision = self.revision.saturating_add(1);
        true
    }

    /// Clears `translation` on every segment and optionally updates `target_language`
    /// to `next_target_language`, incrementing the spine revision when any segment changes.
    pub fn invalidate_translations(&mut self, next_target_language: Option<&str>) -> usize {
        let normalized_lang = next_target_language
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToString::to_string);
        let mut changed = 0usize;
        for seg in &mut self.segments {
            let had_tr = seg.translation.take().is_some();
            let lang_diff = seg.target_language != normalized_lang;
            if lang_diff {
                seg.target_language.clone_from(&normalized_lang);
            }
            if had_tr || lang_diff {
                changed += 1;
            }
        }
        if changed > 0 {
            self.revision = self.revision.saturating_add(1);
        }
        changed
    }

    /// Renames every occurrence of `old_speaker` to `new_speaker` across all segments,
    /// matching colon-suffixed legacy labels and returning the number of segments updated.
    pub fn replace_speaker_name(&mut self, old_speaker: &str, new_speaker: &str) -> usize {
        fn strip_colons(raw: &str) -> &str {
            let mut cur = raw.trim();
            while let Some(stripped) = cur.strip_suffix([':', '：']) {
                cur = stripped.trim();
            }
            cur
        }
        let old_key = strip_colons(old_speaker);
        let new_trimmed = strip_colons(new_speaker);
        if old_key.is_empty() || new_trimmed.is_empty() {
            return 0;
        }
        let mut updated = 0usize;
        for seg in &mut self.segments {
            if seg
                .speaker
                .as_deref()
                .is_some_and(|spk| strip_colons(spk) == old_key && spk != new_trimmed)
            {
                seg.speaker = Some(new_trimmed.to_string());
                seg.revision = seg.revision.saturating_add(1);
                updated += 1;
            }
        }
        if updated > 0 {
            self.revision = self.revision.saturating_add(1);
            self.stale = true;
        }
        updated
    }

    /// Returns `true` if `id` resolves to an existing non-empty segment in this spine.
    #[must_use]
    pub fn validate_citation(&self, id: SegmentId) -> bool {
        self.get(id).is_some_and(|seg| !seg.text.trim().is_empty())
    }

    /// Formats every segment as `"[S1] <text>"` (or `"[S1] <speaker>: <text>"` when speaker is set)
    /// for LLM prompt grounding.
    #[must_use]
    pub fn format_cited_sources(&self) -> Vec<String> {
        self.segments
            .iter()
            .map(|seg| match &seg.speaker {
                Some(spk) if !spk.is_empty() => format!("[{}] {}: {}", seg.id, spk, seg.text),
                _ => format!("[{}] {}", seg.id, seg.text),
            })
            .collect()
    }

    /// Returns borrowed source text slices in `S1..Sn` order.
    #[must_use]
    pub fn source_texts(&self) -> Vec<&str> {
        self.segments.iter().map(|s| s.text.as_str()).collect()
    }

    /// Clears all segments while advancing `revision` by 1 and resetting `stale = false`.
    pub fn clear(&mut self) -> u64 {
        self.segments.clear();
        self.key_to_id.clear();
        self.confirmed_by_connection.clear();
        self.stale = false;
        self.revision = self.revision.saturating_add(1);
        self.revision
    }
}

/// Structured meeting minutes (`v2`) grounded in [`UtteranceSpine`] citations (`S1..Sn`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MeetingMinutes {
    /// Schema version (`1` or `2`).
    pub version: u32,
    /// Spine revision at the moment these minutes were generated.
    pub spine_revision: u64,
    /// Concise meeting title.
    pub title: String,
    /// High-level summary paragraph.
    pub overview: String,
    /// Ordered discussion topics with `S1..Sn` cited points.
    pub topics: Vec<MinuteTopic>,
    /// Key decisions made during the meeting.
    pub decisions: Vec<MinutePoint>,
    /// Action items with optional owner and due date.
    pub actions: Vec<MinutePoint>,
    /// Open questions raised during the meeting.
    pub questions: Vec<MinutePoint>,
    /// Root-cause fishbone diagrams for issues raised in the meeting.
    pub fishbones: Vec<MinuteFishbone>,
    /// Domain terminology and jargon table extracted from the meeting.
    pub terms: Vec<MinuteTerm>,
    /// User-defined or template-driven custom sections.
    pub custom_sections: Vec<MinuteCustomSection>,
    /// Grounding review warnings or flagged items (`reviewItems`).
    pub review_items: Vec<String>,
}

/// A thematic section in [`MeetingMinutes`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinuteTopic {
    /// Topic title.
    pub title: String,
    /// Summary of the topic discussion.
    pub summary: String,
    /// Topic-level [`SegmentId`] citations.
    pub citations: Vec<SegmentId>,
    /// Bullet points backed by [`SegmentId`] citations.
    pub points: Vec<MinutePoint>,
    /// Optional fishbone root-cause analysis attached to this topic.
    pub fishbone: Option<MinuteFishbone>,
}

/// A single factual claim, decision, or action point backed by `S1..Sn` citations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinutePoint {
    /// Factual claim text.
    pub claim: String,
    /// Optional speaker who made the point.
    pub speaker: Option<String>,
    /// Optional action item owner.
    pub owner: Option<String>,
    /// Optional action item due date or deadline text.
    pub due: Option<String>,
    /// Non-empty list of [`SegmentId`] citations supporting `claim`.
    pub citations: Vec<SegmentId>,
}

/// Fishbone (Ishikawa) root-cause analysis entry in [`MeetingMinutes`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinuteFishbone {
    /// Problem statement or effect being analyzed.
    pub issue: String,
    /// Contributing causes with citations.
    pub causes: Vec<MinuteCause>,
}

/// A single cause branch in a [`MinuteFishbone`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinuteCause {
    /// Cause category (such as `"流程"`, `"设备"`, `"沟通"`).
    pub category: String,
    /// Description of the cause.
    pub description: String,
    /// Supporting [`SegmentId`] citations.
    pub citations: Vec<SegmentId>,
}

/// Adoption state of a [`MinuteTerm`] in the user's personal glossary (`qwennote-minutes`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MinuteTermAdoption {
    /// Candidate term awaiting user review.
    Suggested,
    /// Accepted into the persistent hot-word glossary.
    Adopted,
    /// Dismissed by the user.
    Dismissed,
}

/// A domain term or proper noun extracted during minutes generation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinuteTerm {
    /// Canonical term spelling.
    pub term: String,
    /// Plain-language definition in context.
    pub definition: String,
    /// Misheard ASR variants that appear verbatim in cited segments.
    pub heard: Vec<String>,
    /// Current glossary adoption status.
    pub adoption: MinuteTermAdoption,
    /// Supporting [`SegmentId`] citations where the term was used.
    pub citations: Vec<SegmentId>,
}

/// A custom template section in [`MeetingMinutes`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinuteCustomSection {
    /// Section heading.
    pub heading: String,
    /// Grounded points under this heading.
    pub points: Vec<MinutePoint>,
}

/// Lifecycle phase of a [`RecordingAggregate`] across hardware sync, local storage, and AI synthesis.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum RecordingLifecyclePhase {
    /// Audio slices are actively streaming or copying from the D3200 bean.
    #[default]
    Copying,
    /// Audio container (`.opus`/`.wav`) is stored locally and ready for transcription.
    Local,
    /// ASR transcription and structured synthesis are in progress.
    Transcribing,
    /// Utterance spine and structured minutes are ready for reading.
    Ready,
    /// Transfer or transcription failed and can be retried.
    Failed,
}

impl RecordingLifecyclePhase {
    /// Returns the canonical wire token (`"copying"`, `"local"`, `"transcribing"`, `"ready"`, `"failed"`).
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Copying => "copying",
            Self::Local => "local",
            Self::Transcribing => "transcribing",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    /// Returns `true` when the phase has reached a settled outcome (`Ready` or `Failed`).
    #[must_use]
    pub const fn is_terminal(&self) -> bool {
        matches!(self, Self::Ready | Self::Failed)
    }

    /// Returns `true` when a transcription or re-synthesis pass can be launched from this phase.
    #[must_use]
    pub const fn can_transcribe(&self) -> bool {
        matches!(self, Self::Local | Self::Ready | Self::Failed)
    }
}

/// User-selectable structured summary presentation format for a [`RecordingAggregate`].
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Hash)]
pub enum SummaryFormat {
    /// Decision-oriented executive memo (`"决议备忘"`).
    #[default]
    DecisionMemo,
    /// Owner and deadline focused action list (`"待办清单"`).
    ActionList,
    /// Ishikawa root-cause fishbone breakdown (`"鱼骨溯源"`).
    RootCauseFishbone,
    /// Cicada side-by-side bilingual brief (`"双语简报"`).
    BilingualBrief,
    /// Personal journal and reflection synthesis (`"个人随记"`).
    PersonalReflection,
    /// Concise bulleted quick note (`"要点速记"`).
    QuickNote,
}

impl SummaryFormat {
    /// All supported [`SummaryFormat`] variants in display order.
    pub const ALL: [Self; 6] = [
        Self::DecisionMemo,
        Self::ActionList,
        Self::RootCauseFishbone,
        Self::BilingualBrief,
        Self::PersonalReflection,
        Self::QuickNote,
    ];

    /// Returns the canonical wire token for this summary format.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::DecisionMemo => "decision_memo",
            Self::ActionList => "action_list",
            Self::RootCauseFishbone => "root_cause_fishbone",
            Self::BilingualBrief => "bilingual_brief",
            Self::PersonalReflection => "personal_reflection",
            Self::QuickNote => "quick_note",
        }
    }

    /// Returns the localized Chinese label for this summary format.
    #[must_use]
    pub const fn label_zh(&self) -> &'static str {
        match self {
            Self::DecisionMemo => "决议备忘",
            Self::ActionList => "待办清单",
            Self::RootCauseFishbone => "鱼骨溯源",
            Self::BilingualBrief => "双语简报",
            Self::PersonalReflection => "个人随记",
            Self::QuickNote => "要点速记",
        }
    }

    /// Parses a wire token or Chinese label into a [`SummaryFormat`].
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim() {
            "decision_memo" | "决议备忘" => Some(Self::DecisionMemo),
            "action_list" | "待办清单" => Some(Self::ActionList),
            "root_cause_fishbone" | "鱼骨溯源" => Some(Self::RootCauseFishbone),
            "bilingual_brief" | "双语简报" => Some(Self::BilingualBrief),
            "personal_reflection" | "个人随记" => Some(Self::PersonalReflection),
            "quick_note" | "要点速记" => Some(Self::QuickNote),
            _ => None,
        }
    }
}

/// Unified domain aggregate root for a single recording across capture, transcript spine,
/// and structured minutes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordingAggregate {
    /// Stable recording identifier (`"rec-{file_id}"` or UUID).
    pub recording_id: String,
    /// Hardware D3200 file identifier (`0` for local-mic recordings).
    pub file_id: u32,
    /// Current lifecycle phase.
    pub phase: RecordingLifecyclePhase,
    /// Optional coarse geographic place tag (such as `"北京市·海淀区"`).
    pub coarse_place: Option<String>,
    /// Sorted, deduplicated hardware double-tap or manual bookmark timestamps in milliseconds.
    pub bookmarks: Vec<u64>,
    /// Canonical `S1..Sn` utterance spine.
    pub spine: UtteranceSpine,
    /// Active summary presentation format selected by the user.
    pub selected_format: SummaryFormat,
    /// Optional structured meeting minutes (`v2`).
    pub minutes: Option<MeetingMinutes>,
    /// UTC creation timestamp in Unix seconds.
    pub created_at_epoch_sec: u64,
    /// Recording duration in milliseconds.
    pub duration_ms: u64,
}

impl RecordingAggregate {
    /// Creates a new [`RecordingAggregate`] in [`RecordingLifecyclePhase::Copying`] with an empty spine.
    #[must_use]
    pub fn new(
        recording_id: impl Into<String>,
        file_id: u32,
        created_at_epoch_sec: u64,
        duration_ms: u64,
    ) -> Self {
        let rec_id = recording_id.into();
        let spine = UtteranceSpine::new(rec_id.clone());
        Self {
            recording_id: rec_id,
            file_id,
            phase: RecordingLifecyclePhase::Copying,
            coarse_place: None,
            bookmarks: Vec::new(),
            spine,
            selected_format: SummaryFormat::DecisionMemo,
            minutes: None,
            created_at_epoch_sec,
            duration_ms,
        }
    }

    /// Reconstructs a [`RecordingAggregate`] from an existing [`UtteranceSpine`] and optional
    /// [`MeetingMinutes`].
    #[must_use]
    pub fn from_spine_and_minutes(
        recording_id: impl Into<String>,
        file_id: u32,
        created_at_epoch_sec: u64,
        duration_ms: u64,
        spine: UtteranceSpine,
        minutes: Option<MeetingMinutes>,
    ) -> Self {
        let phase = if minutes.is_some() || !spine.is_empty() {
            RecordingLifecyclePhase::Ready
        } else {
            RecordingLifecyclePhase::Local
        };
        Self {
            recording_id: recording_id.into(),
            file_id,
            phase,
            coarse_place: None,
            bookmarks: Vec::new(),
            spine,
            selected_format: SummaryFormat::DecisionMemo,
            minutes,
            created_at_epoch_sec,
            duration_ms,
        }
    }

    /// Inserts a bookmark timestamp in milliseconds if not already present, keeping `bookmarks` sorted.
    pub fn add_bookmark(&mut self, position_ms: u64) -> bool {
        if self.bookmarks.contains(&position_ms) {
            return false;
        }
        self.bookmarks.push(position_ms);
        self.bookmarks.sort_unstable();
        true
    }

    /// Updates the lifecycle phase of this recording.
    pub fn set_phase(&mut self, phase: RecordingLifecyclePhase) {
        self.phase = phase;
    }

    /// Switches the active [`SummaryFormat`].
    pub fn set_selected_format(&mut self, format: SummaryFormat) {
        self.selected_format = format;
    }

    /// Attaches validated [`MeetingMinutes`] and transitions the aggregate to
    /// [`RecordingLifecyclePhase::Ready`].
    pub fn attach_minutes(&mut self, minutes: MeetingMinutes) {
        self.minutes = Some(minutes);
        self.phase = RecordingLifecyclePhase::Ready;
    }

    /// Sets or clears the coarse geographic place tag, trimming whitespace.
    pub fn update_coarse_place(&mut self, place: Option<String>) {
        self.coarse_place = place
            .map(|p| p.trim().to_string())
            .filter(|p| !p.is_empty());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn segment_id_rejects_zero_and_roundtrips_citations() {
        assert_eq!(SegmentId::new(0), None);
        let s1 = SegmentId::new(1).expect("S1 must be valid");
        assert_eq!(s1.ordinal(), 1);
        assert_eq!(s1.zero_based_index(), 0);
        assert_eq!(s1.to_string(), "S1");
        assert_eq!(SegmentId::from_zero_based(0), Some(s1));
        assert_eq!(SegmentId::parse_citation("S1"), Some(s1));
        assert_eq!(SegmentId::parse_citation("s1"), Some(s1));
        assert_eq!(SegmentId::parse_citation("[S1]"), Some(s1));
        assert_eq!(
            " [s19] ".parse::<SegmentId>(),
            Ok(SegmentId::new(19).unwrap())
        );
        assert_eq!(SegmentId::parse_citation("S0"), None);
        assert_eq!(SegmentId::parse_citation("Sabc"), None);
        assert_eq!(SegmentId::parse_citation("1"), None);
    }

    #[test]
    fn spine_append_edit_translation_invalidation_and_speaker_replace() {
        let mut spine = UtteranceSpine::new("rec-101");
        assert!(spine.is_empty());
        assert_eq!(spine.revision(), 0);
        assert_eq!(spine.append_segment("   ", 0, 100, "zh", "qwen"), None);

        let s1 = spine
            .append_segment("基本工资是3910元。", 0, 2_400, "zh", "qwen")
            .expect("S1");
        let s2 = spine
            .append_segment("绩效发放比例为80%。", 2_400, 5_000, "zh", "qwen")
            .expect("S2");
        assert_eq!(s1.to_string(), "S1");
        assert_eq!(s2.to_string(), "S2");
        assert_eq!(spine.len(), 2);
        assert_eq!(spine.revision(), 2);
        assert!(!spine.is_stale());
        assert_eq!(spine.get(s1).unwrap().duration_ms(), 2_400);

        assert!(spine.set_translation(s1, "The base salary is 3910 CNY.", "en"));
        assert_eq!(
            spine.get(s1).unwrap().translation.as_deref(),
            Some("The base salary is 3910 CNY.")
        );
        let rev_after_tr = spine.revision();

        assert!(spine.update_segment_text(s1, "基本工资调整为4200元。"));
        assert!(spine.is_stale());
        assert!(spine.revision() > rev_after_tr);
        let updated_s1 = spine.get(s1).unwrap();
        assert_eq!(updated_s1.revision, 2);
        assert_eq!(updated_s1.translation, None);
        assert_eq!(updated_s1.target_language, None);

        spine.clear_stale();
        assert!(!spine.is_stale());

        assert!(spine.set_speaker(s1, Some("发言人 1".to_string())));
        assert!(spine.set_speaker(s2, Some("发言人 1".to_string())));
        assert_eq!(spine.replace_speaker_name("发言人 1", "张工"), 2);
        assert!(spine.is_stale());
        assert_eq!(
            spine.format_cited_sources(),
            vec![
                "[S1] 张工: 基本工资调整为4200元。".to_string(),
                "[S2] 张工: 绩效发放比例为80%。".to_string(),
            ]
        );
    }

    #[test]
    fn spine_accept_final_and_cumulative_deduplicate_prefixes() {
        let mut spine = UtteranceSpine::new("live-session");
        let id1 = spine
            .accept_final(
                "s1",
                "utt-0",
                "第一句初稿",
                "zh",
                Some("Draft one"),
                Some("en"),
                "fun-asr",
            )
            .unwrap();
        let id1_again = spine
            .accept_final(
                "s1",
                "utt-0",
                "第一句定稿",
                "zh",
                Some("Final one"),
                Some("en"),
                "fun-asr",
            )
            .unwrap();
        assert_eq!(id1, id1_again);
        assert_eq!(spine.len(), 1);
        assert_eq!(spine.get(id1).unwrap().text, "第一句定稿");
        assert_eq!(spine.get(id1).unwrap().revision, 2);

        let c1 = spine
            .accept_cumulative("conn-a", "今天讨论预算", "zh", None, None, "qwen")
            .unwrap();
        assert_eq!(c1.ordinal(), 2);
        assert_eq!(spine.get(c1).unwrap().text, "今天讨论预算");

        let c2 = spine
            .accept_cumulative(
                "conn-a",
                "今天讨论预算 和排期安排",
                "zh",
                Some("and schedule"),
                Some("en"),
                "qwen",
            )
            .unwrap();
        assert_eq!(c2.ordinal(), 3);
        assert_eq!(spine.get(c2).unwrap().text, "和排期安排");
        assert_eq!(
            spine.get(c2).unwrap().translation.as_deref(),
            Some("and schedule")
        );
    }

    #[test]
    fn recording_aggregate_tracks_lifecycle_bookmarks_and_minutes() {
        let mut agg = RecordingAggregate::new("rec-20261108", 20261108, 1_762_590_000, 120_000);
        assert_eq!(agg.phase, RecordingLifecyclePhase::Copying);
        assert_eq!(agg.phase.as_str(), "copying");
        assert!(!agg.phase.is_terminal());
        assert!(!agg.phase.can_transcribe());

        agg.set_phase(RecordingLifecyclePhase::Local);
        assert!(agg.phase.can_transcribe());
        assert!(agg.add_bookmark(900));
        assert!(agg.add_bookmark(300));
        assert!(!agg.add_bookmark(300));
        assert_eq!(agg.bookmarks, vec![300, 900]);

        agg.update_coarse_place(Some("  北京市·海淀区  ".to_string()));
        assert_eq!(agg.coarse_place.as_deref(), Some("北京市·海淀区"));

        for fmt in SummaryFormat::ALL {
            assert_eq!(SummaryFormat::parse(fmt.as_str()), Some(fmt));
            assert_eq!(SummaryFormat::parse(fmt.label_zh()), Some(fmt));
        }

        let s1 = agg
            .spine
            .append_segment("拍板采用竹青色作为主色调。", 0, 3_000, "zh", "qwen")
            .unwrap();
        let s2 = agg
            .spine
            .append_segment("张工周五前完成实时流压测。", 3_000, 6_000, "zh", "qwen")
            .unwrap();
        let s3 = agg
            .spine
            .append_segment(
                "历史固件存在1A06丢包风险，是否升级待定。",
                6_000,
                9_500,
                "zh",
                "qwen",
            )
            .unwrap();

        let mins = MeetingMinutes {
            version: 2,
            spine_revision: agg.spine.revision(),
            title: "Slice Q 实时流收口评审".to_string(),
            overview: "确认 RecordingAggregate 与 1A/06->1A/07 闭环。".to_string(),
            topics: vec![MinuteTopic {
                title: "协议闭环".to_string(),
                summary: "补齐硬件直录自动拉流".to_string(),
                citations: vec![s1, s2],
                points: Vec::new(),
                fishbone: None,
            }],
            decisions: vec![MinutePoint {
                claim: "采用竹青色作为主色调".to_string(),
                speaker: None,
                owner: None,
                due: None,
                citations: vec![s1],
            }],
            actions: vec![MinutePoint {
                claim: "完成实时流压测".to_string(),
                speaker: None,
                owner: Some("张工".to_string()),
                due: Some("周五".to_string()),
                citations: vec![s2],
            }],
            questions: vec![MinutePoint {
                claim: "历史固件是否升级".to_string(),
                speaker: None,
                owner: None,
                due: None,
                citations: vec![s3],
            }],
            fishbones: vec![MinuteFishbone {
                issue: "1A06丢包风险".to_string(),
                causes: vec![MinuteCause {
                    category: "固件".to_string(),
                    description: "旧版未发5字节状态".to_string(),
                    citations: vec![s3],
                }],
            }],
            terms: vec![MinuteTerm {
                term: "1A06".to_string(),
                definition: "录音豆实时状态帧".to_string(),
                heard: vec!["1A06".to_string()],
                adoption: MinuteTermAdoption::Adopted,
                citations: vec![s3],
            }],
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        };

        agg.set_selected_format(SummaryFormat::RootCauseFishbone);
        assert_eq!(agg.selected_format, SummaryFormat::RootCauseFishbone);
        agg.attach_minutes(mins.clone());
        assert_eq!(agg.phase, RecordingLifecyclePhase::Ready);
        assert!(agg.phase.is_terminal());
        assert_eq!(agg.minutes, Some(mins.clone()));

        let empty = RecordingAggregate::from_spine_and_minutes(
            "rec-empty",
            0,
            1_762_590_000,
            0,
            UtteranceSpine::new("rec-empty"),
            None,
        );
        assert_eq!(empty.phase, RecordingLifecyclePhase::Local);

        let restored = RecordingAggregate::from_spine_and_minutes(
            "rec-restored",
            20261108,
            1_762_590_000,
            120_000,
            agg.spine.clone(),
            Some(mins.clone()),
        );
        assert_eq!(restored.phase, RecordingLifecyclePhase::Ready);
        assert_eq!(restored.minutes, Some(mins));
    }
}
