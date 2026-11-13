//! Versioned, panic-contained C boundary for the native product runtime.
#![allow(unsafe_code)]
#![deny(missing_docs)]

mod credentials;
mod local_bridge;

pub use credentials::KoeCredentialCallback;
use koe_runtime::KoeRuntime;
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString, c_char},
    path::Path,
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

/// Native snapshot and command contract version.
pub const KOE_HOST_API_VERSION: u32 = koe_runtime::KOE_HOST_SNAPSHOT_VERSION;

pub(crate) struct SessionEntry {
    pub(crate) runtime: KoeRuntime,
    pub(crate) subscribers: local_bridge::SubscriberHub,
}

#[derive(Default)]
pub(crate) struct Sessions {
    next: u64,
    pub(crate) entries: BTreeMap<u64, SessionEntry>,
    bridges: BTreeMap<u64, local_bridge::BridgeServer>,
}

pub(crate) fn sessions() -> &'static Mutex<Sessions> {
    static SESSIONS: OnceLock<Mutex<Sessions>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(Sessions::default()))
}

pub(crate) fn now(value: u64) -> u64 {
    if value > 0 {
        value
    } else {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_secs())
    }
}

fn guarded<T: Default>(operation: impl FnOnce() -> T) -> T {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(operation)).unwrap_or_default()
}

fn string(value: String) -> *mut c_char {
    CString::new(value).map_or(std::ptr::null_mut(), CString::into_raw)
}

unsafe fn read_string(pointer: *const c_char) -> Option<String> {
    if pointer.is_null() {
        None
    } else {
        // SAFETY: Each exported caller requires a valid terminated string.
        unsafe { CStr::from_ptr(pointer) }
            .to_str()
            .ok()
            .map(str::to_string)
    }
}

fn take_owned_string(pointer: *mut c_char) -> Option<String> {
    if pointer.is_null() {
        return None;
    }
    // SAFETY: `pointer` was allocated by `CString::into_raw` inside this crate.
    let owned = unsafe { CString::from_raw(pointer) };
    owned.into_string().ok()
}

fn register_session(workspace: &Path, runtime: KoeRuntime) -> u64 {
    let subscribers = local_bridge::SubscriberHub::default();
    let handle = {
        let Ok(mut table) = sessions().lock() else {
            return 0;
        };
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
        if let Ok(mut table) = sessions().lock() {
            if table.entries.contains_key(&handle) {
                if let Some(active) = orphan_bridge.take() {
                    table.bridges.insert(handle, active);
                }
            }
        }
        drop(orphan_bridge);
    }
    handle
}

/// Safe RAII wrapper around an active host session handle and its local Unix socket bridge.
pub struct HostSessionGuard(u64);

impl HostSessionGuard {
    /// Opens an isolated host session with its local socket bridge at `path`.
    #[must_use]
    pub fn open(path: &Path) -> Option<Self> {
        let text = path.to_str()?;
        let c_path = CString::new(text).ok()?;
        // SAFETY: `c_path` is a valid NUL-terminated UTF-8 string.
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
        take_owned_string(koe_host_session_snapshot_json(self.0, now))
    }

    /// Dispatches a JSON command into the session and returns the updated snapshot JSON.
    #[must_use]
    pub fn dispatch_json(&self, command_json: &str, now: u64) -> Option<String> {
        let c_cmd = CString::new(command_json).ok()?;
        // SAFETY: `c_cmd` is a valid NUL-terminated UTF-8 string.
        take_owned_string(unsafe { koe_host_session_dispatch_json(self.0, c_cmd.as_ptr(), now) })
    }

    /// Feeds raw BLE notification bytes into the session and returns the resulting generation.
    #[must_use]
    pub fn ingest_ble(&self, bytes: &[u8], now: u64) -> u64 {
        let ptr = if bytes.is_empty() {
            std::ptr::null()
        } else {
            bytes.as_ptr()
        };
        // SAFETY: `ptr` addresses `bytes.len()` initialized bytes when non-empty.
        unsafe { koe_host_session_ingest_ble(self.0, ptr, bytes.len(), now) }
    }

    /// Advances runtime deadlines and returns the resulting generation.
    #[must_use]
    pub fn poll_timers(&self, elapsed_ms: u64, now: u64) -> u64 {
        koe_host_session_poll_timers(self.0, elapsed_ms, now)
    }

    /// Drains queued outbound BLE frames for the session.
    #[must_use]
    pub fn drain_ble_tx(&self) -> Vec<Vec<u8>> {
        guarded(|| {
            sessions()
                .lock()
                .ok()
                .and_then(|mut table| {
                    table
                        .entries
                        .get_mut(&self.0)
                        .map(|entry| entry.runtime.drain_outbound_ble_frames())
                })
                .unwrap_or_default()
        })
    }
}

impl Drop for HostSessionGuard {
    fn drop(&mut self) {
        let _ = koe_host_session_destroy(self.0);
    }
}

/// Returns the native contract version.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_api_version() -> u32 {
    KOE_HOST_API_VERSION
}

/// Opens an isolated product workspace, returning zero if unavailable or already in use.
/// # Safety
/// `directory` must point to a valid terminated UTF-8 string, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_session_create(directory: *const c_char) -> u64 {
    guarded(|| {
        // SAFETY: Forwarded caller contract.
        let Some(path) = (unsafe { read_string(directory) }).filter(|s| !s.trim().is_empty())
        else {
            return 0;
        };
        let runtime = match KoeRuntime::open(&path) {
            Ok(runtime) => runtime,
            Err(error) => {
                eprintln!("koe-host-api: workspace open failed: {error}");
                return 0;
            }
        };
        register_session(Path::new(&path), runtime)
    })
}

/// Opens with a synchronous platform secure-storage adapter.
/// # Safety
/// `directory` must be terminated UTF-8. The callback and context must remain
/// valid until session destruction, support serialized calls on any thread,
/// and obey `KoeCredentialCallback`'s buffer and non-reentrancy contract.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_session_create_with_credentials(
    directory: *const c_char,
    callback: Option<KoeCredentialCallback>,
    context: *mut std::ffi::c_void,
    isolated: bool,
) -> u64 {
    guarded(|| {
        // SAFETY: Forwarded caller contract.
        let Some(path) = (unsafe { read_string(directory) }).filter(|s| !s.trim().is_empty())
        else {
            return 0;
        };
        let Some(callback) = callback else {
            return 0;
        };
        let adapter = credentials::PlatformCredentials {
            callback,
            context: context as usize,
            isolated,
        };
        let runtime = match KoeRuntime::open_with_credentials(&path, Box::new(adapter)) {
            Ok(runtime) => runtime,
            Err(error) => {
                eprintln!("koe-host-api: workspace open failed: {error}");
                return 0;
            }
        };
        register_session(Path::new(&path), runtime)
    })
}

/// Closes a session and cancels its outstanding network work.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_destroy(handle: u64) -> bool {
    guarded(|| {
        let (removed_entry, removed_bridge) = {
            let Ok(mut table) = sessions().lock() else {
                return false;
            };
            (table.entries.remove(&handle), table.bridges.remove(&handle))
        };
        drop(removed_bridge);
        let existed = removed_entry.is_some();
        drop(removed_entry);
        existed
    })
}

/// Returns a session's current generation, or zero for an invalid handle.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_generation(handle: u64) -> u64 {
    guarded(|| {
        sessions()
            .lock()
            .ok()
            .and_then(|s| s.entries.get(&handle).map(|e| e.runtime.generation()))
            .unwrap_or(0)
    })
}

/// Returns immutable JSON; release the result with `koe_host_string_free`.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_snapshot_json(handle: u64, epoch: u64) -> *mut c_char {
    guarded(|| {
        let Ok(table) = sessions().lock() else {
            return std::ptr::null_mut();
        };
        table
            .entries
            .get(&handle)
            .map_or(std::ptr::null_mut(), |e| {
                string(e.runtime.snapshot_json(now(epoch)))
            })
    })
}

/// Applies a command; domain failures are represented in the returned snapshot.
/// # Safety
/// `command` must point to a valid terminated UTF-8 string, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_session_dispatch_json(
    handle: u64,
    command: *const c_char,
    epoch: u64,
) -> *mut c_char {
    guarded(|| {
        // SAFETY: Forwarded caller contract.
        let Some(command) = (unsafe { read_string(command) }) else {
            return std::ptr::null_mut();
        };
        let json_out = {
            let Ok(mut table) = sessions().lock() else {
                return std::ptr::null_mut();
            };
            let Some(entry) = table.entries.get_mut(&handle) else {
                return std::ptr::null_mut();
            };
            let out = entry.runtime.dispatch_json(&command, now(epoch));
            let events = entry.runtime.drain_companion_events();
            entry.subscribers.broadcast(&events);
            out
        };
        string(json_out)
    })
}

/// Accepts a bounded BLE notification; returns the resulting view generation.
/// # Safety
/// `bytes` must address `length` initialized bytes when length is nonzero.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_session_ingest_ble(
    handle: u64,
    bytes: *const u8,
    length: usize,
    epoch: u64,
) -> u64 {
    guarded(|| {
        if length > 1024 * 1024 || (length > 0 && bytes.is_null()) {
            return 0;
        }
        let bytes = if length == 0 {
            &[]
        } else {
            // SAFETY: Checked pointer and length follow the caller contract.
            unsafe { std::slice::from_raw_parts(bytes, length) }
        };
        let generation = {
            let Ok(mut table) = sessions().lock() else {
                return 0;
            };
            let Some(entry) = table.entries.get_mut(&handle) else {
                return 0;
            };
            entry.runtime.ingest_ble_chunk(bytes, now(epoch));
            let generation = entry.runtime.generation();
            let events = entry.runtime.drain_companion_events();
            entry.subscribers.broadcast(&events);
            generation
        };
        generation
    })
}

/// Transfers queued BLE frames as JSON hex strings to the platform adapter.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_drain_ble_tx_json(handle: u64) -> *mut c_char {
    guarded(|| {
        let Ok(mut table) = sessions().lock() else {
            return std::ptr::null_mut();
        };
        let Some(entry) = table.entries.get_mut(&handle) else {
            return std::ptr::null_mut();
        };
        let values: Vec<_> = entry
            .runtime
            .drain_outbound_ble_frames()
            .iter()
            .map(|frame| {
                format!(
                    "\"{}\"",
                    frame.iter().map(|b| format!("{b:02X}")).collect::<String>()
                )
            })
            .collect();
        string(format!("[{}]", values.join(",")))
    })
}

/// Transfers one-shot platform actions as owned JSON.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_drain_host_actions_json(handle: u64) -> *mut c_char {
    guarded(|| {
        let Ok(mut table) = sessions().lock() else {
            return std::ptr::null_mut();
        };
        let Some(entry) = table.entries.get_mut(&handle) else {
            return std::ptr::null_mut();
        };
        string(entry.runtime.drain_host_actions_json())
    })
}

/// Transfers local speech effects as owned JSON without invoking native callbacks.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_drain_local_asr_json(handle: u64) -> *mut c_char {
    guarded(|| {
        let Ok(mut table) = sessions().lock() else {
            return std::ptr::null_mut();
        };
        let Some(entry) = table.entries.get_mut(&handle) else {
            return std::ptr::null_mut();
        };
        string(entry.runtime.drain_local_asr_json())
    })
}

/// Advances runtime deadlines and publishes completed background results.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_poll_timers(handle: u64, elapsed_ms: u64, epoch: u64) -> u64 {
    guarded(|| {
        let generation = {
            let Ok(mut table) = sessions().lock() else {
                return 0;
            };
            let Some(entry) = table.entries.get_mut(&handle) else {
                return 0;
            };
            entry.runtime.poll_timers(elapsed_ms, now(epoch));
            let generation = entry.runtime.generation();
            let events = entry.runtime.drain_companion_events();
            entry.subscribers.broadcast(&events);
            generation
        };
        generation
    })
}

/// Releases a JSON string returned by this library. Null is accepted.
/// # Safety
/// A non-null pointer must be an unreleased string returned by this library.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_string_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        // SAFETY: Ownership is transferred back by the caller.
        drop(unsafe { CString::from_raw(pointer) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn session_lifecycle_has_no_seed_data_and_rejects_duplicate_writer() {
        let root = std::env::temp_dir().join(format!("koe-ffi-v2-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let path = CString::new(root.to_str().unwrap()).unwrap();
        // SAFETY: All pointers are owned terminated strings.
        unsafe {
            let handle = koe_host_session_create(path.as_ptr());
            assert_ne!(handle, 0);
            assert_eq!(koe_host_session_create(path.as_ptr()), 0);
            let snapshot = koe_host_session_snapshot_json(handle, 1000);
            let text = CStr::from_ptr(snapshot).to_str().unwrap();
            assert!(text.contains("\"records\":[]"));
            assert!(text.contains("\"version\":2"));
            koe_host_string_free(snapshot);
            let effects = koe_host_session_drain_local_asr_json(handle);
            assert_eq!(CStr::from_ptr(effects).to_str().unwrap(), "[]");
            koe_host_string_free(effects);
            assert!(koe_host_session_destroy(handle));
            assert!(koe_host_session_drain_local_asr_json(handle).is_null());
            assert_eq!(koe_host_session_generation(handle), 0);
            assert!(!koe_host_session_destroy(handle));
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
