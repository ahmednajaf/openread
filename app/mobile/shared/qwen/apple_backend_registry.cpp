// Keep simulator inference strictly on CPU: its Metal device cannot safely
// handle the native decoder's shared buffers. Physical Apple devices use Metal.
#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR
#define GGML_USE_METAL
#endif
#include "vendor/ggml/src/ggml-backend-reg.cpp"
