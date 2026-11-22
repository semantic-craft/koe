#[cfg(feature = "local-bridge")]
use crate::local_bridge;
use crate::{
    KoeOwnedBytes, KoePcmReceipt, KoePlaybackReceipt, koe_host_bytes_free,
    koe_host_session_create, koe_host_session_destroy, koe_host_session_dispatch_json,
    koe_host_session_drain_ble_tx, koe_host_session_drain_local_asr,
    koe_host_session_ingest_ble, koe_host_session_ingest_pcm, koe_host_session_poll_timers,
    koe_host_session_report_playback_progress, koe_host_session_snapshot_json,
};
use koe_runtime::KoeRuntime;
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString, c_char},
    path::Path,
    sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError},
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
        // SAFETY: Caller guarantees `pointer` is a valid NUL-terminated C string.
        unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .ok()
            .map(str::to_string)
    }
}

#[derive(Default)]
struct Sessions {
    next: u64,
    entries: BTreeMap<u64, Arc<Mutex<Option<KoeRuntime>>>>,
    #[cfg(feature = "local-bridge")]
    bridges: BTreeMap<u64, local_bridge::BridgeServer>,
}

fn sessions() -> &'static Mutex<Sessions> {
    static SESSIONS: OnceLock<Mutex<Sessions>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(Sessions::default()))
}

fn lock_sessions() -> MutexGuard<'static, Sessions> {
    sessions().lock().unwrap_or_else(PoisonError::into_inner)
}

pub(crate) fn with_session<R>(
    handle: u64,
    op: impl FnOnce(&mut KoeRuntime) -> R,
) -> Option<R> {
    let entry = {
        let table = lock_sessions();
        Arc::clone(table.entries.get(&handle)?)
    };
    let mut guard = entry.lock().ok()?;
    let runtime = guard.as_mut()?;
    Some(op(runtime))
}

pub(crate) fn register_session(workspace: &Path, runtime: KoeRuntime) -> u64 {
    let handle = {
        let mut table = lock_sessions();
        table.next = table.next.saturating_add(1);
        let id = table.next;
        table.entries.insert(id, Arc::new(Mutex::new(Some(runtime))));
        id
    };
    #[cfg(feature = "local-bridge")]
    if let Some(bridge) = local_bridge::BridgeServer::start(handle, workspace) {
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
    #[cfg(not(feature = "local-bridge"))]
    let _ = workspace;
    handle
}

pub(crate) fn remove_session(handle: u64) -> bool {
    #[cfg(feature = "local-bridge")]
    let (removed_entry, removed_bridge) = {
        let mut table = lock_sessions();
        (table.entries.remove(&handle), table.bridges.remove(&handle))
    };
    #[cfg(feature = "local-bridge")]
    drop(removed_bridge);
    #[cfg(not(feature = "local-bridge"))]
    let removed_entry = lock_sessions().entries.remove(&handle);
    let Some(entry) = removed_entry else {
        return false;
    };
    let runtime = entry
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .take();
    drop(runtime);
    true
}

unsafe fn take_owned_string(pointer: *mut c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    // SAFETY: Caller passes an owned, unreleased pointer allocated via `CString::into_raw`.
    let owned = unsafe { CString::from_raw(pointer) };
    owned.into_string().ok()
}

unsafe fn take_owned_bytes(bytes: KoeOwnedBytes) -> Vec<u8> {
    if bytes.ptr.is_null() || bytes.len == 0 {
        // SAFETY: Caller passes an owned `KoeOwnedBytes` returned by this crate.
        unsafe { koe_host_bytes_free(bytes) };
        return Vec::new();
    }
    // SAFETY: `bytes.ptr` is non-null and addresses `bytes.len` initialized bytes owned by this crate.
    let slice = unsafe { std::slice::from_raw_parts(bytes.ptr, bytes.len) };
    let out = slice.to_vec();
    // SAFETY: `bytes` is an unreleased `KoeOwnedBytes` buffer owned by this crate.
    unsafe { koe_host_bytes_free(bytes) };
    out
}

/// Safe RAII wrapper around an active host session handle and its local Unix socket bridge.
pub struct HostSessionGuard(u64);

impl HostSessionGuard {
    /// Opens an isolated host session with its local socket bridge at `path`.
    #[must_use]
    pub fn open(path: &Path) -> Option<Self> {
        let text = path.to_str()?;
        let c_path = CString::new(text).ok()?;
        // SAFETY: `c_path` is a valid NUL-terminated UTF-8 C string for the duration of the call.
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
        // SAFETY: `koe_host_session_snapshot_json` returns null or an owned `CString::into_raw` pointer.
        unsafe { take_owned_string(koe_host_session_snapshot_json(self.0, now)) }
    }

    /// Dispatches a JSON command into the session and returns the updated snapshot JSON.
    #[must_use]
    pub fn dispatch_json(&self, command_json: &str, now: u64) -> Option<String> {
        let c_cmd = CString::new(command_json).ok()?;
        // SAFETY: `c_cmd` is valid NUL-terminated UTF-8 and `koe_host_session_dispatch_json` returns an owned C string or null.
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
        // SAFETY: `ptr` addresses `bytes.len()` initialized bytes (or is null when length is zero).
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
        // SAFETY: C strings are valid NUL-terminated UTF-8 and `ptr` addresses `samples.len()` aligned `i16` values (or is null when empty).
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
        // SAFETY: `c_record` is a valid NUL-terminated UTF-8 C string for the duration of the call.
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

    /// Drains queued outbound BLE frames through the binary C ABI.
    #[must_use]
    pub fn drain_ble_tx(&self) -> Vec<Vec<u8>> {
        // SAFETY: `koe_host_session_drain_ble_tx` returns an owned `KoeOwnedBytes` buffer from this crate.
        let raw = unsafe { take_owned_bytes(koe_host_session_drain_ble_tx(self.0)) };
        let mut frames = Vec::new();
        let mut cursor = 0;
        while let Some(header) = raw.get(cursor..).and_then(|rest| rest.get(..4)) {
            let Ok(len_bytes) = <[u8; 4]>::try_from(header) else {
                break;
            };
            let len = u32::from_le_bytes(len_bytes) as usize;
            let Some(payload_start) = cursor.checked_add(4) else {
                break;
            };
            let Some(payload_end) = payload_start.checked_add(len) else {
                break;
            };
            let Some(frame) = raw.get(payload_start..payload_end) else {
                break;
            };
            frames.push(frame.to_vec());
            cursor = payload_end;
        }
        frames
    }

    /// Drains queued outbound local speech effects as raw binary records through the C ABI.
    #[must_use]
    pub fn drain_local_asr_binary(&self) -> Vec<u8> {
        // SAFETY: `koe_host_session_drain_local_asr` returns an owned `KoeOwnedBytes` buffer from this crate.
        unsafe { take_owned_bytes(koe_host_session_drain_local_asr(self.0)) }
    }
}

impl Drop for HostSessionGuard {
    fn drop(&mut self) {
        let _ = koe_host_session_destroy(self.0);
    }
}
