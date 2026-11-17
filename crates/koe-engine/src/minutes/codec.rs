use std::collections::{BTreeMap, BTreeSet};

use super::grounding::{
    validate_minutes_citations, validate_minutes_grounding, MinutesValidationError,
};
use super::json::{extract_json_object, JsonValue};
use crate::domain::{
    MeetingMinutes, MinuteCause, MinuteCustomSection, MinuteFishbone, MinutePoint, MinuteTerm,
    MinuteTermAdoption, MinuteTopic, SegmentId, UtteranceSpine,
};

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
