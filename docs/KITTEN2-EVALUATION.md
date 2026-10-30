# Kitten TTS 2 evaluation

Historical evaluation from 28 October 2026. The optional pack is now available
in TestFlight; see the [current native pack guide](kitten2-native.md).

## What was tested

- `kittenml[mlx]==0.9.7`, pinned KittenML model revision
  `c93cb7c271baa51d9ae8204d5277988906f235a2`, packed weights, default decoder.
- An isolated environment on an M5 MacBook Air with 16 GB memory. The working
  reader's dependencies and default voice were not replaced.
- Eight generated comparisons: Kiki, Maeve, Victoria, Laurence, Saoirse,
  AudiobookNarratorFemale, GrandmaBedtimeStory and NewsAnchorFemale.
- The downloaded catalog contains 115 built-in voices. Reference recordings
  were made available locally for shortlisting, clearly distinguished from
  generated comparisons.
- Leading emotion tags, inline laughter/sigh events, Spanish, Arabic and cloning
  from a synthetic Kitten Mini reference with its exact transcript.

The neutral comparisons generated 8.1–8.9 seconds of audio in 3.8–4.7 seconds
after warm-up. The first Kiki call took 12 seconds; initial model loading was
separate. These are short Mac measurements, not sustained phone performance.
Concurrent native builds slowed later runs; do not treat these as a controlled
model ranking or a promise of uninterrupted 2× playback.

Independent local Whisper Base transcription recovered the generated English
and Spanish passage wording, including the synthetic-reference clone. It did
not transcribe the expression tags as words. The Arabic transcription contained
errors, so Arabic pronunciation needs a fluent listener's assessment. Recognition
is not an objective test of expressiveness, accent quality or speaker similarity.

## Catalog choice and Arabic follow-up

Retain all 115 voice options, grouped by language with search and favourites.
Arabic and Arabic Falconer are the first featured Arabic choices. The local
comparison now includes a new shared Arabic paragraph synthesized in both
voices, rather than only their original reference recordings: 14.2 and 14.96
seconds of audio generated in 8.43 and 8.04 seconds respectively on this Mac.
Both produced playable, non-silent 24 kHz PCM. Pronunciation and dialect quality
still need listener assessment; this does not add Arabic to the shipped native
pack. The audition browser supports all 115 references, language filters and
browser-local favourites.

## Native iPhone investigation

The current upstream Swift SDK supports Mini/Micro/Nano 0.8, not TTS 2.
The Python MLX backend runs its language model on Apple GPU but decodes audio
through PyTorch. The C++ distribution also depends on a separate audio decoder;
neither is a drop-in iOS/Safari runtime.

A local fixed-shape decoder proof was exported to ONNX. Direct export first
failed on complex STFT operations. A real-valued convolution DFT adapter matched
the decoder's inverse transform within `2.4e-7` maximum absolute error on a
random test fixture and allowed export. This checks that transform, not complete
end-to-end voice fidelity.

The exported 573 MB graph produced 48,000 finite, non-silent samples in native
iOS Simulator ONNX Runtime 1.24.2: approximately 1.35 seconds to load and 1.54
seconds to decode two seconds of reference tokens. This is a fixed token-length
decoder fixture. It is **not** text-to-speech running end to end on an iPhone.

Remaining work before a native pack:

- Port the speaker-conditioned language model, exact tokenizer and sampling to
  a native runtime, with output parity checks.
- Export and validate variable-length decoding, speaker encoding and reference
  tokenization for cloning; validate complete audio fidelity.
- Add bounded generation, cancellation, continuous playback and genuine word
  alignment. TTS 2 does not supply the existing Mini/Kokoro duration interface.
- Measure physical-device memory, thermal behaviour and sustained generation.
  The decoder alone exceeds OpenRead's Safari model-size guard, so Safari cannot
  be assumed to support the same pack within its extension memory budget.

Temporary models and probe code stay outside the app and Git repository. The
native test used for this proof was removed after execution. No TTS 2 controls,
SDK dependencies or model downloads were added to production builds.

## Licence and upstream references

Code and model terms differ. The user approved local evaluation under the
Stellon Labs Community License; this does not register commercial use or decide
the terms of a distributed OpenRead pack. The current Mini and Kokoro packs
retain their existing Apache-2.0 terms.

- [Kitten TTS documentation](https://github.com/KittenML/KittenTTS)
- [Voices and expression syntax](https://github.com/KittenML/KittenTTS/blob/main/docs/voices-and-expression.md)
- [Pinned TTS 2 model](https://huggingface.co/KittenML/kitten-tts-2/tree/c93cb7c271baa51d9ae8204d5277988906f235a2)
- [TTS 2 model licence](https://huggingface.co/KittenML/kitten-tts-2/blob/c93cb7c271baa51d9ae8204d5277988906f235a2/LICENSE.md)
- [C++ runtime](https://github.com/KittenML/kitten-tts-2-cpp)
