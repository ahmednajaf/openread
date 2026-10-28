#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// Caller owns returned UTF-8 string; release with openread_speech_free.
// data_parent contains espeak-ng-data/. Null indicates unavailable dictionaries.
// Context replacements are TSV: zero-based whitespace-word index, IPA.
char *openread_speech_phonemize_context_language(const char *data_parent, const char *text, const char *replacements, const char *language);
char *openread_speech_phonemize_context(const char *data_parent, const char *text, const char *replacements);
char *openread_speech_phonemize(const char *data_parent, const char *text);
// Supported language identifiers are explicit; an unavailable voice returns null.
char *openread_speech_phonemize_language(const char *data_parent, const char *text, const char *language);
// JSON source-word UTF-16 ranges and their scalar spans in the supplied FULL
// contextual phoneme string. Unknown words are omitted, never length-estimated.
char *openread_speech_word_spans(const char *data_parent, const char *text, const char *phonemes, const char *language);
void openread_speech_free(char *value);
#ifdef __cplusplus
}
#endif
