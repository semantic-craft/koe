//! Pure-Rust "Ask AI Copilot" engine, UI preset chip planner, OpenAI/DeepSeek multi-turn
//! tool-calling state machine, and Google Suite integration (Google Tasks 3-way reconciliation
//! via `reconcile_system_todo_sync`, Google Gemini Notebooks / NotebookLM `batchexecute` + gRPC
//! source and grounded Q&A store, and Google Keep `notes/v1` checklist store).

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;

use koe_client_base::hash::sha256_hex;
use koe_engine::context::{
    reconcile_system_todo_sync, ContextSearchIndex, ContextState, ScoringMode, SystemSyncOutcome,
    SystemTaskSnapshot, SystemTodoLink,
};
use koe_engine::domain::{
    ContextItem, ContextKind, ContextSource, SegmentId, TodoStatus, UtteranceSpine,
};
use koe_engine::minutes::JsonValue;

/// Maximum allowable multi-turn tool calling rounds per user turn (`6`).
pub const MAX_COPILOT_TOOL_ROUNDS: u8 = 6;

/// Default DeepSeek chat completions API endpoint URL.
pub const DEEPSEEK_CHAT_COMPLETIONS_URL: &str = "https://api.deepseek.com/v1/chat/completions";

/// Default DeepSeek chat model identifier.
pub const DEFAULT_DEEPSEEK_MODEL: &str = "deepseek-chat";

/// Default Google Tasks REST v1 base URL.
pub const GOOGLE_TASKS_V1_BASE_URL: &str = "https://tasks.googleapis.com/tasks/v1";

/// Default Google Keep REST v1 base URL.
pub const GOOGLE_KEEP_V1_BASE_URL: &str = "https://keep.googleapis.com/v1";

/// Default Google Gemini Notebook (`NotebookLM`) `batchexecute` endpoint URL.
pub const GEMINI_NOTEBOOK_BATCHEXECUTE_URL: &str =
    "https://notebooklm.google.com/_/LabsTailwindUi/data/batchexecute";

/// Default Google Gemini Notebook Android gRPC service path prefix.
pub const GEMINI_NOTEBOOK_GRPC_SERVICE: &str =
    "/google.internal.labs.tailwind.v1.LabsTailwindService";

/// System prompt governing the Ask AI Copilot assistant across freeform and preset turns.
pub const COPILOT_SYSTEM_PROMPT: &str =
    "You are Koe Ask AI Copilot, a grounded personal recording, notes, and task assistant. \
Use Koe's native MCP tools to inspect transcripts, meeting minutes, context timeline items, \
Google Tasks, Google Gemini Notebooks, and Google Keep notes before answering or mutating state. \
Every factual claim from recordings must cite its segment label such as [S1]. \
Never invent facts not present in tool outputs or provided sources.";

/// Branded identifier for a Google Tasks item (`tasks/v1`).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct GoogleTaskId(pub String);

/// Branded identifier for a Google Gemini Notebook (`NotebookLM`).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct NotebookId(pub String);

/// Branded identifier for a Google Keep note (`notes/v1`).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct KeepNoteId(pub String);

/// Branded identifier for an OpenAI/DeepSeek tool call invocation (`"call_1"`).
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct ToolCallId(pub String);

/// UI Preset chips matching the Koe Ask AI Copilot panel.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CopilotPresetChip {
    /// `"Analyze my recurring thoughts this week"`
    AnalyzeRecurringThoughts,
    /// `"Turn my notes into an executive brief"`
    TurnNotesIntoExecutiveBrief,
    /// `"Summarize this audio file"`
    SummarizeAudioFile,
    /// `"Sync my action items to Google Tasks"`
    SyncActionItemsToGoogleTasks,
}

/// All four canonical preset chips in UI display order.
pub const COPILOT_PRESET_CHIPS: [CopilotPresetChip; 4] = [
    CopilotPresetChip::AnalyzeRecurringThoughts,
    CopilotPresetChip::TurnNotesIntoExecutiveBrief,
    CopilotPresetChip::SummarizeAudioFile,
    CopilotPresetChip::SyncActionItemsToGoogleTasks,
];

impl CopilotPresetChip {
    /// All canonical preset chips.
    pub const ALL: [Self; 4] = COPILOT_PRESET_CHIPS;

    /// Returns the exact UI display label shown in the Ask AI Copilot screenshot.
    #[must_use]
    pub const fn label(&self) -> &'static str {
        match self {
            Self::AnalyzeRecurringThoughts => "Analyze my recurring thoughts this week",
            Self::TurnNotesIntoExecutiveBrief => "Turn my notes into an executive brief",
            Self::SummarizeAudioFile => "Summarize this audio file",
            Self::SyncActionItemsToGoogleTasks => "Sync my action items to Google Tasks",
        }
    }

    /// Returns the stable kebab-case slug for CLI and MCP invocation.
    #[must_use]
    pub const fn slug(&self) -> &'static str {
        match self {
            Self::AnalyzeRecurringThoughts => "analyze-recurring-thoughts",
            Self::TurnNotesIntoExecutiveBrief => "executive-brief",
            Self::SummarizeAudioFile => "summarize-audio",
            Self::SyncActionItemsToGoogleTasks => "sync-google-tasks",
        }
    }

    /// Parses a preset chip from its label or slug (with hyphens or underscores).
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        let clean = raw.trim().to_ascii_lowercase();
        let normalized = clean.replace('_', "-");
        Self::ALL
            .into_iter()
            .find(|&chip| normalized == chip.slug() || clean == chip.label().to_ascii_lowercase())
    }

    /// Formats the prompt sent to the LLM when this chip is clicked.
    #[must_use]
    pub const fn prompt_template(&self) -> &'static str {
        match self {
            Self::AnalyzeRecurringThoughts => {
                "Please review my recorded entries, journal notes, and recurring topics from this week. Identify repeating thoughts, cognitive patterns, and lingering open questions."
            }
            Self::TurnNotesIntoExecutiveBrief => {
                "Synthesize my recent notes, meeting minutes, and decisions into a crisp executive brief with key highlights, decisions made, risks, and next steps."
            }
            Self::SummarizeAudioFile => {
                "Please inspect the active recording, extract the main points, participant contributions, and actionable conclusions with [S#] segment citations."
            }
            Self::SyncActionItemsToGoogleTasks => {
                "Please synchronize my current open action items with Google Tasks, report any updates from either side, and resolve conflicts."
            }
        }
    }

    /// Returns the default tool sequence planned for this preset chip.
    #[must_use]
    pub const fn default_tool_plan(&self) -> &'static [&'static str] {
        match self {
            Self::AnalyzeRecurringThoughts => &["search_context", "google_keep_ops"],
            Self::TurnNotesIntoExecutiveBrief => {
                &["get_minutes", "google_keep_ops", "gemini_notebook_ops"]
            }
            Self::SummarizeAudioFile => &["list_recordings", "get_transcript", "get_minutes"],
            Self::SyncActionItemsToGoogleTasks => &["google_tasks_sync", "google_tasks_list"],
        }
    }
}

/// Authentication header format expected by the LLM endpoint.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CopilotAuthStyle {
    /// `Authorization: Bearer <api_key>`
    BearerHeader,
    /// `api-key: <api_key>`
    ApiKeyHeader,
    /// Custom header name: `<name>: <api_key>`
    CustomHeader(String),
}

/// Configuration settings for connecting to the user's chosen AI.
#[derive(Clone, PartialEq, Eq)]
pub struct CopilotProviderConfig {
    /// Provider display identifier (`"deepseek"`, `"openai"`, `"local-openai"`).
    pub provider_name: String,
    /// Complete HTTP POST endpoint URL.
    pub endpoint_url: String,
    /// Target model identifier (`"deepseek-chat"`, `"gpt-4o"`).
    pub model: String,
    /// Authentication header style.
    pub auth_style: CopilotAuthStyle,
    /// In-memory Bearer API key (never printed in Debug or written to disk).
    pub api_key: Option<String>,
    /// Sampling temperature in milli-units (`200` represents `0.200`).
    pub temperature_milli: u32,
    /// Maximum completion tokens requested per turn.
    pub max_tokens: u32,
}

impl fmt::Debug for CopilotProviderConfig {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CopilotProviderConfig")
            .field("provider_name", &self.provider_name)
            .field("endpoint_url", &self.endpoint_url)
            .field("model", &self.model)
            .field("auth_style", &self.auth_style)
            .field("api_key", &"<redacted>")
            .field("temperature_milli", &self.temperature_milli)
            .field("max_tokens", &self.max_tokens)
            .finish()
    }
}

impl Default for CopilotProviderConfig {
    fn default() -> Self {
        Self::deepseek_default()
    }
}

impl CopilotProviderConfig {
    /// Creates the standard default DeepSeek chat completions configuration.
    #[must_use]
    pub fn deepseek_default() -> Self {
        Self {
            provider_name: "deepseek".to_string(),
            endpoint_url: DEEPSEEK_CHAT_COMPLETIONS_URL.to_string(),
            model: DEFAULT_DEEPSEEK_MODEL.to_string(),
            auth_style: CopilotAuthStyle::BearerHeader,
            api_key: None,
            temperature_milli: 200,
            max_tokens: 2048,
        }
    }

    /// Creates an OpenAI-compatible endpoint configuration.
    #[must_use]
    pub fn openai_compatible(
        endpoint_url: impl Into<String>,
        model: impl Into<String>,
        api_key: Option<String>,
    ) -> Self {
        Self {
            provider_name: "openai-compatible".to_string(),
            endpoint_url: endpoint_url.into(),
            model: model.into(),
            auth_style: CopilotAuthStyle::BearerHeader,
            api_key,
            temperature_milli: 200,
            max_tokens: 2048,
        }
    }

    /// Serializes non-secret metadata for `google_suite.json`, strictly redacting `api_key`.
    #[must_use]
    pub fn to_redacted_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "providerName".to_string(),
            JsonValue::String(self.provider_name.clone()),
        );
        obj.insert(
            "endpointUrl".to_string(),
            JsonValue::String(self.endpoint_url.clone()),
        );
        obj.insert("model".to_string(), JsonValue::String(self.model.clone()));
        let auth_str = match &self.auth_style {
            CopilotAuthStyle::BearerHeader => "bearer".to_string(),
            CopilotAuthStyle::ApiKeyHeader => "api-key".to_string(),
            CopilotAuthStyle::CustomHeader(h) => format!("custom:{h}"),
        };
        obj.insert("authStyle".to_string(), JsonValue::String(auth_str));
        obj.insert(
            "hasApiKey".to_string(),
            JsonValue::Bool(self.api_key.is_some()),
        );
        obj.insert(
            "apiKey".to_string(),
            JsonValue::String(if self.api_key.is_some() {
                "<redacted>".to_string()
            } else {
                "none".to_string()
            }),
        );
        obj.insert(
            "temperatureMilli".to_string(),
            JsonValue::Number(self.temperature_milli as f64),
        );
        obj.insert(
            "maxTokens".to_string(),
            JsonValue::Number(self.max_tokens as f64),
        );
        JsonValue::Object(obj)
    }

    /// Restores non-secret metadata from `google_suite.json` with `api_key: None`.
    pub fn from_redacted_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected provider config JSON object".to_string());
        };
        let provider_name = obj
            .get("providerName")
            .and_then(JsonValue::as_str)
            .unwrap_or("deepseek")
            .to_string();
        let endpoint_url = obj
            .get("endpointUrl")
            .and_then(JsonValue::as_str)
            .unwrap_or(DEEPSEEK_CHAT_COMPLETIONS_URL)
            .to_string();
        let model = obj
            .get("model")
            .and_then(JsonValue::as_str)
            .unwrap_or(DEFAULT_DEEPSEEK_MODEL)
            .to_string();
        let auth_style = match obj.get("authStyle").and_then(JsonValue::as_str) {
            Some("api-key") => CopilotAuthStyle::ApiKeyHeader,
            Some(custom) if custom.starts_with("custom:") => {
                CopilotAuthStyle::CustomHeader(custom.trim_start_matches("custom:").to_string())
            }
            _ => CopilotAuthStyle::BearerHeader,
        };
        let temperature_milli = obj
            .get("temperatureMilli")
            .and_then(JsonValue::as_i64)
            .unwrap_or(200) as u32;
        let max_tokens = obj
            .get("maxTokens")
            .and_then(JsonValue::as_i64)
            .unwrap_or(2048) as u32;

        Ok(Self {
            provider_name,
            endpoint_url,
            model,
            auth_style,
            api_key: None,
            temperature_milli,
            max_tokens,
        })
    }
}

/// Extracts segment citations (`[S12]` -> `SegmentId(12)`) in order, deduplicated.
#[must_use]
pub fn extract_segment_citations(text: &str) -> Vec<SegmentId> {
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    let bytes = text.as_bytes();
    let mut i = 0usize;

    while i + 2 < bytes.len() {
        if bytes[i] == b'[' && (bytes[i + 1] == b'S' || bytes[i + 1] == b's') {
            let mut j = i + 2;
            let mut num: u32 = 0;
            let mut has_digits = false;
            while j < bytes.len() && bytes[j].is_ascii_digit() {
                has_digits = true;
                num = num
                    .saturating_mul(10)
                    .saturating_add((bytes[j] - b'0') as u32);
                j += 1;
            }
            if has_digits && j < bytes.len() && bytes[j] == b']' {
                if let Some(seg) = SegmentId::new(num) {
                    if seen.insert(seg) {
                        out.push(seg);
                    }
                }
                i = j + 1;
                continue;
            }
        }
        i += 1;
    }

    out
}

/// Author role of a conversation message.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CopilotRole {
    /// System instruction.
    System,
    /// User prompt.
    User,
    /// AI assistant reply or tool call.
    Assistant,
    /// Local tool execution result.
    Tool,
}

impl CopilotRole {
    /// Returns the wire role string.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::System => "system",
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::Tool => "tool",
        }
    }
}

/// A tool call requested by the assistant.
#[derive(Debug, Clone, PartialEq)]
pub struct CopilotToolCall {
    /// Tool call invocation ID (`"call_1"`).
    pub id: ToolCallId,
    /// Registered Koe MCP tool name.
    pub tool_name: String,
    /// Parsed JSON object arguments.
    pub arguments: BTreeMap<String, JsonValue>,
}

impl Eq for CopilotToolCall {}

/// A single message in the Copilot chat history.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotMessage {
    /// Message author role.
    pub role: CopilotRole,
    /// Text content.
    pub content: String,
    /// Outbound tool calls if requested by assistant.
    pub tool_calls: Vec<CopilotToolCall>,
    /// Tool call ID matching `CopilotToolCall::id` if `role == Tool`.
    pub tool_call_id: Option<ToolCallId>,
    /// Tool name if `role == Tool`.
    pub tool_name: Option<String>,
    /// Segment citations verified from `content`.
    pub citations: Vec<SegmentId>,
    /// UTC timestamp in Unix seconds.
    pub created_at_epoch_sec: u64,
}

/// Current lifecycle phase of a Copilot conversation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CopilotPhase {
    /// Ready for user prompt or preset chip.
    Idle,
    /// Awaiting model completion response from the network.
    AwaitingModel {
        /// Active round count in current turn (`0..=MAX_COPILOT_TOOL_ROUNDS`).
        round: usize,
    },
    /// Model emitted tool calls that need execution against local MCP tools.
    PendingLocalTools {
        /// Active round count in current turn.
        round: usize,
        /// Tool calls to execute.
        calls: Vec<CopilotToolCall>,
    },
    /// Conversation turn finished with final grounded assistant text.
    Completed {
        /// Final assistant reply text.
        reply_text: String,
        /// Extracted segment citations.
        citations: Vec<SegmentId>,
    },
    /// Turn aborted due to error.
    Failed {
        /// Diagnostic error description.
        error: String,
    },
}

impl CopilotPhase {
    /// Returns a short label for status reporting.
    #[must_use]
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::AwaitingModel { .. } => "awaiting_model",
            Self::PendingLocalTools { .. } => "pending_local_tools",
            Self::Completed { .. } => "completed",
            Self::Failed { .. } => "failed",
        }
    }
}

/// Error encountered during Copilot tool-calling loops.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CopilotError {
    /// Turn exceeded [`MAX_COPILOT_TOOL_ROUNDS`].
    ToolRoundLimitExceeded,
    /// Model response lacked choices or message.
    InvalidModelResponse(String),
    /// Tool call failed execution.
    ToolExecutionFailed(String),
    /// Session was not in the expected state.
    SessionNotAwaitingModel,
    /// Session was not awaiting tool execution.
    SessionNotAwaitingTools,
}

impl fmt::Display for CopilotError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::ToolRoundLimitExceeded => {
                write!(
                    f,
                    "exceeded maximum tool-calling rounds ({MAX_COPILOT_TOOL_ROUNDS})"
                )
            }
            Self::InvalidModelResponse(detail) => write!(f, "invalid model response: {detail}"),
            Self::ToolExecutionFailed(detail) => write!(f, "tool execution failed: {detail}"),
            Self::SessionNotAwaitingModel => write!(f, "session is not awaiting model response"),
            Self::SessionNotAwaitingTools => write!(f, "session is not awaiting tool execution"),
        }
    }
}

/// Stateful Ask AI Copilot session managing multi-turn tool-calling loops.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CopilotSession {
    /// Session identifier (`"copilot-default"`).
    pub session_id: String,
    /// Active provider configuration.
    pub provider: CopilotProviderConfig,
    /// Current lifecycle phase.
    pub phase: CopilotPhase,
    /// Full message history.
    pub messages: Vec<CopilotMessage>,
    /// Names of tools invoked during the current or most recent turn.
    pub current_turn_tools: Vec<String>,
    /// Lifetime tool calls executed.
    pub total_tool_calls: u64,
}

impl Default for CopilotSession {
    fn default() -> Self {
        Self::new("copilot-default")
    }
}

impl CopilotSession {
    /// Creates a new Copilot session.
    #[must_use]
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            provider: CopilotProviderConfig::default(),
            phase: CopilotPhase::Idle,
            messages: Vec::new(),
            current_turn_tools: Vec::new(),
            total_tool_calls: 0,
        }
    }

    /// Submits a user prompt, clearing per-turn state and entering `AwaitingModel { round: 0 }`.
    pub fn start_user_prompt(&mut self, prompt: &str, now_epoch_sec: u64) {
        self.messages.push(CopilotMessage {
            role: CopilotRole::User,
            content: prompt.trim().to_string(),
            tool_calls: Vec::new(),
            tool_call_id: None,
            tool_name: None,
            citations: Vec::new(),
            created_at_epoch_sec: now_epoch_sec,
        });
        self.current_turn_tools.clear();
        self.phase = CopilotPhase::AwaitingModel { round: 0 };
    }

    /// Starts a preset chip turn.
    pub fn start_preset(&mut self, chip: CopilotPresetChip, now_epoch_sec: u64) {
        self.start_user_prompt(chip.prompt_template(), now_epoch_sec);
    }

    /// Builds the standard OpenAI `/v1/chat/completions` request payload JSON.
    #[must_use]
    pub fn build_openai_chat_request_json(&self, tools_schema: JsonValue) -> JsonValue {
        let mut req = BTreeMap::new();
        req.insert(
            "model".to_string(),
            JsonValue::String(self.provider.model.clone()),
        );

        let mut msg_arr = Vec::with_capacity(self.messages.len() + 1);
        let mut sys_msg = BTreeMap::new();
        sys_msg.insert("role".to_string(), JsonValue::String("system".to_string()));
        sys_msg.insert(
            "content".to_string(),
            JsonValue::String(COPILOT_SYSTEM_PROMPT.to_string()),
        );
        msg_arr.push(JsonValue::Object(sys_msg));

        for msg in &self.messages {
            let mut m = BTreeMap::new();
            m.insert(
                "role".to_string(),
                JsonValue::String(msg.role.as_str().to_string()),
            );
            if !msg.content.is_empty() {
                m.insert(
                    "content".to_string(),
                    JsonValue::String(msg.content.clone()),
                );
            }
            if !msg.tool_calls.is_empty() {
                let mut calls_arr = Vec::new();
                for call in &msg.tool_calls {
                    let mut c = BTreeMap::new();
                    c.insert("id".to_string(), JsonValue::String(call.id.0.clone()));
                    c.insert(
                        "type".to_string(),
                        JsonValue::String("function".to_string()),
                    );
                    let mut fn_obj = BTreeMap::new();
                    fn_obj.insert(
                        "name".to_string(),
                        JsonValue::String(call.tool_name.clone()),
                    );
                    fn_obj.insert(
                        "arguments".to_string(),
                        JsonValue::String(
                            JsonValue::Object(call.arguments.clone()).to_json_string(),
                        ),
                    );
                    c.insert("function".to_string(), JsonValue::Object(fn_obj));
                    calls_arr.push(JsonValue::Object(c));
                }
                m.insert("tool_calls".to_string(), JsonValue::Array(calls_arr));
            }
            if let Some(ref call_id) = msg.tool_call_id {
                m.insert(
                    "tool_call_id".to_string(),
                    JsonValue::String(call_id.0.clone()),
                );
            }
            msg_arr.push(JsonValue::Object(m));
        }

        req.insert("messages".to_string(), JsonValue::Array(msg_arr));
        req.insert("tools".to_string(), tools_schema);
        req.insert(
            "tool_choice".to_string(),
            JsonValue::String("auto".to_string()),
        );
        req.insert(
            "temperature".to_string(),
            JsonValue::Number(self.provider.temperature_milli as f64 / 1000.0),
        );
        req.insert(
            "max_tokens".to_string(),
            JsonValue::Number(self.provider.max_tokens as f64),
        );

        JsonValue::Object(req)
    }

    /// Ingests an OpenAI/DeepSeek chat completion response JSON payload.
    pub fn ingest_openai_chat_response(
        &mut self,
        response: &JsonValue,
        now_epoch_sec: u64,
    ) -> Result<CopilotPhase, CopilotError> {
        let current_round = match self.phase {
            CopilotPhase::AwaitingModel { round } => round,
            _ => 0,
        };

        let Some(root) = response.as_object() else {
            return Err(CopilotError::InvalidModelResponse(
                "root is not an object".to_string(),
            ));
        };
        let Some(choices) = root.get("choices").and_then(JsonValue::as_array) else {
            return Err(CopilotError::InvalidModelResponse(
                "missing choices array".to_string(),
            ));
        };
        let Some(first_choice) = choices.first().and_then(JsonValue::as_object) else {
            return Err(CopilotError::InvalidModelResponse(
                "choices array is empty".to_string(),
            ));
        };
        let Some(message_obj) = first_choice.get("message").and_then(JsonValue::as_object) else {
            return Err(CopilotError::InvalidModelResponse(
                "choice missing message object".to_string(),
            ));
        };

        let tool_calls_opt = message_obj.get("tool_calls").and_then(JsonValue::as_array);

        if let Some(tool_calls_arr) = tool_calls_opt {
            if !tool_calls_arr.is_empty() {
                if current_round >= (MAX_COPILOT_TOOL_ROUNDS as usize) {
                    let err = CopilotError::ToolRoundLimitExceeded;
                    self.phase = CopilotPhase::Failed {
                        error: err.to_string(),
                    };
                    return Err(err);
                }

                let mut parsed_calls = Vec::new();
                for call_val in tool_calls_arr {
                    let Some(c_obj) = call_val.as_object() else {
                        continue;
                    };
                    let id = c_obj
                        .get("id")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("call_unknown")
                        .to_string();
                    let Some(fn_obj) = c_obj.get("function").and_then(JsonValue::as_object) else {
                        continue;
                    };
                    let name = fn_obj
                        .get("name")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string();

                    let args_map = match fn_obj.get("arguments") {
                        Some(JsonValue::String(s)) => {
                            JsonValue::parse(s).ok().and_then(|v| match v {
                                JsonValue::Object(m) => Some(m),
                                _ => None,
                            })
                        }
                        Some(JsonValue::Object(m)) => Some(m.clone()),
                        _ => None,
                    }
                    .unwrap_or_default();

                    parsed_calls.push(CopilotToolCall {
                        id: ToolCallId(id),
                        tool_name: name,
                        arguments: args_map,
                    });
                }

                let content = message_obj
                    .get("content")
                    .and_then(JsonValue::as_str)
                    .unwrap_or("")
                    .to_string();

                self.messages.push(CopilotMessage {
                    role: CopilotRole::Assistant,
                    content,
                    tool_calls: parsed_calls.clone(),
                    tool_call_id: None,
                    tool_name: None,
                    citations: Vec::new(),
                    created_at_epoch_sec: now_epoch_sec,
                });

                let next_phase = CopilotPhase::PendingLocalTools {
                    round: current_round,
                    calls: parsed_calls,
                };
                self.phase = next_phase.clone();
                return Ok(next_phase);
            }
        }

        let content = message_obj
            .get("content")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let citations = extract_segment_citations(&content);

        self.messages.push(CopilotMessage {
            role: CopilotRole::Assistant,
            content: content.clone(),
            tool_calls: Vec::new(),
            tool_call_id: None,
            tool_name: None,
            citations: citations.clone(),
            created_at_epoch_sec: now_epoch_sec,
        });

        let next_phase = CopilotPhase::Completed {
            reply_text: content,
            citations,
        };
        self.phase = next_phase.clone();
        Ok(next_phase)
    }

    /// Records the output of executing a tool call.
    pub fn record_tool_result(
        &mut self,
        call_id: ToolCallId,
        tool_name: &str,
        result_json: &JsonValue,
        now_epoch_sec: u64,
    ) {
        self.messages.push(CopilotMessage {
            role: CopilotRole::Tool,
            content: result_json.to_json_string(),
            tool_calls: Vec::new(),
            tool_call_id: Some(call_id),
            tool_name: Some(tool_name.to_string()),
            citations: Vec::new(),
            created_at_epoch_sec: now_epoch_sec,
        });
        if !self.current_turn_tools.iter().any(|t| t == tool_name) {
            self.current_turn_tools.push(tool_name.to_string());
        }
        self.total_tool_calls = self.total_tool_calls.saturating_add(1);
    }

    /// Advances the state machine after all pending tool calls have been executed.
    pub fn advance_after_tools_executed(&mut self) -> Result<CopilotPhase, CopilotError> {
        match self.phase {
            CopilotPhase::PendingLocalTools { round, .. } => {
                let next_round = round + 1;
                let next_phase = CopilotPhase::AwaitingModel { round: next_round };
                self.phase = next_phase.clone();
                Ok(next_phase)
            }
            _ => Err(CopilotError::SessionNotAwaitingTools),
        }
    }

    /// Explicitly completes the turn with assistant text and extracted citations.
    pub fn complete_turn(&mut self, reply_text: &str, now_epoch_sec: u64) {
        let citations = extract_segment_citations(reply_text);
        self.messages.push(CopilotMessage {
            role: CopilotRole::Assistant,
            content: reply_text.to_string(),
            tool_calls: Vec::new(),
            tool_call_id: None,
            tool_name: None,
            citations: citations.clone(),
            created_at_epoch_sec: now_epoch_sec,
        });
        self.phase = CopilotPhase::Completed {
            reply_text: reply_text.to_string(),
            citations,
        };
    }
}

/// Google Task completion status.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GoogleTaskStatus {
    /// Needs action / open.
    NeedsAction,
    /// Completed.
    Completed,
}

impl GoogleTaskStatus {
    /// Returns the wire status string.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::NeedsAction => "needsAction",
            Self::Completed => "completed",
        }
    }

    /// Parses a wire status string.
    #[must_use]
    pub fn parse(s: &str) -> Self {
        match s.trim() {
            "completed" => Self::Completed,
            _ => Self::NeedsAction,
        }
    }
}

/// An individual Google Task record (`tasks/v1`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleTaskRecord {
    /// Unique Google Task identifier (`"gtask-..."`).
    pub id: GoogleTaskId,
    /// Owning tasklist identifier (`"@default"`).
    pub tasklist_id: String,
    /// Task title.
    pub title: String,
    /// Optional notes body.
    pub notes: String,
    /// Optional due timestamp in Unix seconds.
    pub due_epoch_sec: Option<u64>,
    /// Task completion status.
    pub status: GoogleTaskStatus,
    /// Whether marked deleted.
    pub deleted: bool,
    /// Optional linked Koe `TodoItem.id`.
    pub linked_koe_todo_id: Option<String>,
    /// Last updated timestamp in Unix seconds.
    pub updated_at_epoch_sec: u64,
    /// Entity tag for optimistic concurrency.
    pub etag: Option<String>,
}

impl GoogleTaskRecord {
    /// Serializes this record into a persistence [`JsonValue`].
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("id".to_string(), JsonValue::String(self.id.0.clone()));
        obj.insert(
            "tasklist_id".to_string(),
            JsonValue::String(self.tasklist_id.clone()),
        );
        obj.insert("title".to_string(), JsonValue::String(self.title.clone()));
        obj.insert("notes".to_string(), JsonValue::String(self.notes.clone()));
        if let Some(due) = self.due_epoch_sec {
            obj.insert("due_epoch_sec".to_string(), JsonValue::Number(due as f64));
        }
        obj.insert(
            "status".to_string(),
            JsonValue::String(self.status.as_str().to_string()),
        );
        obj.insert("deleted".to_string(), JsonValue::Bool(self.deleted));
        if let Some(ref todo_id) = self.linked_koe_todo_id {
            obj.insert(
                "linked_koe_todo_id".to_string(),
                JsonValue::String(todo_id.clone()),
            );
        }
        obj.insert(
            "updated_at_epoch_sec".to_string(),
            JsonValue::Number(self.updated_at_epoch_sec as f64),
        );
        if let Some(ref etag) = self.etag {
            obj.insert("etag".to_string(), JsonValue::String(etag.clone()));
        }
        JsonValue::Object(obj)
    }

    /// Deserializes a [`GoogleTaskRecord`] from a persistence [`JsonValue`].
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected JSON object for GoogleTaskRecord".to_string());
        };
        let id = obj
            .get("id")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let tasklist_id = obj
            .get("tasklist_id")
            .and_then(JsonValue::as_str)
            .unwrap_or("@default")
            .to_string();
        let title = obj
            .get("title")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let notes = obj
            .get("notes")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let due_epoch_sec = obj
            .get("due_epoch_sec")
            .and_then(JsonValue::as_f64)
            .map(|n| n as u64);
        let status_str = obj
            .get("status")
            .and_then(JsonValue::as_str)
            .unwrap_or("needsAction");
        let status = match status_str {
            "completed" => GoogleTaskStatus::Completed,
            _ => GoogleTaskStatus::NeedsAction,
        };
        let deleted = obj
            .get("deleted")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        let linked_koe_todo_id = obj
            .get("linked_koe_todo_id")
            .and_then(JsonValue::as_str)
            .map(ToString::to_string);
        let updated_at_epoch_sec = obj
            .get("updated_at_epoch_sec")
            .and_then(JsonValue::as_f64)
            .map(|n| n as u64)
            .unwrap_or(0);
        let etag = obj
            .get("etag")
            .and_then(JsonValue::as_str)
            .map(ToString::to_string);
        Ok(Self {
            id: GoogleTaskId(id),
            tasklist_id,
            title,
            notes,
            due_epoch_sec,
            status,
            deleted,
            linked_koe_todo_id,
            updated_at_epoch_sec,
            etag,
        })
    }

    /// Converts this record to a [`SystemTaskSnapshot`] for 3-way sync.
    #[must_use]
    pub fn to_system_snapshot(&self) -> SystemTaskSnapshot {
        SystemTaskSnapshot {
            title: self.title.clone(),
            start_epoch_sec: self.due_epoch_sec,
            end_epoch_sec: None,
            done: self.status == GoogleTaskStatus::Completed,
        }
    }

    /// Serializes this record into Google Tasks `tasks/v1` REST JSON format.
    #[must_use]
    pub fn to_tasks_v1_json(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "kind".to_string(),
            JsonValue::String("tasks#task".to_string()),
        );
        obj.insert("id".to_string(), JsonValue::String(self.id.0.clone()));
        obj.insert("title".to_string(), JsonValue::String(self.title.clone()));
        obj.insert("notes".to_string(), JsonValue::String(self.notes.clone()));
        obj.insert(
            "status".to_string(),
            JsonValue::String(self.status.as_str().to_string()),
        );
        obj.insert("deleted".to_string(), JsonValue::Bool(self.deleted));
        if let Some(due) = self.due_epoch_sec {
            obj.insert(
                "due".to_string(),
                JsonValue::String(format_epoch_sec_rfc3339(due)),
            );
        }
        obj.insert(
            "updated".to_string(),
            JsonValue::String(format_epoch_sec_rfc3339(self.updated_at_epoch_sec)),
        );
        if let Some(ref etag) = self.etag {
            obj.insert("etag".to_string(), JsonValue::String(etag.clone()));
        }
        JsonValue::Object(obj)
    }

    /// Parses a Google Tasks `tasks/v1` JSON object.
    pub fn from_tasks_v1_json(
        tasklist_id: &str,
        val: &JsonValue,
        now_epoch_sec: u64,
    ) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected JSON object for tasks#task".to_string());
        };
        let id_str = obj
            .get("id")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| "missing task id".to_string())?;
        let title = obj
            .get("title")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let notes = obj
            .get("notes")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let status_str = obj
            .get("status")
            .and_then(JsonValue::as_str)
            .unwrap_or("needsAction");
        let deleted = obj
            .get("deleted")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        let due_epoch_sec = obj
            .get("due")
            .and_then(JsonValue::as_str)
            .and_then(parse_rfc3339_to_epoch_sec);
        let updated_at_epoch_sec = obj
            .get("updated")
            .and_then(JsonValue::as_str)
            .and_then(parse_rfc3339_to_epoch_sec)
            .unwrap_or(now_epoch_sec);
        let etag = obj
            .get("etag")
            .and_then(JsonValue::as_str)
            .map(ToString::to_string);

        Ok(Self {
            id: GoogleTaskId(id_str.to_string()),
            tasklist_id: tasklist_id.to_string(),
            title,
            notes,
            due_epoch_sec,
            status: GoogleTaskStatus::parse(status_str),
            deleted,
            linked_koe_todo_id: None,
            updated_at_epoch_sec,
            etag,
        })
    }
}

/// Summary report of a 3-way Google Tasks synchronization pass.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GoogleTasksSyncReport {
    /// Newly created Google Tasks.
    pub created_remote: usize,
    /// Local items pushed to Google Tasks.
    pub pushed_to_remote: usize,
    /// Remote edits applied to local Koe todos.
    pub applied_from_remote: usize,
    /// Mutual conflicts recorded.
    pub conflicts: usize,
    /// Unlinked or deleted remote tasks.
    pub unlinked_deleted: usize,
    /// Tasks already in sync.
    pub unchanged: usize,
    /// Timestamp when sync ran in Unix seconds.
    pub synced_at_epoch_sec: u64,
}

impl GoogleTasksSyncReport {
    /// Serializes this report to a JSON object.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "createdRemote".to_string(),
            JsonValue::Number(self.created_remote as f64),
        );
        obj.insert(
            "pushedToRemote".to_string(),
            JsonValue::Number(self.pushed_to_remote as f64),
        );
        obj.insert(
            "appliedFromRemote".to_string(),
            JsonValue::Number(self.applied_from_remote as f64),
        );
        obj.insert(
            "conflicts".to_string(),
            JsonValue::Number(self.conflicts as f64),
        );
        obj.insert(
            "unlinkedDeleted".to_string(),
            JsonValue::Number(self.unlinked_deleted as f64),
        );
        obj.insert(
            "unchanged".to_string(),
            JsonValue::Number(self.unchanged as f64),
        );
        obj.insert(
            "syncedAtEpochSec".to_string(),
            JsonValue::Number(self.synced_at_epoch_sec as f64),
        );
        JsonValue::Object(obj)
    }
}

/// Transport protocol kind used for Gemini Notebook operations.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotebookTransportKind {
    /// Internal Google batch execute RPC endpoint over HTTPS.
    WebBatchExecute,
    /// gRPC endpoint for Android clients.
    AndroidGrpc,
}

/// Kind of source material in a Gemini Notebook.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotebookSourceKind {
    /// Audio recording transcript.
    Transcript,
    /// User text note.
    TextNote,
    /// Document or file content.
    Document,
    /// Web page URL.
    Url,
}

impl NotebookSourceKind {
    /// Returns the wire string.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Transcript => "transcript",
            Self::TextNote => "text_note",
            Self::Document => "document",
            Self::Url => "url",
        }
    }

    /// Parses a wire string.
    #[must_use]
    pub fn parse(s: &str) -> Self {
        match s.trim() {
            "transcript" => Self::Transcript,
            "document" => Self::Document,
            "url" => Self::Url,
            _ => Self::TextNote,
        }
    }
}

/// An ingested source in a Gemini Notebook.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotebookSource {
    /// Unique source identifier (`"src-1"`).
    pub source_id: String,
    /// Source title.
    pub title: String,
    /// Source material kind.
    pub kind: NotebookSourceKind,
    /// Text content.
    pub content: String,
    /// SHA-256 hex digest of `content`.
    pub content_hash: String,
    /// Optional originating Koe recording ID.
    pub recording_id: Option<String>,
    /// Added timestamp in Unix seconds.
    pub added_at_epoch_sec: u64,
}

impl NotebookSource {
    /// Serializes this source to JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "sourceId".to_string(),
            JsonValue::String(self.source_id.clone()),
        );
        obj.insert("title".to_string(), JsonValue::String(self.title.clone()));
        obj.insert(
            "kind".to_string(),
            JsonValue::String(self.kind.as_str().to_string()),
        );
        obj.insert(
            "content".to_string(),
            JsonValue::String(self.content.clone()),
        );
        obj.insert(
            "contentHash".to_string(),
            JsonValue::String(self.content_hash.clone()),
        );
        if let Some(ref rid) = self.recording_id {
            obj.insert("recordingId".to_string(), JsonValue::String(rid.clone()));
        }
        obj.insert(
            "addedAtEpochSec".to_string(),
            JsonValue::Number(self.added_at_epoch_sec as f64),
        );
        JsonValue::Object(obj)
    }

    /// Restores a source from JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected source object".to_string());
        };
        let source_id = obj
            .get("sourceId")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| "missing sourceId".to_string())?
            .to_string();
        let title = obj
            .get("title")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let kind = obj
            .get("kind")
            .and_then(JsonValue::as_str)
            .map(NotebookSourceKind::parse)
            .unwrap_or(NotebookSourceKind::TextNote);
        let content = obj
            .get("content")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let content_hash = obj
            .get("contentHash")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let recording_id = obj
            .get("recordingId")
            .and_then(JsonValue::as_str)
            .map(ToString::to_string);
        let added_at_epoch_sec = obj
            .get("addedAtEpochSec")
            .and_then(JsonValue::as_i64)
            .unwrap_or(0) as u64;

        Ok(Self {
            source_id,
            title,
            kind,
            content,
            content_hash,
            recording_id,
            added_at_epoch_sec,
        })
    }
}

/// Generation status for a NotebookLM Audio Overview (podcast).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotebookAudioOverviewStatus {
    /// Not generated.
    NotGenerated,
    /// Queued.
    Queued,
    /// Synthesizing.
    Synthesizing,
    /// Ready.
    Ready,
    /// Failed.
    Failed,
}

impl NotebookAudioOverviewStatus {
    /// Returns the wire status string.
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::NotGenerated => "not_generated",
            Self::Queued => "queued",
            Self::Synthesizing => "synthesizing",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }

    /// Parses a wire status string.
    #[must_use]
    pub fn parse(s: &str) -> Self {
        match s.trim() {
            "queued" => Self::Queued,
            "synthesizing" => Self::Synthesizing,
            "ready" => Self::Ready,
            "failed" => Self::Failed,
            _ => Self::NotGenerated,
        }
    }
}

/// Audio Overview podcast dialogue script and status.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotebookAudioOverview {
    /// Overview artifact identifier (`"ao-1"`).
    pub overview_id: String,
    /// User focus prompt.
    pub focus_prompt: String,
    /// Generation status.
    pub status: NotebookAudioOverviewStatus,
    /// Dialogue script.
    pub dialogue_script: String,
    /// Synthesized audio URL or local path.
    pub audio_url: Option<String>,
    /// Duration in milliseconds.
    pub duration_ms: u64,
    /// Cited segment IDs.
    pub citations: Vec<SegmentId>,
    /// Updated timestamp in Unix seconds.
    pub updated_at_epoch_sec: u64,
}

impl NotebookAudioOverview {
    /// Serializes this overview to JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "overviewId".to_string(),
            JsonValue::String(self.overview_id.clone()),
        );
        obj.insert(
            "focusPrompt".to_string(),
            JsonValue::String(self.focus_prompt.clone()),
        );
        obj.insert(
            "status".to_string(),
            JsonValue::String(self.status.as_str().to_string()),
        );
        obj.insert(
            "dialogueScript".to_string(),
            JsonValue::String(self.dialogue_script.clone()),
        );
        if let Some(ref url) = self.audio_url {
            obj.insert("audioUrl".to_string(), JsonValue::String(url.clone()));
        }
        obj.insert(
            "durationMs".to_string(),
            JsonValue::Number(self.duration_ms as f64),
        );
        obj.insert(
            "citations".to_string(),
            JsonValue::Array(
                self.citations
                    .iter()
                    .map(|s| JsonValue::String(s.to_string()))
                    .collect(),
            ),
        );
        obj.insert(
            "updatedAtEpochSec".to_string(),
            JsonValue::Number(self.updated_at_epoch_sec as f64),
        );
        JsonValue::Object(obj)
    }

    /// Restores an overview from JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected overview object".to_string());
        };
        let overview_id = obj
            .get("overviewId")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| "missing overviewId".to_string())?
            .to_string();
        let focus_prompt = obj
            .get("focusPrompt")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let status = obj
            .get("status")
            .and_then(JsonValue::as_str)
            .map(NotebookAudioOverviewStatus::parse)
            .unwrap_or(NotebookAudioOverviewStatus::NotGenerated);
        let dialogue_script = obj
            .get("dialogueScript")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let audio_url = obj
            .get("audioUrl")
            .and_then(JsonValue::as_str)
            .map(ToString::to_string);
        let duration_ms = obj
            .get("durationMs")
            .and_then(JsonValue::as_i64)
            .unwrap_or(0) as u64;
        let citations = obj
            .get("citations")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(JsonValue::as_str)
                    .filter_map(SegmentId::parse_citation)
                    .collect()
            })
            .unwrap_or_default();
        let updated_at_epoch_sec = obj
            .get("updatedAtEpochSec")
            .and_then(JsonValue::as_i64)
            .unwrap_or(0) as u64;

        Ok(Self {
            overview_id,
            focus_prompt,
            status,
            dialogue_script,
            audio_url,
            duration_ms,
            citations,
            updated_at_epoch_sec,
        })
    }
}

/// A grounded Q&A turn stored inside a [`GeminiNotebook`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotebookQaTurn {
    /// User question posed to the notebook.
    pub question: String,
    /// Grounded answer citing `[S#]` segments and `source_id`s.
    pub answer: String,
    /// Supporting `source_id`s from the notebook.
    pub cited_source_ids: Vec<String>,
    /// Supporting Koe [`SegmentId`]s.
    pub cited_segments: Vec<SegmentId>,
    /// UTC timestamp in Unix seconds.
    pub answered_at_epoch_sec: u64,
}

impl NotebookQaTurn {
    /// Serializes this Q&A turn to JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "question".to_string(),
            JsonValue::String(self.question.clone()),
        );
        obj.insert("answer".to_string(), JsonValue::String(self.answer.clone()));
        obj.insert(
            "citedSourceIds".to_string(),
            JsonValue::Array(
                self.cited_source_ids
                    .iter()
                    .cloned()
                    .map(JsonValue::String)
                    .collect(),
            ),
        );
        obj.insert(
            "citedSegments".to_string(),
            JsonValue::Array(
                self.cited_segments
                    .iter()
                    .map(|s| JsonValue::String(s.to_string()))
                    .collect(),
            ),
        );
        obj.insert(
            "answeredAtEpochSec".to_string(),
            JsonValue::Number(self.answered_at_epoch_sec as f64),
        );
        JsonValue::Object(obj)
    }

    /// Deserializes a Q&A turn from JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected Q&A turn object".to_string());
        };
        let question = obj
            .get("question")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let answer = obj
            .get("answer")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let cited_source_ids = obj
            .get("citedSourceIds")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(JsonValue::as_str)
                    .map(ToString::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let cited_segments = obj
            .get("citedSegments")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(JsonValue::as_str)
                    .filter_map(SegmentId::parse_citation)
                    .collect()
            })
            .unwrap_or_default();
        let answered_at_epoch_sec = obj
            .get("answeredAtEpochSec")
            .and_then(JsonValue::as_i64)
            .unwrap_or(0) as u64;

        Ok(Self {
            question,
            answer,
            cited_source_ids,
            cited_segments,
            answered_at_epoch_sec,
        })
    }
}

/// A Google Gemini Notebook (`NotebookLM`) containing sources, audio overviews, and grounded Q&A.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GeminiNotebook {
    /// Notebook identifier.
    pub id: NotebookId,
    /// Notebook title.
    pub title: String,
    /// Deduplicated sources attached to this notebook.
    pub sources: Vec<NotebookSource>,
    /// Generated Audio Overviews.
    pub audio_overviews: Vec<NotebookAudioOverview>,
    /// Grounded Q&A turns.
    pub qa_history: Vec<NotebookQaTurn>,
    /// UTC timestamp in Unix seconds when last updated.
    pub updated_at_epoch_sec: u64,
}

impl GeminiNotebook {
    /// Creates a new notebook with the given title.
    #[must_use]
    pub fn new(id: NotebookId, title: impl Into<String>, now_epoch_sec: u64) -> Self {
        Self {
            id,
            title: title.into(),
            sources: Vec::new(),
            audio_overviews: Vec::new(),
            qa_history: Vec::new(),
            updated_at_epoch_sec: now_epoch_sec,
        }
    }

    /// Serializes this notebook to JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("id".to_string(), JsonValue::String(self.id.0.clone()));
        obj.insert("title".to_string(), JsonValue::String(self.title.clone()));
        obj.insert(
            "sources".to_string(),
            JsonValue::Array(
                self.sources
                    .iter()
                    .map(NotebookSource::to_json_value)
                    .collect(),
            ),
        );
        obj.insert(
            "audioOverviews".to_string(),
            JsonValue::Array(
                self.audio_overviews
                    .iter()
                    .map(NotebookAudioOverview::to_json_value)
                    .collect(),
            ),
        );
        obj.insert(
            "qaHistory".to_string(),
            JsonValue::Array(
                self.qa_history
                    .iter()
                    .map(NotebookQaTurn::to_json_value)
                    .collect(),
            ),
        );
        obj.insert(
            "updatedAtEpochSec".to_string(),
            JsonValue::Number(self.updated_at_epoch_sec as f64),
        );
        JsonValue::Object(obj)
    }

    /// Deserializes a notebook from JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected notebook object".to_string());
        };
        let id = obj
            .get("id")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| "missing notebook id".to_string())?;
        let title = obj
            .get("title")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let sources = obj
            .get("sources")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| NotebookSource::from_json_value(v).ok())
                    .collect()
            })
            .unwrap_or_default();
        let audio_overviews = obj
            .get("audioOverviews")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| NotebookAudioOverview::from_json_value(v).ok())
                    .collect()
            })
            .unwrap_or_default();
        let qa_history = obj
            .get("qaHistory")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| NotebookQaTurn::from_json_value(v).ok())
                    .collect()
            })
            .unwrap_or_default();
        let updated_at_epoch_sec = obj
            .get("updatedAtEpochSec")
            .and_then(JsonValue::as_i64)
            .unwrap_or(0) as u64;

        Ok(Self {
            id: NotebookId(id.to_string()),
            title,
            sources,
            audio_overviews,
            qa_history,
            updated_at_epoch_sec,
        })
    }
}

/// Canonical RPC operation identifiers for Google Gemini Notebook (`NotebookLM`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotebookRpcOp {
    /// Create a new notebook (`rpcid: "CCqFvf"`).
    CreateNotebook,
    /// Add a transcript, minutes, or text source to a notebook (`rpcid: "izAoDd"`).
    AddSource,
    /// Generate an Audio Overview / studio discussion (`rpcid: "RM37f"`).
    CreateAudioOverview,
    /// Ask a grounded question with source citations against a notebook (`rpcid: "VfAZjd"`).
    QueryGroundedQa,
}

impl NotebookRpcOp {
    /// Returns the web `batchexecute` RPC identifier (`rpcid`) for this operation.
    #[must_use]
    pub const fn batchexecute_rpcid(self) -> &'static str {
        match self {
            Self::CreateNotebook => "CCqFvf",
            Self::AddSource => "izAoDd",
            Self::CreateAudioOverview => "RM37f",
            Self::QueryGroundedQa => "VfAZjd",
        }
    }

    /// Returns the Android gRPC method path for this operation.
    #[must_use]
    pub const fn grpc_method_path(self) -> &'static str {
        match self {
            Self::CreateNotebook => {
                "/google.internal.labs.tailwind.v1.LabsTailwindService/CreateProject"
            }
            Self::AddSource => "/google.internal.labs.tailwind.v1.LabsTailwindService/AddSources",
            Self::CreateAudioOverview => {
                "/google.internal.labs.tailwind.v1.LabsTailwindService/CreateAudioOverview"
            }
            Self::QueryGroundedQa => {
                "/google.internal.labs.tailwind.v1.LabsTailwindService/GenerateAnswer"
            }
        }
    }
}

/// Encodes a `batchexecute` HTTP POST form body (`f.req=[[[rpcid, json_payload, null, "generic"]]]`)
/// for Google Gemini Notebook web calls.
#[must_use]
pub fn encode_batchexecute_envelope(op: NotebookRpcOp, inner_args: &JsonValue) -> String {
    let payload_str = inner_args.to_json_string();
    let inner_call = JsonValue::Array(vec![
        JsonValue::String(op.batchexecute_rpcid().to_string()),
        JsonValue::String(payload_str),
        JsonValue::Null,
        JsonValue::String("generic".to_string()),
    ]);
    let envelope = JsonValue::Array(vec![JsonValue::Array(vec![inner_call])]);
    let raw = envelope.to_json_string();
    let mut out = String::with_capacity(raw.len() * 3 + 6);
    out.push_str("f.req=");
    for b in raw.bytes() {
        if b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'.' || b == b'~' {
            out.push(b as char);
        } else {
            use std::fmt::Write;
            let _ = write!(out, "%{b:02X}");
        }
    }
    out
}

/// Decodes a `batchexecute` response body (stripping the `)]}'` anti-XSSI prefix and extracting
/// the `wrb.fr` payload for `expected_rpcid`).
pub fn decode_batchexecute_response(
    raw_body: &str,
    expected_rpcid: &str,
) -> Result<JsonValue, String> {
    let stripped = raw_body.trim().trim_start_matches(")]}'").trim();
    let parsed = JsonValue::parse(stripped)
        .map_err(|e| format!("invalid batchexecute response JSON: {e:?}"))?;

    fn find_payload(val: &JsonValue, target_rpcid: &str) -> Option<String> {
        if let Some(arr) = val.as_array() {
            if arr.len() >= 3 {
                if let (Some(tag), Some(rpcid), Some(payload)) =
                    (arr[0].as_str(), arr[1].as_str(), arr[2].as_str())
                {
                    if tag == "wrb.fr" && rpcid == target_rpcid {
                        return Some(payload.to_string());
                    }
                }
            }
            for item in arr {
                if let Some(res) = find_payload(item, target_rpcid) {
                    return Some(res);
                }
            }
        }
        None
    }

    let payload_str = find_payload(&parsed, expected_rpcid)
        .ok_or_else(|| format!("RPC ID '{expected_rpcid}' not found in batchexecute envelope"))?;

    JsonValue::parse(&payload_str)
        .map_err(|e| format!("invalid inner payload JSON for '{expected_rpcid}': {e:?}"))
}

/// Canonical background color palette supported by Google Keep (`notes/v1`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeepNoteColor {
    /// Default white/theme background (`"DEFAULT"`).
    Default,
    /// Red (`"RED"`).
    Red,
    /// Orange (`"ORANGE"`).
    Orange,
    /// Yellow (`"YELLOW"`).
    Yellow,
    /// Green (`"GREEN"`).
    Green,
    /// Teal (`"TEAL"`).
    Teal,
    /// Blue (`"BLUE"`).
    Blue,
    /// Gray (`"GRAY"`).
    Gray,
}

impl KeepNoteColor {
    /// Returns the uppercase Google Keep wire color name.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Default => "DEFAULT",
            Self::Red => "RED",
            Self::Orange => "ORANGE",
            Self::Yellow => "YELLOW",
            Self::Green => "GREEN",
            Self::Teal => "TEAL",
            Self::Blue => "BLUE",
            Self::Gray => "GRAY",
        }
    }

    /// Parses a case-insensitive color name into [`KeepNoteColor`].
    #[must_use]
    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_uppercase().as_str() {
            "DEFAULT" => Some(Self::Default),
            "RED" => Some(Self::Red),
            "ORANGE" => Some(Self::Orange),
            "YELLOW" => Some(Self::Yellow),
            "GREEN" => Some(Self::Green),
            "TEAL" => Some(Self::Teal),
            "BLUE" => Some(Self::Blue),
            "GRAY" | "GREY" => Some(Self::Gray),
            _ => None,
        }
    }
}

/// A single checklist row inside a Google Keep note (`listContent`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeepChecklistItem {
    /// Item text (`<= 1000` chars).
    pub text: String,
    /// Whether the checkbox is checked.
    pub checked: bool,
}

impl KeepChecklistItem {
    /// Creates a new [`KeepChecklistItem`].
    #[must_use]
    pub fn new(text: impl Into<String>, checked: bool) -> Self {
        Self {
            text: text.into(),
            checked,
        }
    }

    /// Serializes this checklist item to JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("text".to_string(), JsonValue::String(self.text.clone()));
        obj.insert("checked".to_string(), JsonValue::Bool(self.checked));
        JsonValue::Object(obj)
    }

    /// Deserializes a checklist item from JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected checklist item object".to_string());
        };
        let text = obj
            .get("text")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let checked = obj
            .get("checked")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        Ok(Self { text, checked })
    }
}

/// Input payload for creating or updating a [`KeepNote`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeepNoteDraft {
    /// Optional existing note ID to update in place; when `None`, derives a deterministic ID.
    pub id: Option<KeepNoteId>,
    /// Note title.
    pub title: String,
    /// Freeform note body text (used when `checklist` is empty).
    pub body_text: String,
    /// Checklist items (when non-empty, the note is stored as a Keep checklist note).
    pub checklist: Vec<KeepChecklistItem>,
    /// Note card color.
    pub color: KeepNoteColor,
    /// Whether the note is pinned to the top.
    pub pinned: bool,
    /// Attached Keep labels.
    pub labels: Vec<String>,
}

/// A persisted Google Keep note (`notes/v1/notes/{noteId}`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeepNote {
    /// Stable Google Keep note identifier (`"keep-..."`).
    pub id: KeepNoteId,
    /// Note title.
    pub title: String,
    /// Freeform note body text.
    pub body_text: String,
    /// Checklist items.
    pub checklist: Vec<KeepChecklistItem>,
    /// Card background color.
    pub color: KeepNoteColor,
    /// Whether the note is pinned.
    pub pinned: bool,
    /// Whether the note is archived.
    pub archived: bool,
    /// Deduplicated, sorted labels.
    pub labels: Vec<String>,
    /// UTC timestamp in Unix seconds when last modified.
    pub updated_at_epoch_sec: u64,
}

impl KeepNote {
    /// Serializes this note into Google Keep `notes/v1` REST JSON format.
    #[must_use]
    pub fn to_keep_v1_json(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "name".to_string(),
            JsonValue::String(format!("notes/{}", self.id.0)),
        );
        obj.insert("title".to_string(), JsonValue::String(self.title.clone()));
        let mut body = BTreeMap::new();
        if !self.checklist.is_empty() {
            let mut list_obj = BTreeMap::new();
            let items: Vec<JsonValue> = self
                .checklist
                .iter()
                .map(|item| {
                    let mut it = BTreeMap::new();
                    let mut text_obj = BTreeMap::new();
                    text_obj.insert("text".to_string(), JsonValue::String(item.text.clone()));
                    it.insert("text".to_string(), JsonValue::Object(text_obj));
                    it.insert("checked".to_string(), JsonValue::Bool(item.checked));
                    JsonValue::Object(it)
                })
                .collect();
            list_obj.insert("listItems".to_string(), JsonValue::Array(items));
            body.insert("list".to_string(), JsonValue::Object(list_obj));
        } else {
            let mut text_obj = BTreeMap::new();
            text_obj.insert(
                "text".to_string(),
                JsonValue::String(self.body_text.clone()),
            );
            body.insert("text".to_string(), JsonValue::Object(text_obj));
        }
        obj.insert("body".to_string(), JsonValue::Object(body));
        obj.insert(
            "color".to_string(),
            JsonValue::String(self.color.as_str().to_string()),
        );
        obj.insert("pinned".to_string(), JsonValue::Bool(self.pinned));
        obj.insert("archived".to_string(), JsonValue::Bool(self.archived));
        obj.insert(
            "labels".to_string(),
            JsonValue::Array(self.labels.iter().cloned().map(JsonValue::String).collect()),
        );
        obj.insert(
            "updateTime".to_string(),
            JsonValue::String(format_epoch_sec_rfc3339(self.updated_at_epoch_sec)),
        );
        JsonValue::Object(obj)
    }

    /// Deserializes a note from Google Keep `notes/v1` REST JSON format.
    pub fn from_keep_v1_json(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected note object".to_string());
        };
        let raw_name = obj
            .get("name")
            .and_then(JsonValue::as_str)
            .unwrap_or("notes/keep-default");
        let id_str = raw_name.strip_prefix("notes/").unwrap_or(raw_name);
        let id = KeepNoteId(id_str.to_string());
        let title = obj
            .get("title")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();

        let mut body_text = String::new();
        let mut checklist = Vec::new();
        if let Some(body_obj) = obj.get("body").and_then(JsonValue::as_object) {
            if let Some(list_obj) = body_obj.get("list").and_then(JsonValue::as_object) {
                if let Some(items) = list_obj.get("listItems").and_then(JsonValue::as_array) {
                    for it_val in items {
                        if let Some(it_obj) = it_val.as_object() {
                            let text = it_obj
                                .get("text")
                                .and_then(JsonValue::as_object)
                                .and_then(|t| t.get("text"))
                                .and_then(JsonValue::as_str)
                                .unwrap_or("")
                                .to_string();
                            let checked = it_obj
                                .get("checked")
                                .and_then(JsonValue::as_bool)
                                .unwrap_or(false);
                            checklist.push(KeepChecklistItem::new(text, checked));
                        }
                    }
                }
            } else if let Some(text_obj) = body_obj.get("text").and_then(JsonValue::as_object) {
                if let Some(t) = text_obj.get("text").and_then(JsonValue::as_str) {
                    body_text = t.to_string();
                }
            }
        }
        let color = obj
            .get("color")
            .and_then(JsonValue::as_str)
            .and_then(KeepNoteColor::parse)
            .unwrap_or(KeepNoteColor::Default);
        let pinned = obj
            .get("pinned")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        let archived = obj
            .get("archived")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        let labels = obj
            .get("labels")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(JsonValue::as_str)
                    .map(ToString::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let updated_at_epoch_sec = obj
            .get("updateTime")
            .and_then(JsonValue::as_str)
            .and_then(parse_rfc3339_to_epoch_sec)
            .unwrap_or(0);

        Ok(Self {
            id,
            title,
            body_text,
            checklist,
            color,
            pinned,
            archived,
            labels,
            updated_at_epoch_sec,
        })
    }

    /// Serializes this note to canonical internal JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("id".to_string(), JsonValue::String(self.id.0.clone()));
        obj.insert("title".to_string(), JsonValue::String(self.title.clone()));
        obj.insert(
            "bodyText".to_string(),
            JsonValue::String(self.body_text.clone()),
        );
        obj.insert(
            "checklist".to_string(),
            JsonValue::Array(
                self.checklist
                    .iter()
                    .map(KeepChecklistItem::to_json_value)
                    .collect(),
            ),
        );
        obj.insert(
            "color".to_string(),
            JsonValue::String(self.color.as_str().to_string()),
        );
        obj.insert("pinned".to_string(), JsonValue::Bool(self.pinned));
        obj.insert("archived".to_string(), JsonValue::Bool(self.archived));
        obj.insert(
            "labels".to_string(),
            JsonValue::Array(self.labels.iter().cloned().map(JsonValue::String).collect()),
        );
        obj.insert(
            "updatedAtEpochSec".to_string(),
            JsonValue::Number(self.updated_at_epoch_sec as f64),
        );
        JsonValue::Object(obj)
    }

    /// Deserializes a note from internal JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected note object".to_string());
        };
        let id = obj
            .get("id")
            .and_then(JsonValue::as_str)
            .ok_or_else(|| "missing id".to_string())?;
        let title = obj
            .get("title")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let body_text = obj
            .get("bodyText")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let checklist = obj
            .get("checklist")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(|v| KeepChecklistItem::from_json_value(v).ok())
                    .collect()
            })
            .unwrap_or_default();
        let color = obj
            .get("color")
            .and_then(JsonValue::as_str)
            .and_then(KeepNoteColor::parse)
            .unwrap_or(KeepNoteColor::Default);
        let pinned = obj
            .get("pinned")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        let archived = obj
            .get("archived")
            .and_then(JsonValue::as_bool)
            .unwrap_or(false);
        let labels = obj
            .get("labels")
            .and_then(JsonValue::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(JsonValue::as_str)
                    .map(ToString::to_string)
                    .collect()
            })
            .unwrap_or_default();
        let updated_at_epoch_sec = obj
            .get("updatedAtEpochSec")
            .and_then(JsonValue::as_i64)
            .unwrap_or(0) as u64;

        Ok(Self {
            id: KeepNoteId(id.to_string()),
            title,
            body_text,
            checklist,
            color,
            pinned,
            archived,
            labels,
            updated_at_epoch_sec,
        })
    }
}

/// Target Google service kind for outbound requests or routing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GoogleServiceKind {
    /// Google Tasks REST API (`tasks/v1`).
    Tasks,
    /// Google Gemini Notebook / NotebookLM (`batchexecute` or gRPC).
    Notebook,
    /// Google Keep REST API (`notes/v1`).
    Keep,
}

impl GoogleServiceKind {
    /// Returns the lowercase service name.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Tasks => "tasks",
            Self::Notebook => "notebook",
            Self::Keep => "keep",
        }
    }
}

/// Outbound HTTP/gRPC wire request descriptor emitted by [`GoogleSuiteStore`] mutations
/// so an online host or CLI adapter can replay changes against Google APIs idempotently.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GoogleWireRequest {
    /// Service name (`"tasks"`, `"notebook"`, `"keep"`).
    pub service: String,
    /// HTTP method (`"GET"`, `"POST"`, `"PATCH"`, `"DELETE"`).
    pub method: String,
    /// Full target URL or gRPC path.
    pub url: String,
    /// Content-Type header (`"application/json"`, `"application/x-www-form-urlencoded"`, `"application/grpc+json"`).
    pub content_type: String,
    /// Serialized request body.
    pub body: String,
}

impl GoogleWireRequest {
    /// Serializes this request descriptor to JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "service".to_string(),
            JsonValue::String(self.service.clone()),
        );
        obj.insert("method".to_string(), JsonValue::String(self.method.clone()));
        obj.insert("url".to_string(), JsonValue::String(self.url.clone()));
        obj.insert(
            "contentType".to_string(),
            JsonValue::String(self.content_type.clone()),
        );
        obj.insert("body".to_string(), JsonValue::String(self.body.clone()));
        JsonValue::Object(obj)
    }

    /// Restores a request descriptor from JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected wire request object".to_string());
        };
        let service = obj
            .get("service")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let method = obj
            .get("method")
            .and_then(JsonValue::as_str)
            .unwrap_or("POST")
            .to_string();
        let url = obj
            .get("url")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        let content_type = obj
            .get("contentType")
            .and_then(JsonValue::as_str)
            .unwrap_or("application/json")
            .to_string();
        let body = obj
            .get("body")
            .and_then(JsonValue::as_str)
            .unwrap_or("")
            .to_string();
        Ok(Self {
            service,
            method,
            url,
            content_type,
            body,
        })
    }
}

/// Single-aggregate store owning Google Tasks (+ 3-way `SystemTodoLink` baseline),
/// Google Gemini Notebooks, and Google Keep notes, with deterministic JSON persistence.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GoogleSuiteStore {
    /// Monotonically increasing store revision incremented on every mutation.
    pub revision: u64,
    /// Google Tasks keyed by `GoogleTaskId`.
    pub tasks: BTreeMap<GoogleTaskId, GoogleTaskRecord>,
    /// 3-way sync links keyed by Koe `TodoItem.id`.
    pub task_links: BTreeMap<String, SystemTodoLink>,
    /// Google Gemini Notebooks keyed by `NotebookId`.
    pub notebooks: BTreeMap<NotebookId, GeminiNotebook>,
    /// Google Keep notes keyed by `KeepNoteId`.
    pub keep_notes: BTreeMap<KeepNoteId, KeepNote>,
    /// Bounded queue (`<= 256`) of outbound Google API wire requests emitted by recent mutations.
    pub pending_wire_requests: Vec<GoogleWireRequest>,
}

impl GoogleSuiteStore {
    /// Creates an empty [`GoogleSuiteStore`].
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn queue_wire_request(&mut self, req: GoogleWireRequest) {
        if self.pending_wire_requests.len() >= 256 {
            self.pending_wire_requests.remove(0);
        }
        self.pending_wire_requests.push(req);
    }

    /// Reconciles Koe's `ContextState.todos` against `self.tasks` and `self.task_links`
    /// using [`reconcile_system_todo_sync`].
    pub fn sync_google_tasks_with_context(
        &mut self,
        context: &mut ContextState,
        tasklist_id: &str,
        now_epoch_sec: u64,
    ) -> GoogleTasksSyncReport {
        let mut report = GoogleTasksSyncReport {
            synced_at_epoch_sec: now_epoch_sec,
            ..Default::default()
        };

        let list_id = if tasklist_id.trim().is_empty() {
            "@default"
        } else {
            tasklist_id.trim()
        };

        for todo in &mut context.todos {
            if let Some(link) = self.task_links.get(&todo.id).cloned() {
                let ext_id = GoogleTaskId(link.external_id.clone());
                let task_snapshot = self
                    .tasks
                    .get(&ext_id)
                    .map(GoogleTaskRecord::to_system_snapshot);
                let has_time = todo.due_at_epoch_sec.is_some();
                let outcome =
                    reconcile_system_todo_sync(todo, &link, task_snapshot.as_ref(), true, has_time);
                match outcome {
                    SystemSyncOutcome::NoChange => {
                        report.unchanged = report.unchanged.saturating_add(1);
                    }
                    SystemSyncOutcome::PushedToExternal {
                        todo: updated_todo,
                        link: next_link,
                    } => {
                        *todo = updated_todo;
                        self.task_links.insert(todo.id.clone(), next_link);
                        let outbound = if let Some(task) = self.tasks.get_mut(&ext_id) {
                            task.title = todo.title.clone();
                            task.due_epoch_sec = todo.due_at_epoch_sec;
                            task.status = if todo.status == TodoStatus::Done {
                                GoogleTaskStatus::Completed
                            } else {
                                GoogleTaskStatus::NeedsAction
                            };
                            task.updated_at_epoch_sec = now_epoch_sec;
                            Some(GoogleWireRequest {
                                service: "tasks".to_string(),
                                method: "PATCH".to_string(),
                                url: format!(
                                    "{GOOGLE_TASKS_V1_BASE_URL}/lists/{list_id}/tasks/{}",
                                    ext_id.0
                                ),
                                content_type: "application/json".to_string(),
                                body: task.to_tasks_v1_json().to_json_string(),
                            })
                        } else {
                            None
                        };
                        if let Some(req) = outbound {
                            self.queue_wire_request(req);
                        }
                        report.pushed_to_remote = report.pushed_to_remote.saturating_add(1);
                    }
                    SystemSyncOutcome::AppliedFromExternal {
                        todo: updated_todo,
                        link: next_link,
                    } => {
                        *todo = updated_todo;
                        self.task_links.insert(todo.id.clone(), next_link);
                        report.applied_from_remote = report.applied_from_remote.saturating_add(1);
                    }
                    SystemSyncOutcome::ConflictDetected {
                        todo: _,
                        link: next_link,
                    } => {
                        self.task_links.insert(todo.id.clone(), next_link);
                        report.conflicts = report.conflicts.saturating_add(1);
                    }
                    SystemSyncOutcome::UnlinkedDeleted { todo: _ } => {
                        self.task_links.remove(&todo.id);
                        report.unlinked_deleted = report.unlinked_deleted.saturating_add(1);
                    }
                }
            } else if todo.status == TodoStatus::Open {
                let task_id_str = format!("gt-{}", todo.id);
                let ext_id = GoogleTaskId(task_id_str.clone());
                let task = GoogleTaskRecord {
                    id: ext_id.clone(),
                    tasklist_id: list_id.to_string(),
                    title: todo.title.clone(),
                    notes: format!("Synced from Koe todo {}", todo.id),
                    due_epoch_sec: todo.due_at_epoch_sec,
                    status: GoogleTaskStatus::NeedsAction,
                    deleted: false,
                    linked_koe_todo_id: Some(todo.id.clone()),
                    updated_at_epoch_sec: now_epoch_sec,
                    etag: None,
                };
                let link = SystemTodoLink {
                    external_id: task_id_str,
                    synced_title: todo.title.clone(),
                    synced_start_epoch_sec: todo.due_at_epoch_sec,
                    synced_end_epoch_sec: None,
                    synced_done: false,
                    unsynced: false,
                    conflict: None,
                };
                self.queue_wire_request(GoogleWireRequest {
                    service: "tasks".to_string(),
                    method: "POST".to_string(),
                    url: format!("{GOOGLE_TASKS_V1_BASE_URL}/lists/{list_id}/tasks"),
                    content_type: "application/json".to_string(),
                    body: task.to_tasks_v1_json().to_json_string(),
                });
                self.tasks.insert(ext_id, task);
                self.task_links.insert(todo.id.clone(), link);
                report.created_remote = report.created_remote.saturating_add(1);
            }
        }

        self.revision = self.revision.saturating_add(1);
        report
    }

    /// Creates a new Google Task item and records the mutation wire request.
    pub fn create_task(
        &mut self,
        tasklist_id: &str,
        title: &str,
        notes: &str,
        due_epoch_sec: Option<u64>,
        now_epoch_sec: u64,
    ) -> GoogleTaskRecord {
        let actual_list_id = if tasklist_id.trim().is_empty() {
            "@default"
        } else {
            tasklist_id.trim()
        };
        let task_id = GoogleTaskId(format!("task-{}", now_epoch_sec));
        let record = GoogleTaskRecord {
            id: task_id.clone(),
            tasklist_id: actual_list_id.to_string(),
            title: title.to_string(),
            notes: notes.to_string(),
            due_epoch_sec,
            status: GoogleTaskStatus::NeedsAction,
            deleted: false,
            linked_koe_todo_id: None,
            updated_at_epoch_sec: now_epoch_sec,
            etag: None,
        };
        self.queue_wire_request(GoogleWireRequest {
            service: "tasks".to_string(),
            method: "POST".to_string(),
            url: format!("{GOOGLE_TASKS_V1_BASE_URL}/lists/{actual_list_id}/tasks"),
            content_type: "application/json".to_string(),
            body: record.to_tasks_v1_json().to_json_string(),
        });
        self.tasks.insert(task_id, record.clone());
        self.revision = self.revision.saturating_add(1);
        record
    }

    /// Toggles the completion status of a Google Task.
    pub fn complete_task(
        &mut self,
        task_id: &GoogleTaskId,
        completed: bool,
        now_epoch_sec: u64,
    ) -> Result<(), String> {
        let (list_id, body) = {
            let task = self
                .tasks
                .get_mut(task_id)
                .ok_or_else(|| format!("task '{}' not found", task_id.0))?;
            task.status = if completed {
                GoogleTaskStatus::Completed
            } else {
                GoogleTaskStatus::NeedsAction
            };
            task.updated_at_epoch_sec = now_epoch_sec;
            (
                task.tasklist_id.clone(),
                task.to_tasks_v1_json().to_json_string(),
            )
        };
        self.queue_wire_request(GoogleWireRequest {
            service: "tasks".to_string(),
            method: "PATCH".to_string(),
            url: format!(
                "{GOOGLE_TASKS_V1_BASE_URL}/lists/{list_id}/tasks/{}",
                task_id.0
            ),
            content_type: "application/json".to_string(),
            body,
        });
        self.revision = self.revision.saturating_add(1);
        Ok(())
    }

    /// Marks a Google Task as deleted.
    pub fn delete_task(
        &mut self,
        task_id: &GoogleTaskId,
        now_epoch_sec: u64,
    ) -> Result<(), String> {
        let list_id = {
            let task = self
                .tasks
                .get_mut(task_id)
                .ok_or_else(|| format!("task '{}' not found", task_id.0))?;
            task.deleted = true;
            task.updated_at_epoch_sec = now_epoch_sec;
            task.tasklist_id.clone()
        };
        self.queue_wire_request(GoogleWireRequest {
            service: "tasks".to_string(),
            method: "DELETE".to_string(),
            url: format!(
                "{GOOGLE_TASKS_V1_BASE_URL}/lists/{list_id}/tasks/{}",
                task_id.0
            ),
            content_type: "application/json".to_string(),
            body: "{}".to_string(),
        });
        self.revision = self.revision.saturating_add(1);
        Ok(())
    }

    /// Returns non-deleted Google Tasks.
    #[must_use]
    pub fn list_tasks(&self) -> Vec<&GoogleTaskRecord> {
        self.tasks.values().filter(|t| !t.deleted).collect()
    }

    /// Creates a new Gemini Notebook.
    pub fn create_notebook(&mut self, title: &str, now_epoch_sec: u64) -> NotebookId {
        let id = NotebookId(format!("nb-{}", now_epoch_sec));
        let nb = GeminiNotebook::new(id.clone(), title, now_epoch_sec);
        let mut inner_args = BTreeMap::new();
        inner_args.insert("title".to_string(), JsonValue::String(title.to_string()));
        self.queue_wire_request(GoogleWireRequest {
            service: "notebook".to_string(),
            method: "POST".to_string(),
            url: GEMINI_NOTEBOOK_BATCHEXECUTE_URL.to_string(),
            content_type: "application/x-www-form-urlencoded".to_string(),
            body: encode_batchexecute_envelope(
                NotebookRpcOp::CreateNotebook,
                &JsonValue::Object(inner_args),
            ),
        });
        self.notebooks.insert(id.clone(), nb);
        self.revision = self.revision.saturating_add(1);
        id
    }

    /// Adds a source to a Gemini Notebook, deduplicating by SHA-256 hash.
    pub fn add_notebook_source(
        &mut self,
        notebook_id: &NotebookId,
        title: &str,
        content: &str,
        recording_id: Option<&str>,
        now_epoch_sec: u64,
    ) -> Result<String, String> {
        let nb = self
            .notebooks
            .get_mut(notebook_id)
            .ok_or_else(|| format!("notebook '{}' not found", notebook_id.0))?;
        let hash = sha256_hex(content.as_bytes());
        if let Some(existing) = nb.sources.iter().find(|s| s.content_hash == hash) {
            return Ok(existing.source_id.clone());
        }
        let source_id = format!("src-{}", nb.sources.len() + 1);
        let source = NotebookSource {
            source_id: source_id.clone(),
            title: title.to_string(),
            content: content.to_string(),
            content_hash: hash,
            kind: NotebookSourceKind::Transcript,
            recording_id: recording_id.map(ToString::to_string),
            added_at_epoch_sec: now_epoch_sec,
        };
        nb.sources.push(source);
        nb.updated_at_epoch_sec = now_epoch_sec;
        let mut inner_args = BTreeMap::new();
        inner_args.insert(
            "notebookId".to_string(),
            JsonValue::String(notebook_id.0.clone()),
        );
        inner_args.insert("title".to_string(), JsonValue::String(title.to_string()));
        inner_args.insert(
            "content".to_string(),
            JsonValue::String(content.to_string()),
        );
        self.queue_wire_request(GoogleWireRequest {
            service: "notebook".to_string(),
            method: "POST".to_string(),
            url: GEMINI_NOTEBOOK_BATCHEXECUTE_URL.to_string(),
            content_type: "application/x-www-form-urlencoded".to_string(),
            body: encode_batchexecute_envelope(
                NotebookRpcOp::AddSource,
                &JsonValue::Object(inner_args),
            ),
        });
        self.revision = self.revision.saturating_add(1);
        Ok(source_id)
    }

    /// Generates a grounded Audio Overview dialogue for a Gemini Notebook.
    pub fn generate_notebook_audio_overview(
        &mut self,
        notebook_id: &NotebookId,
        focus_prompt: &str,
        spine: Option<&UtteranceSpine>,
        now_epoch_sec: u64,
    ) -> Result<NotebookAudioOverview, String> {
        let nb = self
            .notebooks
            .get_mut(notebook_id)
            .ok_or_else(|| format!("notebook '{}' not found", notebook_id.0))?;
        let prompt_text = if focus_prompt.trim().is_empty() {
            "Executive summary and action items"
        } else {
            focus_prompt.trim()
        };
        let mut citations = Vec::new();
        if let Some(s) = spine {
            for seg in s.segments() {
                citations.push(seg.id);
            }
        }
        let cite_str = if citations.is_empty() {
            String::new()
        } else {
            format!(" [S{}]", citations[0].ordinal())
        };
        let script = format!(
            "Host 1: Welcome to this deep dive on '{}'{cite_str}.
Host 2: We are focusing on {prompt_text}, examining all recorded points.",
            nb.title
        );
        let overview = NotebookAudioOverview {
            overview_id: format!("ao-{}", nb.audio_overviews.len() + 1),
            focus_prompt: prompt_text.to_string(),
            status: NotebookAudioOverviewStatus::Ready,
            dialogue_script: script,
            audio_url: None,
            duration_ms: 120_000,
            citations,
            updated_at_epoch_sec: now_epoch_sec,
        };
        nb.audio_overviews.push(overview.clone());
        nb.updated_at_epoch_sec = now_epoch_sec;
        let mut inner_args = BTreeMap::new();
        inner_args.insert(
            "notebookId".to_string(),
            JsonValue::String(notebook_id.0.clone()),
        );
        inner_args.insert(
            "prompt".to_string(),
            JsonValue::String(prompt_text.to_string()),
        );
        self.queue_wire_request(GoogleWireRequest {
            service: "notebook".to_string(),
            method: "POST".to_string(),
            url: GEMINI_NOTEBOOK_BATCHEXECUTE_URL.to_string(),
            content_type: "application/x-www-form-urlencoded".to_string(),
            body: encode_batchexecute_envelope(
                NotebookRpcOp::CreateAudioOverview,
                &JsonValue::Object(inner_args),
            ),
        });
        self.revision = self.revision.saturating_add(1);
        Ok(overview)
    }

    /// Performs a grounded Q&A query over a Gemini Notebook's sources.
    pub fn query_notebook_grounded(
        &mut self,
        notebook_id: &NotebookId,
        query: &str,
        search_index: &ContextSearchIndex,
        spine: &UtteranceSpine,
        now_epoch_sec: u64,
    ) -> Result<NotebookQaTurn, String> {
        let nb = self
            .notebooks
            .get_mut(notebook_id)
            .ok_or_else(|| format!("notebook '{}' not found", notebook_id.0))?;
        let hits = search_index.search(query, 3, ScoringMode::default());
        let mut cited_segments = Vec::new();
        let mut snippets = Vec::new();
        for hit in hits {
            if let Some(seg) = spine.segments().get(hit.doc_index) {
                cited_segments.push(seg.id);
                snippets.push(format!("[S{}] {}", seg.id.ordinal(), seg.text));
            }
        }
        let cited_source_ids: Vec<String> = nb
            .sources
            .iter()
            .take(2)
            .map(|s| s.source_id.clone())
            .collect();
        let answer = if snippets.is_empty() {
            format!(
                "Based on notebook '{}', here is the grounded synthesis for '{}'.",
                nb.title, query
            )
        } else {
            format!("Based on {}: {}", nb.title, snippets.join(" "))
        };
        let turn = NotebookQaTurn {
            question: query.to_string(),
            answer,
            cited_source_ids,
            cited_segments,
            answered_at_epoch_sec: now_epoch_sec,
        };
        nb.qa_history.push(turn.clone());
        nb.updated_at_epoch_sec = now_epoch_sec;
        let mut inner_args = BTreeMap::new();
        inner_args.insert(
            "notebookId".to_string(),
            JsonValue::String(notebook_id.0.clone()),
        );
        inner_args.insert("query".to_string(), JsonValue::String(query.to_string()));
        self.queue_wire_request(GoogleWireRequest {
            service: "notebook".to_string(),
            method: "POST".to_string(),
            url: GEMINI_NOTEBOOK_BATCHEXECUTE_URL.to_string(),
            content_type: "application/x-www-form-urlencoded".to_string(),
            body: encode_batchexecute_envelope(
                NotebookRpcOp::QueryGroundedQa,
                &JsonValue::Object(inner_args),
            ),
        });
        self.revision = self.revision.saturating_add(1);
        Ok(turn)
    }

    /// Creates a Google Keep note.
    pub fn create_keep_note(&mut self, draft: KeepNoteDraft, now_epoch_sec: u64) -> KeepNote {
        let id = draft
            .id
            .unwrap_or_else(|| KeepNoteId(format!("keep-{}", now_epoch_sec)));
        let note = KeepNote {
            id: id.clone(),
            title: draft.title,
            body_text: draft.body_text,
            checklist: draft.checklist,
            color: draft.color,
            pinned: draft.pinned,
            archived: false,
            labels: draft.labels,
            updated_at_epoch_sec: now_epoch_sec,
        };
        self.queue_wire_request(GoogleWireRequest {
            service: "keep".to_string(),
            method: "POST".to_string(),
            url: format!("{GOOGLE_KEEP_V1_BASE_URL}/notes"),
            content_type: "application/json".to_string(),
            body: note.to_keep_v1_json().to_json_string(),
        });
        self.keep_notes.insert(id, note.clone());
        self.revision = self.revision.saturating_add(1);
        note
    }

    /// Toggles the checked status of a checklist item inside a Google Keep note.
    pub fn toggle_keep_checklist_item(
        &mut self,
        note_id: &KeepNoteId,
        index: usize,
        now_epoch_sec: u64,
    ) -> Result<bool, String> {
        let (new_val, body) = {
            let note = self
                .keep_notes
                .get_mut(note_id)
                .ok_or_else(|| format!("note '{}' not found", note_id.0))?;
            let item = note
                .checklist
                .get_mut(index)
                .ok_or_else(|| format!("checklist item index {} out of range", index))?;
            item.checked = !item.checked;
            let new_val = item.checked;
            note.updated_at_epoch_sec = now_epoch_sec;
            (new_val, note.to_keep_v1_json().to_json_string())
        };
        self.queue_wire_request(GoogleWireRequest {
            service: "keep".to_string(),
            method: "PATCH".to_string(),
            url: format!("{GOOGLE_KEEP_V1_BASE_URL}/notes/{}", note_id.0),
            content_type: "application/json".to_string(),
            body,
        });
        self.revision = self.revision.saturating_add(1);
        Ok(new_val)
    }

    /// Synchronizes Google Keep notes bidirectionally with Koe `ContextState`.
    pub fn sync_keep_with_context(
        &mut self,
        context: &mut ContextState,
        now_epoch_sec: u64,
    ) -> usize {
        let mut synced_count = 0;
        for note in self.keep_notes.values() {
            let item_id = format!("keep-{}", note.id.0);
            if !context.timeline.iter().any(|t| t.id == item_id) {
                let summary = if !note.checklist.is_empty() {
                    let total = note.checklist.len();
                    let done = note.checklist.iter().filter(|i| i.checked).count();
                    format!(
                        "{done}/{total} items checked: {}",
                        note.checklist
                            .iter()
                            .map(|i| i.text.as_str())
                            .collect::<Vec<_>>()
                            .join(", ")
                    )
                } else {
                    note.body_text.clone()
                };
                context.timeline.push(ContextItem {
                    id: item_id,
                    kind: ContextKind::QuickNote,
                    source: ContextSource::ManualEntry,
                    created_at_epoch_sec: note.updated_at_epoch_sec,
                    title: note.title.clone(),
                    summary,
                    project_id: None,
                    place_label: None,
                    citations: Vec::new(),
                });
                synced_count += 1;
            }
        }

        for item in &context.timeline {
            if item.kind == ContextKind::QuickNote && !item.id.starts_with("keep-") {
                let note_id = KeepNoteId(format!("keep-{}", item.id));
                if !self.keep_notes.contains_key(&note_id) {
                    let draft = KeepNoteDraft {
                        id: Some(note_id),
                        title: item.title.clone(),
                        body_text: item.summary.clone(),
                        checklist: Vec::new(),
                        color: KeepNoteColor::Default,
                        pinned: false,
                        labels: Vec::new(),
                    };
                    self.create_keep_note(draft, now_epoch_sec);
                    synced_count += 1;
                }
            }
        }

        if synced_count > 0 {
            self.revision = self.revision.saturating_add(1);
        }
        synced_count
    }

    /// Serializes this store to internal JSON.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "revision".to_string(),
            JsonValue::Number(self.revision as f64),
        );
        obj.insert(
            "tasks".to_string(),
            JsonValue::Array(
                self.tasks
                    .values()
                    .map(GoogleTaskRecord::to_json_value)
                    .collect(),
            ),
        );
        let mut links_obj = BTreeMap::new();
        for (k, v) in &self.task_links {
            let mut l = BTreeMap::new();
            l.insert(
                "externalId".to_string(),
                JsonValue::String(v.external_id.clone()),
            );
            l.insert(
                "syncedTitle".to_string(),
                JsonValue::String(v.synced_title.clone()),
            );
            if let Some(s) = v.synced_start_epoch_sec {
                l.insert(
                    "syncedStartEpochSec".to_string(),
                    JsonValue::Number(s as f64),
                );
            }
            if let Some(e) = v.synced_end_epoch_sec {
                l.insert("syncedEndEpochSec".to_string(), JsonValue::Number(e as f64));
            }
            l.insert("syncedDone".to_string(), JsonValue::Bool(v.synced_done));
            l.insert("unsynced".to_string(), JsonValue::Bool(v.unsynced));
            links_obj.insert(k.clone(), JsonValue::Object(l));
        }
        obj.insert("taskLinks".to_string(), JsonValue::Object(links_obj));
        obj.insert(
            "notebooks".to_string(),
            JsonValue::Array(
                self.notebooks
                    .values()
                    .map(GeminiNotebook::to_json_value)
                    .collect(),
            ),
        );
        obj.insert(
            "keepNotes".to_string(),
            JsonValue::Array(
                self.keep_notes
                    .values()
                    .map(KeepNote::to_json_value)
                    .collect(),
            ),
        );
        obj.insert(
            "pendingWireRequests".to_string(),
            JsonValue::Array(
                self.pending_wire_requests
                    .iter()
                    .map(GoogleWireRequest::to_json_value)
                    .collect(),
            ),
        );
        JsonValue::Object(obj)
    }

    /// Deserializes a store from internal JSON.
    pub fn from_json_value(val: &JsonValue) -> Result<Self, String> {
        let Some(obj) = val.as_object() else {
            return Err("expected google suite store object".to_string());
        };
        let revision = obj.get("revision").and_then(JsonValue::as_i64).unwrap_or(0) as u64;
        let mut tasks = BTreeMap::new();
        if let Some(arr) = obj.get("tasks").and_then(JsonValue::as_array) {
            for v in arr {
                if let Ok(rec) = GoogleTaskRecord::from_json_value(v) {
                    tasks.insert(rec.id.clone(), rec);
                }
            }
        }
        let mut task_links = BTreeMap::new();
        if let Some(links) = obj.get("taskLinks").and_then(JsonValue::as_object) {
            for (k, v) in links {
                if let Some(l_obj) = v.as_object() {
                    let external_id = l_obj
                        .get("externalId")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string();
                    let synced_title = l_obj
                        .get("syncedTitle")
                        .and_then(JsonValue::as_str)
                        .unwrap_or("")
                        .to_string();
                    let synced_start_epoch_sec = l_obj
                        .get("syncedStartEpochSec")
                        .and_then(JsonValue::as_i64)
                        .map(|x| x as u64);
                    let synced_end_epoch_sec = l_obj
                        .get("syncedEndEpochSec")
                        .and_then(JsonValue::as_i64)
                        .map(|x| x as u64);
                    let synced_done = l_obj
                        .get("syncedDone")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false);
                    let unsynced = l_obj
                        .get("unsynced")
                        .and_then(JsonValue::as_bool)
                        .unwrap_or(false);
                    task_links.insert(
                        k.clone(),
                        SystemTodoLink {
                            external_id,
                            synced_title,
                            synced_start_epoch_sec,
                            synced_end_epoch_sec,
                            synced_done,
                            unsynced,
                            conflict: None,
                        },
                    );
                }
            }
        }
        let mut notebooks = BTreeMap::new();
        if let Some(arr) = obj.get("notebooks").and_then(JsonValue::as_array) {
            for v in arr {
                if let Ok(nb) = GeminiNotebook::from_json_value(v) {
                    notebooks.insert(nb.id.clone(), nb);
                }
            }
        }
        let mut keep_notes = BTreeMap::new();
        if let Some(arr) = obj.get("keepNotes").and_then(JsonValue::as_array) {
            for v in arr {
                if let Ok(note) = KeepNote::from_json_value(v) {
                    keep_notes.insert(note.id.clone(), note);
                }
            }
        }
        let mut pending_wire_requests = Vec::new();
        if let Some(arr) = obj.get("pendingWireRequests").and_then(JsonValue::as_array) {
            for v in arr {
                if let Ok(req) = GoogleWireRequest::from_json_value(v) {
                    pending_wire_requests.push(req);
                }
            }
        }

        Ok(Self {
            revision,
            tasks,
            task_links,
            notebooks,
            keep_notes,
            pending_wire_requests,
        })
    }
}

/// Formats a Unix epoch second timestamp into RFC 3339 UTC format (`YYYY-MM-DDTHH:MM:SSZ`).
#[must_use]
pub fn format_epoch_sec_rfc3339(epoch_sec: u64) -> String {
    let days = (epoch_sec / 86_400) as i64;
    let rem_sec = epoch_sec % 86_400;
    let hour = rem_sec / 3_600;
    let minute = (rem_sec % 3_600) / 60;
    let second = rem_sec % 60;

    let z = days + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let y = (yoe as i64) + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = if m <= 2 { y + 1 } else { y };
    format!("{year:04}-{m:02}-{d:02}T{hour:02}:{minute:02}:{second:02}Z")
}

/// Parses an RFC 3339 / ISO-8601 UTC timestamp string into Unix epoch seconds.
#[must_use]
pub fn parse_rfc3339_to_epoch_sec(s: &str) -> Option<u64> {
    let text = s.trim();
    if text.len() < 10 {
        return None;
    }
    let b = text.as_bytes();
    if b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let year = text[0..4].parse::<u32>().ok()?;
    let month = text[5..7].parse::<u32>().ok()?;
    let day = text[8..10].parse::<u32>().ok()?;

    let (hour, minute, second) =
        if text.len() >= 19 && (b[10] == b'T' || b[10] == b' ') && b[13] == b':' && b[16] == b':' {
            let h = text[11..13].parse::<u32>().ok()?;
            let m = text[14..16].parse::<u32>().ok()?;
            let sec = text[17..19].parse::<u32>().ok()?;
            (h, m, sec)
        } else if text.len() >= 16 && (b[10] == b'T' || b[10] == b' ') && b[13] == b':' {
            let h = text[11..13].parse::<u32>().ok()?;
            let m = text[14..16].parse::<u32>().ok()?;
            (h, m, 0)
        } else {
            (0, 0, 0)
        };

    if !(1970..=9999).contains(&year)
        || !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 59
    {
        return None;
    }

    let y = year as i64 - if month <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u32;
    let m = month;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe as i64 - 719_468;
    if days < 0 {
        return None;
    }
    Some((days as u64) * 86_400 + (hour as u64) * 3600 + (minute as u64) * 60 + (second as u64))
}

#[cfg(test)]
mod tests {
    use super::*;
    use koe_engine::domain::{TodoItem, TodoKind};

    #[test]
    fn test_copilot_preset_chips() {
        assert_eq!(CopilotPresetChip::ALL.len(), 4);
        for chip in CopilotPresetChip::ALL {
            assert_eq!(CopilotPresetChip::parse(chip.slug()), Some(chip));
            assert_eq!(CopilotPresetChip::parse(chip.label()), Some(chip));
            assert!(!chip.prompt_template().is_empty());
            assert!(!chip.default_tool_plan().is_empty());
        }
    }

    #[test]
    fn test_copilot_provider_config_redacts_api_key() {
        let cfg = CopilotProviderConfig::openai_compatible(
            "https://custom.api/v1",
            "model-x",
            Some("secret-api-key-12345".to_string()),
        );
        let debug_str = format!("{cfg:?}");
        assert!(!debug_str.contains("secret-api-key-12345"));
        assert!(debug_str.contains("<redacted>"));

        let redacted_val = cfg.to_redacted_json_value();
        assert_eq!(
            redacted_val.as_object().unwrap().get("apiKey").unwrap(),
            &JsonValue::String("<redacted>".to_string())
        );
    }

    #[test]
    fn test_extract_segment_citations() {
        let text = "We discussed the contract in [S1] and finalized deadlines in [S12] and [S1].";
        let citations = extract_segment_citations(text);
        assert_eq!(citations.len(), 2);
        assert_eq!(citations[0].ordinal(), 1);
        assert_eq!(citations[1].ordinal(), 12);
    }

    #[test]
    fn test_copilot_session_tool_calling_loop() {
        let mut session = CopilotSession::new("test-session");
        session.start_user_prompt("Summarize meeting", 1_000);
        assert_eq!(session.phase, CopilotPhase::AwaitingModel { round: 0 });

        let tools = JsonValue::Array(Vec::new());
        let req = session.build_openai_chat_request_json(tools);
        assert_eq!(
            req.as_object()
                .unwrap()
                .get("model")
                .unwrap()
                .as_str()
                .unwrap(),
            DEFAULT_DEEPSEEK_MODEL
        );

        let mut fn_obj = BTreeMap::new();
        fn_obj.insert(
            "name".to_string(),
            JsonValue::String("get_transcript".to_string()),
        );
        fn_obj.insert(
            "arguments".to_string(),
            JsonValue::String(r#"{"recording_id":"active"}"#.to_string()),
        );
        let mut call_obj = BTreeMap::new();
        call_obj.insert("id".to_string(), JsonValue::String("call_abc".to_string()));
        call_obj.insert(
            "type".to_string(),
            JsonValue::String("function".to_string()),
        );
        call_obj.insert("function".to_string(), JsonValue::Object(fn_obj));
        let mut msg_obj = BTreeMap::new();
        msg_obj.insert(
            "role".to_string(),
            JsonValue::String("assistant".to_string()),
        );
        msg_obj.insert(
            "tool_calls".to_string(),
            JsonValue::Array(vec![JsonValue::Object(call_obj)]),
        );
        let mut choice_obj = BTreeMap::new();
        choice_obj.insert("message".to_string(), JsonValue::Object(msg_obj));
        let mut resp_obj = BTreeMap::new();
        resp_obj.insert(
            "choices".to_string(),
            JsonValue::Array(vec![JsonValue::Object(choice_obj)]),
        );

        let phase = session
            .ingest_openai_chat_response(&JsonValue::Object(resp_obj), 1_001)
            .unwrap();
        match phase {
            CopilotPhase::PendingLocalTools { round, calls } => {
                assert_eq!(round, 0);
                assert_eq!(calls.len(), 1);
                assert_eq!(calls[0].tool_name, "get_transcript");
            }
            _ => panic!("unexpected phase"),
        }

        let mut res = BTreeMap::new();
        res.insert(
            "transcript".to_string(),
            JsonValue::String("hello world".to_string()),
        );
        session.record_tool_result(
            ToolCallId("call_abc".to_string()),
            "get_transcript",
            &JsonValue::Object(res),
            1_002,
        );
        assert_eq!(session.total_tool_calls, 1);

        let next_phase = session.advance_after_tools_executed().unwrap();
        assert_eq!(next_phase, CopilotPhase::AwaitingModel { round: 1 });

        session.complete_turn("Here is the summary based on [S1].", 1_003);
        match session.phase {
            CopilotPhase::Completed {
                reply_text,
                citations,
            } => {
                assert!(reply_text.contains("[S1]"));
                assert_eq!(citations.len(), 1);
            }
            _ => panic!("unexpected completion phase"),
        }
    }

    #[test]
    fn test_google_tasks_sync_with_context() {
        let mut store = GoogleSuiteStore::new();
        let mut context = ContextState::default();
        context.todos.push(TodoItem {
            id: "todo-1".to_string(),
            title: "Review supply contract".to_string(),
            due_at_epoch_sec: Some(1_762_540_000),
            status: TodoStatus::Open,
            kind: TodoKind::Mine,
            assignee: None,
            created_at_epoch_sec: 1_762_500_000,
            citations: Vec::new(),
        });

        let report = store.sync_google_tasks_with_context(&mut context, "@default", 1_762_510_000);
        assert_eq!(report.created_remote, 1);
        assert_eq!(store.tasks.len(), 1);
        assert_eq!(store.task_links.len(), 1);
        assert_eq!(store.pending_wire_requests.len(), 1);

        let report2 = store.sync_google_tasks_with_context(&mut context, "@default", 1_762_510_001);
        assert_eq!(report2.unchanged, 1);
        assert_eq!(report2.created_remote, 0);

        context.todos[0].status = TodoStatus::Done;
        let report3 = store.sync_google_tasks_with_context(&mut context, "@default", 1_762_510_002);
        assert_eq!(report3.pushed_to_remote, 1);
        let task = store
            .tasks
            .get(&GoogleTaskId("gt-todo-1".to_string()))
            .unwrap();
        assert_eq!(task.status, GoogleTaskStatus::Completed);
    }

    #[test]
    fn test_gemini_notebook_and_batchexecute() {
        let mut store = GoogleSuiteStore::new();
        let nb_id = store.create_notebook("Test Project", 1_000);
        assert_eq!(store.notebooks.len(), 1);

        let src_id = store
            .add_notebook_source(
                &nb_id,
                "Transcript 1",
                "Sample text [S1]",
                Some("rec-1"),
                1_001,
            )
            .unwrap();
        assert_eq!(src_id, "src-1");

        let src_id2 = store
            .add_notebook_source(
                &nb_id,
                "Transcript 1 Duplicate",
                "Sample text [S1]",
                None,
                1_002,
            )
            .unwrap();
        assert_eq!(src_id2, "src-1");

        let mut args = BTreeMap::new();
        args.insert("title".to_string(), JsonValue::String("Test".to_string()));
        let env =
            encode_batchexecute_envelope(NotebookRpcOp::CreateNotebook, &JsonValue::Object(args));
        assert!(env.starts_with("f.req="));

        let mock_resp = r#")]}'
[[["wrb.fr","CCqFvf","{\"notebookId\":\"nb-created\"}",null,null,null,"generic"]]]"#;
        let decoded = decode_batchexecute_response(mock_resp, "CCqFvf").unwrap();
        assert_eq!(
            decoded
                .as_object()
                .unwrap()
                .get("notebookId")
                .unwrap()
                .as_str()
                .unwrap(),
            "nb-created"
        );
    }

    #[test]
    fn test_keep_notes_and_context_sync() {
        let mut store = GoogleSuiteStore::new();
        let draft = KeepNoteDraft {
            id: None,
            title: "Shopping".to_string(),
            body_text: "".to_string(),
            checklist: vec![
                KeepChecklistItem::new("Apples", false),
                KeepChecklistItem::new("Oranges", true),
            ],
            color: KeepNoteColor::Yellow,
            pinned: true,
            labels: vec!["groceries".to_string()],
        };
        let note = store.create_keep_note(draft, 1_000);
        assert_eq!(note.checklist.len(), 2);
        assert_eq!(note.color, KeepNoteColor::Yellow);

        let keep_json = note.to_keep_v1_json();
        let restored = KeepNote::from_keep_v1_json(&keep_json).unwrap();
        assert_eq!(restored.title, "Shopping");
        assert_eq!(restored.checklist.len(), 2);
        assert_eq!(restored.color, KeepNoteColor::Yellow);

        let mut context = ContextState::default();
        let synced = store.sync_keep_with_context(&mut context, 1_001);
        assert_eq!(synced, 1);
        assert_eq!(context.timeline.len(), 1);
        assert_eq!(context.timeline[0].title, "Shopping");
    }

    #[test]
    fn test_rfc3339_roundtrip() {
        let ts = 1_762_540_000u64;
        let formatted = format_epoch_sec_rfc3339(ts);
        let parsed = parse_rfc3339_to_epoch_sec(&formatted);
        assert_eq!(parsed, Some(ts));

        assert_eq!(parse_rfc3339_to_epoch_sec("1970-01-01T00:00:00Z"), Some(0));
    }

    #[test]
    fn test_google_suite_store_persistence_roundtrip() {
        let mut store = GoogleSuiteStore::new();
        let task = store.create_task(
            "@default",
            "Urgent Task",
            "Call supplier",
            Some(1_762_540_000),
            1_000,
        );
        let _ = store.create_notebook("AI Research", 1_001);
        let draft = KeepNoteDraft {
            id: None,
            title: "Idea".to_string(),
            body_text: "Great idea".to_string(),
            checklist: Vec::new(),
            color: KeepNoteColor::Teal,
            pinned: false,
            labels: vec!["brainstorm".to_string()],
        };
        let _ = store.create_keep_note(draft, 1_002);

        let json_val = store.to_json_value();
        let restored = GoogleSuiteStore::from_json_value(&json_val).unwrap();

        assert_eq!(restored.revision, store.revision);
        assert_eq!(restored.tasks.len(), 1);
        assert_eq!(restored.notebooks.len(), 1);
        assert_eq!(restored.keep_notes.len(), 1);
        assert_eq!(restored.tasks.get(&task.id).unwrap().title, "Urgent Task");
    }
}
