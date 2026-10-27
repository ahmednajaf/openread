#if defined(__aarch64__)
#include "vendor/ggml/src/ggml-cpu/arch/arm/quants.c"
#elif defined(__x86_64__)
#include "vendor/ggml/src/ggml-cpu/arch/x86/quants.c"
#endif
