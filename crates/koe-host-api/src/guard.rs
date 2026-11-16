use crate::{
    KoePcmReceipt, KoePlaybackReceipt, koe_host_session_create, koe_host_session_destroy,
    koe_host_session_dispatch_json, koe_host_session_ingest_ble, koe_host_session_ingest_pcm,
    koe_host_session_poll_timers, koe_host_session_report_playback_progress,
    koe_host_session_snapshot_json, local_bridge,
};
use koe_runtime::KoeRuntime;
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString, c_char},
    path::Path,
    sync::{Mutex, MutexGuard, OnceLock, PoisonError},
    time::{SystemTime, UNIX_EPOCH},
};

pub(crate) fn now(value: u64) -> u64 {
    if value > 0 {
        value
    } else {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs())
    }
}

pub(crate) fn guarded<T: Default>(operation: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(operation)).unwrap_or_default()
}

pub(crate) fn string(value: String) -> *mut c_char {
    CString::new(value).map_or(std::ptr::null_mut(), CString::into_raw)
}

pub(crate) unsafe fn read_string(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        None
    } else {
        unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .ok()
            .map(str::to_string)
    }
}

pub(crate) struct SessionEntry {
    pub(crate) runtime: KoeRuntime,
    pub(crate) subscribers: local_bridge::SubscriberHub,
}

#[derive(Default)]
pub(crate) struct Sessions {
    next: u64,
    pub(crate) entries: BTreeMap<u64, SessionEntry>,
    pub(crate) bridges: BTreeMap<u64, local_bridge::BridgeServer>,
}

pub(crate) fn sessions() -> &'static Mutex<Sessions> {
    static SESSIONS: OnceLock<Mutex<Sessions>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(Sessions::default()))
}

pub(crate) fn lock_sessions() -> MutexGuard<'static, Sessions> {
    sessions().lock().unwrap_or_else(PoisonError::into_inner)
}

pub(crate) fn with_session_broadcast<R>(
    handle: u64,
    op: impl FnOnce(&mut KoeRuntime) -> R,
) -> Option<R> {
    let (result, hub, events) = {
        let mut table = lock_sessions();
        let entry = table.entries.get_mut(&handle)?;
        let result = op(&mut entry.runtime);
        let events = entry.runtime.drain_companion_events();
        (result, entry.subscribers.clone(), events)
    };
    hub.broadcast(&events);
    Some(result)
}

pub(crate) fn register_session(workspace: &Path, runtime: KoeRuntime) -> u64 {
    let subscribers = local_bridge::SubscriberHub::default();
    let handle = {
        let mut table = lock_sessions();
        table.next = table.next.saturating_add(1);
        let id = table.next;
        table.entries.insert(
            id,
            SessionEntry {
                runtime,
                subscribers: subscribers.clone(),
            },
        );
        id
    };
    if let Some(bridge) = local_bridge::BridgeServer::start(handle, workspace, subscribers) {
        let mut orphan_bridge = Some(bridge);
        let mut table = lock_sessions();
        if table.entries.contains_key(&handle) {
            if let Some(active) = orphan_bridge.take() {
                table.bridges.insert(handle, active);
            }
        }
        drop(table);
        drop(orphan_bridge);
    }
    handle
}

unsafe fn take_owned_string(pointer: *mut c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    let owned = unsafe { CString::from_raw(pointer) };
    owned.into_string().ok()
}

/// Safe RAII wrapper around an active host session handle and its local Unix socket bridge.
pub struct HostSessionGuard(u64);

impl HostSessionGuard {
    /// Opens an isolated host session with its local socket bridge at `path`.
    #[must_use]
    pub fn open(path: &Path) -> Option<Self> {
        let text = path.to_str()?;
        let c_path = CString::new(text).ok()?;
        let handle = unsafe { koe_host_session_create(c_path.as_ptr()) };
        (handle != 0).then_some(Self(handle))
    }

    /// Returns the underlying 1-based session handle.
    #[must_use]
    pub fn handle(&self) -> u64 {
        self.0
    }

    /// Captures an immutable JSON projection of the session at `now`.
    #[must_use]
    pub fn snapshot_json(&self, now: u64) -> Option<String> {
        unsafe { take_owned_string(koe_host_session_snapshot_json(self.0, now)) }
    }

    /// Dispatches a JSON command into the session and returns the updated snapshot JSON.
    #[must_use]
    pub fn dispatch_json(&self, command_json: &str, now: u64) -> Option<String> {
        let c_cmd = CString::new(command_json).ok()?;
        unsafe { take_owned_string(koe_host_session_dispatch_json(self.0, c_cmd.as_ptr(), now)) }
    }

    /// Feeds raw BLE notification bytes into the session and returns the resulting generation.
    #[must_use]
    pub fn ingest_ble(&self, bytes: &[u8], now: u64) -> u64 {
        let ptr = if bytes.is_empty() {
            std::ptr::null()
        } else {
            bytes.as_ptr()
        };
        unsafe { koe_host_session_ingest_ble(self.0, ptr, bytes.len(), now) }
    }

    /// Feeds one PCM16 microphone/system audio chunk through the fast-path C ABI.
    #[must_use]
    #[allow(clippy::too_many_arguments)]
    pub fn ingest_pcm(
        &self,
        record_id: &str,
        session_id: &str,
        lane: &str,
        sequence: u64,
        timing: Option<(u64, u64)>,
        samples: &[i16],
        now: u64,
    ) -> KoePcmReceipt {
        let (Ok(c_record), Ok(c_session), Ok(c_lane)) = (
            CString::new(record_id),
            CString::new(session_id),
            CString::new(lane),
        ) else {
            return KoePcmReceipt::default();
        };
        let (epoch, captured_start_ns) = timing.unwrap_or((0, 0));
        let ptr = if samples.is_empty() {
            std::ptr::null()
        } else {
            samples.as_ptr()
        };
        unsafe {
            koe_host_session_ingest_pcm(
                self.0,
                c_record.as_ptr(),
                c_session.as_ptr(),
                c_lane.as_ptr(),
                sequence,
                epoch,
                captured_start_ns,
                timing.is_some(),
                ptr,
                samples.len(),
                now,
            )
        }
    }

    /// Reports native playhead progress through the fast-path C ABI.
    #[must_use]
    pub fn report_playback_progress(
        &self,
        record_id: &str,
        request_id: u64,
        position_ms: u64,
        is_playing: bool,
        last_projected_now_sec: u64,
        now: u64,
    ) -> KoePlaybackReceipt {
        let Ok(c_record) = CString::new(record_id) else {
            return KoePlaybackReceipt::default();
        };
        unsafe {
            koe_host_session_report_playback_progress(
                self.0,
                c_record.as_ptr(),
                request_id,
                position_ms,
                is_playing,
                last_projected_now_sec,
                now,
            )
        }
    }

    /// Advances runtime deadlines and returns the resulting generation.
    #[must_use]
    pub fn poll_timers(&self, elapsed_ms: u64, now: u64) -> u64 {
        koe_host_session_poll_timers(self.0, elapsed_ms, now)
    }

    /// Drains queued outbound BLE frames for the session.
    #[must_use]
    pub fn drain_ble_tx(&self) -> Vec<Vec<u8>> {
        crate::guarded(|| {
            lock_sessions()
                .entries
                .get_mut(&self.0)
                .map(|entry| entry.runtime.drain_outbound_ble_frames())
                .unwrap_or_default()
        })
    }
}

impl Drop for HostSessionGuard {
    fn drop(&mut self) {
        let _ = koe_host_session_destroy(self.0);
    }
}
