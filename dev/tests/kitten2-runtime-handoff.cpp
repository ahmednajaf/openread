// Optional hardware regression: link against the built Kitten2Runtime library.
// Run with the pinned GGUF and voice SQLite paths. No downloads or fixture text.
#include "Kitten2Runtime.h"
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <iostream>
#include <mutex>
#include <thread>
#include <vector>

struct Progress {
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<int32_t> prefix;
    bool valid = true, done = false, continued_on_cpu = false;
    size_t returned_at = 0;
    double drain_seconds = 0;
};
int receive(void *value, const int32_t *tokens, size_t count, int) {
    auto &p = *static_cast<Progress *>(value);
    std::lock_guard<std::mutex> lock(p.mutex);
    p.valid = p.valid && count >= p.prefix.size() && std::equal(p.prefix.begin(), p.prefix.end(), tokens);
    if (!p.valid) return 0;
    p.prefix.assign(tokens, tokens + count);
    p.changed.notify_all();
    return 1;
}
int main(int argc, char **argv) {
    if (argc != 3) { std::cerr << "Usage: check-handoff MODEL.gguf VOICES.sqlite\n"; return 2; }
    kitten2_set_gpu_allowed(1);
    char *error = nullptr;
    void *model = kitten2_create(argv[1], argv[2], 1, 3, &error);
    if (!model) { std::cerr << (error ? error : "Model load failed") << '\n'; kitten2_free(error); return 1; }
    Progress p;
    std::thread lifecycle([&] {
        std::unique_lock<std::mutex> lock(p.mutex);
        p.changed.wait_for(lock, std::chrono::seconds(30), [&] { return p.prefix.size() >= 32 || p.done; });
        if (p.done || p.prefix.size() < 32) return;
        lock.unlock();
        auto begin = std::chrono::steady_clock::now();
        kitten2_set_gpu_allowed(0); // Must return after the context has left Metal.
        auto elapsed = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        lock.lock();
        p.drain_seconds = elapsed;
        size_t before = p.prefix.size();
        p.changed.wait_for(lock, std::chrono::seconds(30), [&] { return p.prefix.size() >= before + 32 || p.done; });
        p.continued_on_cpu = p.prefix.size() >= before + 32;
        p.returned_at = p.prefix.size();
        lock.unlock();
        kitten2_set_gpu_allowed(1);
    });
    const char *text = "حين نقرأ، لا نبحث عن الكلمات وحدها، بل عن المعنى الذي يجمعها. هل يمكن أن تصبح القراءة أسهل؟ خذ وقتك، واستمع بهدوء؛ فلكل قصة إيقاعها الخاص.";
    int result = kitten2_generate(model, text, "ArabicFalconer", 0, 1234, 1000, receive, &p, &error);
    { std::lock_guard<std::mutex> lock(p.mutex); p.done = true; p.changed.notify_all(); }
    lifecycle.join();
    bool passed = result == 1 && p.valid && p.continued_on_cpu && p.prefix.size() > p.returned_at;
    std::cout << "handoff=" << (passed ? "PASS" : "FAIL") << " tokens=" << p.prefix.size()
              << " cpu_continued=" << p.continued_on_cpu << " returned_at=" << p.returned_at
              << " gpu_drain_seconds=" << p.drain_seconds << '\n';
    if (error) { std::cerr << error << '\n'; kitten2_free(error); }
    kitten2_destroy(model); kitten2_set_gpu_allowed(1);
    return passed ? 0 : 1;
}
