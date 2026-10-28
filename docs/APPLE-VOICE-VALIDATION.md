# Voice catalog cleanup — follow-up validation

The follow-up source update uses one catalog across Apple apps, Safari, Chrome
and the desktop helper: eight Kitten Mini voices and 41 Kokoro voices across
six languages. It removes active Qwen speech controls and Apple adapters,
retaining Android source and existing user model/profile files. Desktop Kitten
now uses model durations; Whisper is optional for dictation only.

Checks on 28 October 2026:

- Full simulator suite: 40 passed, no skips or failures. All 49 voices generated
  matching-language audio with complete, ordered source ranges.
- An additional mapped Safari inference test passed for US/British English,
  Spanish, French, Hindi, Italian and Brazilian Portuguese.
- Desktop real inference checked all eight Kitten voices and one Kokoro voice
  per additional language. Shared regressions: 45 Python and 39 JavaScript tests.
- iOS device Release build, Mac app/Safari build, TypeScript, reader/site builds
  and generated Safari resources passed.
- The separate [Kitten TTS 2 decoder proof](KITTEN2-EVALUATION.md) passed in
  iOS Simulator; no evaluation runtime or weights are included in the app.

These are simulator and local inference checks. Physical-device playback,
extension memory limits and subjective multilingual pronunciation still need
TestFlight/listener validation. This source update has not yet been released.

---

# Apple voice playback — 0.6.2 (13)

The Apple apps now use one continuous audio queue for Kitten and Kokoro. Source
word ranges are matched to full-context phonemes before model chunking; model
duration outputs place those ranges on the audio timeline. Changing playback
speed changes consumption of queued audio, rather than restarting synthesis.
Safari preloads the following passage in a second gesture-authorized audio
element and keeps pitch preservation enabled.

Kitten Mini 0.8 exposes eight voice presets and speed, not emotion markup or
voice cloning. Kokoro adds 28 American/British presets. The native Kokoro pack
uses the pinned official fp16 export: int8 was substantially slower in Apple's
native runtime during simulator checks. Both models use contextual English
pronunciation. Qwen narration and cloning remain app-only experimental options,
off by default; this release does not claim to fix Qwen cloning.

## Checks run on 28 October 2026

- iPhone Duo simulator, iOS 27.1: full suite of 48 tests, 44 executed successfully,
  four optional Qwen model tests skipped because their packs were not installed.
- All eight Kitten and 28 Kokoro voices generated audible clips with complete,
  ordered UTF-16 source ranges and timing bounds within the audio duration.
- Long repeated passages, Unicode, currency/numbers and contextual homographs
  retained source ranges through chunk boundaries. Representative Kitten and
  Kokoro clips also ran through Safari's mapped runtime path.
- Four additional App Group integration checks passed, including whole-reader
  Kitten/Kokoro playback at 2× across passages, pause/resume and monotonically
  advancing highlights. The other checks covered mapped inference, source
  ranges and real WebKit audio preloading/pitch/highlight clearing.
- Continuous-player regressions covered exact sample continuity, startup,
  underrun recovery, speed changes and cancellation.
- JavaScript transport/player regressions and the desktop helper's Python suite
  passed. The normal HTMLAudio fallback remains covered alongside preloading.
- Signed iOS and universal Mac release archives built and uploaded successfully.

Simulator results do not establish physical-iPhone speed, battery use or native
extension memory limits. Live Safari UI validation was incomplete because the
simulator extension-enable control did not respond to automation. TestFlight
checks must cover Kitten/Kokoro on a real phone and Safari, including locking the
phone, longer reading sessions, headset controls and faster playback. Word times
come from the synthesis model; they are not a guarantee of phonetic accuracy or
perfect forced alignment for every utterance.
