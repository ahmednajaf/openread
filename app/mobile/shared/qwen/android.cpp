#include <jni.h>
#include <cmath>
#include <string>
#include "OpenReadQwen.h"
// JNI modified UTF-8 represents astral characters as surrogate pairs. Convert
// text to standard UTF-8 before the model's BPE tokenizer sees it.
static std::string utf8(JNIEnv* env, jstring value) {
 const jchar* units=env->GetStringChars(value,nullptr);const jsize count=env->GetStringLength(value);std::string result;
 for(jsize i=0;i<count;i++){uint32_t scalar=units[i];if(scalar>=0xd800 && scalar<=0xdbff && i+1<count && units[i+1]>=0xdc00 && units[i+1]<=0xdfff){scalar=0x10000+((scalar-0xd800)<<10)+(units[++i]-0xdc00);}else if(scalar>=0xd800 && scalar<=0xdfff)scalar=0xfffd;
 if(scalar<0x80)result.push_back(char(scalar));else if(scalar<0x800){result.push_back(char(0xc0|(scalar>>6)));result.push_back(char(0x80|(scalar&63)));}else if(scalar<0x10000){result.push_back(char(0xe0|(scalar>>12)));result.push_back(char(0x80|((scalar>>6)&63)));result.push_back(char(0x80|(scalar&63)));}else{result.push_back(char(0xf0|(scalar>>18)));result.push_back(char(0x80|((scalar>>12)&63)));result.push_back(char(0x80|((scalar>>6)&63)));result.push_back(char(0x80|(scalar&63)));}}
 env->ReleaseStringChars(value,units);return result;
}
static void fail(JNIEnv* env, const char* message) { env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message); }
static int32_t keepGoing(const qwen3_tts_audio_chunk_t*, void* user) {
 auto* env=static_cast<JNIEnv*>(user); auto type=env->FindClass("java/lang/Thread");
 auto thread=env->CallStaticObjectMethod(type,env->GetStaticMethodID(type,"currentThread","()Ljava/lang/Thread;"));
 bool interrupted=env->CallBooleanMethod(thread,env->GetMethodID(type,"isInterrupted","()Z"));env->DeleteLocalRef(thread);env->DeleteLocalRef(type);return interrupted?0:1;
}
extern "C" JNIEXPORT jlong JNICALL Java_dev_openread_mobile_NativeQwen_create(JNIEnv* env,jobject,jstring root,jstring model) {
 const char* path=env->GetStringUTFChars(root,nullptr); const char* name=env->GetStringUTFChars(model,nullptr);
 auto* ctx=qwen3_tts_init(); bool ok=ctx && qwen3_tts_load_models_with_name(ctx,path,name);
 env->ReleaseStringUTFChars(root,path);env->ReleaseStringUTFChars(model,name);
 if(!ok){if(ctx)qwen3_tts_free(ctx);fail(env,"Qwen could not load. Reinstall its optional voice pack.");return 0;}return reinterpret_cast<jlong>(ctx);
}
extern "C" JNIEXPORT void JNICALL Java_dev_openread_mobile_NativeQwen_destroy(JNIEnv*,jobject,jlong handle){qwen3_tts_free(reinterpret_cast<qwen3_tts_context_t*>(handle));}
extern "C" JNIEXPORT jfloatArray JNICALL Java_dev_openread_mobile_NativeQwen_generate(JNIEnv* env,jobject,jlong handle,jstring text,jstring speaker,jstring direction,jstring prompt) {
 if(!handle || env->GetStringLength(text)>1600 || env->GetStringLength(direction)>500){fail(env,"Choose a shorter speech passage.");return nullptr;}
 auto sourceText=utf8(env,text);auto speakerText=utf8(env,speaker);auto directionText=utf8(env,direction);const char* source=sourceText.c_str();const char* voice=speakerText.c_str();const char* instruct=directionText.c_str();
 qwen3_tts_params_t params{720,.7f,.9f,40,4,0,0,1.1f,2050,instruct,voice,1.f};
 qwen3_tts_result_t result{}; qwen3_tts_streaming_params_t streaming{params,1.5f,1.f,1};
 if(prompt){const char* path=env->GetStringUTFChars(prompt,nullptr);result=std::string(path).find(".speaker.json")!=std::string::npos ? qwen3_tts_synthesize_with_speaker_embedding_streaming(reinterpret_cast<qwen3_tts_context_t*>(handle),source,path,streaming,keepGoing,env) : qwen3_tts_synthesize_with_icl_prompt_streaming(reinterpret_cast<qwen3_tts_context_t*>(handle),source,path,streaming,keepGoing,env);env->ReleaseStringUTFChars(prompt,path);}
 else result=qwen3_tts_synthesize_streaming(reinterpret_cast<qwen3_tts_context_t*>(handle),source,streaming,keepGoing,env);

 jfloatArray output=nullptr;
 bool valid=result.success && result.audio && result.sample_rate==24000 && result.audio_len>240 && result.audio_len<=24000*90;
 if(valid)for(int i=0;i<result.audio_len;i++)if(!std::isfinite(result.audio[i])){valid=false;break;}
 if(valid){output=env->NewFloatArray(result.audio_len);if(output)env->SetFloatArrayRegion(output,0,result.audio_len,result.audio);}
 qwen3_tts_free_result(result);
 if(!valid && keepGoing(nullptr,env))fail(env,"Qwen could not finish this passage. Try again or choose another voice.");return output;
}
extern "C" JNIEXPORT jboolean JNICALL Java_dev_openread_mobile_NativeQwen_clone(JNIEnv* env,jobject,jlong handle,jstring sample,jstring transcript,jstring output){
 if(!handle || env->GetStringLength(transcript)>2000)return false;
 auto transcriptText=utf8(env,transcript);const char* source=env->GetStringUTFChars(sample,nullptr);const char* words=transcriptText.c_str();const char* destination=env->GetStringUTFChars(output,nullptr);
 bool ok=transcriptText.empty() ? qwen3_tts_extract_speaker_embedding(reinterpret_cast<qwen3_tts_context_t*>(handle),source,destination) : qwen3_tts_extract_icl_prompt(reinterpret_cast<qwen3_tts_context_t*>(handle),source,words,destination);
 env->ReleaseStringUTFChars(sample,source);env->ReleaseStringUTFChars(output,destination);return ok;
}
