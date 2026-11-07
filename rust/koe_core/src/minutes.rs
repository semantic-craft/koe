//! Structured meeting minutes grounding validator (`S1..Sn` evidence checks) and pure
//! reducer for `qwennote-minutes` ASR and chunked merge state.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use crate::domain::{
    AiProviderCommand, MeetingMinutesV2, MinutePoint, SegmentId, UtteranceSpine,
};

/// Validation failure returned when a [`MeetingMinutesV2`] claim violates `S1..Sn` grounding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MinutesValidationError {
    /// A claim referenced an empty citation list or a [`SegmentId`] outside `spine`.
    InvalidCitation {
        /// The ungrounded claim text.
        claim: String,
        /// The missing or invalid citation, if any.
        invalid_id: Option<SegmentId>,
    },
    /// A claim synthesized a wage/salary + percentage calculation across multiple segments
    /// instead of citing a single source sentence that already states both figures.
    UngroundedWageCalculation {
        /// The rejected calculation claim text.
        claim: String,
    },
}

/// Returns `true` if `text` contains a percentage figure (such as `"80%"`, `"80％"`, or `"百分之"`).
#[must_use]
pub fn contains_percentage(text: &str) -> bool {
    let bytes = text.as_bytes();
    for (idx, ch) in text.char_indices() {
        if (ch == '%' || ch == '％') && idx > 0 && bytes[idx - 1].is_ascii_digit() {
            return true;
        }
    }
    text.contains("百分之")
}

/// Returns `true` if `text` contains a wage/salary calculation phrase (such as `"工资"`, `"薪资"`,
/// `"底薪"`, `"乘以"`, or `"*"`).
#[must_use]
pub fn contains_calculation_phrase(text: &str) -> bool {
    const KEYWORDS: [&str; 9] = [
        "工资",
        "薪资",
        "底薪",
        "月薪",
        "基本工资",
        "乘以",
        "实发",
        "×",
        "*",
    ];
    KEYWORDS.iter().any(|kw| text.contains(kw))
}

/// Validates that a single `claim` and its `citations` are grounded in `spine`.
///
/// Specifically, if `claim` combines a wage/calculation phrase with a percentage figure,
/// at least one cited source segment in `spine` must contain **both** a calculation/wage
/// phrase and a percentage figure in that same single utterance (`S{k}`). Cross-sentence
/// arithmetic synthesis is rejected.
///
/// # Examples
///
/// ```
/// use koe_core::domain::{SegmentId, UtteranceSpine};
/// use koe_core::minutes::validate_calculation_grounding;
///
/// let mut spine = UtteranceSpine::new("s1");
/// let s1 = spine.append_segment("基本工资是3910元。", 0, 1000, "zh", "qwen").unwrap();
/// let s2 = spine.append_segment("考核比例按80%计算。", 1000, 2000, "zh", "qwen").unwrap();
///
/// assert!(validate_calculation_grounding(
///     "基本工资3910元乘以80%发放",
///     &[s1, s2],
///     &spine
/// ).is_err());
/// ```
pub fn validate_calculation_grounding(
    claim: &str,
    citations: &[SegmentId],
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    if citations.is_empty() {
        return Err(MinutesValidationError::InvalidCitation {
            claim: claim.to_string(),
            invalid_id: None,
        });
    }
    for &id in citations {
        if !spine.validate_citation(id) {
            return Err(MinutesValidationError::InvalidCitation {
                claim: claim.to_string(),
                invalid_id: Some(id),
            });
        }
    }

    if contains_percentage(claim) && contains_calculation_phrase(claim) {
        let single_segment_grounds_both = citations.iter().any(|&id| {
            spine.get(id).is_some_and(|seg| {
                contains_percentage(&seg.text) && contains_calculation_phrase(&seg.text)
            })
        });
        if !single_segment_grounds_both {
            return Err(MinutesValidationError::UngroundedWageCalculation {
                claim: claim.to_string(),
            });
        }
    }
    Ok(())
}

/// Validates every topic point, fishbone cause, term, and custom section point in `minutes`
/// against `spine`.
pub fn validate_minutes_grounding(
    minutes: &MeetingMinutesV2,
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    for topic in &minutes.topics {
        for point in &topic.points {
            validate_point(point, spine)?;
        }
    }
    for fb in &minutes.fishbones {
        for cause in &fb.causes {
            validate_calculation_grounding(&cause.description, &cause.citations, spine)?;
        }
    }
    for term in &minutes.terms {
        validate_calculation_grounding(&term.definition, &term.citations, spine)?;
    }
    for section in &minutes.custom_sections {
        for point in &section.points {
            validate_point(point, spine)?;
        }
    }
    Ok(())
}

fn validate_point(
    point: &MinutePoint,
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    validate_calculation_grounding(&point.claim, &point.citations, spine)
}

/// Pure state for the structured meeting minutes domain module.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MinutesState {
    /// Latest validated meeting minutes document, if any.
    pub latest_minutes: Option<MeetingMinutesV2>,
    /// User-configured hot-words (`qwennote-minutes`).
    pub hot_words: Vec<String>,
    /// Active template identifier, if any.
    pub active_template_id: Option<String>,
    /// Last grounding validation error encountered.
    pub last_error: Option<MinutesValidationError>,
}

/// Input events for [`MinutesReducer`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MinutesEvent {
    /// Request minutes generation over the current [`UtteranceSpine`].
    RequestGenerate {
        /// Optional template override.
        template_id: Option<String>,
    },
    /// Candidate [`MeetingMinutesV2`] returned by the AI provider.
    CandidateReceived(MeetingMinutesV2),
    /// Add a personal hot-word (`qwennote-minutes`).
    AddHotWord(String),
}

/// Pure output from [`MinutesReducer::reduce`].
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MinutesOutcome {
    /// Outbound AI provider commands to execute.
    pub commands: Vec<AiProviderCommand>,
    /// Validation error if a candidate document failed grounding checks.
    pub validation_error: Option<MinutesValidationError>,
}

/// Pure reducer contract for the meeting minutes subsystem.
pub trait MinutesReducer {
    /// Applies `event` to `state` against `spine` without side effects.
    fn reduce(
        state: &mut MinutesState,
        spine: &UtteranceSpine,
        event: MinutesEvent,
    ) -> MinutesOutcome;
}

impl MinutesReducer for MinutesState {
    fn reduce(
        state: &mut MinutesState,
        spine: &UtteranceSpine,
        event: MinutesEvent,
    ) -> MinutesOutcome {
        match event {
            MinutesEvent::RequestGenerate { template_id } => {
                if let Some(tid) = &template_id {
                    state.active_template_id = Some(tid.clone());
                }
                let Some(first) = spine.segments().first().map(|s| s.id) else {
                    return MinutesOutcome::default();
                };
                let Some(last) = spine.segments().last().map(|s| s.id) else {
                    return MinutesOutcome::default();
                };
                MinutesOutcome {
                    commands: vec![AiProviderCommand::GenerateMinutes {
                        session_id: spine.session_id().to_string(),
                        spine_revision: spine.revision(),
                        segment_range: (first, last),
                        template_id: template_id.or_else(|| state.active_template_id.clone()),
                    }],
                    validation_error: None,
                }
            }
            MinutesEvent::CandidateReceived(candidate) => {
                match validate_minutes_grounding(&candidate, spine) {
                    Ok(()) => {
                        state.latest_minutes = Some(candidate);
                        state.last_error = None;
                        MinutesOutcome::default()
                    }
                    Err(err) => {
                        state.last_error = Some(err.clone());
                        MinutesOutcome {
                            commands: Vec::new(),
                            validation_error: Some(err),
                        }
                    }
                }
            }
            MinutesEvent::AddHotWord(word) => {
                let clean = word.trim().to_string();
                if !clean.is_empty() && !state.hot_words.contains(&clean) {
                    state.hot_words.push(clean);
                }
                MinutesOutcome::default()
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::domain::MinuteTopic;

    #[test]
    fn rejects_cross_segment_wage_and_percentage_stitching_but_accepts_single_segment() {
        let mut spine = UtteranceSpine::new("rec-wage");
        let s1 = spine
            .append_segment("合同约定基本工资为3910元。", 0, 1_500, "zh", "qwen")
            .unwrap();
        let s2 = spine
            .append_segment("本月出勤率是80%。", 1_500, 3_000, "zh", "qwen")
            .unwrap();
        let s3 = spine
            .append_segment(
                "所以实发工资按3910元乘以80%折算。",
                3_000,
                4_500,
                "zh",
                "qwen",
            )
            .unwrap();

        let stitched = validate_calculation_grounding(
            "员工实发工资按3910元乘以80%计算",
            &[s1, s2],
            &spine,
        );
        assert_eq!(
            stitched,
            Err(MinutesValidationError::UngroundedWageCalculation {
                claim: "员工实发工资按3910元乘以80%计算".to_string(),
            })
        );

        let grounded = validate_calculation_grounding(
            "员工实发工资按3910元乘以80%计算",
            &[s3],
            &spine,
        );
        assert_eq!(grounded, Ok(()));
    }

    #[test]
    fn minutes_reducer_validates_candidate_and_records_errors() {
        let mut spine = UtteranceSpine::new("rec-200");
        let s1 = spine
            .append_segment("确定下周三发布版本。", 0, 2_000, "zh", "qwen")
            .unwrap();
        let mut state = MinutesState::default();

        let out_req = MinutesState::reduce(
            &mut state,
            &spine,
            MinutesEvent::RequestGenerate {
                template_id: Some("tpl-weekly".to_string()),
            },
        );
        assert_eq!(out_req.commands.len(), 1);

        let bad_doc = MeetingMinutesV2 {
            version: 2,
            spine_revision: spine.revision(),
            title: "周会".to_string(),
            overview: "发布计划".to_string(),
            topics: vec![MinuteTopic {
                title: "排期".to_string(),
                summary: "下周发布".to_string(),
                points: vec![MinutePoint {
                    claim: "下周三上线".to_string(),
                    speaker: None,
                    citations: vec![SegmentId::new(99).unwrap()],
                }],
            }],
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
        };
        let out_bad = MinutesState::reduce(
            &mut state,
            &spine,
            MinutesEvent::CandidateReceived(bad_doc),
        );
        assert!(out_bad.validation_error.is_some());
        assert!(state.latest_minutes.is_none());

        let good_doc = MeetingMinutesV2 {
            version: 2,
            spine_revision: spine.revision(),
            title: "周会".to_string(),
            overview: "发布计划".to_string(),
            topics: vec![MinuteTopic {
                title: "排期".to_string(),
                summary: "下周发布".to_string(),
                points: vec![MinutePoint {
                    claim: "确定下周三发布版本".to_string(),
                    speaker: None,
                    citations: vec![s1],
                }],
            }],
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
        };
        let out_good = MinutesState::reduce(
            &mut state,
            &spine,
            MinutesEvent::CandidateReceived(good_doc.clone()),
        );
        assert!(out_good.validation_error.is_none());
        assert_eq!(state.latest_minutes, Some(good_doc));
    }
}
