#if defined(__aarch64__)
#include "vendor/ggml/src/ggml-cpu/arch/arm/repack.cpp"
#elif defined(__x86_64__)
#include "vendor/ggml/src/ggml-cpu/arch/x86/repack.cpp"
#endif
