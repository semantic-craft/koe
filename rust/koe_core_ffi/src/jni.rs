//! Zero-dependency JNI C-ABI bindings (`com.anker.anker_recorder.KoeCoreNative`)
//! backed by the standard `JNINativeInterface_` function pointer table.

use std::collections::BTreeMap;
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};

use crate::{
    koe_buffer_free, koe_library_free, koe_library_ingest_entry, koe_library_jump_to_mark,
    koe_library_move_to_trash, koe_library_new, koe_library_seek_ms, koe_library_select,
    koe_library_snapshot, koe_library_undo_trash, koe_opus_decode_pcm16, koe_opus_decode_wav,
    koe_protocol_checksum, koe_protocol_encode, koe_protocol_verify_checksum,
    koe_reassembler_free, koe_reassembler_ingest, koe_reassembler_new, koe_reassembler_pop_packet,
    koe_reassembler_reset, koe_session_accept_ecdh_reply, koe_session_begin_offline_pull,
    koe_session_free, koe_session_ingest_ble_chunk, koe_session_new,
    koe_session_on_transport_interrupted, koe_session_poll_timers, koe_session_pop_outbound_tx,
    koe_session_resume_offline_pull, koe_session_simulate_realtime_pipeline,
    koe_session_stop_realtime_recording, koe_session_take_live_pcm16, session_map,
    KoeLibrarySnapshot, KoeRecordingEntry, KoeSessionStepResult,
};
use koe_core::crypto::DeviceCrypto;
use koe_core::ogg_opus::OggOpus;
use koe_core::wav::OpusWave;

type JniEnv = *mut *const *const c_void;
type JClass = *mut c_void;
type JArray = *mut c_void;
type JByteArray = *mut c_void;
type JLongArray = *mut c_void;
type JSize = i32;
type JBoolean = u8;
type JInt = i32;
type JLong = i64;

const SLOT_GET_ARRAY_LENGTH: usize = 171;
const SLOT_NEW_BYTE_ARRAY: usize = 176;
const SLOT_NEW_LONG_ARRAY: usize = 180;
const SLOT_GET_BYTE_ARRAY_REGION: usize = 200;
const SLOT_GET_LONG_ARRAY_REGION: usize = 204;
const SLOT_SET_BYTE_ARRAY_REGION: usize = 208;
const SLOT_SET_LONG_ARRAY_REGION: usize = 212;

type FnGetArrayLength = unsafe extern "C" fn(JniEnv, JArray) -> JSize;
type FnNewByteArray = unsafe extern "C" fn(JniEnv, JSize) -> JByteArray;
type FnNewLongArray = unsafe extern "C" fn(JniEnv, JSize) -> JLongArray;
type FnGetByteArrayRegion = unsafe extern "C" fn(JniEnv, JByteArray, JSize, JSize, *mut i8);
type FnGetLongArrayRegion = unsafe extern "C" fn(JniEnv, JLongArray, JSize, JSize, *mut i64);
type FnSetByteArrayRegion = unsafe extern "C" fn(JniEnv, JByteArray, JSize, JSize, *const i8);
type FnSetLongArrayRegion = unsafe extern "C" fn(JniEnv, JLongArray, JSize, JSize, *const i64);

unsafe fn jni_read_bytes(env: JniEnv, arr: JByteArray) -> Vec<u8> {
    if env.is_null() || arr.is_null() {
        return Vec::new();
    }
    let vtable = unsafe { *env };
    let get_len: FnGetArrayLength =
        unsafe { std::mem::transmute(*vtable.add(SLOT_GET_ARRAY_LENGTH)) };
    let len = unsafe { get_len(env, arr) };
    if len <= 0 {
        return Vec::new();
    }
    let mut out = vec![0u8; len as usize];
    let get_region: FnGetByteArrayRegion =
        unsafe { std::mem::transmute(*vtable.add(SLOT_GET_BYTE_ARRAY_REGION)) };
    unsafe {
        get_region(env, arr, 0, len, out.as_mut_ptr().cast::<i8>());
    }
    out
}

unsafe fn jni_new_bytes(env: JniEnv, bytes: &[u8]) -> JByteArray {
    if env.is_null() {
        return std::ptr::null_mut();
    }
    let vtable = unsafe { *env };
    let new_arr: FnNewByteArray =
        unsafe { std::mem::transmute(*vtable.add(SLOT_NEW_BYTE_ARRAY)) };
    let len = bytes.len().min(i32::MAX as usize) as JSize;
    let arr = unsafe { new_arr(env, len) };
    if !arr.is_null() && len > 0 {
        let set_region: FnSetByteArrayRegion =
            unsafe { std::mem::transmute(*vtable.add(SLOT_SET_BYTE_ARRAY_REGION)) };
        unsafe {
            set_region(env, arr, 0, len, bytes.as_ptr().cast::<i8>());
        }
    }
    arr
}

unsafe fn jni_read_longs(env: JniEnv, arr: JLongArray) -> Vec<i64> {
    if env.is_null() || arr.is_null() {
        return Vec::new();
    }
    let vtable = unsafe { *env };
    let get_len: FnGetArrayLength =
        unsafe { std::mem::transmute(*vtable.add(SLOT_GET_ARRAY_LENGTH)) };
    let len = unsafe { get_len(env, arr) };
    if len <= 0 {
        return Vec::new();
    }
    let mut out = vec![0i64; len as usize];
    let get_region: FnGetLongArrayRegion =
        unsafe { std::mem::transmute(*vtable.add(SLOT_GET_LONG_ARRAY_REGION)) };
    unsafe {
        get_region(env, arr, 0, len, out.as_mut_ptr());
    }
    out
}

unsafe fn jni_new_longs(env: JniEnv, values: &[i64]) -> JLongArray {
    if env.is_null() {
        return std::ptr::null_mut();
    }
    let vtable = unsafe { *env };
    let new_arr: FnNewLongArray =
        unsafe { std::mem::transmute(*vtable.add(SLOT_NEW_LONG_ARRAY)) };
    let len = values.len().min(i32::MAX as usize) as JSize;
    let arr = unsafe { new_arr(env, len) };
    if !arr.is_null() && len > 0 {
        let set_region: FnSetLongArrayRegion =
            unsafe { std::mem::transmute(*vtable.add(SLOT_SET_LONG_ARRAY_REGION)) };
        unsafe {
            set_region(env, arr, 0, len, values.as_ptr());
        }
    }
    arr
}

fn empty_step_result() -> KoeSessionStepResult {
    KoeSessionStepResult {
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
        transfer: crate::KoeTransferProgress {
            phase: 0,
            error_code: 0,
            retry_count: 0,
            quiet_draining: 0,
            file_id: 0,
            received_wire_bytes: 0,
            expected_wire_bytes: 0,
            mark_count: 0,
        },
    }
}

fn step_to_longs(step: &KoeSessionStepResult) -> [i64; 18] {
    [
        i64::from(step.frames_decoded),
        i64::from(step.connection_phase),
        i64::from(step.telemetry_updated),
        i64::from(step.session_key_established),
        i64::from(step.catalog_updated),
        i64::from(step.transfer_updated),
        i64::from(step.has_finalized_recording),
        i64::from(step.slices_unpacked_count),
        i64::from(step.new_marks_count),
        i64::from(step.outbound_tx_count),
        i64::from(step.transfer.phase),
        i64::from(step.transfer.file_id),
        i64::from(step.transfer.received_wire_bytes),
        i64::from(step.transfer.expected_wire_bytes),
        i64::from(step.live_pcm16_bytes_available),
        i64::from(step.transfer.error_code),
        i64::from(step.transfer.retry_count),
        i64::from(step.transfer.quiet_draining),
    ]
}

struct JniFinalizedBlobs {
    ogg: Vec<u8>,
    wav: Vec<u8>,
}

static JNI_FINALIZED_BLOBS: OnceLock<Mutex<BTreeMap<u64, JniFinalizedBlobs>>> = OnceLock::new();

fn finalized_blob_map() -> &'static Mutex<BTreeMap<u64, JniFinalizedBlobs>> {
    JNI_FINALIZED_BLOBS.get_or_init(|| Mutex::new(BTreeMap::new()))
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_checksum(
    env: JniEnv,
    _cls: JClass,
    data: JByteArray,
) -> JInt {
    let bytes = unsafe { jni_read_bytes(env, data) };
    i32::from(unsafe { koe_protocol_checksum(bytes.as_ptr(), bytes.len()) })
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_verifyChecksum(
    env: JniEnv,
    _cls: JClass,
    packet: JByteArray,
) -> JBoolean {
    let bytes = unsafe { jni_read_bytes(env, packet) };
    unsafe { koe_protocol_verify_checksum(bytes.as_ptr(), bytes.len()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_encodeFrame(
    env: JniEnv,
    _cls: JClass,
    cmd_type: JInt,
    cmd_id: JInt,
    payload: JByteArray,
) -> JByteArray {
    let pay = unsafe { jni_read_bytes(env, payload) };
    let mut out = vec![0u8; pay.len() + 10];
    let n = unsafe {
        koe_protocol_encode(
            (cmd_type & 0xFF) as u8,
            (cmd_id & 0xFF) as u8,
            pay.as_ptr(),
            pay.len(),
            out.as_mut_ptr(),
            out.len(),
        )
    };
    unsafe { jni_new_bytes(env, &out[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_hkdfSha256(
    env: JniEnv,
    _cls: JClass,
    ikm: JByteArray,
    salt: JByteArray,
    info: JByteArray,
    length: JInt,
) -> JByteArray {
    let ikm_b = unsafe { jni_read_bytes(env, ikm) };
    let salt_b = unsafe { jni_read_bytes(env, salt) };
    let info_b = unsafe { jni_read_bytes(env, info) };
    let out = DeviceCrypto::hkdf_sha256(&ikm_b, &salt_b, &info_b, length.max(0) as usize);
    unsafe { jni_new_bytes(env, &out) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_muxOggOpus(
    env: JniEnv,
    _cls: JClass,
    raw_opus_frames: JByteArray,
) -> JByteArray {
    let raw = unsafe { jni_read_bytes(env, raw_opus_frames) };
    let ogg = OggOpus::mux_raw_frames(&raw);
    unsafe { jni_new_bytes(env, &ogg) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_buildAudiblePreviewWav(
    env: JniEnv,
    _cls: JClass,
    duration_ms: JLong,
    marks_ms: JLongArray,
) -> JByteArray {
    let marks_i64 = unsafe { jni_read_longs(env, marks_ms) };
    let marks_u64: Vec<u64> = marks_i64.into_iter().map(|v| v.max(0) as u64).collect();
    let wav = OpusWave::build_audible_preview_wav(duration_ms.max(0) as u64, &marks_u64);
    unsafe { jni_new_bytes(env, &wav) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_decodeOpusPcm16(
    env: JniEnv,
    _cls: JClass,
    raw_opus_frames: JByteArray,
    sample_rate: JInt,
) -> JByteArray {
    let raw = unsafe { jni_read_bytes(env, raw_opus_frames) };
    let mut out_len = 0usize;
    let ptr = unsafe {
        koe_opus_decode_pcm16(
            raw.as_ptr(),
            raw.len(),
            sample_rate.max(0) as u32,
            &mut out_len,
        )
    };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let arr = unsafe { jni_new_bytes(env, slice) };
    unsafe {
        koe_buffer_free(ptr, out_len);
    }
    arr
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_decodeOpusWav(
    env: JniEnv,
    _cls: JClass,
    raw_opus_frames: JByteArray,
    sample_rate: JInt,
    marks_ms: JLongArray,
) -> JByteArray {
    let raw = unsafe { jni_read_bytes(env, raw_opus_frames) };
    let marks_i64 = unsafe { jni_read_longs(env, marks_ms) };
    let marks_u64: Vec<u64> = marks_i64.into_iter().map(|v| v.max(0) as u64).collect();
    let mut out_len = 0usize;
    let ptr = unsafe {
        koe_opus_decode_wav(
            raw.as_ptr(),
            raw.len(),
            sample_rate.max(0) as u32,
            marks_u64.as_ptr(),
            marks_u64.len(),
            &mut out_len,
        )
    };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let arr = unsafe { jni_new_bytes(env, slice) };
    unsafe {
        koe_buffer_free(ptr, out_len);
    }
    arr
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_reassemblerNew(
    _env: JniEnv,
    _cls: JClass,
) -> JLong {
    koe_reassembler_new() as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_reassemblerFree(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_reassembler_free(handle as u64);
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_reassemblerReset(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_reassembler_reset(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_reassemblerIngest(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    chunk: JByteArray,
) -> JInt {
    let bytes = unsafe { jni_read_bytes(env, chunk) };
    unsafe { koe_reassembler_ingest(handle as u64, bytes.as_ptr(), bytes.len()) as JInt }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_reassemblerPopPacket(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut buf = vec![0u8; 65536];
    let mut cmd_type = 0u8;
    let mut cmd_id = 0u8;
    let n = unsafe {
        koe_reassembler_pop_packet(
            handle as u64,
            buf.as_mut_ptr(),
            buf.len(),
            &mut cmd_type,
            &mut cmd_id,
        )
    };
    if n == 0 {
        return std::ptr::null_mut();
    }
    unsafe { jni_new_bytes(env, &buf[..n]) }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionNew(
    _env: JniEnv,
    _cls: JClass,
) -> JLong {
    koe_session_new() as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionFree(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    let h = handle as u64;
    koe_session_free(h);
    if let Ok(mut blobs) = finalized_blob_map().lock() {
        blobs.remove(&h);
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionAcceptEcdhReply(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    reply_payload: JByteArray,
    shared_secret: JByteArray,
) -> JBoolean {
    let reply = unsafe { jni_read_bytes(env, reply_payload) };
    let secret = unsafe { jni_read_bytes(env, shared_secret) };
    unsafe {
        koe_session_accept_ecdh_reply(
            handle as u64,
            reply.as_ptr(),
            reply.len(),
            secret.as_ptr(),
            secret.len(),
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionBeginOfflinePull(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    file_id: JInt,
    duration_ms: JInt,
) -> JByteArray {
    let mut tx = [0u8; 32];
    let n = unsafe {
        koe_session_begin_offline_pull(
            handle as u64,
            file_id as u32,
            duration_ms.max(0) as u32,
            tx.as_mut_ptr(),
            tx.len(),
        )
    };
    unsafe { jni_new_bytes(env, &tx[..n]) }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionOnTransportInterrupted(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_session_on_transport_interrupted(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionResumeOfflinePull(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut tx = [0u8; 32];
    let n = unsafe {
        koe_session_resume_offline_pull(handle as u64, tx.as_mut_ptr(), tx.len())
    };
    unsafe { jni_new_bytes(env, &tx[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionStopRealtimeRecording(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut step = empty_step_result();
    unsafe {
        koe_session_stop_realtime_recording(handle as u64, &mut step);
        jni_new_longs(env, &step_to_longs(&step))
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionPollTimers(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    elapsed_ms: JLong,
    now_epoch_sec: JLong,
) -> JLongArray {
    let mut step = empty_step_result();
    unsafe {
        koe_session_poll_timers(
            handle as u64,
            elapsed_ms.max(0) as u64,
            now_epoch_sec.max(0) as u64,
            &mut step,
        );
        jni_new_longs(env, &step_to_longs(&step))
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionIngestBleChunk(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    chunk: JByteArray,
    now_epoch_sec: JLong,
) -> JLongArray {
    let bytes = unsafe { jni_read_bytes(env, chunk) };
    let mut step = empty_step_result();
    unsafe {
        koe_session_ingest_ble_chunk(
            handle as u64,
            bytes.as_ptr(),
            bytes.len(),
            now_epoch_sec.max(0) as u64,
            &mut step,
        );
        jni_new_longs(env, &step_to_longs(&step))
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionPopOutboundTx(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut buf = [0u8; 512];
    let n = unsafe { koe_session_pop_outbound_tx(handle as u64, buf.as_mut_ptr(), buf.len()) };
    if n == 0 {
        return std::ptr::null_mut();
    }
    unsafe { jni_new_bytes(env, &buf[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionSimulateRealtimePipeline(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    now_epoch_sec: JLong,
) -> JLongArray {
    let mut step = empty_step_result();
    unsafe {
        koe_session_simulate_realtime_pipeline(
            handle as u64,
            now_epoch_sec.max(0) as u64,
            &mut step,
        );
        jni_new_longs(env, &step_to_longs(&step))
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionTakeFinalizedMeta(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let h = handle as u64;
    let taken = session_map()
        .lock()
        .ok()
        .and_then(|mut map| map.get_mut(&h)?.inner.last_finalized.take());
    let Some(fin) = taken else {
        return std::ptr::null_mut();
    };
    let mut meta = Vec::with_capacity(6 + fin.entry.marks_ms.len());
    meta.push(i64::from(fin.entry.id));
    meta.push(i64::from(fin.entry.bean_file_id));
    meta.push(fin.entry.created_at_epoch_sec as i64);
    meta.push(fin.entry.duration_ms as i64);
    meta.push(i64::from(fin.entry.byte_count));
    meta.push(fin.entry.marks_ms.len() as i64);
    for m in &fin.entry.marks_ms {
        meta.push(*m as i64);
    }
    if let Ok(mut blobs) = finalized_blob_map().lock() {
        blobs.insert(
            h,
            JniFinalizedBlobs {
                ogg: fin.ogg_opus_bytes,
                wav: fin.preview_wav_bytes,
            },
        );
    }
    unsafe { jni_new_longs(env, &meta) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionTakeFinalizedOgg(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let h = handle as u64;
    let ogg = finalized_blob_map()
        .lock()
        .ok()
        .and_then(|mut map| map.get_mut(&h).map(|b| std::mem::take(&mut b.ogg)))
        .unwrap_or_default();
    if ogg.is_empty() {
        return std::ptr::null_mut();
    }
    unsafe { jni_new_bytes(env, &ogg) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionTakeFinalizedWav(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let h = handle as u64;
    let wav = finalized_blob_map()
        .lock()
        .ok()
        .and_then(|mut map| map.get_mut(&h).map(|b| std::mem::take(&mut b.wav)))
        .unwrap_or_default();
    if wav.is_empty() {
        return std::ptr::null_mut();
    }
    unsafe { jni_new_bytes(env, &wav) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionTakeLivePcm16(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut out_len = 0usize;
    let ptr = unsafe { koe_session_take_live_pcm16(handle as u64, &mut out_len) };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let arr = unsafe { jni_new_bytes(env, slice) };
    unsafe {
        koe_buffer_free(ptr, out_len);
    }
    arr
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_libraryNew(
    _env: JniEnv,
    _cls: JClass,
) -> JLong {
    koe_library_new() as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_libraryFree(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_library_free(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_libraryIngestEntry(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    id: JInt,
    bean_file_id: JInt,
    created_at_epoch_sec: JLong,
    duration_ms: JLong,
    byte_count: JInt,
    marks_ms: JLongArray,
) -> JBoolean {
    let marks_vec = unsafe { jni_read_longs(env, marks_ms) };
    let mut marks_arr = [0u64; 32];
    let count = marks_vec.len().min(32);
    for (dst, &src) in marks_arr.iter_mut().zip(marks_vec.iter().take(count)) {
        *dst = src.max(0) as u64;
    }
    let entry = KoeRecordingEntry {
        id: id as u32,
        bean_file_id: bean_file_id as u32,
        created_at_epoch_sec: created_at_epoch_sec.max(0) as u64,
        duration_ms: duration_ms.max(0) as u64,
        byte_count: byte_count.max(0) as u32,
        mark_count: count as u32,
        marks_ms: marks_arr,
    };
    (unsafe { koe_library_ingest_entry(handle as u64, &entry) } == 1) as JBoolean
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_librarySelect(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
    recording_id: JInt,
) -> JBoolean {
    let mut playhead = 0u64;
    unsafe { koe_library_select(handle as u64, recording_id as u32, &mut playhead) }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_librarySeekMs(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
    position_ms: JLong,
) -> JLong {
    koe_library_seek_ms(handle as u64, position_ms.max(0) as u64) as JLong
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_libraryJumpToMark(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
    current_ms: JLong,
    direction: JInt,
) -> JLong {
    let mut target = 0u64;
    let ok = unsafe {
        koe_library_jump_to_mark(
            handle as u64,
            current_ms.max(0) as u64,
            direction,
            &mut target,
        )
    };
    if ok == 1 {
        target as JLong
    } else {
        -1
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_libraryMoveToTrash(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
    recording_id: JInt,
) -> JBoolean {
    unsafe { koe_library_move_to_trash(handle as u64, recording_id as u32, std::ptr::null_mut()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_libraryUndoTrash(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JInt {
    let mut restored = KoeRecordingEntry {
        id: 0,
        bean_file_id: 0,
        created_at_epoch_sec: 0,
        duration_ms: 0,
        byte_count: 0,
        mark_count: 0,
        marks_ms: [0; 32],
    };
    let ok = unsafe { koe_library_undo_trash(handle as u64, &mut restored) };
    if ok == 1 {
        restored.id as JInt
    } else {
        0
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_librarySnapshot(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut snap = KoeLibrarySnapshot {
        entry_count: 0,
        selected_recording_id: 0,
        playhead_ms: 0,
        has_last_trashed: 0,
        reserved: [0; 7],
        last_trashed_id: 0,
        pad_tail: 0,
    };
    unsafe {
        koe_library_snapshot(handle as u64, &mut snap);
        let values = [
            i64::from(snap.entry_count),
            i64::from(snap.selected_recording_id),
            snap.playhead_ms as i64,
            i64::from(snap.has_last_trashed),
            i64::from(snap.last_trashed_id),
        ];
        jni_new_longs(env, &values)
    }
}
