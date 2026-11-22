//! Versioned, panic-contained C boundary for the native product runtime.
#![deny(missing_docs)]

mod credentials;
mod guard;
#[cfg(feature = "local-bridge")]
mod local_bridge;

pub use credentials::KoeCredentialCallback;
pub use guard::{HostSessionGuard, PcmIngestInput};
pub(crate) use guard::{
    guarded, now, read_string, register_session, remove_session, string, with_session,
};
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

/// Owned byte buffer returned by binary drain FFI functions; release with [`koe_host_bytes_free`].
#[repr(C)]
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
pub struct KoeOwnedBytes {
    /// Heap pointer owned by Rust (`null` when empty or handle is invalid).
    pub ptr: *mut u8,
    /// Byte length at `ptr` (`0` when empty or handle is invalid).
    pub len: usize,
    /// Allocation capacity (`0` when empty or handle is invalid).
    pub cap: usize,
}

fn owned_bytes(mut bytes: Vec<u8>) -> KoeOwnedBytes {
    if bytes.is_empty() {
        return KoeOwnedBytes::default();
    }
    let ptr = bytes.as_mut_ptr();
    let len = bytes.len();
    let cap = bytes.capacity();
    std::mem::forget(bytes);
    KoeOwnedBytes { ptr, len, cap }
}

/// Returns the native contract version.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_api_version() -> u32 {
    KOE_HOST_API_VERSION
}

/// Opens an isolated product workspace, returning zero if unavailable or already in use.
/// # Safety
/// `directory` must point to a valid terminated UTF-8 string, or be null.
#[allow(unsafe_code)]
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
/// and obey `KoeCredentialCallback`'s buffer contract.
#[allow(unsafe_code)]
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
            context,
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
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_destroy(handle: u64) -> bool {
    guarded(|| remove_session(handle))
}

/// Returns a session's current generation, or zero for an invalid handle.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_generation(handle: u64) -> u64 {
    guarded(|| with_session(handle, |rt| rt.generation()).unwrap_or(0))
}

/// Returns immutable JSON; release the result with `koe_host_string_free`.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_snapshot_json(handle: u64, epoch: u64) -> *mut c_char {
    guarded(|| {
        with_session(handle, |rt| string(rt.snapshot_json(now(epoch))))
            .unwrap_or(std::ptr::null_mut())
    })
}

/// Applies a command; domain failures are represented in the returned snapshot.
/// # Safety
/// `command` must point to a valid terminated UTF-8 string, or be null.
#[allow(unsafe_code)]
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
        let Some(json_out) =
            with_session(handle, |rt| rt.dispatch_json(&command, now(epoch)))
        else {
            return std::ptr::null_mut();
        };
        string(json_out)
    })
}

/// Appends a bounded PCM16 audio chunk directly without JSON encoding or snapshot projection.
/// # Safety
/// `record_id`, `session_id`, and `lane` must point to valid terminated UTF-8 strings, or be null.
/// When `sample_count` is nonzero, `samples` must be aligned and address `sample_count` initialized
/// `i16` values, or be null.
#[allow(unsafe_code)]
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
        if sample_count == 0
            || sample_count > 8192
            || samples.is_null()
            || !samples.is_aligned()
        {
            return KoePcmReceipt::default();
        }
        // SAFETY: Forwarded caller contract guarantees valid NUL-terminated UTF-8 strings or null.
        let (Some(record_id), Some(session_id), Some(lane)) = (unsafe {
            (
                read_string(record_id),
                read_string(session_id),
                read_string(lane),
            )
        }) else {
            return KoePcmReceipt::default();
        };
        // SAFETY: `samples` was checked non-null and aligned above, and caller guarantees `sample_count` initialized `i16` elements.
        let slice = unsafe { std::slice::from_raw_parts(samples, sample_count) };
        let timing = has_timing.then_some((epoch, captured_start_ns));
        let Some(receipt) = with_session(handle, |rt| {
            rt.ingest_microphone_pcm(koe_runtime::MicrophonePcmChunk {
                record_id: &record_id,
                session_id: &session_id,
                lane: &lane,
                sequence,
                samples: slice,
                timing,
                now: now(now_epoch_sec),
            })
        }) else {
            return KoePcmReceipt::default();
        };
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
#[allow(unsafe_code)]
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
        // SAFETY: Forwarded caller contract guarantees `record_id` is valid NUL-terminated UTF-8 or null.
        let Some(record_id) = (unsafe { read_string(record_id) }) else {
            return KoePlaybackReceipt::default();
        };
        let Some(receipt) = with_session(handle, |rt| {
            rt.report_playback_progress(
                &record_id,
                request_id,
                position_ms,
                is_playing,
                last_projected_now_sec,
                now(now_epoch_sec),
            )
        }) else {
            return KoePlaybackReceipt::default();
        };
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
#[allow(unsafe_code)]
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
            // SAFETY: `bytes` was checked non-null above and caller guarantees `length` initialized bytes.
            unsafe { std::slice::from_raw_parts(bytes, length) }
        };
        with_session(handle, |rt| {
            rt.ingest_ble_chunk(bytes, now(epoch));
            rt.generation()
        })
        .unwrap_or(0)
    })
}

/// Transfers queued BLE frames as length-prefixed binary records (`[u32 le len][bytes]`).
/// Release non-empty buffers with [`koe_host_bytes_free`].
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_drain_ble_tx(handle: u64) -> KoeOwnedBytes {
    guarded(|| {
        let Some(frames) = with_session(handle, |rt| rt.drain_outbound_ble_frames()) else {
            return KoeOwnedBytes::default();
        };
        if frames.is_empty() {
            return KoeOwnedBytes::default();
        }
        let Some(total) = frames
            .iter()
            .filter(|frame| u32::try_from(frame.len()).is_ok())
            .try_fold(0usize, |acc, frame| {
                acc.checked_add(4)?.checked_add(frame.len())
            })
        else {
            return KoeOwnedBytes::default();
        };
        let mut out = Vec::with_capacity(total);
        for frame in frames {
            let Ok(len) = u32::try_from(frame.len()) else {
                continue;
            };
            out.extend_from_slice(&len.to_le_bytes());
            out.extend_from_slice(&frame);
        }
        owned_bytes(out)
    })
}

/// Transfers queued local speech effects as framed binary records (`[u8 kind][u64 le id][u32 le len][payload]`).
/// Release non-empty buffers with [`koe_host_bytes_free`].
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_drain_local_asr(handle: u64) -> KoeOwnedBytes {
    guarded(|| {
        with_session(handle, |rt| owned_bytes(rt.drain_local_asr_binary())).unwrap_or_default()
    })
}

/// Releases a binary buffer returned by this library. Empty/null buffers are accepted.
/// # Safety
/// Non-null `bytes` must be an unreleased buffer returned by this library.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_bytes_free(bytes: KoeOwnedBytes) {
    if !bytes.ptr.is_null() && bytes.cap > 0 && bytes.len <= bytes.cap {
        // SAFETY: Caller transfers ownership of an unreleased `Vec<u8>` returned by `owned_bytes`, and `len <= cap` holds.
        drop(unsafe { Vec::from_raw_parts(bytes.ptr, bytes.len, bytes.cap) });
    }
}

/// Advances runtime deadlines and publishes completed background results.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub extern "C" fn koe_host_session_poll_timers(handle: u64, elapsed_ms: u64, epoch: u64) -> u64 {
    guarded(|| {
        with_session(handle, |rt| {
            rt.poll_timers(elapsed_ms, now(epoch));
            rt.generation()
        })
        .unwrap_or(0)
    })
}

/// Releases a JSON string returned by this library. Null is accepted.
/// # Safety
/// A non-null pointer must be an unreleased string returned by this library.
#[allow(unsafe_code)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn koe_host_string_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        // SAFETY: Ownership is transferred back by the caller.
        drop(unsafe { CString::from_raw(pointer) });
    }
}

#[cfg(test)]
mod session_tests;
