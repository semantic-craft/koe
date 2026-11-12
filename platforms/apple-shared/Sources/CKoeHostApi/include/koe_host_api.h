#ifndef KOE_HOST_API_H
#define KOE_HOST_API_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Synchronous, serialized callback. No host API reentry or retained pointers.
 * op: 0 read, 1 create, 2 delete, 3 read legacy, 4 authorize.
 * Return 0 success, 1 missing, -1 failure. Write terminated UTF-8 into output.
 * Context and callback remain valid until session destruction. */
typedef int32_t (*KoeCredentialCallback)(void *context, uint32_t operation,
    const char *reference, const char *value, char *output, size_t capacity);
uint64_t koe_host_session_create_with_credentials(const char *workspace_dir,
    KoeCredentialCallback callback, void *context, bool isolated);
uint32_t koe_host_api_version(void);
uint64_t koe_host_session_create(const char *workspace_dir);
bool koe_host_session_destroy(uint64_t handle);
uint64_t koe_host_session_generation(uint64_t handle);
char *koe_host_session_snapshot_json(uint64_t handle, uint64_t now_epoch_sec);
char *koe_host_session_dispatch_json(uint64_t handle, const char *command_json, uint64_t now_epoch_sec);
uint64_t koe_host_session_ingest_ble(uint64_t handle, const uint8_t *bytes, size_t len, uint64_t now_epoch_sec);
char *koe_host_session_drain_ble_tx_json(uint64_t handle);
char *koe_host_session_drain_local_asr_json(uint64_t handle);
uint64_t koe_host_session_poll_timers(uint64_t handle, uint64_t elapsed_ms, uint64_t now_epoch_sec);
void koe_host_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* KOE_HOST_API_H */
