// C ABI of the Cassotis engine for an embedding host (iOS keyboard extension).
// It replaces the Unix socket of the macOS build: frames are the same IPC frames
// (see nc_ipc_protocol.pas) and go to the same TncIpcDispatcher.DispatchRequest.
//
// Threading: every call must come from one thread that outlives the engine.
// The Pascal heap keeps per-thread free lists, so a GCD pool thread that exits
// strands whatever it cached.
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum { CASSOTIS_OK = 0, CASSOTIS_ERR_STATE = -1, CASSOTIS_ERR_ARG = -2,
       CASSOTIS_ERR_OPEN = -3, CASSOTIS_ERR_FRAME = -4, CASSOTIS_ERR_EXCEPTION = -5 };

// resource_dir: read-only directory holding schema.sql (and dict_sc.db unless
// dictionary_path says otherwise). data_dir: writable directory for user_dict.db.
// user_dictionary_path may be NULL or "" to run without learning.
int32_t cassotis_core_open(const char *dictionary_path,
                           const char *user_dictionary_path,
                           const char *resource_dir,
                           const char *data_dir);

// Runs one request frame. Returns the response frame length, or a negative
// CASSOTIS_ERR_*. If capacity is too small nothing is written and the needed
// length is returned, so a caller compares the result against its capacity.
int32_t cassotis_core_dispatch(const uint8_t *request, uint32_t request_length,
                               uint8_t *response, uint32_t response_capacity);

// Copies the last error as UTF-8 (NUL-terminated); returns its full byte length.
uint32_t cassotis_core_last_error(char *buffer, uint32_t capacity);

// Drops rebuildable caches (level 0: lookup results; 1: everything optional).
void cassotis_core_trim(int32_t level);

void cassotis_core_close(void);

// Set before cassotis_core_open: cache_percent (100 = macOS bounds),
// sqlite_cache_kib, sqlite_mmap_mib, query_path_on_demand, prewarm_short_lookups,
// char_lm (1, the default: load <resource_dir>/char_lm with Core ML on a
// background thread; candidates are unchanged until it is ready; 0: no model),
// char_lm_async (0, the default: no Tab continuation or one-key rerank, whose
// results a host must poll for; 1: queue them after every key, as on macOS).
// The Core ML runtime (macos/src/host/native/nc_char_lm_coreml.mm) is in the
// archive; the host links CoreML.framework and libc++.
int32_t cassotis_core_set_option(const char *name, int32_t value);

// "name=entries\n" per engine container; returns the full byte length.
uint32_t cassotis_core_cache_census(char *buffer, uint32_t capacity);

// The character LM and the repair that shares it: 1 ready, 0 still loading,
// -1 none (char_lm off, or the load failed: cassotis_core_last_error says why).
// The model loads on a background thread the first time it is needed; this
// call starts it and waits up to timeout_ms (0: does not wait). The first load
// of a new model file compiles it for the Neural Engine (seconds).
int32_t cassotis_core_model_state(int32_t timeout_ms);

#ifdef __cplusplus
}
#endif
