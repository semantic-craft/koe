use serde_json::{json, Map, Value};

use super::blocking::{
    ensure_allowed_keys, optional_nullable_string, optional_u64, required_bool, required_str,
};
use super::{McpToolCallState, McpToolError};
use crate::command::{AdapterEvent, DispatchMessage, HostIntent};
use crate::*;
use koe_engine::product::ItemKind;

impl KoeRuntime {
    pub(super) fn call_mcp_write_tool(
        &mut self,
        name: &str,
        obj: &Map<String, Value>,
        now: u64,
    ) -> Result<McpToolCallState, McpToolError> {
        match name {
            "review_item" => {
                ensure_allowed_keys(obj, &["item_id", "decision"])?;
                let item_id = required_str(obj, "item_id")?.to_string();
                let decision = required_str(obj, "decision")?.to_string();
                if !matches!(decision.as_str(), "accept" | "dismiss" | "reset") {
                    return Err(McpToolError::invalid_params("无效的 decision 参数"));
                }
                let result = self
                    .run_mcp_intent(
                        HostIntent::ReviewItem {
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
                    .run_mcp_intent(
                        HostIntent::CompleteTask {
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
                    .run_mcp_intent(
                        HostIntent::EditItem {
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
                            .run_mcp_intent(
                                HostIntent::EditSegmentText {
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
                            .run_mcp_intent(
                                HostIntent::SetSegmentSpeaker {
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
                    "rename" => HostIntent::RenameRecord {
                        record_id: record_id.clone(),
                        title: required_str(obj, "title")?.to_string(),
                    },
                    "archive" => HostIntent::SetRecordArchived {
                        record_id: record_id.clone(),
                        archived: true,
                    },
                    "unarchive" => HostIntent::SetRecordArchived {
                        record_id: record_id.clone(),
                        archived: false,
                    },
                    "trash" => HostIntent::TrashRecord {
                        record_id: record_id.clone(),
                    },
                    "restore" => HostIntent::RestoreRecord {
                        record_id: record_id.clone(),
                    },
                    "transcribe" => HostIntent::Transcribe {
                        record_id: record_id.clone(),
                    },
                    "summarize" => HostIntent::Summarize {
                        record_id: record_id.clone(),
                    },
                    "purge" | "empty_trash" => {
                        return Err(McpToolError::invalid_params(
                            "永久删除操作未对 MCP 开放，请在 Koe 应用内确认执行",
                        ));
                    }
                    _ => return Err(McpToolError::invalid_params("无效的 manage_record action")),
                };
                let result = self.run_mcp_intent(command, now).map(|()| {
                    json!({
                        "ok": true,
                        "recordId": record_id,
                        "action": action,
                        "generation": self.generation
                    })
                });
                Ok(McpToolCallState::Completed(result))
            }
            "device_control" => {
                ensure_allowed_keys(obj, &["action", "file_id", "enabled"])?;
                let action = required_str(obj, "action")?;
                let message = match action {
                    "start_recording" => DispatchMessage::Intent(HostIntent::DeviceStart),
                    "stop_recording" => DispatchMessage::Intent(HostIntent::DeviceStop),
                    "download_file" => {
                        let raw = optional_u64(obj, "file_id")?
                            .ok_or_else(|| McpToolError::invalid_params("缺少 file_id"))?;
                        let file_id = u32::try_from(raw)
                            .ok()
                            .filter(|&id| id > 0)
                            .ok_or_else(|| McpToolError::invalid_params("无效的 file_id"))?;
                        DispatchMessage::Intent(HostIntent::DeviceDownload { file_id })
                    }
                    "disconnect" => DispatchMessage::Adapter(AdapterEvent::DeviceDisconnect),
                    "release_ble" => DispatchMessage::Intent(HostIntent::DeviceRelease),
                    "set_auto_connect" => DispatchMessage::Intent(HostIntent::SetBleAutoConnect {
                        enabled: required_bool(obj, "enabled")?,
                    }),
                    "refresh" => DispatchMessage::Intent(HostIntent::DeviceRefresh),
                    _ => return Err(McpToolError::invalid_params("无效的 device_control action")),
                };
                let result = self.run_mcp_message(message, now).map(|()| {
                    json!({
                        "ok": true,
                        "action": action,
                        "generation": self.generation,
                        "device": self.device_json()
                    })
                });
                Ok(McpToolCallState::Completed(result))
            }
            _ => Err(McpToolError::invalid_params("未知工具")),
        }
    }

    pub(super) fn prepare_mcp_write(&mut self, now: u64) -> Result<(), String> {
        if self.is_quitting() {
            let _ = self.enter_runtime_step(now);
            return Err("正在退出，请先取消退出再开始新操作".into());
        }
        self.clear_error();
        self.notice = None;
        let _ = self.enter_runtime_step(now);
        Ok(())
    }

    fn run_mcp_intent(&mut self, intent: HostIntent, now: u64) -> Result<(), String> {
        self.run_mcp_message(DispatchMessage::Intent(intent), now)
    }

    fn run_mcp_message(&mut self, message: DispatchMessage, now: u64) -> Result<(), String> {
        self.clear_error();
        self.notice = None;
        let result = self.dispatch_message(message, now);
        if let Err(error) = &result {
            self.set_error(error.clone());
        }
        self.generation = self.generation.saturating_add(1);
        result
    }

    fn mcp_create_note(&mut self, title: String, text: &str, now: u64) -> Result<Value, String> {
        self.prepare_mcp_write(now)?;
        let created = self.create_quick_note(title, text, false, now);
        self.generation = self.generation.saturating_add(1);
        match created {
            Ok(id) => self.record_detail_json(&id),
            Err(error) => {
                self.set_error(error.clone());
                Err(error)
            }
        }
    }

    fn mcp_annotate_segment(
        &mut self,
        record_id: &str,
        segment_id: &str,
        kind: &str,
        now: u64,
    ) -> Result<Value, String> {
        self.prepare_mcp_write(now)?;
        let item_id = match kind {
            "highlight" => self.highlight_segment(record_id, segment_id).map(|()| None),
            "task" => self
                .accept_segment_item(ItemKind::Task, record_id, segment_id)
                .map(Some),
            "memory" => self
                .accept_segment_item(ItemKind::Memory, record_id, segment_id)
                .map(Some),
            _ => unreachable!(),
        };
        self.generation = self.generation.saturating_add(1);
        match item_id {
            Ok(None) => Ok(json!({
                "ok": true,
                "kind": "highlight",
                "recordId": record_id,
                "segmentId": segment_id,
                "generation": self.generation
            })),
            Ok(Some(item_id)) => Ok(json!({
                "ok": true,
                "kind": kind,
                "itemId": item_id,
                "recordId": record_id,
                "segmentId": segment_id,
                "generation": self.generation
            })),
            Err(error) => {
                self.set_error(error.clone());
                Err(error)
            }
        }
    }

    fn mcp_rename_speaker(
        &mut self,
        record_id: &str,
        from_speaker: &str,
        to_speaker: &str,
        now: u64,
    ) -> Result<Value, String> {
        self.prepare_mcp_write(now)?;
        let res = self.rename_speaker(record_id, from_speaker, to_speaker);
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
                self.set_error(error.clone());
                Err(error)
            }
        }
    }
}
