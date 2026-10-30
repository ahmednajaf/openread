// OpenRead native adapter: GPL-3.0-or-later.
// Prompt assembly and sampling use KittenML/kitten-tts-2-cpp (MIT), pinned by the build script.
#include "Kitten2Runtime.h"
#include "llama.h"
#include "sampling.h"
#include <atomic>
#include <cstring>
#include <cstdlib>
#include <fstream>
#include <sqlite3.h>
#include <memory>
#include <mutex>
#include <stdexcept>

namespace {
using json = kitten::json;
using Model = std::unique_ptr<llama_model, decltype(&llama_model_free)>;
using Context = std::unique_ptr<llama_context, decltype(&llama_free)>;
struct Runtime {
    Model model{nullptr, llama_model_free};
    std::unique_ptr<sqlite3, decltype(&sqlite3_close)> database{nullptr,sqlite3_close};
    std::string cached_name;
    json cached_voice;
    std::atomic_bool cancelled{false};
    std::mutex generation;
    int threads;
    Runtime(const char *path, const char *conditioning, bool gpu, int workers): threads(workers) {
        static std::once_flag backend;
        std::call_once(backend, [] { ggml_backend_load_all(); llama_backend_init(); });
        sqlite3 *db=nullptr;
        if (sqlite3_open_v2(conditioning,&db,SQLITE_OPEN_READONLY|SQLITE_OPEN_NOMUTEX,nullptr)!=SQLITE_OK) {
            if (db) sqlite3_close(db);
            throw std::runtime_error("Voice conditioning is missing.");
        }
        database.reset(db);
        sqlite3_limit(db,SQLITE_LIMIT_LENGTH,4*1024*1024);
        sqlite3_stmt *count=nullptr;
        if (sqlite3_prepare_v2(db,"SELECT count(*) FROM voices",-1,&count,nullptr)!=SQLITE_OK)
            throw std::runtime_error("Invalid voice conditioning catalog.");
        std::unique_ptr<sqlite3_stmt,decltype(&sqlite3_finalize)> statement(count,sqlite3_finalize);
        if (sqlite3_step(count)!=SQLITE_ROW || sqlite3_column_int(count,0)!=115)
            throw std::runtime_error("Invalid voice conditioning catalog.");
        auto params = llama_model_default_params();
        params.n_gpu_layers = gpu ? 999 : 0;
        params.use_extra_bufts = false;
        model.reset(llama_model_load_from_file(path, params));
        if (!model || llama_vocab_n_tokens(llama_model_get_vocab(model.get())) != 158241 || llama_model_n_embd(model.get()) != 2048)
            throw std::runtime_error("Kitten TTS 2 could not load its language model.");
    }
    const json &voice(const std::string &name) {
        if (cached_name==name) return cached_voice;
        sqlite3_stmt *raw=nullptr;
        if (sqlite3_prepare_v2(database.get(),"SELECT conditioning FROM voices WHERE name=?1",-1,&raw,nullptr)!=SQLITE_OK)
            throw std::runtime_error("The voice catalog could not be read.");
        std::unique_ptr<sqlite3_stmt,decltype(&sqlite3_finalize)> statement(raw,sqlite3_finalize);
        sqlite3_bind_text(raw,1,name.c_str(),-1,SQLITE_TRANSIENT);
        if (sqlite3_step(raw)!=SQLITE_ROW) throw std::runtime_error("Unknown Kitten TTS 2 voice.");
        const auto *bytes=sqlite3_column_text(raw,0);
        if (!bytes) throw std::runtime_error("Invalid voice conditioning.");
        cached_voice=json::parse(reinterpret_cast<const char *>(bytes)); cached_name=name;
        return cached_voice;
    }

};
void error_message(char **out, const char *message) { if (out) *out = strdup(message); }
std::vector<int> tokenize(const llama_vocab *vocab, const std::string &text) {
    int count = llama_tokenize(vocab, text.data(), int(text.size()), nullptr, 0, false, true);
    if (!count) return {};
    if (count > 0 || count < -4096) throw std::runtime_error("The text is too long for one voice request.");
    std::vector<int> result(-count);
    count = llama_tokenize(vocab, text.data(), int(text.size()), result.data(), int(result.size()), false, true);
    if (count < 0) throw std::runtime_error("Text tokenization failed.");
    result.resize(count); return result;
}
struct Batch {
    llama_batch value;
    Batch(int count, int embedding = 0): value(llama_batch_init(count, embedding, 1)) { value.n_tokens = count; }
    ~Batch() { llama_batch_free(value); }
    void position(int index, int offset, bool logits) {
        value.pos[index] = offset; value.n_seq_id[index] = 1; value.seq_id[index][0] = 0; value.logits[index] = logits;
    }
};
const json token_ids = {{"audio_id_base",151675},{"num_audio_tokens",6561},{"speech_start_id",151669},
    {"speech_end_id",151670},{"text_start_id",151671},{"start_id",151673},{"stop_id",151674},
    {"final_seg_id",158236},{"reference_text_start_id",158239},{"reference_text_end_id",158240},
    {"reference_speech_start_id",158237},{"reference_speech_end_id",158238}};
}
extern "C" void *kitten2_create(const char *model, const char *conditioning, int gpu, int threads, char **error) {
    try {
        if (!model || !conditioning || threads < 1 || threads > 8) throw std::runtime_error("Invalid voice configuration.");
        return new Runtime(model, conditioning, gpu != 0, threads);
    } catch (const std::exception &e) { error_message(error, e.what()); return nullptr; }
}
extern "C" int kitten2_generate(void *handle, const char *text, const char *voice, int expressive, uint32_t seed,
                                int max_tokens, kitten2_tokens_callback callback, void *user, char **error) {
    try {
        if (!handle || !text || !voice || !callback || max_tokens < 16 || max_tokens > 1400 || strlen(text) > 6400)
            throw std::runtime_error("Invalid voice request.");
        auto &runtime = *static_cast<Runtime *>(handle);
        std::lock_guard<std::mutex> lock(runtime.generation);
        runtime.cancelled.store(false);
        const auto &ref = runtime.voice(voice);
        const auto *vocab = llama_model_get_vocab(runtime.model.get());
        kitten::token_map map(token_ids);
        auto speaker = ref.at("speaker").get<std::vector<float>>();
        if (speaker.size() != 2048) throw std::runtime_error("Invalid speaker projection.");
        std::vector<int> emotion;
        if (expressive & 2) emotion = tokenize(vocab, "{emo: 1}");
        auto prompt = kitten::prompt(map, tokenize(vocab, text), tokenize(vocab, ref.at("transcript").get<std::string>()),
            ref.at("reference_tokens").get<std::vector<int>>(), emotion, true);
        if (prompt.size() > 1400) throw std::runtime_error("The passage is too long for this voice.");
        auto params = llama_context_default_params();
        params.n_ctx = uint32_t(prompt.size() + max_tokens); params.n_batch = 128; params.n_ubatch = 128;
        params.n_threads = runtime.threads; params.n_threads_batch = runtime.threads;
        params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
        params.abort_callback = [](void *value) { return static_cast<Runtime *>(value)->cancelled.load(); };
        params.abort_callback_data = &runtime;
        Context context(llama_init_from_model(runtime.model.get(), params), llama_free);
        if (!context) throw std::runtime_error("The voice could not allocate a generation context.");
        auto decode = [&](llama_batch batch) {
            if (runtime.cancelled.load()) return false;
            if (llama_decode(context.get(), batch)) {
                if (runtime.cancelled.load()) return false;
                throw std::runtime_error("Kitten TTS 2 generation failed.");
            }
            return true;
        };
        { Batch batch(1, int(speaker.size())); std::copy(speaker.begin(), speaker.end(), batch.value.embd);
          batch.position(0,0,false); if (!decode(batch.value)) return -1; }
        for (size_t offset=1; offset<prompt.size();) {
            int count = int(std::min(size_t(128),prompt.size()-offset)); Batch batch(count);
            for (int i=0;i<count;++i) { batch.value.token[i]=prompt[offset+i]; batch.position(i,int(offset)+i,offset+i+1==prompt.size()); }
            if (!decode(batch.value)) return -1;
            offset+=count;
        }
        kitten::sampling settings;
        if (expressive & 1) { settings.temperature=0.9f; settings.top_p=0.9f; }
        std::mt19937 random(seed);
        auto history=prompt; std::vector<int32_t> audio;
        const int count=llama_vocab_n_tokens(vocab);
        for (int step=0;step<max_tokens;++step) {
            if (runtime.cancelled.load()) return -1;
            const float *raw=llama_get_logits_ith(context.get(),-1);
            std::vector<float> scores(raw,raw+count);
            kitten::process(scores,history,prompt.size(),map,settings);
            int token=kitten::sample(scores,random,false); history.push_back(token);
            if (token==map.speech_end || token==map.stop) {
                if (audio.empty()) throw std::runtime_error("The voice returned no audio tokens.");
                return callback(user,audio.data(),audio.size(),1) ? 1 : -1;
            }
            if (token>=map.base && token<map.base+map.count) {
                audio.push_back(token-map.base);
                // The first decoder window needs 64 tokens plus lookahead.
                // Small cumulative updates avoid waiting for a second full
                // window before the first audible audio can be decoded.
                if (audio.size()%16==0 && !callback(user,audio.data(),audio.size(),0)) return -1;
            }
            Batch batch(1); batch.value.token[0]=token; batch.position(0,int(history.size()-1),true);
            if (!decode(batch.value)) return -1;
        }
        throw std::runtime_error("The voice exceeded its generation limit. Try a shorter passage.");
    } catch (const std::exception &e) { error_message(error,e.what()); return 0; }
}
extern "C" char *kitten2_voice_conditioning(void *handle, const char *voice, char **error) {
    try {
        if (!handle || !voice || strlen(voice)>100) throw std::runtime_error("Invalid voice request.");
        auto &runtime=*static_cast<Runtime *>(handle);
        std::lock_guard<std::mutex> lock(runtime.generation);
        return strdup(runtime.voice(voice).dump().c_str());
    } catch (const std::exception &e) { error_message(error,e.what()); return nullptr; }
}
extern "C" int kitten2_token_count(void *handle, const char *text) {
    try {
        if (!handle || !text || strlen(text)>6400) return -1;
        return int(tokenize(llama_model_get_vocab(static_cast<Runtime *>(handle)->model.get()),text).size());
    } catch (...) { return -1; }
}
extern "C" void kitten2_cancel(void *handle) { if (handle) static_cast<Runtime *>(handle)->cancelled.store(true); }
extern "C" void kitten2_destroy(void *handle) { delete static_cast<Runtime *>(handle); }
extern "C" void kitten2_free(void *value) { free(value); }
