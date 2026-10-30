// Optional fault-injection regression. Compile runtime.cpp with only its
// llama_get_logits_ith reference redirected to openread_test_logits.
#include "Kitten2Runtime.h"
#include "llama.h"
#include <algorithm>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

static int calls = 0, injected = 0;
static bool persistent = false;
extern "C" float *openread_test_logits(llama_context *context, int32_t index) {
    ++calls;
    if (calls == 40 || (persistent && calls > 40)) {
        ++injected;
        static std::vector<float> invalid(158241, std::numeric_limits<float>::quiet_NaN());
        return invalid.data();
    }
    return llama_get_logits_ith(context, index);
}
struct Progress { std::vector<int32_t> prefix; bool valid = true; };
int receive(void *value, const int32_t *tokens, size_t count, int) {
    auto &p = *static_cast<Progress *>(value);
    p.valid = p.valid && count >= p.prefix.size() && std::equal(p.prefix.begin(), p.prefix.end(), tokens);
    p.prefix.assign(tokens, tokens + count);
    return p.valid;
}
int main(int argc, char **argv) {
    if (argc != 4) { std::cerr << "Usage: check-recovery MODEL.gguf VOICES.sqlite once|persistent\n"; return 2; }
    persistent = std::string(argv[3]) == "persistent";
    char *error = nullptr;
    void *model = kitten2_create(argv[1], argv[2], 1, 3, &error);
    if (!model) { std::cerr << (error ? error : "Model load failed") << '\n'; kitten2_free(error); return 1; }
    Progress p;
    int result = kitten2_generate(model,
        "حين نقرأ، لا نبحث عن الكلمات وحدها، بل عن المعنى الذي يجمعها. خذ وقتك، واستمع بهدوء؛ فلكل قصة إيقاعها الخاص.",
        "ArabicFalconer", 0, 1234, 1000, receive, &p, &error);
    bool passed = p.valid && p.prefix.size() >= 32 && (persistent
        ? result == 0 && injected == 2 && error && std::string(error).find("continue safely") != std::string::npos
        : result == 1 && injected == 1 && p.prefix.size() > 40 && !error);
    std::cout << "recovery=" << (passed ? "PASS" : "FAIL") << " mode=" << argv[3]
              << " injected=" << injected << " tokens=" << p.prefix.size() << " result=" << result << '\n';
    if (error) { std::cerr << error << '\n'; kitten2_free(error); }
    kitten2_destroy(model);
    return passed ? 0 : 1;
}
