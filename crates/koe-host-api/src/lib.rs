//! Versioned, panic-contained C boundary for the native product runtime.
#![allow(unsafe_code)]
#![deny(missing_docs)]

mod credentials;
mod guard;
mod local_bridge;

pub use credentials::KoeCredentialCallback;
pub use guard::HostSessionGuard;
pub(crate) use guard::{guarded, now, read_string, register_session, sessions, string};
use koe_runtime::{KoeRuntime, PcmIngestStatus};
use std::{
    ffi::{CString, c_char},
    path::Path,
};

/// Native snapshot and command contract version.
pub const KOE_HOST_API_VERSION: u32 = koe_runtime::KOE_HOST_SNAPSHOT_VERSION;

/// C-ABI receipt returned by [`koe_host_session_ingest_pcm`].
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoePcmReceipt {
    /// Resulting session view generation (`0` when handle or pointer is invalid).
    pub generation: u64,
    /// Lane `next_sequence` after attempting chunk ingestion (`0` when stale or invalid).
    pub next_sequence: u64,
    /// `0` accepted, `1` stale session/lane, `2` rejected.
    pub status: u32,
    /// Explicit padding to 8-byte alignment.
    pub reserved: u32,
}

impl Default for KoePcmReceipt {
    fn default() -> Self {
        Self {
            generation: 0,
            next_sequence: 0,
            status: PcmIngestStatus::Rejected as u32,
            reserved: 0,
        }
    }
}

/// C-ABI receipt returned by [`koe_host_session_report_playback_progress`].
#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct KoePlaybackReceipt {
    /// Resulting session view generation (`0` when handle or pointer is invalid).
    pub generation: u64,
    /// Session view generation immediately before applying progress.
    pub prev_generation: u64,
    /// Clamped playback position in milliseconds.
    pub position_ms: u64,
    /// Effective wall-clock timestamp in epoch seconds resolved by the runtime.
    pub now_epoch_sec: u64,
    /// Active playing state after applying progress.
    pub is_playing: bool,
    /// Whether active playback state mutated (or applied alongside dirty clock state).
    pub applied: bool,
    /// Whether day rollover, trash retention, or background reconciliation requires a full snapshot.
    pub needs_full_snapshot: bool,
    /// Explicit padding to 8-byte alignment.
    pub reserved: [u8; 5],
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

/// Appends a bounded PCM16 audio chunk directly without JSON encoding or snapshot projection.
/// # Safety
/// `record_id`, `session_id`, and `lane` must point to valid terminated UTF-8 strings, or be null.
/// When `sample_count` is nonzero, `samples` must be aligned and address `sample_count` initialized
/// `i16` values, or be null.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn koe_host_session_ingest_pcm(
    handle: u64,
    record_id: *const c_char,
    session_id: *const c_char,
    lane: *const c_char,
    sequence: u64,
    epoch: u64,
    captured_start_ns: u64,
    has_timing: bool,
    samples: *const i16,
    sample_count: usize,
    now_epoch_sec: u64,
) -> KoePcmReceipt {
    guarded(|| {
        let (Some(record_id), Some(session_id), Some(lane)) = (unsafe {
            (
                read_string(record_id),
                read_string(session_id),
                read_string(lane),
            )
        }) else {
            return KoePcmReceipt::default();
        };
        if sample_count > 0 && (samples.is_null() || !samples.is_aligned()) {
            return KoePcmReceipt::default();
        }
        let slice: &[i16] = if sample_count == 0 || sample_count > 8192 {
            &[]
        } else {
            unsafe { std::slice::from_raw_parts(samples, sample_count) }
        };
        let timing = has_timing.then_some((epoch, captured_start_ns));
        let Ok(mut table) = sessions().lock() else {
            return KoePcmReceipt::default();
        };
        let Some(entry) = table.entries.get_mut(&handle) else {
            return KoePcmReceipt::default();
        };
        let receipt = entry.runtime.ingest_microphone_pcm(
            &record_id,
            &session_id,
            &lane,
            sequence,
            slice,
            timing,
            now(now_epoch_sec),
        );
        let events = entry.runtime.drain_companion_events();
        entry.subscribers.broadcast(&events);
        KoePcmReceipt {
            generation: receipt.generation,
            next_sequence: receipt.next_sequence,
            status: receipt.status as u32,
            reserved: 0,
        }
    })
}

/// Reports native playhead progress without re-projecting the workspace when clock state is clean.
/// # Safety
/// `record_id` must point to a valid terminated UTF-8 string, or be null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_session_report_playback_progress(
    handle: u64,
    record_id: *const c_char,
    request_id: u64,
    position_ms: u64,
    is_playing: bool,
    last_projected_now_sec: u64,
    now_epoch_sec: u64,
) -> KoePlaybackReceipt {
    guarded(|| {
        let Some(record_id) = (unsafe { read_string(record_id) }) else {
            return KoePlaybackReceipt::default();
        };
        let Ok(mut table) = sessions().lock() else {
            return KoePlaybackReceipt::default();
        };
        let Some(entry) = table.entries.get_mut(&handle) else {
            return KoePlaybackReceipt::default();
        };
        let receipt = entry.runtime.report_playback_progress(
            &record_id,
            request_id,
            position_ms,
            is_playing,
            last_projected_now_sec,
            now(now_epoch_sec),
        );
        let events = entry.runtime.drain_companion_events();
        entry.subscribers.broadcast(&events);
        KoePlaybackReceipt {
            generation: receipt.generation,
            prev_generation: receipt.prev_generation,
            position_ms: receipt.position_ms,
            now_epoch_sec: receipt.now_epoch_sec,
            is_playing: receipt.is_playing,
            applied: receipt.applied,
            needs_full_snapshot: receipt.needs_full_snapshot,
            reserved: [0; 5],
        }
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
            unsafe { std::slice::from_raw_parts(bytes, length) }
        };
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
mod session_tests;

#[cfg(test)]
#[path = "local_bridge_dictation_tests.rs"]
mod local_bridge_dictation_tests;
