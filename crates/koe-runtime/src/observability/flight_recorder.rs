//! Bounded, redacted flight recorder and deterministic replay engine for [`crate::KoeRuntime`].

use crate::{
    credentials::IsolatedCredentials,
    observability::env::{RuntimeEnv, RuntimeEnvMetadata},
    KoeRuntime, MicrophonePcmChunk,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::{collections::VecDeque, path::Path};

/// Maximum number of boundary inputs retained in memory by [`FlightRecorder`].
pub const MAX_FLIGHT_RECORDER_ENTRIES: usize = 2048;

/// Maximum serialized byte budget retained by [`FlightRecorder`] so bundles stay within IPC limits.
pub const MAX_FLIGHT_RECORDER_BYTES: usize = 1_200_000;

/// Maximum PCM16 sample count synthesized for a single replayed microphone chunk.
pub const MAX_REPLAY_PCM_SAMPLES: usize = 64_000;

/// Maximum lowercase hex length accepted for a single replayed BLE notification chunk.
pub const MAX_REPLAY_BLE_HEX_BYTES: usize = 2 * 1024 * 1024;

/// Schema version of exported [`DiagnosticsBundle`] JSON documents.
pub const DIAGNOSTICS_BUNDLE_VERSION: u32 = 1;

const MAX_SINGLE_ENTRY_BYTES: usize = 128 * 1024;
const MAX_TZ_OFFSET_SECS: i32 = 86_399;
const INVALID_DISPATCH_SENTINEL: &str = "__invalid_dispatch_json";
const OVERSIZED_ENTRY_SENTINEL: &str = "__oversized_entry_truncated";

/// Unified, redacted boundary input accepted by [`KoeRuntime`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum RuntimeInput {
    /// Command or adapter event dispatched via `dispatch_json`.
    DispatchJson {
        /// Redacted JSON command payload.
        command: Value,
        /// Wall-clock timestamp in Unix epoch seconds.
        now: u64,
    },
    /// Raw BLE notification bytes encoded as lowercase hex.
    IngestBleChunk {
        /// Lowercase hex representation of the BLE notification bytes.
        bytes_hex: String,
        /// Wall-clock timestamp in Unix epoch seconds.
        now: u64,
    },
    /// Metadata-only record of an ingested microphone/system PCM chunk (never stores raw audio).
    IngestMicrophonePcm {
        /// Active recording identifier.
        record_id: String,
        /// Active capture session identifier.
        session_id: String,
        /// Audio lane name (`"microphone"` or `"system"`).
        lane: String,
        /// Monotonic per-lane chunk sequence number.
        sequence: u64,
        /// Number of PCM16 samples ingested.
        sample_count: usize,
        /// Optional `(epoch, captured_start_ns)` capture timing.
        timing: Option<(u64, u64)>,
        /// Wall-clock timestamp in Unix epoch seconds.
        now: u64,
    },
    /// Native audio playback progress report.
    ReportPlaybackProgress {
        /// Active recording identifier.
        record_id: String,
        /// Playback request identifier.
        request_id: u64,
        /// Playhead position in milliseconds.
        position_ms: u64,
        /// Whether playback is currently active.
        is_playing: bool,
        /// Last projected Unix epoch second cached by host.
        last_projected_now_sec: u64,
        /// Wall-clock timestamp in Unix epoch seconds.
        now: u64,
    },
    /// Periodic protocol and background timer poll.
    PollTimers {
        /// Elapsed milliseconds since previous poll.
        elapsed_ms: u64,
        /// Wall-clock timestamp in Unix epoch seconds.
        now: u64,
    },
}

impl RuntimeInput {
    /// Returns a copy with all secret keys, secret value patterns, and private user free-text scrubbed.
    #[must_use]
    pub fn redacted(&self) -> Self {
        match self {
            Self::DispatchJson { command, now } => Self::DispatchJson {
                command: redact_json_value(command),
                now: *now,
            },
            Self::IngestBleChunk { bytes_hex, now } => Self::IngestBleChunk {
                bytes_hex: bytes_hex.clone(),
                now: *now,
            },
            Self::IngestMicrophonePcm {
                record_id,
                session_id,
                lane,
                sequence,
                sample_count,
                timing,
                now,
            } => Self::IngestMicrophonePcm {
                record_id: redact_secret_patterns(record_id),
                session_id: redact_secret_patterns(session_id),
                lane: redact_secret_patterns(lane),
                sequence: *sequence,
                sample_count: *sample_count,
                timing: *timing,
                now: *now,
            },
            Self::ReportPlaybackProgress {
                record_id,
                request_id,
                position_ms,
                is_playing,
                last_projected_now_sec,
                now,
            } => Self::ReportPlaybackProgress {
                record_id: redact_secret_patterns(record_id),
                request_id: *request_id,
                position_ms: *position_ms,
                is_playing: *is_playing,
                last_projected_now_sec: *last_projected_now_sec,
                now: *now,
            },
            Self::PollTimers { elapsed_ms, now } => Self::PollTimers {
                elapsed_ms: *elapsed_ms,
                now: *now,
            },
        }
    }

    pub(crate) fn from_dispatch_json(raw_json: &str, now: u64) -> Self {
        let command = if raw_json.len() > crate::MAX_COMMAND_JSON_BYTES {
            json!({
                "type": INVALID_DISPATCH_SENTINEL,
                "byteLen": raw_json.len(),
            })
        } else {
            match serde_json::from_str::<Value>(raw_json) {
                Ok(value) => value,
                Err(_) => json!({
                    "type": INVALID_DISPATCH_SENTINEL,
                    "byteLen": raw_json.len(),
                }),
            }
        };
        Self::DispatchJson { command, now }
    }
}

/// Single recorded boundary event in a [`FlightRecorder`] ring buffer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FlightRecorderEntry {
    /// 1-based monotonic sequence number across the lifetime of the runtime session.
    pub seq: u64,
    /// Runtime view `generation` immediately after processing `input`.
    pub generation_after: u64,
    /// Mandatory redacted boundary input.
    pub input: RuntimeInput,
}

/// Serializable snapshot of a bounded [`FlightRecorder`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FlightRecorderSnapshot {
    /// Configured ring-buffer capacity (`2048`).
    pub max_entries: usize,
    /// Count of oldest entries evicted after reaching capacity.
    pub dropped_count: u64,
    /// Total boundary inputs observed by the session.
    pub total_recorded: u64,
    /// Retained entries in chronological order.
    pub entries: Vec<FlightRecorderEntry>,
}

/// Bounded in-memory recorder attached to each [`KoeRuntime`] session.
#[derive(Debug)]
pub(crate) struct FlightRecorder {
    max_entries: usize,
    max_bytes: usize,
    total_bytes: usize,
    next_seq: u64,
    dropped_count: u64,
    pending_poll_elapsed_ms: u64,
    entries: VecDeque<(FlightRecorderEntry, usize)>,
}

impl Default for FlightRecorder {
    fn default() -> Self {
        Self::with_limits(MAX_FLIGHT_RECORDER_ENTRIES, MAX_FLIGHT_RECORDER_BYTES)
    }
}

impl FlightRecorder {
    pub(crate) fn with_limits(max_entries: usize, max_bytes: usize) -> Self {
        let cap = max_entries.max(1);
        Self {
            max_entries: cap,
            max_bytes: max_bytes.max(MAX_SINGLE_ENTRY_BYTES),
            total_bytes: 0,
            next_seq: 1,
            dropped_count: 0,
            pending_poll_elapsed_ms: 0,
            entries: VecDeque::with_capacity(cap.min(64)),
        }
    }

    pub(crate) fn accumulate_noop_poll(&mut self, elapsed_ms: u64) {
        self.pending_poll_elapsed_ms = self
            .pending_poll_elapsed_ms
            .saturating_add(elapsed_ms)
            .min(60_000);
    }

    pub(crate) fn take_pending_poll_elapsed_ms(&mut self) -> u64 {
        std::mem::take(&mut self.pending_poll_elapsed_ms)
    }

    pub(crate) fn record(&mut self, input: RuntimeInput, generation_after: u64) {
        self.pending_poll_elapsed_ms = 0;
        let seq = self.next_seq;
        self.next_seq = self.next_seq.saturating_add(1);
        let mut entry = FlightRecorderEntry {
            seq,
            generation_after,
            input: input.redacted(),
        };
        let mut entry_bytes = estimate_entry_bytes(&entry);
        if entry_bytes > MAX_SINGLE_ENTRY_BYTES {
            entry.input = truncate_oversized_input(entry.input, entry_bytes);
            entry_bytes = estimate_entry_bytes(&entry);
        }
        while self.entries.len() >= self.max_entries
            || (self.total_bytes.saturating_add(entry_bytes) > self.max_bytes
                && !self.entries.is_empty())
        {
            if let Some((_, dropped_bytes)) = self.entries.pop_front() {
                self.total_bytes = self.total_bytes.saturating_sub(dropped_bytes);
                self.dropped_count = self.dropped_count.saturating_add(1);
            }
        }
        self.total_bytes = self.total_bytes.saturating_add(entry_bytes);
        self.entries.push_back((entry, entry_bytes));
    }

    pub(crate) fn len(&self) -> usize {
        self.entries.len()
    }

    pub(crate) const fn dropped_count(&self) -> u64 {
        self.dropped_count
    }

    pub(crate) fn snapshot_redacted(&self) -> FlightRecorderSnapshot {
        FlightRecorderSnapshot {
            max_entries: self.max_entries,
            dropped_count: self.dropped_count,
            total_recorded: self.next_seq.saturating_sub(1),
            entries: self
                .entries
                .iter()
                .map(|(entry, _)| FlightRecorderEntry {
                    seq: entry.seq,
                    generation_after: entry.generation_after,
                    input: entry.input.redacted(),
                })
                .collect(),
        }
    }
}

fn estimate_entry_bytes(entry: &FlightRecorderEntry) -> usize {
    serde_json::to_string(entry).map_or(256, |encoded| encoded.len().saturating_add(1))
}

fn truncate_oversized_input(input: RuntimeInput, byte_len: usize) -> RuntimeInput {
    match input {
        RuntimeInput::DispatchJson { command, now } => RuntimeInput::DispatchJson {
            command: json!({
                "type": OVERSIZED_ENTRY_SENTINEL,
                "originalType": command.get("type").cloned().unwrap_or(Value::Null),
                "byteLen": byte_len,
            }),
            now,
        },
        RuntimeInput::IngestBleChunk { now, .. } => RuntimeInput::IngestBleChunk {
            bytes_hex: String::new(),
            now,
        },
        other => other,
    }
}

/// Redacted, replayable runtime diagnostics bundle exported across C ABI, JNI, CLI, and native hosts.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DiagnosticsBundle {
    /// Bundle schema version (`1`).
    pub bundle_version: u32,
    /// Application semantic version string.
    pub app_version: String,
    /// Unix epoch timestamp in seconds when the bundle was exported.
    pub exported_at_epoch_sec: u64,
    /// Deterministic environment capture (`tzOffsetSecs`, `rngSeed`, `nonceSeed`, `initialNowSec`).
    pub env: RuntimeEnvMetadata,
    /// Expanded doctor snapshot including `runtimeState`.
    pub doctor: Value,
    /// Bounded redacted flight recorder entries.
    pub flight_recorder: FlightRecorderSnapshot,
}

/// Deterministic summary of key observable runtime state after replaying a bundle.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplaySnapshotSummary {
    /// Final runtime view generation.
    pub generation: u64,
    /// Final persisted workspace revision.
    pub revision: u64,
    /// Active UI section slug.
    pub section: String,
    /// Live (non-trashed) record count.
    pub record_count: usize,
    /// Trashed record count.
    pub trash_count: usize,
    /// Device connection phase slug.
    pub device_phase: String,
    /// Whether device handshake is complete.
    pub device_connected: bool,
    /// Whether device is currently busy recording or transferring.
    pub device_busy: bool,
    /// Whether runtime is awaiting stop confirmation from device.
    pub device_stopping: bool,
    /// Device transfer phase slug.
    pub transfer_phase: String,
    /// Lifecycle quit phase (`running`, `draining`, `blocked`, `ready`).
    pub quit_phase: String,
    /// Redacted top-level runtime error, if any.
    pub error: Option<String>,
}

/// Result returned by [`KoeRuntime::replay_bundle`].
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplayReport {
    /// Number of flight-recorder entries replayed.
    pub entries_replayed: usize,
    /// Final view generation after replaying all entries.
    pub final_generation: u64,
    /// Whether earlier flight-recorder entries were evicted before export.
    pub truncated: bool,
    /// Count of flight-recorder entries evicted before export.
    pub dropped_count: u64,
    /// Whether BLE chunks were recorded under system entropy without a deterministic RNG seed.
    pub non_deterministic_ble_crypto: bool,
    /// Explicit fidelity caveats discovered while preparing replay.
    pub warnings: Vec<String>,
    /// Final doctor projection (with `runtimeState`) after replay.
    pub doctor: Value,
    /// Condensed snapshot summary for quick equality assertions and CLI inspection.
    pub snapshot_summary: ReplaySnapshotSummary,
}

pub(crate) fn bytes_to_hex_lower(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(HEX[(b >> 4) as usize] as char);
        out.push(HEX[(b & 0x0F) as usize] as char);
    }
    out
}

fn hex_to_bytes(hex: &str) -> Result<Vec<u8>, String> {
    if !hex.len().is_multiple_of(2) {
        return Err("无效的 BLE 十六进制长度".into());
    }
    let mut out = Vec::with_capacity(hex.len() / 2);
    let raw = hex.as_bytes();
    for pair in raw.as_chunks::<2>().0 {
        let hi = decode_hex_nibble(pair[0]).ok_or("无效的 BLE 十六进制字符")?;
        let lo = decode_hex_nibble(pair[1]).ok_or("无效的 BLE 十六进制字符")?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

const fn decode_hex_nibble(byte: u8) -> Option<u8> {
    match byte {
        b'0'..=b'9' => Some(byte - b'0'),
        b'a'..=b'f' => Some(byte - b'a' + 10),
        b'A'..=b'F' => Some(byte - b'A' + 10),
        _ => None,
    }
}

fn normalize_key(key: &str) -> String {
    key.chars()
        .filter(|c| *c != '_' && *c != '-')
        .flat_map(char::to_lowercase)
        .collect()
}

fn is_secret_key(key: &str) -> bool {
    let norm = normalize_key(key);
    matches!(
        norm.as_str(),
        "apikey"
            | "deepseekapikey"
            | "token"
            | "secret"
            | "password"
            | "authorization"
            | "credential"
            | "key"
            | "privatekey"
            | "accesstoken"
            | "refreshtoken"
            | "mcpsynctoken"
    ) || norm.ends_with("apikey")
        || norm.ends_with("token")
        || norm.ends_with("secret")
        || norm.ends_with("password")
        || norm.ends_with("authorization")
        || norm.ends_with("credential")
        || norm.ends_with("privatekey")
}

fn is_private_text_key(key: &str) -> bool {
    let norm = normalize_key(key);
    matches!(
        norm.as_str(),
        "text"
            | "question"
            | "title"
            | "content"
            | "note"
            | "speaker"
            | "fromspeaker"
            | "tospeaker"
            | "path"
            | "directory"
            | "query"
            | "project"
            | "devicename"
            | "message"
            | "minutesvocabulary"
    )
}

fn is_endpoint_key(key: &str) -> bool {
    let norm = normalize_key(key);
    matches!(
        norm.as_str(),
        "asrendpoint"
            | "chatendpoint"
            | "endpoint"
            | "url"
            | "updateendpoint"
            | "downloadurl"
            | "releaseurl"
    ) || norm.ends_with("endpoint")
        || norm.ends_with("url")
}

fn scrub_url_credentials(raw: &str) -> String {
    let cleaned = redact_secret_patterns(raw);
    let trimmed = cleaned.trim();
    if trimmed.is_empty() {
        return cleaned;
    }
    let without_query = trimmed
        .find(['?', '#'])
        .map_or(trimmed, |idx| &trimmed[..idx]);
    if let Some(scheme_idx) = without_query.find("://") {
        let scheme = &without_query[..scheme_idx + 3];
        let rest = &without_query[scheme_idx + 3..];
        let (authority, path_tail) = rest
            .find('/')
            .map_or((rest, ""), |slash| (&rest[..slash], &rest[slash..]));
        let clean_authority = authority
            .rfind('@')
            .map_or(authority, |at| &authority[at + 1..]);
        format!("{scheme}{clean_authority}{path_tail}")
    } else {
        let (authority, path_tail) = without_query
            .find('/')
            .map_or((without_query, ""), |slash| {
                (&without_query[..slash], &without_query[slash..])
            });
        let clean_authority = authority
            .rfind('@')
            .map_or(authority, |at| &authority[at + 1..]);
        format!("{clean_authority}{path_tail}")
    }
}

fn is_redacted_text_placeholder(trimmed: &str) -> bool {
    trimmed
        .strip_prefix("[REDACTED_TEXT_")
        .and_then(|rest| rest.strip_suffix(']'))
        .is_some_and(|digits| !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()))
}

fn redact_free_text(value: &str) -> String {
    if value.trim().is_empty() {
        return String::new();
    }
    value
        .split('\n')
        .map(|line| {
            let trimmed = line.trim();
            if trimmed.is_empty() {
                String::new()
            } else if is_redacted_text_placeholder(trimmed) {
                trimmed.to_owned()
            } else {
                format!("[REDACTED_TEXT_{}]", trimmed.chars().count())
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Scrubs secret token patterns (`sk-*`, `Bearer *`, `Basic *`) from an arbitrary string.
#[must_use]
pub(crate) fn redact_secret_patterns(input: &str) -> String {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return input.to_owned();
    }
    let lower_trimmed = trimmed.to_ascii_lowercase();
    if lower_trimmed.starts_with("bearer ") || lower_trimmed.starts_with("basic ") {
        return "[REDACTED]".to_owned();
    }

    let mut result = String::with_capacity(input.len());
    let mut rest = input;
    while !rest.is_empty() {
        if let Some(next_rest) = match_auth_prefix(rest) {
            result.push_str("[REDACTED]");
            rest = next_rest;
            continue;
        }
        if rest.starts_with("sk-") {
            let after_prefix = &rest[3..];
            let token_len = after_prefix
                .find(|c: char| !(c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.')))
                .unwrap_or(after_prefix.len());
            if token_len > 0 {
                result.push_str("[REDACTED]");
                rest = &rest[3 + token_len..];
                continue;
            }
        }
        let mut chars = rest.chars();
        if let Some(ch) = chars.next() {
            result.push(ch);
            rest = chars.as_str();
        } else {
            break;
        }
    }
    result
}

fn match_auth_prefix(rest: &str) -> Option<&str> {
    for prefix in ["bearer ", "basic "] {
        let len = prefix.len();
        if rest.len() > len
            && rest.is_char_boundary(len)
            && rest[..len].eq_ignore_ascii_case(prefix)
        {
            let tail = &rest[len..];
            let token_end = tail
                .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | ',' | ';' | '}' | ']'))
                .unwrap_or(tail.len());
            if token_end > 0 {
                return Some(&tail[token_end..]);
            }
        }
    }
    None
}

/// Recursively redacts secret keys, secret value patterns, and private free-text fields in JSON.
#[must_use]
pub fn redact_json_value(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut out = Map::with_capacity(map.len());
            for (k, v) in map {
                let redacted = if is_secret_key(k) {
                    redact_secret_field(v)
                } else if is_endpoint_key(k) {
                    redact_endpoint_field(v)
                } else if is_private_text_key(k) {
                    redact_private_text_field(v)
                } else {
                    redact_json_value(v)
                };
                out.insert(k.clone(), redacted);
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(redact_json_value).collect()),
        Value::String(s) => Value::String(redact_secret_patterns(s)),
        other => other.clone(),
    }
}

fn redact_secret_field(value: &Value) -> Value {
    match value {
        Value::Null => Value::Null,
        Value::String(s) if s.trim().is_empty() => Value::String(String::new()),
        Value::String(_) => Value::String("[REDACTED]".to_owned()),
        Value::Array(items) => Value::Array(items.iter().map(redact_secret_field).collect()),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(k, v)| (k.clone(), redact_secret_field(v)))
                .collect(),
        ),
        _ => Value::String("[REDACTED]".to_owned()),
    }
}

fn redact_endpoint_field(value: &Value) -> Value {
    match value {
        Value::Null => Value::Null,
        Value::String(s) => Value::String(scrub_url_credentials(s)),
        Value::Array(items) => Value::Array(items.iter().map(redact_endpoint_field).collect()),
        other => redact_json_value(other),
    }
}

fn redact_private_text_field(value: &Value) -> Value {
    match value {
        Value::Null => Value::Null,
        Value::String(s) => Value::String(redact_free_text(s)),
        Value::Array(items) => Value::Array(items.iter().map(redact_private_text_field).collect()),
        other => redact_json_value(other),
    }
}

impl KoeRuntime {
    /// Builds the expanded read-only doctor projection without advancing timers or mutating state.
    #[must_use]
    pub fn doctor_snapshot_readonly(&self) -> Value {
        let device = self.device_json();
        let error = self.error_str().map(redact_secret_patterns);
        let section = serde_json::to_value(self.selection.location.page)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_else(|| "today".to_owned());
        let quit_blockers = self.quit_blocker_codes();
        let runtime_state = json!({
            "generation": self.generation,
            "section": section,
            "activeCaptureTag": self.active_capture.tag(),
            "devicePhase": device["phase"],
            "transferPhase": device["transferPhase"],
            "deviceBusy": self.is_device_busy(),
            "quitting": self.is_quitting(),
            "quitBlockers": quit_blockers,
            "requiresReopen": self.store.requires_reopen(),
            "pendingWorkCount": self.pending.len(),
            "completedQueueDepth": self.completed.len(),
            "speechSessionCount": self.captures.sessions.len(),
            "captureLaneCount": self.active_capture.microphone().map_or(0, |m| m.lane_count()),
            "flightRecorderEntries": self.flight_recorder.len(),
            "flightRecorderDropped": self.flight_recorder.dropped_count(),
        });
        json!({
            "workspaceReadable": true,
            "version": self.app_update.current_version.to_string(),
            "build": self.app_update.current_build,
            "generation": self.generation,
            "appUpdate": self.app_update_json(),
            "device": device,
            "provider": self.provider_json(),
            "error": error,
            "runtimeState": runtime_state,
        })
    }

    /// Exports a side-effect-free, redacted diagnostics bundle suitable for deterministic replay.
    #[must_use]
    pub fn export_diagnostics_bundle(&self, now: u64) -> DiagnosticsBundle {
        let eff_now = if now > 0 {
            now
        } else if self.last_now_sec > 0 {
            self.last_now_sec
        } else {
            self.env.clock().now_sec()
        };
        let doctor = redact_json_value(&self.doctor_snapshot_readonly());
        DiagnosticsBundle {
            bundle_version: DIAGNOSTICS_BUNDLE_VERSION,
            app_version: self.app_update.current_version.to_string(),
            exported_at_epoch_sec: eff_now,
            env: self.env.metadata(),
            doctor,
            flight_recorder: self.flight_recorder.snapshot_redacted(),
        }
    }

    /// Exports a side-effect-free, redacted diagnostics bundle serialized as UTF-8 JSON.
    #[must_use]
    pub fn export_diagnostics_json(&self, now: u64) -> String {
        let bundle = self.export_diagnostics_bundle(now);
        serde_json::to_string(&bundle).unwrap_or_else(|_| "{}".to_owned())
    }

    /// Deterministically replays a redacted [`DiagnosticsBundle`] into a clean workspace directory.
    pub fn replay_bundle(
        workspace_dir: &Path,
        bundle: &DiagnosticsBundle,
    ) -> Result<ReplayReport, String> {
        if bundle.bundle_version != DIAGNOSTICS_BUNDLE_VERSION {
            return Err(format!(
                "不支持的诊断包版本：{}（当前仅支持版本 {}）",
                bundle.bundle_version, DIAGNOSTICS_BUNDLE_VERSION
            ));
        }
        if bundle.flight_recorder.entries.len() > MAX_FLIGHT_RECORDER_ENTRIES {
            return Err(format!(
                "诊断包事件数 {} 超过上限 {}",
                bundle.flight_recorder.entries.len(),
                MAX_FLIGHT_RECORDER_ENTRIES
            ));
        }
        if let Some(offset) = bundle.env.tz_offset_secs {
            if !(-MAX_TZ_OFFSET_SECS..=MAX_TZ_OFFSET_SECS).contains(&offset)
                || chrono::FixedOffset::east_opt(offset).is_none()
            {
                return Err(format!("无效的时区偏移量：{offset}"));
            }
        }
        for entry in &bundle.flight_recorder.entries {
            match &entry.input {
                RuntimeInput::IngestMicrophonePcm { sample_count, .. }
                    if *sample_count > MAX_REPLAY_PCM_SAMPLES =>
                {
                    return Err(format!(
                        "音频片段采样数 {sample_count} 超过回放上限 {MAX_REPLAY_PCM_SAMPLES}"
                    ));
                }
                RuntimeInput::IngestBleChunk { bytes_hex, .. }
                    if bytes_hex.len() > MAX_REPLAY_BLE_HEX_BYTES =>
                {
                    return Err(format!(
                        "BLE 十六进制长度 {} 超过回放上限 {MAX_REPLAY_BLE_HEX_BYTES}",
                        bytes_hex.len()
                    ));
                }
                _ => {}
            }
        }

        let env = RuntimeEnv::for_replay(&bundle.env);
        let credentials = Box::new(IsolatedCredentials::deterministic(bundle.env.replay_seed()));
        let mut runtime = Self::open_with_env(workspace_dir, credentials, env)?;

        for entry in &bundle.flight_recorder.entries {
            match &entry.input {
                RuntimeInput::DispatchJson { command, now } => {
                    let kind = command.get("type").and_then(Value::as_str);
                    if kind == Some(OVERSIZED_ENTRY_SENTINEL) {
                        continue;
                    }
                    let payload = if kind == Some(INVALID_DISPATCH_SENTINEL) {
                        "{invalid".to_owned()
                    } else {
                        command.to_string()
                    };
                    let _ = runtime.dispatch_json(&payload, *now);
                }
                RuntimeInput::IngestBleChunk { bytes_hex, now } => {
                    if bytes_hex.len() > MAX_REPLAY_BLE_HEX_BYTES {
                        return Err(format!(
                            "BLE 十六进制长度 {} 超过回放上限 {MAX_REPLAY_BLE_HEX_BYTES}",
                            bytes_hex.len()
                        ));
                    }
                    let bytes = hex_to_bytes(bytes_hex)?;
                    runtime.ingest_ble_chunk(&bytes, *now);
                }
                RuntimeInput::IngestMicrophonePcm {
                    record_id,
                    session_id,
                    lane,
                    sequence,
                    sample_count,
                    timing,
                    now,
                } => {
                    if *sample_count > MAX_REPLAY_PCM_SAMPLES {
                        return Err(format!(
                            "音频片段采样数 {sample_count} 超过回放上限 {MAX_REPLAY_PCM_SAMPLES}"
                        ));
                    }
                    let synthesized: Vec<i16> = (0..*sample_count)
                        .map(|idx| ((idx % 64) as i16).wrapping_mul(16))
                        .collect();
                    let _ = runtime.ingest_microphone_pcm(MicrophonePcmChunk {
                        record_id,
                        session_id,
                        lane,
                        sequence: *sequence,
                        samples: &synthesized,
                        timing: *timing,
                        now: *now,
                    });
                }
                RuntimeInput::ReportPlaybackProgress {
                    record_id,
                    request_id,
                    position_ms,
                    is_playing,
                    last_projected_now_sec,
                    now,
                } => {
                    let _ = runtime.report_playback_progress(
                        record_id,
                        *request_id,
                        *position_ms,
                        *is_playing,
                        *last_projected_now_sec,
                        *now,
                    );
                }
                RuntimeInput::PollTimers { elapsed_ms, now } => {
                    runtime.poll_timers(*elapsed_ms, *now);
                }
            }
            let _ = runtime.drain_outbound_ble_frames();
            let _ = runtime.drain_local_asr_effects();
        }

        let dropped_count = bundle.flight_recorder.dropped_count;
        let truncated = dropped_count > 0;
        let non_deterministic_ble_crypto = bundle.env.rng_seed.is_none()
            && bundle
                .flight_recorder
                .entries
                .iter()
                .any(|entry| matches!(entry.input, RuntimeInput::IngestBleChunk { .. }));
        let mut warnings = Vec::new();
        if truncated {
            warnings.push(format!(
                "flight_recorder_truncated: {dropped_count} earlier entries were evicted before export"
            ));
        }
        if non_deterministic_ble_crypto {
            warnings.push(
                "non_deterministic_ble_crypto: bundle captured under system entropy without rngSeed"
                    .to_owned(),
            );
        }

        let doctor = redact_json_value(&runtime.doctor_snapshot_readonly());
        let snapshot_summary = runtime.replay_snapshot_summary(bundle.exported_at_epoch_sec);
        Ok(ReplayReport {
            entries_replayed: bundle.flight_recorder.entries.len(),
            final_generation: runtime.generation(),
            truncated,
            dropped_count,
            non_deterministic_ble_crypto,
            warnings,
            doctor,
            snapshot_summary,
        })
    }

    fn replay_snapshot_summary(&self, now: u64) -> ReplaySnapshotSummary {
        let snap = self.snapshot(now);
        ReplaySnapshotSummary {
            generation: self.generation,
            revision: self.workspace().revision(),
            section: snap["section"].as_str().unwrap_or("today").to_owned(),
            record_count: snap["records"].as_array().map_or(0, Vec::len),
            trash_count: snap["trashRecords"].as_array().map_or(0, Vec::len),
            device_phase: snap["device"]["phase"]
                .as_str()
                .unwrap_or("disconnected")
                .to_owned(),
            device_connected: snap["device"]["connected"].as_bool().unwrap_or(false),
            device_busy: snap["device"]["busy"].as_bool().unwrap_or(false),
            device_stopping: snap["device"]["stopping"].as_bool().unwrap_or(false),
            transfer_phase: snap["device"]["transferPhase"]
                .as_str()
                .unwrap_or("idle")
                .to_owned(),
            quit_phase: snap["lifecycle"]["quitPhase"]
                .as_str()
                .unwrap_or("running")
                .to_owned(),
            error: self.error_str().map(redact_secret_patterns),
        }
    }
}
