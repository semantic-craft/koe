use std::collections::{BTreeSet, VecDeque};
use std::ffi::OsStr;
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

pub use koe_engine::product::{CompanionRoutingMode, RecordOrigin};
use koe_engine::{
    commands::DeviceCommands,
    session::{RawCompanionSignal, TransferPhaseTag},
};
use serde::{Deserialize, Serialize};

use crate::{KoeRuntime, speech::DictationSource};

/// Number of 20 ms slices (`60 ms`) skipped immediately after a start front double-tap.
pub const POST_TAP_SKIP_SLICES: usize = 3;

/// Number of 20 ms slices (`240 ms`) held back so a stop front double-tap trims finger-tap thumps.
pub const PRE_STOP_TAP_HOLDBACK_SLICES: usize = 12;

/// Wire protocol version emitted in [`CompanionStreamEvent::Hello`].
pub const COMPANION_PROTOCOL_VERSION: u32 = 1;

/// Canonical PCM format string emitted in [`CompanionStreamEvent::Hello`].
pub const COMPANION_AUDIO_FORMAT: &str = "pcm16/16000/mono";

/// Canonical D3200 front housing control name.
pub const COMPANION_FRONT_CONTROL: &str = "front_surface";

/// Canonical D3200 front housing gesture trigger name.
pub const COMPANION_DOUBLE_TAP_TRIGGER: &str = "double_tap";

/// Maximum encoded byte length for a Unix domain socket path on macOS (`sun_path` is 104 bytes including NUL).
const MAX_UNIX_SOCKET_PATH_BYTES: usize = 103;

/// Resolves the canonical local bridge Unix domain socket path for `workspace`.
///
/// Honors `KOE_BRIDGE_SOCKET` (`""`, `"0"`, or `"off"` disables the socket), places App Sandbox
/// default container workspaces inside `<Data>/.koe/koe.sock` (`koe-dev.sock` for development)
/// to stay within the 104-byte `sun_path` kernel limit without altering entitlements, and falls
/// back to `<workspace>/koe.sock` for standalone directories.
#[must_use]
pub fn resolve_bridge_socket_path(workspace: &Path) -> Option<PathBuf> {
    resolve_bridge_socket_path_with_env(workspace, std::env::var_os("KOE_BRIDGE_SOCKET").as_deref())
}

pub(crate) fn resolve_bridge_socket_path_with_env(
    workspace: &Path,
    env_override: Option<&OsStr>,
) -> Option<PathBuf> {
    if let Some(raw) = env_override {
        if let Some(s) = raw.to_str() {
            let trimmed = s.trim();
            if trimmed.is_empty() || trimmed == "0" || trimmed.eq_ignore_ascii_case("off") {
                return None;
            }
            let candidate = PathBuf::from(trimmed);
            return (candidate.as_os_str().as_encoded_bytes().len() < MAX_UNIX_SOCKET_PATH_BYTES)
                .then_some(candidate);
        }
        if raw.is_empty() {
            return None;
        }
        let candidate = PathBuf::from(raw);
        return (candidate.as_os_str().as_encoded_bytes().len() < MAX_UNIX_SOCKET_PATH_BYTES)
            .then_some(candidate);
    }

    let canonical_workspace = workspace.ancestors().find_map(|ancestor| {
        if !ancestor.ends_with("Containers/com.anker.ankerRecorder/Data") {
            return None;
        }
        match workspace.strip_prefix(ancestor).ok()?.to_str()? {
            "Library/Application Support/KoeWorkspace" => Some((ancestor, "koe.sock")),
            "Library/Application Support/KoeWorkspaceDevelopment" => {
                Some((ancestor, "koe-dev.sock"))
            }
            _ => None,
        }
    });
    let candidate = if let Some((container_data, sock_name)) = canonical_workspace {
        container_data.join(".koe").join(sock_name)
    } else {
        workspace.join("koe.sock")
    };

    (candidate.as_os_str().as_encoded_bytes().len() < MAX_UNIX_SOCKET_PATH_BYTES)
        .then_some(candidate)
}

const MAX_COMPANION_EVENTS: usize = 8_192;

/// Hardware input control advertised to companion subscribers.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeclaredControlSpec {
    /// Control surface identifier (`"front_surface"`).
    pub name: String,
    /// Gesture trigger identifier (`"double_tap"`).
    pub trigger: String,
}

/// Inbound control command sent by a companion stream subscriber.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "method",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum CompanionClientCommand {
    /// Subscribes to live companion events and requests an initial `hello` event.
    Subscribe,
    /// Selects whether recognized final text is sent to the companion text bridge.
    SetDictationActive {
        /// Explicit dictation selection; ordinary recording does not enable this.
        active: bool,
    },
    /// Synchronizes active voice capture state across keyboard shortcuts and front double-taps.
    SetCaptureActive {
        /// Whether decoded 16 kHz PCM16 frames should be emitted to subscribers.
        active: bool,
        /// Optional transition trigger (`"double_tap"`, `"shortcut_dictate"`, etc.).
        #[serde(default)]
        reason: Option<String>,
    },
}

/// Outbound companion event frame emitted in monotonic sequence order.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(
    tag = "event",
    rename_all = "snake_case",
    rename_all_fields = "camelCase"
)]
pub enum CompanionStreamEvent {
    /// Initial and per-reconnect session declaration.
    Hello {
        /// Companion protocol version (`1`).
        protocol_version: u32,
        /// Optional negotiated stream features.
        capabilities: Vec<String>,
        /// Stable D3200 device identifier.
        device_id: String,
        /// Human-readable device display name.
        device_name: String,
        /// RFC 4122 v4 UUID rotated on every new BLE connection.
        epoch: String,
        /// Whether the D3200 BLE transport is authenticated and online.
        online: bool,
        /// Whether a realtime 16 kHz Opus stream is hot and ready for zero-latency capture.
        standby_ready: bool,
        /// Microphone battery percentage (`0..=100`), if known.
        battery_percent: Option<u8>,
        /// Active routing policy (`"disabled"`, `"collar_standby"`, or `"meeting_and_collar"`).
        routing_mode: String,
        /// Declared hardware controls.
        controls: Vec<DeclaredControlSpec>,
        /// Audio stream format descriptor (`"pcm16/16000/mono"`).
        audio_format: String,
    },
    /// Stateless hardware control edge event.
    ControlEdge {
        /// Stable D3200 device identifier.
        device_id: String,
        /// Active BLE connection epoch UUID.
        epoch: String,
        /// Strictly monotonic 1-based sequence number within `epoch`.
        sequence: u64,
        /// Control surface identifier (`"front_surface"`).
        control: String,
        /// Edge state (`true` followed by `false` for a stateless double-tap pulse).
        down: bool,
        /// Active bean `file_id`, if known.
        file_id: Option<u32>,
        /// Millisecond offset within `file_id`, if known.
        offset_ms: Option<u64>,
    },
    /// Single 20 ms (`320` samples) 16 kHz mono signed 16-bit little-endian PCM frame.
    AudioPcm16 {
        /// Stable D3200 device identifier.
        device_id: String,
        /// Active BLE connection epoch UUID.
        epoch: String,
        /// Strictly monotonic 1-based sequence number within `epoch`.
        sequence: u64,
        /// Sample rate in Hz (`16000`).
        sample_rate_hz: u32,
        /// Standard RFC 4648 Base64-encoded little-endian `i16` PCM bytes.
        samples_le_b64: String,
    },
    /// A persisted recognition final selected by an explicit dictation intent.
    TranscriptFinal {
        /// Stable recording identity.
        record_id: String,
        /// Stable cited segment identity.
        segment_id: String,
        /// Inclusive start offset in the recording.
        start_ms: u64,
        /// End offset in the recording.
        end_ms: u64,
        /// Recognized text from the selected speech engine.
        text: String,
        /// Explicit dictation selection, always true for this event.
        dictation: bool,
    },
    /// Device connection, standby readiness, battery, or recording-state update.
    DeviceStatus {
        /// Stable D3200 device identifier.
        device_id: String,
        /// Whether the D3200 BLE transport is authenticated and online.
        online: bool,
        /// Whether a realtime 16 kHz Opus stream is hot and ready.
        standby_ready: bool,
        /// Microphone battery percentage (`0..=100`), if known.
        battery_percent: Option<u8>,
        /// D3200 recording state (`0` = stopped, `1` = recording, `2` = paused).
        recording_state: u8,
    },
}

#[derive(Clone, PartialEq, Eq)]
struct StatusSnapshot {
    online: bool,
    standby_ready: bool,
    battery_percent: Option<u8>,
    recording_state: u8,
}

enum CompanionTail {
    Flush,
    Discard,
}

pub(crate) struct CompanionRuntime {
    pub epoch: String,
    pub sequence: u64,
    pub forwarded_audio_frames: u64,
    pub capture_active: bool,
    pub auto_gate: bool,
    pub bridge_subscribers: usize,
    pub manual_gate_subscribers: usize,
    pub last_dictation_text: Option<String>,
    pub armed: bool,
    pub standby_stream_owned: bool,
    pub active_standby_file_id: Option<u32>,
    pub pending_standby_stop: bool,
    pub pre_standby_catalog_ids: BTreeSet<u32>,
    pub pre_standby_catalog_complete: bool,
    pub deleted_in_connection: BTreeSet<u32>,
    pub standby_suppressed_for_connection: bool,
    pub post_tap_skip_slices: usize,
    pub pending_tap_holdback_extra: usize,
    pub tail_holdback: VecDeque<Vec<i16>>,
    pub events: VecDeque<CompanionStreamEvent>,
    pub standby_file_ids: BTreeSet<u32>,
    pub last_recording_state: u8,
    was_connected: bool,
    last_connection_id: Option<String>,
    last_status: Option<StatusSnapshot>,
}

impl Default for CompanionRuntime {
    fn default() -> Self {
        Self {
            epoch: generate_uuid_v4(),
            sequence: 0,
            forwarded_audio_frames: 0,
            capture_active: false,
            auto_gate: true,
            bridge_subscribers: 0,
            manual_gate_subscribers: 0,
            last_dictation_text: None,
            armed: false,
            standby_stream_owned: false,
            active_standby_file_id: None,
            pending_standby_stop: false,
            pre_standby_catalog_ids: BTreeSet::new(),
            pre_standby_catalog_complete: false,
            deleted_in_connection: BTreeSet::new(),
            standby_suppressed_for_connection: false,
            post_tap_skip_slices: 0,
            pending_tap_holdback_extra: 0,
            tail_holdback: VecDeque::new(),
            events: VecDeque::new(),
            standby_file_ids: BTreeSet::new(),
            last_recording_state: 0,
            was_connected: false,
            last_connection_id: None,
            last_status: Some(StatusSnapshot {
                online: false,
                standby_ready: false,
                battery_percent: None,
                recording_state: 0,
            }),
        }
    }
}

impl CompanionRuntime {
    pub(super) fn clear_transient_capture(&mut self) {
        self.capture_active = false;
        self.post_tap_skip_slices = 0;
        self.tail_holdback.clear();
    }

    pub(super) fn on_ble_disconnected(&mut self) {
        self.deleted_in_connection.clear();
    }

    pub(super) fn on_ble_released(&mut self) {
        self.on_ble_disconnected();
        self.clear_transient_capture();
    }

    fn next_sequence(&mut self) -> u64 {
        self.sequence = self.sequence.saturating_add(1);
        self.sequence
    }

    fn push_event(&mut self, event: CompanionStreamEvent) {
        match &event {
            CompanionStreamEvent::TranscriptFinal { text, .. } if !text.trim().is_empty() => {
                self.last_dictation_text = Some(text.clone());
            }
            CompanionStreamEvent::AudioPcm16 { .. } => {
                self.forwarded_audio_frames = self.forwarded_audio_frames.saturating_add(1);
            }
            _ => {}
        }
        if self.events.len() >= MAX_COMPANION_EVENTS {
            self.events.pop_front();
        }
        self.events.push_back(event);
    }
}

impl KoeRuntime {
    pub(super) fn active_companion_mode(&self) -> CompanionRoutingMode {
        if self.companion.armed {
            self.workspace().companion_mode()
        } else {
            CompanionRoutingMode::Disabled
        }
    }

    pub(super) fn publish_transcript(
        &mut self,
        record_id: &str,
        segment_id: koe_engine::domain::SegmentId,
        segment: &koe_client_providers::TranscriptSegment,
    ) {
        self.companion
            .push_event(CompanionStreamEvent::TranscriptFinal {
                record_id: record_id.into(),
                segment_id: segment_id.to_string(),
                start_ms: segment.start_ms,
                end_ms: segment.end_ms,
                text: segment.text.clone(),
                dictation: true,
            });
    }
    /// Builds a current [`CompanionStreamEvent::Hello`] snapshot for new subscribers.
    #[must_use]
    pub fn companion_hello(&self) -> CompanionStreamEvent {
        CompanionStreamEvent::Hello {
            protocol_version: COMPANION_PROTOCOL_VERSION,
            capabilities: Vec::new(),
            device_id: self.companion_device_id(),
            device_name: self.companion_device_name(),
            epoch: self.companion.epoch.clone(),
            online: self.device.is_connected(),
            standby_ready: self.is_standby_ready(),
            battery_percent: self
                .device
                .session
                .telemetry
                .as_ref()
                .and_then(|t| t.battery),
            routing_mode: self.workspace().companion_mode().as_str().to_string(),
            controls: vec![DeclaredControlSpec {
                name: COMPANION_FRONT_CONTROL.to_string(),
                trigger: COMPANION_DOUBLE_TAP_TRIGGER.to_string(),
            }],
            audio_format: COMPANION_AUDIO_FORMAT.to_string(),
        }
    }

    /// Drains all queued outbound [`CompanionStreamEvent`] frames in monotonic order.
    pub fn drain_companion_events(&mut self) -> Vec<CompanionStreamEvent> {
        self.companion.events.drain(..).collect()
    }

    /// Returns `true` when the D3200 is connected in a companion-enabled mode with an active live stream.
    #[must_use]
    pub fn is_standby_ready(&self) -> bool {
        self.device.is_connected()
            && self.active_companion_mode() != CompanionRoutingMode::Disabled
            && self.device.session.active_is_realtime
            && matches!(
                self.device.session.transfer.phase,
                TransferPhaseTag::StreamingRealtime
            )
            && !self.device.session.is_realtime_quiet_draining()
            && !self.device.awaiting_stop
    }

    /// Enables or disables internal capture-active toggling on front double-tap events.
    ///
    /// Standalone Koe debugging (`koe companion-listen`) leaves `auto_gate` enabled; an external
    /// orchestrator that drives [`Self::set_companion_capture_active`] explicitly may disable it.
    pub fn set_companion_auto_gate(&mut self, enabled: bool) {
        self.companion.auto_gate = enabled;
    }

    /// Registers an active companion stream subscriber across any subscription policy.
    pub fn acquire_companion_subscriber(&mut self) {
        self.companion.bridge_subscribers = self.companion.bridge_subscribers.saturating_add(1);
        self.generation = self.generation.saturating_add(1);
    }

    /// Unregisters a disconnected companion stream subscriber.
    pub fn release_companion_subscriber(&mut self) {
        self.companion.bridge_subscribers = self.companion.bridge_subscribers.saturating_sub(1);
        self.generation = self.generation.saturating_add(1);
    }

    /// Acquires a scoped manual capture-gate lease for a subscriber with `autoGate == false`.
    pub fn acquire_companion_manual_gate(&mut self) {
        self.companion.manual_gate_subscribers =
            self.companion.manual_gate_subscribers.saturating_add(1);
        self.generation = self.generation.saturating_add(1);
    }

    /// Releases a scoped manual capture-gate lease when a subscriber disconnects.
    pub fn release_companion_manual_gate(&mut self) {
        self.companion.manual_gate_subscribers =
            self.companion.manual_gate_subscribers.saturating_sub(1);
        self.generation = self.generation.saturating_add(1);
    }

    fn effective_companion_auto_gate(&self) -> bool {
        self.companion.auto_gate && self.companion.manual_gate_subscribers == 0
    }

    /// Synchronizes companion PCM capture gating across front double-taps and host shortcuts.
    ///
    /// Starting with `reason == Some("double_tap")` skips 60 ms (`POST_TAP_SKIP_SLICES`) of tap
    /// transient; stopping with `reason == Some("double_tap")` discards the 240 ms tail holdback
    /// window so finger-tap housing thumps never leak into ASR; stopping for any other reason
    /// flushes the held-back speech tail into the companion event queue.
    pub fn set_companion_capture_active(&mut self, active: bool, reason: Option<String>) {
        let double_tap = reason.as_deref() == Some(COMPANION_DOUBLE_TAP_TRIGGER);
        let tail = if double_tap {
            CompanionTail::Discard
        } else {
            CompanionTail::Flush
        };
        self.set_companion_pcm_gate(active, double_tap, tail);
        self.set_source_dictation(self.bean_dictation_source(), active);
    }

    /// Synchronizes companion PCM capture gating at wall-clock `now` and bumps generation.
    pub fn set_companion_capture_active_at(
        &mut self,
        active: bool,
        reason: Option<String>,
        now: u64,
    ) {
        if now > 0 {
            self.last_now_sec = now;
        }
        if self.is_quitting() {
            return;
        }
        self.set_companion_capture_active(active, reason);
        self.generation = self.generation.saturating_add(1);
    }

    /// Updates dictation state at wall-clock `now` and bumps generation without snapshot serialization.
    pub fn set_dictation_active_at(&mut self, active: bool, now: u64) {
        if now > 0 {
            self.last_now_sec = now;
        }
        if self.is_quitting() {
            return;
        }
        self.set_dictation_active(active);
        self.generation = self.generation.saturating_add(1);
    }

    fn set_companion_pcm_gate(&mut self, active: bool, skip_start_tap: bool, tail: CompanionTail) {
        self.companion.pending_tap_holdback_extra = 0;
        if self.companion.capture_active && !active {
            match tail {
                CompanionTail::Discard => self.companion.tail_holdback.clear(),
                CompanionTail::Flush => self.flush_companion_holdback(),
            }
            self.companion.capture_active = false;
        } else if !self.companion.capture_active && active {
            self.companion.tail_holdback.clear();
            self.companion.post_tap_skip_slices = if skip_start_tap {
                POST_TAP_SKIP_SLICES
            } else {
                0
            };
            self.companion.capture_active = true;
        }
    }

    pub(crate) fn is_known_bean_record(&self, file_id: u32) -> bool {
        file_id > 0
            && (self.captures.records_by_file_id.contains_key(&file_id)
                || self.captures.active.contains_key(&file_id)
                || self
                    .workspace()
                    .records()
                    .values()
                    .any(|r| r.origin == RecordOrigin::Bean && r.aggregate.file_id == file_id))
    }

    pub(crate) fn is_standby_file(&self, file_id: u32) -> bool {
        file_id != 0
            && (self.companion.standby_file_ids.contains(&file_id)
                || self.workspace().is_standby_scratch_file(file_id)
                || self.workspace().is_reclaimed_standby_file(file_id))
    }

    pub(crate) fn can_own_as_standby_scratch(&self, file_id: u32) -> bool {
        if self
            .all_day
            .run
            .as_ref()
            .is_some_and(|r| r.source == "bean")
        {
            return false;
        }
        file_id > 0
            && !self.is_known_bean_record(file_id)
            && (self.is_standby_file(file_id)
                || (self.companion.pre_standby_catalog_complete
                    && !self.companion.pre_standby_catalog_ids.contains(&file_id)))
    }

    pub(crate) fn treats_file_as_standby(&self, file_id: u32) -> bool {
        if self
            .all_day
            .run
            .as_ref()
            .is_some_and(|r| r.source == "bean")
        {
            return false;
        }
        !self.is_known_bean_record(file_id)
            && (self.is_standby_file(file_id)
                || self.companion.standby_stream_owned
                || self.companion.pending_standby_stop)
    }

    pub(crate) fn mark_standby_scratch_file(&mut self, file_id: u32) -> Result<(), String> {
        if file_id == 0 {
            return Ok(());
        }
        self.companion.standby_file_ids.insert(file_id);
        if !self.workspace().is_standby_scratch_file(file_id) {
            self.commit(|w| {
                w.record_standby_scratch_file_id(file_id);
                Ok(())
            })?;
        }
        Ok(())
    }

    fn bean_dictation_source(&self) -> DictationSource {
        if self.companion.standby_stream_owned {
            DictationSource::Standby
        } else {
            DictationSource::Bean
        }
    }

    pub(super) fn stop_bean_dictation(&mut self) {
        self.set_source_dictation(DictationSource::Bean, false);
        self.set_source_dictation(DictationSource::Standby, false);
    }

    pub(crate) fn stop_owned_standby_stream(&mut self) -> Result<(), String> {
        self.stop_bean_dictation();
        let session = &self.device.session;
        let in_flight = session.device_recording_active
            || session.pending_realtime_subscribe
            || (session.active_is_realtime && !session.transfer.quiet_draining);
        let active_fid = session
            .active_file_id
            .filter(|&id| id > 0)
            .or_else(|| self.companion.active_standby_file_id.take());
        if let Some(fid) = active_fid {
            if self.can_own_as_standby_scratch(fid) {
                self.mark_standby_scratch_file(fid)?;
            }
            self.companion.pending_standby_stop = false;
        } else if self.companion.standby_stream_owned && in_flight {
            self.companion.pending_standby_stop = true;
        }
        self.companion.active_standby_file_id = None;
        self.companion.standby_stream_owned = false;
        self.companion.clear_transient_capture();
        if in_flight {
            self.device.stop_recording();
        }
        Ok(())
    }

    pub(crate) fn drive_companion(&mut self, now: u64) -> bool {
        let mut changed = false;
        let connected = self.device.is_connected();
        let reconnected = (!self.companion.was_connected && connected)
            || (connected
                && self.device.connection.is_some()
                && self.companion.last_connection_id.is_some()
                && self.device.connection != self.companion.last_connection_id);

        if reconnected {
            self.companion.epoch = generate_uuid_v4();
            self.companion.sequence = 0;
            self.companion.forwarded_audio_frames = 0;
            self.companion.active_standby_file_id = None;
            self.companion.pending_standby_stop = false;
            self.companion.pre_standby_catalog_ids.clear();
            self.companion.pre_standby_catalog_complete = false;
            self.companion.standby_suppressed_for_connection = false;
            self.companion.on_ble_released();
            self.companion.last_recording_state = self
                .device
                .session
                .telemetry
                .as_ref()
                .map_or(0, |t| t.recording_status.min(2));
            let hello = self.companion_hello();
            self.companion.last_status = Some(self.current_companion_status());
            self.companion.push_event(hello);
            changed = true;
        } else if self.companion.was_connected && !connected {
            self.stop_bean_dictation();
            self.retire_active_standby_stream();
            self.companion.pre_standby_catalog_ids.clear();
            self.companion.pre_standby_catalog_complete = false;
            self.companion.standby_suppressed_for_connection = false;
            self.companion.on_ble_released();
            self.companion.last_recording_state = 0;
            changed = true;
        }

        self.companion.was_connected = connected;
        if connected {
            self.companion.last_connection_id = self.device.connection.clone();
        } else if self.device.connection.is_none() {
            self.companion.last_connection_id = None;
        }

        changed |= self.process_companion_signals();

        if self.companion.pending_standby_stop {
            let candidate = self
                .device
                .session
                .raw_catalog
                .iter()
                .filter(|f| {
                    f.file_id > 0
                        && f.end_time == Some(0)
                        && self.can_own_as_standby_scratch(f.file_id)
                        && !self.is_device_file_synced(f.file_id)
                })
                .max_by_key(|f| f.file_id)
                .map(|f| f.file_id);
            if let Some(fid) = candidate {
                if self.can_own_as_standby_scratch(fid) {
                    let _ = self.mark_standby_scratch_file(fid);
                }
                self.companion.active_standby_file_id = None;
                self.companion.pending_standby_stop = false;
                self.device.stop_recording();
                changed = true;
            }
        }

        if self.device.session.has_complete_catalog()
            && !self.companion.pre_standby_catalog_complete
        {
            self.companion.pre_standby_catalog_ids = self.device.session.raw_catalog_file_ids();
            self.companion.pre_standby_catalog_complete = true;
        }

        if self.device.is_connected()
            && self.device.session.telemetry.is_some()
            && self.is_device_completely_idle()
            && self.device.session.has_complete_catalog()
            && !self.device.session.is_catalog_loading()
        {
            if self.current_companion_recording_state() == 0 {
                let mut reclaim_ids: BTreeSet<u32> = self
                    .workspace()
                    .standby_scratch_file_ids()
                    .iter()
                    .copied()
                    .collect();
                for entry in &self.device.session.raw_catalog {
                    if self.workspace().is_reclaimed_standby_file(entry.file_id) {
                        reclaim_ids.insert(entry.file_id);
                    }
                }
                reclaim_ids
                    .retain(|&fid| fid > 0 && !self.companion.deleted_in_connection.contains(&fid));
                if !reclaim_ids.is_empty() {
                    for &fid in &reclaim_ids {
                        self.device.outbound.push(DeviceCommands::delete_file(fid));
                        self.companion.deleted_in_connection.insert(fid);
                        self.device.session.remove_catalog_entry(fid);
                        self.companion.standby_file_ids.insert(fid);
                    }
                    let _ = self.commit(|w| {
                        for &fid in &reclaim_ids {
                            w.record_purged_bean_file_id(fid);
                        }
                        Ok(())
                    });
                    changed = true;
                }
            }

            if !self.is_quitting()
                && !self.companion.standby_suppressed_for_connection
                && self.active_companion_mode() == CompanionRoutingMode::CollarStandby
                && self.all_day.run.is_none()
            {
                let open_entry = self
                    .device
                    .session
                    .raw_catalog
                    .iter()
                    .find(|f| f.end_time == Some(0));
                let open_is_known =
                    open_entry.is_some_and(|f| self.is_known_bean_record(f.file_id));
                if self.current_companion_recording_state() != 0 && open_is_known {
                    self.companion.standby_suppressed_for_connection = true;
                } else {
                    let page0 = DeviceCommands::list_files_with_end_time(0);
                    self.device.outbound.retain(|f| f != &page0);
                    self.companion.active_standby_file_id = None;
                    self.companion.pending_standby_stop = false;
                    let skip_existing = self.current_companion_recording_state() != 0;
                    let outcome = self.device.session.start_realtime_recording_with_options(
                        None,
                        now.saturating_mul(1_000),
                        skip_existing,
                    );
                    self.device.accept(outcome);
                    self.companion.standby_stream_owned = true;
                    let _ = self.process_companion_signals();
                    changed = true;
                }
            }
        }

        let status = self.current_companion_status();
        if self.companion.last_status.as_ref() != Some(&status) {
            self.companion.last_status = Some(status.clone());
            let event = CompanionStreamEvent::DeviceStatus {
                device_id: self.companion_device_id(),
                online: status.online,
                standby_ready: status.standby_ready,
                battery_percent: status.battery_percent,
                recording_state: status.recording_state,
            };
            self.companion.push_event(event);
            changed = true;
        }

        changed
    }

    pub(crate) fn is_device_completely_idle(&self) -> bool {
        !self.device.session.device_recording_active
            && !self.device.session.pending_realtime_subscribe
            && !self.device.session.is_catalog_loading()
            && self.device.session.active_file_id.is_none()
            && matches!(self.device.session.transfer.phase, TransferPhaseTag::Idle)
            && !self.device.awaiting_stop
            && !self.device.session.is_offline_pull_suspended()
    }

    fn process_companion_signals(&mut self) -> bool {
        let signals = self.device.session.take_companion_signals();
        if signals.is_empty() {
            return false;
        }
        let device_id = self.companion_device_id();

        for signal in signals {
            match signal {
                RawCompanionSignal::RecordingStateChanged { state, file_id } => {
                    let prev_recording_state = self.companion.last_recording_state;
                    self.companion.last_recording_state = state;
                    if prev_recording_state != 0 && state == 0 {
                        self.companion.deleted_in_connection.clear();
                        self.device.auto_pull_attempted.clear();
                    }
                    if state == 1
                        && (self.companion.standby_stream_owned
                            || self.companion.pending_standby_stop)
                    {
                        if let Some(fid) = file_id.filter(|&id| id > 0) {
                            if self.can_own_as_standby_scratch(fid) {
                                self.companion.active_standby_file_id = Some(fid);
                                let _ = self.mark_standby_scratch_file(fid);
                            } else {
                                self.companion.active_standby_file_id = None;
                            }
                            if self.companion.pending_standby_stop {
                                self.companion.pending_standby_stop = false;
                                self.companion.standby_stream_owned = false;
                                self.device.stop_recording();
                            }
                        }
                    } else if state == 0 || state == 2 {
                        if self.all_day.run.is_none()
                            && (prev_recording_state == 1 || !self.captures.active.is_empty())
                        {
                            self.companion.armed = false;
                        }
                        if self.companion.standby_stream_owned {
                            self.stop_bean_dictation();
                            let fid = file_id
                                .filter(|&id| id > 0)
                                .or_else(|| self.companion.active_standby_file_id.take())
                                .or_else(|| {
                                    self.device.session.active_file_id.filter(|&id| id > 0)
                                });
                            if let Some(fid) = fid {
                                if self.can_own_as_standby_scratch(fid) {
                                    let _ = self.mark_standby_scratch_file(fid);
                                }
                            }
                            self.companion.active_standby_file_id = None;
                            self.companion.standby_stream_owned = false;
                            self.companion.pending_standby_stop = false;
                            self.companion.standby_suppressed_for_connection = true;
                            self.companion.capture_active = false;
                            self.companion.post_tap_skip_slices = 0;
                            self.companion.tail_holdback.clear();
                        } else if self.companion.pending_standby_stop {
                            if let Some(fid) = file_id.filter(|&id| id > 0) {
                                if self.can_own_as_standby_scratch(fid) {
                                    let _ = self.mark_standby_scratch_file(fid);
                                }
                                self.companion.active_standby_file_id = None;
                                self.companion.pending_standby_stop = false;
                            }
                        }
                    }
                }
                RawCompanionSignal::DeleteFileAck { success } => {
                    if !success {
                        let rollback_ids: Vec<u32> = self
                            .companion
                            .deleted_in_connection
                            .iter()
                            .copied()
                            .collect();
                        for fid in rollback_ids {
                            let _ = self.mark_standby_scratch_file(fid);
                        }
                        self.companion.deleted_in_connection.clear();
                    }
                }
                RawCompanionSignal::FrontDoubleTap {
                    file_id, offset_ms, ..
                } => {
                    if self.active_companion_mode() == CompanionRoutingMode::Disabled
                        && !self
                            .all_day
                            .run
                            .as_ref()
                            .is_some_and(|r| r.source == "bean")
                    {
                        continue;
                    }
                    let next_dictation = !self.dictation_active(self.bean_dictation_source());
                    let epoch = self.companion.epoch.clone();
                    let seq_down = self.companion.next_sequence();
                    self.companion
                        .push_event(CompanionStreamEvent::ControlEdge {
                            device_id: device_id.clone(),
                            epoch: epoch.clone(),
                            sequence: seq_down,
                            control: COMPANION_FRONT_CONTROL.to_string(),
                            down: true,
                            file_id: Some(file_id),
                            offset_ms: Some(offset_ms),
                        });
                    let seq_up = self.companion.next_sequence();
                    self.companion
                        .push_event(CompanionStreamEvent::ControlEdge {
                            device_id: device_id.clone(),
                            epoch,
                            sequence: seq_up,
                            control: COMPANION_FRONT_CONTROL.to_string(),
                            down: false,
                            file_id: Some(file_id),
                            offset_ms: Some(offset_ms),
                        });
                    if self.effective_companion_auto_gate() {
                        self.set_companion_capture_active(
                            next_dictation,
                            Some(COMPANION_DOUBLE_TAP_TRIGGER.to_string()),
                        );
                    } else if self.companion.capture_active {
                        self.companion.pending_tap_holdback_extra = POST_TAP_SKIP_SLICES;
                    }
                }
                RawCompanionSignal::LivePcm16 {
                    samples, ..
                } => {
                    if self.active_companion_mode() == CompanionRoutingMode::Disabled {
                        continue;
                    }
                    if self.companion.post_tap_skip_slices > 0 {
                        self.companion.post_tap_skip_slices -= 1;
                        continue;
                    }
                    if self.companion.capture_active {
                        self.companion.tail_holdback.push_back(samples);
                        let limit = PRE_STOP_TAP_HOLDBACK_SLICES
                            + self.companion.pending_tap_holdback_extra;
                        if self.companion.tail_holdback.len() > limit {
                            self.companion.pending_tap_holdback_extra = 0;
                        }
                        let effective_limit = PRE_STOP_TAP_HOLDBACK_SLICES
                            + self.companion.pending_tap_holdback_extra;
                        while self.companion.tail_holdback.len() > effective_limit {
                            if let Some(ready) = self.companion.tail_holdback.pop_front() {
                                self.capture_standby_dictation(&ready);
                                let epoch = self.companion.epoch.clone();
                                let seq = self.companion.next_sequence();
                                self.companion.push_event(CompanionStreamEvent::AudioPcm16 {
                                    device_id: device_id.clone(),
                                    epoch,
                                    sequence: seq,
                                    sample_rate_hz: 16_000,
                                    samples_le_b64: encode_pcm16_le_b64(&ready),
                                });
                            }
                        }
                    }
                }
            }
        }
        true
    }

    pub(super) fn flush_companion_holdback(&mut self) {
        let device_id = self.companion_device_id();
        while let Some(ready) = self.companion.tail_holdback.pop_front() {
            self.capture_standby_dictation(&ready);
            let epoch = self.companion.epoch.clone();
            let seq = self.companion.next_sequence();
            self.companion.push_event(CompanionStreamEvent::AudioPcm16 {
                device_id: device_id.clone(),
                epoch,
                sequence: seq,
                sample_rate_hz: 16_000,
                samples_le_b64: encode_pcm16_le_b64(&ready),
            });
        }
    }

    fn companion_device_id(&self) -> String {
        if let Some(serial) = self
            .device
            .session
            .telemetry
            .as_ref()
            .map(|t| t.serial_number.trim())
            .filter(|s| !s.is_empty())
        {
            return serial.to_string();
        }
        if let Some(conn) = self
            .device
            .connection
            .as_deref()
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            return conn.to_string();
        }
        "d3200".to_string()
    }

    fn companion_device_name(&self) -> String {
        self.device
            .device_name
            .clone()
            .unwrap_or_else(|| "Soundcore Work".to_string())
    }

    pub(crate) fn current_companion_recording_state(&self) -> u8 {
        if !self.device.is_connected() {
            0
        } else if self.device.session.device_recording_active {
            1
        } else {
            self.companion.last_recording_state
        }
    }

    fn current_companion_status(&self) -> StatusSnapshot {
        let online = self.device.is_connected();
        StatusSnapshot {
            online,
            standby_ready: self.is_standby_ready(),
            battery_percent: self
                .device
                .session
                .telemetry
                .as_ref()
                .and_then(|t| t.battery),
            recording_state: self.current_companion_recording_state(),
        }
    }
}

/// Encodes signed 16-bit PCM samples as little-endian bytes in standard RFC 4648 Base64.
#[must_use]
pub fn encode_pcm16_le_b64(samples: &[i16]) -> String {
    let mut bytes = Vec::with_capacity(samples.len() * 2);
    for &sample in samples {
        bytes.extend_from_slice(&sample.to_le_bytes());
    }
    encode_base64(&bytes)
}

/// Decodes standard RFC 4648 Base64 little-endian bytes back into signed 16-bit PCM samples.
#[must_use]
pub fn decode_pcm16_le_b64(encoded: &str) -> Option<Vec<i16>> {
    let bytes = decode_base64(encoded)?;
    if !bytes.len().is_multiple_of(2) {
        return None;
    }
    Some(
        bytes
            .as_chunks::<2>()
            .0
            .iter()
            .copied()
            .map(i16::from_le_bytes)
            .collect(),
    )
}

const B64_ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encode_base64(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0];
        let b1 = *chunk.get(1).unwrap_or(&0);
        let b2 = *chunk.get(2).unwrap_or(&0);
        let triple = (u32::from(b0) << 16) | (u32::from(b1) << 8) | u32::from(b2);
        out.push(B64_ALPHABET[((triple >> 18) & 0x3F) as usize] as char);
        out.push(B64_ALPHABET[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(B64_ALPHABET[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(B64_ALPHABET[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

fn decode_b64_sextet(byte: u8) -> Option<u8> {
    match byte {
        b'A'..=b'Z' => Some(byte - b'A'),
        b'a'..=b'z' => Some(byte - b'a' + 26),
        b'0'..=b'9' => Some(byte - b'0' + 52),
        b'+' => Some(62),
        b'/' => Some(63),
        _ => None,
    }
}

fn decode_base64(encoded: &str) -> Option<Vec<u8>> {
    let trimmed = encoded.trim();
    if trimmed.is_empty() {
        return Some(Vec::new());
    }
    let raw = trimmed.as_bytes();
    let (quads, rem) = raw.as_chunks::<4>();
    if !rem.is_empty() {
        return None;
    }
    let mut out = Vec::with_capacity(quads.len() * 3);
    for (quad_idx, quad) in quads.iter().enumerate() {
        let is_last = quad_idx + 1 == quads.len();
        let s0 = decode_b64_sextet(quad[0])?;
        let s1 = decode_b64_sextet(quad[1])?;
        match (quad[2], quad[3]) {
            (b'=', b'=') if is_last => {
                out.push((s0 << 2) | (s1 >> 4));
            }
            (c2, b'=') if is_last && c2 != b'=' => {
                let s2 = decode_b64_sextet(c2)?;
                out.push((s0 << 2) | (s1 >> 4));
                out.push((s1 << 4) | (s2 >> 2));
            }
            (c2, c3) if c2 != b'=' && c3 != b'=' => {
                let s2 = decode_b64_sextet(c2)?;
                let s3 = decode_b64_sextet(c3)?;
                out.push((s0 << 2) | (s1 >> 4));
                out.push((s1 << 4) | (s2 >> 2));
                out.push((s2 << 6) | s3);
            }
            _ => return None,
        }
    }
    Some(out)
}

fn generate_uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    if File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .is_err()
    {
        static FALLBACK: AtomicU64 = AtomicU64::new(1);
        let hi = FALLBACK.fetch_add(1, Ordering::Relaxed);
        let lo = std::process::id() as u64 ^ 0x9E37_79B9_7F4A_7C15u64.wrapping_mul(hi);
        bytes[..8].copy_from_slice(&hi.to_le_bytes());
        bytes[8..].copy_from_slice(&lo.to_le_bytes());
    }
    bytes[6] = (bytes[6] & 0x0F) | 0x40;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    format!(
        "{:02x}{:02x}{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}-{:02x}{:02x}{:02x}{:02x}{:02x}{:02x}",
        bytes[0],
        bytes[1],
        bytes[2],
        bytes[3],
        bytes[4],
        bytes[5],
        bytes[6],
        bytes[7],
        bytes[8],
        bytes[9],
        bytes[10],
        bytes[11],
        bytes[12],
        bytes[13],
        bytes[14],
        bytes[15]
    )
}
