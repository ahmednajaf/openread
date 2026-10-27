// OpenRead adapter: GPL-3.0-or-later. ONNX Runtime public C++ API: MIT.
// The upstream runtime remains pinned by Package.swift. No model is bundled.
#include "openread_inference.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <array>
#include <stdexcept>
#include <memory>
#include <cstdlib>
#include <cstring>

namespace {
struct MappedModel {
    void *bytes = MAP_FAILED;
    size_t size = 0;
    explicit MappedModel(const char *path) {
        int fd = open(path, O_RDONLY);
        if (fd < 0) throw std::runtime_error("Model unavailable");
        struct stat info{};
        if (fstat(fd, &info) || info.st_size < 8 || info.st_size > 200000000) { close(fd); throw std::runtime_error("Invalid model"); }
        size = static_cast<size_t>(info.st_size);
        bytes = mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (bytes == MAP_FAILED) throw std::runtime_error("Model mapping failed");
    }
    ~MappedModel() { if (bytes != MAP_FAILED) munmap(bytes, size); }
};
struct Inference {
    // Destruction order keeps the mapped weights alive until after the session.
    MappedModel model;
    Ort::Env environment{ORT_LOGGING_LEVEL_WARNING, "OpenRead"};
    Ort::Session session{nullptr};
    explicit Inference(const char *path) : model(path) {
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(2);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_DISABLE_ALL);
        options.DisableCpuMemArena();
        options.DisableMemPattern();
        options.AddConfigEntry("session.disable_prepacking", "1");
        options.AddConfigEntry("session.use_ort_model_bytes_directly", "1");
        options.AddConfigEntry("session.use_ort_model_bytes_for_initializers", "1");
        session = Ort::Session(environment, model.bytes, model.size, options);
    }
};
}

extern "C" void *openread_inference_create(const char *path) {
    try { return path ? new Inference(path) : nullptr; } catch (...) { return nullptr; }
}
extern "C" void openread_inference_destroy(void *session) { delete static_cast<Inference *>(session); }
extern "C" void openread_inference_free(void *buffer) { std::free(buffer); }
extern "C" int openread_inference_run(void *session, const int64_t *tokens, size_t count,
    const float *style, size_t width, float **samples, size_t *sample_count, int64_t **frames, size_t *frame_count) {
    if (!session || !tokens || !style || !count || count > 400 || !width || width > 4096 || !samples || !sample_count || !frames || !frame_count) return 0;
    *samples = nullptr; *frames = nullptr; *sample_count = 0; *frame_count = 0;
    try {
        auto memory = Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);
        std::array<int64_t, 2> token_shape{1, static_cast<int64_t>(count)}, style_shape{1, static_cast<int64_t>(width)};
        std::array<int64_t, 1> speed_shape{1};
        float speed = 1;
        std::array<Ort::Value, 3> inputs{
            Ort::Value::CreateTensor<int64_t>(memory, const_cast<int64_t *>(tokens), count, token_shape.data(), 2),
            Ort::Value::CreateTensor<float>(memory, const_cast<float *>(style), width, style_shape.data(), 2),
            Ort::Value::CreateTensor<float>(memory, &speed, 1, speed_shape.data(), 1)};
        const char *names[] = {"input_ids", "style", "speed"}, *outputs[] = {"waveform", "duration"};
        auto result = static_cast<Inference *>(session)->session.Run(Ort::RunOptions{nullptr}, names, inputs.data(), 3, outputs, 2);
        auto audio_info = result[0].GetTensorTypeAndShapeInfo(), duration_info = result[1].GetTensorTypeAndShapeInfo();
        const auto n = audio_info.GetElementCount(), m = duration_info.GetElementCount();
        if (audio_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || duration_info.GetElementType() != ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64 || n > 24000 * 180 || m > 400) return 0;
        using Owned = std::unique_ptr<void, decltype(&std::free)>;
        Owned audio(std::malloc(n * sizeof(float)), &std::free), duration(std::malloc(m * sizeof(int64_t)), &std::free);
        if (!audio || !duration) return 0;
        std::memcpy(audio.get(), result[0].GetTensorData<float>(), n * sizeof(float));
        std::memcpy(duration.get(), result[1].GetTensorData<int64_t>(), m * sizeof(int64_t));
        *samples = static_cast<float *>(audio.release()); *sample_count = n;
        *frames = static_cast<int64_t *>(duration.release()); *frame_count = m;
        return 1;
    } catch (...) { return 0; }
}
