#include "JniCallbacks.h"
#include "koe_host_api.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <jni.h>
#include <limits>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace {

constexpr size_t kMaxIdentifierBytes = 64 * 1024;
constexpr size_t kMaxCommandJsonBytes = 2 * 1024 * 1024;
constexpr size_t kMaxBleChunkBytes = 1024 * 1024;
constexpr jint kMaxPcmSamples = 8192;
constexpr uint32_t kPcmStatusRejected = 2;

static_assert(sizeof(jshort) == sizeof(int16_t),
              "JNI jshort must match int16_t");

void log_bridge_error(const char *message) noexcept {
#ifdef __ANDROID__
  __android_log_print(ANDROID_LOG_ERROR, "KoeNativeBridge", "%s", message);
#else
  (void)message;
#endif
}

class SessionContextRegistry {
 public:
  void insert(uint64_t handle, void *context) {
    std::lock_guard<std::mutex> lock(mutex_);
    entries_[handle] = context;
  }

  void *take(uint64_t handle) noexcept {
    std::lock_guard<std::mutex> lock(mutex_);
    const auto it = entries_.find(handle);
    if (it == entries_.end()) {
      return nullptr;
    }
    void *context = it->second;
    entries_.erase(it);
    return context;
  }

 private:
  std::mutex mutex_;
  std::unordered_map<uint64_t, void *> entries_;
};

SessionContextRegistry &session_contexts() {
  static SessionContextRegistry registry;
  return registry;
}

bool read_utf8_cstr(JNIEnv *env, jbyteArray array, size_t max_bytes,
                    std::string &out) {
  out.clear();
  if (env == nullptr || array == nullptr) {
    return false;
  }
  const jsize raw_len = env->GetArrayLength(array);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return false;
  }
  if (raw_len < 0 || static_cast<size_t>(raw_len) > max_bytes) {
    return false;
  }
  out.resize(static_cast<size_t>(raw_len));
  if (raw_len > 0) {
    env->GetByteArrayRegion(array, 0, raw_len,
                            reinterpret_cast<jbyte *>(out.data()));
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      out.clear();
      return false;
    }
    if (std::memchr(out.data(), '\0', out.size()) != nullptr) {
      out.clear();
      return false;
    }
  }
  return true;
}

jbyteArray owned_cstr_to_byte_array(JNIEnv *env, char *rust_str) {
  if (rust_str == nullptr) {
    return nullptr;
  }
  struct StringGuard {
    char *ptr;
    ~StringGuard() { koe_host_string_free(ptr); }
  } guard{rust_str};

  const size_t len = std::strlen(rust_str);
  if (len > static_cast<size_t>(std::numeric_limits<jsize>::max())) {
    return nullptr;
  }
  jbyteArray out = env->NewByteArray(static_cast<jsize>(len));
  if (out == nullptr || env->ExceptionCheck()) {
    return nullptr;
  }
  if (len > 0) {
    env->SetByteArrayRegion(out, 0, static_cast<jsize>(len),
                            reinterpret_cast<const jbyte *>(rust_str));
    if (env->ExceptionCheck()) {
      return nullptr;
    }
  }
  return out;
}

jbyteArray owned_bytes_to_byte_array(JNIEnv *env, KoeOwnedBytes bytes) {
  struct BytesGuard {
    KoeOwnedBytes owned;
    ~BytesGuard() { koe_host_bytes_free(owned); }
  } guard{bytes};

  if (bytes.ptr == nullptr || bytes.len == 0) {
    jbyteArray empty = env->NewByteArray(0);
    if (empty == nullptr || env->ExceptionCheck()) {
      return nullptr;
    }
    return empty;
  }
  if (bytes.len > static_cast<size_t>(std::numeric_limits<jsize>::max())) {
    return nullptr;
  }
  jbyteArray out = env->NewByteArray(static_cast<jsize>(bytes.len));
  if (out == nullptr || env->ExceptionCheck()) {
    return nullptr;
  }
  env->SetByteArrayRegion(out, 0, static_cast<jsize>(bytes.len),
                          reinterpret_cast<const jbyte *>(bytes.ptr));
  if (env->ExceptionCheck()) {
    return nullptr;
  }
  return out;
}

jlongArray make_pcm_receipt_array(JNIEnv *env, const KoePcmReceipt &receipt) {
  jlongArray out = env->NewLongArray(3);
  if (out == nullptr || env->ExceptionCheck()) {
    return nullptr;
  }
  const jlong values[3] = {
      static_cast<jlong>(receipt.generation),
      static_cast<jlong>(receipt.next_sequence),
      static_cast<jlong>(receipt.status),
  };
  env->SetLongArrayRegion(out, 0, 3, values);
  if (env->ExceptionCheck()) {
    return nullptr;
  }
  return out;
}

jlongArray make_playback_receipt_array(JNIEnv *env,
                                       const KoePlaybackReceipt &receipt) {
  jlongArray out = env->NewLongArray(7);
  if (out == nullptr || env->ExceptionCheck()) {
    return nullptr;
  }
  const jlong values[7] = {
      static_cast<jlong>(receipt.generation),
      static_cast<jlong>(receipt.prev_generation),
      static_cast<jlong>(receipt.position_ms),
      static_cast<jlong>(receipt.now_epoch_sec),
      receipt.is_playing ? 1 : 0,
      receipt.applied ? 1 : 0,
      receipt.needs_full_snapshot ? 1 : 0,
  };
  env->SetLongArrayRegion(out, 0, 7, values);
  if (env->ExceptionCheck()) {
    return nullptr;
  }
  return out;
}

}  // namespace

extern "C" {

static int32_t koe_credential_trampoline(void *context, uint32_t operation,
                                         const char *reference,
                                         const char *value, char *output,
                                         size_t capacity) {
  return koe::android::credential_callback(context, operation, reference, value,
                                           output, capacity);
}

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *) {
  if (vm == nullptr) {
    log_bridge_error("JNI_OnLoad received null JavaVM");
    return JNI_ERR;
  }
  koe::android::remember_java_vm(vm);
  return JNI_VERSION_1_6;
}

JNIEXPORT jint JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeApiVersion(JNIEnv *,
                                                                   jclass) {
  return static_cast<jint>(koe_host_api_version());
}

JNIEXPORT jlong JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionCreate(
    JNIEnv *env, jclass, jbyteArray directoryUtf8) {
  try {
    std::string directory;
    if (!read_utf8_cstr(env, directoryUtf8, kMaxIdentifierBytes, directory) ||
        directory.empty()) {
      return 0;
    }
    return static_cast<jlong>(koe_host_session_create(directory.c_str()));
  } catch (...) {
    log_bridge_error("nativeSessionCreate failed");
    return 0;
  }
}

JNIEXPORT jlong JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionCreateWithCredentials(
    JNIEnv *env, jclass, jbyteArray directoryUtf8, jobject credentialBridge,
    jboolean isolated) {
  try {
    std::string directory;
    if (!read_utf8_cstr(env, directoryUtf8, kMaxIdentifierBytes, directory) ||
        directory.empty()) {
      return 0;
    }
    void *context =
        koe::android::credential_bridge_create(env, credentialBridge);
    if (context == nullptr) {
      log_bridge_error("credential bridge initialization failed");
      return 0;
    }
    const uint64_t handle = koe_host_session_create_with_credentials(
        directory.c_str(), &koe_credential_trampoline, context,
        isolated == JNI_TRUE);
    if (handle == 0) {
      koe::android::credential_bridge_destroy(context);
      return 0;
    }
    try {
      session_contexts().insert(handle, context);
    } catch (...) {
      koe_host_session_destroy(handle);
      koe::android::credential_bridge_destroy(context);
      log_bridge_error("session context registration failed");
      return 0;
    }
    return static_cast<jlong>(handle);
  } catch (...) {
    log_bridge_error("nativeSessionCreateWithCredentials failed");
    return 0;
  }
}

JNIEXPORT jboolean JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDestroy(
    JNIEnv *, jclass, jlong handle) {
  if (handle <= 0) {
    return JNI_FALSE;
  }
  try {
    const auto session_handle = static_cast<uint64_t>(handle);
    // Destroy the Rust session first so worker threads stop before releasing JNI state.
    const bool destroyed = koe_host_session_destroy(session_handle);
    if (destroyed) {
      if (void *context = session_contexts().take(session_handle);
          context != nullptr) {
        koe::android::credential_bridge_destroy(context);
      }
    }
    return destroyed ? JNI_TRUE : JNI_FALSE;
  } catch (...) {
    log_bridge_error("nativeSessionDestroy failed");
    return JNI_FALSE;
  }
}

JNIEXPORT jlong JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionGeneration(
    JNIEnv *, jclass, jlong handle) {
  if (handle <= 0) {
    return 0;
  }
  return static_cast<jlong>(
      koe_host_session_generation(static_cast<uint64_t>(handle)));
}

JNIEXPORT jbyteArray JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionSnapshotJson(
    JNIEnv *env, jclass, jlong handle, jlong nowEpochSec) {
  if (handle <= 0 || nowEpochSec < 0) {
    return nullptr;
  }
  char *json = koe_host_session_snapshot_json(
      static_cast<uint64_t>(handle), static_cast<uint64_t>(nowEpochSec));
  return owned_cstr_to_byte_array(env, json);
}

JNIEXPORT jbyteArray JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDispatchJson(
    JNIEnv *env, jclass, jlong handle, jbyteArray commandUtf8,
    jlong nowEpochSec) {
  if (handle <= 0 || nowEpochSec < 0) {
    return nullptr;
  }
  try {
    std::string command;
    if (!read_utf8_cstr(env, commandUtf8, kMaxCommandJsonBytes, command)) {
      return nullptr;
    }
    char *json = koe_host_session_dispatch_json(
        static_cast<uint64_t>(handle), command.c_str(),
        static_cast<uint64_t>(nowEpochSec));
    return owned_cstr_to_byte_array(env, json);
  } catch (...) {
    log_bridge_error("nativeSessionDispatchJson failed");
    return nullptr;
  }
}

JNIEXPORT jlong JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionIngestBle(
    JNIEnv *env, jclass, jlong handle, jbyteArray bytes, jlong nowEpochSec) {
  if (env == nullptr || bytes == nullptr || handle <= 0 || nowEpochSec < 0) {
    return 0;
  }
  try {
    const jsize raw_len = env->GetArrayLength(bytes);
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      return 0;
    }
    if (raw_len < 0 || static_cast<size_t>(raw_len) > kMaxBleChunkBytes) {
      return 0;
    }
    if (raw_len == 0) {
      return static_cast<jlong>(koe_host_session_ingest_ble(
          static_cast<uint64_t>(handle), nullptr, 0,
          static_cast<uint64_t>(nowEpochSec)));
    }
    std::vector<uint8_t> buffer(static_cast<size_t>(raw_len));
    env->GetByteArrayRegion(bytes, 0, raw_len,
                            reinterpret_cast<jbyte *>(buffer.data()));
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      return 0;
    }
    return static_cast<jlong>(koe_host_session_ingest_ble(
        static_cast<uint64_t>(handle), buffer.data(), buffer.size(),
        static_cast<uint64_t>(nowEpochSec)));
  } catch (...) {
    log_bridge_error("nativeSessionIngestBle failed");
    return 0;
  }
}

JNIEXPORT jlongArray JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionIngestPcm(
    JNIEnv *env, jclass, jlong handle, jbyteArray recordId,
    jbyteArray sessionId, jbyteArray lane, jlong sequence, jlong epoch,
    jlong capturedStartNs, jboolean hasTiming, jshortArray samples,
    jint sampleCount, jlong nowEpochSec) {
  const KoePcmReceipt rejected{0, 0, kPcmStatusRejected, 0};
  if (handle <= 0 || sequence < 0 || epoch < 0 || capturedStartNs < 0 ||
      nowEpochSec < 0 || sampleCount < 0 || sampleCount > kMaxPcmSamples) {
    return make_pcm_receipt_array(env, rejected);
  }
  try {
    std::string rec_id;
    std::string ses_id;
    std::string lane_name;
    if (!read_utf8_cstr(env, recordId, kMaxIdentifierBytes, rec_id) ||
        !read_utf8_cstr(env, sessionId, kMaxIdentifierBytes, ses_id) ||
        !read_utf8_cstr(env, lane, kMaxIdentifierBytes, lane_name)) {
      return make_pcm_receipt_array(env, rejected);
    }
    if (sampleCount > 0) {
      if (samples == nullptr) {
        return make_pcm_receipt_array(env, rejected);
      }
      const jsize arr_len = env->GetArrayLength(samples);
      if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return make_pcm_receipt_array(env, rejected);
      }
      if (arr_len < sampleCount) {
        return make_pcm_receipt_array(env, rejected);
      }
    }

    std::array<int16_t, static_cast<size_t>(kMaxPcmSamples)> pcm_buffer;
    const int16_t *pcm_ptr = nullptr;
    if (sampleCount > 0) {
      env->GetShortArrayRegion(samples, 0, sampleCount,
                               reinterpret_cast<jshort *>(pcm_buffer.data()));
      if (env->ExceptionCheck()) {
        env->ExceptionClear();
        return make_pcm_receipt_array(env, rejected);
      }
      pcm_ptr = pcm_buffer.data();
    }

    const KoePcmReceipt receipt = koe_host_session_ingest_pcm(
        static_cast<uint64_t>(handle), rec_id.c_str(), ses_id.c_str(),
        lane_name.c_str(), static_cast<uint64_t>(sequence),
        static_cast<uint64_t>(epoch), static_cast<uint64_t>(capturedStartNs),
        hasTiming == JNI_TRUE, pcm_ptr, static_cast<size_t>(sampleCount),
        static_cast<uint64_t>(nowEpochSec));
    return make_pcm_receipt_array(env, receipt);
  } catch (...) {
    log_bridge_error("nativeSessionIngestPcm failed");
    return make_pcm_receipt_array(env, rejected);
  }
}

JNIEXPORT jlongArray JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionReportPlaybackProgress(
    JNIEnv *env, jclass, jlong handle, jbyteArray recordId, jlong requestId,
    jlong positionMs, jboolean isPlaying, jlong lastProjectedNowSec,
    jlong nowEpochSec) {
  const KoePlaybackReceipt empty{};
  if (handle <= 0 || requestId < 0 || positionMs < 0 ||
      lastProjectedNowSec < 0 || nowEpochSec < 0) {
    return make_playback_receipt_array(env, empty);
  }
  try {
    std::string rec_id;
    if (!read_utf8_cstr(env, recordId, kMaxIdentifierBytes, rec_id)) {
      return make_playback_receipt_array(env, empty);
    }
    const KoePlaybackReceipt receipt = koe_host_session_report_playback_progress(
        static_cast<uint64_t>(handle), rec_id.c_str(),
        static_cast<uint64_t>(requestId), static_cast<uint64_t>(positionMs),
        isPlaying == JNI_TRUE, static_cast<uint64_t>(lastProjectedNowSec),
        static_cast<uint64_t>(nowEpochSec));
    return make_playback_receipt_array(env, receipt);
  } catch (...) {
    log_bridge_error("nativeSessionReportPlaybackProgress failed");
    return make_playback_receipt_array(env, empty);
  }
}

JNIEXPORT jbyteArray JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDrainBleTx(
    JNIEnv *env, jclass, jlong handle) {
  if (handle <= 0) {
    return owned_bytes_to_byte_array(env, KoeOwnedBytes{});
  }
  return owned_bytes_to_byte_array(
      env, koe_host_session_drain_ble_tx(static_cast<uint64_t>(handle)));
}

JNIEXPORT jbyteArray JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionDrainLocalAsr(
    JNIEnv *env, jclass, jlong handle) {
  if (handle <= 0) {
    return owned_bytes_to_byte_array(env, KoeOwnedBytes{});
  }
  return owned_bytes_to_byte_array(
      env, koe_host_session_drain_local_asr(static_cast<uint64_t>(handle)));
}

JNIEXPORT jlong JNICALL
Java_com_semanticcraft_koe_bridge_KoeNativeBridge_nativeSessionPollTimers(
    JNIEnv *, jclass, jlong handle, jlong elapsedMs, jlong nowEpochSec) {
  if (handle <= 0 || elapsedMs < 0 || nowEpochSec < 0) {
    return 0;
  }
  return static_cast<jlong>(koe_host_session_poll_timers(
      static_cast<uint64_t>(handle), static_cast<uint64_t>(elapsedMs),
      static_cast<uint64_t>(nowEpochSec)));
}

}  // extern "C"
