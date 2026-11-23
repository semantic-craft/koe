//! A single durable product workspace shared by the native host and CLI.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod capture;
mod command;
mod device;
mod dispatch;
/// Centralized 16-tool MCP registry and step/poll dispatcher shared by native host and CLI.
pub mod mcp_surface;
mod observability;
mod processing;
mod projection;
mod speech;
#[cfg(test)]
mod tests;
mod workspace;

use command::{DispatchMessage, Location, Page};
pub(crate) use dispatch::source_ref;
pub use mcp_surface::{drive_mcp_tool_blocking, McpToolCallState, McpToolError};
pub use observability::bridge_path::resolve_bridge_socket_path;
#[cfg(test)]
pub(crate) use observability::bridge_path::resolve_bridge_socket_path_with_env;
/// Secure platform I/O; credential values never enter product snapshots.
pub use processing::credentials;
pub use speech::local_asr::LocalAsrEffect;

use device::DeviceRuntime;
use koe_client_providers::{ProviderLane, ProviderPool};
use koe_client_services::{product_store::ProductStore, recording_assets};
use koe_engine::{domain::SegmentId, product::*};
use processing::provider_settings::ProviderSettings;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Version of the native JSON snapshot and command contract.
pub const KOE_HOST_SNAPSHOT_VERSION: u32 = 2;
/// Maximum accepted byte length of a native JSON command payload.
pub const MAX_COMMAND_JSON_BYTES: usize = 2 * 1024 * 1024;


/// Borrowed native microphone or system audio PCM16 chunk ingested into [`KoeRuntime`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MicrophonePcmChunk<'a> {
    /// Active recording identifier.
    pub record_id: &'a str,
    /// Active capture session identifier.
    pub session_id: &'a str,
    /// Audio lane name (`"microphone"` or `"system"`).
    pub lane: &'a str,
    /// Monotonic per-lane chunk sequence number.
    pub sequence: u64,
    /// Mono 16-bit PCM sample slice.
    pub samples: &'a [i16],
    /// Optional `(epoch, captured_start_ns)` capture clock timestamp.
    pub timing: Option<(u64, u64)>,
    /// Wall-clock timestamp in Unix epoch seconds.
    pub now: u64,
}

/// Outcome of attempting to ingest a native microphone PCM chunk.
#[repr(u32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PcmIngestStatus {
    /// Chunk was accepted and lane sequence advanced by one.
    Accepted = 0,
    /// No active microphone session or lane matches the caller's identity.
    StaleSession = 1,
    /// Session matched, but the chunk was rejected or failed to persist.
    Rejected = 2,
}

/// Summary receipt returned by [`KoeRuntime::ingest_microphone_pcm`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PcmIngestReceipt {
    /// Resulting runtime view generation after processing the chunk.
    pub generation: u64,
    /// Current expected sequence number for the addressed lane (`0` when stale).
    pub next_sequence: u64,
    /// Acceptance classification for the chunk.
    pub status: PcmIngestStatus,
}

/// Summary receipt returned by [`KoeRuntime::report_playback_progress`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlaybackProgressReceipt {
    /// Resulting runtime view generation.
    pub generation: u64,
    /// Runtime view generation immediately prior to this progress report.
    pub prev_generation: u64,
    /// Clamped playback position in milliseconds (`0` when unmatched).
    pub position_ms: u64,
    /// Effective wall-clock timestamp in epoch seconds resolved for this receipt.
    pub now_epoch_sec: u64,
    /// Resulting playing state (`false` when unmatched).
    pub is_playing: bool,
    /// Whether active playback state was applied.
    pub applied: bool,
    /// Whether day rollover, trash retention, or session reconciliation requires a full snapshot.
    pub needs_full_snapshot: bool,
}

#[derive(Clone)]
enum PendingWork {
    Transcription(RequestKey),
    Summary(RequestKey),
    LiveSummary {
        key: RequestKey,
        sources: koe_engine::domain::UtteranceSpine,
    },
    Ask(u64),
}

impl PendingWork {
    const fn lane(&self) -> ProviderLane {
        match self {
            Self::Transcription(_) => ProviderLane::Audio,
            Self::Summary(_) | Self::LiveSummary { .. } => ProviderLane::Summary,
            Self::Ask(_) => ProviderLane::Ask,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum RuntimeError {
    External(String),
    Ingest(String),
}

impl RuntimeError {
    pub(crate) fn as_str(&self) -> &str {
        match self {
            Self::External(message) | Self::Ingest(message) => message.as_str(),
        }
    }

    pub(crate) const fn is_ingest(&self) -> bool {
        matches!(self, Self::Ingest(_))
    }
}

pub(crate) struct RuntimeStepEntry {
    day_changed: bool,
    trash_reconciled: bool,
    revision: u64,
    error: Option<RuntimeError>,
    lifecycle: observability::lifecycle::LifecycleState,
    capture_state: (u8, bool, Option<capture::SingleShotMode>),
}

/// Serialized application session. Network I/O runs on an owned background worker.
pub struct KoeRuntime {
    store: ProductStore,
    root: PathBuf,
    generation: u64,
    selection: workspace::selection::WorkspaceSelection,
    device: DeviceRuntime,
    provider: ProviderPool,
    platform: workspace::platform::HostPlatformProfile,
    app_update: processing::app_update::AppUpdateState,
    settings: ProviderSettings,
    credentials: Box<dyn credentials::CredentialStore>,
    pending: BTreeMap<u64, PendingWork>,
    completed: std::collections::VecDeque<koe_client_providers::ProviderEvent>,
    captures: capture::Captures,
    local_asr: speech::local_asr::LocalAsr,
    speech: speech::SpeechState,
    capture_studio: capture::studio::CaptureStudioState,
    active_capture: capture::ActiveCaptureSession,
    auto_transcribe: std::collections::BTreeSet<String>,
    auto_summarize: std::collections::BTreeSet<String>,
    next_job: u64,
    error: Option<RuntimeError>,
    notice: Option<String>,
    audio_policy_error: Option<String>,
    quit: observability::lifecycle::QuitState,
    drain_error: Option<String>,
    undo_trash: Option<workspace::trash::UndoTrashBanner>,
    last_now_sec: u64,
}

impl KoeRuntime {
    /// Opens durable state, rejecting corrupted storage and concurrent writers.
    pub fn open(path: impl AsRef<Path>) -> Result<Self, String> {
        Self::open_with_credentials(path, Box::<credentials::IsolatedCredentials>::default())
    }

    /// Opens with a platform secure storage adapter.
    pub fn open_with_credentials(
        path: impl AsRef<Path>,
        credentials: Box<dyn credentials::CredentialStore>,
    ) -> Result<Self, String> {
        let root = path.as_ref().to_path_buf();
        let store = ProductStore::open(&root).map_err(|e| e.to_string())?;
        let mut runtime = Self {
            store,
            speech: speech::SpeechState::new(&root),
            root,
            generation: 1,
            selection: Default::default(),
            device: DeviceRuntime::default(),
            provider: ProviderPool::new()?,
            platform: workspace::platform::HostPlatformProfile::default(),
            app_update: Default::default(),
            settings: ProviderSettings::default(),
            credentials,
            pending: BTreeMap::new(),
            completed: std::collections::VecDeque::new(),
            captures: Default::default(),
            local_asr: Default::default(),
            capture_studio: Default::default(),
            active_capture: capture::ActiveCaptureSession::Idle,
            auto_transcribe: Default::default(),
            auto_summarize: Default::default(),
            next_job: 1,
            error: None,
            notice: None,
            audio_policy_error: None,
            quit: Default::default(),
            drain_error: None,
            undo_trash: None,
            last_now_sec: 0,
        };
        runtime.recover_local_captures()?;
        runtime.reconcile_orphan_audio();
        runtime.refresh_audio_storage_summary();
        if let Err(error) = runtime.load_credentials() {
            runtime.set_error(error);
        }
        if let SpeechEngine::Downloaded(id) = runtime
            .workspace()
            .provider_configuration()
            .speech_engine
            .clone()
        {
            let _ = runtime.prepare_speech_model(&id);
        }
        Ok(runtime)
    }

    pub(crate) fn error_str(&self) -> Option<&str> {
        self.error.as_ref().map(RuntimeError::as_str)
    }

    pub(crate) fn set_error(&mut self, error: impl Into<String>) {
        self.error = Some(RuntimeError::External(error.into()));
    }

    pub(crate) fn set_ingest_error(&mut self, error: impl Into<String>) {
        self.error = Some(RuntimeError::Ingest(error.into()));
    }

    pub(crate) fn clear_error(&mut self) {
        self.error = None;
    }

    pub(crate) fn clear_ingest_error(&mut self) {
        if self.error.as_ref().is_some_and(RuntimeError::is_ingest) {
            self.error = None;
        }
    }

    /// Immutable facts for trusted query callers.
    pub fn workspace(&self) -> &ProductWorkspace {
        self.store.workspace()
    }
    /// UI change generation, independent of wall-clock time.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Applies a native command and returns a projection including any operation failure.
    pub fn dispatch_json(&mut self, json: &str, now: u64) -> String {
        let result = if json.len() > MAX_COMMAND_JSON_BYTES {
            Err("操作内容过大".into())
        } else {
            DispatchMessage::parse(json).and_then(|message| {
                let clears_feedback = match &message {
                    DispatchMessage::Intent(_) => true,
                    DispatchMessage::Adapter(event) => event.clears_transient_feedback(),
                };
                if clears_feedback {
                    self.clear_error();
                    self.notice = None;
                }
                self.dispatch_message(message, now)
            })
        };
        if let Err(error) = result {
            self.set_error(error);
        }
        self.generation = self.generation.saturating_add(1);
        self.snapshot_json(now)
    }

    /// Appends a microphone PCM16 chunk without JSON command serialization or full snapshot projection.
    pub fn ingest_microphone_pcm(&mut self, chunk: MicrophonePcmChunk<'_>) -> PcmIngestReceipt {
        let MicrophonePcmChunk {
            record_id,
            session_id,
            lane,
            sequence,
            samples,
            timing,
            now,
        } = chunk;
        let _ = self.enter_runtime_step(now);
        let capture_timing = timing.map(|(epoch, captured_start_ns)| command::CaptureTiming {
            epoch,
            captured_start_ns,
        });
        let result = self.microphone_chunk(
            (record_id, session_id, lane),
            sequence,
            samples,
            capture_timing,
        );
        match result {
            Ok(()) => {
                self.reconcile_capture_session();
            }
            Err(ref error) => {
                self.set_ingest_error(error.clone());
            }
        }
        self.generation = self.generation.saturating_add(1);
        let Some((next_sequence, has_lane_error)) = self
            .active_capture
            .microphone()
            .and_then(|m| m.lane_receipt_state(record_id, session_id, lane))
        else {
            if result.is_ok() {
                self.clear_ingest_error();
            }
            return PcmIngestReceipt {
                generation: self.generation,
                next_sequence: 0,
                status: PcmIngestStatus::StaleSession,
            };
        };
        let status = if result.is_ok()
            && sequence.checked_add(1) == Some(next_sequence)
            && !has_lane_error
        {
            self.clear_ingest_error();
            PcmIngestStatus::Accepted
        } else {
            PcmIngestStatus::Rejected
        };
        PcmIngestReceipt {
            generation: self.generation,
            next_sequence,
            status,
        }
    }

    /// Updates native playhead progress, eliding generation bumps when unchanged and clock state is clean.
    pub fn report_playback_progress(
        &mut self,
        record_id: &str,
        request_id: u64,
        position_ms: u64,
        is_playing: bool,
        last_projected_now_sec: u64,
        now: u64,
    ) -> PlaybackProgressReceipt {
        let prev_generation = self.generation;
        let entry = self.enter_runtime_step(now);
        let eff_now = if now > 0 { now } else { self.last_now_sec };
        let today = projection::local_date(eff_now);
        let prev_day = if last_projected_now_sec > 0 {
            projection::local_date(last_projected_now_sec)
        } else {
            None
        };
        let trash_countdown_dirty = self.workspace().records().values().any(|r| {
            r.is_trashed()
                && (last_projected_now_sec == 0
                    || projection::trash_remaining_days(r, eff_now)
                        != projection::trash_remaining_days(r, last_projected_now_sec))
        });
        let session_reconciled = self.reconcile_capture_session();
        let post_hook_changed =
            session_reconciled || self.active_capture.state_fingerprint() != entry.capture_state;
        let clock_dirty = last_projected_now_sec == 0
            || eff_now == 0
            || today.is_none()
            || today != prev_day
            || entry.trash_reconciled
            || trash_countdown_dirty
            || self.workspace().revision() != entry.revision
            || post_hook_changed;

        let Some(clamped_pos) = self.clamped_playback_position(record_id, request_id, position_ms)
        else {
            if !clock_dirty {
                return PlaybackProgressReceipt {
                    generation: prev_generation,
                    prev_generation,
                    position_ms: 0,
                    now_epoch_sec: eff_now,
                    is_playing: false,
                    applied: false,
                    needs_full_snapshot: false,
                };
            }
            self.generation = self.generation.saturating_add(1);
            return PlaybackProgressReceipt {
                generation: self.generation,
                prev_generation,
                position_ms: 0,
                now_epoch_sec: eff_now,
                is_playing: false,
                applied: false,
                needs_full_snapshot: true,
            };
        };

        if (clamped_pos, is_playing)
            == (
                self.selection.playback.position_ms,
                self.selection.playback.playing,
            )
            && !clock_dirty
        {
            return PlaybackProgressReceipt {
                generation: prev_generation,
                prev_generation,
                position_ms: clamped_pos,
                now_epoch_sec: eff_now,
                is_playing,
                applied: false,
                needs_full_snapshot: false,
            };
        }

        self.selection.playback.position_ms = clamped_pos;
        self.selection.playback.playing = is_playing;
        self.generation = self.generation.saturating_add(1);
        PlaybackProgressReceipt {
            generation: self.generation,
            prev_generation,
            position_ms: clamped_pos,
            now_epoch_sec: eff_now,
            is_playing,
            applied: true,
            needs_full_snapshot: clock_dirty,
        }
    }

    fn commit<T>(
        &mut self,
        change: impl FnOnce(&mut ProductWorkspace) -> Result<T, ProductError>,
    ) -> Result<T, String> {
        self.store.transact(change).map_err(|e| {
            if matches!(
                e,
                koe_client_services::product_store::StoreError::CommitUncertain(_)
                    | koe_client_services::product_store::StoreError::Unavailable
            ) {
                self.settings.mark_all_reopen_required();
            }
            e.to_string()
        })
    }


    pub(crate) fn release_to_phone_block_reason(&self) -> Option<&'static str> {
        use koe_engine::session::TransferPhaseTag;
        let is_macos = self.platform.kind == workspace::platform::HostPlatformKind::Macos;
        if self.is_quitting() || self.store.requires_reopen() {
            return Some("当前状态暂不可释放录音豆蓝牙控制权");
        }
        if matches!(
            self.device.session.transfer.phase,
            TransferPhaseTag::PullingOffline
        ) || self.device.session.is_offline_pull_suspended()
        {
            return Some(if is_macos {
                "正在从录音豆拉取离线录音，请等待完成后再切回手机"
            } else {
                "正在从录音豆拉取离线录音，请等待完成后再释放蓝牙控制"
            });
        }
        if self.is_bean_meeting_recording()
            || self.device.session.device_recording_active
            || self.active_capture.bean_single_shot_mode().is_some()
            || self.active_capture.all_day_is_bean()
            || self.device.session.pending_realtime_subscribe
        {
            return Some(if is_macos {
                "录音豆正在录音，请先停止当前录音再切回手机"
            } else {
                "录音豆正在录音，请先停止当前录音再释放蓝牙控制"
            });
        }
        None
    }

    pub(crate) fn can_release_to_phone(&self) -> bool {
        self.release_to_phone_block_reason().is_none()
    }

    fn reset_bean_preference_if_needed(&mut self) {
        if self.capture_studio.preference == capture::studio::CaptureSourcePreference::Bean {
            self.capture_studio.preference = capture::studio::CaptureSourcePreference::Auto;
        }
    }

    fn disconnect_device_session(&mut self, now: u64) -> Result<(), String> {
        self.device.disconnect();
        self.save_captures(now)?;
        Ok(())
    }

    fn go(&mut self, location: Location) {
        self.selection.go(location);
    }

    fn open_record(&mut self, id: &str, segment: Option<String>) -> Result<(), String> {
        let record = self.workspace().record(id).ok_or("记录不存在")?;
        record.ensure_live().map_err(|e| e.to_string())?;
        self.go(Location {
            page: Page::Detail,
            record: Some(id.into()),
            segment,
        });
        Ok(())
    }

    pub(crate) fn create_quick_note(
        &mut self,
        title: String,
        text: &str,
        select_in_ui: bool,
        now: u64,
    ) -> Result<String, String> {
        if text.trim().is_empty() {
            return Err("先写下一段内容".into());
        }
        let id = format!("note-{now}-{}", self.workspace().revision() + 1);
        self.commit(|workspace| {
            workspace.insert_record(id.clone(), title, RecordOrigin::Note, 0, now, 0)?;
            for paragraph in text.lines().map(str::trim).filter(|v| !v.is_empty()) {
                workspace.append_transcript(&id, paragraph, 0, 0, "manual")?;
            }
            Ok(())
        })?;
        if select_in_ui {
            self.selection.selected_quick_note_record = Some(id.clone());
        }
        self.notice = Some("记录已保存".into());
        Ok(id)
    }

    pub(crate) fn accept_segment_item(
        &mut self,
        kind: ItemKind,
        record_id: &str,
        segment_id: &str,
    ) -> Result<String, String> {
        let source = source_ref(record_id, segment_id)?;
        let item_id = self.commit(|w| {
            let evidence = w.resolve_live_source(&source)?;
            let id = w.propose_item(kind, &evidence.quote, vec![source])?;
            w.review_item(&id, ReviewDecision::Accept)?;
            Ok(id)
        })?;
        self.notice = Some("已保存，可从来源返回原文".into());
        Ok(item_id)
    }

    pub(crate) fn highlight_segment(
        &mut self,
        record_id: &str,
        segment_id: &str,
    ) -> Result<(), String> {
        let source = source_ref(record_id, segment_id)?;
        self.commit(|w| w.add_highlight(source))
    }

    pub(crate) fn enter_runtime_step(&mut self, now: u64) -> RuntimeStepEntry {
        let day_changed = self.advance_clock(now);
        let lifecycle = self.lifecycle_state();
        let revision = self.workspace().revision();
        let error = self.error.clone();
        let capture_state = self.active_capture.state_fingerprint();
        let trash_reconciled = if !self.is_quitting() {
            self.reconcile_expired_trash(now)
        } else {
            false
        };
        RuntimeStepEntry {
            day_changed,
            trash_reconciled,
            revision,
            error,
            lifecycle,
            capture_state,
        }
    }

    pub(crate) fn finish_runtime_step(
        &mut self,
        entry: RuntimeStepEntry,
        extra_changed: bool,
    ) -> bool {
        let session_reconciled = self.reconcile_capture_session();
        let changed = extra_changed
            || entry.day_changed
            || entry.trash_reconciled
            || session_reconciled
            || entry.capture_state != self.active_capture.state_fingerprint()
            || entry.revision != self.workspace().revision()
            || entry.error != self.error
            || entry.lifecycle != self.lifecycle_state();
        if changed {
            self.generation = self.generation.saturating_add(1);
        }
        changed
    }

    /// Feeds real platform notifications into the existing protocol engine.
    pub fn ingest_ble_chunk(&mut self, bytes: &[u8], now: u64) {
        let entry = self.enter_runtime_step(now);
        let mut changed = self.device.ingest(bytes, now);
        if let Err(error) = self.save_captures(now) {
            self.set_error(error);
        }
        changed |= self.maybe_start_auto_offline_pull();
        self.finish_runtime_step(entry, changed);
    }
    /// Advances protocol deadlines and consumes completed provider work.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now: u64) {
        let entry = self.enter_runtime_step(now);
        self.drain_error = None;
        let undo_expired = self.tick_undo_trash(elapsed_ms);
        let changed = match self.device.tick(elapsed_ms.min(60_000), now) {
            Ok(changed) => changed,
            Err(error) => {
                self.set_error(error);
                true
            }
        };
        if let Err(error) = self.save_captures(now) {
            self.set_error(error);
        }
        self.tick_local_asr(elapsed_ms);
        let mut completed = self.poll_offline_speech()
            | self.drive_speech_files()
            | self.drive_apple_speech()
            | self.poll_provider()
            | self.poll_captures();
        self.drive_analysis_queue();
        self.drive_live_minutes(elapsed_ms);
        completed |= self.maybe_start_auto_offline_pull();
        self.finish_runtime_step(entry, changed || completed || undo_expired);
    }

    fn advance_clock(&mut self, now: u64) -> bool {
        if now == 0 {
            return false;
        }
        let before = std::mem::replace(&mut self.last_now_sec, now);
        before > 0 && projection::local_date(before) != projection::local_date(now)
    }

    pub(crate) fn is_device_busy(&self) -> bool {
        use koe_engine::session::TransferPhaseTag;
        self.device.awaiting_stop
            || self.device.session.device_recording_active
            || matches!(
                self.device.session.transfer.phase,
                TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
            )
            || self.device.session.is_offline_pull_suspended()
    }

    pub(crate) fn ensure_device_idle(&self) -> Result<(), String> {
        if self.is_device_busy() {
            Err("请等待当前录音取回或录制结束".into())
        } else {
            Ok(())
        }
    }
    /// Transfers queued protocol frames to the native transport adapter.
    pub fn drain_outbound_ble_frames(&mut self) -> Vec<Vec<u8>> {
        std::mem::take(&mut self.device.outbound)
    }
    /// Serializes an immutable projection without changing domain state.
    pub fn snapshot_json(&self, now: u64) -> String {
        self.snapshot(now).to_string()
    }
    /// Structured read-only projection for native and CLI clients.
    pub fn snapshot(&self, now: u64) -> Value {
        self.project(now)
    }
    /// Advances timers and returns the diagnostic projection shared by CLI and local bridge.
    pub fn doctor_snapshot(&mut self, now: u64) -> Value {
        self.poll_timers(0, now);
        json!({
            "workspaceReadable": true,
            "version": self.app_update.current_version.to_string(),
            "build": self.app_update.current_build,
            "generation": self.generation,
            "appUpdate": self.app_update_json(),
            "device": self.device_json(),
            "provider": self.provider_json(),
            "error": self.error_str()
        })
    }
}
