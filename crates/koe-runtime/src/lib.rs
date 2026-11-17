//! A single durable product workspace shared by the native host and CLI.
#![forbid(unsafe_code)]
#![deny(missing_docs)]

mod all_day;
#[cfg(test)]
mod ask_tests;
mod audio_policy;
mod bridge_path;
#[cfg(test)]
mod audio_policy_tests;
mod capture;
mod capture_studio;
#[cfg(test)]
mod capture_tests;
mod command;
mod dispatch;
#[cfg(test)]
mod mcp_device_tests;
pub mod credentials;
mod device;
mod device_custody;
mod capture_flow;
mod legacy;
mod lifecycle;
#[cfg(test)]
mod lifecycle_tests;
mod live_minutes;
mod local_asr;
/// Centralized 16-tool MCP registry and step/poll dispatcher shared by native host and CLI.
pub mod mcp_surface;
mod microphone;
mod mode_workspaces;
mod mode_workspaces_all_day;
mod mode_workspaces_live_minutes;
#[cfg(test)]
mod navigation_tests;
mod playback;
mod processing;
mod projection;
mod provider_settings;
mod selection;
mod speech;
use provider_settings::ProviderSettings;
mod transcript_edit;
mod trash;

use command::{DispatchMessage, HostIntent, Location, Page};
pub use bridge_path::resolve_bridge_socket_path;
#[cfg(test)]
pub(crate) use bridge_path::resolve_bridge_socket_path_with_env;
use device::DeviceRuntime;
use koe_client_providers::{ProviderLane, ProviderPool};
use koe_client_services::{product_store::ProductStore, recording_assets};
use koe_engine::{domain::SegmentId, product::*};
pub(crate) use dispatch::source_ref;
pub use local_asr::LocalAsrEffect;
pub use mcp_surface::{drive_mcp_tool_blocking, McpToolCallState, McpToolError};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

/// Version of the native JSON snapshot and command contract.
pub const KOE_HOST_SNAPSHOT_VERSION: u32 = 2;


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

/// Serialized application session. Network I/O runs on an owned background worker.
pub struct KoeRuntime {
    store: ProductStore,
    root: PathBuf,
    generation: u64,
    selection: selection::WorkspaceSelection,
    device: DeviceRuntime,
    provider: ProviderPool,
    settings: ProviderSettings,
    credentials: Box<dyn credentials::CredentialStore>,
    pending: BTreeMap<u64, PendingWork>,
    completed: std::collections::VecDeque<koe_client_providers::ProviderEvent>,
    captures: capture::Captures,
    local_asr: local_asr::LocalAsr,
    speech: speech::SpeechState,
    all_day: all_day::AllDayState,
    capture_studio: capture_studio::CaptureStudioState,
    microphone: Option<microphone::Microphone>,
    bean_capture_mode: Option<command::CaptureMode>,
    auto_transcribe: std::collections::BTreeSet<String>,
    auto_summarize: std::collections::BTreeSet<String>,
    next_job: u64,
    error: Option<String>,
    notice: Option<String>,
    audio_policy_error: Option<String>,
    quit: lifecycle::QuitState,
    drain_error: Option<String>,
    undo_trash: Option<trash::UndoTrashBanner>,
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
        let existed = root.join("product-workspace.json").exists();
        let store = ProductStore::open(&root).map_err(|e| e.to_string())?;
        let mut runtime = Self {
            store,
            speech: speech::SpeechState::new(&root),
            all_day: Default::default(),
            root,
            generation: 1,
            selection: Default::default(),
            device: DeviceRuntime::default(),
            provider: ProviderPool::new()?,
            settings: ProviderSettings::default(),
            credentials,
            pending: BTreeMap::new(),
            completed: std::collections::VecDeque::new(),
            captures: Default::default(),
            local_asr: Default::default(),
            capture_studio: Default::default(),
            microphone: None,
            bean_capture_mode: None,
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
        if !existed {
            runtime.restore_legacy()?;
        }
        runtime.recover_local_captures()?;
        runtime.reconcile_orphan_audio();
        if let Err(error) = runtime.load_credentials() {
            runtime.error = Some(error);
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
        let result = if json.len() > 2 * 1024 * 1024 {
            Err("操作内容过大".into())
        } else {
            DispatchMessage::parse(json).and_then(|message| {
                let clears_feedback = match &message {
                    DispatchMessage::Intent(_) => true,
                    DispatchMessage::Adapter(event) => event.clears_transient_feedback(),
                };
                if clears_feedback {
                    self.error = None;
                    self.notice = None;
                }
                self.dispatch_message(message, now)
            })
        };
        if let Err(error) = result {
            self.error = Some(error);
        }
        self.generation = self.generation.saturating_add(1);
        self.snapshot_json(now)
    }

    /// Appends a microphone PCM16 chunk without JSON command serialization or full snapshot projection.
    #[allow(clippy::too_many_arguments)]
    pub fn ingest_microphone_pcm(
        &mut self,
        record_id: &str,
        session_id: &str,
        lane: &str,
        sequence: u64,
        samples: &[i16],
        timing: Option<(u64, u64)>,
        now: u64,
    ) -> PcmIngestReceipt {
        self.error = None;
        self.notice = None;
        if now > 0 {
            self.last_now_sec = now;
        }
        if !self.is_quitting() {
            self.reconcile_expired_trash(now);
        }
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
                self.reconcile_all_day();
                self.reconcile_bean_capture_mode();
            }
            Err(ref error) => {
                self.error = Some(error.clone());
            }
        }
        self.generation = self.generation.saturating_add(1);
        let Some((next_sequence, has_lane_error)) = self
            .microphone
            .as_ref()
            .and_then(|m| m.lane_receipt_state(record_id, session_id, lane))
        else {
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
        if now > 0 {
            self.last_now_sec = now;
        }
        let rev_before = self.workspace().revision();
        let trash_reconciled = if !self.is_quitting() {
            self.reconcile_expired_trash(now)
        } else {
            false
        };
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
        let all_day_stopping_before = self.all_day.run.as_ref().map(|r| r.stopping);
        let bean_mode_before = self.bean_capture_mode;
        let all_day_done = self.reconcile_all_day();
        self.reconcile_bean_capture_mode();
        let post_hook_changed = all_day_done
            || self.all_day.run.as_ref().map(|r| r.stopping) != all_day_stopping_before
            || self.bean_capture_mode != bean_mode_before;
        let clock_dirty = last_projected_now_sec == 0
            || eff_now == 0
            || today.is_none()
            || today != prev_day
            || trash_reconciled
            || trash_countdown_dirty
            || self.workspace().revision() != rev_before
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
                self.settings.key.clear();
                self.settings.unavailable = true;
            }
            e.to_string()
        })
    }


    pub(crate) fn release_to_phone_block_reason(&self) -> Option<&'static str> {
        use koe_engine::session::TransferPhaseTag;
        if self.is_quitting() || self.store.requires_reopen() {
            return Some("当前状态暂不可释放录音豆蓝牙控制权");
        }
        if matches!(
            self.device.session.transfer.phase,
            TransferPhaseTag::PullingOffline
        ) || self.device.session.is_offline_pull_suspended()
        {
            return Some("正在从录音豆拉取离线录音，请等待完成后再切回手机");
        }
        if self.is_bean_meeting_recording()
            || self.device.session.device_recording_active
            || self.bean_capture_mode.is_some()
            || self
                .all_day
                .run
                .as_ref()
                .is_some_and(|run| run.source == "bean")
            || self.device.session.pending_realtime_subscribe
        {
            return Some("录音豆正在录音，请先停止当前录音再切回手机");
        }
        None
    }

    pub(crate) fn can_release_to_phone(&self) -> bool {
        self.release_to_phone_block_reason().is_none()
    }

    fn reset_bean_preference_if_needed(&mut self) {
        if self.capture_studio.preference == capture_studio::CaptureSourcePreference::Bean {
            self.capture_studio.preference = capture_studio::CaptureSourcePreference::Auto;
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

    /// Feeds real platform notifications into the existing protocol engine.
    pub fn ingest_ble_chunk(&mut self, bytes: &[u8], now: u64) {
        let day_changed = self.advance_clock(now);
        let lifecycle = self.lifecycle_json();
        let revision = self.workspace().revision();
        let error = self.error.clone();
        let mut changed = self.device.ingest(bytes, now);
        if let Err(error) = self.save_captures(now) {
            self.error = Some(error);
        }
        changed |= self.maybe_start_auto_offline_pull();
        self.reconcile_bean_capture_mode();
        let all_day_finished = self.reconcile_all_day();
        if changed
            || day_changed
            || all_day_finished
            || revision != self.workspace().revision()
            || error != self.error
            || lifecycle != self.lifecycle_json()
        {
            self.generation = self.generation.saturating_add(1);
        }
    }
    /// Advances protocol deadlines and consumes completed provider work.
    pub fn poll_timers(&mut self, elapsed_ms: u64, now: u64) {
        let day_changed = self.advance_clock(now);
        let lifecycle = self.lifecycle_json();
        let revision = self.workspace().revision();
        let error = self.error.clone();
        self.drain_error = None;
        let undo_expired = self.tick_undo_trash(elapsed_ms);
        let trash_expired = self.reconcile_expired_trash(now);
        let changed = match self.device.tick(elapsed_ms.min(60_000), now) {
            Ok(changed) => changed,
            Err(error) => {
                self.error = Some(error);
                true
            }
        };
        if let Err(error) = self.save_captures(now) {
            self.error = Some(error);
        }
        self.tick_local_asr(elapsed_ms);
        let mut completed = self.poll_offline_speech()
            | self.drive_speech_files()
            | self.drive_apple_speech()
            | self.poll_provider()
            | self.poll_captures();
        self.drive_analysis_queue();
        self.drive_live_minutes(elapsed_ms);
        let all_day_finished = self.reconcile_all_day();
        completed |= self.maybe_start_auto_offline_pull();
        self.reconcile_bean_capture_mode();
        if changed
            || completed
            || day_changed
            || all_day_finished
            || undo_expired
            || trash_expired
            || revision != self.workspace().revision()
            || error != self.error
            || lifecycle != self.lifecycle_json()
        {
            self.generation = self.generation.saturating_add(1);
        }
    }

    fn advance_clock(&mut self, now: u64) -> bool {
        if now == 0 {
            return false;
        }
        let before = std::mem::replace(&mut self.last_now_sec, now);
        before > 0 && projection::local_date(before) != projection::local_date(now)
    }

    pub(crate) fn ensure_device_idle(&self) -> Result<(), String> {
        use koe_engine::session::TransferPhaseTag;
        if self.device.awaiting_stop
            || matches!(
                self.device.session.transfer.phase,
                TransferPhaseTag::PullingOffline | TransferPhaseTag::StreamingRealtime
            )
            || self.device.session.is_offline_pull_suspended()
            || self.device.session.device_recording_active
        {
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
            "generation": self.generation,
            "device": self.device_json(),
            "provider": self.provider_json(),
            "error": self.error
        })
    }
}
