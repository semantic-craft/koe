#ifndef KOE_HOST_API_H
#define KOE_HOST_API_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Synchronous, serialized callback. No host API reentry or retained pointers.
 * op: 0 read, 1 create, 2 delete, 3 read legacy, 4 authorize, 5 prepare.
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
typedef struct KoePcmReceipt {
    uint64_t generation;
    uint64_t next_sequence;
    uint32_t status;
    uint32_t reserved;
} KoePcmReceipt;

typedef struct KoePlaybackReceipt {
    uint64_t generation;
    uint64_t prev_generation;
    uint64_t position_ms;
    uint64_t now_epoch_sec;
    bool is_playing;
    bool applied;
    bool needs_full_snapshot;
    uint8_t reserved[5];
} KoePlaybackReceipt;

typedef struct KoeOwnedBytes {
    uint8_t *ptr;
    size_t len;
    size_t cap;
} KoeOwnedBytes;

uint64_t koe_host_session_ingest_ble(uint64_t handle, const uint8_t *bytes, size_t len, uint64_t now_epoch_sec);
KoePcmReceipt koe_host_session_ingest_pcm(
    uint64_t handle, const char *record_id, const char *session_id, const char *lane,
    uint64_t sequence, uint64_t epoch, uint64_t captured_start_ns, bool has_timing,
    const int16_t *samples, size_t sample_count, uint64_t now_epoch_sec);
KoePlaybackReceipt koe_host_session_report_playback_progress(
    uint64_t handle, const char *record_id, uint64_t request_id,
    uint64_t position_ms, bool is_playing, uint64_t last_projected_now_sec, uint64_t now_epoch_sec);
KoeOwnedBytes koe_host_session_drain_ble_tx(uint64_t handle);
KoeOwnedBytes koe_host_session_drain_local_asr(uint64_t handle);
uint64_t koe_host_session_poll_timers(uint64_t handle, uint64_t elapsed_ms, uint64_t now_epoch_sec);
void koe_host_bytes_free(KoeOwnedBytes bytes);
void koe_host_string_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* KOE_HOST_API_H */
