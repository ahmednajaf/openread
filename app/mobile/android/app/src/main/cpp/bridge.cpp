#include <jni.h>
#include <codecvt>
#include <locale>
#include <memory>
#include "phonemizer.h"

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
extern "C" JNIEXPORT jlong JNICALL
Java_dev_openread_mobile_NativePhonemizer_create(JNIEnv* env, jobject, jstring rules, jstring list) {
    try {
        auto instance = std::make_unique<IPAPhonemizer>(utf8(env, rules), utf8(env, list), "en-us");
        if (!instance->isLoaded()) throw std::runtime_error("The pronunciation dictionary could not load.");
        return reinterpret_cast<jlong>(instance.release());
    } catch (const std::exception& error) { fail(env, error.what()); return 0; }
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_openread_mobile_NativePhonemizer_phonemize(JNIEnv* env, jobject, jlong handle, jstring text) {
    try {
        if (!handle) throw std::runtime_error("The pronunciation dictionary is not ready.");
        auto output = reinterpret_cast<IPAPhonemizer*>(handle)->phonemizeText(utf8(env, text));
        auto result = std::wstring_convert<std::codecvt_utf8_utf16<char16_t>, char16_t>().from_bytes(output);
        return env->NewString(reinterpret_cast<const jchar*>(result.data()), result.size());
    } catch (const std::exception& error) { fail(env, error.what()); return nullptr; }
}
extern "C" JNIEXPORT void JNICALL
Java_dev_openread_mobile_NativePhonemizer_destroy(JNIEnv*, jobject, jlong handle) {
    delete reinterpret_cast<IPAPhonemizer*>(handle);
}
