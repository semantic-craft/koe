use serde_json::{json, Map, Value};

use super::blocking::{
    ensure_allowed_keys, evidence_json, optional_bool, optional_limit, optional_scope,
    optional_str, optional_u64, required_str,
};
use super::{McpToolCallState, McpToolError};
use crate::*;
use koe_engine::product::{ItemKind, ReviewState, SourcedItem};

const GET_RECORD_RESPONSE_BYTE_BUDGET: usize = 1_200_000;
const QUOTE_EXCERPT_MAX_JSON_BYTES: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RecordSegmentPageRequest {
    include_segments: bool,
    offset: usize,
    limit: Option<usize>,
}

fn parse_record_segment_page(
    obj: &Map<String, Value>,
) -> Result<RecordSegmentPageRequest, McpToolError> {
    let include_segments = optional_bool(obj, "include_segments")?.unwrap_or(true);
    let offset = match optional_u64(obj, "segment_offset")? {
        None => 0,
        Some(raw) => usize::try_from(raw)
            .map_err(|_| McpToolError::invalid_params("segment_offset 超出范围"))?,
    };
    let limit = match optional_u64(obj, "segment_limit")? {
        None => None,
        Some(0) => {
            return Err(McpToolError::invalid_params("segment_limit 必须大于等于 1"));
        }
        Some(raw) => Some(
            usize::try_from(raw)
                .map_err(|_| McpToolError::invalid_params("segment_limit 超出范围"))?,
        ),
    };
    Ok(RecordSegmentPageRequest {
        include_segments,
        offset,
        limit,
    })
}

fn set_pagination_fields(
    detail: &mut Value,
    total_segments: usize,
    segment_offset: usize,
    segments_truncated: bool,
    next_segment_offset: Option<usize>,
    metadata_truncated: bool,
) {
    if let Some(obj) = detail.as_object_mut() {
        obj.insert("totalSegments".into(), json!(total_segments));
        obj.insert("segmentOffset".into(), json!(segment_offset));
        obj.insert("segmentsTruncated".into(), json!(segments_truncated));
        obj.insert("nextSegmentOffset".into(), json!(next_segment_offset));
        obj.insert("metadataTruncated".into(), json!(metadata_truncated));
    }
}

fn json_byte_len<T: serde::Serialize + ?Sized>(value: &T) -> usize {
    serde_json::to_vec(value).map_or(usize::MAX, |v| v.len())
}

fn floor_char_boundary(s: &str, max_bytes: usize) -> usize {
    let mut idx = max_bytes.min(s.len());
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    idx
}

fn truncate_str_to_json_budget(text: &str, max_json_bytes: usize) -> Option<String> {
    if text.is_empty() || json_byte_len(text) <= max_json_bytes {
        return None;
    }
    const SUFFIX: &str = "…";
    let mut lo = 0usize;
    let mut hi = text.len().saturating_sub(1);
    let mut best = String::new();
    while lo <= hi {
        let mid = lo + (hi - lo) / 2;
        let cut = floor_char_boundary(text, mid);
        let mut candidate = String::with_capacity(cut + SUFFIX.len());
        candidate.push_str(&text[..cut]);
        candidate.push_str(SUFFIX);
        if json_byte_len(candidate.as_str()) <= max_json_bytes {
            best = candidate;
            lo = mid + 1;
        } else if mid == 0 {
            break;
        } else {
            hi = mid - 1;
        }
    }
    Some(best)
}

fn truncate_string_field_to_shed(
    obj: &mut Map<String, Value>,
    key: &str,
    excess: &mut usize,
) -> bool {
    if *excess == 0 {
        return false;
    }
    let Some(current) = obj.get(key).and_then(Value::as_str) else {
        return false;
    };
    let old_len = json_byte_len(current);
    if old_len <= 2 {
        return false;
    }
    let target = old_len.saturating_sub(*excess).max(2);
    let Some(shortened) = truncate_str_to_json_budget(current, target) else {
        return false;
    };
    let new_len = json_byte_len(shortened.as_str());
    *excess = excess.saturating_sub(old_len.saturating_sub(new_len));
    obj.insert(key.into(), Value::String(shortened));
    true
}

fn pop_json_elem(arr: &mut Vec<Value>, excess: &mut usize) -> bool {
    let Some(removed) = arr.pop() else {
        return false;
    };
    let saved = json_byte_len(&removed).saturating_add(usize::from(!arr.is_empty()));
    *excess = excess.saturating_sub(saved);
    true
}

fn trim_array_to_shed(arr: &mut Vec<Value>, excess: &mut usize) -> bool {
    let mut modified = false;
    while *excess > 0 && pop_json_elem(arr, excess) {
        modified = true;
    }
    modified
}

fn truncate_source_quotes(sources: &mut [Value], max_quote_json_bytes: usize) -> bool {
    let mut modified = false;
    for source in sources {
        let Some(obj) = source.as_object_mut() else {
            continue;
        };
        let Some(quote) = obj.get("quote").and_then(Value::as_str) else {
            continue;
        };
        if let Some(shortened) = truncate_str_to_json_budget(quote, max_quote_json_bytes) {
            obj.insert("quote".into(), Value::String(shortened));
            modified = true;
        }
    }
    modified
}

fn trim_summary_sections_to_shed(sections: &mut Vec<Value>, excess: &mut usize) -> bool {
    let mut modified = false;
    while *excess > 0 && !sections.is_empty() {
        let can_trim_in_place = sections.len() == 1
            || sections
                .last()
                .and_then(|s| s.get("text"))
                .and_then(Value::as_str)
                .is_some_and(|text| json_byte_len(text).saturating_sub(2) >= *excess);
        if can_trim_in_place {
            if let Some(last_obj) = sections.last_mut().and_then(Value::as_object_mut) {
                let trimmed_text = truncate_string_field_to_shed(last_obj, "text", excess);
                let trimmed_title = truncate_string_field_to_shed(last_obj, "title", excess);
                if trimmed_text || trimmed_title {
                    modified = true;
                    continue;
                }
            }
        }
        modified |= pop_json_elem(sections, excess);
    }
    modified
}

fn compact_metadata_to_budget(detail: &mut Value, metadata_budget: usize) -> bool {
    if json_byte_len(detail) <= metadata_budget {
        return false;
    }

    let mut truncated = false;
    if let Some(obj) = detail.as_object_mut() {
        if let Some(highlights) = obj.get_mut("highlights").and_then(Value::as_array_mut) {
            truncated |= truncate_source_quotes(highlights, QUOTE_EXCERPT_MAX_JSON_BYTES);
        }
        if let Some(summary) = obj.get_mut("summary").and_then(Value::as_array_mut) {
            for section in summary {
                if let Some(sources) = section.get_mut("sources").and_then(Value::as_array_mut) {
                    truncated |= truncate_source_quotes(sources, QUOTE_EXCERPT_MAX_JSON_BYTES);
                }
            }
        }
    }

    let mut excess = json_byte_len(detail).saturating_sub(metadata_budget);
    if excess == 0 {
        return truncated;
    }

    if let Some(lanes) = detail
        .get_mut("captureLanes")
        .and_then(Value::as_array_mut)
    {
        for lane in lanes {
            if let Some(timeline) = lane.get_mut("timeline").and_then(Value::as_array_mut) {
                if !timeline.is_empty() {
                    timeline.clear();
                    truncated = true;
                }
            }
        }
    }

    excess = json_byte_len(detail).saturating_sub(metadata_budget);
    if excess == 0 {
        return truncated;
    }

    if let Some(highlights) = detail.get_mut("highlights").and_then(Value::as_array_mut) {
        truncated |= trim_array_to_shed(highlights, &mut excess);
    }
    if excess > 0 {
        if let Some(summary) = detail.get_mut("summary").and_then(Value::as_array_mut) {
            for section in summary.iter_mut().rev() {
                if excess == 0 {
                    break;
                }
                if let Some(sources) = section.get_mut("sources").and_then(Value::as_array_mut) {
                    truncated |= trim_array_to_shed(sources, &mut excess);
                }
            }
            if excess > 0 {
                truncated |= trim_summary_sections_to_shed(summary, &mut excess);
            }
        }
    }
    if excess > 0 {
        if let Some(speakers) = detail.get_mut("speakers").and_then(Value::as_array_mut) {
            truncated |= trim_array_to_shed(speakers, &mut excess);
        }
    }
    if excess > 0 {
        if let Some(lanes) = detail
            .get_mut("captureLanes")
            .and_then(Value::as_array_mut)
        {
            truncated |= trim_array_to_shed(lanes, &mut excess);
        }
    }
    if excess > 0 {
        if let Some(obj) = detail.as_object_mut() {
            for key in ["title", "project"] {
                truncated |= truncate_string_field_to_shed(obj, key, &mut excess);
            }
        }
    }

    truncated
}

fn cap_single_segment_to_budget(mut segment: Value, remaining_budget: usize) -> Option<Value> {
    let obj = segment.as_object_mut()?;
    let original_text = obj
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    obj.insert("text".into(), Value::String(String::new()));
    if obj.get("originalText").is_some_and(Value::is_string) {
        obj.insert("originalText".into(), Value::Null);
    }
    let empty_len = serde_json::to_vec(&segment).ok()?.len();
    if empty_len > remaining_budget {
        return None;
    }
    let max_text_json_bytes = remaining_budget - empty_len + 2;
    let text =
        truncate_str_to_json_budget(&original_text, max_text_json_bytes).unwrap_or(original_text);
    if let Some(obj) = segment.as_object_mut() {
        obj.insert("text".into(), Value::String(text));
    }
    (serde_json::to_vec(&segment).ok()?.len() <= remaining_budget).then_some(segment)
}

fn paginate_record_detail(
    mut detail: Value,
    page: RecordSegmentPageRequest,
    byte_budget: usize,
) -> Value {
    let all_segments = detail
        .get_mut("segments")
        .and_then(Value::as_array_mut)
        .map(std::mem::take)
        .unwrap_or_default();
    if let Some(obj) = detail.as_object_mut() {
        obj.insert("segments".into(), Value::Array(Vec::new()));
    }
    let total_segments = all_segments.len();

    if !page.include_segments {
        let segments_truncated = total_segments > 0;
        let next_segment_offset = segments_truncated.then_some(0);
        set_pagination_fields(
            &mut detail,
            total_segments,
            0,
            segments_truncated,
            next_segment_offset,
            false,
        );
        if compact_metadata_to_budget(&mut detail, byte_budget) {
            if let Some(obj) = detail.as_object_mut() {
                obj.insert("metadataTruncated".into(), Value::Bool(true));
            }
        }
        return detail;
    }

    let start = page.offset.min(total_segments);
    let metadata_budget = if total_segments > 0 {
        byte_budget / 2
    } else {
        byte_budget
    };
    set_pagination_fields(
        &mut detail,
        total_segments,
        start,
        false,
        Some(total_segments.max(9_999)),
        false,
    );
    let metadata_truncated = compact_metadata_to_budget(&mut detail, metadata_budget);
    if metadata_truncated {
        if let Some(obj) = detail.as_object_mut() {
            obj.insert("metadataTruncated".into(), Value::Bool(true));
        }
    }

    let base_bytes = json_byte_len(&detail);
    let max_count = page.limit.unwrap_or(usize::MAX);
    let mut included = Vec::new();
    let mut used_bytes = base_bytes;
    let mut capped_single_segment = false;

    for segment in all_segments.into_iter().skip(start).take(max_count) {
        let sep = usize::from(!included.is_empty());
        let seg_bytes = json_byte_len(&segment);
        if used_bytes.saturating_add(sep).saturating_add(seg_bytes) <= byte_budget {
            used_bytes = used_bytes.saturating_add(sep).saturating_add(seg_bytes);
            included.push(segment);
            continue;
        }
        if included.is_empty() {
            let remaining = byte_budget.saturating_sub(base_bytes);
            if let Some(capped) = cap_single_segment_to_budget(segment, remaining) {
                included.push(capped);
                capped_single_segment = true;
            }
        }
        break;
    }

    let included_count = included.len();
    let has_more = start.saturating_add(included_count) < total_segments;
    let segments_truncated = has_more || capped_single_segment;
    let next_segment_offset =
        (has_more && included_count > 0).then_some(start.saturating_add(included_count));
    if let Some(obj) = detail.as_object_mut() {
        obj.insert("segments".into(), Value::Array(included));
    }
    set_pagination_fields(
        &mut detail,
        total_segments,
        start,
        segments_truncated,
        next_segment_offset,
        metadata_truncated,
    );
    detail
}

impl KoeRuntime {
    pub(super) fn is_mcp_read_tool(name: &str) -> bool {
        matches!(
            name,
            "search"
                | "get_today_brief"
                | "list_records"
                | "get_record"
                | "ask"
                | "list_review_items"
                | "device_status"
                | "poll_updates"
        )
    }

    pub(super) fn call_mcp_read_tool(
        &mut self,
        name: &str,
        obj: &Map<String, Value>,
        now: u64,
    ) -> Result<McpToolCallState, McpToolError> {
        match name {
            "search" => {
                ensure_allowed_keys(obj, &["query", "record_id", "limit"])?;
                let query = required_str(obj, "query")?;
                let scope = optional_scope(obj)?;
                let limit = optional_limit(obj, 10)?;
                if query.trim().is_empty() {
                    return Ok(McpToolCallState::Completed(Err("请输入搜索内容".into())));
                }
                let result = self
                    .workspace()
                    .search(&scope, query, limit)
                    .map(|evidence| {
                        json!({
                            "query": query,
                            "sources": evidence.iter().map(evidence_json).collect::<Vec<_>>()
                        })
                    })
                    .map_err(|e| e.to_string());
                Ok(McpToolCallState::Completed(result))
            }
            "get_today_brief" => {
                ensure_allowed_keys(obj, &[])?;
                let eff_now = if now > 0 { now } else { self.last_now_sec };
                let today = self.local_date(eff_now);
                let live_records: Vec<&ProductRecord> = self
                    .sorted_records()
                    .into_iter()
                    .filter(|r| r.is_live())
                    .collect();
                let live_count = live_records.len();
                let live_non_archived: Vec<&ProductRecord> = live_records
                    .iter()
                    .copied()
                    .filter(|r| !r.is_archived())
                    .collect();
                let today_record_ids: Vec<&str> = live_records
                    .iter()
                    .filter(|r| {
                        today.is_some_and(|t| {
                            self.local_date(r.aggregate.created_at_epoch_sec) == Some(t)
                        })
                    })
                    .map(|r| r.aggregate.recording_id.as_str())
                    .collect();
                let today_count = today_record_ids.len();
                let (live_record_id, live_duration_ms) = self.live_bean_capture_progress();
                let recent_records: Vec<Value> = live_non_archived
                    .iter()
                    .take(5)
                    .map(|r| self.live_record_row_json(r, live_record_id, live_duration_ms))
                    .collect();
                let (tasks, memories) = self.tasks_and_memories_json();
                let pending_tasks = tasks.iter().filter(|t| t["state"] == "proposed").count();
                let pending_memories = memories.iter().filter(|m| m["state"] == "proposed").count();
                let open_tasks = tasks
                    .iter()
                    .filter(|t| t["state"] == "accepted" && t["completed"] == Value::Bool(false))
                    .count();
                let accepted_memories =
                    memories.iter().filter(|m| m["state"] == "accepted").count();
                let device = self.device_json();
                Ok(McpToolCallState::Completed(Ok(json!({
                    "generation": self.generation,
                    "revision": self.workspace().revision(),
                    "todayRecordIds": today_record_ids,
                    "recentRecords": recent_records,
                    "counts": {
                        "liveRecords": live_count,
                        "todayRecords": today_count,
                        "pendingTasks": pending_tasks,
                        "pendingMemories": pending_memories,
                        "openTasks": open_tasks,
                        "acceptedMemories": accepted_memories
                    },
                    "device": {
                        "connected": device["connected"],
                        "phase": device["phase"],
                        "state": device["state"],
                        "deviceName": device["deviceName"],
                        "batteryPercent": device["batteryPercent"],
                        "boxBatteryPercent": device["boxBatteryPercent"],
                        "autoConnect": device["autoConnect"]
                    }
                }))))
            }
            "list_records" => {
                ensure_allowed_keys(
                    obj,
                    &[
                        "include_archived",
                        "include_trashed",
                        "origin",
                        "limit",
                        "offset",
                    ],
                )?;
                let include_archived = optional_bool(obj, "include_archived")?.unwrap_or(false);
                let include_trashed = optional_bool(obj, "include_trashed")?.unwrap_or(false);
                let origin_filter = match optional_str(obj, "origin")? {
                    None | Some("all") => None,
                    Some("microphone") => Some(RecordOrigin::Microphone),
                    Some("bean") => Some(RecordOrigin::Bean),
                    Some("imported_audio") => Some(RecordOrigin::ImportedAudio),
                    Some("imported_text") => Some(RecordOrigin::ImportedText),
                    Some("note") => Some(RecordOrigin::Note),
                    Some(_) => {
                        return Err(McpToolError::invalid_params("无效的 origin 过滤条件"));
                    }
                };
                let limit = optional_limit(obj, 20)?;
                let offset = optional_u64(obj, "offset")?.unwrap_or(0) as usize;

                let records = self.sorted_records();
                let filtered: Vec<_> = records
                    .into_iter()
                    .filter(|r| {
                        if r.is_trashed() {
                            return include_trashed;
                        }
                        if r.is_archived() && !include_archived {
                            return false;
                        }
                        origin_filter.is_none_or(|wanted| r.origin == wanted)
                    })
                    .collect();
                let total = filtered.len();
                let rows: Vec<Value> = filtered
                    .into_iter()
                    .skip(offset)
                    .take(limit)
                    .map(|record| {
                        let preview = record
                            .aggregate
                            .spine
                            .segments()
                            .first()
                            .map(|s| s.text.chars().take(100).collect::<String>())
                            .unwrap_or_default();
                        json!({
                            "id": record.aggregate.recording_id,
                            "title": record.title,
                            "createdAtEpochSec": record.aggregate.created_at_epoch_sec,
                            "durationMs": record.aggregate.duration_ms,
                            "origin": projection::origin_slug(record.origin),
                            "source": self.origin_label(record.origin),
                            "status": projection::status(record),
                            "segmentCount": record.aggregate.spine.len(),
                            "preview": preview,
                            "archived": record.is_archived(),
                            "trashed": record.is_trashed()
                        })
                    })
                    .collect();
                Ok(McpToolCallState::Completed(Ok(json!({
                    "total": total,
                    "offset": offset,
                    "limit": limit,
                    "records": rows
                }))))
            }
            "get_record" => {
                ensure_allowed_keys(
                    obj,
                    &[
                        "record_id",
                        "include_segments",
                        "segment_offset",
                        "segment_limit",
                    ],
                )?;
                let id = required_str(obj, "record_id")?;
                let page = parse_record_segment_page(obj)?;
                let result = self.record_detail_json(id).map(|detail| {
                    paginate_record_detail(detail, page, GET_RECORD_RESPONSE_BYTE_BUDGET)
                });
                Ok(McpToolCallState::Completed(result))
            }
            "ask" => {
                ensure_allowed_keys(obj, &["question", "record_id"])?;
                let question = required_str(obj, "question")?;
                let scope = optional_scope(obj)?;
                if question.trim().is_empty() {
                    return Ok(McpToolCallState::Completed(Err("请输入问题".into())));
                }
                if let Err(err) = self.prepare_mcp_write(now) {
                    return Ok(McpToolCallState::Completed(Err(err)));
                }
                let start_res = self.start_ask(scope, question, now);
                self.generation = self.generation.saturating_add(1);
                if let Err(err) = start_res {
                    self.set_error(err.clone());
                    return Ok(McpToolCallState::Completed(Err(err)));
                }
                match self.resolve_settled_ask() {
                    None => Ok(McpToolCallState::PendingAsk),
                    Some(done) => Ok(McpToolCallState::Completed(done)),
                }
            }
            "list_review_items" => {
                ensure_allowed_keys(obj, &["kind", "state"])?;
                let kind_filter = match optional_str(obj, "kind")? {
                    None | Some("all") => None,
                    Some("task") => Some(ItemKind::Task),
                    Some("memory") => Some(ItemKind::Memory),
                    Some(_) => return Err(McpToolError::invalid_params("无效的 kind 参数")),
                };
                let state_filter = match optional_str(obj, "state")? {
                    None | Some("all") => None,
                    Some("proposed") => Some(ReviewState::Proposed),
                    Some("accepted") => Some(ReviewState::Accepted),
                    Some("dismissed") => Some(ReviewState::Dismissed),
                    Some(_) => return Err(McpToolError::invalid_params("无效的 state 参数")),
                };
                let mut items = Vec::new();
                for item in self.workspace().items().values() {
                    if kind_filter.is_some_and(|wanted| item.kind != wanted) {
                        continue;
                    }
                    if state_filter.is_some_and(|wanted| item.review != wanted) {
                        continue;
                    }
                    let sources: Vec<Value> = item
                        .sources
                        .iter()
                        .filter_map(|s| self.source_json(s))
                        .collect();
                    if sources.is_empty() {
                        continue;
                    }
                    items.push(self.item_json(item, sources));
                }
                Ok(McpToolCallState::Completed(Ok(json!({ "items": items }))))
            }
            "device_status" => {
                ensure_allowed_keys(obj, &[])?;
                Ok(McpToolCallState::Completed(Ok(self.device_json())))
            }
            "poll_updates" => {
                ensure_allowed_keys(obj, &["since_generation", "since_revision"])?;
                let since_generation = optional_u64(obj, "since_generation")?;
                let since_revision = optional_u64(obj, "since_revision")?;
                let generation = self.generation();
                let revision = self.workspace().revision();
                let generation_reset = since_generation.is_some_and(|prev| prev > generation);
                let has_updates = generation_reset
                    || match (since_generation, since_revision) {
                        (None, None) => true,
                        (g, r) => {
                            g.is_some_and(|prev| generation > prev)
                                || r.is_some_and(|prev| revision > prev)
                        }
                    };
                let mut pending_jobs: Vec<Value> = self
                    .pending
                    .iter()
                    .map(|(op_id, work)| match work {
                        PendingWork::Transcription(key) => {
                            json!({"operationId": op_id, "kind": "transcription", "recordId": key.record_id})
                        }
                        PendingWork::Summary(key) | PendingWork::LiveSummary { key, .. } => {
                            json!({"operationId": op_id, "kind": "summary", "recordId": key.record_id})
                        }
                        PendingWork::Ask(op) => {
                            json!({"operationId": op_id, "kind": "ask", "askOperation": op})
                        }
                    })
                    .collect();
                pending_jobs.extend(self.active_local_speech_jobs().into_iter().map(|job| {
                    json!({
                        "operationId": job.operation_id,
                        "kind": "local_transcription",
                        "recordId": job.record_id,
                        "engine": job.engine
                    })
                }));
                let device = self.device_json();
                Ok(McpToolCallState::Completed(Ok(json!({
                    "generation": generation,
                    "revision": revision,
                    "hasUpdates": has_updates,
                    "generationReset": generation_reset,
                    "pendingJobs": pending_jobs,
                    "askInFlight": self.workspace().ask_session().in_flight,
                    "notice": self.notice,
                    "error": self.error_str(),
                    "device": {
                        "connected": device["connected"],
                        "phase": device["phase"],
                        "transferPhase": device["transferPhase"],
                        "batteryPercent": device["batteryPercent"],
                        "autoConnect": device["autoConnect"]
                    }
                }))))
            }
            _ => Err(McpToolError::invalid_params("未知工具")),
        }
    }

    /// Advances background timers for an in-flight MCP `ask` call and returns `Some` once settled.
    pub fn poll_mcp_ask(&mut self, elapsed_ms: u64, now: u64) -> Option<Result<Value, String>> {
        self.poll_timers(elapsed_ms, now);
        self.resolve_settled_ask()
    }

    pub(super) fn resolve_settled_ask(&self) -> Option<Result<Value, String>> {
        let phase = self.ask_phase();
        if phase == "pending" {
            return None;
        }
        if phase == "failed" {
            let reason = self
                .workspace()
                .ask_session()
                .messages
                .last()
                .filter(|m| m.status == koe_engine::context::AskStatus::Failed)
                .map(|m| m.text.trim())
                .filter(|s| !s.is_empty())
                .unwrap_or("问答处理失败，原始记录已保留")
                .to_string();
            return Some(Err(reason));
        }
        Some(Ok(self.ask_json()))
    }

    pub(super) fn item_json(&self, item: &SourcedItem, sources: Vec<Value>) -> Value {
        let state = match item.review {
            ReviewState::Proposed => "proposed",
            ReviewState::Accepted => "accepted",
            ReviewState::Dismissed => "dismissed",
        };
        let kind = match item.kind {
            ItemKind::Task => "task",
            ItemKind::Memory => "memory",
        };
        json!({
            "id": item.id,
            "kind": kind,
            "text": item.text,
            "state": state,
            "completed": item.completed,
            "due": item.due,
            "sources": sources
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use koe_engine::minutes::parse_meeting_minutes_json;
    use koe_engine::product::AnalysisStage;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    struct TempWorkspace(PathBuf);

    impl TempWorkspace {
        fn new() -> Self {
            static NEXT: AtomicU64 = AtomicU64::new(1);
            let path = std::env::temp_dir().join(format!(
                "koe-read-tools-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TempWorkspace {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn call_get_record(runtime: &mut KoeRuntime, args: Value, now: u64) -> Value {
        match runtime.call_mcp_tool_step("get_record", &args, now).unwrap() {
            McpToolCallState::Completed(Ok(value)) => value,
            other => panic!("get_record failed: {other:?}"),
        }
    }

    #[test]
    fn get_record_bounds_highlighted_and_cited_giant_utf8_segment_metadata() {
        const NOW: u64 = 1_800_000_000;
        let ws = TempWorkspace::new();
        let mut runtime = KoeRuntime::open(&ws.0).unwrap();
        let rec_id = "giant-highlighted-cited";
        let giant_text = "中".repeat(550_000);

        runtime
            .commit(|w| {
                w.insert_record(
                    rec_id.into(),
                    "Giant Cited".into(),
                    RecordOrigin::Note,
                    0,
                    NOW,
                    0,
                )?;
                w.append_transcript(rec_id, &giant_text, 0, 1_000, "manual")?;
                w.append_transcript(rec_id, "follow-up short segment", 1_000, 2_000, "manual")?;
                let key = w.begin_analysis(rec_id, AnalysisStage::Summarizing)?;
                let minutes = parse_meeting_minutes_json(
                    r#"{"schemaVersion":2,"title":"Giant Cited","overview":"关键纪要","topics":[{"text":"核心议题","summary":"引用了超长段落","sources":["S1"]}],"decisions":[],"actions":[],"questions":[],"terms":[],"reviewItems":[]}"#,
                    &w.record(rec_id).unwrap().aggregate.spine,
                )
                .unwrap();
                w.complete_summary(&key, minutes)
            })
            .unwrap();

        let _ = runtime
            .call_mcp_tool_step(
                "annotate_segment",
                &json!({
                    "record_id": rec_id,
                    "segment_id": "S1",
                    "kind": "highlight"
                }),
                NOW + 1,
            )
            .unwrap();

        let meta_only = call_get_record(
            &mut runtime,
            json!({"record_id": rec_id, "include_segments": false}),
            NOW + 2,
        );
        let meta_bytes = serde_json::to_vec(&meta_only).unwrap().len();
        assert!(
            meta_bytes <= GET_RECORD_RESPONSE_BYTE_BUDGET,
            "include_segments=false exceeded byte budget: {meta_bytes} > {GET_RECORD_RESPONSE_BYTE_BUDGET}"
        );
        assert_eq!(meta_only["metadataTruncated"], true);
        assert_eq!(meta_only["segments"], json!([]));
        assert_eq!(meta_only["totalSegments"], 2);
        assert_eq!(meta_only["segmentsTruncated"], true);
        assert_eq!(meta_only["nextSegmentOffset"], 0);
        assert_eq!(meta_only["highlights"].as_array().unwrap().len(), 1);
        let highlight_quote = meta_only["highlights"][0]["quote"].as_str().unwrap();
        assert!(highlight_quote.ends_with('…'));
        assert!(highlight_quote.len() < 1_024);
        let summary_quote = meta_only["summary"][1]["sources"][0]["quote"]
            .as_str()
            .unwrap();
        assert!(summary_quote.ends_with('…'));
        assert!(summary_quote.len() < 1_024);

        let page0 = call_get_record(
            &mut runtime,
            json!({"record_id": rec_id, "include_segments": true, "segment_offset": 0}),
            NOW + 3,
        );
        let page0_bytes = serde_json::to_vec(&page0).unwrap().len();
        assert!(
            page0_bytes <= GET_RECORD_RESPONSE_BYTE_BUDGET,
            "page 0 exceeded byte budget: {page0_bytes} > {GET_RECORD_RESPONSE_BYTE_BUDGET}"
        );
        assert_eq!(page0["metadataTruncated"], true);
        let segs0 = page0["segments"].as_array().unwrap();
        assert_eq!(segs0.len(), 1, "segment 0 must not be starved by metadata");
        assert_eq!(segs0[0]["id"], "S1");
        let seg0_text = segs0[0]["text"].as_str().unwrap();
        assert!(!seg0_text.is_empty());
        assert!(seg0_text.ends_with('…'));
        assert_eq!(page0["segmentsTruncated"], true);
        assert_eq!(page0["nextSegmentOffset"], 1);

        let page1 = call_get_record(
            &mut runtime,
            json!({"record_id": rec_id, "include_segments": true, "segment_offset": 1}),
            NOW + 4,
        );
        let page1_bytes = serde_json::to_vec(&page1).unwrap().len();
        assert!(page1_bytes <= GET_RECORD_RESPONSE_BYTE_BUDGET);
        assert_eq!(page1["metadataTruncated"], true);
        let segs1 = page1["segments"].as_array().unwrap();
        assert_eq!(segs1.len(), 1);
        assert_eq!(segs1[0]["id"], "S2");
        assert_eq!(segs1[0]["text"], "follow-up short segment");
        assert_eq!(page1["segmentsTruncated"], false);
        assert!(page1["nextSegmentOffset"].is_null());
    }

    #[test]
    fn paginate_record_detail_compacts_timeline_and_large_summary_under_budget() {
        let timeline: Vec<Value> = (0..500)
            .map(|i| {
                json!({
                    "epoch": 1,
                    "startNs": i * 20_000_000u64,
                    "sampleOffset": i * 320u64,
                    "sampleCount": 320
                })
            })
            .collect();
        let detail = json!({
            "id": "rec-dense",
            "title": "Dense Record",
            "segments": [
                {"id": "S1", "text": "hello world", "originalText": null, "isEdited": false, "startMs": 0, "endMs": 1000, "timed": true, "speaker": null}
            ],
            "captureLanes": [
                {
                    "lane": "bean",
                    "audioPath": "/tmp/bean.wav",
                    "sampleRate": 16000,
                    "durationMs": 10000,
                    "interruption": null,
                    "timeline": timeline
                }
            ],
            "summary": [
                {"title": "摘要", "text": "段".repeat(4_000), "sources": []}
            ],
            "highlights": []
        });

        let budget = 8_000;
        let meta_only = paginate_record_detail(
            detail.clone(),
            RecordSegmentPageRequest {
                include_segments: false,
                offset: 0,
                limit: None,
            },
            budget,
        );
        let meta_len = serde_json::to_vec(&meta_only).unwrap().len();
        assert!(meta_len <= budget, "meta_only exceeded budget: {meta_len}");
        assert_eq!(meta_only["metadataTruncated"], true);
        assert_eq!(meta_only["captureLanes"][0]["lane"], "bean");
        assert_eq!(meta_only["captureLanes"][0]["audioPath"], "/tmp/bean.wav");
        assert_eq!(meta_only["captureLanes"][0]["sampleRate"], 16000);
        assert_eq!(meta_only["captureLanes"][0]["durationMs"], 10000);
        assert_eq!(meta_only["captureLanes"][0]["timeline"], json!([]));
        assert!(meta_only["summary"][0]["text"].as_str().unwrap().ends_with('…'));

        let with_segments = paginate_record_detail(
            detail,
            RecordSegmentPageRequest {
                include_segments: true,
                offset: 0,
                limit: None,
            },
            budget,
        );
        let with_seg_len = serde_json::to_vec(&with_segments).unwrap().len();
        assert!(
            with_seg_len <= budget,
            "with_segments exceeded budget: {with_seg_len}"
        );
        assert_eq!(with_segments["metadataTruncated"], true);
        assert_eq!(with_segments["segments"].as_array().unwrap().len(), 1);
        assert_eq!(with_segments["segments"][0]["text"], "hello world");
        assert_eq!(with_segments["segmentsTruncated"], false);
        assert!(with_segments["nextSegmentOffset"].is_null());
    }

    #[test]
    fn paginate_record_detail_sets_metadata_truncated_false_when_within_budget() {
        let detail = json!({
            "id": "rec-normal",
            "title": "Normal",
            "segments": [
                {"id": "S1", "text": "short line", "originalText": null, "isEdited": false, "startMs": 0, "endMs": 500, "timed": true, "speaker": null}
            ],
            "captureLanes": [],
            "summary": [{"title": "摘要", "text": "简短总结", "sources": []}],
            "highlights": [{"recordId": "rec-normal", "segmentId": "S1", "title": "Normal", "quote": "short line", "startMs": 0}]
        });

        let out = paginate_record_detail(
            detail,
            RecordSegmentPageRequest {
                include_segments: true,
                offset: 0,
                limit: None,
            },
            GET_RECORD_RESPONSE_BYTE_BUDGET,
        );
        assert_eq!(out["metadataTruncated"], false);
        assert_eq!(out["highlights"][0]["quote"], "short line");
        assert_eq!(out["segments"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn paginate_record_detail_does_not_starve_segments_when_metadata_exceeds_budget() {
        let giant_quote = "汉".repeat(10_000);
        let detail = json!({
            "id": "rec-starve",
            "title": "Starvation Check",
            "segments": [
                {"id": "S1", "text": "中".repeat(8_000), "originalText": null, "isEdited": false, "startMs": 0, "endMs": 1000, "timed": true, "speaker": null},
                {"id": "S2", "text": "tail", "originalText": null, "isEdited": false, "startMs": 1000, "endMs": 2000, "timed": true, "speaker": null}
            ],
            "captureLanes": [],
            "summary": [
                {
                    "title": "摘要",
                    "text": "概述",
                    "sources": [
                        {"recordId": "rec-starve", "segmentId": "S1", "title": "Starvation Check", "quote": giant_quote, "startMs": 0}
                    ]
                }
            ],
            "highlights": [
                {"recordId": "rec-starve", "segmentId": "S1", "title": "Starvation Check", "quote": giant_quote, "startMs": 0}
            ]
        });

        let budget = 8_000;
        let page0 = paginate_record_detail(
            detail,
            RecordSegmentPageRequest {
                include_segments: true,
                offset: 0,
                limit: None,
            },
            budget,
        );
        let segs = page0["segments"].as_array().unwrap();
        assert_eq!(
            segs.len(),
            1,
            "segment 0 starved: segments={segs:?}, nextSegmentOffset={}",
            page0["nextSegmentOffset"]
        );
        assert_eq!(segs[0]["id"], "S1");
        assert!(segs[0]["text"].as_str().unwrap().ends_with('…'));
        assert_eq!(page0["segmentsTruncated"], true);
        assert_eq!(page0["nextSegmentOffset"], 1);
        assert_eq!(page0["metadataTruncated"], true);
        let encoded = serde_json::to_vec(&page0).unwrap().len();
        assert!(encoded <= budget, "page0 exceeded budget: {encoded} > {budget}");
    }

    #[test]
    fn paginate_record_detail_trims_huge_highlights_sources_and_sections_under_budget() {
        let highlights: Vec<Value> = (0..400)
            .map(|i| {
                json!({
                    "recordId": "rec-many",
                    "segmentId": format!("S{}", i + 1),
                    "title": "Many",
                    "quote": format!("excerpt-{i:04}-{}", "a".repeat(80)),
                    "startMs": i as u64 * 1000
                })
            })
            .collect();
        let summary_sources: Vec<Value> = (0..400)
            .map(|i| {
                json!({
                    "recordId": "rec-many",
                    "segmentId": format!("S{}", i + 1),
                    "title": "Many",
                    "quote": format!("src-{i:04}-{}", "b".repeat(80)),
                    "startMs": i as u64 * 1000
                })
            })
            .collect();
        let summary: Vec<Value> = (0..50)
            .map(|i| {
                json!({
                    "title": format!("议题 {i}"),
                    "text": "议".repeat(200),
                    "sources": if i == 0 { summary_sources.clone() } else { vec![] }
                })
            })
            .collect();
        let detail = json!({
            "id": "rec-many",
            "title": "Many Metadata Entries",
            "segments": [
                {"id": "S1", "text": "first segment", "originalText": null, "isEdited": false, "startMs": 0, "endMs": 500, "timed": true, "speaker": null}
            ],
            "captureLanes": [],
            "summary": summary,
            "highlights": highlights
        });

        let budget = 8_000;
        let out = paginate_record_detail(
            detail,
            RecordSegmentPageRequest {
                include_segments: true,
                offset: 0,
                limit: None,
            },
            budget,
        );
        let encoded = serde_json::to_vec(&out).unwrap().len();
        assert!(encoded <= budget, "exceeded budget: {encoded} > {budget}");
        assert_eq!(out["metadataTruncated"], true);
        assert_eq!(out["segments"].as_array().unwrap().len(), 1);
        assert_eq!(out["segments"][0]["text"], "first segment");
    }
}
