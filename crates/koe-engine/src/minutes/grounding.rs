use crate::domain::{MeetingMinutes, MinutePoint, SegmentId, UtteranceSpine};

#[cfg(test)]
std::thread_local! {
    static MINUTES_VALIDATION_PASSES: std::cell::Cell<usize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
pub(crate) fn reset_validation_pass_count() {
    MINUTES_VALIDATION_PASSES.with(|c| c.set(0));
}

#[cfg(test)]
pub(crate) fn validation_pass_count() -> usize {
    MINUTES_VALIDATION_PASSES.with(std::cell::Cell::get)
}

#[cfg(test)]
fn record_validation_pass() {
    MINUTES_VALIDATION_PASSES.with(|c| c.set(c.get() + 1));
}

/// Validation failure returned when a [`MeetingMinutes`] document or claim violates `S1..Sn` grounding.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MinutesValidationError {
    /// Raw output was not valid JSON or missed required schema fields.
    InvalidJson(String),
    /// `schemaVersion` was neither `1` nor `2`.
    UnsupportedSchemaVersion(i64),
    /// A claim referenced an empty citation list or a [`SegmentId`] outside `spine`.
    InvalidCitation {
        /// The ungrounded claim text.
        claim: String,
        /// The missing or invalid citation, if any.
        invalid_id: Option<SegmentId>,
    },
    /// A chunk/merge node cited a [`SegmentId`] outside its permitted `allowed_sources` subset.
    NodeCitedDisallowedSource {
        /// The chunk or merge node identifier.
        node_id: String,
        /// The disallowed citation.
        disallowed_id: SegmentId,
    },
    /// A `terms[].heard` variant did not appear verbatim in any cited `S{k}` segment.
    UngroundedHeardVariant {
        /// Canonical term name.
        term: String,
        /// Misheard spelling that was not found in the cited source segments.
        heard: String,
    },
    /// A claim synthesized a wage/salary + percentage calculation across multiple segments
    /// instead of citing a single source sentence that already states both figures.
    UngroundedWageCalculation {
        /// The rejected calculation claim text.
        claim: String,
    },
    /// A claim synthesized a calculation ratio (`基数`, `按...计算`, `基于...计算`, `按...比例...缴纳/计算`)
    /// with a percentage without a single cited sentence containing both `工资`/`基数` and a percentage.
    BaselessRatioCalculation {
        /// The rejected calculation ratio claim text.
        claim: String,
    },
    /// A concrete percentage figure in `claim` (such as `80%` or `百分之80`) did not appear
    /// in any of its cited `S{k}` source segments.
    UncitedPercentageNumber {
        /// The claim containing the fabricated percentage.
        claim: String,
        /// The ungrounded percentage token.
        percentage: String,
    },
}

fn contains_percentage(text: &str) -> bool {
    !extract_percentage_tokens(text).is_empty() || text.contains("百分之")
}

fn extract_percentage_tokens(text: &str) -> Vec<String> {
    let mut tokens = Vec::new();
    let chars: Vec<char> = text.chars().collect();
    let n = chars.len();
    let mut i = 0usize;

    while i < n {
        if chars[i].is_ascii_digit() {
            let start = i;
            while i < n && chars[i].is_ascii_digit() {
                i += 1;
            }
            if i + 1 < n && chars[i] == '.' && chars[i + 1].is_ascii_digit() {
                i += 1;
                while i < n && chars[i].is_ascii_digit() {
                    i += 1;
                }
            }
            let num_end = i;
            let mut ws = i;
            while ws < n && (chars[ws] == ' ' || chars[ws] == '\t') {
                ws += 1;
            }
            if ws < n && (chars[ws] == '%' || chars[ws] == '％') {
                let num_str: String = chars[start..num_end].iter().collect();
                tokens.push(format!("{num_str}%"));
                i = ws + 1;
                continue;
            }
            continue;
        }

        if i + 3 <= n && chars[i] == '百' && chars[i + 1] == '分' && chars[i + 2] == '之' {
            let start = i;
            i += 3;
            let num_start = i;
            while i < n
                && (chars[i].is_ascii_digit()
                    || matches!(
                        chars[i],
                        '.' | '点'
                            | '零'
                            | '一'
                            | '二'
                            | '两'
                            | '三'
                            | '四'
                            | '五'
                            | '六'
                            | '七'
                            | '八'
                            | '九'
                            | '十'
                            | '百'
                    ))
            {
                i += 1;
            }
            if i > num_start {
                let tok: String = chars[start..i].iter().collect();
                tokens.push(tok);
                continue;
            }
        }
        i += 1;
    }
    tokens
}

fn normalize_percentage_value(token: &str) -> String {
    if let Some(rest) = token.strip_prefix("百分之") {
        let converted = chinese_num_to_ascii(rest);
        format!("{converted}%")
    } else {
        token
            .trim()
            .trim_end_matches(['%', '％'])
            .trim()
            .to_string()
            + "%"
    }
}

fn chinese_num_to_ascii(s: &str) -> String {
    if s.chars().all(|c| c.is_ascii_digit() || c == '.') {
        return s.to_string();
    }
    match s {
        "十" => "10".to_string(),
        "二十" => "20".to_string(),
        "三十" => "30".to_string(),
        "四十" => "40".to_string(),
        "五十" => "50".to_string(),
        "六十" => "60".to_string(),
        "七十" => "70".to_string(),
        "八十" => "80".to_string(),
        "九十" => "90".to_string(),
        "一百" => "100".to_string(),
        _ => s.replace('点', "."),
    }
}

fn contains_wage_keyword(text: &str) -> bool {
    const WAGE_KEYWORDS: [&str; 6] = ["工资", "薪资", "底薪", "月薪", "基本工资", "实发"];
    WAGE_KEYWORDS.iter().any(|kw| text.contains(kw))
}

fn contains_ratio_calculation_pattern(text: &str) -> bool {
    if text.contains("基数") {
        return true;
    }
    for clause in text.split(['。', '；', '\n']) {
        let chars: Vec<char> = clause.chars().collect();
        let n = chars.len();
        for i in 0..n {
            if i + 1 < n && chars[i] == '基' && chars[i + 1] == '于' {
                let rest: String = chars[i + 2..(i + 2 + 26).min(n)].iter().collect();
                if let Some(pos) = rest.find("计算") {
                    if rest[..pos].chars().count() <= 24 {
                        return true;
                    }
                }
            }
            if chars[i] == '按' {
                let window: String = chars[i + 1..(i + 1 + 48).min(n)].iter().collect();
                if let Some(pos) = window.find("计算") {
                    if window[..pos].chars().count() <= 24 {
                        return true;
                    }
                }
                if let Some(p_pos) = window.find("比例") {
                    if window[..p_pos].chars().count() <= 24 {
                        let after_ratio = &window[p_pos + "比例".len()..];
                        for target in ["缴纳", "计算"] {
                            if let Some(t_pos) = after_ratio.find(target) {
                                if after_ratio[..t_pos].chars().count() <= 16 {
                                    return true;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    false
}

fn validate_claim_grounding_inner(
    claim: &str,
    citations: &[SegmentId],
    spine: &UtteranceSpine,
    check_uncited_percentage_number: bool,
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

    if !contains_percentage(claim) {
        return Ok(());
    }

    let wage_in_same_clause = claim
        .split(['。', '；', '！', '？', '\n'])
        .any(|clause| contains_percentage(clause) && contains_wage_keyword(clause));
    let wage_with_mult = contains_wage_keyword(claim)
        && (claim.contains("乘以") || claim.contains('×') || claim.contains('*'));
    let has_ratio_calc = contains_ratio_calculation_pattern(claim);

    let single_segment_grounds_wage_and_pct = citations.iter().any(|&id| {
        spine.get(id).is_some_and(|seg| {
            contains_percentage(&seg.text)
                && (contains_wage_keyword(&seg.text) || seg.text.contains("基数"))
        })
    });

    if (wage_in_same_clause || wage_with_mult) && !single_segment_grounds_wage_and_pct {
        return Err(MinutesValidationError::UngroundedWageCalculation {
            claim: claim.to_string(),
        });
    }

    if has_ratio_calc && !single_segment_grounds_wage_and_pct {
        return Err(MinutesValidationError::BaselessRatioCalculation {
            claim: claim.to_string(),
        });
    }

    if check_uncited_percentage_number {
        let claim_pcts = extract_percentage_tokens(claim);
        for pct in claim_pcts {
            let norm = normalize_percentage_value(&pct);
            let found_in_cited = citations.iter().any(|&id| {
                spine.get(id).is_some_and(|seg| {
                    if seg.text.contains(&pct) {
                        return true;
                    }
                    extract_percentage_tokens(&seg.text)
                        .iter()
                        .any(|s_pct| normalize_percentage_value(s_pct) == norm)
                })
            });
            if !found_in_cited {
                return Err(MinutesValidationError::UncitedPercentageNumber {
                    claim: claim.to_string(),
                    percentage: pct,
                });
            }
        }
    }

    Ok(())
}

/// Validates every overview, topic, point, decision, action, question, fishbone cause, term
/// (including `heard` variants), and custom section in `minutes` against `spine`.
pub fn validate_minutes_grounding(
    minutes: &MeetingMinutes,
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    #[cfg(test)]
    record_validation_pass();
    if !spine.is_empty() && !minutes.overview.trim().is_empty() {
        let all_ids: Vec<SegmentId> = spine.segments().iter().map(|s| s.id).collect();
        validate_claim_grounding_inner(&minutes.overview, &all_ids, spine, false)?;
    }

    for topic in &minutes.topics {
        if !topic.citations.is_empty() {
            validate_claim_grounding_inner(&topic.title, &topic.citations, spine, true)?;
            if !topic.summary.trim().is_empty() {
                validate_claim_grounding_inner(&topic.summary, &topic.citations, spine, true)?;
            }
        }
        for point in &topic.points {
            validate_point(point, spine)?;
        }
        if let Some(fb) = &topic.fishbone {
            for cause in &fb.causes {
                let combined = format!("{} {}", cause.category, cause.description);
                validate_claim_grounding_inner(&combined, &cause.citations, spine, true)?;
            }
        }
    }

    for d in &minutes.decisions {
        validate_point(d, spine)?;
    }
    for a in &minutes.actions {
        validate_point(a, spine)?;
    }
    for q in &minutes.questions {
        validate_point(q, spine)?;
    }
    for fb in &minutes.fishbones {
        for cause in &fb.causes {
            let combined = format!("{} {}", cause.category, cause.description);
            validate_claim_grounding_inner(&combined, &cause.citations, spine, true)?;
        }
    }
    for term in &minutes.terms {
        for spelling in &term.heard {
            let trimmed = spelling.trim();
            if trimmed.is_empty() {
                return Err(MinutesValidationError::UngroundedHeardVariant {
                    term: term.term.clone(),
                    heard: spelling.clone(),
                });
            }
            let grounded = term
                .citations
                .iter()
                .any(|&id| spine.get(id).is_some_and(|seg| seg.text.contains(trimmed)));
            if !grounded {
                return Err(MinutesValidationError::UngroundedHeardVariant {
                    term: term.term.clone(),
                    heard: trimmed.to_string(),
                });
            }
        }
        let combined = format!("{} {}", term.term, term.definition);
        validate_claim_grounding_inner(&combined, &term.citations, spine, true)?;
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
    validate_claim_grounding_inner(&point.claim, &point.citations, spine, true)
}

fn validate_citation_slice(
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
    Ok(())
}

/// Validates non-empty citation lists and live `S1..Sn` existence across all sections of `minutes`.
pub fn validate_minutes_citations(
    minutes: &MeetingMinutes,
    spine: &UtteranceSpine,
) -> Result<(), MinutesValidationError> {
    #[cfg(test)]
    record_validation_pass();
    for topic in &minutes.topics {
        if !topic.citations.is_empty() {
            validate_citation_slice(&topic.title, &topic.citations, spine)?;
        }
        for point in &topic.points {
            validate_citation_slice(&point.claim, &point.citations, spine)?;
        }
        if let Some(fb) = &topic.fishbone {
            for cause in &fb.causes {
                let combined = format!("{} {}", cause.category, cause.description);
                validate_citation_slice(&combined, &cause.citations, spine)?;
            }
        }
    }
    for d in &minutes.decisions {
        validate_citation_slice(&d.claim, &d.citations, spine)?;
    }
    for a in &minutes.actions {
        validate_citation_slice(&a.claim, &a.citations, spine)?;
    }
    for q in &minutes.questions {
        validate_citation_slice(&q.claim, &q.citations, spine)?;
    }
    for fb in &minutes.fishbones {
        for cause in &fb.causes {
            let combined = format!("{} {}", cause.category, cause.description);
            validate_citation_slice(&combined, &cause.citations, spine)?;
        }
    }
    for term in &minutes.terms {
        for spelling in &term.heard {
            let trimmed = spelling.trim();
            if trimmed.is_empty() || trimmed.chars().count() > 20_000 {
                return Err(MinutesValidationError::InvalidJson(
                    "empty or oversized term.heard item".to_string(),
                ));
            }
        }
        let combined = format!("{} {}", term.term, term.definition);
        validate_citation_slice(&combined, &term.citations, spine)?;
    }
    for section in &minutes.custom_sections {
        for point in &section.points {
            validate_citation_slice(&point.claim, &point.citations, spine)?;
        }
    }
    Ok(())
}
