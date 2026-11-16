//! Structured meeting minutes grounding validator (`S1..Sn` evidence checks)
//! and prompt/JSON codec.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::collections::{BTreeMap, BTreeSet};

use crate::domain::{
    MeetingMinutes, MinuteCause, MinuteCustomSection, MinuteFishbone, MinutePoint, MinuteTerm,
    MinuteTermAdoption, MinuteTopic, SegmentId, UtteranceSpine,
};

/// Zero-dependency JSON DOM value with canonical `BTreeMap` key ordering.
#[derive(Debug, Clone, PartialEq)]
pub enum JsonValue {
    /// JSON `null`.
    Null,
    /// JSON boolean (`true` or `false`).
    Bool(bool),
    /// JSON IEEE-754 floating-point number.
    Number(f64),
    /// JSON UTF-8 string.
    String(String),
    /// JSON array.
    Array(Vec<JsonValue>),
    /// JSON object with deterministic lexicographical key order.
    Object(BTreeMap<String, JsonValue>),
}

impl JsonValue {
    /// Parses a JSON string into a [`JsonValue`].
    pub fn parse(raw: &str) -> Result<Self, String> {
        let mut parser = JsonParser::new(raw);
        let value = parser.parse_value()?;
        parser.skip_ws();
        if !parser.is_eof() {
            return Err(format!("trailing characters at byte {}", parser.pos));
        }
        Ok(value)
    }

    /// Serializes this [`JsonValue`] into a compact deterministic JSON string.
    #[must_use]
    pub fn to_json_string(&self) -> String {
        let mut out = String::new();
        self.write_json(&mut out);
        out
    }

    /// Returns `Some(&str)` if this value is a [`JsonValue::String`].
    #[must_use]
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Self::String(s) => Some(s.as_str()),
            _ => None,
        }
    }

    /// Returns `Some(bool)` if this value is a [`JsonValue::Bool`].
    #[must_use]
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Self::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// Returns `Some(f64)` if this value is a [`JsonValue::Number`].
    #[must_use]
    pub fn as_f64(&self) -> Option<f64> {
        match self {
            Self::Number(n) => Some(*n),
            _ => None,
        }
    }

    /// Returns `Some(i64)` if this value is an integral [`JsonValue::Number`].
    #[must_use]
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Self::Number(n) if n.is_finite() && (*n - n.trunc()).abs() < f64::EPSILON => {
                Some(*n as i64)
            }
            _ => None,
        }
    }

    /// Returns `Some(&[JsonValue])` if this value is a [`JsonValue::Array`].
    #[must_use]
    pub fn as_array(&self) -> Option<&[JsonValue]> {
        match self {
            Self::Array(items) => Some(items.as_slice()),
            _ => None,
        }
    }

    /// Returns `Some(&BTreeMap<String, JsonValue>)` if this value is a [`JsonValue::Object`].
    #[must_use]
    pub fn as_object(&self) -> Option<&BTreeMap<String, JsonValue>> {
        match self {
            Self::Object(map) => Some(map),
            _ => None,
        }
    }

    fn write_json(&self, out: &mut String) {
        match self {
            Self::Null => out.push_str("null"),
            Self::Bool(true) => out.push_str("true"),
            Self::Bool(false) => out.push_str("false"),
            Self::Number(n) => {
                if !n.is_finite() {
                    out.push_str("null");
                } else if (*n - n.trunc()).abs() < f64::EPSILON
                    && *n >= (i64::MIN as f64)
                    && *n <= (i64::MAX as f64)
                {
                    out.push_str(&(*n as i64).to_string());
                } else {
                    out.push_str(&n.to_string());
                }
            }
            Self::String(s) => write_escaped_json_string(s, out),
            Self::Array(items) => {
                out.push('[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    item.write_json(out);
                }
                out.push(']');
            }
            Self::Object(map) => {
                out.push('{');
                for (i, (k, v)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(',');
                    }
                    write_escaped_json_string(k, out);
                    out.push(':');
                    v.write_json(out);
                }
                out.push('}');
            }
        }
    }
}

fn write_escaped_json_string(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{08}' => out.push_str("\\b"),
            '\u{0C}' => out.push_str("\\f"),
            c if (c as u32) < 0x20 => {
                let code = c as u32;
                out.push_str(&format!("\\u{code:04x}"));
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

struct JsonParser<'a> {
    src: &'a str,
    bytes: &'a [u8],
    pos: usize,
}

impl<'a> JsonParser<'a> {
    fn new(src: &'a str) -> Self {
        Self {
            src,
            bytes: src.as_bytes(),
            pos: 0,
        }
    }

    fn is_eof(&self) -> bool {
        self.pos >= self.bytes.len()
    }

    fn skip_ws(&mut self) {
        while self.pos < self.bytes.len() {
            match self.bytes[self.pos] {
                b' ' | b'\t' | b'\r' | b'\n' => self.pos += 1,
                _ => break,
            }
        }
    }

    fn peek(&self) -> Option<u8> {
        self.bytes.get(self.pos).copied()
    }

    fn parse_value(&mut self) -> Result<JsonValue, String> {
        self.skip_ws();
        let Some(b) = self.peek() else {
            return Err("unexpected end of JSON".to_string());
        };
        match b {
            b'{' => self.parse_object(),
            b'[' => self.parse_array(),
            b'"' => self.parse_string().map(JsonValue::String),
            b't' => {
                if self.src[self.pos..].starts_with("true") {
                    self.pos += 4;
                    Ok(JsonValue::Bool(true))
                } else {
                    Err(format!("invalid literal at {}", self.pos))
                }
            }
            b'f' => {
                if self.src[self.pos..].starts_with("false") {
                    self.pos += 5;
                    Ok(JsonValue::Bool(false))
                } else {
                    Err(format!("invalid literal at {}", self.pos))
                }
            }
            b'n' => {
                if self.src[self.pos..].starts_with("null") {
                    self.pos += 4;
                    Ok(JsonValue::Null)
                } else {
                    Err(format!("invalid literal at {}", self.pos))
                }
            }
            b'-' | b'0'..=b'9' => self.parse_number(),
            other => Err(format!(
                "unexpected byte '{}' at {}",
                other as char, self.pos
            )),
        }
    }

    fn parse_object(&mut self) -> Result<JsonValue, String> {
        self.pos += 1;
        self.skip_ws();
        let mut map = BTreeMap::new();
        if self.peek() == Some(b'}') {
            self.pos += 1;
            return Ok(JsonValue::Object(map));
        }
        loop {
            self.skip_ws();
            if self.peek() != Some(b'"') {
                return Err(format!("expected string key at {}", self.pos));
            }
            let key = self.parse_string()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Err(format!("expected ':' at {}", self.pos));
            }
            self.pos += 1;
            let val = self.parse_value()?;
            map.insert(key, val);
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b'}') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(format!("expected ',' or '}}' at {}", self.pos)),
            }
        }
        Ok(JsonValue::Object(map))
    }

    fn parse_array(&mut self) -> Result<JsonValue, String> {
        self.pos += 1;
        self.skip_ws();
        let mut items = Vec::new();
        if self.peek() == Some(b']') {
            self.pos += 1;
            return Ok(JsonValue::Array(items));
        }
        loop {
            let val = self.parse_value()?;
            items.push(val);
            self.skip_ws();
            match self.peek() {
                Some(b',') => {
                    self.pos += 1;
                }
                Some(b']') => {
                    self.pos += 1;
                    break;
                }
                _ => return Err(format!("expected ',' or ']' at {}", self.pos)),
            }
        }
        Ok(JsonValue::Array(items))
    }

    fn parse_string(&mut self) -> Result<String, String> {
        if self.peek() != Some(b'"') {
            return Err(format!("expected '\"' at {}", self.pos));
        }
        self.pos += 1;
        let mut out = String::new();
        while self.pos < self.bytes.len() {
            let ch = self.src[self.pos..]
                .chars()
                .next()
                .ok_or_else(|| "invalid UTF-8".to_string())?;
            self.pos += ch.len_utf8();
            match ch {
                '"' => return Ok(out),
                '\\' => {
                    if self.is_eof() {
                        return Err("unterminated escape sequence".to_string());
                    }
                    let esc = self.src[self.pos..]
                        .chars()
                        .next()
                        .ok_or_else(|| "invalid escape".to_string())?;
                    self.pos += esc.len_utf8();
                    match esc {
                        '"' => out.push('"'),
                        '\\' => out.push('\\'),
                        '/' => out.push('/'),
                        'b' => out.push('\u{08}'),
                        'f' => out.push('\u{0C}'),
                        'n' => out.push('\n'),
                        'r' => out.push('\r'),
                        't' => out.push('\t'),
                        'u' => {
                            let code = self.parse_hex4()?;
                            if (0xD800..=0xDBFF).contains(&code) {
                                if self.src[self.pos..].starts_with("\\u") {
                                    self.pos += 2;
                                    let low = self.parse_hex4()?;
                                    if (0xDC00..=0xDFFF).contains(&low) {
                                        let combined = 0x10000
                                            + (((code as u32 - 0xD800) << 10)
                                                | (low as u32 - 0xDC00));
                                        let c = char::from_u32(combined)
                                            .ok_or_else(|| "invalid surrogate pair".to_string())?;
                                        out.push(c);
                                        continue;
                                    }
                                }
                                return Err("unpaired high surrogate".to_string());
                            }
                            let c = char::from_u32(u32::from(code))
                                .ok_or_else(|| "invalid unicode escape".to_string())?;
                            out.push(c);
                        }
                        other => return Err(format!("invalid escape '\\{other}'")),
                    }
                }
                c if (c as u32) < 0x20 => {
                    return Err(format!("unescaped control character at {}", self.pos));
                }
                c => out.push(c),
            }
        }
        Err("unterminated JSON string".to_string())
    }

    fn parse_hex4(&mut self) -> Result<u16, String> {
        if self.pos + 4 > self.bytes.len() {
            return Err("truncated \\uXXXX escape".to_string());
        }
        let hex = &self.src[self.pos..self.pos + 4];
        self.pos += 4;
        u16::from_str_radix(hex, 16).map_err(|e| format!("invalid hex escape: {e}"))
    }

    fn parse_number(&mut self) -> Result<JsonValue, String> {
        let start = self.pos;
        if self.peek() == Some(b'-') {
            self.pos += 1;
        }
        while let Some(b'0'..=b'9') = self.peek() {
            self.pos += 1;
        }
        if self.peek() == Some(b'.') {
            self.pos += 1;
            while let Some(b'0'..=b'9') = self.peek() {
                self.pos += 1;
            }
        }
        if matches!(self.peek(), Some(b'e' | b'E')) {
            self.pos += 1;
            if matches!(self.peek(), Some(b'+' | b'-')) {
                self.pos += 1;
            }
            while let Some(b'0'..=b'9') = self.peek() {
                self.pos += 1;
            }
        }
        let slice = &self.src[start..self.pos];
        let num = slice
            .parse::<f64>()
            .map_err(|e| format!("invalid number '{slice}': {e}"))?;
        Ok(JsonValue::Number(num))
    }
}

/// Strips optional markdown ```json fences and extracts the outermost `{...}` JSON substring.
#[must_use]
pub fn extract_json_object(raw: &str) -> &str {
    let mut s = raw.trim();
    if let Some(after_fence) = s.strip_prefix("```") {
        let after_first_line = if let Some(nl) = after_fence.find('\n') {
            &after_fence[nl + 1..]
        } else {
            after_fence
        };
        let without_closing = after_first_line
            .trim_end()
            .strip_suffix("```")
            .unwrap_or(after_first_line);
        s = without_closing.trim();
    }
    if let (Some(start), Some(end)) = (s.find('{'), s.rfind('}')) {
        if end > start {
            return &s[start..=end];
        }
    }
    s
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

/// Parses persisted [`MeetingMinutes`] JSON against `spine`, enforcing full lexical grounding
/// when `require_lexical_grounding` is `true` and citation totality when `false`.
pub fn parse_persisted_meeting_minutes_json(
    raw: &str,
    spine: &UtteranceSpine,
    require_lexical_grounding: bool,
) -> Result<MeetingMinutes, MinutesValidationError> {
    parse_meeting_minutes_json_inner(raw, spine, require_lexical_grounding)
}

/// Parses and validates a raw LLM JSON response into [`MeetingMinutes`] against `spine`.
pub fn parse_meeting_minutes_json(
    raw: &str,
    spine: &UtteranceSpine,
) -> Result<MeetingMinutes, MinutesValidationError> {
    parse_meeting_minutes_json_inner(raw, spine, true)
}

fn parse_meeting_minutes_json_inner(
    raw: &str,
    spine: &UtteranceSpine,
    require_lexical_grounding: bool,
) -> Result<MeetingMinutes, MinutesValidationError> {
    let extracted = extract_json_object(raw);
    let val = JsonValue::parse(extracted).map_err(MinutesValidationError::InvalidJson)?;
    let map = val
        .as_object()
        .ok_or_else(|| MinutesValidationError::InvalidJson("root must be an object".to_string()))?;

    let version = match map.get("schemaVersion") {
        None | Some(JsonValue::Null) => 1u32,
        Some(v) => {
            let Some(n) = v.as_i64() else {
                return Err(MinutesValidationError::UnsupportedSchemaVersion(-1));
            };
            if n != 1 && n != 2 {
                return Err(MinutesValidationError::UnsupportedSchemaVersion(n));
            }
            n as u32
        }
    };

    let req_str =
        |obj: &BTreeMap<String, JsonValue>, key: &str| -> Result<String, MinutesValidationError> {
            let Some(s) = obj.get(key).and_then(JsonValue::as_str) else {
                return Err(MinutesValidationError::InvalidJson(format!(
                    "missing or non-string field '{key}'"
                )));
            };
            let t = s.trim();
            if t.is_empty() || (version == 2 && t.chars().count() > 20_000) {
                return Err(MinutesValidationError::InvalidJson(format!(
                    "empty or oversized field '{key}'"
                )));
            }
            Ok(t.to_string())
        };

    let opt_str = |obj: &BTreeMap<String, JsonValue>,
                   key: &str|
     -> Result<Option<String>, MinutesValidationError> {
        match obj.get(key) {
            None | Some(JsonValue::Null) => Ok(None),
            Some(JsonValue::String(s)) => {
                let t = s.trim();
                if version == 2 && t.chars().count() > 20_000 {
                    return Err(MinutesValidationError::InvalidJson(format!(
                        "oversized optional field '{key}'"
                    )));
                }
                if t.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(t.to_string()))
                }
            }
            _ => Err(MinutesValidationError::InvalidJson(format!(
                "non-string optional field '{key}'"
            ))),
        }
    };

    let parse_sources = |obj: &BTreeMap<String, JsonValue>,
                         claim_label: &str|
     -> Result<Vec<SegmentId>, MinutesValidationError> {
        let Some(arr) = obj.get("sources").and_then(JsonValue::as_array) else {
            return Err(MinutesValidationError::InvalidCitation {
                claim: claim_label.to_string(),
                invalid_id: None,
            });
        };
        if arr.is_empty() {
            return Err(MinutesValidationError::InvalidCitation {
                claim: claim_label.to_string(),
                invalid_id: None,
            });
        }
        let mut seen = BTreeSet::new();
        let mut out = Vec::with_capacity(arr.len());
        for entry in arr {
            let Some(s) = entry.as_str() else {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: None,
                });
            };
            let trimmed = s.trim();
            if !trimmed.starts_with('S') {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: None,
                });
            }
            let Some(seg_id) = SegmentId::parse_citation(trimmed) else {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: None,
                });
            };
            if !spine.validate_citation(seg_id) {
                return Err(MinutesValidationError::InvalidCitation {
                    claim: claim_label.to_string(),
                    invalid_id: Some(seg_id),
                });
            }
            if seen.insert(seg_id) {
                out.push(seg_id);
            }
        }
        Ok(out)
    };

    let parse_point = |val: &JsonValue| -> Result<MinutePoint, MinutesValidationError> {
        let obj = val.as_object().ok_or_else(|| {
            MinutesValidationError::InvalidJson("item must be an object".to_string())
        })?;
        let text = req_str(obj, "text")?;
        let owner = opt_str(obj, "owner")?;
        let due = opt_str(obj, "due")?;
        let speaker = opt_str(obj, "speaker")?;
        let citations = parse_sources(obj, &text)?;
        Ok(MinutePoint {
            claim: text,
            speaker,
            owner,
            due,
            citations,
        })
    };

    let parse_point_list =
        |key: &str, required: bool| -> Result<Vec<MinutePoint>, MinutesValidationError> {
            let Some(v) = map.get(key) else {
                if required {
                    return Err(MinutesValidationError::InvalidJson(format!(
                        "missing required array '{key}'"
                    )));
                }
                return Ok(Vec::new());
            };
            if matches!(v, JsonValue::Null) && !required {
                return Ok(Vec::new());
            }
            let arr = v.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson(format!("field '{key}' must be an array"))
            })?;
            arr.iter().map(parse_point).collect()
        };

    let parse_fishbone = |val: &JsonValue| -> Result<MinuteFishbone, MinutesValidationError> {
        let obj = val.as_object().ok_or_else(|| {
            MinutesValidationError::InvalidJson("fishbone must be an object".to_string())
        })?;
        let question = req_str(obj, "question")?;
        let branches = obj
            .get("branches")
            .and_then(JsonValue::as_array)
            .ok_or_else(|| {
                MinutesValidationError::InvalidJson(
                    "fishbone.branches must be an array".to_string(),
                )
            })?;
        if branches.is_empty() || branches.len() > 8 {
            return Err(MinutesValidationError::InvalidJson(
                "fishbone.branches must have 1..=8 items".to_string(),
            ));
        }
        let mut causes = Vec::with_capacity(branches.len());
        for b in branches {
            let b_obj = b.as_object().ok_or_else(|| {
                MinutesValidationError::InvalidJson("fishbone branch must be an object".to_string())
            })?;
            let category = req_str(b_obj, "text")?;
            let description = req_str(b_obj, "detail")?;
            let citations = parse_sources(b_obj, &format!("{category} {description}"))?;
            causes.push(MinuteCause {
                category,
                description,
                citations,
            });
        }
        Ok(MinuteFishbone {
            issue: question,
            causes,
        })
    };

    let title = req_str(map, "title")?;
    let overview = req_str(map, "overview")?;

    let topics_arr = map
        .get("topics")
        .and_then(JsonValue::as_array)
        .ok_or_else(|| MinutesValidationError::InvalidJson("missing 'topics' array".to_string()))?;
    let mut topics = Vec::with_capacity(topics_arr.len());
    let mut top_fishbones = Vec::new();
    for t_val in topics_arr {
        let t_obj = t_val.as_object().ok_or_else(|| {
            MinutesValidationError::InvalidJson("topic must be an object".to_string())
        })?;
        let t_title = req_str(t_obj, "text")?;
        let t_citations = parse_sources(t_obj, &t_title)?;
        let t_summary = opt_str(t_obj, "summary")?.unwrap_or_default();
        let t_points = match t_obj.get("points") {
            None | Some(JsonValue::Null) => Vec::new(),
            Some(JsonValue::Array(arr)) => {
                arr.iter().map(parse_point).collect::<Result<Vec<_>, _>>()?
            }
            _ => {
                return Err(MinutesValidationError::InvalidJson(
                    "topic.points must be an array".to_string(),
                ))
            }
        };
        let t_fishbone = match t_obj.get("fishbone") {
            None | Some(JsonValue::Null) => None,
            Some(fb_val) => {
                let fb = parse_fishbone(fb_val)?;
                top_fishbones.push(fb.clone());
                Some(fb)
            }
        };
        topics.push(MinuteTopic {
            title: t_title,
            summary: t_summary,
            citations: t_citations,
            points: t_points,
            fishbone: t_fishbone,
        });
    }
    if let Some(fbs_val) = map.get("fishbones") {
        if !matches!(fbs_val, JsonValue::Null) {
            let arr = fbs_val.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'fishbones' must be an array".to_string())
            })?;
            for fb_val in arr {
                let fb = parse_fishbone(fb_val)?;
                if !top_fishbones.contains(&fb) {
                    top_fishbones.push(fb);
                }
            }
        }
    }

    let decisions = parse_point_list("decisions", true)?;
    let actions = parse_point_list("actions", true)?;
    let questions = parse_point_list("questions", true)?;

    let mut custom_sections = Vec::new();
    if let Some(custom_val) = map.get("custom") {
        if !matches!(custom_val, JsonValue::Null) {
            let custom_obj = custom_val.as_object().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'custom' must be an object".to_string())
            })?;
            for (heading, items_val) in custom_obj {
                let clean_heading = heading.trim();
                if clean_heading.is_empty()
                    || (version == 2 && clean_heading.chars().count() > 20_000)
                {
                    return Err(MinutesValidationError::InvalidJson(
                        "invalid custom section heading".to_string(),
                    ));
                }
                let arr = items_val.as_array().ok_or_else(|| {
                    MinutesValidationError::InvalidJson(
                        "custom section items must be an array".to_string(),
                    )
                })?;
                let pts = arr.iter().map(parse_point).collect::<Result<Vec<_>, _>>()?;
                custom_sections.push(MinuteCustomSection {
                    heading: clean_heading.to_string(),
                    points: pts,
                });
            }
        }
    }

    let mut review_items = Vec::new();
    if let Some(rev_val) = map.get("reviewItems") {
        if !matches!(rev_val, JsonValue::Null) {
            let arr = rev_val.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'reviewItems' must be an array".to_string())
            })?;
            for r in arr {
                let Some(s) = r.as_str() else {
                    return Err(MinutesValidationError::InvalidJson(
                        "reviewItems entry must be a string".to_string(),
                    ));
                };
                let t = s.trim();
                if t.is_empty() || (version == 2 && t.chars().count() > 20_000) {
                    return Err(MinutesValidationError::InvalidJson(
                        "invalid reviewItems entry".to_string(),
                    ));
                }
                review_items.push(t.to_string());
            }
        }
    }

    let mut terms = Vec::new();
    if let Some(terms_val) = map.get("terms") {
        if !matches!(terms_val, JsonValue::Null) {
            if version < 2 {
                return Err(MinutesValidationError::InvalidJson(
                    "'terms' is only supported in schemaVersion 2".to_string(),
                ));
            }
            let arr = terms_val.as_array().ok_or_else(|| {
                MinutesValidationError::InvalidJson("'terms' must be an array".to_string())
            })?;
            for entry in arr {
                let t_obj = entry.as_object().ok_or_else(|| {
                    MinutesValidationError::InvalidJson("term entry must be an object".to_string())
                })?;
                let name = req_str(t_obj, "name")?;
                let note = req_str(t_obj, "note")?;
                let citations = parse_sources(t_obj, &format!("{name} {note}"))?;
                let mut heard = Vec::new();
                if let Some(h_val) = t_obj.get("heard") {
                    if !matches!(h_val, JsonValue::Null) {
                        let h_arr = h_val.as_array().ok_or_else(|| {
                            MinutesValidationError::InvalidJson(
                                "term.heard must be an array".to_string(),
                            )
                        })?;
                        if h_arr.len() > 30 {
                            return Err(MinutesValidationError::InvalidJson(
                                "term.heard exceeds 30 entries".to_string(),
                            ));
                        }
                        let mut seen_h = BTreeSet::new();
                        for h_item in h_arr {
                            let Some(hs) = h_item.as_str() else {
                                return Err(MinutesValidationError::InvalidJson(
                                    "term.heard item must be a string".to_string(),
                                ));
                            };
                            let ht = hs.trim();
                            if ht.is_empty() || ht.chars().count() > 20_000 {
                                return Err(MinutesValidationError::InvalidJson(
                                    "empty or oversized term.heard item".to_string(),
                                ));
                            }
                            if require_lexical_grounding {
                                let grounded = citations.iter().any(|&cid| {
                                    spine.get(cid).is_some_and(|seg| seg.text.contains(ht))
                                });
                                if !grounded {
                                    return Err(MinutesValidationError::UngroundedHeardVariant {
                                        term: name,
                                        heard: ht.to_string(),
                                    });
                                }
                            }
                            if seen_h.insert(ht.to_string()) {
                                heard.push(ht.to_string());
                            }
                        }
                    }
                }
                terms.push(MinuteTerm {
                    term: name,
                    definition: note,
                    heard,
                    adoption: MinuteTermAdoption::Suggested,
                    citations,
                });
            }
        }
    }

    let minutes = MeetingMinutes {
        version,
        spine_revision: spine.revision(),
        title,
        overview,
        topics,
        decisions,
        actions,
        questions,
        fishbones: top_fishbones,
        terms,
        custom_sections,
        review_items,
    };

    if require_lexical_grounding {
        validate_minutes_grounding(&minutes, spine)?;
    } else {
        validate_minutes_citations(&minutes, spine)?;
    }
    Ok(minutes)
}

/// Encodes [`MeetingMinutes`] into the canonical JSON schema.
#[must_use]
pub fn encode_meeting_minutes_json(minutes: &MeetingMinutes) -> String {
    let encode_sources = |citations: &[SegmentId]| -> JsonValue {
        JsonValue::Array(
            citations
                .iter()
                .map(|id| JsonValue::String(id.to_string()))
                .collect(),
        )
    };
    let encode_point = |pt: &MinutePoint| -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("text".to_string(), JsonValue::String(pt.claim.clone()));
        if let Some(owner) = &pt.owner {
            obj.insert("owner".to_string(), JsonValue::String(owner.clone()));
        }
        if let Some(due) = &pt.due {
            obj.insert("due".to_string(), JsonValue::String(due.clone()));
        }
        if let Some(speaker) = &pt.speaker {
            obj.insert("speaker".to_string(), JsonValue::String(speaker.clone()));
        }
        obj.insert("sources".to_string(), encode_sources(&pt.citations));
        JsonValue::Object(obj)
    };
    let encode_fishbone = |fb: &MinuteFishbone| -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("question".to_string(), JsonValue::String(fb.issue.clone()));
        let branches = fb
            .causes
            .iter()
            .map(|c| {
                let mut b = BTreeMap::new();
                b.insert("text".to_string(), JsonValue::String(c.category.clone()));
                b.insert(
                    "detail".to_string(),
                    JsonValue::String(c.description.clone()),
                );
                b.insert("sources".to_string(), encode_sources(&c.citations));
                JsonValue::Object(b)
            })
            .collect();
        obj.insert("branches".to_string(), JsonValue::Array(branches));
        JsonValue::Object(obj)
    };

    let mut root = BTreeMap::new();
    root.insert(
        "schemaVersion".to_string(),
        JsonValue::Number(f64::from(minutes.version.max(1))),
    );
    root.insert(
        "title".to_string(),
        JsonValue::String(minutes.title.clone()),
    );
    root.insert(
        "overview".to_string(),
        JsonValue::String(minutes.overview.clone()),
    );

    let topics_json: Vec<JsonValue> = minutes
        .topics
        .iter()
        .map(|t| {
            let mut obj = BTreeMap::new();
            obj.insert("text".to_string(), JsonValue::String(t.title.clone()));
            let citations = if t.citations.is_empty() {
                t.points
                    .first()
                    .map(|p| p.citations.clone())
                    .unwrap_or_default()
            } else {
                t.citations.clone()
            };
            obj.insert("sources".to_string(), encode_sources(&citations));
            if !t.summary.is_empty() {
                obj.insert("summary".to_string(), JsonValue::String(t.summary.clone()));
            }
            if !t.points.is_empty() {
                obj.insert(
                    "points".to_string(),
                    JsonValue::Array(t.points.iter().map(encode_point).collect()),
                );
            }
            if let Some(fb) = &t.fishbone {
                obj.insert("fishbone".to_string(), encode_fishbone(fb));
            }
            JsonValue::Object(obj)
        })
        .collect();
    root.insert("topics".to_string(), JsonValue::Array(topics_json));
    if !minutes.fishbones.is_empty() {
        root.insert(
            "fishbones".to_string(),
            JsonValue::Array(minutes.fishbones.iter().map(encode_fishbone).collect()),
        );
    }
    root.insert(
        "decisions".to_string(),
        JsonValue::Array(minutes.decisions.iter().map(encode_point).collect()),
    );
    root.insert(
        "actions".to_string(),
        JsonValue::Array(minutes.actions.iter().map(encode_point).collect()),
    );
    root.insert(
        "questions".to_string(),
        JsonValue::Array(minutes.questions.iter().map(encode_point).collect()),
    );

    if !minutes.custom_sections.is_empty() {
        let mut custom_map = BTreeMap::new();
        for sec in &minutes.custom_sections {
            custom_map.insert(
                sec.heading.clone(),
                JsonValue::Array(sec.points.iter().map(encode_point).collect()),
            );
        }
        root.insert("custom".to_string(), JsonValue::Object(custom_map));
    }
    if !minutes.review_items.is_empty() {
        root.insert(
            "reviewItems".to_string(),
            JsonValue::Array(
                minutes
                    .review_items
                    .iter()
                    .map(|s| JsonValue::String(s.clone()))
                    .collect(),
            ),
        );
    }
    if !minutes.terms.is_empty() {
        let terms_json: Vec<JsonValue> = minutes
            .terms
            .iter()
            .map(|term| {
                let mut obj = BTreeMap::new();
                obj.insert("name".to_string(), JsonValue::String(term.term.clone()));
                obj.insert(
                    "note".to_string(),
                    JsonValue::String(term.definition.clone()),
                );
                if !term.heard.is_empty() {
                    obj.insert(
                        "heard".to_string(),
                        JsonValue::Array(
                            term.heard
                                .iter()
                                .map(|h| JsonValue::String(h.clone()))
                                .collect(),
                        ),
                    );
                }
                obj.insert("sources".to_string(), encode_sources(&term.citations));
                JsonValue::Object(obj)
            })
            .collect();
        root.insert("terms".to_string(), JsonValue::Array(terms_json));
    }

    JsonValue::Object(root).to_json_string()
}

fn replace_minute_terms(text: &str, replacements: &[(&str, &str)]) -> String {
    if text.is_empty() || replacements.is_empty() {
        return text.to_string();
    }
    let mut sorted: Vec<(&str, &str, usize)> = Vec::new();
    let mut seen_keys = BTreeSet::new();
    for &(from, to) in replacements {
        if !from.is_empty() && from != to && seen_keys.insert(from) {
            sorted.push((from, to, from.chars().count()));
        }
    }
    if sorted.is_empty() {
        return text.to_string();
    }
    sorted.sort_by(|a, b| b.2.cmp(&a.2).then_with(|| a.0.cmp(b.0)));

    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while !rest.is_empty() {
        let mut matched: Option<(&str, &str)> = None;
        for &(from, to, _) in &sorted {
            if rest.starts_with(from) {
                matched = Some((from, to));
                break;
            }
        }
        if let Some((from, to)) = matched {
            out.push_str(to);
            rest = &rest[from.len()..];
        } else if let Some(ch) = rest.chars().next() {
            out.push(ch);
            rest = &rest[ch.len_utf8()..];
        } else {
            break;
        }
    }
    out
}

impl MeetingMinutes {
    /// Returns the deduplicated set of all [`SegmentId`]s cited anywhere in this document.
    #[must_use]
    pub fn all_cited_ids(&self) -> BTreeSet<SegmentId> {
        let mut ids = BTreeSet::new();
        for t in &self.topics {
            ids.extend(t.citations.iter().copied());
            for p in &t.points {
                ids.extend(p.citations.iter().copied());
            }
            if let Some(fb) = &t.fishbone {
                for c in &fb.causes {
                    ids.extend(c.citations.iter().copied());
                }
            }
        }
        for d in &self.decisions {
            ids.extend(d.citations.iter().copied());
        }
        for a in &self.actions {
            ids.extend(a.citations.iter().copied());
        }
        for q in &self.questions {
            ids.extend(q.citations.iter().copied());
        }
        for fb in &self.fishbones {
            for c in &fb.causes {
                ids.extend(c.citations.iter().copied());
            }
        }
        for term in &self.terms {
            ids.extend(term.citations.iter().copied());
        }
        for sec in &self.custom_sections {
            for p in &sec.points {
                ids.extend(p.citations.iter().copied());
            }
        }
        ids
    }

    /// Applies single-pass longest-match term replacement across all text fields, custom section
    /// headings, and `terms` (merging duplicate term names after replacement).
    pub fn replace_terms(&mut self, replacements: &[(&str, &str)]) {
        if replacements.is_empty() {
            return;
        }
        let r = |s: &str| replace_minute_terms(s, replacements);
        self.title = r(&self.title);
        self.overview = r(&self.overview);

        let replace_point = |pt: &mut MinutePoint| {
            pt.claim = r(&pt.claim);
            pt.owner = pt.owner.as_deref().map(&r);
            pt.due = pt.due.as_deref().map(&r);
            pt.speaker = pt.speaker.as_deref().map(&r);
        };
        let replace_fb = |fb: &mut MinuteFishbone| {
            fb.issue = r(&fb.issue);
            for c in &mut fb.causes {
                c.category = r(&c.category);
                c.description = r(&c.description);
            }
        };

        for t in &mut self.topics {
            t.title = r(&t.title);
            t.summary = r(&t.summary);
            for pt in &mut t.points {
                replace_point(pt);
            }
            if let Some(fb) = &mut t.fishbone {
                replace_fb(fb);
            }
        }
        for d in &mut self.decisions {
            replace_point(d);
        }
        for a in &mut self.actions {
            replace_point(a);
        }
        for q in &mut self.questions {
            replace_point(q);
        }
        for fb in &mut self.fishbones {
            replace_fb(fb);
        }
        for sec in &mut self.custom_sections {
            sec.heading = r(&sec.heading);
            for pt in &mut sec.points {
                replace_point(pt);
            }
        }
        self.review_items = self.review_items.iter().map(|s| r(s)).collect();

        let mut merged_terms: Vec<MinuteTerm> = Vec::new();
        for term in &self.terms {
            let next_name = r(&term.term);
            let next_note = r(&term.definition);
            let mut next_heard = Vec::new();
            for h in &term.heard {
                let rh = r(h);
                if rh != next_name && !next_heard.contains(&rh) {
                    next_heard.push(rh);
                }
            }
            if let Some(existing) = merged_terms.iter_mut().find(|t| t.term == next_name) {
                for h in next_heard {
                    if !existing.heard.contains(&h) {
                        existing.heard.push(h);
                    }
                }
                for &cid in &term.citations {
                    if !existing.citations.contains(&cid) {
                        existing.citations.push(cid);
                    }
                }
            } else {
                merged_terms.push(MinuteTerm {
                    term: next_name,
                    definition: next_note,
                    heard: next_heard,
                    adoption: term.adoption,
                    citations: term.citations.clone(),
                });
            }
        }
        self.terms = merged_terms;
    }

    /// Replaces `old_name` with `new_name` across all fields (`replaceSpeakerName`).
    pub fn replace_speaker_name(&mut self, old_name: &str, new_name: &str) {
        let from = old_name.trim();
        let to = new_name.trim();
        if from.is_empty() || to.is_empty() || from == to {
            return;
        }
        self.replace_terms(&[(from, to)]);
    }

    /// Removes a specific `heard` spelling from the term matching `term_name` (`pruneHeard`).
    pub fn prune_heard(&mut self, term_name: &str, heard_spelling: &str) {
        for t in &mut self.terms {
            if t.term == term_name {
                t.heard.retain(|h| h != heard_spelling);
            }
        }
    }
}

/// Builds the trilingual (`zh` / `en` / `ja`) meeting minutes LLM system/user prompt with
/// optional custom template sections, custom instructions, and hot-word vocabulary hints.
#[must_use]
pub fn build_meeting_minutes_prompt(
    numbered_transcript: &str,
    locale_code: &str,
    custom_sections: &[String],
    custom_instructions: Option<&str>,
    vocabulary: &[String],
) -> String {
    let sections: Vec<String> = custom_sections
        .iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect();

    let extra = custom_instructions
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(|s| format!("\n- {s}"))
        .unwrap_or_default();

    let clean_vocab: Vec<String> = vocabulary
        .iter()
        .map(|w| w.trim().to_string())
        .filter(|w| !w.is_empty())
        .take(200)
        .collect();

    let mut custom_schema = String::new();
    let mut custom_rule = extra.clone();
    if !sections.is_empty() {
        let entries: Vec<String> = sections
            .iter()
            .map(|h| {
                let mut key = String::new();
                write_escaped_json_string(h, &mut key);
                format!("    {key}: [{{ \"text\": \"...\", \"sources\": [\"S1\"] }}]")
            })
            .collect();
        custom_schema = format!(",\n  \"custom\": {{\n{}\n  }}", entries.join(",\n"));
        custom_rule = match locale_code {
            "en" => format!(
                "\n- Fill \"custom\" with the template sections ({}); use [] when a section has no grounded points.{extra}",
                sections.join(", ")
            ),
            "ja" => format!(
                "\n- \"custom\" にはテンプレートの各セクション（{}）を入れ、該当がない場合は [] にしてください。{extra}",
                sections.join("、")
            ),
            _ => format!(
                "\n- 按模板填写 \"custom\" 中的各个分栏（{}），原话未提及时填 []。{extra}",
                sections.join("、")
            ),
        };
    }

    let vocab_rule = if clean_vocab.is_empty() {
        String::new()
    } else {
        let joined = clean_vocab.join(", ");
        match locale_code {
            "en" => format!(
                "\n- Known terms / proper nouns (correct obvious homophone ASR errors to these spellings when context matches, and cite the original sentence): {joined}"
            ),
            "ja" => format!(
                "\n- 既知の固有名詞・専門用語（同音異字の認識誤りがあれば文脈に応じてこの表記に揃え、元の文の番号を引用してください）：{joined}"
            ),
            _ => format!(
                "\n- 已知专有名词/术语表（若原话中有同音或近音识别错误，请在纪要与 terms.name 中统一写成以下标准写法，并在 terms.heard 中列出原话里实际出现的错别字，同时引用原句编号）：{}",
                clean_vocab.join("、")
            ),
        }
    };

    match locale_code {
        "en" => format!(
            "Turn the numbered transcript below into structured meeting minutes.\nReturn ONLY a single JSON object (no markdown fences, no commentary) matching this exact schema:\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"Concise title (<= 16 words)\",\n  \"overview\": \"2-4 sentence executive summary\",\n  \"topics\": [\n    {{\n      \"text\": \"Topic title\",\n      \"summary\": \"1-2 sentence synthesis of this topic\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"Specific viewpoint, argument, or fact\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"Core problem or question (optional: include ONLY when the topic analyzes causes of an issue)\",\n        \"branches\": [\n          {{ \"text\": \"Cause category\", \"detail\": \"Specific cause\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"Decision reached\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"Concrete next step\", \"owner\": \"Person (optional)\", \"due\": \"Deadline (optional)\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"Unresolved question or risk\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"Proper noun or domain term (<= 6 items)\", \"note\": \"Brief role or meaning in this recording\", \"heard\": [\"Exact substring in cited S# if ASR misheard it\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3: possible ASR error or ambiguity worth checking\"]{custom_schema}\n}}\n\nStrict grounding rules:\n- Every item in topics, topic.points, fishbone.branches, decisions, actions, questions, and terms MUST have a non-empty \"sources\" array containing only sentence IDs (S1, S2, ...) that directly support it.\n- Never invent facts, numbers, ratios, formulas, or deadlines not stated in the transcript.\n- Never combine numbers from different sentences to infer a formula or calculation (e.g., do NOT write \"salary is base * 80%\" or \"calculated at 80% of X\" unless a single source sentence explicitly states that exact calculation).\n- Use [] for any list that has no grounded items; omit \"fishbone\" when a topic is not a root-cause discussion; omit \"owner\" / \"due\" when not explicitly mentioned.\n- In \"terms.heard\", include ONLY exact substrings that literally appear in the cited sentences when ASR misheard the term; omit \"heard\" if the transcript already uses the canonical spelling.\n- Keep the language of the transcript.{custom_rule}{vocab_rule}\n\nNumbered transcript:\n{numbered_transcript}"
        ),
        "ja" => format!(
            "以下の番号付き文字起こしから構造化された議事録を作成してください。\nマークダウンのコードブロックや説明文は一切付けず、次のスキーマに厳密に従う JSON オブジェクトのみを返してください:\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"簡潔なタイトル（25文字以内）\",\n  \"overview\": \"2〜4文の要約\",\n  \"topics\": [\n    {{\n      \"text\": \"トピック見出し\",\n      \"summary\": \"このトピックの1〜2文のまとめ\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"具体的な発言・論点・事実\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"中心となる問題・問い（原因分析をしているトピックのみ任意で記載）\",\n        \"branches\": [\n          {{ \"text\": \"要因カテゴリ\", \"detail\": \"具体的な原因\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"決定事項\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"具体的な次のアクション\", \"owner\": \"担当者（任意）\", \"due\": \"期限（任意）\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"未解決の課題・疑問\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"固有名詞・専門用語（最大6件）\", \"note\": \"この録音における簡単な説明\", \"heard\": [\"誤変換されている場合、引用した S# 内に実際に出現する文字列\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3: 認識誤りや曖昧さがあり確認が必要な箇所\"]{custom_schema}\n}}\n\n厳守事項:\n- topics、topic.points、fishbone.branches、decisions、actions、questions、terms の各要素には、根拠となる文番号（S1, S2, ...）のみを含む非空の \"sources\" 配列を必ず付けてください。\n- 文字起こしにない事実・数値・割合・計算式・期限を絶対に創作しないでください。\n- 複数の文の数値を組み合わせて計算式や割合を推測しないでください（1つの文で明言されていない限り「基本給×80%」「Xの80%で計算」等と書かないこと）。\n- 該当がない配列は [] にし、原因分析でないトピックでは \"fishbone\" を省略し、明言されていない \"owner\" / \"due\" は省略してください。\n- \"terms.heard\" には、音声認識の誤りがある場合に引用元の文にそのまま含まれる部分文字列のみを入れてください。元の文がすでに正しい表記なら \"heard\" は省略してください。{custom_rule}{vocab_rule}\n\n番号付き文字起こし:\n{numbered_transcript}"
        ),
        _ => format!(
            "请根据下方带编号的逐句原话，整理结构化闪记纪要。\n只返回一个 JSON 对象（不要 ``` 代码块，不要任何额外说明），严格符合以下结构：\n{{\n  \"schemaVersion\": 2,\n  \"title\": \"简短标题（20字以内）\",\n  \"overview\": \"2到4句话的整体概述\",\n  \"topics\": [\n    {{\n      \"text\": \"主题标题\",\n      \"summary\": \"1到2句话概括该主题的核心内容\",\n      \"sources\": [\"S1\", \"S2\"],\n      \"points\": [\n        {{ \"text\": \"该主题下的具体观点、论据或事实\", \"sources\": [\"S1\"] }}\n      ],\n      \"fishbone\": {{\n        \"question\": \"核心问题（可选：仅在该主题讨论问题成因/故障排查时填写）\",\n        \"branches\": [\n          {{ \"text\": \"原因类别（如人员/流程/环境）\", \"detail\": \"具体原因说明\", \"sources\": [\"S2\"] }}\n        ]\n      }}\n    }}\n  ],\n  \"decisions\": [\n    {{ \"text\": \"已达成的决定或结论\", \"sources\": [\"S3\"] }}\n  ],\n  \"actions\": [\n    {{ \"text\": \"具体待办事项\", \"owner\": \"负责人（原话未提则省略）\", \"due\": \"期限（原话未提则省略）\", \"sources\": [\"S4\"] }}\n  ],\n  \"questions\": [\n    {{ \"text\": \"未解决的问题或风险\", \"sources\": [\"S5\"] }}\n  ],\n  \"terms\": [\n    {{ \"name\": \"专有名词/人名/项目名/术语（最多6个）\", \"note\": \"在本次录音中的简短说明\", \"heard\": [\"若原话被识别成同音错字，填所引原句中实际出现的错字子串\"], \"sources\": [\"S1\"] }}\n  ],\n  \"reviewItems\": [\"S3：疑似识别有误或表述含糊、建议人工复核的地方\"]{custom_schema}\n}}\n\n严格约束：\n- topics、topic.points、fishbone.branches、decisions、actions、questions、terms 中的每一条都必须带有非空的 \"sources\" 数组，且只能引用直接支撑该条内容的原句编号（S1、S2……）。\n- 严禁编造原话中没有的事实、数字、比例、计算公式、人名或期限。\n- 严禁把不同句子的数字拼在一起推算工资、基数或比例公式（例如原话未在同一句明确说出“按基本工资乘以80%计算”，绝不能自行合成此类算式）。\n- 没有对应内容的列表填 []；非原因分析的主题省略 \"fishbone\"；未明确提及的 \"owner\" / \"due\" 直接省略字段。\n- \"terms.heard\" 只能填写所引原句（sources）中逐字出现过的错别字子串；若原话本身写法正确则省略 \"heard\"。{custom_rule}{vocab_rule}\n\n带编号原话：\n{numbered_transcript}"
        ),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn minutes_with_claim(
        claim: &str,
        citations: Vec<SegmentId>,
        spine_revision: u64,
    ) -> MeetingMinutes {
        MeetingMinutes {
            version: 2,
            spine_revision,
            title: "核算".to_string(),
            overview: "核对结果".to_string(),
            topics: vec![MinuteTopic {
                title: "薪资".to_string(),
                summary: "讨论情况".to_string(),
                citations: citations.clone(),
                points: vec![MinutePoint {
                    claim: claim.to_string(),
                    speaker: None,
                    owner: None,
                    due: None,
                    citations,
                }],
                fishbone: None,
            }],
            decisions: Vec::new(),
            actions: Vec::new(),
            questions: Vec::new(),
            fishbones: Vec::new(),
            terms: Vec::new(),
            custom_sections: Vec::new(),
            review_items: Vec::new(),
        }
    }

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

        let stitched = validate_minutes_grounding(
            &minutes_with_claim(
                "员工实发工资按3910元乘以80%计算",
                vec![s1, s2],
                spine.revision(),
            ),
            &spine,
        );
        assert_eq!(
            stitched,
            Err(MinutesValidationError::UngroundedWageCalculation {
                claim: "员工实发工资按3910元乘以80%计算".to_string(),
            })
        );

        let baseless_ratio = validate_minutes_grounding(
            &minutes_with_claim("社保缴费基数按80%计算", vec![s1, s2], spine.revision()),
            &spine,
        );
        assert_eq!(
            baseless_ratio,
            Err(MinutesValidationError::BaselessRatioCalculation {
                claim: "社保缴费基数按80%计算".to_string(),
            })
        );

        let uncited_pct = validate_minutes_grounding(
            &minutes_with_claim("本月出勤率达到85%", vec![s2], spine.revision()),
            &spine,
        );
        assert_eq!(
            uncited_pct,
            Err(MinutesValidationError::UncitedPercentageNumber {
                claim: "本月出勤率达到85%".to_string(),
                percentage: "85%".to_string(),
            })
        );

        let grounded = validate_minutes_grounding(
            &minutes_with_claim(
                "员工实发工资按3910元乘以80%计算",
                vec![s3],
                spine.revision(),
            ),
            &spine,
        );
        assert_eq!(grounded, Ok(()));
    }

    #[test]
    fn longest_match_single_pass_term_replacement_and_heard_pruning() {
        let mut spine = UtteranceSpine::new("rec-terms");
        spine.append_segment("今天测试深科和深科Work录音豆。", 0, 1000, "zh", "qwen");
        let raw = r#"{
            "schemaVersion": 2,
            "title": "深科的深科Work录音豆",
            "overview": "测试深科设备",
            "topics": [{"text": "深科蓝牙", "sources": ["S1"]}],
            "decisions": [],
            "actions": [],
            "questions": [],
            "terms": [{"name": "声刻", "note": "品牌", "heard": ["深科"], "sources": ["S1"]}]
        }"#;
        let mut doc = parse_meeting_minutes_json(raw, &spine).unwrap();
        doc.replace_terms(&[("深科", "声刻"), ("深科Work", "Soundcore Work")]);
        assert_eq!(doc.title, "声刻的Soundcore Work录音豆");
        assert!(doc.terms[0].heard.is_empty());
    }

    #[test]
    fn build_meeting_minutes_prompt_includes_custom_instructions_without_custom_sections() {
        for (locale, instruction) in [
            ("zh", "只写有来源的结论、行动和记忆。"),
            ("en", "Keep only cited outcomes."),
            ("ja", "出典のある結論のみ記載してください。"),
        ] {
            let prompt = build_meeting_minutes_prompt(
                "[S1] Example",
                locale,
                &[],
                Some(&format!("  {instruction}  ")),
                &[],
            );
            assert!(
                prompt.contains(&format!("\n- {instruction}")),
                "locale {locale} prompt missing custom instruction: {prompt}"
            );
            assert!(!prompt.contains("\"custom\":"));
        }

        let with_sections = build_meeting_minutes_prompt(
            "[S1] Example",
            "zh",
            &["风险与建议".to_string()],
            Some("仅输出高置信结论。"),
            &[],
        );
        assert!(with_sections.contains("\"custom\":"));
        assert!(with_sections.contains("\n- 仅输出高置信结论。"));
    }
}
