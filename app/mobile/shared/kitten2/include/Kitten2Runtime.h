// OpenRead native adapter: GPL-3.0-or-later. Runtime dependencies: MIT.
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Return zero from the callback to cancel. Tokens are zero-based S3 codec IDs.
typedef int (*kitten2_tokens_callback)(void *, const int32_t *, size_t, int);
void *kitten2_create(const char *model, const char *conditioning, int gpu, int threads, char **error);
int kitten2_generate(void *handle, const char *text, const char *voice, int expressive, uint32_t seed,
                     int max_tokens, kitten2_tokens_callback callback, void *context, char **error);
char *kitten2_voice_conditioning(void *handle, const char *voice, char **error);
int kitten2_token_count(void *handle, const char *text);
// App lifecycle gate. Disabling waits until in-flight Metal work is drained;
// active generations migrate their context to CPU without restarting the text.
// Call from the lifecycle thread, never from a token callback.
void kitten2_set_gpu_allowed(int allowed);
void kitten2_cancel(void *handle);
void kitten2_destroy(void *handle);
void kitten2_free(void *value);
#ifdef __cplusplus
}
#endif
