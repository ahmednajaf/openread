#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// Maps a previously prepared ORT model. Never loads or downloads protobuf.
void *openread_inference_create(const char *path);
void openread_inference_destroy(void *session);
int openread_inference_run(void *session, const int64_t *tokens, size_t token_count,
                          const float *style, size_t style_count,
                          float **samples, size_t *sample_count,
                          int64_t **frames, size_t *frame_count);
void openread_inference_free(void *buffer);
#ifdef __cplusplus
}
#endif
