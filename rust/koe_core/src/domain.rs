//! Canonical utterance spine (`S1..Sn`), structured meeting minutes (`MeetingMinutesV2`),
//! personal context timeline items, and pure AI provider command descriptions.
//!
//! Every downstream subsystem (minutes grounding, Cicada rolling bilingual translation,
//! personal context extraction, and MCP/ACP tools) reads from [`UtteranceSpine`] via
//! 1-based [`SegmentId`] citations (`S1..Sn`) instead of mutating raw transcript strings.

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
    /// use koe_core::domain::SegmentId;
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
    /// use koe_core::domain::SegmentId;
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

    /// Updates the source text of segment `id`, increments both segment and spine revisions,
    /// clears any existing translation on that segment, and marks the spine stale.
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
        seg.text = clean;
        seg.revision = seg.revision.saturating_add(1);
        seg.translation = None;
        seg.target_language = None;
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

    /// Renames every occurrence of `old_speaker` to `new_speaker` across all segments,
    /// returning the number of segments updated.
    pub fn replace_speaker_name(&mut self, old_speaker: &str, new_speaker: &str) -> usize {
        let old_trimmed = old_speaker.trim();
        let new_trimmed = new_speaker.trim();
        if old_trimmed.is_empty() || new_trimmed.is_empty() || old_trimmed == new_trimmed {
            return 0;
        }
        let mut updated = 0usize;
        for seg in &mut self.segments {
            if seg.speaker.as_deref() == Some(old_trimmed) {
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
pub struct MeetingMinutesV2 {
    /// Schema version (`2`).
    pub version: u32,
    /// Spine revision at the moment these minutes were generated.
    pub spine_revision: u64,
    /// Concise meeting title.
    pub title: String,
    /// High-level summary paragraph.
    pub overview: String,
    /// Ordered discussion topics with `S1..Sn` cited points.
    pub topics: Vec<MinuteTopic>,
    /// Root-cause fishbone diagrams for issues raised in the meeting.
    pub fishbones: Vec<MinuteFishbone>,
    /// Domain terminology and jargon table extracted from the meeting.
    pub terms: Vec<MinuteTerm>,
    /// User-defined or template-driven custom sections.
    pub custom_sections: Vec<MinuteCustomSection>,
}

/// A thematic section in [`MeetingMinutesV2`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinuteTopic {
    /// Topic title.
    pub title: String,
    /// Summary of the topic discussion.
    pub summary: String,
    /// Bullet points backed by [`SegmentId`] citations.
    pub points: Vec<MinutePoint>,
}

/// A single factual claim or decision point backed by `S1..Sn` citations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinutePoint {
    /// Factual claim text.
    pub claim: String,
    /// Optional speaker who made the point.
    pub speaker: Option<String>,
    /// Non-empty list of [`SegmentId`] citations supporting `claim`.
    pub citations: Vec<SegmentId>,
}

/// Fishbone (Ishikawa) root-cause analysis entry in [`MeetingMinutesV2`].
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
    /// Current glossary adoption status.
    pub adoption: MinuteTermAdoption,
    /// Supporting [`SegmentId`] citations where the term was used.
    pub citations: Vec<SegmentId>,
}

/// A custom template section in [`MeetingMinutesV2`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MinuteCustomSection {
    /// Section heading.
    pub heading: String,
    /// Grounded points under this heading.
    pub points: Vec<MinutePoint>,
}

/// Category of a [`ContextItem`] on the user's personal timeline.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextKind {
    /// Imported or live audio recording.
    Recording,
    /// Quick text or voice memo.
    QuickNote,
    /// Spoken commitment or promise detected from conversation.
    Commitment,
    /// Daily journal synthesis.
    Journal,
    /// Geographic place visit attachment.
    PlaceVisit,
}

/// Originating source of a [`ContextItem`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContextSource {
    /// Soundcore Work D3200 recording bean.
    BeanHardware,
    /// Local phone/desktop microphone.
    DeviceMic,
    /// Direct user input.
    ManualEntry,
    /// AI synthesis from [`UtteranceSpine`].
    AiSynthesis,
}

/// A single item in the user's personal context timeline (`lib/state/context`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ContextItem {
    /// Stable unique identifier.
    pub id: String,
    /// Item category.
    pub kind: ContextKind,
    /// Originating capture source.
    pub source: ContextSource,
    /// UTC creation timestamp in Unix seconds.
    pub created_at_epoch_sec: u64,
    /// Primary title or headline.
    pub title: String,
    /// Body text or summary.
    pub summary: String,
    /// Optional project tag.
    pub project_id: Option<String>,
    /// Optional human-readable location label.
    pub place_label: Option<String>,
    /// Supporting [`SegmentId`] citations when derived from an [`UtteranceSpine`].
    pub citations: Vec<SegmentId>,
}

/// Ownership category of a [`TodoItem`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TodoKind {
    /// Action item owned by the user (`"我的待办"`).
    Mine,
    /// Action item delegated to or awaited from another person.
    Delegated,
}

/// Completion state of a [`TodoItem`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TodoStatus {
    /// Pending execution.
    Open,
    /// Completed.
    Done,
    /// Archived or cancelled.
    Archived,
}

/// A personal or meeting-derived action item linked to [`SegmentId`] citations.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TodoItem {
    /// Stable unique identifier.
    pub id: String,
    /// Action description.
    pub title: String,
    /// Whether the user owns the task or is waiting on someone else.
    pub kind: TodoKind,
    /// Current completion status.
    pub status: TodoStatus,
    /// UTC creation timestamp in Unix seconds.
    pub created_at_epoch_sec: u64,
    /// Optional due timestamp in Unix seconds.
    pub due_at_epoch_sec: Option<u64>,
    /// Optional assignee or counterparty name.
    pub assignee: Option<String>,
    /// Supporting [`SegmentId`] citations from the originating recording.
    pub citations: Vec<SegmentId>,
}

/// Pure value description of an outbound AI provider request emitted by a domain reducer.
///
/// The `#![forbid(unsafe_code)]` Rust kernel never performs network I/O directly; it emits
/// [`AiProviderCommand`] values that the host executes and feeds back as reducer events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AiProviderCommand {
    /// Submit an audio file or PCM stream for ASR transcription with optional hot-words.
    TranscribeAudio {
        /// Session or recording identifier.
        session_id: String,
        /// Language hint (such as `"zh"` or `"en"`).
        language_hint: String,
        /// Domain hot-words to boost recognition accuracy.
        hot_words: Vec<String>,
    },
    /// Generate or merge [`MeetingMinutesV2`] over a range of [`SegmentId`]s.
    GenerateMinutes {
        /// Session or recording identifier.
        session_id: String,
        /// Spine revision being summarized.
        spine_revision: u64,
        /// Inclusive segment range `(first, last)`.
        segment_range: (SegmentId, SegmentId),
        /// Optional custom template identifier.
        template_id: Option<String>,
    },
    /// Translate a batch of [`SegmentId`]s into `target_language`.
    TranslateSegments {
        /// Session or recording identifier.
        session_id: String,
        /// Target language code (such as `"en"` or `"zh"`).
        target_language: String,
        /// Segments requiring translation.
        segments: Vec<SegmentId>,
    },
    /// Extract [`ContextItem`]s and [`TodoItem`]s from finalized segments.
    ExtractContext {
        /// Session or recording identifier.
        session_id: String,
        /// Spine revision being analyzed.
        spine_revision: u64,
    },
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
        assert_eq!(" [s19] ".parse::<SegmentId>(), Ok(SegmentId::new(19).unwrap()));
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
        assert_eq!(spine.get(c2).unwrap().translation.as_deref(), Some("and schedule"));
    }
}
