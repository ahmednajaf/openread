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
#include <random>
#include <vector>
#include <cmath>

namespace {
struct MappedModel {
    void *bytes = MAP_FAILED;
    size_t size = 0;
    explicit MappedModel(const char *path, size_t limit = 200000000) {
        int fd = open(path, O_RDONLY);
        if (fd < 0) throw std::runtime_error("Model unavailable");
        struct stat info{};
        if (fstat(fd, &info) || info.st_size < 8 || static_cast<uint64_t>(info.st_size) > limit) { close(fd); throw std::runtime_error("Invalid model"); }
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
    explicit Inference(const char *path, size_t limit = 200000000) : model(path, limit) {
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

extern "C" int openread_context_inference_run(void *session, const int64_t *tokens, const int64_t *mask,
    size_t batch, size_t width, float **scores, size_t *score_count, float **grammar, size_t *grammar_count) {
    if(!session || !tokens || !mask || !batch || batch>8 || !width || width>128 || !scores || !score_count || !grammar || !grammar_count)return 0;
    *scores=nullptr;*grammar=nullptr;*score_count=0;*grammar_count=0;
    try {
        auto memory=Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator,OrtMemTypeDefault);
        std::array<int64_t,2> shape{static_cast<int64_t>(batch),static_cast<int64_t>(width)};
        std::array<Ort::Value,2> inputs{Ort::Value::CreateTensor<int64_t>(memory,const_cast<int64_t*>(tokens),batch*width,shape.data(),2),Ort::Value::CreateTensor<int64_t>(memory,const_cast<int64_t*>(mask),batch*width,shape.data(),2)};
        const char* names[]={"input_ids","attention_mask"};const char* outputs[]={"logits","grammar"};
        auto result=static_cast<Inference*>(session)->session.Run(Ort::RunOptions{nullptr},names,inputs.data(),2,outputs,2);
        size_t a=result[0].GetTensorTypeAndShapeInfo().GetElementCount(),b=result[1].GetTensorTypeAndShapeInfo().GetElementCount();
        if(a>4096 || b>1024 || a%batch || b%batch)return 0;
        auto* first=static_cast<float*>(std::malloc(a*sizeof(float)));auto* second=static_cast<float*>(std::malloc(b*sizeof(float)));
        if(!first || !second){std::free(first);std::free(second);return 0;}
        std::memcpy(first,result[0].GetTensorData<float>(),a*sizeof(float));std::memcpy(second,result[1].GetTensorData<float>(),b*sizeof(float));
        *scores=first;*grammar=second;*score_count=a;*grammar_count=b;return 1;
    }catch(...){return 0;}
}


// The larger decoder is app-owned. Safari retains its existing 200 MB path.
extern "C" void *openread_kitten2_decoder_create(const char *path) {
    try { return path ? new Inference(path, 700000000) : nullptr; } catch (...) { return nullptr; }
}
extern "C" int openread_kitten2_decoder_run(void *session, const int64_t *tokens, size_t count,
    const int64_t *prompt, size_t prompt_count, const float *features, size_t feature_count,
    const float *embedding, size_t embedding_count, uint32_t seed, float **samples, size_t *sample_count) {
    if (!session || !tokens || count < 4 || count > 320 || !prompt || !prompt_count || prompt_count > 300 ||
        !features || (feature_count != prompt_count * 2 * 80 && feature_count != (prompt_count * 2 + 1) * 80) || !embedding || embedding_count != 192 || !samples || !sample_count) return 0;
    *samples = nullptr; *sample_count = 0;
    try {
        auto memory = Ort::MemoryInfo::CreateCpu(OrtDeviceAllocator, OrtMemTypeDefault);
        std::array<int64_t,2> token_shape{1,static_cast<int64_t>(count)}, prompt_shape{1,static_cast<int64_t>(prompt_count)}, embedding_shape{1,192};
        // The codec uses 25 Hz tokens and 50 Hz reference frames. STFT can
        // leave one unpaired trailing frame; align to complete codec frames.
        const size_t aligned_features = prompt_count * 2 * 80;
        std::array<int64_t,3> feature_shape{1,static_cast<int64_t>(prompt_count*2),80}, noise_shape{1,80,static_cast<int64_t>(count*2)};
        std::vector<float> noise(count*2*80);
        std::mt19937 random(seed); std::normal_distribution<float> normal;
        for (auto &value:noise) value=normal(random);
        std::array<Ort::Value,5> inputs{
            Ort::Value::CreateTensor<int64_t>(memory,const_cast<int64_t *>(tokens),count,token_shape.data(),2),
            Ort::Value::CreateTensor<int64_t>(memory,const_cast<int64_t *>(prompt),prompt_count,prompt_shape.data(),2),
            Ort::Value::CreateTensor<float>(memory,const_cast<float *>(features),aligned_features,feature_shape.data(),3),
            Ort::Value::CreateTensor<float>(memory,const_cast<float *>(embedding),embedding_count,embedding_shape.data(),2),
            Ort::Value::CreateTensor<float>(memory,noise.data(),noise.size(),noise_shape.data(),3)};
        const char *names[]={"tokens","prompt_token","prompt_feat","embedding","noise"}, *outputs[]={"waveform"};
        auto result=static_cast<Inference *>(session)->session.Run(Ort::RunOptions{nullptr},names,inputs.data(),inputs.size(),outputs,1);
        const auto info=result[0].GetTensorTypeAndShapeInfo(); const auto size=info.GetElementCount();
        if (info.GetElementType()!=ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || size!=count*960) return 0;
        const float *data=result[0].GetTensorData<float>();
        for (size_t i=0;i<size;++i) if (!std::isfinite(data[i])) return 0;
        auto copy=static_cast<float *>(std::malloc(size*sizeof(float)));
        if (!copy) return 0;
        std::memcpy(copy,data,size*sizeof(float)); *samples=copy; *sample_count=size; return 1;
    } catch (...) { return 0; }
}
