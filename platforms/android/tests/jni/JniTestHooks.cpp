#include "JniCallbacks.h"

#include <array>
#include <cstdint>
#include <cstring>
#include <jni.h>
#include <string>
#include <thread>

extern "C" {

JNIEXPORT jint JNICALL
Java_com_semanticcraft_koe_bridge_KoeJniHostTest_nativeStressDetachedThread(
    JNIEnv *env, jclass, jobject bridge, jint iterations) {
  void *context = koe::android::credential_bridge_create(env, bridge);
  if (context == nullptr) {
    return -100;
  }

  int failure_code = 0;
  std::thread worker([context, iterations, &failure_code]() {
    std::array<char, 256> out{};
    for (jint i = 0; i < iterations; ++i) {
      const auto op = static_cast<uint32_t>(i % 6);
      if (i % 17 == 5) {
        const std::string missing_ref = "missing-" + std::to_string(i);
        const int32_t rc = koe::android::credential_callback(
            context, op, missing_ref.c_str(), "", out.data(), out.size());
        if (rc != 1) {
          failure_code = -10;
          return;
        }
        continue;
      }

      if (i % 23 == 7) {
        const std::string throw_ref = "throw-" + std::to_string(i);
        const int32_t rc = koe::android::credential_callback(
            context, op, throw_ref.c_str(), "", out.data(), out.size());
        if (rc != -1) {
          failure_code = -11;
          return;
        }
        const std::string recovery_ref = "recover-" + std::to_string(i);
        const std::string expected = "echo:0:" + recovery_ref + ":ok";
        const int32_t after = koe::android::credential_callback(
            context, 0, recovery_ref.c_str(), "ok", out.data(), out.size());
        if (after != 0 || expected != out.data()) {
          failure_code = -12;
          return;
        }
        continue;
      }

      const std::string ref =
          "slot-\xF0\xA0\x80\x80-" + std::to_string(i);
      const std::string val =
          "val-\xF0\x9F\x8E\x99\xEF\xB8\x8F-" + std::to_string(i);
      const std::string expected =
          "echo:" + std::to_string(op) + ":" + ref + ":" + val;
      const int32_t rc = koe::android::credential_callback(
          context, op, ref.c_str(), val.c_str(), out.data(), out.size());
      if (rc != 0 || expected != out.data()) {
        failure_code = -13;
        return;
      }
    }

    const std::string cap_expected = "echo:0:cap-check:v";
    std::array<char, 64> exact_buf{};
    if (koe::android::credential_callback(context, 0, "cap-check", "v",
                                          exact_buf.data(), 4) != -1) {
      failure_code = -20;
      return;
    }
    if (koe::android::credential_callback(context, 0, "cap-check", "v",
                                          exact_buf.data(),
                                          cap_expected.size()) != -1) {
      failure_code = -21;
      return;
    }
    if (koe::android::credential_callback(context, 0, "cap-check", "v",
                                          exact_buf.data(),
                                          cap_expected.size() + 1) != 0 ||
        cap_expected != exact_buf.data()) {
      failure_code = -22;
      return;
    }
    if (koe::android::credential_callback(context, 0, "empty-ok", "", nullptr,
                                          0) != 0) {
      failure_code = -23;
      return;
    }
    if (koe::android::credential_callback(context, 0, "cap-check", "v", nullptr,
                                          0) != -1) {
      failure_code = -24;
      return;
    }
    if (koe::android::credential_callback(context, 0, "nul-byte", "",
                                          exact_buf.data(),
                                          exact_buf.size()) != -1) {
      failure_code = -25;
      return;
    }
  });
  worker.join();

  std::thread destroyer([context]() {
    koe::android::credential_bridge_destroy(context);
  });
  destroyer.join();

  return failure_code;
}

JNIEXPORT jboolean JNICALL
Java_com_semanticcraft_koe_bridge_KoeJniHostTest_nativeTestPendingExceptionPreserved(
    JNIEnv *env, jclass, jobject bridge) {
  void *context = koe::android::credential_bridge_create(env, bridge);
  if (context == nullptr) {
    return JNI_FALSE;
  }

  jclass ex_cls = env->FindClass("java/lang/IllegalStateException");
  if (ex_cls == nullptr) {
    koe::android::credential_bridge_destroy(context);
    return JNI_FALSE;
  }
  env->ThrowNew(ex_cls, "pre-existing-pending");

  std::array<char, 64> out{};
  const int32_t rc = koe::android::credential_callback(
      context, 0, "must-not-invoke", "", out.data(), out.size());
  const jboolean still_pending = env->ExceptionCheck();
  koe::android::credential_bridge_destroy(context);

  if (rc != -1) {
    env->ExceptionClear();
    jclass err_cls = env->FindClass("java/lang/AssertionError");
    if (err_cls != nullptr) {
      env->ThrowNew(err_cls, "expected credential_callback to return -1");
    }
    return JNI_FALSE;
  }
  return still_pending;
}

}  // extern "C"
