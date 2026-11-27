use serde_json::{json, Value};

use crate::KoeRuntime;

impl KoeRuntime {
    /// Returns the canonical 17-tool MCP schema array exposed by Koe.
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
                "description": "读取「今天」视图摘要、近期记录、待审核数量与录音豆状态。",
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
                "description": "读取指定记录的元数据、说话人、纪要、高亮重点、来源证据与分页转写段落（超长记录按字节预算自动分页）。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "record_id": { "type": "string" },
                        "include_segments": { "type": "boolean" },
                        "segment_offset": { "type": "integer", "minimum": 0 },
                        "segment_limit": { "type": "integer", "minimum": 1 }
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
                "description": "重命名、设置项目归属、归档、取消归档、移入回收站、恢复记录，或触发转写与纪要重算（支持 if_idle 幂等保护，不含永久清除）。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "record_id": { "type": "string" },
                        "action": {
                            "type": "string",
                            "enum": [
                                "rename",
                                "set_project",
                                "archive",
                                "unarchive",
                                "trash",
                                "restore",
                                "transcribe",
                                "summarize"
                            ]
                        },
                        "title": { "type": "string" },
                        "project": { "type": ["string", "null"] },
                        "if_idle": { "type": "boolean" }
                    },
                    "required": ["record_id", "action"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "device_status",
                "description": "读取 D3200 录音豆在线状态、电量、固件、存储、目录文件与同步进度。",
                "inputSchema": {
                    "type": "object",
                    "properties": {},
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": true, "openWorldHint": false }
            }),
            json!({
                "name": "device_control",
                "description": "控制录音豆开始/停止录音、下载指定或全部离线文件、刷新状态、断开或释放蓝牙控制权，以及切换自动重连。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "action": {
                            "type": "string",
                            "enum": [
                                "start_recording",
                                "stop_recording",
                                "download_file",
                                "download_all",
                                "disconnect",
                                "release_ble",
                                "set_auto_connect",
                                "refresh"
                            ]
                        },
                        "file_id": { "type": "integer", "minimum": 1 },
                        "enabled": { "type": "boolean" }
                    },
                    "required": ["action"],
                    "additionalProperties": false
                },
                "annotations": { "readOnlyHint": false, "destructiveHint": false, "openWorldHint": false }
            }),
            json!({
                "name": "poll_updates",
                "description": "轮询工作区代次、修订号、后台转写/纪要/问答任务进度以及设备状态变更。",
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
            json!({
                "name": "manage_vocabulary",
                "description": "读取或更新会议纪要专有名词/热词表（最多 200 个不重复词条，单条不超过 64 字符，自动去重并拒绝控制字符）。",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "action": { "type": "string", "enum": ["get", "set"] },
                        "terms": {
                            "type": "array",
                            "items": { "type": "string" }
                        }
                    },
                    "required": ["action"],
                    "additionalProperties": false
                },
                "annotations": {
                    "readOnlyHint": false,
                    "destructiveHint": false,
                    "idempotentHint": true,
                    "openWorldHint": false
                }
            }),
        ]
    }

    /// Returns the JSON-RPC `tools/list` result payload (`{"tools": [...]}`).
    #[must_use]
    pub fn mcp_tools_list() -> Value {
        json!({ "tools": Self::mcp_tool_definitions() })
    }
}
