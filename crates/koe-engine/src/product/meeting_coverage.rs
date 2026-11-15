use std::collections::BTreeSet;

use super::{AnalysisStage, AnalysisState, ProductRecord};

/// Lifecycle stage of post-session full meeting minutes consolidation.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub enum ConsolidationStage {
    /// Capture is still active or post-session consolidation has not started.
    #[default]
    NotStarted,
    /// Full post-session minutes consolidation is currently in flight.
    InProgress,
    /// Grounded full minutes match the current transcript revision.
    Ready,
    /// Transcript text or speaker labels changed after minutes were generated.
    Stale,
    /// Post-session consolidation failed or was interrupted.
    Failed,
}

impl ConsolidationStage {
    /// Stable snake_case identifier for host snapshots.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::NotStarted => "not_started",
            Self::InProgress => "in_progress",
            Self::Ready => "ready",
            Self::Stale => "stale",
            Self::Failed => "failed",
        }
    }

    /// User-facing Chinese status label for the meeting coverage bar.
    #[must_use]
    pub const fn label_zh(self) -> &'static str {
        match self {
            Self::NotStarted => "录音结束后整理",
            Self::InProgress => "正在整理完整纪要",
            Self::Ready => "完整纪要已核对",
            Self::Stale => "原文已修改待重算",
            Self::Failed => "整理未完成",
        }
    }
}

/// Processing and citation coverage summary for a meeting session.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MeetingCoverage {
    /// Effective audio duration in milliseconds (`record.duration_ms.max(live_duration_ms)`).
    pub audio_duration_ms: u64,
    /// Audio duration covered by finalized transcript segments in milliseconds.
    pub transcribed_duration_ms: u64,
    /// Percentage (`0..=100`) of audio covered by finalized transcript segments.
    pub transcript_percent: u8,
    /// Total finalized segments in the recording's `UtteranceSpine`.
    pub total_segments: usize,
    /// Distinct spine segments cited by structured minutes topics or decisions.
    pub grounded_segments: usize,
    /// Percentage (`0..=100`) of finalized segments cited by structured minutes.
    pub minutes_percent: u8,
    /// Post-session full-minutes consolidation status.
    pub consolidation: ConsolidationStage,
}

/// Computes transcript, minutes grounding, and consolidation coverage for `record`.
#[must_use]
pub fn compute_meeting_coverage(
    record: &ProductRecord,
    live_duration_ms: u64,
    capture_active: bool,
) -> MeetingCoverage {
    let spine = &record.aggregate.spine;
    let segments = spine.segments();
    let total_segments = segments.len();
    let audio_duration_ms = record.aggregate.duration_ms.max(live_duration_ms);
    let max_end_ms = segments.iter().map(|s| s.end_ms).max().unwrap_or(0);

    let (transcribed_duration_ms, transcript_percent) = if audio_duration_ms > 0 {
        if !segments.is_empty() && max_end_ms == 0 {
            (audio_duration_ms, 100)
        } else {
            let covered = max_end_ms.min(audio_duration_ms);
            let pct = ((covered.saturating_mul(100)) / audio_duration_ms).min(100) as u8;
            (covered, pct)
        }
    } else if segments.is_empty() {
        (0, 0)
    } else {
        (0, 100)
    };

    let grounded_segments = if let Some(minutes) = &record.aggregate.minutes {
        let mut cited = BTreeSet::new();
        for topic in &minutes.topics {
            for &id in &topic.citations {
                if spine.validate_citation(id) {
                    cited.insert(id);
                }
            }
            for point in &topic.points {
                for &id in &point.citations {
                    if spine.validate_citation(id) {
                        cited.insert(id);
                    }
                }
            }
        }
        for decision in &minutes.decisions {
            for &id in &decision.citations {
                if spine.validate_citation(id) {
                    cited.insert(id);
                }
            }
        }
        cited.len().min(total_segments)
    } else {
        0
    };

    let minutes_percent = grounded_segments
        .saturating_mul(100)
        .checked_div(total_segments)
        .unwrap_or(0)
        .min(100) as u8;

    let consolidation = if capture_active {
        ConsolidationStage::NotStarted
    } else {
        match &record.analysis {
            AnalysisState::Pending {
                stage: AnalysisStage::Summarizing,
                ..
            } => ConsolidationStage::InProgress,
            AnalysisState::Pending {
                stage: AnalysisStage::Transcribing,
                ..
            } => ConsolidationStage::NotStarted,
            AnalysisState::Failed { .. } | AnalysisState::Interrupted { .. } => {
                ConsolidationStage::Failed
            }
            AnalysisState::Idle | AnalysisState::Ready { .. } => {
                if record.is_minutes_stale() {
                    ConsolidationStage::Stale
                } else if record.aggregate.minutes.is_some() {
                    ConsolidationStage::Ready
                } else {
                    ConsolidationStage::NotStarted
                }
            }
        }
    };

    MeetingCoverage {
        audio_duration_ms,
        transcribed_duration_ms,
        transcript_percent,
        total_segments,
        grounded_segments,
        minutes_percent,
        consolidation,
    }
}
