#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <TargetConditionals.h>
#include "include/OpenReadQwen.h"

void openread_qwen_configure_apple_backend(void) {
    @autoreleasepool {
        // Xcode precompiles the portable shader into default.metallib. SwiftPM's
        // command-line build copies the expanded source into the resource root.
        setenv("GGML_METAL_PATH_RESOURCES", SWIFTPM_MODULE_BUNDLE.resourceURL.path.UTF8String, 1);
        // These optional kernels aren't in the portable precompiled library.
        // Quantized Qwen uses the ordinary SIMD kernels on supported Apple GPUs.
        setenv("GGML_METAL_TENSOR_DISABLE", "1", 1);
        setenv("GGML_METAL_BF16_DISABLE", "1", 1);
#if TARGET_OS_SIMULATOR
        qwen3_tts_set_backend_preference(QWEN3_TTS_BACKEND_CPU);
#else
        // AUTO chooses Metal when present, retaining the native CPU fallback.
        qwen3_tts_set_backend_preference(QWEN3_TTS_BACKEND_AUTO);
#endif
    }
}
