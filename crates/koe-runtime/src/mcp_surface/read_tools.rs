use serde_json::{json, Map, Value};

use super::blocking::{
    ensure_allowed_keys, evidence_json, optional_bool, optional_limit, optional_scope,
    optional_str, optional_u64, required_str,
};
use super::{McpToolCallState, McpToolError};
use crate::*;
use koe_engine::product::{ItemKind, ReviewState, SourcedItem};

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
                let today = crate::projection::local_date(eff_now);
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
                            crate::projection::local_date(r.aggregate.created_at_epoch_sec)
                                == Some(t)
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
                ensure_allowed_keys(obj, &["record_id"])?;
                let id = required_str(obj, "record_id")?;
                Ok(McpToolCallState::Completed(self.record_detail_json(id)))
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
                let has_updates = match (since_generation, since_revision) {
                    (None, None) => true,
                    (g, r) => {
                        g.is_some_and(|prev| generation > prev)
                            || r.is_some_and(|prev| revision > prev)
                    }
                };
                let pending_jobs: Vec<Value> = self
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
                let device = self.device_json();
                Ok(McpToolCallState::Completed(Ok(json!({
                    "generation": generation,
                    "revision": revision,
                    "hasUpdates": has_updates,
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
