#include "JniCallbacks.h"

#include <atomic>
#include <cstring>
#include <limits>
#include <new>

namespace koe::android {

namespace {

std::atomic<JavaVM *> g_java_vm{nullptr};

struct CredentialBridgeContext {
  JavaVM *vm = nullptr;
  jobject bridge = nullptr;
  jmethodID on_credential = nullptr;
};

class ThreadEnv {
 public:
  explicit ThreadEnv(JavaVM *vm) noexcept : vm_(vm) {
    if (vm_ == nullptr) {
      return;
    }
    void *current = nullptr;
    const jint status = vm_->GetEnv(&current, JNI_VERSION_1_6);
    if (status == JNI_OK) {
      env_ = static_cast<JNIEnv *>(current);
      return;
    }
    if (status != JNI_EDETACHED) {
      return;
    }
    char thread_name[] = "koe-credentials";
    JavaVMAttachArgs args{};
    args.version = JNI_VERSION_1_6;
    args.name = thread_name;
    args.group = nullptr;
#ifdef __ANDROID__
    JNIEnv *attached = nullptr;
#else
    void *attached = nullptr;
#endif
    if (vm_->AttachCurrentThread(&attached, &args) == JNI_OK) {
      env_ = static_cast<JNIEnv *>(attached);
      attached_ = true;
    }
  }

  ~ThreadEnv() noexcept {
    if (attached_ && vm_ != nullptr) {
      vm_->DetachCurrentThread();
    }
  }

  ThreadEnv(const ThreadEnv &) = delete;
  ThreadEnv &operator=(const ThreadEnv &) = delete;

  JNIEnv *get() const noexcept { return env_; }

 private:
  JavaVM *vm_ = nullptr;
  JNIEnv *env_ = nullptr;
  bool attached_ = false;
};

class LocalFrame {
 public:
  LocalFrame(JNIEnv *env, jint capacity) noexcept
      : env_(env),
        active_(env != nullptr && env->PushLocalFrame(capacity) == JNI_OK) {}

  ~LocalFrame() noexcept {
    if (active_) {
      env_->PopLocalFrame(nullptr);
    }
  }

  LocalFrame(const LocalFrame &) = delete;
  LocalFrame &operator=(const LocalFrame &) = delete;

  bool ok() const noexcept { return active_; }

 private:
  JNIEnv *env_ = nullptr;
  bool active_ = false;
};

bool cstr_to_utf8_bytes(JNIEnv *env, const char *text,
                        jbyteArray &out) noexcept {
  out = nullptr;
  if (text == nullptr) {
    return true;
  }
  const size_t len = std::strlen(text);
  if (len > static_cast<size_t>(std::numeric_limits<jsize>::max())) {
    return false;
  }
  jbyteArray array = env->NewByteArray(static_cast<jsize>(len));
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return false;
  }
  if (array == nullptr) {
    return false;
  }
  if (len > 0) {
    env->SetByteArrayRegion(array, 0, static_cast<jsize>(len),
                            reinterpret_cast<const jbyte *>(text));
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      return false;
    }
  }
  out = array;
  return true;
}

}  // namespace

void remember_java_vm(JavaVM *vm) noexcept {
  g_java_vm.store(vm, std::memory_order_release);
}

void *credential_bridge_create(JNIEnv *env, jobject bridge) noexcept {
  if (env == nullptr || bridge == nullptr || env->ExceptionCheck()) {
    return nullptr;
  }

  JavaVM *vm = g_java_vm.load(std::memory_order_acquire);
  if (vm == nullptr) {
    if (env->GetJavaVM(&vm) != JNI_OK || vm == nullptr) {
      return nullptr;
    }
  }

  LocalFrame frame(env, 8);
  if (!frame.ok()) {
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
    }
    return nullptr;
  }

  jclass bridge_class = env->GetObjectClass(bridge);
  if (bridge_class == nullptr || env->ExceptionCheck()) {
    env->ExceptionClear();
    return nullptr;
  }

  jmethodID on_credential =
      env->GetMethodID(bridge_class, "onCredential", "(I[B[B)[B");
  if (on_credential == nullptr || env->ExceptionCheck()) {
    env->ExceptionClear();
    return nullptr;
  }

  jobject global_bridge = env->NewGlobalRef(bridge);
  if (global_bridge == nullptr || env->ExceptionCheck()) {
    env->ExceptionClear();
    return nullptr;
  }

  auto *ctx = new (std::nothrow) CredentialBridgeContext{
      vm, global_bridge, on_credential};
  if (ctx == nullptr) {
    env->DeleteGlobalRef(global_bridge);
    return nullptr;
  }
  return ctx;
}

int32_t credential_callback(void *context, uint32_t operation,
                            const char *reference, const char *value,
                            char *output, size_t capacity) noexcept {
  if (context == nullptr) {
    return -1;
  }
  if (capacity > 0) {
    if (output == nullptr) {
      return -1;
    }
    output[0] = '\0';
  }

  auto *ctx = static_cast<CredentialBridgeContext *>(context);
  JavaVM *vm =
      ctx->vm != nullptr ? ctx->vm : g_java_vm.load(std::memory_order_acquire);
  if (vm == nullptr || ctx->bridge == nullptr ||
      ctx->on_credential == nullptr) {
    return -1;
  }

  ThreadEnv thread_env(vm);
  JNIEnv *env = thread_env.get();
  if (env == nullptr) {
    return -1;
  }

  // Preserve any exception already pending on the calling JVM thread.
  if (env->ExceptionCheck()) {
    return -1;
  }

  LocalFrame frame(env, 8);
  if (!frame.ok()) {
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
    }
    return -1;
  }

  jbyteArray ref_bytes = nullptr;
  jbyteArray val_bytes = nullptr;
  if (!cstr_to_utf8_bytes(env, reference, ref_bytes) ||
      !cstr_to_utf8_bytes(env, value, val_bytes)) {
    return -1;
  }

  auto result = static_cast<jbyteArray>(
      env->CallObjectMethod(ctx->bridge, ctx->on_credential,
                            static_cast<jint>(operation), ref_bytes, val_bytes));
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return -1;
  }
  if (result == nullptr) {
    return 1;
  }

  const jsize raw_len = env->GetArrayLength(result);
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return -1;
  }
  if (raw_len < 0) {
    return -1;
  }
  const auto byte_len = static_cast<size_t>(raw_len);
  if (capacity == 0) {
    return byte_len == 0 ? 0 : -1;
  }
  if (byte_len >= capacity) {
    return -1;
  }
  if (byte_len > 0) {
    env->GetByteArrayRegion(result, 0, raw_len,
                            reinterpret_cast<jbyte *>(output));
    if (env->ExceptionCheck()) {
      env->ExceptionClear();
      output[0] = '\0';
      return -1;
    }
    if (std::memchr(output, '\0', byte_len) != nullptr) {
      output[0] = '\0';
      return -1;
    }
  }
  output[byte_len] = '\0';
  return 0;
}

void credential_bridge_destroy(void *context) noexcept {
  if (context == nullptr) {
    return;
  }
  auto *ctx = static_cast<CredentialBridgeContext *>(context);
  JavaVM *vm =
      ctx->vm != nullptr ? ctx->vm : g_java_vm.load(std::memory_order_acquire);
  if (ctx->bridge != nullptr && vm != nullptr) {
    ThreadEnv thread_env(vm);
    if (JNIEnv *env = thread_env.get(); env != nullptr) {
      env->DeleteGlobalRef(ctx->bridge);
    }
  }
  delete ctx;
}

}  // namespace koe::android
