cmake_minimum_required(VERSION 3.22)
project(OpenReadQwen LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
add_library(openread_qwen SHARED
 vendor/ggml/src/ggml.c
 vendor/ggml/src/ggml.cpp
 vendor/ggml/src/ggml-alloc.c
 vendor/ggml/src/ggml-backend.cpp
 vendor/ggml/src/ggml-backend-meta.cpp
 vendor/ggml/src/ggml-opt.cpp
 vendor/ggml/src/ggml-threading.cpp
 vendor/ggml/src/ggml-quants.c
 vendor/ggml/src/gguf.cpp
 vendor/ggml/src/ggml-backend-dl.cpp
 vendor/ggml/src/ggml-backend-reg.cpp
 vendor/ggml/src/ggml-cpu/ggml-cpu.c
 vendor/ggml/src/ggml-cpu/ggml-cpu.cpp
 vendor/ggml/src/ggml-cpu/repack.cpp
 vendor/ggml/src/ggml-cpu/hbm.cpp
 vendor/ggml/src/ggml-cpu/quants.c
 vendor/ggml/src/ggml-cpu/traits.cpp
 vendor/ggml/src/ggml-cpu/amx/amx.cpp
 vendor/ggml/src/ggml-cpu/amx/mmq.cpp
 vendor/ggml/src/ggml-cpu/binary-ops.cpp
 vendor/ggml/src/ggml-cpu/unary-ops.cpp
 vendor/ggml/src/ggml-cpu/vec.cpp
 vendor/ggml/src/ggml-cpu/ops.cpp
 vendor/src/audio_tokenizer_encoder.cpp
 vendor/src/qwen3_tts_c.cpp
 vendor/src/gguf_loader.cpp
 vendor/src/speech_tokenizer_encoder.cpp
 vendor/src/tokenizer_unicode_data.cpp
 vendor/src/tts_transformer.cpp
 vendor/src/tokenizer_unicode.cpp
 vendor/src/qwen3_tts.cpp
 vendor/src/text_tokenizer.cpp
 vendor/src/coreml_code_predictor_stub.cpp
 vendor/src/pipeline/pipeline_synthesize.cpp
 vendor/src/pipeline/pipeline_models.cpp
 vendor/src/pipeline/pipeline_runtime.cpp
 vendor/src/encoder/encoder_frontend.cpp
 vendor/src/encoder/encoder_runtime.cpp
 vendor/src/encoder/encoder_graph.cpp
 vendor/src/encoder/encoder_loader.cpp
 vendor/src/transformer/transformer_graph_code_pred.cpp
 vendor/src/transformer/transformer_generate.cpp
 vendor/src/transformer/transformer_embeddings.cpp
 vendor/src/transformer/transformer_loader_tensors.cpp
 vendor/src/transformer/transformer_debug.cpp
 vendor/src/transformer/transformer_graph_talker.cpp
 vendor/src/transformer/transformer_runtime.cpp
 vendor/src/transformer/transformer_loader.cpp
 vendor/src/transformer/transformer_loader_metadata.cpp
 vendor/src/transformer/transformer_cache.cpp
 vendor/src/transformer/transformer_runtime_code_pred.cpp
 vendor/src/decoder/decoder_cache.cpp
 vendor/src/decoder/decoder_loader.cpp
 vendor/src/decoder/decoder_layers.cpp
 vendor/src/decoder/decoder_graph.cpp
 vendor/src/decoder/decoder_runtime.cpp
 vendor/src/common/speaker_embedding_io.cpp
 vendor/src/common/icl_prompt_io.cpp
 vendor/src/common/audio_io.cpp
 arch.c
 arch.cpp
)
target_include_directories(openread_qwen PUBLIC include PRIVATE vendor/src vendor/ggml/include vendor/ggml/src vendor/ggml/src/ggml-cpu)
target_compile_definitions(openread_qwen PRIVATE GGML_USE_CPU GGML_SCHED_MAX_COPIES=4 GGML_VERSION="0.16.0" GGML_COMMIT="af97976c")
target_compile_options(openread_qwen PRIVATE -O3)
find_package(Threads REQUIRED)
target_link_libraries(openread_qwen PRIVATE Threads::Threads ${CMAKE_DL_LIBS})
if(ANDROID)
 target_sources(openread_qwen PRIVATE android.cpp)
 target_link_libraries(openread_qwen PRIVATE log)
endif()

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
 target_compile_definitions(openread_qwen PRIVATE _GNU_SOURCE)
endif()
