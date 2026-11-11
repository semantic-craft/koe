use serde_json::{json, Map, Value};

use super::*;

/// JSON-RPC parameter or tool-routing error returned before domain execution.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpToolError {
    /// Standard JSON-RPC error code (such as `-32602` for invalid params).
    pub code: i64,
    /// Human-readable error message.
    pub message: String,
}

impl McpToolError {
    fn invalid_params(message: impl Into<String>) -> Self {
        Self {
            code: -32602,
            message: message.into(),
        }
    }
}

/// Step result returned by [`KoeRuntime::call_mcp_tool_step`].
#[derive(Debug, Clone)]
pub enum McpToolCallState {
    /// Synchronous tool completion (`Ok(payload)` or `Err(domain_error)` mapped to `isError: true`).
    Completed(Result<Value, String>),
    /// Asynchronous `ask` job submitted; poll with [`KoeRuntime::poll_mcp_ask`] until `Some`.
    PendingAsk {
        /// Original question string submitted by the caller.
        question: String,
    },
}

impl KoeRuntime {
    /// Returns the canonical 16-tool MCP schema array exposed by Koe.
    #[must_use]
    pub fn mcp_tool_definitions() -> Vec<Value> {
        vec![
            json!({
                "name": "search",
                "description": "全库或单条记录 BM25 检索，返回原文引用与时间戳。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "query": { "type": "string" },
                        "record_id": { "type": "string" },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 100 }
                    },
                    "required": ["query"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
            json!({
                "name": "get_today_brief",
                "description": "读取「今天」视图摘要、近期记录、待审核数量与录音豆伴侣状态。",
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
            json!({
                "name": "list_records",
                "description": "按归档、回收站状态与来源类型分页列出记录元数据。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "include_archived": { "type": "boolean" },
                        "include_trashed": { "type": "boolean" },
                        "origin": {
                            "type": "string",
                            "enum": ["all", "microphone", "bean", "imported_audio", "imported_text", "note"]
                        },
                        "limit": { "type": "integer", "minimum": 1, "maximum": 100 },
                        "offset": { "type": "integer", "minimum": 0 }
                    },
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
            json!({
                "name": "get_record",
                "description": "读取指定记录的完整转写段落、说话人、纪要、高亮重点与来源证据。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "record_id": { "type": "string" }
                    },
                    "required": ["record_id"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
            json!({
                "name": "ask",
                "description": "基于全库或指定记录提问并保留问答历史；未配置模型时返回本地检索来源。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "question": { "type": "string" },
                        "record_id": { "type": "string" }
                    },
                    "required": ["question"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "list_review_items",
                "description": "列出待审核或已生效的待办事项与个人记忆条目。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "kind": { "type": "string", "enum": ["all", "task", "memory"] },
                        "state": { "type": "string", "enum": ["all", "proposed", "accepted", "dismissed"] }
                    },
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
            json!({
                "name": "review_item",
                "description": "审核通过、忽略或重置待办与记忆候选条目。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "item_id": { "type": "string" },
                        "decision": { "type": "string", "enum": ["accept", "dismiss", "reset"] }
                    },
                    "required": ["item_id", "decision"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "complete_task",
                "description": "勾选完成或重新打开一条已确认的待办事项。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "item_id": { "type": "string" },
                        "completed": { "type": "boolean" }
                    },
                    "required": ["item_id", "completed"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "edit_item",
                "description": "修改待办或记忆条目的正文与截止日期。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "item_id": { "type": "string" },
                        "text": { "type": "string" },
                        "due": { "type": ["string", "null"] }
                    },
                    "required": ["item_id", "text"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "create_note",
                "description": "直接写入一条纯文本速记或外部 AI 汇总笔记到 Koe 工作区。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "title": { "type": "string" },
                        "text": { "type": "string" }
                    },
                    "required": ["title", "text"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "annotate_segment",
                "description": "从指定转写段落生成高亮重点、待办事项或个人记忆。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "record_id": { "type": "string" },
                        "segment_id": { "type": "string" },
                        "kind": { "type": "string", "enum": ["highlight", "task", "memory"] }
                    },
                    "required": ["record_id", "segment_id", "kind"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "edit_transcript",
                "description": "修正单段转写文字、设置单段说话人或批量重命名整条记录中的说话人。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "record_id": { "type": "string" },
                        "action": { "type": "string", "enum": ["edit_segment", "set_speaker", "rename_speaker"] },
                        "segment_id": { "type": "string" },
                        "text": { "type": "string" },
                        "speaker": { "type": ["string", "null"] },
                        "from_speaker": { "type": "string" },
                        "to_speaker": { "type": "string" }
                    },
                    "required": ["record_id", "action"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "manage_record",
                "description": "重命名、归档、取消归档、移入回收站、恢复记录，或触发转写与纪要重算（不含永久清除）。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "record_id": { "type": "string" },
                        "action": {
                            "type": "string",
                            "enum": ["rename", "archive", "unarchive", "trash", "restore", "transcribe", "summarize"]
                        },
                        "title": { "type": "string" }
                    },
                    "required": ["record_id", "action"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "device_status",
                "description": "读取 D3200 录音豆在线状态、电量、固件、存储、目录文件、同步进度与伴侣待命状态。",
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
            json!({
                "name": "device_control",
                "description": "控制录音豆开始/停止录音、下载指定文件、刷新状态、断开或释放蓝牙控制权，以及切换自动重连与伴侣模式。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": [
                                "start_recording",
                                "stop_recording",
                                "download_file",
                                "disconnect",
                                "release_ble",
                                "set_auto_connect",
                                "set_companion_mode",
                                "refresh"
                            ]
                        },
                        "file_id": { "type": "integer", "minimum": 1 },
                        "enabled": { "type": "boolean" },
                        "mode": { "type": "string", "enum": ["disabled", "collar_standby", "meeting_and_collar"] }
                    },
                    "required": ["action"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "poll_updates",
                "description": "轮询工作区代次、修订号、后台转写/纪要/问答任务进度以及设备与领夹麦待命变更。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "since_generation": { "type": "integer", "minimum": 0 },
                        "since_revision": { "type": "integer", "minimum": 0 }
                    },
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
        ]
    }

    /// Returns the JSON-RPC `tools/list` result payload (`{"tools": [...]}`).
    #[must_use]
    pub fn mcp_tools_list() -> Value {
        json!({ "tools": Self::mcp_tool_definitions() })
    }

    /// Validates and executes a single MCP tool call step without blocking on network I/O.
    pub fn call_mcp_tool_step(
        &mut self,
        name: &str,
        args: &Value,
        now: u64,
    ) -> Result<McpToolCallState, McpToolError> {
        let obj = args
            .as_object()
            .ok_or_else(|| McpToolError::invalid_params("工具参数必须是对象"))?;
        self.poll_timers(0, now);

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
                let snap = self.snapshot(now);
                let recent_records: Vec<Value> = snap["records"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|r| r["archived"] != Value::Bool(true))
                    .take(5)
                    .cloned()
                    .collect();
                let live_count = snap["records"].as_array().map_or(0, Vec::len);
                let today_count = snap["todayRecordIds"].as_array().map_or(0, Vec::len);
                let tasks = snap["tasks"].as_array().cloned().unwrap_or_default();
                let memories = snap["memories"].as_array().cloned().unwrap_or_default();
                let pending_tasks = tasks.iter().filter(|t| t["state"] == "proposed").count();
                let pending_memories = memories.iter().filter(|m| m["state"] == "proposed").count();
                let open_tasks = tasks
                    .iter()
                    .filter(|t| t["state"] == "accepted" && t["completed"] == Value::Bool(false))
                    .count();
                let accepted_memories =
                    memories.iter().filter(|m| m["state"] == "accepted").count();
                Ok(McpToolCallState::Completed(Ok(json!({
                    "generation": snap["generation"],
                    "revision": self.workspace().revision(),
                    "todayRecordIds": snap["todayRecordIds"],
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
                        "connected": snap["device"]["connected"],
                        "phase": snap["device"]["phase"],
                        "state": snap["device"]["state"],
                        "deviceName": snap["device"]["deviceName"],
                        "batteryPercent": snap["device"]["batteryPercent"],
                        "boxBatteryPercent": snap["device"]["boxBatteryPercent"],
                        "autoConnect": snap["device"]["autoConnect"],
                        "companionMode": snap["device"]["companionMode"],
                        "standbyReady": snap["device"]["standbyReady"]
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

                let mut records: Vec<_> = self.workspace().records().values().collect();
                records.sort_by_key(|r| {
                    std::cmp::Reverse((
                        r.aggregate.created_at_epoch_sec,
                        r.aggregate.recording_id.clone(),
                    ))
                });
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
                            "source": projection::origin(record.origin),
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
                let question = required_str(obj, "question")?.to_string();
                let scope = optional_scope(obj)?;
                if question.trim().is_empty() {
                    return Ok(McpToolCallState::Completed(Err("请输入问题".into())));
                }
                if let Err(err) = self.prepare_mcp_write(now) {
                    return Ok(McpToolCallState::Completed(Err(err)));
                }
                let start_res = self.start_ask(scope, &question, now);
                self.generation = self.generation.saturating_add(1);
                if let Err(err) = start_res {
                    self.error = Some(err.clone());
                    return Ok(McpToolCallState::Completed(Err(err)));
                }
                let snap = self.snapshot(now);
                if snap["ask"]["phase"] == "pending" {
                    return Ok(McpToolCallState::PendingAsk { question });
                }
                if let Some(error) = snap["error"].as_str() {
                    return Ok(McpToolCallState::Completed(Err(error.to_string())));
                }
                if snap["ask"]["phase"] == "failed" {
                    return Ok(McpToolCallState::Completed(Err(
                        "问答处理失败，原始记录已保留".into(),
                    )));
                }
                Ok(McpToolCallState::Completed(Ok(snap["ask"].clone())))
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
            "review_item" => {
                ensure_allowed_keys(obj, &["item_id", "decision"])?;
                let item_id = required_str(obj, "item_id")?.to_string();
                let decision = required_str(obj, "decision")?.to_string();
                if !matches!(decision.as_str(), "accept" | "dismiss" | "reset") {
                    return Err(McpToolError::invalid_params("无效的 decision 参数"));
                }
                let result = self
                    .run_mcp_command(
                        Command::ReviewItem {
                            item_id: item_id.clone(),
                            decision: decision.clone(),
                        },
                        now,
                    )
                    .map(|()| {
                        json!({
                            "ok": true,
                            "itemId": item_id,
                            "decision": decision,
                            "generation": self.generation
                        })
                    });
                Ok(McpToolCallState::Completed(result))
            }
            "complete_task" => {
                ensure_allowed_keys(obj, &["item_id", "completed"])?;
                let item_id = required_str(obj, "item_id")?.to_string();
                let completed = required_bool(obj, "completed")?;
                let result = self
                    .run_mcp_command(
                        Command::CompleteTask {
                            item_id: item_id.clone(),
                            completed,
                        },
                        now,
                    )
                    .map(|()| {
                        json!({
                            "ok": true,
                            "itemId": item_id,
                            "completed": completed,
                            "generation": self.generation
                        })
                    });
                Ok(McpToolCallState::Completed(result))
            }
            "edit_item" => {
                ensure_allowed_keys(obj, &["item_id", "text", "due"])?;
                let item_id = required_str(obj, "item_id")?.to_string();
                let text = required_str(obj, "text")?.to_string();
                let due = optional_nullable_string(obj, "due")?;
                let result = self
                    .run_mcp_command(
                        Command::EditItem {
                            item_id: item_id.clone(),
                            text,
                            due,
                        },
                        now,
                    )
                    .map(|()| {
                        json!({
                            "ok": true,
                            "itemId": item_id,
                            "generation": self.generation
                        })
                    });
                Ok(McpToolCallState::Completed(result))
            }
            "create_note" => {
                ensure_allowed_keys(obj, &["title", "text"])?;
                let title = required_str(obj, "title")?.to_string();
                let text = required_str(obj, "text")?.to_string();
                let result = self.mcp_create_note(title, &text, now);
                Ok(McpToolCallState::Completed(result))
            }
            "annotate_segment" => {
                ensure_allowed_keys(obj, &["record_id", "segment_id", "kind"])?;
                let record_id = required_str(obj, "record_id")?.to_string();
                let segment_id = required_str(obj, "segment_id")?.to_string();
                let kind = required_str(obj, "kind")?;
                if !matches!(kind, "highlight" | "task" | "memory") {
                    return Err(McpToolError::invalid_params("无效的 kind 参数"));
                }
                let result = self.mcp_annotate_segment(&record_id, &segment_id, kind, now);
                Ok(McpToolCallState::Completed(result))
            }
            "edit_transcript" => {
                ensure_allowed_keys(
                    obj,
                    &[
                        "record_id",
                        "action",
                        "segment_id",
                        "text",
                        "speaker",
                        "from_speaker",
                        "to_speaker",
                    ],
                )?;
                let record_id = required_str(obj, "record_id")?.to_string();
                let action = required_str(obj, "action")?;
                match action {
                    "edit_segment" => {
                        let segment_id = required_str(obj, "segment_id")?.to_string();
                        let text = required_str(obj, "text")?.to_string();
                        let result = self
                            .run_mcp_command(
                                Command::EditSegmentText {
                                    record_id: record_id.clone(),
                                    segment_id: segment_id.clone(),
                                    text,
                                },
                                now,
                            )
                            .map(|()| {
                                json!({
                                    "ok": true,
                                    "action": "edit_segment",
                                    "recordId": record_id,
                                    "segmentId": segment_id,
                                    "generation": self.generation
                                })
                            });
                        Ok(McpToolCallState::Completed(result))
                    }
                    "set_speaker" => {
                        let segment_id = required_str(obj, "segment_id")?.to_string();
                        let speaker = optional_nullable_string(obj, "speaker")?;
                        let result = self
                            .run_mcp_command(
                                Command::SetSegmentSpeaker {
                                    record_id: record_id.clone(),
                                    segment_id: segment_id.clone(),
                                    speaker,
                                },
                                now,
                            )
                            .map(|()| {
                                json!({
                                    "ok": true,
                                    "action": "set_speaker",
                                    "recordId": record_id,
                                    "segmentId": segment_id,
                                    "generation": self.generation
                                })
                            });
                        Ok(McpToolCallState::Completed(result))
                    }
                    "rename_speaker" => {
                        let from_speaker = required_str(obj, "from_speaker")?.to_string();
                        let to_speaker = required_str(obj, "to_speaker")?.to_string();
                        let result =
                            self.mcp_rename_speaker(&record_id, &from_speaker, &to_speaker, now);
                        Ok(McpToolCallState::Completed(result))
                    }
                    _ => Err(McpToolError::invalid_params("无效的 edit_transcript action")),
                }
            }
            "manage_record" => {
                ensure_allowed_keys(obj, &["record_id", "action", "title"])?;
                let record_id = required_str(obj, "record_id")?.to_string();
                let action = required_str(obj, "action")?;
                let command = match action {
                    "rename" => Command::RenameRecord {
                        record_id: record_id.clone(),
                        title: required_str(obj, "title")?.to_string(),
                    },
                    "archive" => Command::SetRecordArchived {
                        record_id: record_id.clone(),
                        archived: true,
                    },
                    "unarchive" => Command::SetRecordArchived {
                        record_id: record_id.clone(),
                        archived: false,
                    },
                    "trash" => Command::TrashRecord {
                        record_id: record_id.clone(),
                    },
                    "restore" => Command::RestoreRecord {
                        record_id: record_id.clone(),
                    },
                    "transcribe" => Command::Transcribe {
                        record_id: record_id.clone(),
                    },
                    "summarize" => Command::Summarize {
                        record_id: record_id.clone(),
                    },
                    "purge" | "empty_trash" => {
                        return Err(McpToolError::invalid_params(
                            "永久删除操作未对 MCP 开放，请在 Koe 应用内确认执行",
                        ));
                    }
                    _ => return Err(McpToolError::invalid_params("无效的 manage_record action")),
                };
                let result = self.run_mcp_command(command, now).map(|()| {
                    json!({
                        "ok": true,
                        "recordId": record_id,
                        "action": action,
                        "generation": self.generation
                    })
                });
                Ok(McpToolCallState::Completed(result))
            }
            "device_status" => {
                ensure_allowed_keys(obj, &[])?;
                let mut device = self.snapshot(now)["device"].clone();
                if let Some(map) = device.as_object_mut() {
                    map.insert(
                        "hardwareRecordingState".to_string(),
                        json!(self.current_companion_recording_state()),
                    );
                    map.insert("epoch".to_string(), json!(self.companion.epoch));
                }
                Ok(McpToolCallState::Completed(Ok(device)))
            }
            "device_control" => {
                ensure_allowed_keys(obj, &["action", "file_id", "enabled", "mode"])?;
                let action = required_str(obj, "action")?;
                let command = match action {
                    "start_recording" => Command::DeviceStart,
                    "stop_recording" => Command::DeviceStop,
                    "download_file" => {
                        let raw = optional_u64(obj, "file_id")?
                            .ok_or_else(|| McpToolError::invalid_params("缺少 file_id"))?;
                        let file_id = u32::try_from(raw)
                            .ok()
                            .filter(|&id| id > 0)
                            .ok_or_else(|| McpToolError::invalid_params("无效的 file_id"))?;
                        Command::DeviceDownload { file_id }
                    }
                    "disconnect" => Command::DeviceDisconnect,
                    "release_ble" => Command::DeviceRelease,
                    "set_auto_connect" => Command::SetBleAutoConnect {
                        enabled: required_bool(obj, "enabled")?,
                    },
                    "set_companion_mode" => {
                        let mode = required_str(obj, "mode")?.to_string();
                        if CompanionRoutingMode::parse(&mode).is_none() {
                            return Err(McpToolError::invalid_params("无效的领夹麦伴侣模式"));
                        }
                        Command::SetCompanionMode { mode }
                    }
                    "refresh" => Command::DeviceRefresh,
                    _ => return Err(McpToolError::invalid_params("无效的 device_control action")),
                };
                let result = self.run_mcp_command(command, now).map(|()| {
                    let snap = self.snapshot(now);
                    json!({
                        "ok": true,
                        "action": action,
                        "generation": self.generation,
                        "device": snap["device"]
                    })
                });
                Ok(McpToolCallState::Completed(result))
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
                        PendingWork::Summary(key) => {
                            json!({"operationId": op_id, "kind": "summary", "recordId": key.record_id})
                        }
                        PendingWork::Ask(op) => {
                            json!({"operationId": op_id, "kind": "ask", "askOperation": op})
                        }
                    })
                    .collect();
                let snap = self.snapshot(now);
                Ok(McpToolCallState::Completed(Ok(json!({
                    "generation": generation,
                    "revision": revision,
                    "hasUpdates": has_updates,
                    "pendingJobs": pending_jobs,
                    "askInFlight": self.workspace().ask_session().in_flight,
                    "notice": self.notice,
                    "error": self.error,
                    "device": {
                        "connected": self.device.is_connected(),
                        "phase": snap["device"]["phase"],
                        "transferPhase": snap["device"]["transferPhase"],
                        "batteryPercent": snap["device"]["batteryPercent"],
                        "autoConnect": self.workspace().ble_auto_connect(),
                        "companionMode": self.workspace().companion_mode().as_str(),
                        "standbyReady": self.is_standby_ready()
                    }
                }))))
            }
            _ => Err(McpToolError::invalid_params("未知工具")),
        }
    }

    /// Advances background timers for an in-flight MCP `ask` call and returns `Some` once settled.
    pub fn poll_mcp_ask(
        &mut self,
        _question: &str,
        elapsed_ms: u64,
        now: u64,
    ) -> Option<Result<Value, String>> {
        self.poll_timers(elapsed_ms, now);
        let snapshot = self.snapshot(now);
        if snapshot["ask"]["phase"] == "pending" {
            return None;
        }
        if let Some(error) = snapshot["error"].as_str() {
            return Some(Err(error.to_string()));
        }
        if snapshot["ask"]["phase"] == "failed" {
            return Some(Err("问答处理失败，原始记录已保留".into()));
        }
        Some(Ok(snapshot["ask"].clone()))
    }

    fn prepare_mcp_write(&mut self, now: u64) -> Result<(), String> {
        if now > 0 {
            self.last_now_sec = now;
        }
        if self.is_quitting() {
            return Err("正在退出，请先取消退出再开始新操作".into());
        }
        self.error = None;
        self.notice = None;
        self.reconcile_expired_trash(now);
        Ok(())
    }

    fn run_mcp_command(&mut self, command: Command, now: u64) -> Result<(), String> {
        self.error = None;
        self.notice = None;
        let result = self.dispatch(command, now);
        if let Err(error) = &result {
            self.error = Some(error.clone());
        }
        self.generation = self.generation.saturating_add(1);
        result
    }

    fn mcp_create_note(&mut self, title: String, text: &str, now: u64) -> Result<Value, String> {
        self.prepare_mcp_write(now)?;
        if text.trim().is_empty() {
            let err = "先写下一段内容".to_string();
            self.error = Some(err.clone());
            self.generation = self.generation.saturating_add(1);
            return Err(err);
        }
        let id = format!("note-{now}-{}", self.workspace().revision() + 1);
        let commit_res = self.commit(|workspace| {
            workspace.insert_record(id.clone(), title, RecordOrigin::Note, 0, now, 0)?;
            for paragraph in text.lines().map(str::trim).filter(|v| !v.is_empty()) {
                workspace.append_transcript(&id, paragraph, 0, 0, "manual")?;
            }
            Ok(())
        });
        self.generation = self.generation.saturating_add(1);
        if let Err(error) = commit_res {
            self.error = Some(error.clone());
            return Err(error);
        }
        self.notice = Some("记录已保存".into());
        self.record_detail_json(&id)
    }

    fn mcp_annotate_segment(
        &mut self,
        record_id: &str,
        segment_id: &str,
        kind: &str,
        now: u64,
    ) -> Result<Value, String> {
        self.prepare_mcp_write(now)?;
        let source = match source_ref(record_id, segment_id) {
            Ok(source) => source,
            Err(error) => {
                self.error = Some(error.clone());
                self.generation = self.generation.saturating_add(1);
                return Err(error);
            }
        };
        let result = match kind {
            "highlight" => self.commit(|w| w.add_highlight(source)).map(|()| {
                json!({
                    "ok": true,
                    "kind": "highlight",
                    "recordId": record_id,
                    "segmentId": segment_id
                })
            }),
            "task" | "memory" => {
                let item_kind = if kind == "task" {
                    ItemKind::Task
                } else {
                    ItemKind::Memory
                };
                self.commit(|w| {
                    let evidence = w.resolve_live_source(&source)?;
                    let id = w.propose_item(item_kind, &evidence.quote, vec![source])?;
                    w.review_item(&id, ReviewDecision::Accept)?;
                    Ok(id)
                })
                .map(|item_id| {
                    self.notice = Some("已保存，可从来源返回原文".into());
                    json!({
                        "ok": true,
                        "kind": kind,
                        "itemId": item_id,
                        "recordId": record_id,
                        "segmentId": segment_id
                    })
                })
            }
            _ => unreachable!(),
        };
        self.generation = self.generation.saturating_add(1);
        if let Err(error) = &result {
            self.error = Some(error.clone());
        } else if let Some(obj) = result.as_ref().ok().and_then(Value::as_object) {
            let mut enriched = obj.clone();
            enriched.insert("generation".to_string(), json!(self.generation));
            return Ok(Value::Object(enriched));
        }
        result
    }

    fn mcp_rename_speaker(
        &mut self,
        record_id: &str,
        from_speaker: &str,
        to_speaker: &str,
        now: u64,
    ) -> Result<Value, String> {
        self.prepare_mcp_write(now)?;
        let res: Result<TranscriptEditReceipt, String> = (|| {
            self.ensure_record_editable(record_id)?;
            let target = SpeakerName::parse(to_speaker).map_err(|e| e.to_string())?;
            let receipt =
                self.commit(|w| w.rename_speaker(record_id, from_speaker, target.as_str()))?;
            if receipt.updated_segments > 0 {
                let _ = self.reclaim_stale_summaries();
                self.drive_analysis_queue();
                self.notice = Some(format!(
                    "已将 {} 段说话人更新为 {}",
                    receipt.updated_segments,
                    target.as_str()
                ));
            }
            Ok(receipt)
        })();
        self.generation = self.generation.saturating_add(1);
        match res {
            Ok(receipt) => Ok(json!({
                "ok": true,
                "action": "rename_speaker",
                "recordId": record_id,
                "updatedSegments": receipt.updated_segments,
                "generation": self.generation
            })),
            Err(error) => {
                self.error = Some(error.clone());
                Err(error)
            }
        }
    }

    fn item_json(&self, item: &SourcedItem, sources: Vec<Value>) -> Value {
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

fn ensure_allowed_keys(obj: &Map<String, Value>, allowed: &[&str]) -> Result<(), McpToolError> {
    if obj.keys().any(|key| !allowed.contains(&key.as_str())) {
        return Err(McpToolError::invalid_params("工具参数包含未知字段"));
    }
    Ok(())
}

fn required_str<'a>(obj: &'a Map<String, Value>, key: &str) -> Result<&'a str, McpToolError> {
    obj.get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| McpToolError::invalid_params(format!("{key} 必须是字符串")))
}

fn optional_str<'a>(
    obj: &'a Map<String, Value>,
    key: &str,
) -> Result<Option<&'a str>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.as_str())),
        Some(_) => Err(McpToolError::invalid_params(format!("{key} 必须是字符串"))),
    }
}

fn optional_nullable_string(
    obj: &Map<String, Value>,
    key: &str,
) -> Result<Option<String>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(McpToolError::invalid_params(format!(
            "{key} 必须是字符串或 null"
        ))),
    }
}

fn required_bool(obj: &Map<String, Value>, key: &str) -> Result<bool, McpToolError> {
    obj.get(key)
        .and_then(Value::as_bool)
        .ok_or_else(|| McpToolError::invalid_params(format!("{key} 必须是布尔值")))
}

fn optional_bool(obj: &Map<String, Value>, key: &str) -> Result<Option<bool>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(value)) => Ok(Some(*value)),
        Some(_) => Err(McpToolError::invalid_params(format!("{key} 必须是布尔值"))),
    }
}

fn optional_u64(obj: &Map<String, Value>, key: &str) -> Result<Option<u64>, McpToolError> {
    match obj.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .map(Some)
            .ok_or_else(|| McpToolError::invalid_params(format!("{key} 必须是非负整数"))),
    }
}

fn optional_limit(obj: &Map<String, Value>, default_limit: usize) -> Result<usize, McpToolError> {
    match optional_u64(obj, "limit")? {
        None => Ok(default_limit),
        Some(n) if (1..=100).contains(&n) => Ok(n as usize),
        Some(_) => Err(McpToolError::invalid_params("limit 必须在 1 到 100 之间")),
    }
}

fn optional_scope(obj: &Map<String, Value>) -> Result<SearchScope, McpToolError> {
    match obj.get("record_id") {
        None | Some(Value::Null) => Ok(SearchScope::All),
        Some(Value::String(id)) => Ok(SearchScope::Record(id.clone())),
        Some(_) => Err(McpToolError::invalid_params("record_id 必须是字符串")),
    }
}

fn evidence_json(evidence: &Evidence) -> Value {
    json!({
        "recordId": evidence.source.record_id,
        "segmentId": evidence.source.segment_id.to_string(),
        "title": evidence.title,
        "quote": evidence.quote,
        "startMs": evidence.start_ms
    })
}
