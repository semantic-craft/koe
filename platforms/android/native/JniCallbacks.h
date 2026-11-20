#pragma once

#include <cstddef>
#include <cstdint>
#include <jni.h>

namespace koe::android {

void remember_java_vm(JavaVM *vm) noexcept;
void *credential_bridge_create(JNIEnv *env, jobject bridge) noexcept;
int32_t credential_callback(void *context, uint32_t operation,
                            const char *reference, const char *value,
                            char *output, size_t capacity) noexcept;
void credential_bridge_destroy(void *context) noexcept;

}  // namespace koe::android
