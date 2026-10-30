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
int openread_context_inference_run(void *session, const int64_t *tokens, const int64_t *mask,
                                  size_t batch, size_t width, float **scores, size_t *score_count,
                                  float **grammar, size_t *grammar_count);
// App-owned Kitten TTS 2 decoder; the ordinary Safari model guard is unchanged.
void *openread_kitten2_decoder_create(const char *path);
int openread_kitten2_decoder_run(void *session, const int64_t *tokens, size_t count,
    const int64_t *prompt, size_t prompt_count, const float *features, size_t feature_count,
    const float *embedding, size_t embedding_count, uint32_t seed, float **samples, size_t *sample_count);
void openread_inference_free(void *buffer);
#ifdef __cplusplus
}
#endif
