//! Thin C-ABI boundary wrapping the `#![forbid(unsafe_code)]` `koe_core` crate
//! for `dart:ffi`, Swift (`darwin/KoeCore.swift`), and Kotlin (`KoeCore.kt`) callers.

use std::slice;

use koe_core::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
use koe_core::frame::{DecodedPacket, ProtocolFrame};
use koe_core::models::{DeviceInfoModel, OfflineFileList};
use koe_core::ogg_opus::OggOpus;
use koe_core::slice_marks::{SliceMark, SliceMarkProbe};
use koe_core::transport::{TransportSliceProcessor, OPUS_FRAME_BYTES};
use koe_core::wav::OpusWave;

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
