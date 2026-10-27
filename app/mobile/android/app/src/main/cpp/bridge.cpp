#include <jni.h>
#include <codecvt>
#include <locale>
#include <memory>
#include "openread_speech.h"

static std::string utf8(JNIEnv* env, jstring value) {
    const jchar* chars = env->GetStringChars(value, nullptr);
    if (!chars) throw std::runtime_error("Unable to read text");
    std::u16string text(reinterpret_cast<const char16_t*>(chars), env->GetStringLength(value));
    env->ReleaseStringChars(value, chars);
    return std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t>().to_bytes(text);
}
static void fail(JNIEnv* env, const char* message) {
    env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_openread_mobile_NativePhonemizer_phonemize(JNIEnv* env, jobject, jstring dataParent, jstring text) {
    try {
        std::unique_ptr<char, decltype(&openread_speech_free)> output(
            openread_speech_phonemize(utf8(env, dataParent).c_str(), utf8(env, text).c_str()), openread_speech_free);
        if (!output) throw std::runtime_error("The pronunciation dictionary could not load.");
        auto result = std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t>().from_bytes(output.get());
        return env->NewString(reinterpret_cast<const jchar*>(result.data()), result.size());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_openread_mobile_NativePhonemizer_phonemizeContext(JNIEnv* env, jobject, jstring dataParent, jstring text, jstring replacements) {
    try {
        std::unique_ptr<char, decltype(&openread_speech_free)> output(openread_speech_phonemize_context(utf8(env,dataParent).c_str(),utf8(env,text).c_str(),utf8(env,replacements).c_str()),openread_speech_free);
        if(!output)throw std::runtime_error("Contextual pronunciation could not finish.");
        auto result=std::wstring_convert<std::codecvt_utf8_utf16<char16_t>,char16_t>().from_bytes(output.get());
        return env->NewString(reinterpret_cast<const jchar*>(result.data()),result.size());
    }catch(const std::exception& error){fail(env,error.what());return nullptr;}
}
