#include "openread_speech.h"
#include "espeak-ng/speak_lib.h"
#include <mutex>
#include <string>
#include <cstring>
#include <cstdlib>
#include <cctype>

// eSpeak has process-global state, including a reused output buffer.
static std::mutex speech_mutex;
static bool initialized = false;
extern "C" char *openread_speech_phonemize_language(const char *data_parent, const char *text, const char *language) {
    std::lock_guard<std::mutex> lock(speech_mutex);
    if (!data_parent || !text || !language || std::strlen(text) > 16000) return nullptr;
    const std::string lang(language);
    if (lang != "en-us" && lang != "en-gb" && lang != "fr-fr" && lang != "es" && lang != "it" && lang != "pt-br" && lang != "hi" && lang != "ar") return nullptr;
    if (!initialized) {
        if (espeak_Initialize(AUDIO_OUTPUT_SYNCHRONOUS, 0, data_parent, espeakINITIALIZE_DONT_EXIT) <= 0) return nullptr;
        initialized = true;
    }
    const char *voice = lang == "en-gb" ? "en" : lang == "fr-fr" ? "fr" : language;
    if (espeak_SetVoiceByName(voice) != EE_OK) return nullptr;
    const void *cursor = text;
    std::string output;
    while (cursor && *static_cast<const char *>(cursor)) {
        const char *before = static_cast<const char *>(cursor);
        int terminator = 0;
        const char *ipa = espeak_TextToPhonemesWithTerminator(&cursor, espeakCHARS_UTF8, espeakPHONEMES_IPA, &terminator);
        if (!ipa) return nullptr;
        std::string part(ipa);
        if (part.empty()) { if (cursor == before) break; continue; }
        if (!output.empty()) output += " ";
        output += part;
        // Let eSpeak identify actual clause endings (Dr., decimals and initials
        // are not sentence breaks). Restore their prosody token for Kitten.
        // The returned cursor is owned by eSpeak's decoder, not a pointer
        // into the caller's string. Use its clause metadata, never pointer math.
        const int intonation = terminator & 0x7000;
        const int pause = terminator & 0xfff;
        if (intonation == 0x1000) output += pause >= 30 ? ";" : ",";
        else if (intonation == 0x2000) output += "?";
        else if (intonation == 0x3000) output += "!";
        else if (intonation == 0 && pause > 0) output += pause == 30 ? ":" : ".";
        if (cursor == before) break;
    }
    char *copy = static_cast<char *>(std::malloc(output.size() + 1));
    if (copy) std::memcpy(copy, output.c_str(), output.size() + 1);
    return copy;
}
extern "C" char *openread_speech_phonemize(const char *data_parent, const char *text) {
    return openread_speech_phonemize_language(data_parent, text, "en-us");
}
extern "C" void openread_speech_free(char *value) { std::free(value); }
