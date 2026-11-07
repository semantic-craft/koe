//! Zero-dependency JNI C-ABI bindings (`com.anker.anker_recorder.KoeCoreNative`)
//! backed by the standard `JNINativeInterface_` function pointer table.

use std::collections::BTreeMap;
use std::ffi::c_void;
use std::sync::{Mutex, OnceLock};

use crate::{
    koe_buffer_free, koe_cicada_rolling_accept_candidate, koe_cicada_rolling_add_segment,
    koe_cicada_rolling_complete, koe_cicada_rolling_edit, koe_cicada_rolling_free,
    koe_cicada_rolling_get_active, koe_cicada_rolling_new, koe_cicada_rolling_poll_tick,
    koe_cicada_rolling_status, koe_cicada_silence_reduce, koe_context_format_coarse_place,
    koe_context_is_delegation_request, koe_context_names_todo, koe_context_search_add_doc,
    koe_context_search_free, koe_context_search_new, koe_context_search_query,
    koe_context_search_status, koe_koepack_encode_demo_v2, koe_koepack_verify_v2,
    koe_library_free, koe_library_ingest_entry, koe_library_jump_to_mark,
    koe_library_move_to_trash, koe_library_new, koe_library_seek_ms, koe_library_select,
    koe_library_snapshot, koe_library_undo_trash, koe_mcp_acp_configure_pairing,
    koe_mcp_acp_dispatch_jsonrpc, koe_mcp_acp_free, koe_mcp_acp_ingest_utterance,
    koe_mcp_acp_new, koe_mcp_acp_publish_live, koe_mcp_acp_put_pack, koe_mcp_acp_status,
    koe_mcp_acp_verify_bearer, koe_minutes_plan_batches_count,
    koe_minutes_replace_terms_utf8, koe_minutes_validate_claim_grounding,
    koe_minutes_validate_json, koe_opus_decode_pcm16, koe_opus_decode_wav, koe_protocol_checksum,
    koe_protocol_encode, koe_protocol_verify_checksum, koe_qwen_parse_transcript_into_spine,
    koe_reassembler_free, koe_reassembler_ingest,
    koe_reassembler_new, koe_reassembler_pop_packet, koe_reassembler_reset,
    koe_session_accept_ecdh_reply, koe_session_begin_offline_pull, koe_session_begin_wifi_batch,
    koe_session_cancel_wifi_batch, koe_session_free, koe_session_get_wifi_batch_progress,
    koe_session_get_wifi_endpoint, koe_session_ingest_ble_chunk, koe_session_ingest_wifi_chunk,
    koe_session_new, koe_session_on_transport_interrupted, koe_session_on_wifi_interrupted,
    koe_session_poll_timers, koe_session_pop_outbound_tx, koe_session_pop_outbound_wifi_udp,
    koe_session_pop_outbound_wifi_ws, koe_session_resume_offline_pull,
    koe_session_resume_wifi_batch, koe_session_simulate_realtime_pipeline,
    koe_session_stop_realtime_recording, koe_session_take_live_pcm16,
    koe_spine_accept_cumulative, koe_spine_append_segment, koe_spine_clear_stale,
    koe_spine_format_cited_sources, koe_spine_free, koe_spine_get_segment, koe_spine_new,
    koe_spine_set_translation, koe_spine_snapshot, koe_spine_update_segment_text,
    koe_wifi_build_file_request_hex, koe_wifi_build_transfer_complete_hex,
    koe_wifi_keepalive_payload, koe_wifi_parse_config_response, koe_wifi_shares_subnet,
    session_map, KoeCicadaRollingStatus, KoeContextSearchStatus, KoeLibrarySnapshot,
    KoeMcpAcpStatus, KoeRecordingEntry, KoeSessionStepResult, KoeUtteranceSegmentHeader,
    KoeUtteranceSpineSnapshot, KoeWifiBatchProgress, KoeWifiEndpoint,
};
use koe_core::crypto::DeviceCrypto;
use koe_core::ogg_opus::OggOpus;
use koe_core::wav::OpusWave;

type JniEnv = *mut *const *const c_void;
type JClass = *mut c_void;
type JString = *mut c_void;
type JArray = *mut c_void;
type JByteArray = *mut c_void;
type JLongArray = *mut c_void;
type JSize = i32;
type JBoolean = u8;
type JInt = i32;
type JLong = i64;

const SLOT_NEW_STRING_UTF: usize = 167;
const SLOT_GET_STRING_UTF_LENGTH: usize = 168;
const SLOT_GET_STRING_UTF_CHARS: usize = 169;
const SLOT_RELEASE_STRING_UTF_CHARS: usize = 170;
const SLOT_GET_ARRAY_LENGTH: usize = 171;
const SLOT_NEW_BYTE_ARRAY: usize = 176;
const SLOT_NEW_LONG_ARRAY: usize = 180;
const SLOT_GET_BYTE_ARRAY_REGION: usize = 200;
const SLOT_GET_LONG_ARRAY_REGION: usize = 204;
const SLOT_SET_BYTE_ARRAY_REGION: usize = 208;
const SLOT_SET_LONG_ARRAY_REGION: usize = 212;

type FnNewStringUtf = unsafe extern "C" fn(JniEnv, *const u8) -> JString;
type FnGetStringUtfLength = unsafe extern "C" fn(JniEnv, JString) -> JSize;
type FnGetStringUtfChars = unsafe extern "C" fn(JniEnv, JString, *mut JBoolean) -> *const u8;
type FnReleaseStringUtfChars = unsafe extern "C" fn(JniEnv, JString, *const u8);
type FnGetArrayLength = unsafe extern "C" fn(JniEnv, JArray) -> JSize;
type FnNewByteArray = unsafe extern "C" fn(JniEnv, JSize) -> JByteArray;
type FnNewLongArray = unsafe extern "C" fn(JniEnv, JSize) -> JLongArray;
type FnGetByteArrayRegion = unsafe extern "C" fn(JniEnv, JByteArray, JSize, JSize, *mut i8);
type FnGetLongArrayRegion = unsafe extern "C" fn(JniEnv, JLongArray, JSize, JSize, *mut i64);
type FnSetByteArrayRegion = unsafe extern "C" fn(JniEnv, JByteArray, JSize, JSize, *const i8);
type FnSetLongArrayRegion = unsafe extern "C" fn(JniEnv, JLongArray, JSize, JSize, *const i64);

unsafe fn jni_read_string(env: JniEnv, s: JString) -> String {
    if env.is_null() || s.is_null() {
        return String::new();
    }
    let vtable = unsafe { *env };
    let get_len: FnGetStringUtfLength =
        unsafe { std::mem::transmute(*vtable.add(SLOT_GET_STRING_UTF_LENGTH)) };
    let len = unsafe { get_len(env, s) };
    if len <= 0 {
        return String::new();
    }
    let get_chars: FnGetStringUtfChars =
        unsafe { std::mem::transmute(*vtable.add(SLOT_GET_STRING_UTF_CHARS)) };
    let chars = unsafe { get_chars(env, s, std::ptr::null_mut()) };
    if chars.is_null() {
        return String::new();
    }
    let slice = unsafe { std::slice::from_raw_parts(chars, len as usize) };
    let out = String::from_utf8_lossy(slice).into_owned();
    let release_chars: FnReleaseStringUtfChars =
        unsafe { std::mem::transmute(*vtable.add(SLOT_RELEASE_STRING_UTF_CHARS)) };
    unsafe {
        release_chars(env, s, chars);
    }
    out
}

unsafe fn jni_new_string(env: JniEnv, text: &str) -> JString {
    if env.is_null() {
        return std::ptr::null_mut();
    }
    let vtable = unsafe { *env };
    let new_str: FnNewStringUtf =
        unsafe { std::mem::transmute(*vtable.add(SLOT_NEW_STRING_UTF)) };
    let mut c_bytes = Vec::with_capacity(text.len() + 1);
    for &b in text.as_bytes() {
        if b != 0 {
            c_bytes.push(b);
        }
    }
    c_bytes.push(0);
    unsafe { new_str(env, c_bytes.as_ptr()) }
}

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
        .and_then(|mut map| map.get_mut(&h)?.inner.take_next_finalized());
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

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_wifiParseConfigResponse(
    env: JniEnv,
    _cls: JClass,
    raw: JByteArray,
) -> JLongArray {
    let bytes = unsafe { jni_read_bytes(env, raw) };
    let mut ep = KoeWifiEndpoint {
        ip: [0; 4],
        port: 0,
        reserved: [0; 2],
    };
    let ok = unsafe { koe_wifi_parse_config_response(bytes.as_ptr(), bytes.len(), &mut ep) };
    if ok == 0 {
        return std::ptr::null_mut();
    }
    let values = [
        i64::from(ep.ip[0]),
        i64::from(ep.ip[1]),
        i64::from(ep.ip[2]),
        i64::from(ep.ip[3]),
        i64::from(ep.port),
    ];
    unsafe { jni_new_longs(env, &values) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_wifiSharesSubnet(
    env: JniEnv,
    _cls: JClass,
    device_ip: JByteArray,
    local_ip: JByteArray,
) -> JBoolean {
    let dev = unsafe { jni_read_bytes(env, device_ip) };
    let loc = unsafe { jni_read_bytes(env, local_ip) };
    if dev.len() < 4 || loc.len() < 4 {
        return 0;
    }
    unsafe { koe_wifi_shares_subnet(dev.as_ptr(), loc.as_ptr()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_wifiBuildFileRequestHex(
    env: JniEnv,
    _cls: JClass,
    file_id: JInt,
    already_transferred: JInt,
) -> JByteArray {
    let mut out = [0u8; 64];
    let n = unsafe {
        koe_wifi_build_file_request_hex(
            file_id as u32,
            already_transferred.max(0) as u32,
            out.as_mut_ptr(),
            out.len(),
        )
    };
    unsafe { jni_new_bytes(env, &out[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_wifiBuildTransferCompleteHex(
    env: JniEnv,
    _cls: JClass,
) -> JByteArray {
    let mut out = [0u8; 64];
    let n = unsafe { koe_wifi_build_transfer_complete_hex(out.as_mut_ptr(), out.len()) };
    unsafe { jni_new_bytes(env, &out[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_wifiKeepalivePayload(
    env: JniEnv,
    _cls: JClass,
) -> JByteArray {
    let mut out = [0u8; 64];
    let n = unsafe { koe_wifi_keepalive_payload(out.as_mut_ptr(), out.len()) };
    unsafe { jni_new_bytes(env, &out[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionBeginWifiBatch(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    file_ids: JLongArray,
) -> JBoolean {
    let raw_ids = unsafe { jni_read_longs(env, file_ids) };
    let ids: Vec<u32> = raw_ids.into_iter().map(|v| v.max(0) as u32).collect();
    unsafe { koe_session_begin_wifi_batch(handle as u64, ids.as_ptr(), ids.len()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionIngestWifiChunk(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    chunk: JByteArray,
    now_epoch_sec: JLong,
) -> JLongArray {
    let bytes = unsafe { jni_read_bytes(env, chunk) };
    let mut step = empty_step_result();
    unsafe {
        koe_session_ingest_wifi_chunk(
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
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionPopOutboundWifiWs(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut buf = [0u8; 512];
    let n = unsafe {
        koe_session_pop_outbound_wifi_ws(handle as u64, buf.as_mut_ptr(), buf.len())
    };
    if n == 0 {
        return std::ptr::null_mut();
    }
    unsafe { jni_new_bytes(env, &buf[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionPopOutboundWifiUdp(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut buf = [0u8; 512];
    let n = unsafe {
        koe_session_pop_outbound_wifi_udp(handle as u64, buf.as_mut_ptr(), buf.len())
    };
    if n == 0 {
        return std::ptr::null_mut();
    }
    unsafe { jni_new_bytes(env, &buf[..n]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionGetWifiBatchProgress(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut prog = KoeWifiBatchProgress {
        phase: 0,
        error_code: 0,
        reserved: [0; 2],
        current_file_index: 0,
        total_files: 0,
        active_file_id: 0,
        received_wire_bytes: 0,
        expected_wire_bytes: 0,
        finalized_count: 0,
        salvaged_count: 0,
        skipped_count: 0,
        remaining_count: 0,
    };
    unsafe {
        koe_session_get_wifi_batch_progress(handle as u64, &mut prog);
        let values = [
            i64::from(prog.phase),
            i64::from(prog.error_code),
            i64::from(prog.current_file_index),
            i64::from(prog.total_files),
            i64::from(prog.active_file_id),
            i64::from(prog.received_wire_bytes),
            i64::from(prog.expected_wire_bytes),
            i64::from(prog.finalized_count),
            i64::from(prog.salvaged_count),
            i64::from(prog.skipped_count),
            i64::from(prog.remaining_count),
        ];
        jni_new_longs(env, &values)
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionGetWifiEndpoint(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut ep = KoeWifiEndpoint {
        ip: [0; 4],
        port: 0,
        reserved: [0; 2],
    };
    let ok = unsafe { koe_session_get_wifi_endpoint(handle as u64, &mut ep) };
    if ok == 0 {
        return std::ptr::null_mut();
    }
    let values = [
        i64::from(ep.ip[0]),
        i64::from(ep.ip[1]),
        i64::from(ep.ip[2]),
        i64::from(ep.ip[3]),
        i64::from(ep.port),
    ];
    unsafe { jni_new_longs(env, &values) }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionOnWifiInterrupted(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
    now_epoch_sec: JLong,
) -> JBoolean {
    koe_session_on_wifi_interrupted(handle as u64, now_epoch_sec.max(0) as u64)
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionResumeWifiBatch(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JBoolean {
    koe_session_resume_wifi_batch(handle as u64)
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_sessionCancelWifiBatch(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_session_cancel_wifi_batch(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineNew(
    env: JniEnv,
    _cls: JClass,
    session_id: JByteArray,
) -> JLong {
    let sid = unsafe { jni_read_bytes(env, session_id) };
    unsafe { koe_spine_new(sid.as_ptr(), sid.len()) as JLong }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineFree(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_spine_free(handle as u64);
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineClearStale(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_spine_clear_stale(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineSnapshot(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut snap = KoeUtteranceSpineSnapshot {
        segment_count: 0,
        is_stale: 0,
        reserved: [0; 3],
        revision: 0,
    };
    unsafe {
        koe_spine_snapshot(handle as u64, &mut snap);
        let values = [
            i64::from(snap.segment_count),
            snap.revision as i64,
            i64::from(snap.is_stale),
        ];
        jni_new_longs(env, &values)
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineAppendSegment(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    text: JByteArray,
    start_ms: JLong,
    end_ms: JLong,
    source_lang: JByteArray,
    provider: JByteArray,
) -> JInt {
    let text_b = unsafe { jni_read_bytes(env, text) };
    let lang_b = unsafe { jni_read_bytes(env, source_lang) };
    let prov_b = unsafe { jni_read_bytes(env, provider) };
    unsafe {
        koe_spine_append_segment(
            handle as u64,
            text_b.as_ptr(),
            text_b.len(),
            start_ms.max(0) as u64,
            end_ms.max(0) as u64,
            lang_b.as_ptr(),
            lang_b.len(),
            prov_b.as_ptr(),
            prov_b.len(),
        ) as JInt
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineAcceptCumulative(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    conn_id: JByteArray,
    text: JByteArray,
    source_lang: JByteArray,
    translation: JByteArray,
    target_lang: JByteArray,
    provider: JByteArray,
) -> JInt {
    let conn_b = unsafe { jni_read_bytes(env, conn_id) };
    let text_b = unsafe { jni_read_bytes(env, text) };
    let lang_b = unsafe { jni_read_bytes(env, source_lang) };
    let tr_b = unsafe { jni_read_bytes(env, translation) };
    let tlang_b = unsafe { jni_read_bytes(env, target_lang) };
    let prov_b = unsafe { jni_read_bytes(env, provider) };
    unsafe {
        koe_spine_accept_cumulative(
            handle as u64,
            conn_b.as_ptr(),
            conn_b.len(),
            text_b.as_ptr(),
            text_b.len(),
            lang_b.as_ptr(),
            lang_b.len(),
            tr_b.as_ptr(),
            tr_b.len(),
            tlang_b.as_ptr(),
            tlang_b.len(),
            prov_b.as_ptr(),
            prov_b.len(),
        ) as JInt
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineUpdateSegmentText(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    ordinal: JInt,
    new_text: JByteArray,
) -> JBoolean {
    let text_b = unsafe { jni_read_bytes(env, new_text) };
    unsafe {
        koe_spine_update_segment_text(
            handle as u64,
            ordinal.max(0) as u32,
            text_b.as_ptr(),
            text_b.len(),
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineSetTranslation(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    ordinal: JInt,
    translation: JByteArray,
    target_lang: JByteArray,
) -> JBoolean {
    let tr_b = unsafe { jni_read_bytes(env, translation) };
    let tlang_b = unsafe { jni_read_bytes(env, target_lang) };
    unsafe {
        koe_spine_set_translation(
            handle as u64,
            ordinal.max(0) as u32,
            tr_b.as_ptr(),
            tr_b.len(),
            tlang_b.as_ptr(),
            tlang_b.len(),
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineGetSegmentMeta(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    ordinal: JInt,
) -> JLongArray {
    let mut hdr = KoeUtteranceSegmentHeader {
        ordinal: 0,
        revision: 0,
        start_ms: 0,
        end_ms: 0,
        is_final: 0,
        has_translation: 0,
        reserved: [0; 2],
        text_len: 0,
        translation_len: 0,
        source_language: [0; 16],
        target_language: [0; 16],
    };
    let ok = unsafe {
        koe_spine_get_segment(
            handle as u64,
            ordinal.max(0) as u32,
            &mut hdr,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            0,
        )
    };
    if ok == 0 {
        return std::ptr::null_mut();
    }
    let values = [
        i64::from(hdr.ordinal),
        i64::from(hdr.revision),
        hdr.start_ms as i64,
        hdr.end_ms as i64,
        i64::from(hdr.is_final),
        i64::from(hdr.has_translation),
    ];
    unsafe { jni_new_longs(env, &values) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineGetSegmentText(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    ordinal: JInt,
) -> JByteArray {
    let mut hdr = KoeUtteranceSegmentHeader {
        ordinal: 0,
        revision: 0,
        start_ms: 0,
        end_ms: 0,
        is_final: 0,
        has_translation: 0,
        reserved: [0; 2],
        text_len: 0,
        translation_len: 0,
        source_language: [0; 16],
        target_language: [0; 16],
    };
    let ok = unsafe {
        koe_spine_get_segment(
            handle as u64,
            ordinal.max(0) as u32,
            &mut hdr,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            0,
        )
    };
    if ok == 0 || hdr.text_len == 0 {
        return std::ptr::null_mut();
    }
    let mut text_buf = vec![0u8; hdr.text_len as usize];
    unsafe {
        koe_spine_get_segment(
            handle as u64,
            ordinal.max(0) as u32,
            &mut hdr,
            text_buf.as_mut_ptr(),
            text_buf.len(),
            std::ptr::null_mut(),
            0,
        );
        jni_new_bytes(env, &text_buf)
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineGetSegmentTranslation(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    ordinal: JInt,
) -> JByteArray {
    let mut hdr = KoeUtteranceSegmentHeader {
        ordinal: 0,
        revision: 0,
        start_ms: 0,
        end_ms: 0,
        is_final: 0,
        has_translation: 0,
        reserved: [0; 2],
        text_len: 0,
        translation_len: 0,
        source_language: [0; 16],
        target_language: [0; 16],
    };
    let ok = unsafe {
        koe_spine_get_segment(
            handle as u64,
            ordinal.max(0) as u32,
            &mut hdr,
            std::ptr::null_mut(),
            0,
            std::ptr::null_mut(),
            0,
        )
    };
    if ok == 0 || hdr.has_translation == 0 || hdr.translation_len == 0 {
        return std::ptr::null_mut();
    }
    let mut tr_buf = vec![0u8; hdr.translation_len as usize];
    unsafe {
        koe_spine_get_segment(
            handle as u64,
            ordinal.max(0) as u32,
            &mut hdr,
            std::ptr::null_mut(),
            0,
            tr_buf.as_mut_ptr(),
            tr_buf.len(),
        );
        jni_new_bytes(env, &tr_buf)
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_spineFormatCitedSources(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut out_len = 0usize;
    let ptr = unsafe { koe_spine_format_cited_sources(handle as u64, &mut out_len) };
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
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_minutesValidateClaimGrounding(
    env: JniEnv,
    _cls: JClass,
    spine_handle: JLong,
    claim: JByteArray,
    citations: JLongArray,
) -> JBoolean {
    let claim_b = unsafe { jni_read_bytes(env, claim) };
    let raw_cites = unsafe { jni_read_longs(env, citations) };
    let cites_u32: Vec<u32> = raw_cites.into_iter().map(|v| v.max(0) as u32).collect();
    unsafe {
        koe_minutes_validate_claim_grounding(
            spine_handle as u64,
            claim_b.as_ptr(),
            claim_b.len(),
            cites_u32.as_ptr(),
            cites_u32.len(),
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_minutesValidateJson(
    env: JniEnv,
    _cls: JClass,
    spine_handle: JLong,
    json: JByteArray,
) -> JInt {
    let json_b = unsafe { jni_read_bytes(env, json) };
    unsafe { koe_minutes_validate_json(spine_handle as u64, json_b.as_ptr(), json_b.len()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_minutesReplaceTermsUtf8(
    env: JniEnv,
    _cls: JClass,
    text: JByteArray,
    from_terms: JByteArray,
    to_terms: JByteArray,
) -> JByteArray {
    let text_b = unsafe { jni_read_bytes(env, text) };
    let from_b = unsafe { jni_read_bytes(env, from_terms) };
    let to_b = unsafe { jni_read_bytes(env, to_terms) };
    let needed = unsafe {
        koe_minutes_replace_terms_utf8(
            text_b.as_ptr(),
            text_b.len(),
            from_b.as_ptr(),
            from_b.len(),
            to_b.as_ptr(),
            to_b.len(),
            std::ptr::null_mut(),
            0,
        )
    };
    if needed < 0 {
        return std::ptr::null_mut();
    }
    let mut out = vec![0u8; needed as usize];
    let written = unsafe {
        koe_minutes_replace_terms_utf8(
            text_b.as_ptr(),
            text_b.len(),
            from_b.as_ptr(),
            from_b.len(),
            to_b.as_ptr(),
            to_b.len(),
            out.as_mut_ptr(),
            out.len(),
        )
    };
    if written < 0 {
        return std::ptr::null_mut();
    }
    unsafe { jni_new_bytes(env, &out[..written as usize]) }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_minutesPlanBatchesCount(
    _env: JniEnv,
    _cls: JClass,
    spine_handle: JLong,
    max_runes: JInt,
) -> JInt {
    koe_minutes_plan_batches_count(spine_handle as u64, max_runes.max(0) as u32)
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_qwenParseTranscriptIntoSpine(
    env: JniEnv,
    _cls: JClass,
    spine_handle: JLong,
    json: JByteArray,
) -> JInt {
    let json_b = unsafe { jni_read_bytes(env, json) };
    unsafe {
        koe_qwen_parse_transcript_into_spine(spine_handle as u64, json_b.as_ptr(), json_b.len())
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_nativeCicadaSilenceReduce(
    env: JniEnv,
    _cls: JClass,
    silence_elapsed_ms: JLong,
    delta_ms: JLong,
    speech_detected: JBoolean,
    already_auto_stopped: JBoolean,
) -> JLongArray {
    let mut next_elapsed = 0u64;
    let mut auto_stopped = 0u8;
    let triggered = unsafe {
        koe_cicada_silence_reduce(
            silence_elapsed_ms.max(0) as u64,
            delta_ms.max(0) as u64,
            speech_detected,
            already_auto_stopped,
            &mut next_elapsed,
            &mut auto_stopped,
        )
    };
    let out = [
        next_elapsed as i64,
        i64::from(auto_stopped),
        i64::from(triggered),
    ];
    unsafe { jni_new_longs(env, &out) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaSilenceReduce(
    env: JniEnv,
    cls: JClass,
    silence_elapsed_ms: JLong,
    delta_ms: JLong,
    speech_detected: JBoolean,
    already_auto_stopped: JBoolean,
) -> JLongArray {
    unsafe {
        Java_com_anker_anker_1recorder_KoeCoreNative_nativeCicadaSilenceReduce(
            env,
            cls,
            silence_elapsed_ms,
            delta_ms,
            speech_detected,
            already_auto_stopped,
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_nativeKoepackVerifyV2(
    env: JniEnv,
    _cls: JClass,
    pack: JByteArray,
) -> JInt {
    let pack_b = unsafe { jni_read_bytes(env, pack) };
    unsafe { koe_koepack_verify_v2(pack_b.as_ptr(), pack_b.len()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_koepackVerifyV2(
    env: JniEnv,
    cls: JClass,
    pack: JByteArray,
) -> JInt {
    unsafe { Java_com_anker_anker_1recorder_KoeCoreNative_nativeKoepackVerifyV2(env, cls, pack) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_nativeKoepackEncodeDemoV2(
    env: JniEnv,
    _cls: JClass,
    content_hash: JByteArray,
    title: JByteArray,
    source: JByteArray,
    minutes_json: JByteArray,
) -> JByteArray {
    let hash_b = unsafe { jni_read_bytes(env, content_hash) };
    let title_b = unsafe { jni_read_bytes(env, title) };
    let source_b = unsafe { jni_read_bytes(env, source) };
    let minutes_b = unsafe { jni_read_bytes(env, minutes_json) };
    let mut out_len = 0usize;
    let ptr = unsafe {
        koe_koepack_encode_demo_v2(
            hash_b.as_ptr(),
            hash_b.len(),
            title_b.as_ptr(),
            title_b.len(),
            source_b.as_ptr(),
            source_b.len(),
            minutes_b.as_ptr(),
            minutes_b.len(),
            &mut out_len,
        )
    };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let arr = unsafe { jni_new_bytes(env, slice) };
    unsafe { koe_buffer_free(ptr, out_len) };
    arr
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_koepackEncodeDemoV2(
    env: JniEnv,
    cls: JClass,
    content_hash: JByteArray,
    title: JByteArray,
    source: JByteArray,
    minutes_json: JByteArray,
) -> JByteArray {
    unsafe {
        Java_com_anker_anker_1recorder_KoeCoreNative_nativeKoepackEncodeDemoV2(
            env,
            cls,
            content_hash,
            title,
            source,
            minutes_json,
        )
    }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextSearchNew(
    _env: JniEnv,
    _cls: JClass,
) -> JLong {
    koe_context_search_new() as JLong
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextSearchFree(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_context_search_free(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextSearchAddDoc(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    text: JByteArray,
) -> JInt {
    let text_b = unsafe { jni_read_bytes(env, text) };
    unsafe { koe_context_search_add_doc(handle as u64, text_b.as_ptr(), text_b.len()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextSearchQuery(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    query: JByteArray,
    limit: JInt,
) -> JLongArray {
    let query_b = unsafe { jni_read_bytes(env, query) };
    let cap = limit.max(0) as usize;
    if cap == 0 {
        return unsafe { jni_new_longs(env, &[]) };
    }
    let mut indices = vec![0u32; cap];
    let total = unsafe {
        koe_context_search_query(
            handle as u64,
            query_b.as_ptr(),
            query_b.len(),
            cap as u32,
            indices.as_mut_ptr(),
            cap,
        )
    };
    let n = total.min(cap);
    let longs: Vec<i64> = indices[..n].iter().map(|&idx| i64::from(idx)).collect();
    unsafe { jni_new_longs(env, &longs) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextSearchStatus(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut st = KoeContextSearchStatus {
        doc_count: 0,
        total_chars: 0,
        vocab_size: 0,
        last_hit_count: 0,
    };
    let ok = unsafe { koe_context_search_status(handle as u64, &mut st) };
    if ok == 0 {
        return unsafe { jni_new_longs(env, &[]) };
    }
    let out = [
        i64::from(st.doc_count),
        i64::from(st.total_chars),
        i64::from(st.vocab_size),
        i64::from(st.last_hit_count),
    ];
    unsafe { jni_new_longs(env, &out) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextFormatCoarsePlace(
    env: JniEnv,
    _cls: JClass,
    parts_joined: JByteArray,
) -> JByteArray {
    let parts_b = unsafe { jni_read_bytes(env, parts_joined) };
    let needed = unsafe {
        koe_context_format_coarse_place(
            parts_b.as_ptr(),
            parts_b.len(),
            std::ptr::null_mut(),
            0,
        )
    };
    if needed <= 0 {
        return unsafe { jni_new_bytes(env, &[]) };
    }
    let mut out = vec![0u8; needed as usize];
    let written = unsafe {
        koe_context_format_coarse_place(
            parts_b.as_ptr(),
            parts_b.len(),
            out.as_mut_ptr(),
            out.len(),
        )
    };
    if written <= 0 {
        return unsafe { jni_new_bytes(env, &[]) };
    }
    unsafe { jni_new_bytes(env, &out[..written as usize]) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextIsDelegationRequest(
    env: JniEnv,
    _cls: JClass,
    text: JByteArray,
) -> JBoolean {
    let text_b = unsafe { jni_read_bytes(env, text) };
    unsafe { koe_context_is_delegation_request(text_b.as_ptr(), text_b.len()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_contextNamesTodo(
    env: JniEnv,
    _cls: JClass,
    mention: JByteArray,
    sentence: JByteArray,
    title: JByteArray,
) -> JBoolean {
    let m_b = unsafe { jni_read_bytes(env, mention) };
    let s_b = unsafe { jni_read_bytes(env, sentence) };
    let t_b = unsafe { jni_read_bytes(env, title) };
    unsafe {
        koe_context_names_todo(
            m_b.as_ptr(),
            m_b.len(),
            s_b.as_ptr(),
            s_b.len(),
            t_b.as_ptr(),
            t_b.len(),
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingNew(
    env: JniEnv,
    _cls: JClass,
    session_id: JByteArray,
) -> JLong {
    let sid = unsafe { jni_read_bytes(env, session_id) };
    unsafe { koe_cicada_rolling_new(sid.as_ptr(), sid.len()) as JLong }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingFree(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_cicada_rolling_free(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingAddSegment(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    seg_id: JByteArray,
    text: JByteArray,
    now_ms: JLong,
) -> JBoolean {
    let id_b = unsafe { jni_read_bytes(env, seg_id) };
    let text_b = unsafe { jni_read_bytes(env, text) };
    unsafe {
        koe_cicada_rolling_add_segment(
            handle as u64,
            id_b.as_ptr(),
            id_b.len(),
            text_b.as_ptr(),
            text_b.len(),
            now_ms.max(0) as u64,
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingPollTick(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    now_ms: JLong,
) -> JByteArray {
    let mut from_idx = 0u32;
    let mut end_idx = 0u32;
    let mut generation = 0u64;
    let mut out_len = 0usize;
    let ptr = unsafe {
        koe_cicada_rolling_poll_tick(
            handle as u64,
            now_ms.max(0) as u64,
            &mut from_idx,
            &mut end_idx,
            &mut generation,
            &mut out_len,
        )
    };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let payload = unsafe {
        std::str::from_utf8(std::slice::from_raw_parts(ptr, out_len))
            .unwrap_or("")
            .to_string()
    };
    unsafe { koe_buffer_free(ptr, out_len) };
    let combined = format!("{from_idx}\n{end_idx}\n{generation}\n{payload}");
    unsafe { jni_new_bytes(env, combined.as_bytes()) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingComplete(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    generation: JLong,
    from_index: JInt,
    end_index: JInt,
    raw_json: JByteArray,
) -> JInt {
    let json_b = unsafe { jni_read_bytes(env, raw_json) };
    unsafe {
        koe_cicada_rolling_complete(
            handle as u64,
            generation.max(0) as u64,
            from_index.max(0) as u32,
            end_index.max(0) as u32,
            json_b.as_ptr(),
            json_b.len(),
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingEdit(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    edited_json: JByteArray,
) -> JInt {
    let json_b = unsafe { jni_read_bytes(env, edited_json) };
    unsafe { koe_cicada_rolling_edit(handle as u64, json_b.as_ptr(), json_b.len()) }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingAcceptCandidate(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JBoolean {
    koe_cicada_rolling_accept_candidate(handle as u64)
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingGetActive(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JByteArray {
    let mut out_len = 0usize;
    let ptr = unsafe { koe_cicada_rolling_get_active(handle as u64, &mut out_len) };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let arr = unsafe { jni_new_bytes(env, slice) };
    unsafe { koe_buffer_free(ptr, out_len) };
    arr
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_cicadaRollingStatus(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut st = KoeCicadaRollingStatus {
        paused: 0,
        closed: 0,
        edited: 0,
        has_candidate: 0,
        request_status: 0,
        reserved: [0; 3],
        watermark: 0,
        calls_this_hour: 0,
        generation: 0,
    };
    let ok = unsafe { koe_cicada_rolling_status(handle as u64, &mut st) };
    if ok == 0 {
        return unsafe { jni_new_longs(env, &[]) };
    }
    let out = [
        i64::from(st.paused),
        i64::from(st.closed),
        i64::from(st.edited),
        i64::from(st.has_candidate),
        i64::from(st.request_status),
        i64::from(st.watermark),
        i64::from(st.calls_this_hour),
        st.generation as i64,
    ];
    unsafe { jni_new_longs(env, &out) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpNew(
    env: JniEnv,
    _cls: JClass,
    session_id: JString,
) -> JLong {
    let sid = unsafe { jni_read_string(env, session_id) };
    unsafe { koe_mcp_acp_new(sid.as_ptr(), sid.len()) as JLong }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpFree(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
) {
    koe_mcp_acp_free(handle as u64);
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpConfigurePairing(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    base_url: JString,
    token: JString,
    mode_is_lan: JBoolean,
    expires_at_epoch_sec: JLong,
) -> JString {
    let url_s = unsafe { jni_read_string(env, base_url) };
    let tok_s = unsafe { jni_read_string(env, token) };
    let mut out_len = 0usize;
    let ptr = unsafe {
        koe_mcp_acp_configure_pairing(
            handle as u64,
            url_s.as_ptr(),
            url_s.len(),
            tok_s.as_ptr(),
            tok_s.len(),
            mode_is_lan,
            expires_at_epoch_sec.max(0) as u64,
            &mut out_len,
        )
    };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let ticket = String::from_utf8_lossy(slice).into_owned();
    unsafe { koe_buffer_free(ptr, out_len) };
    unsafe { jni_new_string(env, &ticket) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpVerifyBearer(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    auth_header: JString,
    now_epoch_sec: JLong,
) -> JBoolean {
    let hdr = unsafe { jni_read_string(env, auth_header) };
    unsafe {
        koe_mcp_acp_verify_bearer(
            handle as u64,
            hdr.as_ptr(),
            hdr.len(),
            now_epoch_sec.max(0) as u64,
        )
    }
}

#[no_mangle]
pub extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpPublishLive(
    _env: JniEnv,
    _cls: JClass,
    handle: JLong,
    generation: JLong,
    now_epoch_sec: JLong,
    ttl_sec: JInt,
) -> JInt {
    koe_mcp_acp_publish_live(
        handle as u64,
        generation.max(0) as u64,
        now_epoch_sec.max(0) as u64,
        ttl_sec.max(0) as u32,
    )
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpIngestUtterance(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    text: JString,
    translation: JString,
    start_ms: JLong,
    end_ms: JLong,
    source_lang: JString,
    target_lang: JString,
    now_epoch_sec: JLong,
) -> JInt {
    let text_s = unsafe { jni_read_string(env, text) };
    let tr_s = unsafe { jni_read_string(env, translation) };
    let src_s = unsafe { jni_read_string(env, source_lang) };
    let tgt_s = unsafe { jni_read_string(env, target_lang) };
    unsafe {
        koe_mcp_acp_ingest_utterance(
            handle as u64,
            text_s.as_ptr(),
            text_s.len(),
            tr_s.as_ptr(),
            tr_s.len(),
            start_ms.max(0) as u64,
            end_ms.max(0) as u64,
            src_s.as_ptr(),
            src_s.len(),
            tgt_s.as_ptr(),
            tgt_s.len(),
            now_epoch_sec.max(0) as u64,
        ) as JInt
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpPutPack(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    material_id: JString,
    pack_bytes: JByteArray,
) -> JInt {
    let mat_id = unsafe { jni_read_string(env, material_id) };
    let pack = unsafe { jni_read_bytes(env, pack_bytes) };
    unsafe {
        koe_mcp_acp_put_pack(
            handle as u64,
            mat_id.as_ptr(),
            mat_id.len(),
            pack.as_ptr(),
            pack.len(),
        )
    }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpDispatchJsonRpc(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
    request_json: JString,
    now_epoch_sec: JLong,
) -> JString {
    let req = unsafe { jni_read_string(env, request_json) };
    let mut out_len = 0usize;
    let ptr = unsafe {
        koe_mcp_acp_dispatch_jsonrpc(
            handle as u64,
            req.as_ptr(),
            req.len(),
            now_epoch_sec.max(0) as u64,
            &mut out_len,
        )
    };
    if ptr.is_null() || out_len == 0 {
        return std::ptr::null_mut();
    }
    let slice = unsafe { std::slice::from_raw_parts(ptr, out_len) };
    let resp = String::from_utf8_lossy(slice).into_owned();
    unsafe { koe_buffer_free(ptr, out_len) };
    unsafe { jni_new_string(env, &resp) }
}

#[no_mangle]
pub unsafe extern "C" fn Java_com_anker_anker_1recorder_KoeCoreNative_mcpAcpStatus(
    env: JniEnv,
    _cls: JClass,
    handle: JLong,
) -> JLongArray {
    let mut st = KoeMcpAcpStatus {
        mcp_initialized: 0,
        mcp_ready: 0,
        acp_initialized: 0,
        has_pairing_ticket: 0,
        pack_count: 0,
        hotword_count: 0,
        acp_task_count: 0,
        handled_calls: 0,
        live_generation: 0,
        live_expires_at_sec: 0,
    };
    let ok = unsafe { koe_mcp_acp_status(handle as u64, &mut st) };
    if ok == 0 {
        return unsafe { jni_new_longs(env, &[]) };
    }
    let out = [
        i64::from(st.mcp_initialized),
        i64::from(st.mcp_ready),
        i64::from(st.acp_initialized),
        i64::from(st.has_pairing_ticket),
        i64::from(st.pack_count),
        i64::from(st.hotword_count),
        i64::from(st.acp_task_count),
        st.handled_calls as i64,
        st.live_generation as i64,
        st.live_expires_at_sec as i64,
    ];
    unsafe { jni_new_longs(env, &out) }
}
