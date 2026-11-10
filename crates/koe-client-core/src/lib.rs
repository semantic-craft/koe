//! Shared client configuration defaults, version contract, Copilot / Google Suite
//! schema & state machines, and UI design tokens (`theme`, `preferences`) across all native Koe hosts.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

pub mod copilot_google;
pub mod preferences;
pub mod theme;

pub use copilot_google::{
    extract_segment_citations, format_epoch_sec_rfc3339, parse_rfc3339_to_epoch_sec,
    CopilotAuthStyle, CopilotError, CopilotMessage, CopilotPhase, CopilotPresetChip,
    CopilotProviderConfig, CopilotRole, CopilotSession, CopilotToolCall, GeminiNotebook,
    GoogleServiceKind, GoogleSuiteStore, GoogleTaskId, GoogleTaskRecord, GoogleTaskStatus,
    GoogleTasksSyncReport, GoogleWireRequest, KeepChecklistItem, KeepNote, KeepNoteColor,
    KeepNoteDraft, KeepNoteId, NotebookAudioOverview, NotebookAudioOverviewStatus, NotebookId,
    NotebookQaTurn, NotebookRpcOp, NotebookSource, NotebookSourceKind, NotebookTransportKind,
    ToolCallId, COPILOT_PRESET_CHIPS, COPILOT_SYSTEM_PROMPT, DEEPSEEK_CHAT_COMPLETIONS_URL,
    DEFAULT_DEEPSEEK_MODEL, GEMINI_NOTEBOOK_BATCHEXECUTE_URL, GEMINI_NOTEBOOK_GRPC_SERVICE,
    GOOGLE_KEEP_V1_BASE_URL, GOOGLE_TASKS_V1_BASE_URL, MAX_COPILOT_TOOL_ROUNDS,
};
pub use preferences::{
    ClientPreferences, DEFAULT_ASR_MODEL, DEFAULT_MINUTES_MODEL, DEFAULT_TRANSLATION_TARGET_LANG,
    KOE_CLIENT_VERSION,
};
pub use theme::{
    AIVisualEditorialPalette, AppColors, AppFontSizes, AppRadii, EditorialCardRole,
    EditorialRolePalette,
};
