//! Native JSON-RPC 2.0 MCP (`2025-11-25`) tool registry, `KOEMCP1.` pairing ticket codec,
//! 15-second live publication lease validator, `.koepack v2` `/sync/packs` store,
//! `qwennote-minutes` hotword/speaker/template catalog, and ACP (`2026-01-01`) task runtime.

#![forbid(unsafe_code)]
#![deny(missing_docs)]

use std::collections::{BTreeMap, BTreeSet};

use crate::cicada::{
    decode_koepack_v2, encode_koepack_v2, MaterialPackV2, PackMaterialMeta, PackMinutesV2,
    PortableMinutesEntry, RollingMinutesScheduler,
};
use crate::context::{ContextSearchIndex, ContextState, ScoringMode};
use crate::domain::{
    ContextItem, ContextKind, ContextSource, SegmentId, TodoItem, TodoKind, TodoStatus,
    UtteranceSpine,
};
use crate::hash::{is_valid_sha256_hex, sha256_hex};
use crate::library::{RecordingEntry, RecordingLibrary};
use crate::minutes::{
    encode_meeting_minutes_json, extract_json_object, parse_meeting_minutes_json,
    replace_minute_terms, JsonValue, MinutesState, BUILTIN_MINUTE_TEMPLATES,
};

/// Canonical MCP protocol version required during `initialize`.
pub const MCP_PROTOCOL_VERSION: &str = "2025-11-25";

/// Canonical ACP (Agent Communication Protocol) version returned by `acp/initialize`.
pub const ACP_PROTOCOL_VERSION: &str = "2026-01-01";

/// Prefix for base64url-encoded Koe MCP pairing tickets (`"KOEMCP1."`).
pub const PAIRING_TICKET_PREFIX: &str = "KOEMCP1.";

/// Maximum permitted remaining lease seconds on a `live.json` publication (`20` s).
pub const LIVE_LEASE_MAX_REMAINING_SEC: i64 = 20;

/// Default lease TTL in seconds written when publishing a live recording (`15` s).
pub const LIVE_LEASE_DEFAULT_TTL_SEC: u64 = 15;

/// Maximum UTF-8 byte length accepted for a single JSON-RPC 2.0 request (`64 KiB`).
pub const MAX_JSONRPC_REQUEST_BYTES: usize = 64 * 1024;

/// Maximum UTF-8 byte length permitted for a single JSON-RPC 2.0 response (`1 MiB`).
pub const MAX_JSONRPC_RESPONSE_BYTES: usize = 1024 * 1024;

/// Maximum log lines retained per [`AcpTaskRecord`] (`1000`).
pub const MAX_ACP_TASK_LOGS: usize = 1000;

/// Canonical MCP tools exposed by Koe's local and VPS agent bridge.
pub const KOE_MCP_TOOLS: [&str; 6] = [
    "list_recordings",
    "get_transcript",
    "get_minutes",
    "search_context",
    "sync_qwennote_hotwords",
    "export_koepack_v2",
];

/// Canonical ACP JSON-RPC 2.0 methods exposed by Koe's native agent runtime.
pub const KOE_ACP_METHODS: [&str; 6] = [
    "acp/initialize",
    "acp/session.start",
    "acp/task.send",
    "acp/task.status",
    "acp/task.cancel",
    "acp/agent.card",
];

/// Returns `true` if `tool_name` is a registered Koe MCP tool.
#[must_use]
pub fn is_supported_mcp_tool(tool_name: &str) -> bool {
    KOE_MCP_TOOLS.contains(&tool_name.trim())
}

/// Compares two byte slices in constant time with respect to their contents.
///
/// Returns `false` immediately when `a` and `b` have different lengths or are empty.
#[must_use]
pub fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() || a.is_empty() {
        return false;
    }
    let mut diff = 0u8;
    for (&x, &y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

/// Network transport mode encoded inside a [`PairingTicket`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum McpPairingMode {
    /// Cloud or self-hosted VPS relay mode (`"vps"`).
    Vps,
    /// Local area network direct mode (`"lan"`).
    Lan,
}

impl McpPairingMode {
    /// Returns the wire code (`"vps"` or `"lan"`).
    #[must_use]
    pub const fn as_str(&self) -> &'static str {
        match self {
            Self::Vps => "vps",
            Self::Lan => "lan",
        }
    }

    /// Parses a wire code (`"vps"` or `"lan"`) into [`McpPairingMode`].
    #[must_use]
    pub fn from_code(s: &str) -> Option<Self> {
        match s.trim() {
            "vps" => Some(Self::Vps),
            "lan" => Some(Self::Lan),
            _ => None,
        }
    }
}

/// Structured error codes returned by MCP tools and pairing/publication validators.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum McpToolError {
    /// Tool arguments or ticket fields failed validation (`"invalid_arguments"`).
    InvalidArguments,
    /// Requested tool name is not in [`KOE_MCP_TOOLS`] (`"unknown_tool"`).
    UnknownTool,
    /// Target recording or session does not exist (`"recording_unavailable"`).
    RecordingUnavailable,
    /// Live publication snapshot is missing (`"publication_unavailable"`).
    PublicationUnavailable,
    /// Live publication lease has expired (`remaining <= 0`, `"publication_expired"`).
    PublicationExpired,
    /// Live publication lease is malformed or exceeds 20 seconds (`"invalid_publication"`).
    InvalidPublication,
    /// `expected_revision` did not match the active revision (`"snapshot_changed"`).
    SnapshotChanged,
    /// `.koepack v2` payload or material hash failed validation (`"invalid_pack"`).
    InvalidPack,
    /// Serialized tool response exceeded [`MAX_JSONRPC_RESPONSE_BYTES`] (`"response_too_large"`).
    ResponseTooLarge,
}

impl McpToolError {
    /// Returns the canonical snake_case wire error code matching `tools/koe-mcp/server.py`.
    #[must_use]
    pub const fn as_code(self) -> &'static str {
        match self {
            Self::InvalidArguments => "invalid_arguments",
            Self::UnknownTool => "unknown_tool",
            Self::RecordingUnavailable => "recording_unavailable",
            Self::PublicationUnavailable => "publication_unavailable",
            Self::PublicationExpired => "publication_expired",
            Self::InvalidPublication => "invalid_publication",
            Self::SnapshotChanged => "snapshot_changed",
            Self::InvalidPack => "invalid_pack",
            Self::ResponseTooLarge => "response_too_large",
        }
    }
}

/// `KOEMCP1.<base64url>` pairing ticket carrying endpoint URL, Bearer token, and mode.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairingTicket {
    /// Ticket schema version (`1`).
    pub version: u8,
    /// Normalized base URL (without trailing `/` or `/mcp`).
    pub base_url: String,
    /// Bearer secret token (`>= 24` ASCII characters).
    pub token: String,
    /// Pairing mode (`Vps` or `Lan`).
    pub mode: McpPairingMode,
    /// Optional account email hint (`"e"`).
    pub email: Option<String>,
    /// Optional expiration timestamp in Unix epoch seconds (`"exp"`).
    pub expires_at_epoch_sec: Option<u64>,
}

impl PairingTicket {
    /// Normalizes a base URL by trimming whitespace, trailing `/`, and trailing `/mcp`.
    #[must_use]
    pub fn normalize_base_url(raw: &str) -> String {
        let mut s = raw.trim().trim_end_matches('/').to_string();
        if let Some(stripped) = s.strip_suffix("/mcp") {
            s = stripped.trim_end_matches('/').to_string();
        }
        s
    }

    /// Validates and encodes this ticket into a `"KOEMCP1.<base64url>"` string.
    pub fn encode(&self) -> Result<String, McpToolError> {
        if self.version != 1 {
            return Err(McpToolError::InvalidArguments);
        }
        let norm_url = Self::normalize_base_url(&self.base_url);
        if norm_url.is_empty()
            || (!norm_url.starts_with("https://") && !norm_url.starts_with("http://"))
        {
            return Err(McpToolError::InvalidArguments);
        }
        let clean_token = self.token.trim();
        if clean_token.len() < 24 {
            return Err(McpToolError::InvalidArguments);
        }
        let mut map = BTreeMap::new();
        map.insert("v".to_string(), JsonValue::Number(1.0));
        map.insert("u".to_string(), JsonValue::String(norm_url));
        map.insert("t".to_string(), JsonValue::String(clean_token.to_string()));
        map.insert(
            "m".to_string(),
            JsonValue::String(self.mode.as_str().to_string()),
        );
        if let Some(ref e) = self.email {
            let trimmed = e.trim();
            if !trimmed.is_empty() {
                map.insert("e".to_string(), JsonValue::String(trimmed.to_string()));
            }
        }
        if let Some(exp) = self.expires_at_epoch_sec {
            map.insert("exp".to_string(), JsonValue::Number(exp as f64));
        }
        let json = JsonValue::Object(map).to_json_string();
        let encoded = base64url_encode_nopad(json.as_bytes());
        Ok(format!("{PAIRING_TICKET_PREFIX}{encoded}"))
    }

    /// Decodes and validates a `"KOEMCP1.<base64url>"` ticket string.
    pub fn decode(raw: &str) -> Result<Self, McpToolError> {
        let trimmed = raw.trim();
        let Some(body) = trimmed.strip_prefix(PAIRING_TICKET_PREFIX) else {
            return Err(McpToolError::InvalidArguments);
        };
        if body.is_empty() {
            return Err(McpToolError::InvalidArguments);
        }
        let bytes = base64url_decode(body).ok_or(McpToolError::InvalidArguments)?;
        let text = String::from_utf8(bytes).map_err(|_| McpToolError::InvalidArguments)?;
        let val = JsonValue::parse(&text).map_err(|_| McpToolError::InvalidArguments)?;
        let obj = val.as_object().ok_or(McpToolError::InvalidArguments)?;

        let version_i64 = obj
            .get("v")
            .and_then(JsonValue::as_i64)
            .ok_or(McpToolError::InvalidArguments)?;
        if version_i64 != 1 {
            return Err(McpToolError::InvalidArguments);
        }
        let raw_url = obj
            .get("u")
            .and_then(JsonValue::as_str)
            .ok_or(McpToolError::InvalidArguments)?;
        let base_url = Self::normalize_base_url(raw_url);
        if base_url.is_empty()
            || (!base_url.starts_with("https://") && !base_url.starts_with("http://"))
        {
            return Err(McpToolError::InvalidArguments);
        }
        let token = obj
            .get("t")
            .and_then(JsonValue::as_str)
            .map(str::trim)
            .filter(|t| t.len() >= 24)
            .ok_or(McpToolError::InvalidArguments)?
            .to_string();
        let mode = obj
            .get("m")
            .and_then(JsonValue::as_str)
            .and_then(McpPairingMode::from_code)
            .ok_or(McpToolError::InvalidArguments)?;
        let email = match obj.get("e") {
            None | Some(JsonValue::Null) => None,
            Some(JsonValue::String(s)) => {
                let t = s.trim();
                if t.is_empty() {
                    None
                } else {
                    Some(t.to_string())
                }
            }
            _ => return Err(McpToolError::InvalidArguments),
        };
        let expires_at_epoch_sec = match obj.get("exp") {
            None | Some(JsonValue::Null) => None,
            Some(v) => {
                let n = v.as_i64().ok_or(McpToolError::InvalidArguments)?;
                if n < 0 {
                    return Err(McpToolError::InvalidArguments);
                }
                Some(n as u64)
            }
        };

        Ok(Self {
            version: 1,
            base_url,
            token,
            mode,
            email,
            expires_at_epoch_sec,
        })
    }

    /// Verifies `candidate_token` against this ticket's token and expiration at `now_epoch_sec`.
    #[must_use]
    pub fn verify_token(&self, candidate_token: &str, now_epoch_sec: u64) -> bool {
        if let Some(exp) = self.expires_at_epoch_sec {
            if now_epoch_sec >= exp {
                return false;
            }
        }
        constant_time_eq(self.token.as_bytes(), candidate_token.trim().as_bytes())
    }
}

/// 15-second live publication lease governing `live.json` freshness and revision checks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LivePublicationLease {
    /// Monotonically increasing snapshot generation/revision.
    pub generation: u64,
    /// Lease expiration timestamp in Unix epoch seconds.
    pub expires_at_epoch_sec: u64,
}

impl LivePublicationLease {
    /// Validates that the lease is currently active (`0 < remaining <= 20`) at `now_epoch_sec`.
    pub fn validate(&self, now_epoch_sec: u64) -> Result<u64, McpToolError> {
        let remaining = (self.expires_at_epoch_sec as i64) - (now_epoch_sec as i64);
        if remaining <= 0 {
            return Err(McpToolError::PublicationExpired);
        }
        if remaining > LIVE_LEASE_MAX_REMAINING_SEC {
            return Err(McpToolError::InvalidPublication);
        }
        Ok(remaining as u64)
    }

    /// Checks an optional `expected_revision` string against `self.generation`.
    pub fn check_expected_revision(&self, expected: Option<&str>) -> Result<(), McpToolError> {
        let Some(exp) = expected else {
            return Ok(());
        };
        let trimmed = exp.trim();
        if trimmed.is_empty() || !trimmed.bytes().all(|b| b.is_ascii_digit()) {
            return Err(McpToolError::InvalidArguments);
        }
        if trimmed != self.generation.to_string() {
            return Err(McpToolError::SnapshotChanged);
        }
        Ok(())
    }
}

/// Stateless helper for validating `live.json` lease windows and revision strings.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct LiveLeaseValidator;

impl LiveLeaseValidator {
    /// Validates `lease` at `now_epoch_sec`.
    pub fn validate(lease: &LivePublicationLease, now_epoch_sec: u64) -> Result<u64, McpToolError> {
        lease.validate(now_epoch_sec)
    }

    /// Validates `expected_revision` against `current_revision`.
    pub fn check_revision(
        current_revision: u64,
        expected: Option<&str>,
    ) -> Result<(), McpToolError> {
        let lease = LivePublicationLease {
            generation: current_revision,
            expires_at_epoch_sec: 0,
        };
        lease.check_expected_revision(expected)
    }
}

/// Summary metadata for a `.koepack v2` archive stored in `/sync/packs`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SyncPackSummary {
    /// 64-hex `material.contentHash` identifier.
    pub id: String,
    /// Originating recording identifier (`deviceFileId` or `contentHash`).
    pub recording_id: String,
    /// Lowercase 64-hex SHA-256 digest of the raw `.koepack` bytes.
    pub sha256: String,
    /// Human-readable material title.
    pub title: String,
    /// ISO-8601 export timestamp.
    pub exported_at_iso: String,
    /// Whether the pack contains non-empty transcript source blocks.
    pub has_transcript: bool,
    /// Whether the pack contains a validated `minutes` section (`v2`).
    pub has_minutes: bool,
}

impl SyncPackSummary {
    /// Serializes this summary into a JSON object matching `/sync/packs`.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("id".to_string(), JsonValue::String(self.id.clone()));
        obj.insert(
            "recordingId".to_string(),
            JsonValue::String(self.recording_id.clone()),
        );
        obj.insert("sha256".to_string(), JsonValue::String(self.sha256.clone()));
        obj.insert("title".to_string(), JsonValue::String(self.title.clone()));
        obj.insert(
            "exportedAt".to_string(),
            JsonValue::String(self.exported_at_iso.clone()),
        );
        obj.insert(
            "hasTranscript".to_string(),
            JsonValue::Bool(self.has_transcript),
        );
        obj.insert("hasMinutes".to_string(), JsonValue::Bool(self.has_minutes));
        JsonValue::Object(obj)
    }
}

/// Bidirectional synchronization plan between local and remote `/sync/packs` catalogs.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PackSyncDelta {
    /// Pack IDs present locally (or newer/changed locally) that should be uploaded via `PUT /sync/packs/<id>`.
    pub to_upload: Vec<String>,
    /// Pack IDs present remotely (or newer/changed remotely) that should be downloaded via `GET /sync/packs/<id>`.
    pub to_download: Vec<String>,
    /// Pack IDs whose `sha256` already matches on both sides.
    pub up_to_date: Vec<String>,
}

/// Computes the deterministic [`PackSyncDelta`] between `local` and `remote` pack catalogs.
#[must_use]
pub fn compute_pack_sync_delta(
    local: &[SyncPackSummary],
    remote: &[SyncPackSummary],
) -> PackSyncDelta {
    let mut local_map: BTreeMap<&str, &SyncPackSummary> = BTreeMap::new();
    for item in local {
        local_map.insert(item.id.as_str(), item);
    }
    let mut remote_map: BTreeMap<&str, &SyncPackSummary> = BTreeMap::new();
    for item in remote {
        remote_map.insert(item.id.as_str(), item);
    }

    let mut all_ids: BTreeSet<&str> = BTreeSet::new();
    all_ids.extend(local_map.keys().copied());
    all_ids.extend(remote_map.keys().copied());

    let mut delta = PackSyncDelta::default();
    for id in all_ids {
        match (local_map.get(id), remote_map.get(id)) {
            (Some(_), None) => delta.to_upload.push(id.to_string()),
            (None, Some(_)) => delta.to_download.push(id.to_string()),
            (Some(l), Some(r)) => {
                if l.sha256 == r.sha256 {
                    delta.up_to_date.push(id.to_string());
                } else if l.exported_at_iso >= r.exported_at_iso {
                    delta.to_upload.push(id.to_string());
                } else {
                    delta.to_download.push(id.to_string());
                }
            }
            (None, None) => {}
        }
    }
    delta
}

/// Lifecycle phase of an ACP (`2026-01-01`) agent task.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcpTaskPhase {
    /// Task was accepted and queued (`"submitted"`).
    Submitted,
    /// Task is actively executing (`"working"`).
    Working,
    /// Task finished with a grounded result (`"completed"`).
    Completed,
    /// Task was canceled by the caller (`"canceled"`).
    Canceled,
    /// Task failed validation or execution (`"failed"`).
    Failed,
}

impl AcpTaskPhase {
    /// Returns the wire representation of this phase.
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Submitted => "submitted",
            Self::Working => "working",
            Self::Completed => "completed",
            Self::Canceled => "canceled",
            Self::Failed => "failed",
        }
    }
}

/// State and bounded execution log of a single ACP task.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpTaskRecord {
    /// Deterministic task identifier (`"acp-task-1"`, ...).
    pub task_id: String,
    /// Owning ACP session identifier (`"acp-session-1"`, ...).
    pub session_id: String,
    /// Original user or peer agent prompt.
    pub prompt: String,
    /// Current lifecycle phase.
    pub phase: AcpTaskPhase,
    /// Grounded response text with `[S#]` citations.
    pub result_text: String,
    /// Bounded execution log entries (`<= MAX_ACP_TASK_LOGS`).
    pub logs: Vec<String>,
    /// Last update timestamp in Unix epoch seconds.
    pub updated_at_epoch_sec: u64,
}

impl AcpTaskRecord {
    /// Appends a log line while enforcing [`MAX_ACP_TASK_LOGS`].
    pub fn push_log(&mut self, line: impl Into<String>) {
        if self.logs.len() >= MAX_ACP_TASK_LOGS {
            self.logs.remove(0);
        }
        self.logs.push(line.into());
    }

    /// Serializes this task record to its JSON wire representation.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert(
            "taskId".to_string(),
            JsonValue::String(self.task_id.clone()),
        );
        obj.insert(
            "sessionId".to_string(),
            JsonValue::String(self.session_id.clone()),
        );
        obj.insert("prompt".to_string(), JsonValue::String(self.prompt.clone()));
        obj.insert(
            "phase".to_string(),
            JsonValue::String(self.phase.as_str().to_string()),
        );
        obj.insert(
            "result".to_string(),
            JsonValue::String(self.result_text.clone()),
        );
        obj.insert(
            "logs".to_string(),
            JsonValue::Array(
                self.logs
                    .iter()
                    .cloned()
                    .map(JsonValue::String)
                    .collect(),
            ),
        );
        obj.insert(
            "updatedAt".to_string(),
            JsonValue::Number(self.updated_at_epoch_sec as f64),
        );
        JsonValue::Object(obj)
    }
}

/// Discovery metadata returned by `acp/agent.card` and `acp/initialize`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpAgentCard {
    /// Agent network identifier (`"aid://koe.local/native-agent"`).
    pub aid: String,
    /// Human-readable agent name.
    pub name: String,
    /// Semantic version string.
    pub version: String,
    /// Supported ACP capabilities.
    pub capabilities: Vec<String>,
    /// Supported MCP tools bridged by this agent.
    pub supported_tools: Vec<String>,
}

impl Default for AcpAgentCard {
    fn default() -> Self {
        Self {
            aid: "aid://koe.local/native-agent".to_string(),
            name: "Koe Native Agent".to_string(),
            version: "0.2.0".to_string(),
            capabilities: vec![
                "mcp.tools".to_string(),
                "context.search".to_string(),
                "minutes.grounding".to_string(),
                "koepack.v2".to_string(),
            ],
            supported_tools: KOE_MCP_TOOLS.iter().map(|s| (*s).to_string()).collect(),
        }
    }
}

impl AcpAgentCard {
    /// Serializes this agent card into a JSON object.
    #[must_use]
    pub fn to_json_value(&self) -> JsonValue {
        let mut obj = BTreeMap::new();
        obj.insert("aid".to_string(), JsonValue::String(self.aid.clone()));
        obj.insert("name".to_string(), JsonValue::String(self.name.clone()));
        obj.insert(
            "version".to_string(),
            JsonValue::String(self.version.clone()),
        );
        obj.insert(
            "capabilities".to_string(),
            JsonValue::Array(
                self.capabilities
                    .iter()
                    .cloned()
                    .map(JsonValue::String)
                    .collect(),
            ),
        );
        obj.insert(
            "supportedTools".to_string(),
            JsonValue::Array(
                self.supported_tools
                    .iter()
                    .cloned()
                    .map(JsonValue::String)
                    .collect(),
            ),
        );
        JsonValue::Object(obj)
    }
}

/// In-memory `qwennote-minutes` hotword, speaker alias, and default template catalog.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QwennoteCatalog {
    /// Deduplicated personal hotwords (`<= 200`).
    pub hotwords: Vec<String>,
    /// Speaker alias replacements (`old_speaker -> new_speaker`).
    pub speaker_aliases: BTreeMap<String, String>,
    /// Active default meeting minutes template identifier.
    pub default_template_id: String,
}

impl Default for QwennoteCatalog {
    fn default() -> Self {
        Self {
            hotwords: Vec::new(),
            speaker_aliases: BTreeMap::new(),
            default_template_id: "retro".to_string(),
        }
    }
}

/// Borrowed workspace view uniting all Koe domain subsystems for a single JSON-RPC 2.0 dispatch.
pub struct McpAcpWorkspaceView<'a> {
    /// Active utterance spine (`S1..Sn`).
    pub spine: &'a mut UtteranceSpine,
    /// Local recording library.
    pub library: &'a RecordingLibrary,
    /// Structured meeting minutes state.
    pub minutes: &'a mut MinutesState,
    /// Cicada bounded rolling minutes scheduler.
    pub rolling_scheduler: &'a mut RollingMinutesScheduler,
    /// Personal context timeline and todo state.
    pub context: &'a mut ContextState,
    /// Chinese bigram + Latin stem BM25 retrieval index.
    pub search_index: &'a mut ContextSearchIndex,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct StoredSyncPack {
    summary: SyncPackSummary,
    decoded: MaterialPackV2,
    raw_bytes: Vec<u8>,
}

/// Stateful MCP (`2025-11-25`) and ACP (`2026-01-01`) protocol engine.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct McpAcpState {
    /// Total JSON-RPC 2.0 tool or ACP task invocations handled.
    pub handled_calls: u64,
    /// Last invoked MCP tool or ACP method name, if any.
    pub last_tool: Option<String>,
    /// Whether MCP `initialize` has completed on this session.
    pub mcp_initialized: bool,
    /// Whether `notifications/initialized` has been received.
    pub mcp_ready: bool,
    /// Whether `acp/initialize` has completed on this session.
    pub acp_initialized: bool,
    /// Active pairing ticket configured for Bearer authentication, if any.
    pub pairing: Option<PairingTicket>,
    /// Active 15-second live publication lease, if any.
    pub live_lease: Option<LivePublicationLease>,
    /// Synchronized `qwennote-minutes` hotwords, speaker aliases, and template selection.
    pub qwennote: QwennoteCatalog,
    sync_packs: BTreeMap<String, StoredSyncPack>,
    acp_sessions: Vec<String>,
    acp_tasks: BTreeMap<String, AcpTaskRecord>,
    next_session_seq: u64,
    next_task_seq: u64,
}

impl McpAcpState {
    /// Creates a new default [`McpAcpState`].
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Configures a [`PairingTicket`] and returns its encoded `"KOEMCP1.<base64url>"` string.
    pub fn configure_pairing(
        &mut self,
        base_url: &str,
        token: &str,
        mode: McpPairingMode,
        email: Option<&str>,
        expires_at_epoch_sec: Option<u64>,
    ) -> Result<String, McpToolError> {
        let ticket = PairingTicket {
            version: 1,
            base_url: PairingTicket::normalize_base_url(base_url),
            token: token.trim().to_string(),
            mode,
            email: email
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(ToString::to_string),
            expires_at_epoch_sec,
        };
        let encoded = ticket.encode()?;
        self.pairing = Some(ticket);
        Ok(encoded)
    }

    /// Verifies an HTTP `Authorization: Bearer <token>` header against the active pairing ticket.
    #[must_use]
    pub fn verify_bearer_header(&self, auth_header: Option<&str>, now_epoch_sec: u64) -> bool {
        let Some(ref ticket) = self.pairing else {
            return false;
        };
        let Some(raw) = auth_header else {
            return false;
        };
        let trimmed = raw.trim();
        let Some(token) = trimmed
            .strip_prefix("Bearer ")
            .or_else(|| trimmed.strip_prefix("bearer "))
        else {
            return false;
        };
        ticket.verify_token(token.trim(), now_epoch_sec)
    }

    /// Publishes or refreshes a live lease (`0 < ttl_sec <= 20`).
    pub fn publish_live_lease(
        &mut self,
        generation: u64,
        now_epoch_sec: u64,
        ttl_sec: u64,
    ) -> Result<LivePublicationLease, McpToolError> {
        if ttl_sec == 0 || (ttl_sec as i64) > LIVE_LEASE_MAX_REMAINING_SEC {
            return Err(McpToolError::InvalidPublication);
        }
        let lease = LivePublicationLease {
            generation,
            expires_at_epoch_sec: now_epoch_sec.saturating_add(ttl_sec),
        };
        self.live_lease = Some(lease);
        Ok(lease)
    }

    /// Validates and stores a `.koepack v2` archive under `/sync/packs/<material_id>`.
    pub fn put_sync_pack(
        &mut self,
        material_id: &str,
        raw_pack: &[u8],
    ) -> Result<SyncPackSummary, McpToolError> {
        let clean_id = material_id.trim().to_ascii_lowercase();
        if !is_valid_sha256_hex(&clean_id) {
            return Err(McpToolError::InvalidPack);
        }
        let decoded = decode_koepack_v2(raw_pack).map_err(|_| McpToolError::InvalidPack)?;
        if decoded.material.content_hash != clean_id {
            return Err(McpToolError::InvalidPack);
        }
        let sha256 = sha256_hex(raw_pack);
        let recording_id = decoded
            .material
            .device_file_id
            .map_or_else(|| clean_id.clone(), |id| id.to_string());
        let has_transcript = decoded
            .minutes
            .as_ref()
            .is_some_and(|m| !m.current.sources.is_empty());
        let has_minutes = decoded.minutes.is_some();
        let summary = SyncPackSummary {
            id: clean_id.clone(),
            recording_id,
            sha256,
            title: decoded.material.title.clone(),
            exported_at_iso: decoded.exported_at_iso.clone(),
            has_transcript,
            has_minutes,
        };
        self.sync_packs.insert(
            clean_id,
            StoredSyncPack {
                summary: summary.clone(),
                decoded,
                raw_bytes: raw_pack.to_vec(),
            },
        );
        Ok(summary)
    }

    /// Retrieves the raw `.koepack v2` bytes for `material_id` (`GET /sync/packs/<id>`).
    pub fn get_sync_pack(&self, material_id: &str) -> Result<&[u8], McpToolError> {
        let clean_id = material_id.trim().to_ascii_lowercase();
        self.sync_packs
            .get(&clean_id)
            .map(|p| p.raw_bytes.as_slice())
            .ok_or(McpToolError::RecordingUnavailable)
    }

    /// Lists all stored `.koepack v2` pack summaries ordered by `id` (`GET /sync/packs`).
    #[must_use]
    pub fn list_sync_packs(&self) -> Vec<SyncPackSummary> {
        self.sync_packs
            .values()
            .map(|p| p.summary.clone())
            .collect()
    }

    /// Returns the number of `.koepack v2` archives stored in memory.
    #[must_use]
    pub fn pack_count(&self) -> usize {
        self.sync_packs.len()
    }

    /// Returns the number of tracked ACP tasks.
    #[must_use]
    pub fn acp_task_count(&self) -> usize {
        self.acp_tasks.len()
    }

    /// Synchronizes `hotwords`, `speaker_aliases`, and optional `default_template_id` into [`QwennoteCatalog`].
    pub fn sync_qwennote(
        &mut self,
        hotwords: &[&str],
        speaker_aliases: &[(&str, &str)],
        default_template_id: Option<&str>,
    ) -> usize {
        for &word in hotwords {
            let clean = word.trim();
            if !clean.is_empty()
                && !self.qwennote.hotwords.iter().any(|w| w == clean)
                && self.qwennote.hotwords.len() < 200
            {
                self.qwennote.hotwords.push(clean.to_string());
            }
        }
        for &(from, to) in speaker_aliases {
            let f = from.trim();
            let t = to.trim();
            if !f.is_empty() && !t.is_empty() && f != t {
                self.qwennote
                    .speaker_aliases
                    .insert(f.to_string(), t.to_string());
            }
        }
        if let Some(tpl) = default_template_id.map(str::trim).filter(|s| !s.is_empty()) {
            if BUILTIN_MINUTE_TEMPLATES.iter().any(|b| b.id == tpl) {
                self.qwennote.default_template_id = tpl.to_string();
            }
        }
        self.qwennote.hotwords.len()
    }

    /// Dispatches a raw JSON-RPC 2.0 request or notification against `workspace` at `now_epoch_sec`.
    ///
    /// Returns `None` for notifications (`notifications/initialized` without `"id"`), or `Some(json_response)`
    /// for requests.
    pub fn dispatch_jsonrpc(
        &mut self,
        workspace: &mut McpAcpWorkspaceView<'_>,
        raw_json: &str,
        now_epoch_sec: u64,
    ) -> Option<String> {
        if raw_json.len() > MAX_JSONRPC_REQUEST_BYTES {
            return Some(jsonrpc_error_response(
                &JsonValue::Null,
                -32600,
                "Request exceeds maximum byte length",
            ));
        }
        let parsed = match JsonValue::parse(raw_json.trim()) {
            Ok(v) => v,
            Err(_) => {
                return Some(jsonrpc_error_response(
                    &JsonValue::Null,
                    -32700,
                    "Parse error",
                ));
            }
        };
        let Some(root) = parsed.as_object() else {
            return Some(jsonrpc_error_response(
                &JsonValue::Null,
                -32600,
                "Invalid Request",
            ));
        };
        let id_opt = root.get("id").cloned();
        let id_ref = id_opt.as_ref().unwrap_or(&JsonValue::Null);

        if root.get("jsonrpc").and_then(JsonValue::as_str) != Some("2.0") {
            return Some(jsonrpc_error_response(id_ref, -32600, "Invalid Request"));
        }
        let Some(method) = root.get("method").and_then(JsonValue::as_str) else {
            return Some(jsonrpc_error_response(id_ref, -32600, "Invalid Request"));
        };
        let params = root.get("params");

        if method == "notifications/initialized" {
            self.mcp_ready = true;
            return id_opt.map(|id| jsonrpc_result_response(&id, JsonValue::Object(BTreeMap::new())));
        }

        if id_opt.is_none() {
            return None;
        }

        if method == "ping" {
            return Some(jsonrpc_result_response(
                id_ref,
                JsonValue::Object(BTreeMap::new()),
            ));
        }

        if method == "initialize" {
            if self.mcp_initialized {
                return Some(jsonrpc_error_response(id_ref, -32601, "Method not found"));
            }
            let Some(p_obj) = params.and_then(JsonValue::as_object) else {
                return Some(jsonrpc_error_response(
                    id_ref,
                    -32602,
                    "Missing initialize params",
                ));
            };
            let version = p_obj.get("protocolVersion").and_then(JsonValue::as_str);
            if version != Some(MCP_PROTOCOL_VERSION) {
                return Some(jsonrpc_error_response(
                    id_ref,
                    -32602,
                    "Unsupported protocolVersion",
                ));
            }
            self.mcp_initialized = true;
            let mut server_info = BTreeMap::new();
            server_info.insert(
                "name".to_string(),
                JsonValue::String("koe-native-mcp".to_string()),
            );
            server_info.insert("version".to_string(), JsonValue::String("0.2.0".to_string()));
            let mut capabilities = BTreeMap::new();
            capabilities.insert("tools".to_string(), JsonValue::Object(BTreeMap::new()));
            let mut result = BTreeMap::new();
            result.insert(
                "protocolVersion".to_string(),
                JsonValue::String(MCP_PROTOCOL_VERSION.to_string()),
            );
            result.insert("serverInfo".to_string(), JsonValue::Object(server_info));
            result.insert("capabilities".to_string(), JsonValue::Object(capabilities));
            return Some(jsonrpc_result_response(id_ref, JsonValue::Object(result)));
        }

        if method == "tools/list" {
            if !self.mcp_initialized || !self.mcp_ready {
                return Some(jsonrpc_error_response(id_ref, -32002, "Initialize first"));
            }
            if let Some(p_obj) = params.and_then(JsonValue::as_object) {
                if let Some(cursor) = p_obj.get("cursor") {
                    let empty_str = cursor.as_str().is_some_and(|s| s.trim().is_empty());
                    if !matches!(cursor, JsonValue::Null) && !empty_str {
                        return Some(jsonrpc_error_response(id_ref, -32602, "Invalid cursor"));
                    }
                }
            }
            let tools = build_mcp_tools_schema();
            let mut result = BTreeMap::new();
            result.insert("tools".to_string(), JsonValue::Array(tools));
            return Some(jsonrpc_result_response(id_ref, JsonValue::Object(result)));
        }

        if method == "tools/call" {
            if !self.mcp_initialized || !self.mcp_ready {
                return Some(jsonrpc_error_response(id_ref, -32002, "Initialize first"));
            }
            let Some(p_obj) = params.and_then(JsonValue::as_object) else {
                return Some(jsonrpc_error_response(id_ref, -32602, "Invalid params"));
            };
            let Some(tool_name) = p_obj.get("name").and_then(JsonValue::as_str) else {
                return Some(jsonrpc_error_response(id_ref, -32602, "Missing tool name"));
            };
            let args_map = match p_obj.get("arguments") {
                None | Some(JsonValue::Null) => BTreeMap::new(),
                Some(JsonValue::Object(m)) => m.clone(),
                _ => {
                    return Some(jsonrpc_result_response(
                        id_ref,
                        mcp_tool_error_payload(
                            McpToolError::InvalidArguments,
                            "arguments must be an object",
                        ),
                    ));
                }
            };
            let tool_result = self.execute_mcp_tool(workspace, tool_name, &args_map, now_epoch_sec);
            let payload = match tool_result {
                Ok(val) => {
                    self.handled_calls = self.handled_calls.saturating_add(1);
                    self.last_tool = Some(tool_name.to_string());
                    mcp_tool_ok_payload(val)
                }
                Err(err) => mcp_tool_error_payload(err, err.as_code()),
            };
            let response = jsonrpc_result_response(id_ref, payload);
            if response.len() > MAX_JSONRPC_RESPONSE_BYTES {
                return Some(jsonrpc_result_response(
                    id_ref,
                    mcp_tool_error_payload(
                        McpToolError::ResponseTooLarge,
                        McpToolError::ResponseTooLarge.as_code(),
                    ),
                ));
            }
            return Some(response);
        }

        if method.starts_with("acp/") {
            return Some(self.dispatch_acp_method(workspace, id_ref, method, params, now_epoch_sec));
        }

        Some(jsonrpc_error_response(id_ref, -32601, "Method not found"))
    }

    fn execute_mcp_tool(
        &mut self,
        workspace: &mut McpAcpWorkspaceView<'_>,
        tool_name: &str,
        args: &BTreeMap<String, JsonValue>,
        now_epoch_sec: u64,
    ) -> Result<JsonValue, McpToolError> {
        if !is_supported_mcp_tool(tool_name) {
            return Err(McpToolError::UnknownTool);
        }
        if let Some(ref lease) = self.live_lease {
            let _ = lease.validate(now_epoch_sec)?;
        }

        let current_rev = self
            .live_lease
            .map_or_else(|| workspace.spine.revision(), |l| l.generation);

        match tool_name {
            "list_recordings" => {
                let query = args
                    .get("query")
                    .and_then(JsonValue::as_str)
                    .map(str::trim)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                let mut items = Vec::new();
                for rec in &workspace.library.entries {
                    let rec_id = rec.id.to_string();
                    let title = format!("Recording {}", rec.id);
                    if !query.is_empty()
                        && !rec_id.to_ascii_lowercase().contains(&query)
                        && !title.to_ascii_lowercase().contains(&query)
                    {
                        continue;
                    }
                    let mut obj = BTreeMap::new();
                    obj.insert("id".to_string(), JsonValue::String(rec_id));
                    obj.insert("title".to_string(), JsonValue::String(title));
                    obj.insert(
                        "durationMs".to_string(),
                        JsonValue::Number(rec.duration_ms as f64),
                    );
                    obj.insert(
                        "createdAt".to_string(),
                        JsonValue::Number(rec.created_at_epoch_sec as f64),
                    );
                    obj.insert(
                        "source".to_string(),
                        JsonValue::String("library".to_string()),
                    );
                    items.push(JsonValue::Object(obj));
                }
                if !workspace.spine.is_empty() {
                    let sid = workspace.spine.session_id().to_string();
                    if query.is_empty() || sid.to_ascii_lowercase().contains(&query) {
                        let mut obj = BTreeMap::new();
                        obj.insert("id".to_string(), JsonValue::String(sid.clone()));
                        obj.insert("title".to_string(), JsonValue::String(sid));
                        obj.insert(
                            "segmentCount".to_string(),
                            JsonValue::Number(workspace.spine.len() as f64),
                        );
                        obj.insert("source".to_string(), JsonValue::String("live".to_string()));
                        items.push(JsonValue::Object(obj));
                    }
                }
                for pack in self.sync_packs.values() {
                    if !query.is_empty()
                        && !pack.summary.id.to_ascii_lowercase().contains(&query)
                        && !pack.summary.title.to_ascii_lowercase().contains(&query)
                    {
                        continue;
                    }
                    items.push(pack.summary.to_json_value());
                }
                let mut out = BTreeMap::new();
                out.insert("recordings".to_string(), JsonValue::Array(items));
                out.insert("rejectedCount".to_string(), JsonValue::Number(0.0));
                out.insert(
                    "snapshotRevision".to_string(),
                    JsonValue::String(current_rev.to_string()),
                );
                Ok(JsonValue::Object(out))
            }
            "get_transcript" => {
                let expected = args.get("expected_revision").and_then(JsonValue::as_str);
                LiveLeaseValidator::check_revision(current_rev, expected)?;

                let rec_id = args
                    .get("recording_id")
                    .and_then(JsonValue::as_str)
                    .map(str::trim)
                    .unwrap_or("");
                if !rec_id.is_empty() && rec_id != "active" {
                    let stored_opt = self
                        .sync_packs
                        .get(&rec_id.to_ascii_lowercase())
                        .or_else(|| {
                            self.sync_packs
                                .values()
                                .find(|p| p.summary.recording_id == rec_id)
                        });
                    if let Some(stored) = stored_opt {
                        let sources = stored
                            .decoded
                            .minutes
                            .as_ref()
                            .map(|m| m.current.sources.clone())
                            .unwrap_or_default();
                        let text = sources.join("\n");
                        let src_json: Vec<JsonValue> = sources
                            .iter()
                            .enumerate()
                            .map(|(i, s)| {
                                let mut o = BTreeMap::new();
                                o.insert(
                                    "id".to_string(),
                                    JsonValue::String(format!("S{}", i + 1)),
                                );
                                o.insert("text".to_string(), JsonValue::String(s.clone()));
                                JsonValue::Object(o)
                            })
                            .collect();
                        let mut out = BTreeMap::new();
                        out.insert("recordingId".to_string(), JsonValue::String(rec_id.to_string()));
                        out.insert(
                            "revision".to_string(),
                            JsonValue::String(current_rev.to_string()),
                        );
                        out.insert("text".to_string(), JsonValue::String(text));
                        out.insert("timingReliable".to_string(), JsonValue::Bool(true));
                        out.insert("sources".to_string(), JsonValue::Array(src_json));
                        return Ok(JsonValue::Object(out));
                    }
                    let in_library = workspace
                        .library
                        .entries
                        .iter()
                        .any(|e| e.id.to_string() == rec_id);
                    if rec_id != workspace.spine.session_id() && !in_library {
                        return Err(McpToolError::RecordingUnavailable);
                    }
                }

                let resolved_rec_id = if rec_id.is_empty() || rec_id == "active" {
                    workspace.spine.session_id().to_string()
                } else {
                    rec_id.to_string()
                };
                let cited = workspace.spine.format_cited_sources();
                let mut segs = Vec::with_capacity(workspace.spine.len());
                for seg in workspace.spine.segments() {
                    let mut o = BTreeMap::new();
                    o.insert("id".to_string(), JsonValue::String(seg.id.to_string()));
                    o.insert("text".to_string(), JsonValue::String(seg.text.clone()));
                    o.insert("startMs".to_string(), JsonValue::Number(seg.start_ms as f64));
                    o.insert("endMs".to_string(), JsonValue::Number(seg.end_ms as f64));
                    if let Some(ref spk) = seg.speaker {
                        o.insert("speaker".to_string(), JsonValue::String(spk.clone()));
                    }
                    if let Some(ref tr) = seg.translation {
                        o.insert("translation".to_string(), JsonValue::String(tr.clone()));
                    }
                    segs.push(JsonValue::Object(o));
                }
                let mut aliases = BTreeMap::new();
                for (k, v) in &self.qwennote.speaker_aliases {
                    aliases.insert(k.clone(), JsonValue::String(v.clone()));
                }
                let mut out = BTreeMap::new();
                out.insert(
                    "recordingId".to_string(),
                    JsonValue::String(resolved_rec_id),
                );
                out.insert(
                    "revision".to_string(),
                    JsonValue::String(current_rev.to_string()),
                );
                out.insert("text".to_string(), JsonValue::String(cited.join("\n")));
                out.insert("timingReliable".to_string(), JsonValue::Bool(true));
                out.insert("sources".to_string(), JsonValue::Array(segs));
                out.insert("speakerAliases".to_string(), JsonValue::Object(aliases));
                Ok(JsonValue::Object(out))
            }
            "get_minutes" => {
                let expected = args.get("expected_revision").and_then(JsonValue::as_str);
                LiveLeaseValidator::check_revision(current_rev, expected)?;

                let rec_id = args
                    .get("recording_id")
                    .and_then(JsonValue::as_str)
                    .map(str::trim)
                    .unwrap_or("");
                if !rec_id.is_empty() && rec_id != "active" {
                    let stored_opt = self
                        .sync_packs
                        .get(&rec_id.to_ascii_lowercase())
                        .or_else(|| {
                            self.sync_packs
                                .values()
                                .find(|p| p.summary.recording_id == rec_id)
                        });
                    if let Some(stored) = stored_opt {
                        let mut out = BTreeMap::new();
                        out.insert(
                            "recordingId".to_string(),
                            JsonValue::String(rec_id.to_string()),
                        );
                        out.insert(
                            "revision".to_string(),
                            JsonValue::String(current_rev.to_string()),
                        );
                        if let Some(ref mins) = stored.decoded.minutes {
                            let val = JsonValue::parse(&mins.current.text)
                                .unwrap_or_else(|_| JsonValue::String(mins.current.text.clone()));
                            out.insert("current".to_string(), val);
                            out.insert(
                                "freshness".to_string(),
                                JsonValue::String("current".to_string()),
                            );
                            out.insert(
                                "historyCount".to_string(),
                                JsonValue::Number(mins.history.len() as f64),
                            );
                        } else {
                            out.insert("current".to_string(), JsonValue::Null);
                            out.insert(
                                "freshness".to_string(),
                                JsonValue::String("unverified".to_string()),
                            );
                            out.insert("historyCount".to_string(), JsonValue::Number(0.0));
                        }
                        return Ok(JsonValue::Object(out));
                    }
                    let in_library = workspace
                        .library
                        .entries
                        .iter()
                        .any(|e| e.id.to_string() == rec_id);
                    if rec_id != workspace.spine.session_id() && !in_library {
                        return Err(McpToolError::RecordingUnavailable);
                    }
                }

                let resolved_rec_id = if rec_id.is_empty() || rec_id == "active" {
                    workspace.spine.session_id().to_string()
                } else {
                    rec_id.to_string()
                };
                let mut out = BTreeMap::new();
                out.insert(
                    "recordingId".to_string(),
                    JsonValue::String(resolved_rec_id),
                );
                out.insert(
                    "revision".to_string(),
                    JsonValue::String(current_rev.to_string()),
                );
                if let Some(ref latest) = workspace.minutes.latest_minutes {
                    let encoded = encode_meeting_minutes_json(latest);
                    let parsed =
                        JsonValue::parse(&encoded).unwrap_or(JsonValue::String(encoded));
                    let freshness = if workspace.spine.is_stale()
                        || latest.spine_revision != workspace.spine.revision()
                    {
                        "stale"
                    } else {
                        "current"
                    };
                    out.insert("current".to_string(), parsed);
                    out.insert(
                        "freshness".to_string(),
                        JsonValue::String(freshness.to_string()),
                    );
                    out.insert("isDraft".to_string(), JsonValue::Bool(false));
                } else if let Some(active_raw) = workspace.rolling_scheduler.active_json() {
                    let parsed = JsonValue::parse(active_raw)
                        .unwrap_or_else(|_| JsonValue::String(active_raw.to_string()));
                    out.insert("current".to_string(), parsed);
                    out.insert(
                        "freshness".to_string(),
                        JsonValue::String("current".to_string()),
                    );
                    out.insert("isDraft".to_string(), JsonValue::Bool(true));
                } else {
                    out.insert("current".to_string(), JsonValue::Null);
                    out.insert(
                        "freshness".to_string(),
                        JsonValue::String("unverified".to_string()),
                    );
                    out.insert("isDraft".to_string(), JsonValue::Bool(false));
                }
                out.insert("historyCount".to_string(), JsonValue::Number(0.0));
                out.insert(
                    "hotwords".to_string(),
                    JsonValue::Array(
                        self.qwennote
                            .hotwords
                            .iter()
                            .cloned()
                            .map(JsonValue::String)
                            .collect(),
                    ),
                );
                Ok(JsonValue::Object(out))
            }
            "search_context" => {
                let query = args
                    .get("query")
                    .and_then(JsonValue::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .ok_or(McpToolError::InvalidArguments)?;
                let limit = args
                    .get("limit")
                    .and_then(JsonValue::as_i64)
                    .unwrap_or(5)
                    .clamp(1, 20) as usize;

                ensure_search_index_synced(workspace);
                let hits = workspace
                    .search_index
                    .search(query, limit, ScoringMode::default());
                let segs = workspace.spine.segments();
                let mut hit_objs = Vec::with_capacity(hits.len());
                let mut matched_seg_ids = Vec::with_capacity(hits.len());
                for hit in hits {
                    let mut h = BTreeMap::new();
                    h.insert(
                        "docIndex".to_string(),
                        JsonValue::Number(hit.doc_index as f64),
                    );
                    h.insert("score".to_string(), JsonValue::Number(hit.score));
                    if let Some(seg) = segs.get(hit.doc_index) {
                        matched_seg_ids.push(seg.id);
                        h.insert("citation".to_string(), JsonValue::String(seg.id.to_string()));
                        h.insert("snippet".to_string(), JsonValue::String(seg.text.clone()));
                    } else if let Some(item) = workspace.context.timeline.get(hit.doc_index) {
                        h.insert("citation".to_string(), JsonValue::String(item.id.clone()));
                        h.insert(
                            "snippet".to_string(),
                            JsonValue::String(format!("{} {}", item.title, item.summary)),
                        );
                    }
                    hit_objs.push(JsonValue::Object(h));
                }
                let q_lower = query.to_lowercase();
                let mut todos = Vec::new();
                for todo in &workspace.context.todos {
                    let matches_title = todo.title.to_lowercase().contains(&q_lower);
                    let matches_citation = todo
                        .citations
                        .iter()
                        .any(|c| matched_seg_ids.contains(c));
                    if matches_title || matches_citation {
                        let mut t = BTreeMap::new();
                        t.insert("id".to_string(), JsonValue::String(todo.id.clone()));
                        t.insert("title".to_string(), JsonValue::String(todo.title.clone()));
                        t.insert(
                            "kind".to_string(),
                            JsonValue::String(todo.kind.as_str().to_string()),
                        );
                        todos.push(JsonValue::Object(t));
                    }
                }
                let mut out = BTreeMap::new();
                out.insert("query".to_string(), JsonValue::String(query.to_string()));
                out.insert("hits".to_string(), JsonValue::Array(hit_objs));
                out.insert("todos".to_string(), JsonValue::Array(todos));
                Ok(JsonValue::Object(out))
            }
            "sync_qwennote_hotwords" => {
                if let Some(arr) = args.get("hotwords").and_then(JsonValue::as_array) {
                    let words: Vec<&str> = arr.iter().filter_map(JsonValue::as_str).collect();
                    let _ = self.sync_qwennote(&words, &[], None);
                    for w in words {
                        let clean = w.trim().to_string();
                        if !clean.is_empty() && !workspace.minutes.hot_words.contains(&clean) {
                            workspace.minutes.hot_words.push(clean);
                        }
                    }
                }
                if let Some(aliases_obj) =
                    args.get("speaker_aliases").and_then(JsonValue::as_object)
                {
                    let mut pairs: Vec<(&str, &str)> = Vec::new();
                    for (from, to_val) in aliases_obj {
                        if let Some(to) = to_val.as_str() {
                            pairs.push((from.as_str(), to));
                            let _ = workspace.spine.replace_speaker_name(from, to);
                        }
                    }
                    let _ = self.sync_qwennote(&[], &pairs, None);
                    if let Some(ref mut latest) = workspace.minutes.latest_minutes {
                        latest.replace_terms(&pairs);
                    }
                }
                if let Some( pairs_obj) = args.get("replacements").and_then(JsonValue::as_object) {
                    let mut pairs: Vec<(&str, &str)> = Vec::new();
                    for (from, to_val) in pairs_obj {
                        if let Some(to) = to_val.as_str() {
                            pairs.push((from.as_str(), to));
                        }
                    }
                    if let Some(ref mut latest) = workspace.minutes.latest_minutes {
                        latest.replace_terms(&pairs);
                    }
                    if let Some(active) = workspace.rolling_scheduler.active_json() {
                        let replaced = replace_minute_terms(active, &pairs);
                        let _ = workspace.rolling_scheduler.edit_active(&replaced);
                    }
                }
                if let Some(tpl) = args.get("template_id").and_then(JsonValue::as_str) {
                    let _ = self.sync_qwennote(&[], &[], Some(tpl));
                    workspace.minutes.active_template_id =
                        Some(self.qwennote.default_template_id.clone());
                }

                let templates: Vec<JsonValue> = BUILTIN_MINUTE_TEMPLATES
                    .iter()
                    .map(|t| {
                        let mut o = BTreeMap::new();
                        o.insert("id".to_string(), JsonValue::String(t.id.to_string()));
                        o.insert(
                            "sectionsZh".to_string(),
                            JsonValue::Array(
                                t.sections_zh
                                    .iter()
                                    .map(|s| JsonValue::String((*s).to_string()))
                                    .collect(),
                            ),
                        );
                        JsonValue::Object(o)
                    })
                    .collect();
                let mut aliases_json = BTreeMap::new();
                for (k, v) in &self.qwennote.speaker_aliases {
                    aliases_json.insert(k.clone(), JsonValue::String(v.clone()));
                }
                let mut out = BTreeMap::new();
                out.insert(
                    "hotwords".to_string(),
                    JsonValue::Array(
                        self.qwennote
                            .hotwords
                            .iter()
                            .cloned()
                            .map(JsonValue::String)
                            .collect(),
                    ),
                );
                out.insert("speakerAliases".to_string(), JsonValue::Object(aliases_json));
                out.insert(
                    "defaultTemplateId".to_string(),
                    JsonValue::String(self.qwennote.default_template_id.clone()),
                );
                out.insert("templates".to_string(), JsonValue::Array(templates));
                Ok(JsonValue::Object(out))
            }
            "export_koepack_v2" => {
                let title = args
                    .get("title")
                    .and_then(JsonValue::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| workspace.spine.session_id())
                    .to_string();
                let exported_at_iso = args
                    .get("exported_at")
                    .and_then(JsonValue::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                    .unwrap_or("2026-11-07T00:00:00Z")
                    .to_string();

                let (summary, raw_bytes) =
                    self.build_and_store_koepack_from_workspace(workspace, &title, &exported_at_iso)?;
                let mut out = BTreeMap::new();
                out.insert("id".to_string(), JsonValue::String(summary.id));
                out.insert("sha256".to_string(), JsonValue::String(summary.sha256));
                out.insert(
                    "byteLength".to_string(),
                    JsonValue::Number(raw_bytes.len() as f64),
                );
                out.insert(
                    "koepack".to_string(),
                    JsonValue::String(String::from_utf8_lossy(&raw_bytes).into_owned()),
                );
                Ok(JsonValue::Object(out))
            }
            _ => Err(McpToolError::UnknownTool),
        }
    }

    /// Builds a `.koepack v2` archive from `workspace`, stores it in `self.sync_packs`, and returns its summary and raw bytes.
    pub fn build_and_store_koepack_from_workspace(
        &mut self,
        workspace: &McpAcpWorkspaceView<'_>,
        title: &str,
        exported_at_iso: &str,
    ) -> Result<(SyncPackSummary, Vec<u8>), McpToolError> {
        let sources: Vec<String> = workspace
            .spine
            .segments()
            .iter()
            .map(|s| s.text.clone())
            .collect();
        let content_seed = if sources.is_empty() {
            format!("empty:{title}:{exported_at_iso}")
        } else {
            sources.join("\n")
        };
        let content_hash = sha256_hex(content_seed.as_bytes());
        let source_hash = sha256_hex(sources.join("\n").as_bytes());

        let minutes_section = if let Some(ref mins) = workspace.minutes.latest_minutes {
            let text = encode_meeting_minutes_json(mins);
            Some(PackMinutesV2 {
                current: PortableMinutesEntry {
                    text,
                    source_hash,
                    model: "qwen-plus".to_string(),
                    instruction: "meeting-minutes-v2".to_string(),
                    sources,
                    created_at_iso: exported_at_iso.to_string(),
                    edited_at_iso: None,
                    template_id: Some(self.qwennote.default_template_id.clone()),
                    template_version: 2,
                    is_draft: false,
                },
                history: Vec::new(),
            })
        } else if let Some(active_json) = workspace.rolling_scheduler.active_json() {
            let entry = PortableMinutesEntry {
                text: extract_json_object(active_json).to_string(),
                source_hash,
                model: "qwen-plus".to_string(),
                instruction: "rolling-minutes-v2".to_string(),
                sources,
                created_at_iso: exported_at_iso.to_string(),
                edited_at_iso: None,
                template_id: Some(self.qwennote.default_template_id.clone()),
                template_version: 2,
                is_draft: true,
            };
            if entry.validate().is_ok() {
                Some(PackMinutesV2 {
                    current: entry,
                    history: Vec::new(),
                })
            } else {
                None
            }
        } else {
            None
        };

        let version = if minutes_section.is_some() { 2 } else { 1 };
        let pack = MaterialPackV2 {
            version,
            exported_at_iso: exported_at_iso.to_string(),
            material: PackMaterialMeta {
                content_hash: content_hash.clone(),
                title: if title.trim().is_empty() {
                    workspace.spine.session_id().to_string()
                } else {
                    title.trim().to_string()
                },
                source: "device".to_string(),
                device_file_id: workspace.library.selected_id,
                recorded_at_iso: Some(exported_at_iso.to_string()),
                audio_extension: Some(".opus".to_string()),
            },
            minutes: minutes_section,
        };
        let raw_bytes = encode_koepack_v2(&pack).map_err(|_| McpToolError::InvalidPack)?;
        let summary = self.put_sync_pack(&content_hash, &raw_bytes)?;
        Ok((summary, raw_bytes))
    }

    fn dispatch_acp_method(
        &mut self,
        workspace: &mut McpAcpWorkspaceView<'_>,
        id_ref: &JsonValue,
        method: &str,
        params: Option<&JsonValue>,
        now_epoch_sec: u64,
    ) -> String {
        match method {
            "acp/initialize" => {
                self.acp_initialized = true;
                self.handled_calls = self.handled_calls.saturating_add(1);
                self.last_tool = Some(method.to_string());
                let card = AcpAgentCard::default();
                let mut res = BTreeMap::new();
                res.insert(
                    "protocolVersion".to_string(),
                    JsonValue::String(ACP_PROTOCOL_VERSION.to_string()),
                );
                res.insert("agentCard".to_string(), card.to_json_value());
                jsonrpc_result_response(id_ref, JsonValue::Object(res))
            }
            "acp/agent.card" => {
                self.handled_calls = self.handled_calls.saturating_add(1);
                self.last_tool = Some(method.to_string());
                jsonrpc_result_response(id_ref, AcpAgentCard::default().to_json_value())
            }
            "acp/session.start" => {
                self.next_session_seq = self.next_session_seq.saturating_add(1);
                let session_id = format!("acp-session-{}", self.next_session_seq);
                self.acp_sessions.push(session_id.clone());
                self.handled_calls = self.handled_calls.saturating_add(1);
                self.last_tool = Some(method.to_string());
                let mut res = BTreeMap::new();
                res.insert("sessionId".to_string(), JsonValue::String(session_id));
                res.insert(
                    "protocolVersion".to_string(),
                    JsonValue::String(ACP_PROTOCOL_VERSION.to_string()),
                );
                jsonrpc_result_response(id_ref, JsonValue::Object(res))
            }
            "acp/task.send" => {
                let Some(p_obj) = params.and_then(JsonValue::as_object) else {
                    return jsonrpc_error_response(id_ref, -32602, "Missing task params");
                };
                let Some(prompt) = p_obj
                    .get("prompt")
                    .and_then(JsonValue::as_str)
                    .map(str::trim)
                    .filter(|s| !s.is_empty())
                else {
                    return jsonrpc_error_response(id_ref, -32602, "Missing prompt");
                };
                let session_id = p_obj
                    .get("sessionId")
                    .or_else(|| p_obj.get("session_id"))
                    .and_then(JsonValue::as_str)
                    .map(ToString::to_string)
                    .unwrap_or_else(|| {
                        if let Some(last) = self.acp_sessions.last() {
                            last.clone()
                        } else {
                            self.next_session_seq = self.next_session_seq.saturating_add(1);
                            let sid = format!("acp-session-{}", self.next_session_seq);
                            self.acp_sessions.push(sid.clone());
                            sid
                        }
                    });

                self.next_task_seq = self.next_task_seq.saturating_add(1);
                let task_id = format!("acp-task-{}", self.next_task_seq);

                ensure_search_index_synced(workspace);
                let hits = workspace
                    .search_index
                    .search(prompt, 5, ScoringMode::default());
                let segs = workspace.spine.segments();
                let mut cited_lines = Vec::new();
                for hit in &hits {
                    if let Some(seg) = segs.get(hit.doc_index) {
                        cited_lines.push(format!("[{}] {}", seg.id, seg.text));
                    }
                }
                let result_text = if cited_lines.is_empty() {
                    "未找到匹配的录音原话依据。".to_string()
                } else {
                    format!("依据原话：\n{}", cited_lines.join("\n"))
                };
                let is_async = p_obj
                    .get("async")
                    .or_else(|| p_obj.get("defer"))
                    .and_then(JsonValue::as_bool)
                    .unwrap_or(false);
                let phase = if is_async {
                    AcpTaskPhase::Working
                } else {
                    AcpTaskPhase::Completed
                };

                let mut record = AcpTaskRecord {
                    task_id: task_id.clone(),
                    session_id,
                    prompt: prompt.to_string(),
                    phase,
                    result_text,
                    logs: Vec::new(),
                    updated_at_epoch_sec: now_epoch_sec,
                };
                record.push_log(format!("accepted:{}", record.task_id));
                record.push_log(format!("retrieved_hits:{}", hits.len()));
                if !is_async {
                    record.push_log("completed".to_string());
                }

                if let Some(extra_logs) = p_obj.get("debugLogCount").and_then(JsonValue::as_i64) {
                    let count = extra_logs.clamp(0, 2500) as usize;
                    for i in 0..count {
                        record.push_log(format!("trace:{i}"));
                    }
                }

                let val = record.to_json_value();
                self.acp_tasks.insert(task_id, record);
                self.handled_calls = self.handled_calls.saturating_add(1);
                self.last_tool = Some(method.to_string());
                jsonrpc_result_response(id_ref, val)
            }
            "acp/task.status" => {
                let Some(task_id) = params
                    .and_then(JsonValue::as_object)
                    .and_then(|o| o.get("taskId").or_else(|| o.get("task_id")))
                    .and_then(JsonValue::as_str)
                else {
                    return jsonrpc_error_response(id_ref, -32602, "Missing taskId");
                };
                let Some(record) = self.acp_tasks.get(task_id.trim()) else {
                    return jsonrpc_error_response(id_ref, -32602, "Unknown taskId");
                };
                self.handled_calls = self.handled_calls.saturating_add(1);
                self.last_tool = Some(method.to_string());
                jsonrpc_result_response(id_ref, record.to_json_value())
            }
            "acp/task.cancel" => {
                let Some(task_id) = params
                    .and_then(JsonValue::as_object)
                    .and_then(|o| o.get("taskId").or_else(|| o.get("task_id")))
                    .and_then(JsonValue::as_str)
                else {
                    return jsonrpc_error_response(id_ref, -32602, "Missing taskId");
                };
                let Some(record) = self.acp_tasks.get_mut(task_id.trim()) else {
                    return jsonrpc_error_response(id_ref, -32602, "Unknown taskId");
                };
                if matches!(record.phase, AcpTaskPhase::Completed | AcpTaskPhase::Failed) {
                    return jsonrpc_error_response(
                        id_ref,
                        -32602,
                        "Cannot cancel terminal task",
                    );
                }
                record.phase = AcpTaskPhase::Canceled;
                record.updated_at_epoch_sec = now_epoch_sec;
                record.push_log("canceled".to_string());
                let val = record.to_json_value();
                self.handled_calls = self.handled_calls.saturating_add(1);
                self.last_tool = Some(method.to_string());
                jsonrpc_result_response(id_ref, val)
            }
            _ => jsonrpc_error_response(id_ref, -32601, "Method not found"),
        }
    }
}

/// Self-contained MCP + ACP runtime owning a full domain workspace for single-handle C-ABI/FFI hosts.
#[derive(Debug, Clone)]
pub struct McpAcpOwnedRuntime {
    /// Active utterance spine (`S1..Sn`).
    pub spine: UtteranceSpine,
    /// Local recording library.
    pub library: RecordingLibrary,
    /// Structured meeting minutes state.
    pub minutes: MinutesState,
    /// Cicada bounded rolling minutes scheduler.
    pub rolling_scheduler: RollingMinutesScheduler,
    /// Personal context timeline and todo state.
    pub context: ContextState,
    /// Offline BM25 retrieval index.
    pub search_index: ContextSearchIndex,
    /// MCP + ACP protocol engine state.
    pub mcp_acp: McpAcpState,
}

impl Default for McpAcpOwnedRuntime {
    fn default() -> Self {
        Self::new("native-mcp-session")
    }
}

impl McpAcpOwnedRuntime {
    /// Creates a new [`McpAcpOwnedRuntime`] for `session_id`.
    #[must_use]
    pub fn new(session_id: impl Into<String>) -> Self {
        let sid = session_id.into();
        Self {
            spine: UtteranceSpine::new(sid.clone()),
            library: RecordingLibrary::new(),
            minutes: MinutesState::default(),
            rolling_scheduler: RollingMinutesScheduler::new(sid),
            context: ContextState::default(),
            search_index: ContextSearchIndex::new(),
            mcp_acp: McpAcpState::new(),
        }
    }

    /// Ingests a finalized utterance into `spine`, `rolling_scheduler`, `search_index`, and `context`.
    pub fn ingest_utterance(
        &mut self,
        text: &str,
        start_ms: u64,
        end_ms: u64,
        source_language: &str,
        provider: &str,
        now_epoch_sec: u64,
    ) -> Option<SegmentId> {
        let seg_id =
            self.spine
                .append_segment(text, start_ms, end_ms, source_language, provider)?;
        let _ = self.rolling_scheduler.append_segment(
            &seg_id.to_string(),
            text,
            now_epoch_sec.saturating_mul(1_000),
        );
        let _ = self.search_index.add_document(text);
        self.context.timeline.push(ContextItem {
            id: format!("ctx-{}", seg_id),
            kind: ContextKind::Recording,
            source: ContextSource::DeviceMic,
            created_at_epoch_sec: now_epoch_sec,
            title: seg_id.to_string(),
            summary: text.trim().to_string(),
            project_id: None,
            place_label: None,
            citations: vec![seg_id],
        });
        if text.contains("待办")
            || text.contains("前把")
            || text.contains("提交")
            || text.contains("发给")
        {
            self.context.todos.push(TodoItem {
                id: format!("todo-{}", seg_id),
                title: text.trim().to_string(),
                kind: TodoKind::Mine,
                status: TodoStatus::Open,
                created_at_epoch_sec: now_epoch_sec,
                due_at_epoch_sec: None,
                assignee: None,
                citations: vec![seg_id],
            });
        }
        Some(seg_id)
    }

    /// Accepts and validates a structured meeting minutes JSON document against `self.spine`.
    pub fn accept_minutes_json(&mut self, raw_json: &str) -> bool {
        if let Ok(mins) = parse_meeting_minutes_json(raw_json, &self.spine) {
            self.minutes.latest_minutes = Some(mins);
            self.minutes.last_error = None;
            true
        } else {
            false
        }
    }

    /// Registers a saved local recording entry in `self.library` so `list_recordings`, `get_transcript`, and `get_minutes` expose it.
    pub fn ingest_recording(
        &mut self,
        id: u32,
        duration_ms: u64,
        byte_count: u32,
        created_at_epoch_sec: u64,
    ) {
        self.library.ingest(RecordingEntry {
            id,
            bean_file_id: id,
            created_at_epoch_sec,
            duration_ms,
            byte_count,
            marks_ms: Vec::new(),
        });
    }

    /// Builds and accepts a grounded `MeetingMinutesV2` document covering all segments `S1..Sn` in `self.spine`.
    pub fn sync_grounded_minutes_from_spine(&mut self) -> bool {
        let segs = self.spine.segments();
        if segs.is_empty() {
            return false;
        }
        let first_text = segs[0].text.trim().to_string();
        let all_sources: Vec<JsonValue> = segs
            .iter()
            .map(|s| JsonValue::String(s.id.to_string()))
            .collect();
        let points: Vec<JsonValue> = segs
            .iter()
            .map(|s| {
                let mut pt = BTreeMap::new();
                pt.insert("text".to_string(), JsonValue::String(s.text.trim().to_string()));
                pt.insert(
                    "sources".to_string(),
                    JsonValue::Array(vec![JsonValue::String(s.id.to_string())]),
                );
                JsonValue::Object(pt)
            })
            .collect();
        let mut topic = BTreeMap::new();
        topic.insert("text".to_string(), JsonValue::String("录音纪要".to_string()));
        topic.insert("summary".to_string(), JsonValue::String(first_text.clone()));
        topic.insert("sources".to_string(), JsonValue::Array(all_sources));
        topic.insert("points".to_string(), JsonValue::Array(points));

        let mut root = BTreeMap::new();
        root.insert("schemaVersion".to_string(), JsonValue::Number(2.0));
        root.insert("title".to_string(), JsonValue::String(first_text.clone()));
        root.insert("overview".to_string(), JsonValue::String(first_text));
        root.insert(
            "topics".to_string(),
            JsonValue::Array(vec![JsonValue::Object(topic)]),
        );
        root.insert("decisions".to_string(), JsonValue::Array(Vec::new()));
        root.insert("actions".to_string(), JsonValue::Array(Vec::new()));
        root.insert("questions".to_string(), JsonValue::Array(Vec::new()));
        root.insert("terms".to_string(), JsonValue::Array(Vec::new()));
        root.insert("reviewItems".to_string(), JsonValue::Array(Vec::new()));

        let encoded = JsonValue::Object(root).to_json_string();
        let accepted = self.accept_minutes_json(&encoded);
        if accepted {
            self.spine.clear_stale();
        }
        accepted
    }

    /// Dispatches a raw JSON-RPC 2.0 request or notification against this owned workspace.
    pub fn dispatch_jsonrpc(&mut self, raw_json: &str, now_epoch_sec: u64) -> Option<String> {
        let mut view = McpAcpWorkspaceView {
            spine: &mut self.spine,
            library: &self.library,
            minutes: &mut self.minutes,
            rolling_scheduler: &mut self.rolling_scheduler,
            context: &mut self.context,
            search_index: &mut self.search_index,
        };
        self.mcp_acp.dispatch_jsonrpc(&mut view, raw_json, now_epoch_sec)
    }
}

/// Input events for [`McpAcpReducer`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum McpAcpEvent {
    /// Invoke a named MCP tool against the current [`UtteranceSpine`].
    InvokeTool {
        /// JSON-RPC request identifier.
        request_id: u64,
        /// MCP tool name.
        tool_name: String,
    },
}

/// Pure output from [`McpAcpReducer::reduce`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct McpAcpOutcome {
    /// Echoed JSON-RPC request identifier.
    pub request_id: u64,
    /// Whether the tool is supported and succeeded.
    pub supported: bool,
    /// Human-readable or JSON payload summary.
    pub payload_summary: String,
}

/// Pure reducer contract for the MCP/ACP server subsystem.
pub trait McpAcpReducer {
    /// Applies `event` to `state` against `spine` without side effects.
    fn reduce(
        state: &mut McpAcpState,
        spine: &UtteranceSpine,
        event: McpAcpEvent,
    ) -> McpAcpOutcome;
}

impl McpAcpReducer for McpAcpState {
    fn reduce(
        state: &mut McpAcpState,
        spine: &UtteranceSpine,
        event: McpAcpEvent,
    ) -> McpAcpOutcome {
        match event {
            McpAcpEvent::InvokeTool {
                request_id,
                tool_name,
            } => {
                let clean = tool_name.trim().to_string();
                let supported = is_supported_mcp_tool(&clean);
                if supported {
                    state.handled_calls = state.handled_calls.saturating_add(1);
                    state.last_tool = Some(clean.clone());
                }
                let payload_summary = if clean == "get_transcript" {
                    spine.format_cited_sources().join("\n")
                } else if supported {
                    format!("ok:{clean}:rev={}", spine.revision())
                } else {
                    format!("error:unsupported_tool:{clean}")
                };
                McpAcpOutcome {
                    request_id,
                    supported,
                    payload_summary,
                }
            }
        }
    }
}

fn ensure_search_index_synced(workspace: &mut McpAcpWorkspaceView<'_>) {
    if !workspace.spine.is_empty() && workspace.search_index.doc_count() != workspace.spine.len() {
        let mut rebuilt = ContextSearchIndex::new();
        for seg in workspace.spine.segments() {
            let _ = rebuilt.add_document(&seg.text);
        }
        *workspace.search_index = rebuilt;
    }
}

/// Formats `epoch_sec` as an ISO-8601 UTC timestamp (`YYYY-MM-DDTHH:MM:SSZ`).
#[must_use]
pub fn format_epoch_sec_iso8601(epoch_sec: u64) -> String {
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

fn jsonrpc_result_response(id: &JsonValue, result: JsonValue) -> String {
    let mut root = BTreeMap::new();
    root.insert("jsonrpc".to_string(), JsonValue::String("2.0".to_string()));
    root.insert("id".to_string(), id.clone());
    root.insert("result".to_string(), result);
    JsonValue::Object(root).to_json_string()
}

fn jsonrpc_error_response(id: &JsonValue, code: i64, message: &str) -> String {
    let mut err = BTreeMap::new();
    err.insert("code".to_string(), JsonValue::Number(code as f64));
    err.insert(
        "message".to_string(),
        JsonValue::String(message.to_string()),
    );
    let mut root = BTreeMap::new();
    root.insert("jsonrpc".to_string(), JsonValue::String("2.0".to_string()));
    root.insert("id".to_string(), id.clone());
    root.insert("error".to_string(), JsonValue::Object(err));
    JsonValue::Object(root).to_json_string()
}

fn mcp_tool_ok_payload(structured: JsonValue) -> JsonValue {
    let text = structured.to_json_string();
    let mut block = BTreeMap::new();
    block.insert("type".to_string(), JsonValue::String("text".to_string()));
    block.insert("text".to_string(), JsonValue::String(text));
    let mut res = BTreeMap::new();
    res.insert(
        "content".to_string(),
        JsonValue::Array(vec![JsonValue::Object(block)]),
    );
    res.insert("structuredContent".to_string(), structured);
    res.insert("isError".to_string(), JsonValue::Bool(false));
    JsonValue::Object(res)
}

fn mcp_tool_error_payload(err: McpToolError, detail: &str) -> JsonValue {
    let mut err_obj = BTreeMap::new();
    err_obj.insert(
        "error".to_string(),
        JsonValue::String(err.as_code().to_string()),
    );
    err_obj.insert("detail".to_string(), JsonValue::String(detail.to_string()));
    let structured = JsonValue::Object(err_obj);
    let text = structured.to_json_string();
    let mut block = BTreeMap::new();
    block.insert("type".to_string(), JsonValue::String("text".to_string()));
    block.insert("text".to_string(), JsonValue::String(text));
    let mut res = BTreeMap::new();
    res.insert(
        "content".to_string(),
        JsonValue::Array(vec![JsonValue::Object(block)]),
    );
    res.insert("structuredContent".to_string(), structured);
    res.insert("isError".to_string(), JsonValue::Bool(true));
    JsonValue::Object(res)
}

fn build_mcp_tools_schema() -> Vec<JsonValue> {
    KOE_MCP_TOOLS
        .iter()
        .map(|&name| {
            let mut schema = BTreeMap::new();
            schema.insert("type".to_string(), JsonValue::String("object".to_string()));
            let mut tool = BTreeMap::new();
            tool.insert("name".to_string(), JsonValue::String(name.to_string()));
            tool.insert(
                "description".to_string(),
                JsonValue::String(format!("Koe native MCP tool: {name}")),
            );
            tool.insert("inputSchema".to_string(), JsonValue::Object(schema));
            JsonValue::Object(tool)
        })
        .collect()
}

const BASE64URL_ALPHABET: &[u8; 64] =
    b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

fn base64url_encode_nopad(input: &[u8]) -> String {
    let mut out = String::with_capacity((input.len() * 4).div_ceil(3));
    let mut i = 0usize;
    while i + 3 <= input.len() {
        let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8) | (input[i + 2] as u32);
        out.push(BASE64URL_ALPHABET[((n >> 18) & 0x3F) as usize] as char);
        out.push(BASE64URL_ALPHABET[((n >> 12) & 0x3F) as usize] as char);
        out.push(BASE64URL_ALPHABET[((n >> 6) & 0x3F) as usize] as char);
        out.push(BASE64URL_ALPHABET[(n & 0x3F) as usize] as char);
        i += 3;
    }
    let rem = input.len() - i;
    if rem == 1 {
        let n = (input[i] as u32) << 16;
        out.push(BASE64URL_ALPHABET[((n >> 18) & 0x3F) as usize] as char);
        out.push(BASE64URL_ALPHABET[((n >> 12) & 0x3F) as usize] as char);
    } else if rem == 2 {
        let n = ((input[i] as u32) << 16) | ((input[i + 1] as u32) << 8);
        out.push(BASE64URL_ALPHABET[((n >> 18) & 0x3F) as usize] as char);
        out.push(BASE64URL_ALPHABET[((n >> 12) & 0x3F) as usize] as char);
        out.push(BASE64URL_ALPHABET[((n >> 6) & 0x3F) as usize] as char);
    }
    out
}

fn base64url_val(b: u8) -> Option<u32> {
    match b {
        b'A'..=b'Z' => Some((b - b'A') as u32),
        b'a'..=b'z' => Some((b - b'a' + 26) as u32),
        b'0'..=b'9' => Some((b - b'0' + 52) as u32),
        b'-' | b'+' => Some(62),
        b'_' | b'/' => Some(63),
        _ => None,
    }
}

fn base64url_decode(raw: &str) -> Option<Vec<u8>> {
    let clean = raw.trim().trim_end_matches('=').as_bytes();
    if clean.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity((clean.len() * 3) / 4);
    let mut i = 0usize;
    while i + 4 <= clean.len() {
        let a = base64url_val(clean[i])?;
        let b = base64url_val(clean[i + 1])?;
        let c = base64url_val(clean[i + 2])?;
        let d = base64url_val(clean[i + 3])?;
        let n = (a << 18) | (b << 12) | (c << 6) | d;
        out.push(((n >> 16) & 0xFF) as u8);
        out.push(((n >> 8) & 0xFF) as u8);
        out.push((n & 0xFF) as u8);
        i += 4;
    }
    let rem = clean.len() - i;
    if rem == 2 {
        let a = base64url_val(clean[i])?;
        let b = base64url_val(clean[i + 1])?;
        let n = (a << 18) | (b << 12);
        out.push(((n >> 16) & 0xFF) as u8);
    } else if rem == 3 {
        let a = base64url_val(clean[i])?;
        let b = base64url_val(clean[i + 1])?;
        let c = base64url_val(clean[i + 2])?;
        let n = (a << 18) | (b << 12) | (c << 6);
        out.push(((n >> 16) & 0xFF) as u8);
        out.push(((n >> 8) & 0xFF) as u8);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mcp_registry_recognizes_canonical_tools_and_formats_transcript() {
        assert!(is_supported_mcp_tool("get_transcript"));
        assert!(is_supported_mcp_tool("export_koepack_v2"));
        assert!(!is_supported_mcp_tool("drop_database"));

        let mut spine = UtteranceSpine::new("mcp-session");
        spine.append_segment("第一条记录。", 0, 1_000, "zh", "qwen");
        let mut state = McpAcpState::default();
        let out = McpAcpState::reduce(
            &mut state,
            &spine,
            McpAcpEvent::InvokeTool {
                request_id: 7,
                tool_name: "get_transcript".to_string(),
            },
        );
        assert!(out.supported);
        assert_eq!(out.payload_summary, "[S1] 第一条记录。");
        assert_eq!(state.handled_calls, 1);
    }

    #[test]
    fn pairing_ticket_roundtrips_and_enforces_token_length_and_expiry() {
        let ticket = PairingTicket {
            version: 1,
            base_url: "https://koe.example.com/mcp/".to_string(),
            token: "koe-secret-token-with-at-least-24-bytes".to_string(),
            mode: McpPairingMode::Vps,
            email: Some("owner@example.com".to_string()),
            expires_at_epoch_sec: Some(1_800_000_000),
        };
        let encoded = ticket.encode().expect("valid ticket must encode");
        assert!(encoded.starts_with(PAIRING_TICKET_PREFIX));
        assert!(!encoded.contains('='));

        let decoded = PairingTicket::decode(&encoded).expect("encoded ticket must decode");
        assert_eq!(decoded.version, 1);
        assert_eq!(decoded.base_url, "https://koe.example.com");
        assert_eq!(decoded.mode, McpPairingMode::Vps);
        assert_eq!(decoded.email.as_deref(), Some("owner@example.com"));
        assert_eq!(decoded.expires_at_epoch_sec, Some(1_800_000_000));
        assert!(decoded.verify_token("koe-secret-token-with-at-least-24-bytes", 1_799_999_999));
        assert!(!decoded.verify_token("koe-secret-token-with-at-least-24-bytes", 1_800_000_000));
        assert!(!decoded.verify_token("wrong-secret-token-with-at-least-24-bytes", 1_799_999_999));

        let short_token = PairingTicket {
            version: 1,
            base_url: "https://koe.example.com".to_string(),
            token: "too-short".to_string(),
            mode: McpPairingMode::Lan,
            email: None,
            expires_at_epoch_sec: None,
        };
        assert_eq!(short_token.encode(), Err(McpToolError::InvalidArguments));
        assert_eq!(
            PairingTicket::decode("INVALID.abc"),
            Err(McpToolError::InvalidArguments)
        );
    }

    #[test]
    fn live_publication_lease_enforces_15s_window_and_expected_revision() {
        let mut state = McpAcpState::new();
        assert_eq!(
            state.publish_live_lease(3, 1_000, 25),
            Err(McpToolError::InvalidPublication)
        );
        let lease = state
            .publish_live_lease(3, 1_000, LIVE_LEASE_DEFAULT_TTL_SEC)
            .unwrap();
        assert_eq!(lease.validate(1_005), Ok(10));
        assert_eq!(lease.validate(1_015), Err(McpToolError::PublicationExpired));
        assert_eq!(
             (LivePublicationLease {
                generation: 3,
                expires_at_epoch_sec: 1_025,
            })
            .validate(1_000),
            Err(McpToolError::InvalidPublication)
        );
        assert_eq!(lease.check_expected_revision(Some("3")), Ok(()));
        assert_eq!(
            lease.check_expected_revision(Some("2")),
            Err(McpToolError::SnapshotChanged)
        );
        assert_eq!(
            lease.check_expected_revision(Some("rev-abc")),
            Err(McpToolError::InvalidArguments)
        );
    }

    #[test]
    fn mcp_jsonrpc_handshake_and_all_six_tools_execute_end_to_end() {
        let mut rt = McpAcpOwnedRuntime::new("rec-2026");
        rt.ingest_utterance(
            "下周三前把海外渠道合同发给法务审阅。",
            0,
            2_500,
            "zh",
            "qwen",
            1_762_540_000,
        );
        let mins_json = r#"{
            "schemaVersion": 2,
            "title": "海外渠道合同讨论",
            "overview": "确认下周三前将海外渠道合同送交法务审阅。",
            "topics": [
                {
                    "text": "合同审阅",
                    "summary": "法务审阅排期",
                    "sources": ["S1"],
                    "points": [{ "text": "下周三前发给法务审阅", "sources": ["S1"] }]
                }
            ],
            "decisions": [{ "text": "下周三前提交法务", "sources": ["S1"] }],
            "actions": [{ "text": "发送海外渠道合同", "owner": "张总", "due": "下周三", "sources": ["S1"] }],
            "questions": [],
            "terms": [{ "name": "海外渠道", "note": "海外销售渠道合同", "sources": ["S1"] }],
            "reviewItems": []
        }"#;
        assert!(rt.accept_minutes_json(mins_json));

        let pre_init = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
                1_762_540_001,
            )
            .unwrap();
        assert!(pre_init.contains("-32002"));

        let init_resp = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
                1_762_540_001,
            )
            .unwrap();
        assert!(init_resp.contains("\"protocolVersion\":\"2025-11-25\""));

        let dup_init = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":3,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
                1_762_540_001,
            )
            .unwrap();
        assert!(dup_init.contains("-32601"));

        assert!(rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                1_762_540_001,
            )
            .is_none());

        let tools_list = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":4,"method":"tools/list"}"#,
                1_762_540_002,
            )
            .unwrap();
        for tool in KOE_MCP_TOOLS {
            assert!(tools_list.contains(tool));
        }

        let list_rec = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"list_recordings","arguments":{}}}"#,
                1_762_540_002,
            )
            .unwrap();
        assert!(list_rec.contains("rec-2026"));

        let transcript = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"get_transcript","arguments":{"expected_revision":"1"}}}"#,
                1_762_540_002,
            )
            .unwrap();
        assert!(transcript.contains("海外渠道合同"));

        let rev_mismatch = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"get_transcript","arguments":{"expected_revision":"999"}}}"#,
                1_762_540_002,
            )
            .unwrap();
        assert!(rev_mismatch.contains("snapshot_changed"));

        let minutes_resp = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"get_minutes","arguments":{}}}"#,
                1_762_540_002,
            )
            .unwrap();
        assert!(minutes_resp.contains("海外渠道合同讨论"));

        let search_resp = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道","limit":5}}}"#,
                1_762_540_002,
            )
            .unwrap();
        assert!(search_resp.contains("\"citation\":\"S1\""));

        let qwen_sync = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"sync_qwennote_hotwords","arguments":{"hotwords":["心力豆","D3200"],"speaker_aliases":{"张总":"张伟"},"template_id":"fishbone"}}}"#,
                1_762_540_002,
            )
            .unwrap();
        assert!(qwen_sync.contains("心力豆"));
        assert!(qwen_sync.contains("\"defaultTemplateId\":\"fishbone\""));

        let export_pack = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"export_koepack_v2","arguments":{"title":"海外渠道纪要包","exported_at":"2026-11-07T18:00:00Z"}}}"#,
                1_762_540_002,
            )
            .unwrap();
        assert!(export_pack.contains("KOEPACK1"));
        assert_eq!(rt.mcp_acp.pack_count(), 1);
    }

    #[test]
    fn sync_packs_put_get_list_and_delta_computation_verify_hashes() {
        let mut rt = McpAcpOwnedRuntime::new("pack-sync");
        rt.ingest_utterance("测试资料包同步。", 0, 1_000, "zh", "qwen", 1_762_540_000);
        let view = McpAcpWorkspaceView {
            spine: &mut rt.spine,
            library: &rt.library,
            minutes: &mut rt.minutes,
            rolling_scheduler: &mut rt.rolling_scheduler,
            context: &mut rt.context,
            search_index: &mut rt.search_index,
        };
        let (summary, raw_bytes) = rt
            .mcp_acp
            .build_and_store_koepack_from_workspace(&view, "同步包A", "2026-11-07T10:00:00Z")
            .unwrap();

        let wrong_id = "0".repeat(64);
        assert_eq!(
            rt.mcp_acp.put_sync_pack(&wrong_id, &raw_bytes),
            Err(McpToolError::InvalidPack)
        );
        assert_eq!(
            rt.mcp_acp.get_sync_pack(&summary.id).unwrap(),
            raw_bytes.as_slice()
        );

        let remote = vec![SyncPackSummary {
            id: "f".repeat(64),
            recording_id: "99".to_string(),
            sha256: "e".repeat(64),
            title: "远端包".to_string(),
            exported_at_iso: "2026-11-07T11:00:00Z".to_string(),
            has_transcript: true,
            has_minutes: false,
        }];
        let delta = compute_pack_sync_delta(&rt.mcp_acp.list_sync_packs(), &remote);
        assert_eq!(delta.to_upload, vec![summary.id]);
        assert_eq!(delta.to_download, vec!["f".repeat(64)]);
        assert!(delta.up_to_date.is_empty());
    }

    #[test]
    fn acp_lifecycle_initializes_runs_grounded_tasks_caps_logs_and_cancels() {
        let mut rt = McpAcpOwnedRuntime::new("acp-demo");
        rt.ingest_utterance(
            "周五下午三点与供应商核对报价单。",
            0,
            2_000,
            "zh",
            "qwen",
            1_762_540_100,
        );

        let init = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":1,"method":"acp/initialize"}"#,
                1_762_540_101,
            )
            .unwrap();
        assert!(init.contains(ACP_PROTOCOL_VERSION));
        assert!(init.contains("aid://koe.local/native-agent"));

        let session = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":2,"method":"acp/session.start"}"#,
                1_762_540_102,
            )
            .unwrap();
        assert!(session.contains("acp-session-1"));

        let send = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":3,"method":"acp/task.send","params":{"sessionId":"acp-session-1","prompt":"供应商报价单","debugLogCount":1200}}"#,
                1_762_540_103,
            )
            .unwrap();
        assert!(send.contains("acp-task-1"));
        assert!(send.contains("[S1] 周五下午三点与供应商核对报价单。"));

        let record = rt.mcp_acp.acp_tasks.get("acp-task-1").unwrap();
        assert_eq!(record.logs.len(), MAX_ACP_TASK_LOGS);

        let status = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":4,"method":"acp/task.status","params":{"taskId":"acp-task-1"}}"#,
                1_762_540_104,
            )
            .unwrap();
        assert!(status.contains("\"phase\":\"completed\""));

        let cancel_completed = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":5,"method":"acp/task.cancel","params":{"taskId":"acp-task-1"}}"#,
                1_762_540_105,
            )
            .unwrap();
        assert!(cancel_completed.contains("-32602"));

        let send_async = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":6,"method":"acp/task.send","params":{"sessionId":"acp-session-1","prompt":"供应商报价单","async":true}}"#,
                1_762_540_106,
            )
            .unwrap();
        assert!(send_async.contains("\"phase\":\"working\""));

        let cancel_working = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":7,"method":"acp/task.cancel","params":{"taskId":"acp-task-2"}}"#,
                1_762_540_107,
            )
            .unwrap();
        assert!(cancel_working.contains("\"phase\":\"canceled\""));
    }

    #[test]
    fn interrogate_regressions_library_ids_grounded_minutes_bearer_and_notifications() {
        let mut rt = McpAcpOwnedRuntime::new("live-session");
        rt.ingest_recording(20261108, 2_400, 9_818, 1_762_540_000);
        rt.ingest_utterance(
            "第一句带引号\"与换行\n及制表符\t内容。",
            0,
            1_000,
            "zh",
            "qwen",
            1_762_540_001,
        );
        rt.ingest_utterance(
            "第二句独立讨论供应链交付与待办安排。",
            1_000,
            2_400,
            "zh",
            "qwen",
            1_762_540_002,
        );
        assert!(rt.sync_grounded_minutes_from_spine());

        let token = "koe-secret-token-with-at-least-24-bytes";
        let _ = rt
            .mcp_acp
            .configure_pairing("https://koe.example.com", token, McpPairingMode::Lan, None, None)
            .unwrap();
        assert!(rt
            .mcp_acp
            .verify_bearer_header(Some(&format!("Bearer {token}")), 1_762_540_003));
        assert!(!rt.mcp_acp.verify_bearer_header(Some(token), 1_762_540_003));
        assert!(!rt
            .mcp_acp
            .verify_bearer_header(Some(&format!("Basic {token}")), 1_762_540_003));

        let _ = rt.dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
            1_762_540_003,
        );
        assert!(rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
                1_762_540_003,
            )
            .is_none());
        assert!(rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":99}}"#,
                1_762_540_003,
            )
            .is_none());

        let tr_by_lib_id = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"get_transcript","arguments":{"recording_id":"20261108"}}}"#,
                1_762_540_004,
            )
            .unwrap();
        assert!(tr_by_lib_id.contains("\"recordingId\":\"20261108\""));
        assert!(tr_by_lib_id.contains("供应链交付"));

        let mins_by_lib_id = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_minutes","arguments":{"recording_id":"20261108"}}}"#,
                1_762_540_004,
            )
            .unwrap();
        assert!(mins_by_lib_id.contains("\"recordingId\":\"20261108\""));
        assert!(mins_by_lib_id.contains("S2"));
        assert!(mins_by_lib_id.contains("供应链交付"));

        let unmatched_search = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"完全不存在的量子天体词汇"}}}"#,
                1_762_540_004,
            )
            .unwrap();
        assert!(unmatched_search.contains("\"hits\":[]"));
        assert!(unmatched_search.contains("\"todos\":[]"));

        let unmatched_acp = rt
            .dispatch_jsonrpc(
                r#"{"jsonrpc":"2.0","id":5,"method":"acp/task.send","params":{"prompt":"完全不存在的量子天体词汇"}}"#,
                1_762_540_004,
            )
            .unwrap();
        assert!(unmatched_acp.contains("未找到匹配的录音原话依据。"));

        assert_eq!(
            format_epoch_sec_iso8601(1_762_540_000),
            "2025-11-07T18:26:40Z"
        );
    }

    #[test]
    fn mcp_acp_end_to_end_dispatch_and_koepack_benchmark_stays_under_budget() {
        let mut rt = McpAcpOwnedRuntime::new("bench-session");
        rt.ingest_recording(20261108, 60_000, 128_000, 1_762_540_000);
        for i in 0..50u64 {
            rt.ingest_utterance(
                &format!("第{}段会议记录：下周三前把海外渠道合同第{}版发给法务审阅。", i + 1, i + 1),
                i * 1_000,
                (i + 1) * 1_000,
                "zh",
                "qwen",
                1_762_540_000 + i,
            );
        }
        assert!(rt.sync_grounded_minutes_from_spine());
        let _ = rt.dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25"}}"#,
            1_762_540_100,
        );
        let _ = rt.dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            1_762_540_100,
        );
        let _ = rt.dispatch_jsonrpc(
            r#"{"jsonrpc":"2.0","id":2,"method":"acp/initialize"}"#,
            1_762_540_100,
        );

        let start = std::time::Instant::now();
        let mut total_bytes = 0usize;
        for iter in 0..100u64 {
            for req in [
                r#"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"list_recordings","arguments":{}}}"#,
                r#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_transcript","arguments":{"recording_id":"20261108"}}}"#,
                r#"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"get_minutes","arguments":{"recording_id":"20261108"}}}"#,
                r#"{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"search_context","arguments":{"query":"海外渠道合同","limit":5}}}"#,
                r#"{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"sync_qwennote_hotwords","arguments":{"hotwords":["心力豆","D3200"]}}}"#,
                r#"{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"export_koepack_v2","arguments":{"title":"基准包"}}}"#,
                r#"{"jsonrpc":"2.0","id":16,"method":"acp/task.send","params":{"prompt":"海外渠道合同审阅"}}"#,
            ] {
                let resp = rt.dispatch_jsonrpc(req, 1_762_540_200 + iter).unwrap();
                total_bytes += resp.len();
            }
        }
        let elapsed = start.elapsed();
        println!(
            "BENCH_MCP_ACP_700_DISPATCHES: elapsed_us={} total_bytes={} handled_calls={} packs={}",
            elapsed.as_micros(),
            total_bytes,
            rt.mcp_acp.handled_calls,
            rt.mcp_acp.pack_count()
        );
        assert!(total_bytes > 500_000);
        assert_eq!(rt.mcp_acp.handled_calls, 1 + 700);
        assert_eq!(rt.mcp_acp.pack_count(), 1);
        assert!(elapsed.as_millis() < 2_000, "expected < 2000ms, got {:?}", elapsed);
    }
}
