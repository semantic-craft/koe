//! Versioned, panic-contained C boundary for the native product runtime.
#![allow(unsafe_code)]
#![deny(missing_docs)]

use koe_runtime::KoeRuntime;
use std::{
    collections::BTreeMap,
    ffi::{c_char, CStr, CString},
    sync::{Mutex, OnceLock},
    time::{SystemTime, UNIX_EPOCH},
};

/// Native snapshot and command contract version.
pub const KOE_HOST_API_VERSION: u32 = koe_runtime::KOE_HOST_SNAPSHOT_VERSION;

#[derive(Default)]
struct Sessions {
    next: u64,
    runtimes: BTreeMap<u64, KoeRuntime>,
}

fn sessions() -> &'static Mutex<Sessions> {
    static SESSIONS: OnceLock<Mutex<Sessions>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(Sessions::default()))
}
fn now(value: u64) -> u64 {
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
        let Ok(runtime) = KoeRuntime::open(path) else {
            return 0;
        };
        let Ok(mut table) = sessions().lock() else {
            return 0;
        };
        table.next = table.next.saturating_add(1);
        let handle = table.next;
        table.runtimes.insert(handle, runtime);
        handle
    })
}

/// Closes a session and cancels its outstanding network work.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_destroy(handle: u64) -> bool {
    guarded(|| {
        sessions()
            .lock()
            .ok()
            .and_then(|mut s| s.runtimes.remove(&handle))
            .is_some()
    })
}

/// Returns a session's current generation, or zero for an invalid handle.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_generation(handle: u64) -> u64 {
    guarded(|| {
        sessions()
            .lock()
            .ok()
            .and_then(|s| s.runtimes.get(&handle).map(KoeRuntime::generation))
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
            .runtimes
            .get(&handle)
            .map_or(std::ptr::null_mut(), |r| {
                string(r.snapshot_json(now(epoch)))
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
        let Ok(mut table) = sessions().lock() else {
            return std::ptr::null_mut();
        };
        table
            .runtimes
            .get_mut(&handle)
            .map_or(std::ptr::null_mut(), |r| {
                string(r.dispatch_json(&command, now(epoch)))
            })
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
        let Ok(mut table) = sessions().lock() else {
            return 0;
        };
        let Some(runtime) = table.runtimes.get_mut(&handle) else {
            return 0;
        };
        runtime.ingest_ble_chunk(bytes, now(epoch));
        runtime.generation()
    })
}

/// Transfers queued BLE frames as JSON hex strings to the platform adapter.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_drain_ble_tx_json(handle: u64) -> *mut c_char {
    guarded(|| {
        let Ok(mut table) = sessions().lock() else {
            return std::ptr::null_mut();
        };
        let Some(runtime) = table.runtimes.get_mut(&handle) else {
            return std::ptr::null_mut();
        };
        let values: Vec<_> = runtime
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

/// Advances runtime deadlines and publishes completed background results.
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_poll_timers(handle: u64, elapsed_ms: u64, epoch: u64) -> u64 {
    guarded(|| {
        let Ok(mut table) = sessions().lock() else {
            return 0;
        };
        let Some(runtime) = table.runtimes.get_mut(&handle) else {
            return 0;
        };
        runtime.poll_timers(elapsed_ms, now(epoch));
        runtime.generation()
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
            assert!(koe_host_session_destroy(handle));
            assert_eq!(koe_host_session_generation(handle), 0);
            assert!(!koe_host_session_destroy(handle));
        }
        std::fs::remove_dir_all(root).unwrap();
    }
}
