#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Caller owns returned UTF-8 string; release with openread_speech_free.
// data_parent contains espeak-ng-data/. Null indicates unavailable dictionaries.
// Context replacements are TSV: zero-based whitespace-word index, IPA.
char *openread_speech_phonemize_context(const char *data_parent, const char *text, const char *replacements);
char *openread_speech_phonemize(const char *data_parent, const char *text);
void openread_speech_free(char *value);
#ifdef __cplusplus
}
#endif
