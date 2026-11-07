//! Thin C-ABI boundary wrapping the `#![forbid(unsafe_code)]` `koe_core` crate
//! for `dart:ffi`, Swift (`darwin/KoeCore.swift`), and Kotlin (`KoeCore.kt`) callers.

use std::collections::{BTreeMap, VecDeque};
use std::slice;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

use koe_core::cicada::{
    decode_koepack_v2, encode_koepack_v2, CicadaEvent, CicadaReducer, CicadaState, MaterialPackV2,
    PackMaterialMeta, PackMinutesV2, PortableMinutesEntry, RollingMinutesScheduler,
    RollingTickDecision,
};
use koe_core::commands::DeviceCommands;
use koe_core::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
use koe_core::domain::{SegmentId, UtteranceSpine};
use koe_core::frame::{DecodedPacket, FrameReassembler, ProtocolFrame};
use koe_core::hash::sha256_hex;
use koe_core::library::{RecordingEntry, RecordingLibrary};
use koe_core::minutes::{
    build_minutes_batches, parse_meeting_minutes_json, parse_qwen_transcript_json,
    replace_minute_terms, validate_calculation_grounding, MinutesValidationError,
};
use koe_core::models::{DeviceInfoModel, OfflineFileList};
use koe_core::ogg_opus::OggOpus;
use koe_core::session::{SessionIngestOutcome, TransferProgress, TransportSession};
use koe_core::slice_marks::{SliceMark, SliceMarkProbe};
use koe_core::transport::{TransportSliceProcessor, OPUS_FRAME_BYTES};
use koe_core::wav::OpusWave;
use koe_core::wifi::{WifiBatchProgress, WifiEndpoint, WIFI_KEEPALIVE_PAYLOAD};

pub mod jni;
pub mod opus_ffi;

/// C-ABI flat representation of `DeviceInfoModel` for stack-allocated FFI reads.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeDeviceInfo {
    /// `-1` when `None`, else `0..=255`.
    pub connect_status: i32,
    /// `-1` when `None`, else `0..=100`.
    pub battery: i32,
    /// `1` when charging, else `0`.
    pub charging: u8,
    /// `-1` when `None`, else `0..=100`.
    pub box_battery: i32,
    /// `1` when case charging, else `0`.
    pub box_charging: u8,
    /// Wire recording state (`0` stopped, `1` recording, `2` paused).
    pub recording_status: u8,
    /// `1` when `total_memory_kb` and `free_memory_kb` are present, else `0`.
    pub has_memory: u8,
    /// Total storage capacity in KB when `has_memory == 1`.
    pub total_memory_kb: u32,
    /// Free storage capacity in KB when `has_memory == 1`.
    pub free_memory_kb: u32,
    /// NUL-terminated UTF-8 firmware version (`<= 15` bytes + NUL).
    pub firmware_version: [u8; 16],
    /// NUL-terminated UTF-8 lowercase serial number (`<= 31` bytes + NUL).
    pub serial_number: [u8; 32],
    /// NUL-terminated UTF-8 case MAC (`XX:XX:XX:XX:XX:XX`, `<= 23` bytes + NUL).
    pub box_mac: [u8; 24],
    /// NUL-terminated UTF-8 case firmware version (`<= 15` bytes + NUL).
    pub box_firmware: [u8; 16],
    /// NUL-terminated UTF-8 Wi-Fi firmware version (`<= 15` bytes + NUL).
    pub wifi_firmware: [u8; 16],
}

impl KoeDeviceInfo {
    fn from_model(m: &DeviceInfoModel) -> Self {
        let mut out = Self {
            connect_status: m.connect_status.map_or(-1, i32::from),
            battery: m.battery.map_or(-1, i32::from),
            charging: u8::from(m.charging),
            box_battery: m.box_battery.map_or(-1, i32::from),
            box_charging: u8::from(m.box_charging),
            recording_status: m.recording_status,
            has_memory: u8::from(m.total_memory_kb.is_some() && m.free_memory_kb.is_some()),
            total_memory_kb: m.total_memory_kb.unwrap_or(0),
            free_memory_kb: m.free_memory_kb.unwrap_or(0),
            firmware_version: [0u8; 16],
            serial_number: [0u8; 32],
            box_mac: [0u8; 24],
            box_firmware: [0u8; 16],
            wifi_firmware: [0u8; 16],
        };
        copy_c_str(&m.firmware_version, &mut out.firmware_version);
        copy_c_str(&m.serial_number, &mut out.serial_number);
        copy_c_str(&m.box_mac, &mut out.box_mac);
        copy_c_str(&m.box_firmware, &mut out.box_firmware);
        copy_c_str(&m.wifi_firmware, &mut out.wifi_firmware);
        out
    }
}

fn copy_c_str(src: &str, dst: &mut [u8]) {
    dst.fill(0);
    if dst.is_empty() {
        return;
    }
    let bytes = src.as_bytes();
    let len = bytes.len().min(dst.len() - 1);
    dst[..len].copy_from_slice(&bytes[..len]);
}

/// C-ABI flat representation of `OfflineFileEntry`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeOfflineFileEntry {
    /// Device file identifier.
    pub file_id: u32,
    /// Duration in milliseconds.
    pub duration_ms: u32,
    /// `1` when `end_time` is present, else `0`.
    pub has_end_time: u8,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 3],
    /// End timestamp in seconds when `has_end_time == 1`.
    pub end_time: u32,
}

/// C-ABI header summary of `OfflineFileList`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeOfflineFileListHeader {
    /// Raw 16-bit file count reported at payload offset 0.
    pub file_count: u16,
    /// Number of valid non-zero entries parsed from the payload.
    pub parsed_entries: u16,
    /// `1` when trailing transport timestamp/duration are present, else `0`.
    pub has_transport_state: u8,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 3],
    /// Active transport timestamp when `has_transport_state == 1`.
    pub current_transport_timestamp: u32,
    /// Active transport duration when `has_transport_state == 1`.
    pub current_transport_duration: u32,
}

/// C-ABI flat representation of `SliceMarkTransition`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeSliceMarkTransition {
    /// Packet command identifier (such as `0x08`).
    pub cmd_id: u8,
    /// Slice flags byte.
    pub flags: u8,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 2],
    /// Slice sequence number.
    pub sequence: u32,
}

/// C-ABI flat representation of `OpenedFileHead` (`0x1A / 0x07` header + optional unwrapped key).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeAudioFileHead {
    /// Numeric file identifier at offset 9.
    pub file_id: u32,
    /// Total file size in bytes at offset 13 (`0xFFFFFFFF` when unfinished).
    pub file_size: u32,
    /// Device error code at offset 95.
    pub error_code: u8,
    /// `1` when `file_size == 0xFFFFFFFF`, else `0`.
    pub unfinished: u8,
    /// `1` when `file_key` was unwrapped and verified against `"soundcoreD3200"`, else `0`.
    pub has_file_key: u8,
    /// Padding for 4-byte alignment.
    pub reserved: u8,
    /// 16-byte per-file CTR nonce at offset 17..33.
    pub nonce: [u8; 16],
    /// 46-byte encrypted file key material at offset 33..79.
    pub encrypted_file_key: [u8; 46],
    /// 16-byte session CTR nonce at offset 79..95.
    pub session_nonce: [u8; 16],
    /// Unwrapped 32-byte AES-256 file key when `has_file_key == 1`.
    pub file_key: [u8; 32],
}

/// C-ABI flat representation of `RecordingEntry` (up to 32 sorted mark timestamps).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeRecordingEntry {
    /// Recording identifier.
    pub id: u32,
    /// Originating D3200 file ID.
    pub bean_file_id: u32,
    /// UTC creation timestamp in Unix seconds.
    pub created_at_epoch_sec: u64,
    /// Total duration in milliseconds.
    pub duration_ms: u64,
    /// File size on disk in bytes.
    pub byte_count: u32,
    /// Number of valid entries in `marks_ms` (`0..=32`).
    pub mark_count: u32,
    /// Sorted mark positions in milliseconds.
    pub marks_ms: [u64; 32],
}

impl KoeRecordingEntry {
    pub(crate) fn from_domain(entry: &RecordingEntry) -> Self {
        let mut marks_ms = [0u64; 32];
        let count = entry.marks_ms.len().min(32);
        marks_ms[..count].copy_from_slice(&entry.marks_ms[..count]);
        Self {
            id: entry.id,
            bean_file_id: entry.bean_file_id,
            created_at_epoch_sec: entry.created_at_epoch_sec,
            duration_ms: entry.duration_ms,
            byte_count: entry.byte_count,
            mark_count: count as u32,
            marks_ms,
        }
    }

    pub(crate) fn to_domain(&self) -> RecordingEntry {
        let count = (self.mark_count as usize).min(32);
        RecordingEntry {
            id: self.id,
            bean_file_id: self.bean_file_id,
            created_at_epoch_sec: self.created_at_epoch_sec,
            duration_ms: self.duration_ms,
            byte_count: self.byte_count,
            marks_ms: self.marks_ms[..count].to_vec(),
        }
    }
}

/// C-ABI flat representation of `TransferProgress`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeTransferProgress {
    /// `TransferPhaseTag` value (`0..=4`).
    pub phase: u8,
    /// Device or watchdog error code when `phase == 4`.
    pub error_code: u8,
    /// Number of watchdog retries used (`0..=2`).
    pub retry_count: u8,
    /// `1` when realtime stream is in the 2-second quiet-drain window, else `0`.
    pub quiet_draining: u8,
    /// Active D3200 file ID (`0` when idle).
    pub file_id: u32,
    /// Wire record bytes received (`slices * 166`).
    pub received_wire_bytes: u32,
    /// Expected wire bytes (`0` for live stream).
    pub expected_wire_bytes: u32,
    /// Number of unique hardware double-tap marks accumulated.
    pub mark_count: u32,
}

impl KoeTransferProgress {
    pub(crate) fn from_domain(t: &TransferProgress) -> Self {
        Self {
            phase: t.phase as u8,
            error_code: t.error_code,
            retry_count: t.retry_count,
            quiet_draining: u8::from(t.quiet_draining),
            file_id: t.file_id,
            received_wire_bytes: t.received_wire_bytes,
            expected_wire_bytes: t.expected_wire_bytes,
            mark_count: t.mark_count,
        }
    }
}

/// C-ABI coarse step result returned by `koe_session_ingest_ble_chunk` and
/// `koe_session_simulate_realtime_pipeline`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeSessionStepResult {
    /// Number of complete checksum-verified RX frames decoded.
    pub frames_decoded: u32,
    /// `ConnectionPhaseTag` value (`0..=4`).
    pub connection_phase: u8,
    /// `1` when `01/01` telemetry was updated.
    pub telemetry_updated: u8,
    /// `1` when `2E/01` session key was established.
    pub session_key_established: u8,
    /// `1` when offline file catalog was updated.
    pub catalog_updated: u8,
    /// `1` when transfer progress changed.
    pub transfer_updated: u8,
    /// `1` when a recording finalized and is ready via `koe_session_take_finalized`.
    pub has_finalized_recording: u8,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 2],
    /// Number of 160-byte Opus slices unpacked during this step.
    pub slices_unpacked_count: u32,
    /// Number of new mark timestamps observed during this step.
    pub new_marks_count: u32,
    /// Number of queued outbound TX frames awaiting `koe_session_pop_outbound_tx`.
    pub outbound_tx_count: u32,
    /// Total buffered 16 kHz mono PCM16 LE bytes ready to drain via `koe_session_take_live_pcm16`.
    pub live_pcm16_bytes_available: u32,
    /// Current transfer progress snapshot.
    pub transfer: KoeTransferProgress,
}

/// C-ABI summary snapshot of `RecordingLibrary`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeLibrarySnapshot {
    /// Total number of recordings in the library.
    pub entry_count: u32,
    /// Currently selected recording ID (`0` when `None`).
    pub selected_recording_id: u32,
    /// Current playhead position in milliseconds.
    pub playhead_ms: u64,
    /// `1` when an undoable trashed recording exists, else `0`.
    pub has_last_trashed: u8,
    /// Padding for 8-byte alignment.
    pub reserved: [u8; 7],
    /// ID of the most recently trashed recording when `has_last_trashed == 1`.
    pub last_trashed_id: u32,
    /// Trailing alignment padding.
    pub pad_tail: u32,
}

/// C-ABI flat representation of `WifiEndpoint` (`0x1A / 0x05` response).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeWifiEndpoint {
    /// IPv4 address octets `[a, b, c, d]`.
    pub ip: [u8; 4],
    /// WebSocket control port (`32002` on D3200 firmware).
    pub port: u16,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 2],
}

/// C-ABI flat representation of `WifiBatchProgress`.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeWifiBatchProgress {
    /// `WifiBatchPhase` discriminant (`0..=5`).
    pub phase: u8,
    /// Device or transport error code when `phase == 5`.
    pub error_code: u8,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 2],
    /// Zero-based index of the active file in the batch queue.
    pub current_file_index: u32,
    /// Total files queued in the batch.
    pub total_files: u32,
    /// Currently transferring file ID (`0` when none).
    pub active_file_id: u32,
    /// Wire record bytes received for the active file (`slices * 166`).
    pub received_wire_bytes: u32,
    /// Expected wire bytes for the active file (`0` until `1A/07` header arrives).
    pub expected_wire_bytes: u32,
    /// Count of files completed normally in this batch.
    pub finalized_count: u32,
    /// Count of files salvaged (`>= 95%`) on hotspot drop.
    pub salvaged_count: u32,
    /// Count of files skipped due to `1A/07` error codes `1` or `3`.
    pub skipped_count: u32,
    /// Count of files still remaining in the queue.
    pub remaining_count: u32,
}

impl KoeWifiBatchProgress {
    pub(crate) fn from_domain(p: &WifiBatchProgress) -> Self {
        Self {
            phase: p.phase as u8,
            error_code: p.error_code,
            reserved: [0u8; 2],
            current_file_index: p.current_file_index,
            total_files: p.total_files,
            active_file_id: p.active_file_id,
            received_wire_bytes: p.received_wire_bytes,
            expected_wire_bytes: p.expected_wire_bytes,
            finalized_count: p.finalized_count,
            salvaged_count: p.salvaged_count,
            skipped_count: p.skipped_count,
            remaining_count: p.remaining_count,
        }
    }
}

/// C-ABI summary snapshot of `UtteranceSpine` (`S1..Sn`).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeUtteranceSpineSnapshot {
    /// Total number of segments (`S1..Sn`).
    pub segment_count: u32,
    /// `1` when derived artifacts are stale after an edit/speaker rename, else `0`.
    pub is_stale: u8,
    /// Padding for 8-byte alignment.
    pub reserved: [u8; 3],
    /// Monotonically increasing spine revision.
    pub revision: u64,
}

/// C-ABI fixed metadata header for a single `UtteranceSegment` (`S1..Sn`).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeUtteranceSegmentHeader {
    /// 1-based ordinal (`1` for `S1`).
    pub ordinal: u32,
    /// Segment revision (starts at `1`, increments on edit).
    pub revision: u32,
    /// Start timestamp in milliseconds.
    pub start_ms: u64,
    /// End timestamp in milliseconds.
    pub end_ms: u64,
    /// `1` when finalized, else `0`.
    pub is_final: u8,
    /// `1` when `translation` is present, else `0`.
    pub has_translation: u8,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 2],
    /// UTF-8 byte length of `text`.
    pub text_len: u32,
    /// UTF-8 byte length of `translation` (`0` when absent).
    pub translation_len: u32,
    /// NUL-terminated UTF-8 source language code (`<= 15` bytes + NUL).
    pub source_language: [u8; 16],
    /// NUL-terminated UTF-8 target language code (`<= 15` bytes + NUL).
    pub target_language: [u8; 16],
}

/// C-ABI flat status snapshot of `RollingMinutesScheduler` (`wquguru/cicada`).
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct KoeCicadaRollingStatus {
    /// `1` when rolling scheduler is paused, else `0`.
    pub paused: u8,
    /// `1` when rolling scheduler is closed, else `0`.
    pub closed: u8,
    /// `1` when active minutes were manually edited by the user, else `0`.
    pub edited: u8,
    /// `1` when a newer machine-generated candidate is waiting behind a user edit, else `0`.
    pub has_candidate: u8,
    /// `RollingRequestStatus` discriminant (`0..=4`).
    pub request_status: u8,
    /// Padding for 4-byte alignment.
    pub reserved: [u8; 3],
    /// Current source block watermark index.
    pub watermark: u32,
    /// Number of rolling calls issued in the active 1-hour sliding window.
    pub calls_this_hour: u32,
    /// Monotonically increasing scheduler generation.
    pub generation: u64,
}

/// Computes the 8-bit wrapping protocol checksum over `data_ptr[0..data_len]`.
///
/// # Safety
///
/// `data_ptr` must be either null (when `data_len == 0`) or valid for reads of `data_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn koe_protocol_checksum(data_ptr: *const u8, data_len: usize) -> u8 {
    if data_ptr.is_null() || data_len == 0 {
        return 0;
    }
    let data = unsafe { slice::from_raw_parts(data_ptr, data_len) };
    ProtocolFrame::checksum(data)
}

/// Verifies that `packet_ptr[0..packet_len]` has a valid trailing protocol checksum (`1` valid, `0` invalid).
///
/// # Safety
///
/// `packet_ptr` must be valid for reads of `packet_len` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_protocol_verify_checksum(
    packet_ptr: *const u8,
    packet_len: usize,
) -> u8 {
    if packet_ptr.is_null() || packet_len < 2 {
        return 0;
    }
    let packet = unsafe { slice::from_raw_parts(packet_ptr, packet_len) };
    u8::from(ProtocolFrame::verify_checksum(packet))
}

/// Encodes a D3200 TX command frame into `out_ptr` (capacity `>= payload_len + 10`).
/// Returns the number of bytes written (`payload_len + 10`), or `0` on invalid pointers.
///
/// # Safety
///
/// `payload_ptr` must be valid for reads of `payload_len` bytes when non-null, and
/// `out_ptr` must be valid for writes of `out_cap` bytes.
#[no_mangle]
pub unsafe extern "C" fn koe_protocol_encode(
    cmd_type: u8,
    cmd_id: u8,
    payload_ptr: *const u8,
    payload_len: usize,
    out_ptr: *mut u8,
    out_cap: usize,
) -> usize {
    let needed = payload_len.saturating_add(10);
    if out_ptr.is_null() || out_cap < needed {
        return 0;
    }
    let payload = if payload_ptr.is_null() || payload_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(payload_ptr, payload_len) }
    };
    let encoded = ProtocolFrame::encode(cmd_type, cmd_id, payload);
    let out = unsafe { slice::from_raw_parts_mut(out_ptr, encoded.len()) };
    out.copy_from_slice(&encoded);
    encoded.len()
}

/// Converts a raw D3200 battery value (`0..=9` bucket or literal percentage) into `0..=100`.
#[no_mangle]
pub extern "C" fn koe_battery_remaining(raw: i32) -> i32 {
    DeviceInfoModel::battery_remaining(Some(raw)).map_or(-1, i32::from)
}

/// Parses a full D3200 device-info RX packet (`raw_ptr[0..raw_len]`) into `*out_ptr`.
/// Returns `1` on success, `0` on null pointers.
///
/// # Safety
///
/// `raw_ptr` must be valid for reads of `raw_len` bytes when non-null, and `out_ptr`
/// must be valid for writes of one `KoeDeviceInfo`.
#[no_mangle]
pub unsafe extern "C" fn koe_device_info_parse_packet(
    raw_ptr: *const u8,
    raw_len: usize,
    out_ptr: *mut KoeDeviceInfo,
) -> i32 {
    if out_ptr.is_null() {
        return 0;
    }
    let raw = if raw_ptr.is_null() || raw_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(raw_ptr, raw_len) }
    };
    let model = DeviceInfoModel::parse_packet(raw);
    unsafe {
        *out_ptr = KoeDeviceInfo::from_model(&model);
    }
    1
}

/// Parses a D3200 device-info payload slice (`payload_ptr[0..payload_len]`) into `*out_ptr`.
/// Returns `1` on success, `0` on null pointers.
///
/// # Safety
///
/// `payload_ptr` must be valid for reads of `payload_len` bytes when non-null, and `out_ptr`
/// must be valid for writes of one `KoeDeviceInfo`.
#[no_mangle]
pub unsafe extern "C" fn koe_device_info_parse_payload(
    payload_ptr: *const u8,
    payload_len: usize,
    out_ptr: *mut KoeDeviceInfo,
) -> i32 {
    if out_ptr.is_null() {
        return 0;
    }
    let payload = if payload_ptr.is_null() || payload_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(payload_ptr, payload_len) }
    };
    let model = DeviceInfoModel::parse_payload(payload);
    unsafe {
        *out_ptr = KoeDeviceInfo::from_model(&model);
    }
    1
}

/// Parses an offline file list payload (`0x1A 0x0E` or `0x1B 0x0E`) into `*out_header_ptr`
/// and writes up to `out_entries_cap` entries into `out_entries_ptr`.
/// Returns the total number of parsed entries.
///
/// # Safety
///
/// `payload_ptr` must be valid for reads of `payload_len` bytes when non-null;
/// `out_header_ptr` must be valid for writes when non-null; and `out_entries_ptr`
/// must be valid for writes of `out_entries_cap` items when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_offline_file_list_parse(
    payload_ptr: *const u8,
    payload_len: usize,
    with_end_time: u8,
    out_header_ptr: *mut KoeOfflineFileListHeader,
    out_entries_ptr: *mut KoeOfflineFileEntry,
    out_entries_cap: usize,
) -> usize {
    let payload = if payload_ptr.is_null() || payload_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(payload_ptr, payload_len) }
    };
    let parsed = OfflineFileList::parse(payload, with_end_time != 0);
    if !out_header_ptr.is_null() {
        unsafe {
            *out_header_ptr = KoeOfflineFileListHeader {
                file_count: parsed.file_count,
                parsed_entries: parsed.files.len().min(u16::MAX as usize) as u16,
                has_transport_state: u8::from(
                    parsed.current_transport_timestamp.is_some()
                        && parsed.current_transport_duration.is_some(),
                ),
                reserved: [0u8; 3],
                current_transport_timestamp: parsed.current_transport_timestamp.unwrap_or(0),
                current_transport_duration: parsed.current_transport_duration.unwrap_or(0),
            };
        }
    }
    if !out_entries_ptr.is_null() && out_entries_cap > 0 {
        let count = parsed.files.len().min(out_entries_cap);
        let out_slice = unsafe { slice::from_raw_parts_mut(out_entries_ptr, count) };
        for (dst, src) in out_slice.iter_mut().zip(parsed.files.iter().take(count)) {
            *dst = KoeOfflineFileEntry {
                file_id: src.file_id,
                duration_ms: src.duration_ms,
                has_end_time: u8::from(src.end_time.is_some()),
                reserved: [0u8; 3],
                end_time: src.end_time.unwrap_or(0),
            };
        }
    }
    parsed.files.len()
}

/// Returns `1` when `flags` carries the double-tap mark bit (`0x01`), else `0`.
#[no_mangle]
pub extern "C" fn koe_slice_mark_is_mark(flags: u8) -> u8 {
    u8::from(SliceMark::is_mark(flags))
}

/// Returns the recording offset in milliseconds for `sequence` (`sequence * 20`).
#[no_mangle]
pub extern "C" fn koe_slice_mark_position_ms(sequence: u32) -> u64 {
    SliceMark::position_ms(sequence)
}

/// Inspects a full RX packet (`raw_ptr[0..raw_len]`) for `(cmd_id, flags)` slice transitions,
/// updating `*io_last_cmd_id` and `*io_last_flags` in place and writing up to `out_cap`
/// transitions into `out_transitions_ptr`. Returns the total number of transitions detected.
///
/// # Safety
///
/// `raw_ptr` must be valid for reads of `raw_len` bytes; `io_last_cmd_id` and `io_last_flags`
/// must be valid mutable pointers; and `out_transitions_ptr` must be valid for writes of `out_cap`
/// items when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_slice_mark_inspect_transitions(
    raw_ptr: *const u8,
    raw_len: usize,
    io_last_cmd_id: *mut u8,
    io_last_flags: *mut u8,
    out_transitions_ptr: *mut KoeSliceMarkTransition,
    out_cap: usize,
) -> usize {
    if raw_ptr.is_null() || raw_len < 10 || io_last_cmd_id.is_null() || io_last_flags.is_null() {
        return 0;
    }
    let raw = unsafe { slice::from_raw_parts(raw_ptr, raw_len) };
    let pkt = DecodedPacket::from_bytes(raw);
    let mut probe = unsafe { SliceMarkProbe::from_state(*io_last_cmd_id, *io_last_flags) };
    let transitions: Vec<KoeSliceMarkTransition> = probe
        .inspect_transitions(&pkt)
        .into_iter()
        .map(|t| KoeSliceMarkTransition {
            cmd_id: t.cmd_id,
            flags: t.flags,
            reserved: [0u8; 2],
            sequence: t.sequence,
        })
        .collect();
    let (next_cmd, next_flags) = probe.state();
    unsafe {
        *io_last_cmd_id = next_cmd;
        *io_last_flags = next_flags;
    }
    if !out_transitions_ptr.is_null() && out_cap > 0 {
        let count = transitions.len().min(out_cap);
        let out_slice = unsafe { slice::from_raw_parts_mut(out_transitions_ptr, count) };
        out_slice.copy_from_slice(&transitions[..count]);
    }
    transitions.len()
}

/// Parses a `0x1A / 0x07` audio file transfer header (`raw_ptr[0..raw_len]`) and, when
/// `session_key_ptr` is non-null (`session_key_len > 0`), unwraps and verifies the 32-byte
/// per-file AES key into `out_head_ptr->file_key`. Returns `1` on valid header, `0` if `< 97` bytes.
///
/// # Safety
///
/// `raw_ptr` must be valid for reads of `raw_len` bytes; `session_key_ptr` must be valid for
/// reads of `session_key_len` bytes when non-null; and `out_head_ptr` must be valid for writes
/// of one `KoeAudioFileHead`.
#[no_mangle]
pub unsafe extern "C" fn koe_transport_parse_file_head(
    raw_ptr: *const u8,
    raw_len: usize,
    session_key_ptr: *const u8,
    session_key_len: usize,
    out_head_ptr: *mut KoeAudioFileHead,
) -> i32 {
    if raw_ptr.is_null() || raw_len < 97 || out_head_ptr.is_null() {
        return 0;
    }
    let raw = unsafe { slice::from_raw_parts(raw_ptr, raw_len) };
    let session_key = if session_key_ptr.is_null() || session_key_len == 0 {
        None
    } else {
        Some(unsafe { slice::from_raw_parts(session_key_ptr, session_key_len) })
    };
    let Some(opened) = TransportSliceProcessor::open_file_head(raw, session_key) else {
        return 0;
    };
    let mut encrypted_file_key = [0u8; 46];
    let copy_len = opened.secret.encrypted_file_key.len().min(46);
    encrypted_file_key[..copy_len].copy_from_slice(&opened.secret.encrypted_file_key[..copy_len]);
    unsafe {
        *out_head_ptr = KoeAudioFileHead {
            file_id: opened.secret.file_id,
            file_size: opened.secret.file_size,
            error_code: opened.secret.error_code,
            unfinished: u8::from(opened.unfinished),
            has_file_key: u8::from(opened.file_key.is_some()),
            reserved: 0,
            nonce: opened.secret.nonce,
            encrypted_file_key,
            session_nonce: opened.secret.session_nonce,
            file_key: opened.file_key.unwrap_or([0u8; 32]),
        };
    }
    1
}

/// Unpacks all 166-byte slice records in a `0x1A / 0x08` (`0x12`) packet (`frame_ptr[0..frame_len]`),
/// optionally decrypts each 160-byte Opus payload when `file_key_ptr` and `nonce_ptr` are non-null,
/// writes contiguous 160-byte Opus frames into `out_opus_ptr[0..out_opus_cap]`, and writes marked
/// sequence numbers into `out_marks_ptr[0..out_marks_cap]` (storing the mark count in `*out_marks_count_ptr`).
/// Returns the number of unpacked 160-byte slices (`slice_count`).
///
/// # Safety
///
/// `frame_ptr` must be valid for reads of `frame_len` bytes; `file_key_ptr` and `nonce_ptr` must be
/// valid for reads of `file_key_len` and `nonce_len` bytes when non-null; `out_opus_ptr` must be valid
/// for writes of `out_opus_cap` bytes when non-null; `out_marks_ptr` must be valid for writes of
/// `out_marks_cap` `u32` elements when non-null; and `out_marks_count_ptr` must be valid for writes
/// when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_transport_unpack_slices(
    frame_ptr: *const u8,
    frame_len: usize,
    file_key_ptr: *const u8,
    file_key_len: usize,
    nonce_ptr: *const u8,
    nonce_len: usize,
    out_opus_ptr: *mut u8,
    out_opus_cap: usize,
    out_marks_ptr: *mut u32,
    out_marks_cap: usize,
    out_marks_count_ptr: *mut usize,
) -> usize {
    if !out_marks_count_ptr.is_null() {
        unsafe {
            *out_marks_count_ptr = 0;
        }
    }
    if frame_ptr.is_null() || frame_len < 9 + 165 {
        return 0;
    }
    let frame = unsafe { slice::from_raw_parts(frame_ptr, frame_len) };
    let decryptor = if !file_key_ptr.is_null()
        && file_key_len > 0
        && !nonce_ptr.is_null()
        && nonce_len > 0
    {
        let key = unsafe { slice::from_raw_parts(file_key_ptr, file_key_len) };
        let nonce = unsafe { slice::from_raw_parts(nonce_ptr, nonce_len) };
        AesCtrStreamDecrypt::new(key, nonce)
    } else {
        None
    };

    let batch = TransportSliceProcessor::unpack_frame(frame, decryptor.as_ref());
    if !out_opus_ptr.is_null() && out_opus_cap >= batch.opus_bytes.len() && !batch.opus_bytes.is_empty() {
        let out_opus = unsafe { slice::from_raw_parts_mut(out_opus_ptr, batch.opus_bytes.len()) };
        out_opus.copy_from_slice(&batch.opus_bytes);
    } else if !out_opus_ptr.is_null() && out_opus_cap > 0 && !batch.opus_bytes.is_empty() {
        let copy_len = (out_opus_cap / OPUS_FRAME_BYTES) * OPUS_FRAME_BYTES;
        let out_opus = unsafe { slice::from_raw_parts_mut(out_opus_ptr, copy_len) };
        out_opus.copy_from_slice(&batch.opus_bytes[..copy_len]);
    }
    if !out_marks_count_ptr.is_null() {
        unsafe {
            *out_marks_count_ptr = batch.marked_sequences.len();
        }
    }
    if !out_marks_ptr.is_null() && out_marks_cap > 0 && !batch.marked_sequences.is_empty() {
        let count = batch.marked_sequences.len().min(out_marks_cap);
        let out_marks = unsafe { slice::from_raw_parts_mut(out_marks_ptr, count) };
        out_marks.copy_from_slice(&batch.marked_sequences[..count]);
    }
    batch.slice_count
}

/// Derives `out_len` bytes via HKDF-SHA256 into `out_ptr`. Returns `1` on success, `0` on failure.
///
/// # Safety
///
/// Input pointers (`ikm_ptr`, `salt_ptr`, `info_ptr`) must be valid for reads of their
/// respective lengths when non-null, and `out_ptr` must be valid for writes of `out_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn koe_crypto_hkdf_sha256(
    ikm_ptr: *const u8,
    ikm_len: usize,
    salt_ptr: *const u8,
    salt_len: usize,
    info_ptr: *const u8,
    info_len: usize,
    out_ptr: *mut u8,
    out_len: usize,
) -> i32 {
    if out_ptr.is_null() || out_len == 0 {
        return 0;
    }
    let ikm = if ikm_ptr.is_null() || ikm_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(ikm_ptr, ikm_len) }
    };
    let salt = if salt_ptr.is_null() || salt_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(salt_ptr, salt_len) }
    };
    let info = if info_ptr.is_null() || info_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(info_ptr, info_len) }
    };
    let derived = DeviceCrypto::hkdf_sha256(ikm, salt, info, out_len);
    let out = unsafe { slice::from_raw_parts_mut(out_ptr, out_len) };
    out.copy_from_slice(&derived);
    1
}

/// Applies AES-128/192/256-CTR in place over `buf_ptr[0..buf_len]`. Returns `1` on success, `0` on bad key.
///
/// # Safety
///
/// `buf_ptr` must be valid for reads and writes of `buf_len` bytes; `key_ptr` and `iv_ptr`
/// must be valid for reads of `key_len` and `iv_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn koe_crypto_aes_ctr_in_place(
    buf_ptr: *mut u8,
    buf_len: usize,
    key_ptr: *const u8,
    key_len: usize,
    iv_ptr: *const u8,
    iv_len: usize,
) -> i32 {
    if buf_ptr.is_null() || key_ptr.is_null() || iv_ptr.is_null() {
        return 0;
    }
    let key = unsafe { slice::from_raw_parts(key_ptr, key_len) };
    let iv = unsafe { slice::from_raw_parts(iv_ptr, iv_len) };
    let Some(cipher) = koe_core::crypto::AesCipher::new(key) else {
        return 0;
    };
    let buf = unsafe { slice::from_raw_parts_mut(buf_ptr, buf_len) };
    cipher.apply_ctr_in_place(buf, iv);
    1
}

/// Decrypts one or more contiguous 160-byte D3200 audio chunks in place starting at `start_sequence`.
///
/// # Safety
///
/// `buf_ptr` must be valid for reads and writes of `buf_len` bytes; `file_key_ptr` and `nonce_ptr`
/// must be valid for reads of `file_key_len` and `nonce_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn koe_crypto_decrypt_chunks_in_place(
    buf_ptr: *mut u8,
    buf_len: usize,
    file_key_ptr: *const u8,
    file_key_len: usize,
    nonce_ptr: *const u8,
    nonce_len: usize,
    start_sequence: u32,
) -> i32 {
    if buf_ptr.is_null() || file_key_ptr.is_null() || nonce_ptr.is_null() {
        return 0;
    }
    let key = unsafe { slice::from_raw_parts(file_key_ptr, file_key_len) };
    let nonce = unsafe { slice::from_raw_parts(nonce_ptr, nonce_len) };
    let Some(stream) = AesCtrStreamDecrypt::new(key, nonce) else {
        return 0;
    };
    let buf = unsafe { slice::from_raw_parts_mut(buf_ptr, buf_len) };
    stream.decrypt_contiguous_in_place(buf, start_sequence);
    1
}

/// Computes the non-reflected Ogg CRC-32 (`0x04C11DB7`) over `data_ptr[0..data_len]`.
///
/// # Safety
///
/// `data_ptr` must be valid for reads of `data_len` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_ogg_crc32(data_ptr: *const u8, data_len: usize) -> u32 {
    if data_ptr.is_null() || data_len == 0 {
        return 0;
    }
    let data = unsafe { slice::from_raw_parts(data_ptr, data_len) };
    OggOpus::ogg_crc(data)
}

/// Muxes `raw_ptr[0..raw_len]` (concatenated 160-byte Opus frames) into an Ogg Opus
/// buffer allocated on the Rust heap. Stores the output length in `*out_len_ptr` and
/// returns the buffer pointer (freed via `koe_buffer_free`).
///
/// # Safety
///
/// `raw_ptr` must be valid for reads of `raw_len` bytes, and `out_len_ptr` must be valid
/// for writes of a `usize`.
#[no_mangle]
pub unsafe extern "C" fn koe_ogg_opus_mux_raw_frames(
    raw_ptr: *const u8,
    raw_len: usize,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    if raw_ptr.is_null() || raw_len == 0 || out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    let raw = unsafe { slice::from_raw_parts(raw_ptr, raw_len) };
    let mut muxed = OggOpus::mux_raw_frames(raw).into_boxed_slice();
    let len = muxed.len();
    let ptr = muxed.as_mut_ptr();
    std::mem::forget(muxed);
    unsafe {
        *out_len_ptr = len;
    }
    ptr
}

/// Frees a byte buffer previously returned by `koe_ogg_opus_mux_raw_frames`.
///
/// # Safety
///
/// `ptr` and `len` must exactly match a buffer allocated and returned by `koe_ogg_opus_mux_raw_frames`.
#[no_mangle]
pub unsafe extern "C" fn koe_buffer_free(ptr: *mut u8, len: usize) {
    if !ptr.is_null() && len > 0 {
        unsafe {
            let slice_ptr = std::ptr::slice_from_raw_parts_mut(ptr, len);
            drop(Box::from_raw(slice_ptr));
        }
    }
}

/// Writes the 44-byte RIFF/WAVE header for `pcm_length` bytes into `out_ptr`.
///
/// # Safety
///
/// `out_ptr` must be valid for writes of at least 44 bytes.
#[no_mangle]
pub unsafe extern "C" fn koe_wav_header(pcm_length: u32, out_ptr: *mut u8) -> i32 {
    if out_ptr.is_null() {
        return 0;
    }
    let hdr = OpusWave::wav_header(pcm_length);
    let out = unsafe { slice::from_raw_parts_mut(out_ptr, 44) };
    out.copy_from_slice(&hdr);
    1
}

/// Synthesizes a 48 kHz mono PCM16 preview WAV (`RIFF...`) with 880 Hz double-tap mark chimes
/// on the Rust heap. Stores the output byte length in `*out_len_ptr` and returns the buffer
/// pointer (freed via `koe_buffer_free`).
///
/// # Safety
///
/// `marks_ptr` must be valid for reads of `marks_len` `u64` items when non-null, and
/// `out_len_ptr` must be valid for writes of a `usize`.
#[no_mangle]
pub unsafe extern "C" fn koe_wav_build_audible_preview(
    duration_ms: u64,
    marks_ptr: *const u64,
    marks_len: usize,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    if out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    let marks = if marks_ptr.is_null() || marks_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(marks_ptr, marks_len) }
    };
    let mut wav = OpusWave::build_audible_preview_wav(duration_ms, marks).into_boxed_slice();
    let len = wav.len();
    let ptr = wav.as_mut_ptr();
    std::mem::forget(wav);
    unsafe {
        *out_len_ptr = len;
    }
    ptr
}

/// Decodes concatenated 160-byte D3200 Opus frames (`raw_ptr[0..raw_len]`) into
/// mono PCM16 LE bytes at `sample_rate` (`8000 | 12000 | 16000 | 24000 | 48000`)
/// using `libopus`. Stores the output byte length in `*out_len_ptr` and returns a
/// heap buffer (freed via `koe_buffer_free`), or null if decoding fails.
///
/// # Safety
///
/// `raw_ptr` must be valid for reads of `raw_len` bytes, and `out_len_ptr` must be
/// valid for writes of a `usize`.
#[no_mangle]
pub unsafe extern "C" fn koe_opus_decode_pcm16(
    raw_ptr: *const u8,
    raw_len: usize,
    sample_rate: u32,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    opus_ffi::ensure_opus_factory_registered();
    if raw_ptr.is_null() || raw_len == 0 || out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    let raw = unsafe { slice::from_raw_parts(raw_ptr, raw_len) };
    let Some(decoded) = OpusWave::decode_raw_frames_to_pcm16(raw, sample_rate, None) else {
        unsafe {
            *out_len_ptr = 0;
        }
        return std::ptr::null_mut();
    };
    let mut boxed = decoded.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_len_ptr = len;
    }
    ptr
}

/// Decodes concatenated 160-byte D3200 Opus frames (`raw_ptr[0..raw_len]`) into a
/// complete 44-byte RIFF/WAVE header + mono PCM16 LE payload at `sample_rate`
/// using `libopus`, overlaying 880 Hz mark chimes at `marks_ptr[0..marks_len]`.
/// Stores the output byte length in `*out_len_ptr` and returns a heap buffer
/// (freed via `koe_buffer_free`), or null if decoding fails.
///
/// # Safety
///
/// `raw_ptr` must be valid for reads of `raw_len` bytes, `marks_ptr` must be valid
/// for reads of `marks_len` `u64` items when non-null, and `out_len_ptr` must be
/// valid for writes of a `usize`.
#[no_mangle]
pub unsafe extern "C" fn koe_opus_decode_wav(
    raw_ptr: *const u8,
    raw_len: usize,
    sample_rate: u32,
    marks_ptr: *const u64,
    marks_len: usize,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    opus_ffi::ensure_opus_factory_registered();
    if raw_ptr.is_null() || raw_len == 0 || out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    let raw = unsafe { slice::from_raw_parts(raw_ptr, raw_len) };
    let marks = if marks_ptr.is_null() || marks_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(marks_ptr, marks_len) }
    };
    let Some(wav_vec) = OpusWave::decode_raw_frames_to_wav(raw, sample_rate, marks, None) else {
        unsafe {
            *out_len_ptr = 0;
        }
        return std::ptr::null_mut();
    };
    let mut boxed = wav_vec.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_len_ptr = len;
    }
    ptr
}

struct ReassemblerSlot {
    inner: FrameReassembler,
    queued: VecDeque<DecodedPacket>,
}

struct SessionSlot {
    inner: TransportSession,
    outbound_tx: VecDeque<Vec<u8>>,
}

static NEXT_HANDLE: AtomicU64 = AtomicU64::new(1);
static REASSEMBLER_REGISTRY: OnceLock<Mutex<BTreeMap<u64, ReassemblerSlot>>> = OnceLock::new();
static TRANSPORT_REGISTRY: OnceLock<Mutex<BTreeMap<u64, SessionSlot>>> = OnceLock::new();
static LIBRARY_REGISTRY: OnceLock<Mutex<BTreeMap<u64, RecordingLibrary>>> = OnceLock::new();
static SPINE_REGISTRY: OnceLock<Mutex<BTreeMap<u64, UtteranceSpine>>> = OnceLock::new();
static ROLLING_REGISTRY: OnceLock<Mutex<BTreeMap<u64, RollingMinutesScheduler>>> = OnceLock::new();

fn reassembler_map() -> &'static Mutex<BTreeMap<u64, ReassemblerSlot>> {
    REASSEMBLER_REGISTRY.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn session_map() -> &'static Mutex<BTreeMap<u64, SessionSlot>> {
    TRANSPORT_REGISTRY.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn library_map() -> &'static Mutex<BTreeMap<u64, RecordingLibrary>> {
    LIBRARY_REGISTRY.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn spine_map() -> &'static Mutex<BTreeMap<u64, UtteranceSpine>> {
    SPINE_REGISTRY.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn rolling_map() -> &'static Mutex<BTreeMap<u64, RollingMinutesScheduler>> {
    ROLLING_REGISTRY.get_or_init(|| Mutex::new(BTreeMap::new()))
}

pub(crate) fn alloc_handle() -> u64 {
    NEXT_HANDLE.fetch_add(1, Ordering::Relaxed)
}

/// Allocates a stateful `FrameReassembler` handle.
#[no_mangle]
pub extern "C" fn koe_reassembler_new() -> u64 {
    let h = alloc_handle();
    if let Ok(mut map) = reassembler_map().lock() {
        map.insert(
            h,
            ReassemblerSlot {
                inner: FrameReassembler::new(),
                queued: VecDeque::new(),
            },
        );
    }
    h
}

/// Frees a `FrameReassembler` handle.
#[no_mangle]
pub extern "C" fn koe_reassembler_free(handle: u64) {
    if let Ok(mut map) = reassembler_map().lock() {
        map.remove(&handle);
    }
}

/// Clears buffered bytes and queued packets in `FrameReassembler`.
#[no_mangle]
pub extern "C" fn koe_reassembler_reset(handle: u64) {
    if let Ok(mut map) = reassembler_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            slot.inner.reset();
            slot.queued.clear();
        }
    }
}

/// Returns the number of unconsumed tail bytes in `FrameReassembler`.
#[no_mangle]
pub extern "C" fn koe_reassembler_buffered_len(handle: u64) -> usize {
    if let Ok(map) = reassembler_map().lock() {
        if let Some(slot) = map.get(&handle) {
            return slot.inner.buffered_len();
        }
    }
    0
}

/// Feeds `chunk_ptr[0..chunk_len]` into `FrameReassembler` and returns the total number
/// of complete verified packets currently queued for `koe_reassembler_pop_packet`.
///
/// # Safety
///
/// `chunk_ptr` must be valid for reads of `chunk_len` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_reassembler_ingest(
    handle: u64,
    chunk_ptr: *const u8,
    chunk_len: usize,
) -> u32 {
    let chunk = if chunk_ptr.is_null() || chunk_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(chunk_ptr, chunk_len) }
    };
    if let Ok(mut map) = reassembler_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let pkts = slot.inner.ingest(chunk);
            slot.queued.extend(pkts);
            return slot.queued.len() as u32;
        }
    }
    0
}

/// Pops the next verified RX packet from `FrameReassembler`, writing its raw bytes into
/// `out_ptr[0..out_cap]`, its command type into `*out_cmd_type`, and its command ID into
/// `*out_cmd_id`. Returns the packet byte length (`0` if empty).
///
/// # Safety
///
/// `out_ptr` must be valid for writes of `out_cap` bytes when non-null, and `out_cmd_type` /
/// `out_cmd_id` must be valid mutable pointers when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_reassembler_pop_packet(
    handle: u64,
    out_ptr: *mut u8,
    out_cap: usize,
    out_cmd_type: *mut u8,
    out_cmd_id: *mut u8,
) -> usize {
    if let Ok(mut map) = reassembler_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            if let Some(pkt) = slot.queued.pop_front() {
                if !out_cmd_type.is_null() {
                    unsafe {
                        *out_cmd_type = pkt.cmd_type;
                    }
                }
                if !out_cmd_id.is_null() {
                    unsafe {
                        *out_cmd_id = pkt.cmd_id;
                    }
                }
                if !out_ptr.is_null() && out_cap >= pkt.raw.len() {
                    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, pkt.raw.len()) };
                    dst.copy_from_slice(&pkt.raw);
                }
                return pkt.raw.len();
            }
        }
    }
    0
}

/// Allocates a stateful `TransportSession` handle.
#[no_mangle]
pub extern "C" fn koe_session_new() -> u64 {
    opus_ffi::ensure_opus_factory_registered();
    let h = alloc_handle();
    if let Ok(mut map) = session_map().lock() {
        map.insert(
            h,
            SessionSlot {
                inner: TransportSession::new(),
                outbound_tx: VecDeque::new(),
            },
        );
    }
    h
}

/// Frees a `TransportSession` handle.
#[no_mangle]
pub extern "C" fn koe_session_free(handle: u64) {
    if let Ok(mut map) = session_map().lock() {
        map.remove(&handle);
    }
}

/// Resets active transfer buffers on `TransportSession`.
#[no_mangle]
pub extern "C" fn koe_session_reset_active_transfer(handle: u64) {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            slot.inner.reset_active_transfer();
        }
    }
}

/// Resets `TransportSession` on BLE disconnect.
#[no_mangle]
pub extern "C" fn koe_session_on_disconnected(handle: u64) {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            slot.inner.on_disconnected();
            slot.outbound_tx.clear();
        }
    }
}

/// Suspends an in-flight offline pull (preserving buffered slices for byte-offset resume)
/// or salvages buffered realtime slices when the BLE link drops unexpectedly.
#[no_mangle]
pub extern "C" fn koe_session_on_transport_interrupted(handle: u64) {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            slot.inner.on_transport_interrupted();
            slot.outbound_tx.clear();
        }
    }
}

/// Resumes a suspended or active offline pull from `received_slice_count() * 166` wire bytes
/// and writes the encoded `1A/07` TX frame into `out_tx_ptr[0..out_tx_cap]`, returning the
/// encoded frame byte length (`0` when no offline pull is resumable).
///
/// # Safety
///
/// `out_tx_ptr` must be valid for writes of `out_tx_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_resume_offline_pull(
    handle: u64,
    out_tx_ptr: *mut u8,
    out_tx_cap: usize,
) -> usize {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            if let Some(tx) = slot.inner.resume_offline_pull() {
                if !out_tx_ptr.is_null() && out_tx_cap >= tx.len() {
                    let dst = unsafe { slice::from_raw_parts_mut(out_tx_ptr, tx.len()) };
                    dst.copy_from_slice(&tx);
                }
                return tx.len();
            }
        }
    }
    0
}

/// Stops/pauses an active realtime bean recording (`0x18 0x82 [0x02]`), enters the 2,000 ms
/// quiet-drain window, queues outbound TX frames, and writes the step summary into `*out_step_ptr`.
///
/// # Safety
///
/// `out_step_ptr` must be valid for writes of one `KoeSessionStepResult`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_stop_realtime_recording(
    handle: u64,
    out_step_ptr: *mut KoeSessionStepResult,
) -> i32 {
    if out_step_ptr.is_null() {
        return 0;
    }
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let outcome = slot.inner.stop_realtime_recording();
            slot.outbound_tx
                .extend(outcome.outbound_tx_frames.iter().cloned());
            let step = fill_step_result(slot, &outcome);
            unsafe {
                *out_step_ptr = step;
            }
            return 1;
        }
    }
    0
}

/// Advances the 5,000 ms offline pull watchdog (up to 2 retries) and the 2,000 ms realtime
/// quiet-drain timer by `elapsed_ms`, writing the step summary into `*out_step_ptr`.
///
/// # Safety
///
/// `out_step_ptr` must be valid for writes of one `KoeSessionStepResult`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_poll_timers(
    handle: u64,
    elapsed_ms: u64,
    now_epoch_sec: u64,
    out_step_ptr: *mut KoeSessionStepResult,
) -> i32 {
    if out_step_ptr.is_null() {
        return 0;
    }
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let outcome = slot.inner.poll_timers(elapsed_ms, now_epoch_sec);
            slot.outbound_tx
                .extend(outcome.outbound_tx_frames.iter().cloned());
            let step = fill_step_result(slot, &outcome);
            unsafe {
                *out_step_ptr = step;
            }
            return 1;
        }
    }
    0
}

/// Verifies the `2E/01` ECDH reply payload against `secret_ptr[0..secret_len]` and derives
/// the 32-byte HKDF session key. Returns `1` on match, `0` on mismatch.
///
/// # Safety
///
/// `reply_ptr` and `secret_ptr` must be valid for reads of `reply_len` and `secret_len` bytes.
#[no_mangle]
pub unsafe extern "C" fn koe_session_accept_ecdh_reply(
    handle: u64,
    reply_ptr: *const u8,
    reply_len: usize,
    secret_ptr: *const u8,
    secret_len: usize,
) -> u8 {
    if reply_ptr.is_null() || secret_ptr.is_null() {
        return 0;
    }
    let reply = unsafe { slice::from_raw_parts(reply_ptr, reply_len) };
    let secret = unsafe { slice::from_raw_parts(secret_ptr, secret_len) };
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            return u8::from(slot.inner.accept_ecdh_reply(reply, secret));
        }
    }
    0
}

/// Prepares an offline file pull for `file_id` and writes the encoded `1A/07` TX frame into
/// `out_tx_ptr[0..out_tx_cap]`, returning the encoded frame byte length.
///
/// # Safety
///
/// `out_tx_ptr` must be valid for writes of `out_tx_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_begin_offline_pull(
    handle: u64,
    file_id: u32,
    duration_ms: u32,
    out_tx_ptr: *mut u8,
    out_tx_cap: usize,
) -> usize {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let tx = slot.inner.begin_offline_pull(file_id, duration_ms);
            if !out_tx_ptr.is_null() && out_tx_cap >= tx.len() {
                let dst = unsafe { slice::from_raw_parts_mut(out_tx_ptr, tx.len()) };
                dst.copy_from_slice(&tx);
            }
            return tx.len();
        }
    }
    0
}

fn fill_step_result(slot: &SessionSlot, outcome: &SessionIngestOutcome) -> KoeSessionStepResult {
    KoeSessionStepResult {
        frames_decoded: outcome.frames_decoded,
        connection_phase: slot.inner.connection_phase as u8,
        telemetry_updated: u8::from(outcome.telemetry_updated),
        session_key_established: u8::from(outcome.session_key_established),
        catalog_updated: u8::from(outcome.catalog_updated),
        transfer_updated: u8::from(outcome.transfer_updated),
        has_finalized_recording: u8::from(slot.inner.has_finalized_recording()),
        reserved: [0u8; 2],
        slices_unpacked_count: outcome.slices_unpacked_count,
        new_marks_count: outcome.new_marks_ms.len() as u32,
        outbound_tx_count: slot.outbound_tx.len() as u32,
        live_pcm16_bytes_available: slot.inner.live_pcm16_16khz.len() as u32,
        transfer: KoeTransferProgress::from_domain(&slot.inner.transfer),
    }
}

/// Ingests a raw BLE chunk into `TransportSession` and writes the step summary into `*out_step_ptr`.
///
/// # Safety
///
/// `chunk_ptr` must be valid for reads of `chunk_len` bytes when non-null, and `out_step_ptr`
/// must be valid for writes of one `KoeSessionStepResult`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_ingest_ble_chunk(
    handle: u64,
    chunk_ptr: *const u8,
    chunk_len: usize,
    now_epoch_sec: u64,
    out_step_ptr: *mut KoeSessionStepResult,
) -> i32 {
    if out_step_ptr.is_null() {
        return 0;
    }
    let chunk = if chunk_ptr.is_null() || chunk_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(chunk_ptr, chunk_len) }
    };
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let outcome = slot.inner.ingest_ble_chunk(chunk, now_epoch_sec);
            slot.outbound_tx.extend(outcome.outbound_tx_frames.iter().cloned());
            let step = fill_step_result(slot, &outcome);
            unsafe {
                *out_step_ptr = step;
            }
            return 1;
        }
    }
    0
}

/// Pops the next queued outbound TX frame from `TransportSession` into `out_ptr[0..out_cap]`.
///
/// # Safety
///
/// `out_ptr` must be valid for writes of `out_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_pop_outbound_tx(
    handle: u64,
    out_ptr: *mut u8,
    out_cap: usize,
) -> usize {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            if let Some(tx) = slot.outbound_tx.pop_front() {
                if !out_ptr.is_null() && out_cap >= tx.len() {
                    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, tx.len()) };
                    dst.copy_from_slice(&tx);
                }
                return tx.len();
            }
        }
    }
    0
}

/// Writes the latest `01/01` device telemetry from `TransportSession` into `*out_ptr`.
/// Returns `1` when telemetry is available, `0` otherwise.
///
/// # Safety
///
/// `out_ptr` must be valid for writes of one `KoeDeviceInfo`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_get_telemetry(
    handle: u64,
    out_ptr: *mut KoeDeviceInfo,
) -> u8 {
    if out_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = session_map().lock() {
        if let Some(slot) = map.get(&handle) {
            if let Some(tel) = &slot.inner.telemetry {
                unsafe {
                    *out_ptr = KoeDeviceInfo::from_model(tel);
                }
                return 1;
            }
        }
    }
    0
}

/// Writes up to `out_entries_cap` catalog items from `TransportSession` into `out_entries_ptr`.
/// Returns the total number of catalog entries.
///
/// # Safety
///
/// `out_entries_ptr` must be valid for writes of `out_entries_cap` items when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_get_catalog(
    handle: u64,
    out_entries_ptr: *mut KoeOfflineFileEntry,
    out_entries_cap: usize,
) -> usize {
    if let Ok(map) = session_map().lock() {
        if let Some(slot) = map.get(&handle) {
            let total = slot.inner.catalog.len();
            if !out_entries_ptr.is_null() && out_entries_cap > 0 {
                let count = total.min(out_entries_cap);
                let dst = unsafe { slice::from_raw_parts_mut(out_entries_ptr, count) };
                for (d, s) in dst.iter_mut().zip(slot.inner.catalog.iter().take(count)) {
                    *d = KoeOfflineFileEntry {
                        file_id: s.file_id,
                        duration_ms: s.duration_ms,
                        has_end_time: u8::from(s.end_time.is_some()),
                        reserved: [0u8; 3],
                        end_time: s.end_time.unwrap_or(0),
                    };
                }
            }
            return total;
        }
    }
    0
}

/// Writes the current transfer progress of `TransportSession` into `*out_ptr`.
///
/// # Safety
///
/// `out_ptr` must be valid for writes of one `KoeTransferProgress`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_get_transfer(
    handle: u64,
    out_ptr: *mut KoeTransferProgress,
) -> i32 {
    if out_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = session_map().lock() {
        if let Some(slot) = map.get(&handle) {
            unsafe {
                *out_ptr = KoeTransferProgress::from_domain(&slot.inner.transfer);
            }
            return 1;
        }
    }
    0
}

/// Explicitly finalizes the active stream in `TransportSession`. Returns `1` if a recording
/// was finalized, `0` otherwise.
#[no_mangle]
pub extern "C" fn koe_session_finalize_active_transfer(handle: u64, now_epoch_sec: u64) -> u8 {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            return u8::from(slot.inner.finalize_active_transfer(now_epoch_sec).is_some());
        }
    }
    0
}

/// Runs the deterministic closed-loop `01/01` + `1A/07` + 60-slice `1A/08` simulation on
/// `TransportSession` and populates `*out_step_ptr`. Returns `1` on success.
///
/// # Safety
///
/// `out_step_ptr` must be valid for writes of one `KoeSessionStepResult` when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_simulate_realtime_pipeline(
    handle: u64,
    now_epoch_sec: u64,
    out_step_ptr: *mut KoeSessionStepResult,
) -> u8 {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let fin = slot.inner.simulate_realtime_pipeline(now_epoch_sec);
            let outcome = SessionIngestOutcome {
                frames_decoded: 3,
                telemetry_updated: true,
                session_key_established: true,
                catalog_updated: false,
                transfer_updated: true,
                slices_unpacked_count: 60,
                new_marks_ms: fin.entry.marks_ms.clone(),
                live_pcm16_16khz: slot.inner.live_pcm16_16khz.clone(),
                finalized: Some(fin),
                outbound_tx_frames: Vec::new(),
            };
            if !out_step_ptr.is_null() {
                unsafe {
                    *out_step_ptr = fill_step_result(slot, &outcome);
                }
            }
            return 1;
        }
    }
    0
}

/// Drains buffered 16 kHz mono PCM16 LE bytes decoded incrementally during
/// `koe_session_ingest_ble_chunk` or `koe_session_simulate_realtime_pipeline`,
/// storing the byte length in `*out_len_ptr` and returning a heap buffer
/// (freed via `koe_buffer_free`), or null if empty.
///
/// # Safety
///
/// `out_len_ptr` must be valid for writes of a `usize`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_take_live_pcm16(
    handle: u64,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    if out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let pcm = slot.inner.take_live_pcm16();
            if !pcm.is_empty() {
                let mut boxed = pcm.into_boxed_slice();
                let len = boxed.len();
                let ptr = boxed.as_mut_ptr();
                std::mem::forget(boxed);
                unsafe {
                    *out_len_ptr = len;
                }
                return ptr;
            }
        }
    }
    unsafe {
        *out_len_ptr = 0;
    }
    std::ptr::null_mut()
}

/// Takes the most recently finalized recording from `TransportSession`, writing metadata into
/// `*out_entry_ptr` and allocating Ogg Opus and preview WAV buffers (freed via `koe_buffer_free`).
/// Returns `1` when a finalized recording was taken, `0` otherwise.
///
/// # Safety
///
/// Output pointers must be valid mutable pointers when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_take_finalized(
    handle: u64,
    out_entry_ptr: *mut KoeRecordingEntry,
    out_ogg_ptr: *mut *mut u8,
    out_ogg_len_ptr: *mut usize,
    out_wav_ptr: *mut *mut u8,
    out_wav_len_ptr: *mut usize,
) -> u8 {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            if let Some(fin) = slot.inner.take_next_finalized() {
                if !out_entry_ptr.is_null() {
                    unsafe {
                        *out_entry_ptr = KoeRecordingEntry::from_domain(&fin.entry);
                    }
                }
                if !out_ogg_ptr.is_null() && !out_ogg_len_ptr.is_null() {
                    let mut ogg = fin.ogg_opus_bytes.into_boxed_slice();
                    let len = ogg.len();
                    let ptr = ogg.as_mut_ptr();
                    std::mem::forget(ogg);
                    unsafe {
                        *out_ogg_ptr = ptr;
                        *out_ogg_len_ptr = len;
                    }
                }
                if !out_wav_ptr.is_null() && !out_wav_len_ptr.is_null() {
                    let mut wav = fin.preview_wav_bytes.into_boxed_slice();
                    let len = wav.len();
                    let ptr = wav.as_mut_ptr();
                    std::mem::forget(wav);
                    unsafe {
                        *out_wav_ptr = ptr;
                        *out_wav_len_ptr = len;
                    }
                }
                return 1;
            }
        }
    }
    0
}

/// Parses a `0x1A / 0x05` Wi-Fi SoftAP configuration response frame (`raw_ptr[0..raw_len]`)
/// into `*out_endpoint_ptr`. Returns `1` on valid success response, `0` otherwise.
///
/// # Safety
///
/// `raw_ptr` must be valid for reads of `raw_len` bytes when non-null, and `out_endpoint_ptr`
/// must be valid for writes of one `KoeWifiEndpoint`.
#[no_mangle]
pub unsafe extern "C" fn koe_wifi_parse_config_response(
    raw_ptr: *const u8,
    raw_len: usize,
    out_endpoint_ptr: *mut KoeWifiEndpoint,
) -> u8 {
    if raw_ptr.is_null() || raw_len < 15 || out_endpoint_ptr.is_null() {
        return 0;
    }
    let raw = unsafe { slice::from_raw_parts(raw_ptr, raw_len) };
    let Some(ep) = WifiEndpoint::parse_config_response(raw) else {
        return 0;
    };
    unsafe {
        *out_endpoint_ptr = KoeWifiEndpoint {
            ip: ep.ip,
            port: ep.port,
            reserved: [0u8; 2],
        };
    }
    1
}

/// Returns `1` when `device_ip_ptr[0..4]` and `local_ip_ptr[0..4]` share the same `/24` IPv4
/// subnet with distinct host octets, `0` otherwise.
///
/// # Safety
///
/// `device_ip_ptr` and `local_ip_ptr` must be valid for reads of 4 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_wifi_shares_subnet(
    device_ip_ptr: *const u8,
    local_ip_ptr: *const u8,
) -> u8 {
    if device_ip_ptr.is_null() || local_ip_ptr.is_null() {
        return 0;
    }
    let dev = unsafe { slice::from_raw_parts(device_ip_ptr, 4) };
    let loc = unsafe { slice::from_raw_parts(local_ip_ptr, 4) };
    u8::from(WifiEndpoint::shares_ipv4_subnet(
        [dev[0], dev[1], dev[2], dev[3]],
        [loc[0], loc[1], loc[2], loc[3]],
    ))
}

/// Writes the 36-character lowercase hex string for a Wi-Fi WebSocket `0x1A / 0x07` file
/// request into `out_ptr[0..out_cap]`. Returns `36` on success, `0` on insufficient capacity.
///
/// # Safety
///
/// `out_ptr` must be valid for writes of `out_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_wifi_build_file_request_hex(
    file_id: u32,
    already_transferred: u32,
    out_ptr: *mut u8,
    out_cap: usize,
) -> usize {
    let hex = DeviceCommands::build_wifi_file_request_hex(file_id, already_transferred);
    let bytes = hex.as_bytes();
    if out_ptr.is_null() || out_cap < bytes.len() {
        return 0;
    }
    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, bytes.len()) };
    dst.copy_from_slice(bytes);
    bytes.len()
}

/// Writes the 22-character lowercase hex string for a Wi-Fi WebSocket `0x1A / 0x0A` transfer-complete
/// command into `out_ptr[0..out_cap]`. Returns `22` on success, `0` on insufficient capacity.
///
/// # Safety
///
/// `out_ptr` must be valid for writes of `out_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_wifi_build_transfer_complete_hex(
    out_ptr: *mut u8,
    out_cap: usize,
) -> usize {
    let hex = DeviceCommands::wifi_transfer_complete_hex();
    let bytes = hex.as_bytes();
    if out_ptr.is_null() || out_cap < bytes.len() {
        return 0;
    }
    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, bytes.len()) };
    dst.copy_from_slice(bytes);
    bytes.len()
}

/// Writes the 28-byte UDP `:32003` keep-alive payload (`"soundcore-keep-alive-unicast"`) into
/// `out_ptr[0..out_cap]`. Returns `28` on success, `0` on insufficient capacity.
///
/// # Safety
///
/// `out_ptr` must be valid for writes of `out_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_wifi_keepalive_payload(out_ptr: *mut u8, out_cap: usize) -> usize {
    if out_ptr.is_null() || out_cap < WIFI_KEEPALIVE_PAYLOAD.len() {
        return 0;
    }
    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, WIFI_KEEPALIVE_PAYLOAD.len()) };
    dst.copy_from_slice(WIFI_KEEPALIVE_PAYLOAD);
    WIFI_KEEPALIVE_PAYLOAD.len()
}

/// Starts a Wi-Fi SoftAP batch transfer for `file_ids_ptr[0..file_count]` on `TransportSession`.
/// Returns `1` on success, `0` on invalid handle.
///
/// # Safety
///
/// `file_ids_ptr` must be valid for reads of `file_count` `u32` elements when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_begin_wifi_batch(
    handle: u64,
    file_ids_ptr: *const u32,
    file_count: usize,
) -> u8 {
    let ids = if file_ids_ptr.is_null() || file_count == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(file_ids_ptr, file_count) }
    };
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            slot.inner.begin_wifi_batch(ids);
            return 1;
        }
    }
    0
}

/// Ingests a raw Wi-Fi SoftAP chunk (WebSocket text/binary frame or UDP `:32003` datagram) into
/// `TransportSession` and writes the step summary into `*out_step_ptr`.
///
/// # Safety
///
/// `chunk_ptr` must be valid for reads of `chunk_len` bytes when non-null, and `out_step_ptr`
/// must be valid for writes of one `KoeSessionStepResult`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_ingest_wifi_chunk(
    handle: u64,
    chunk_ptr: *const u8,
    chunk_len: usize,
    now_epoch_sec: u64,
    out_step_ptr: *mut KoeSessionStepResult,
) -> i32 {
    if out_step_ptr.is_null() {
        return 0;
    }
    let chunk = if chunk_ptr.is_null() || chunk_len == 0 {
        &[][..]
    } else {
        unsafe { slice::from_raw_parts(chunk_ptr, chunk_len) }
    };
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            let outcome = slot.inner.ingest_wifi_chunk(chunk, now_epoch_sec);
            slot.outbound_tx
                .extend(outcome.outbound_tx_frames.iter().cloned());
            let step = fill_step_result(slot, &outcome);
            unsafe {
                *out_step_ptr = step;
            }
            return 1;
        }
    }
    0
}

/// Pops the next queued outbound WebSocket text message from `TransportSession` into
/// `out_ptr[0..out_cap]`. Returns the UTF-8 byte length (`0` when empty).
///
/// # Safety
///
/// `out_ptr` must be valid for writes of `out_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_pop_outbound_wifi_ws(
    handle: u64,
    out_ptr: *mut u8,
    out_cap: usize,
) -> usize {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            if let Some(msg) = slot.inner.pop_outbound_wifi_ws() {
                let bytes = msg.as_bytes();
                if !out_ptr.is_null() && out_cap >= bytes.len() {
                    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, bytes.len()) };
                    dst.copy_from_slice(bytes);
                }
                return bytes.len();
            }
        }
    }
    0
}

/// Pops the next queued outbound UDP `:32003` datagram from `TransportSession` into
/// `out_ptr[0..out_cap]`. Returns the datagram byte length (`0` when empty).
///
/// # Safety
///
/// `out_ptr` must be valid for writes of `out_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_session_pop_outbound_wifi_udp(
    handle: u64,
    out_ptr: *mut u8,
    out_cap: usize,
) -> usize {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            if let Some(pkt) = slot.inner.pop_outbound_wifi_udp() {
                if !out_ptr.is_null() && out_cap >= pkt.len() {
                    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, pkt.len()) };
                    dst.copy_from_slice(&pkt);
                }
                return pkt.len();
            }
        }
    }
    0
}

/// Writes the current `KoeWifiBatchProgress` snapshot of `TransportSession` into `*out_progress_ptr`.
///
/// # Safety
///
/// `out_progress_ptr` must be valid for writes of one `KoeWifiBatchProgress`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_get_wifi_batch_progress(
    handle: u64,
    out_progress_ptr: *mut KoeWifiBatchProgress,
) -> i32 {
    if out_progress_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = session_map().lock() {
        if let Some(slot) = map.get(&handle) {
            let p = slot.inner.wifi_batch_progress();
            unsafe {
                *out_progress_ptr = KoeWifiBatchProgress::from_domain(&p);
            }
            return 1;
        }
    }
    0
}

/// Writes the most recently parsed `0x1A / 0x05` `KoeWifiEndpoint` from `TransportSession`
/// into `*out_endpoint_ptr`. Returns `1` when an endpoint is available, `0` otherwise.
///
/// # Safety
///
/// `out_endpoint_ptr` must be valid for writes of one `KoeWifiEndpoint`.
#[no_mangle]
pub unsafe extern "C" fn koe_session_get_wifi_endpoint(
    handle: u64,
    out_endpoint_ptr: *mut KoeWifiEndpoint,
) -> u8 {
    if out_endpoint_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = session_map().lock() {
        if let Some(slot) = map.get(&handle) {
            if let Some(ep) = slot.inner.wifi_endpoint {
                unsafe {
                    *out_endpoint_ptr = KoeWifiEndpoint {
                        ip: ep.ip,
                        port: ep.port,
                        reserved: [0u8; 2],
                    };
                }
                return 1;
            }
        }
    }
    0
}

/// Handles an unexpected Wi-Fi hotspot drop or socket error on `TransportSession`, salvaging
/// any active file with `>= 95%` received wire bytes. Returns `1` if a file was salvaged, `0` otherwise.
#[no_mangle]
pub extern "C" fn koe_session_on_wifi_interrupted(handle: u64, now_epoch_sec: u64) -> u8 {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            return u8::from(slot.inner.on_wifi_interrupted(now_epoch_sec));
        }
    }
    0
}

/// Resumes an interrupted Wi-Fi batch from the current unexported file index on `TransportSession`.
/// Returns `1` if resumed, `0` otherwise.
#[no_mangle]
pub extern "C" fn koe_session_resume_wifi_batch(handle: u64) -> u8 {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            return u8::from(slot.inner.resume_wifi_batch());
        }
    }
    0
}

/// Cancels any active or interrupted Wi-Fi batch on `TransportSession`.
#[no_mangle]
pub extern "C" fn koe_session_cancel_wifi_batch(handle: u64) {
    if let Ok(mut map) = session_map().lock() {
        if let Some(slot) = map.get_mut(&handle) {
            slot.inner.cancel_wifi_batch();
        }
    }
}

/// Allocates a stateful `RecordingLibrary` handle.
#[no_mangle]
pub extern "C" fn koe_library_new() -> u64 {
    let h = alloc_handle();
    if let Ok(mut map) = library_map().lock() {
        map.insert(h, RecordingLibrary::new());
    }
    h
}

/// Frees a `RecordingLibrary` handle.
#[no_mangle]
pub extern "C" fn koe_library_free(handle: u64) {
    if let Ok(mut map) = library_map().lock() {
        map.remove(&handle);
    }
}

/// Writes the current `KoeLibrarySnapshot` into `*out_snapshot_ptr`.
///
/// # Safety
///
/// `out_snapshot_ptr` must be valid for writes of one `KoeLibrarySnapshot`.
#[no_mangle]
pub unsafe extern "C" fn koe_library_snapshot(
    handle: u64,
    out_snapshot_ptr: *mut KoeLibrarySnapshot,
) -> i32 {
    if out_snapshot_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = library_map().lock() {
        if let Some(lib) = map.get(&handle) {
            unsafe {
                *out_snapshot_ptr = KoeLibrarySnapshot {
                    entry_count: lib.entries.len() as u32,
                    selected_recording_id: lib.selected_id.unwrap_or(0),
                    playhead_ms: lib.position_ms,
                    has_last_trashed: u8::from(lib.trashed_entry.is_some()),
                    reserved: [0u8; 7],
                    last_trashed_id: lib.trashed_entry.as_ref().map_or(0, |t| t.id),
                    pad_tail: 0,
                };
            }
            return 1;
        }
    }
    0
}

/// Writes up to `out_entries_cap` `KoeRecordingEntry` items from `RecordingLibrary` into `out_entries_ptr`.
/// Returns the total number of entries in the library.
///
/// # Safety
///
/// `out_entries_ptr` must be valid for writes of `out_entries_cap` items when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_library_get_entries(
    handle: u64,
    out_entries_ptr: *mut KoeRecordingEntry,
    out_entries_cap: usize,
) -> usize {
    if let Ok(map) = library_map().lock() {
        if let Some(lib) = map.get(&handle) {
            let total = lib.entries.len();
            if !out_entries_ptr.is_null() && out_entries_cap > 0 {
                let count = total.min(out_entries_cap);
                let dst = unsafe { slice::from_raw_parts_mut(out_entries_ptr, count) };
                for (d, s) in dst.iter_mut().zip(lib.entries.iter().take(count)) {
                    *d = KoeRecordingEntry::from_domain(s);
                }
            }
            return total;
        }
    }
    0
}

/// Writes the currently selected `KoeRecordingEntry` into `*out_entry_ptr`.
/// Returns `1` when an entry is selected, `0` otherwise.
///
/// # Safety
///
/// `out_entry_ptr` must be valid for writes of one `KoeRecordingEntry`.
#[no_mangle]
pub unsafe extern "C" fn koe_library_get_selected(
    handle: u64,
    out_entry_ptr: *mut KoeRecordingEntry,
) -> u8 {
    if out_entry_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = library_map().lock() {
        if let Some(lib) = map.get(&handle) {
            if let Some(sel) = lib.selected_entry() {
                unsafe {
                    *out_entry_ptr = KoeRecordingEntry::from_domain(sel);
                }
                return 1;
            }
        }
    }
    0
}

/// Ingests `*entry_ptr` into `RecordingLibrary` and selects it.
///
/// # Safety
///
/// `entry_ptr` must be valid for reads of one `KoeRecordingEntry`.
#[no_mangle]
pub unsafe extern "C" fn koe_library_ingest_entry(
    handle: u64,
    entry_ptr: *const KoeRecordingEntry,
) -> i32 {
    if entry_ptr.is_null() {
        return 0;
    }
    let entry = unsafe { (*entry_ptr).to_domain() };
    if let Ok(mut map) = library_map().lock() {
        if let Some(lib) = map.get_mut(&handle) {
            lib.ingest(entry);
            return 1;
        }
    }
    0
}

/// Ingests a disk audio file by filename into `RecordingLibrary` and writes the resulting
/// `KoeRecordingEntry` into `*out_entry_ptr` when non-null. Returns `1` if ingested.
///
/// # Safety
///
/// `filename_ptr` must be valid for reads of `filename_len` UTF-8 bytes, and `out_entry_ptr`
/// must be valid for writes of one `KoeRecordingEntry` when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_library_ingest_disk_file(
    handle: u64,
    filename_ptr: *const u8,
    filename_len: usize,
    byte_count: u32,
    created_at_epoch_sec: u64,
    out_entry_ptr: *mut KoeRecordingEntry,
) -> u8 {
    if filename_ptr.is_null() || filename_len == 0 {
        return 0;
    }
    let bytes = unsafe { slice::from_raw_parts(filename_ptr, filename_len) };
    let Ok(filename) = std::str::from_utf8(bytes) else {
        return 0;
    };
    let stem = filename
        .rsplit('/')
        .next()
        .unwrap_or(filename)
        .strip_suffix(".opus")
        .or_else(|| filename.strip_suffix(".wav"))
        .unwrap_or(filename);
    let digits = stem.strip_prefix("koe_rec_").unwrap_or(stem);
    let id = digits.parse::<u32>().unwrap_or_else(|_| {
        let mut h = 2166136261u32;
        for &b in stem.as_bytes() {
            h ^= u32::from(b);
            h = h.wrapping_mul(16777619);
        }
        h.max(1)
    });
    if let Ok(mut map) = library_map().lock() {
        if let Some(lib) = map.get_mut(&handle) {
            if lib.entries.iter().any(|e| e.id == id) {
                return 0;
            }
            lib.ingest_disk_file(id, byte_count, created_at_epoch_sec, &[300, 900]);
            if !out_entry_ptr.is_null() {
                if let Some(entry) = lib.entries.iter().find(|e| e.id == id) {
                    unsafe {
                        *out_entry_ptr = KoeRecordingEntry::from_domain(entry);
                    }
                }
            }
            return 1;
        }
    }
    0
}

/// Selects `recording_id` in `RecordingLibrary`, resets playhead to `0`, and returns `1` if found.
///
/// # Safety
///
/// `out_playhead_ms_ptr` must be valid for writes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_library_select(
    handle: u64,
    recording_id: u32,
    out_playhead_ms_ptr: *mut u64,
) -> u8 {
    if let Ok(mut map) = library_map().lock() {
        if let Some(lib) = map.get_mut(&handle) {
            let ok = lib.select(recording_id);
            if ok && !out_playhead_ms_ptr.is_null() {
                unsafe {
                    *out_playhead_ms_ptr = lib.position_ms;
                }
            }
            return u8::from(ok);
        }
    }
    0
}

/// Clamps and updates the playhead position in milliseconds for the selected recording.
#[no_mangle]
pub extern "C" fn koe_library_seek_ms(handle: u64, position_ms: u64) -> u64 {
    if let Ok(mut map) = library_map().lock() {
        if let Some(lib) = map.get_mut(&handle) {
            return lib.seek_ms(position_ms);
        }
    }
    0
}

/// Computes the next (`direction >= 0`) or previous (`direction < 0`) mark position with
/// 50 ms hysteresis and wrap-around, updates `position_ms`, and writes the target into
/// `*out_target_ms_ptr`. Returns `1` when the selected recording has marks, `0` otherwise.
///
/// # Safety
///
/// `out_target_ms_ptr` must be valid for writes of one `u64`.
#[no_mangle]
pub unsafe extern "C" fn koe_library_jump_to_mark(
    handle: u64,
    current_ms: u64,
    direction: i32,
    out_target_ms_ptr: *mut u64,
) -> u8 {
    if out_target_ms_ptr.is_null() {
        return 0;
    }
    if let Ok(mut map) = library_map().lock() {
        if let Some(lib) = map.get_mut(&handle) {
            let has_marks = lib
                .selected_entry()
                .is_some_and(|e| !e.marks_ms.is_empty());
            if !has_marks {
                return 0;
            }
            lib.position_ms = current_ms;
            let target = lib.jump_to_mark(direction >= 0);
            unsafe {
                *out_target_ms_ptr = target;
            }
            return 1;
        }
    }
    0
}

/// Moves `recording_id` to `trashed_entry` for non-modal Undo and writes the trashed entry
/// into `*out_trashed_ptr` when non-null. Returns `1` if removed.
///
/// # Safety
///
/// `out_trashed_ptr` must be valid for writes of one `KoeRecordingEntry` when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_library_move_to_trash(
    handle: u64,
    recording_id: u32,
    out_trashed_ptr: *mut KoeRecordingEntry,
) -> u8 {
    if let Ok(mut map) = library_map().lock() {
        if let Some(lib) = map.get_mut(&handle) {
            if lib.move_to_trash(recording_id) {
                if !out_trashed_ptr.is_null() {
                    if let Some(removed) = &lib.trashed_entry {
                        unsafe {
                            *out_trashed_ptr = KoeRecordingEntry::from_domain(removed);
                        }
                    }
                }
                return 1;
            }
        }
    }
    0
}

/// Restores `trashed_entry` into `RecordingLibrary`, selects it, and writes the restored entry
/// into `*out_restored_ptr` when non-null. Returns `1` if restored.
///
/// # Safety
///
/// `out_restored_ptr` must be valid for writes of one `KoeRecordingEntry` when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_library_undo_trash(
    handle: u64,
    out_restored_ptr: *mut KoeRecordingEntry,
) -> u8 {
    if let Ok(mut map) = library_map().lock() {
        if let Some(lib) = map.get_mut(&handle) {
            if lib.undo_trash() {
                if !out_restored_ptr.is_null() {
                    if let Some(restored) = lib.selected_entry() {
                        unsafe {
                            *out_restored_ptr = KoeRecordingEntry::from_domain(restored);
                        }
                    }
                }
                return 1;
            }
        }
    }
    0
}

/// Allocates a stateful `UtteranceSpine` handle (`S1..Sn`).
///
/// # Safety
///
/// `session_id_ptr` must be valid for reads of `session_id_len` UTF-8 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_new(
    session_id_ptr: *const u8,
    session_id_len: usize,
) -> u64 {
    let session_id = if session_id_ptr.is_null() || session_id_len == 0 {
        "default"
    } else {
        let bytes = unsafe { slice::from_raw_parts(session_id_ptr, session_id_len) };
        std::str::from_utf8(bytes).unwrap_or("default")
    };
    let h = alloc_handle();
    if let Ok(mut map) = spine_map().lock() {
        map.insert(h, UtteranceSpine::new(session_id));
    }
    h
}

/// Frees an `UtteranceSpine` handle.
#[no_mangle]
pub extern "C" fn koe_spine_free(handle: u64) {
    if let Ok(mut map) = spine_map().lock() {
        map.remove(&handle);
    }
}

/// Clears the stale flag on `UtteranceSpine`.
#[no_mangle]
pub extern "C" fn koe_spine_clear_stale(handle: u64) {
    if let Ok(mut map) = spine_map().lock() {
        if let Some(spine) = map.get_mut(&handle) {
            spine.clear_stale();
        }
    }
}

/// Writes the current `KoeUtteranceSpineSnapshot` into `*out_snapshot_ptr`.
/// Returns `1` on valid handle, `0` otherwise.
///
/// # Safety
///
/// `out_snapshot_ptr` must be valid for writes of one `KoeUtteranceSpineSnapshot`.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_snapshot(
    handle: u64,
    out_snapshot_ptr: *mut KoeUtteranceSpineSnapshot,
) -> i32 {
    if out_snapshot_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = spine_map().lock() {
        if let Some(spine) = map.get(&handle) {
            unsafe {
                *out_snapshot_ptr = KoeUtteranceSpineSnapshot {
                    segment_count: spine.len() as u32,
                    is_stale: u8::from(spine.is_stale()),
                    reserved: [0u8; 3],
                    revision: spine.revision(),
                };
            }
            return 1;
        }
    }
    0
}

/// Appends a finalized segment to `UtteranceSpine` and returns its 1-based ordinal (`1..=n`),
/// or `0` if `text` is empty or the handle is invalid.
///
/// # Safety
///
/// `text_ptr`, `source_lang_ptr`, and `provider_ptr` must be valid for reads of their
/// respective byte lengths when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_append_segment(
    handle: u64,
    text_ptr: *const u8,
    text_len: usize,
    start_ms: u64,
    end_ms: u64,
    source_lang_ptr: *const u8,
    source_lang_len: usize,
    provider_ptr: *const u8,
    provider_len: usize,
) -> u32 {
    if text_ptr.is_null() || text_len == 0 {
        return 0;
    }
    let text_bytes = unsafe { slice::from_raw_parts(text_ptr, text_len) };
    let Ok(text) = std::str::from_utf8(text_bytes) else {
        return 0;
    };
    let source_lang = if source_lang_ptr.is_null() || source_lang_len == 0 {
        "zh"
    } else {
        let b = unsafe { slice::from_raw_parts(source_lang_ptr, source_lang_len) };
        std::str::from_utf8(b).unwrap_or("zh")
    };
    let provider = if provider_ptr.is_null() || provider_len == 0 {
        "qwen"
    } else {
        let b = unsafe { slice::from_raw_parts(provider_ptr, provider_len) };
        std::str::from_utf8(b).unwrap_or("qwen")
    };
    if let Ok(mut map) = spine_map().lock() {
        if let Some(spine) = map.get_mut(&handle) {
            return spine
                .append_segment(text, start_ms, end_ms, source_lang, provider)
                .map_or(0, SegmentId::ordinal);
        }
    }
    0
}

/// Accepts cumulative ASR text for `connection_id` on `UtteranceSpine`, stripping any
/// previously confirmed prefix and returning the latest 1-based ordinal (`1..=n`), or `0`.
///
/// # Safety
///
/// All non-null byte pointers must be valid for reads of their respective byte lengths.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_accept_cumulative(
    handle: u64,
    conn_id_ptr: *const u8,
    conn_id_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    source_lang_ptr: *const u8,
    source_lang_len: usize,
    translation_ptr: *const u8,
    translation_len: usize,
    target_lang_ptr: *const u8,
    target_lang_len: usize,
    provider_ptr: *const u8,
    provider_len: usize,
) -> u32 {
    if text_ptr.is_null() || text_len == 0 {
        return 0;
    }
    let conn_id = if conn_id_ptr.is_null() || conn_id_len == 0 {
        "default"
    } else {
        let b = unsafe { slice::from_raw_parts(conn_id_ptr, conn_id_len) };
        std::str::from_utf8(b).unwrap_or("default")
    };
    let text_b = unsafe { slice::from_raw_parts(text_ptr, text_len) };
    let Ok(text) = std::str::from_utf8(text_b) else {
        return 0;
    };
    let source_lang = if source_lang_ptr.is_null() || source_lang_len == 0 {
        "zh"
    } else {
        let b = unsafe { slice::from_raw_parts(source_lang_ptr, source_lang_len) };
        std::str::from_utf8(b).unwrap_or("zh")
    };
    let translation = if translation_ptr.is_null() || translation_len == 0 {
        None
    } else {
        let b = unsafe { slice::from_raw_parts(translation_ptr, translation_len) };
        std::str::from_utf8(b).ok()
    };
    let target_lang = if target_lang_ptr.is_null() || target_lang_len == 0 {
        None
    } else {
        let b = unsafe { slice::from_raw_parts(target_lang_ptr, target_lang_len) };
        std::str::from_utf8(b).ok()
    };
    let provider = if provider_ptr.is_null() || provider_len == 0 {
        "qwen"
    } else {
        let b = unsafe { slice::from_raw_parts(provider_ptr, provider_len) };
        std::str::from_utf8(b).unwrap_or("qwen")
    };
    if let Ok(mut map) = spine_map().lock() {
        if let Some(spine) = map.get_mut(&handle) {
            return spine
                .accept_cumulative(conn_id, text, source_lang, translation, target_lang, provider)
                .map_or(0, SegmentId::ordinal);
        }
    }
    0
}

/// Updates the text of 1-based segment `ordinal` (`S1..Sn`), incrementing its revision,
/// clearing any stale translation, and marking the spine stale. Returns `1` if updated, `0` otherwise.
///
/// # Safety
///
/// `new_text_ptr` must be valid for reads of `new_text_len` UTF-8 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_update_segment_text(
    handle: u64,
    ordinal: u32,
    new_text_ptr: *const u8,
    new_text_len: usize,
) -> u8 {
    let Some(id) = SegmentId::new(ordinal) else {
        return 0;
    };
    if new_text_ptr.is_null() || new_text_len == 0 {
        return 0;
    }
    let bytes = unsafe { slice::from_raw_parts(new_text_ptr, new_text_len) };
    let Ok(new_text) = std::str::from_utf8(bytes) else {
        return 0;
    };
    if let Ok(mut map) = spine_map().lock() {
        if let Some(spine) = map.get_mut(&handle) {
            return u8::from(spine.update_segment_text(id, new_text));
        }
    }
    0
}

/// Sets the translation on 1-based segment `ordinal` (`S1..Sn`). Returns `1` if updated, `0` otherwise.
///
/// # Safety
///
/// `translation_ptr` and `target_lang_ptr` must be valid for reads of their respective lengths when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_set_translation(
    handle: u64,
    ordinal: u32,
    translation_ptr: *const u8,
    translation_len: usize,
    target_lang_ptr: *const u8,
    target_lang_len: usize,
) -> u8 {
    let Some(id) = SegmentId::new(ordinal) else {
        return 0;
    };
    if translation_ptr.is_null() || translation_len == 0 {
        return 0;
    }
    let tr_bytes = unsafe { slice::from_raw_parts(translation_ptr, translation_len) };
    let Ok(tr_str) = std::str::from_utf8(tr_bytes) else {
        return 0;
    };
    let target_lang = if target_lang_ptr.is_null() || target_lang_len == 0 {
        ""
    } else {
        let b = unsafe { slice::from_raw_parts(target_lang_ptr, target_lang_len) };
        std::str::from_utf8(b).unwrap_or("")
    };
    if let Ok(mut map) = spine_map().lock() {
        if let Some(spine) = map.get_mut(&handle) {
            return u8::from(spine.set_translation(id, tr_str, target_lang));
        }
    }
    0
}

/// Reads 1-based segment `ordinal` (`S1..Sn`) from `UtteranceSpine`, populating `*out_header_ptr`
/// and copying up to `out_text_cap` / `out_translation_cap` UTF-8 bytes into `out_text_ptr` /
/// `out_translation_ptr`. Returns `1` if the segment exists, `0` otherwise.
///
/// # Safety
///
/// `out_header_ptr` must be valid for writes of one `KoeUtteranceSegmentHeader`, and
/// `out_text_ptr` / `out_translation_ptr` must be valid for writes of their capacities when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_get_segment(
    handle: u64,
    ordinal: u32,
    out_header_ptr: *mut KoeUtteranceSegmentHeader,
    out_text_ptr: *mut u8,
    out_text_cap: usize,
    out_translation_ptr: *mut u8,
    out_translation_cap: usize,
) -> u8 {
    if out_header_ptr.is_null() {
        return 0;
    }
    let Some(id) = SegmentId::new(ordinal) else {
        return 0;
    };
    if let Ok(map) = spine_map().lock() {
        if let Some(spine) = map.get(&handle) {
            let Some(seg) = spine.get(id) else {
                return 0;
            };
            let text_bytes = seg.text.as_bytes();
            let tr_bytes = seg.translation.as_deref().map_or(&[][..], str::as_bytes);
            let mut hdr = KoeUtteranceSegmentHeader {
                ordinal: seg.id.ordinal(),
                revision: seg.revision,
                start_ms: seg.start_ms,
                end_ms: seg.end_ms,
                is_final: u8::from(seg.is_final),
                has_translation: u8::from(seg.translation.is_some()),
                reserved: [0u8; 2],
                text_len: text_bytes.len() as u32,
                translation_len: tr_bytes.len() as u32,
                source_language: [0u8; 16],
                target_language: [0u8; 16],
            };
            copy_c_str(&seg.source_language, &mut hdr.source_language);
            if let Some(tl) = &seg.target_language {
                copy_c_str(tl, &mut hdr.target_language);
            }
            unsafe {
                *out_header_ptr = hdr;
            }
            if !out_text_ptr.is_null() && out_text_cap > 0 && !text_bytes.is_empty() {
                let copy_len = text_bytes.len().min(out_text_cap);
                let dst = unsafe { slice::from_raw_parts_mut(out_text_ptr, copy_len) };
                dst.copy_from_slice(&text_bytes[..copy_len]);
            }
            if !out_translation_ptr.is_null() && out_translation_cap > 0 && !tr_bytes.is_empty() {
                let copy_len = tr_bytes.len().min(out_translation_cap);
                let dst = unsafe { slice::from_raw_parts_mut(out_translation_ptr, copy_len) };
                dst.copy_from_slice(&tr_bytes[..copy_len]);
            }
            return 1;
        }
    }
    0
}

/// Formats all segments in `UtteranceSpine` as newline-joined `"[S1] <text>"` UTF-8 bytes
/// on the Rust heap, storing the byte length in `*out_len_ptr` and returning a heap pointer
/// (freed via `koe_buffer_free`), or null when empty.
///
/// # Safety
///
/// `out_len_ptr` must be valid for writes of a `usize`.
#[no_mangle]
pub unsafe extern "C" fn koe_spine_format_cited_sources(
    handle: u64,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    if out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len_ptr = 0;
    }
    if let Ok(map) = spine_map().lock() {
        if let Some(spine) = map.get(&handle) {
            let joined = spine.format_cited_sources().join("\n");
            if joined.is_empty() {
                return std::ptr::null_mut();
            }
            let mut boxed = joined.into_bytes().into_boxed_slice();
            let len = boxed.len();
            let ptr = boxed.as_mut_ptr();
            std::mem::forget(boxed);
            unsafe {
                *out_len_ptr = len;
            }
            return ptr;
        }
    }
    std::ptr::null_mut()
}

/// Validates that `claim_ptr[0..claim_len]` cited by 1-based `citations_ptr[0..citations_len]`
/// is grounded in `UtteranceSpine` `handle` (`1` valid, `0` invalid/ungrounded).
///
/// # Safety
///
/// `claim_ptr` must be valid for reads of `claim_len` UTF-8 bytes, and `citations_ptr` must
/// be valid for reads of `citations_len` `u32` elements when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_minutes_validate_claim_grounding(
    handle: u64,
    claim_ptr: *const u8,
    claim_len: usize,
    citations_ptr: *const u32,
    citations_len: usize,
) -> u8 {
    if claim_ptr.is_null() || claim_len == 0 || citations_ptr.is_null() || citations_len == 0 {
        return 0;
    }
    let claim_bytes = unsafe { slice::from_raw_parts(claim_ptr, claim_len) };
    let Ok(claim) = std::str::from_utf8(claim_bytes) else {
        return 0;
    };
    let raw_ids = unsafe { slice::from_raw_parts(citations_ptr, citations_len) };
    let mut ids = Vec::with_capacity(raw_ids.len());
    for &ord in raw_ids {
        let Some(seg_id) = SegmentId::new(ord) else {
            return 0;
        };
        ids.push(seg_id);
    }
    if let Ok(map) = spine_map().lock() {
        if let Some(spine) = map.get(&handle) {
            return u8::from(validate_calculation_grounding(claim, &ids, spine).is_ok());
        }
    }
    0
}

/// Validates a full meeting minutes JSON document against `UtteranceSpine` `spine_handle`.
///
/// Returns:
/// - `1` when valid and grounded,
/// - `0` on invalid JSON or unsupported schema version,
/// - `-1` on invalid/missing `S1..Sn` citation (`InvalidCitation` / `NodeCitedDisallowedSource`),
/// - `-2` on ungrounded `terms[].heard` variant (`UngroundedHeardVariant`),
/// - `-3` on ungrounded wage/ratio/percentage calculation (`UngroundedWageCalculation`,
///   `BaselessRatioCalculation`, or `UncitedPercentageNumber`).
///
/// # Safety
///
/// `json_ptr` must be valid for reads of `json_len` UTF-8 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_minutes_validate_json(
    spine_handle: u64,
    json_ptr: *const u8,
    json_len: usize,
) -> i32 {
    if json_ptr.is_null() || json_len == 0 {
        return 0;
    }
    let bytes = unsafe { slice::from_raw_parts(json_ptr, json_len) };
    let Ok(raw) = std::str::from_utf8(bytes) else {
        return 0;
    };
    if let Ok(map) = spine_map().lock() {
        if let Some(spine) = map.get(&spine_handle) {
            return match parse_meeting_minutes_json(raw, spine) {
                Ok(_) => 1,
                Err(
                    MinutesValidationError::InvalidJson(_)
                    | MinutesValidationError::UnsupportedSchemaVersion(_),
                ) => 0,
                Err(
                    MinutesValidationError::InvalidCitation { .. }
                    | MinutesValidationError::NodeCitedDisallowedSource { .. },
                ) => -1,
                Err(MinutesValidationError::UngroundedHeardVariant { .. }) => -2,
                Err(
                    MinutesValidationError::UngroundedWageCalculation { .. }
                    | MinutesValidationError::BaselessRatioCalculation { .. }
                    | MinutesValidationError::UncitedPercentageNumber { .. },
                ) => -3,
            };
        }
    }
    0
}

/// Performs single-pass longest-match term replacement on `text_ptr[0..text_len]` where
/// `from_ptr[0..from_len]` and `to_ptr[0..to_len]` are `\n`-separated UTF-8 lists of equal length.
///
/// Writes up to `out_cap` UTF-8 bytes into `out_ptr` and returns the number of bytes written
/// (or `-1` on invalid UTF-8 or buffer overflow).
///
/// # Safety
///
/// Non-null input pointers must be valid for reads of their lengths, and `out_ptr` must be valid
/// for writes of `out_cap` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_minutes_replace_terms_utf8(
    text_ptr: *const u8,
    text_len: usize,
    from_ptr: *const u8,
    from_len: usize,
    to_ptr: *const u8,
    to_len: usize,
    out_ptr: *mut u8,
    out_cap: usize,
) -> i32 {
    let text = if text_ptr.is_null() || text_len == 0 {
        ""
    } else {
        let b = unsafe { slice::from_raw_parts(text_ptr, text_len) };
        let Ok(s) = std::str::from_utf8(b) else {
            return -1;
        };
        s
    };
    let from_str = if from_ptr.is_null() || from_len == 0 {
        ""
    } else {
        let b = unsafe { slice::from_raw_parts(from_ptr, from_len) };
        let Ok(s) = std::str::from_utf8(b) else {
            return -1;
        };
        s
    };
    let to_str = if to_ptr.is_null() || to_len == 0 {
        ""
    } else {
        let b = unsafe { slice::from_raw_parts(to_ptr, to_len) };
        let Ok(s) = std::str::from_utf8(b) else {
            return -1;
        };
        s
    };

    let from_lines: Vec<&str> = if from_str.is_empty() {
        Vec::new()
    } else {
        from_str.split('\n').collect()
    };
    let to_lines: Vec<&str> = if to_str.is_empty() {
        Vec::new()
    } else {
        to_str.split('\n').collect()
    };
    let pair_count = from_lines.len().min(to_lines.len());
    let pairs: Vec<(&str, &str)> = (0..pair_count)
        .map(|i| (from_lines[i], to_lines[i]))
        .collect();
    let replaced = replace_minute_terms(text, &pairs);
    let out_bytes = replaced.as_bytes();
    if out_ptr.is_null() {
        return out_bytes.len() as i32;
    }
    if out_bytes.len() > out_cap {
        return -1;
    }
    let dst = unsafe { slice::from_raw_parts_mut(out_ptr, out_bytes.len()) };
    dst.copy_from_slice(out_bytes);
    out_bytes.len() as i32
}

/// Returns the number of leaf batches planned for `UtteranceSpine` `spine_handle` under
/// `max_runes` per batch (`<= 6000` default when `0`), or `-1` on invalid handle.
#[no_mangle]
pub extern "C" fn koe_minutes_plan_batches_count(spine_handle: u64, max_runes: u32) -> i32 {
    if let Ok(map) = spine_map().lock() {
        if let Some(spine) = map.get(&spine_handle) {
            return build_minutes_batches(spine, max_runes as usize).len() as i32;
        }
    }
    -1
}

/// Parses a DashScope batch transcription result JSON payload and appends its timed sentences
/// into `UtteranceSpine` `spine_handle`, returning the number of appended segments (or `-1` on
/// invalid JSON/handle).
///
/// # Safety
///
/// `json_ptr` must be valid for reads of `json_len` UTF-8 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_qwen_parse_transcript_into_spine(
    spine_handle: u64,
    json_ptr: *const u8,
    json_len: usize,
) -> i32 {
    if json_ptr.is_null() || json_len == 0 {
        return -1;
    }
    let bytes = unsafe { slice::from_raw_parts(json_ptr, json_len) };
    let Ok(raw) = std::str::from_utf8(bytes) else {
        return -1;
    };
    if let Ok(mut map) = spine_map().lock() {
        if let Some(spine) = map.get_mut(&spine_handle) {
            return match parse_qwen_transcript_json(raw, spine) {
                Ok(parsed) => parsed.segment_count as i32,
                Err(_) => -1,
            };
        }
    }
    -1
}

/// Allocates a stateful Cicada `RollingMinutesScheduler` handle.
///
/// # Safety
///
/// `session_id_ptr` must be valid for reads of `session_id_len` UTF-8 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_rolling_new(
    session_id_ptr: *const u8,
    session_id_len: usize,
) -> u64 {
    let session_id = if session_id_ptr.is_null() || session_id_len == 0 {
        "cicada"
    } else {
        let bytes = unsafe { slice::from_raw_parts(session_id_ptr, session_id_len) };
        std::str::from_utf8(bytes).unwrap_or("cicada")
    };
    let h = alloc_handle();
    if let Ok(mut map) = rolling_map().lock() {
        map.insert(h, RollingMinutesScheduler::new(session_id));
    }
    h
}

/// Frees a Cicada `RollingMinutesScheduler` handle.
#[no_mangle]
pub extern "C" fn koe_cicada_rolling_free(handle: u64) {
    if let Ok(mut map) = rolling_map().lock() {
        map.remove(&handle);
    }
}

/// Appends or verifies a finalized `(seg_id, text)` segment in `RollingMinutesScheduler` at `now_ms`.
/// Returns `1` on success, `0` if revised/invalidated or closed.
///
/// # Safety
///
/// `seg_id_ptr` and `text_ptr` must be valid for reads of their respective byte lengths when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_rolling_add_segment(
    handle: u64,
    seg_id_ptr: *const u8,
    seg_id_len: usize,
    text_ptr: *const u8,
    text_len: usize,
    now_ms: u64,
) -> u8 {
    if seg_id_ptr.is_null() || seg_id_len == 0 || text_ptr.is_null() || text_len == 0 {
        return 0;
    }
    let id_bytes = unsafe { slice::from_raw_parts(seg_id_ptr, seg_id_len) };
    let text_bytes = unsafe { slice::from_raw_parts(text_ptr, text_len) };
    let (Ok(seg_id), Ok(text)) = (
        std::str::from_utf8(id_bytes),
        std::str::from_utf8(text_bytes),
    ) else {
        return 0;
    };
    if let Ok(mut map) = rolling_map().lock() {
        if let Some(sched) = map.get_mut(&handle) {
            return u8::from(sched.append_segment(seg_id, text, now_ms));
        }
    }
    0
}

/// Evaluates whether a rolling summary pass should dispatch at `now_ms`.
/// When dispatched, writes `*out_from_ptr`, `*out_end_ptr`, `*out_generation_ptr`, and `*out_len_ptr`,
/// returning a heap-allocated UTF-8 payload buffer (freed via `koe_buffer_free`); otherwise returns null.
///
/// # Safety
///
/// Output pointers must be valid mutable pointers when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_rolling_poll_tick(
    handle: u64,
    now_ms: u64,
    out_from_ptr: *mut u32,
    out_end_ptr: *mut u32,
    out_generation_ptr: *mut u64,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    if out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len_ptr = 0;
    }
    if let Ok(mut map) = rolling_map().lock() {
        if let Some(sched) = map.get_mut(&handle) {
            if let RollingTickDecision::Dispatch(ticket) = sched.poll_tick(now_ms) {
                if !out_from_ptr.is_null() {
                    unsafe {
                        *out_from_ptr = ticket.from_index as u32;
                    }
                }
                if !out_end_ptr.is_null() {
                    unsafe {
                        *out_end_ptr = ticket.end_index as u32;
                    }
                }
                if !out_generation_ptr.is_null() {
                    unsafe {
                        *out_generation_ptr = ticket.generation;
                    }
                }
                let mut boxed = ticket.input_payload.into_bytes().into_boxed_slice();
                let len = boxed.len();
                let ptr = boxed.as_mut_ptr();
                std::mem::forget(boxed);
                unsafe {
                    *out_len_ptr = len;
                }
                return ptr;
            }
        }
    }
    std::ptr::null_mut()
}

/// Validates and commits a rolling minutes LLM JSON response (`1` committed, `0` stale/ignored, `-1` invalid).
///
/// # Safety
///
/// `raw_json_ptr` must be valid for reads of `raw_json_len` UTF-8 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_rolling_complete(
    handle: u64,
    generation: u64,
    from_index: u32,
    end_index: u32,
    raw_json_ptr: *const u8,
    raw_json_len: usize,
) -> i32 {
    if raw_json_ptr.is_null() || raw_json_len == 0 {
        return -1;
    }
    let bytes = unsafe { slice::from_raw_parts(raw_json_ptr, raw_json_len) };
    let Ok(raw_json) = std::str::from_utf8(bytes) else {
        return -1;
    };
    if let Ok(mut map) = rolling_map().lock() {
        if let Some(sched) = map.get_mut(&handle) {
            return match sched.complete_request(
                generation,
                from_index as usize,
                end_index as usize,
                raw_json,
            ) {
                Ok(true) => 1,
                Ok(false) => 0,
                Err(_) => -1,
            };
        }
    }
    -1
}

/// Validates and applies a manual user edit to the active live minutes (`1` ok, `-1` invalid).
///
/// # Safety
///
/// `edited_json_ptr` must be valid for reads of `edited_json_len` UTF-8 bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_rolling_edit(
    handle: u64,
    edited_json_ptr: *const u8,
    edited_json_len: usize,
) -> i32 {
    if edited_json_ptr.is_null() || edited_json_len == 0 {
        return -1;
    }
    let bytes = unsafe { slice::from_raw_parts(edited_json_ptr, edited_json_len) };
    let Ok(edited_json) = std::str::from_utf8(bytes) else {
        return -1;
    };
    if let Ok(mut map) = rolling_map().lock() {
        if let Some(sched) = map.get_mut(&handle) {
            if sched.edit_active(edited_json).is_ok() {
                sched.resume();
                return 1;
            }
        }
    }
    -1
}

/// Promotes the pending machine candidate to active live minutes (`1` promoted, `0` no candidate).
#[no_mangle]
pub extern "C" fn koe_cicada_rolling_accept_candidate(handle: u64) -> u8 {
    if let Ok(mut map) = rolling_map().lock() {
        if let Some(sched) = map.get_mut(&handle) {
            return u8::from(sched.accept_candidate());
        }
    }
    0
}

/// Returns a heap-allocated UTF-8 copy of the active live minutes JSON (freed via `koe_buffer_free`),
/// or null if no active minutes exist yet.
///
/// # Safety
///
/// `out_len_ptr` must be valid for writes of a `usize`.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_rolling_get_active(
    handle: u64,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    if out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len_ptr = 0;
    }
    if let Ok(map) = rolling_map().lock() {
        if let Some(sched) = map.get(&handle) {
            if let Some(active) = sched.active_json() {
                let mut boxed = active.as_bytes().to_vec().into_boxed_slice();
                let len = boxed.len();
                let ptr = boxed.as_mut_ptr();
                std::mem::forget(boxed);
                unsafe {
                    *out_len_ptr = len;
                }
                return ptr;
            }
        }
    }
    std::ptr::null_mut()
}

/// Writes the current `KoeCicadaRollingStatus` snapshot into `*out_status_ptr` (`1` ok, `0` invalid handle).
///
/// # Safety
///
/// `out_status_ptr` must be valid for writes of one `KoeCicadaRollingStatus`.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_rolling_status(
    handle: u64,
    out_status_ptr: *mut KoeCicadaRollingStatus,
) -> u8 {
    if out_status_ptr.is_null() {
        return 0;
    }
    if let Ok(map) = rolling_map().lock() {
        if let Some(sched) = map.get(&handle) {
            unsafe {
                *out_status_ptr = KoeCicadaRollingStatus {
                    paused: u8::from(sched.is_paused()),
                    closed: u8::from(sched.is_closed()),
                    edited: u8::from(sched.is_edited()),
                    has_candidate: u8::from(sched.has_candidate()),
                    request_status: sched.request_status() as u8,
                    reserved: [0u8; 3],
                    watermark: sched.watermark() as u32,
                    calls_this_hour: sched.calls_in_window() as u32,
                    generation: sched.generation(),
                };
            }
            return 1;
        }
    }
    0
}

/// Pure C-ABI step for the 30-second Cicada silence auto-stop reducer.
/// Returns `1` when this step newly triggered auto-stop (`silence_elapsed_ms >= 30_000`), else `0`.
///
/// # Safety
///
/// `out_next_elapsed_ms_ptr` and `out_auto_stopped_ptr` must be valid mutable pointers when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_cicada_silence_reduce(
    silence_elapsed_ms: u64,
    delta_ms: u64,
    speech_detected: u8,
    already_auto_stopped: u8,
    out_next_elapsed_ms_ptr: *mut u64,
    out_auto_stopped_ptr: *mut u8,
) -> u8 {
    let mut state = CicadaState {
        target_language: "en".to_string(),
        calls_this_hour: 0,
        silence_elapsed_ms,
        auto_stopped: already_auto_stopped != 0,
    };
    let spine = UtteranceSpine::new("silence-check");
    let outcome = CicadaState::reduce(
        &mut state,
        &spine,
        CicadaEvent::OnAudioActivity {
            elapsed_ms: delta_ms,
            speech_detected: speech_detected != 0,
        },
    );
    if !out_next_elapsed_ms_ptr.is_null() {
        unsafe {
            *out_next_elapsed_ms_ptr = state.silence_elapsed_ms;
        }
    }
    if !out_auto_stopped_ptr.is_null() {
        unsafe {
            *out_auto_stopped_ptr = u8::from(state.auto_stopped);
        }
    }
    u8::from(outcome.triggered_auto_stop)
}

/// Verifies an audio-less `.koepack` archive (`2` valid v2, `1` valid v1, `-1` invalid).
///
/// # Safety
///
/// `pack_ptr` must be valid for reads of `pack_len` bytes when non-null.
#[no_mangle]
pub unsafe extern "C" fn koe_koepack_verify_v2(pack_ptr: *const u8, pack_len: usize) -> i32 {
    if pack_ptr.is_null() || pack_len == 0 {
        return -1;
    }
    let bytes = unsafe { slice::from_raw_parts(pack_ptr, pack_len) };
    match decode_koepack_v2(bytes) {
        Ok(pack) => pack.version as i32,
        Err(_) => -1,
    }
}

/// Encodes a valid audio-less `.koepack v2` archive from a 64-hex `content_hash`, `title`,
/// single source sentence (`S1`), and `MeetingMinutesV2` JSON string, returning a heap buffer
/// (freed via `koe_buffer_free`) and writing its length to `*out_len_ptr`.
///
/// # Safety
///
/// Input pointers must be valid for reads of their respective lengths, and `out_len_ptr` must be valid for writes.
#[no_mangle]
pub unsafe extern "C" fn koe_koepack_encode_demo_v2(
    content_hash_ptr: *const u8,
    content_hash_len: usize,
    title_ptr: *const u8,
    title_len: usize,
    source_ptr: *const u8,
    source_len: usize,
    minutes_json_ptr: *const u8,
    minutes_json_len: usize,
    out_len_ptr: *mut usize,
) -> *mut u8 {
    if out_len_ptr.is_null() {
        return std::ptr::null_mut();
    }
    unsafe {
        *out_len_ptr = 0;
    }
    if content_hash_ptr.is_null()
        || title_ptr.is_null()
        || source_ptr.is_null()
        || minutes_json_ptr.is_null()
    {
        return std::ptr::null_mut();
    }
    let (Ok(content_hash), Ok(title), Ok(source), Ok(minutes_json)) = (
        std::str::from_utf8(unsafe { slice::from_raw_parts(content_hash_ptr, content_hash_len) }),
        std::str::from_utf8(unsafe { slice::from_raw_parts(title_ptr, title_len) }),
        std::str::from_utf8(unsafe { slice::from_raw_parts(source_ptr, source_len) }),
        std::str::from_utf8(unsafe { slice::from_raw_parts(minutes_json_ptr, minutes_json_len) }),
    ) else {
        return std::ptr::null_mut();
    };
    let sources = vec![source.to_string()];
    let source_hash = sha256_hex(source.as_bytes());
    let entry = PortableMinutesEntry {
        text: minutes_json.to_string(),
        source_hash,
        model: "qwen3.8-flash".to_string(),
        instruction: "整理结构化纪要".to_string(),
        sources,
        created_at_iso: "2026-11-07T12:00:00Z".to_string(),
        edited_at_iso: None,
        template_id: Some("minutes".to_string()),
        template_version: 4,
        is_draft: false,
    };
    let pack = MaterialPackV2 {
        version: 2,
        exported_at_iso: "2026-11-07T12:05:00Z".to_string(),
        material: PackMaterialMeta {
            content_hash: content_hash.to_string(),
            title: title.to_string(),
            source: "device".to_string(),
            device_file_id: Some(1),
            recorded_at_iso: Some("2026-11-07T11:30:00Z".to_string()),
            audio_extension: Some(".wav".to_string()),
        },
        minutes: Some(PackMinutesV2 {
            current: entry,
            history: Vec::new(),
        }),
    };
    let Ok(encoded) = encode_koepack_v2(&pack) else {
        return std::ptr::null_mut();
    };
    let mut boxed = encoded.into_boxed_slice();
    let len = boxed.len();
    let ptr = boxed.as_mut_ptr();
    std::mem::forget(boxed);
    unsafe {
        *out_len_ptr = len;
    }
    ptr
}

#[cfg(test)]
mod tests {
    use super::*;
    use koe_core::session::REAL_OPUS_20MS_440HZ_PACKET;

    #[test]
    fn ffi_decodes_real_opus_20ms_packet_to_16khz_and_48khz_pcm16_and_wav() {
        let mut padded = [0u8; 160];
        padded[..REAL_OPUS_20MS_440HZ_PACKET.len()].copy_from_slice(&REAL_OPUS_20MS_440HZ_PACKET);

        let mut len_16k = 0usize;
        let ptr_16k = unsafe {
            koe_opus_decode_pcm16(padded.as_ptr(), padded.len(), 16_000, &mut len_16k)
        };
        assert!(!ptr_16k.is_null());
        assert_eq!(len_16k, 640);
        let pcm_16k = unsafe { slice::from_raw_parts(ptr_16k, len_16k) };
        let sample_130 = i16::from_le_bytes([pcm_16k[130 * 2], pcm_16k[130 * 2 + 1]]);
        assert!(
            (sample_130 - (-4130)).abs() <= 16,
            "expected sample 130 near -4130, got {sample_130}"
        );
        unsafe { koe_buffer_free(ptr_16k, len_16k) };

        let mut len_48k = 0usize;
        let ptr_48k = unsafe {
            koe_opus_decode_pcm16(padded.as_ptr(), padded.len(), 48_000, &mut len_48k)
        };
        assert!(!ptr_48k.is_null());
        assert_eq!(len_48k, 1920);
        unsafe { koe_buffer_free(ptr_48k, len_48k) };

        let marks = [0u64];
        let mut wav_len = 0usize;
        let wav_ptr = unsafe {
            koe_opus_decode_wav(
                padded.as_ptr(),
                padded.len(),
                48_000,
                marks.as_ptr(),
                marks.len(),
                &mut wav_len,
            )
        };
        assert!(!wav_ptr.is_null());
        assert_eq!(wav_len, 44 + 1920);
        let wav_slice = unsafe { slice::from_raw_parts(wav_ptr, wav_len) };
        assert_eq!(&wav_slice[0..4], b"RIFF");
        unsafe { koe_buffer_free(wav_ptr, wav_len) };
    }

    #[test]
    fn ffi_session_simulate_realtime_pipeline_decodes_real_opus_wav_and_live_16khz_pcm() {
        let handle = koe_session_new();
        let mut step = KoeSessionStepResult {
            frames_decoded: 0,
            connection_phase: 0,
            telemetry_updated: 0,
            session_key_established: 0,
            catalog_updated: 0,
            transfer_updated: 0,
            has_finalized_recording: 0,
            reserved: [0; 2],
            slices_unpacked_count: 0,
            new_marks_count: 0,
            outbound_tx_count: 0,
            live_pcm16_bytes_available: 0,
            transfer: KoeTransferProgress {
                phase: 0,
                error_code: 0,
                retry_count: 0,
                quiet_draining: 0,
                file_id: 0,
                received_wire_bytes: 0,
                expected_wire_bytes: 0,
                mark_count: 0,
            },
        };
        let ok = unsafe { koe_session_simulate_realtime_pipeline(handle, 1_700_000_000, &mut step) };
        assert_eq!(ok, 1);
        assert_eq!(step.has_finalized_recording, 1);
        assert_eq!(step.slices_unpacked_count, 60);
        assert_eq!(step.live_pcm16_bytes_available, 60 * 320 * 2);

        let mut live_len = 0usize;
        let live_ptr = unsafe { koe_session_take_live_pcm16(handle, &mut live_len) };
        assert!(!live_ptr.is_null());
        assert_eq!(live_len, 60 * 320 * 2);
        let live_pcm = unsafe { slice::from_raw_parts(live_ptr, live_len) };
        let sample_130 = i16::from_le_bytes([live_pcm[130 * 2], live_pcm[130 * 2 + 1]]);
        assert!((sample_130 - (-4130)).abs() <= 16);
        unsafe { koe_buffer_free(live_ptr, live_len) };

        let mut entry = KoeRecordingEntry {
            id: 0,
            bean_file_id: 0,
            created_at_epoch_sec: 0,
            duration_ms: 0,
            byte_count: 0,
            mark_count: 0,
            marks_ms: [0; 32],
        };
        let mut ogg_ptr = std::ptr::null_mut();
        let mut ogg_len = 0usize;
        let mut wav_ptr = std::ptr::null_mut();
        let mut wav_len = 0usize;
        let taken = unsafe {
            koe_session_take_finalized(
                handle,
                &mut entry,
                &mut ogg_ptr,
                &mut ogg_len,
                &mut wav_ptr,
                &mut wav_len,
            )
        };
        assert_eq!(taken, 1);
        assert_eq!(wav_len, 44 + 60 * 960 * 2);
        unsafe {
            koe_buffer_free(ogg_ptr, ogg_len);
            koe_buffer_free(wav_ptr, wav_len);
        }
        koe_session_free(handle);
    }
}
