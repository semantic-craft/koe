//! Thin C-ABI boundary wrapping the `#![forbid(unsafe_code)]` `koe_core` crate
//! for `dart:ffi` callers in `lib/native/koe_core_ffi.dart`.

use std::slice;

use koe_core::crypto::{AesCtrStreamDecrypt, DeviceCrypto};
use koe_core::frame::ProtocolFrame;
use koe_core::ogg_opus::OggOpus;
use koe_core::wav::OpusWave;

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
