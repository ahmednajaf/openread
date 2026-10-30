# Kitten TTS 2 native pack

This optional native integration is available in OpenRead’s TestFlight beta. The maintainer completed KittenML registration on 30 October 2026. The optional
pack remains a beta while device playback and word timing are validated.

Kitten Mini and Kokoro remain the smaller everyday packs. Kitten TTS 2 provides
115 speaker presets in 16 language groups, including Arabic and Arabic Falconer.
The prebuilt Mac beta targets Apple silicon. All presets share about 2.1 GB of
model files. Its weights retain the Stellon Labs Community License, separately from OpenRead's GPL code. See the full agreement
and notices in `app/mobile/shared/NOTICES.txt`. Powered by KittenML.

## Build the runtime

The Swift package uses a checksum-pinned prebuilt Apple runtime. To build it
yourself instead, with Xcode and CMake installed, run from the repository root:

```sh
sh dev/scripts/build-kitten2-runtime.sh
xcodegen generate --spec app/mobile/ios/project.yml
xcodegen generate --spec app/apple/project.yml
```

The script builds a local, ignored XCFramework for arm64 Mac, iPhone and iPhone
Simulator from the pinned official KittenML C++ repository. Model weights are
never bundled into that framework. `app/mobile/shared/kitten2/NOTICES.txt` records
the native runtime's upstream licences. The optional model pack is downloaded separately from the app; its files are
not added to the source repository.

## Native playback

The language model uses Metal on Mac and while the iPhone app is active.
Foreground preparation runs alongside the request for a user-started background
GPU lease; it never waits for that lease. When iOS cannot grant background GPU
access, the native worker drains Metal and transfers its current generation
context to CPU before app deactivation completes. It can return to GPU on
reactivation without restarting the passage. Expiring a background lease also
switches compute rather than cancelling narration. Background CPU performance
can still be slower than playback on some phones, especially at higher speeds.
The S3 decoder runs through ONNX Runtime 1.24.2. Reference conditioning is read for one
speaker at a time instead of loading all 115 speaker records into memory.

Text retains sentence context and is bounded using actual language-model tokens.
Unicode compatibility glyphs from PDF fonts are normalized in the spoken copy,
including Arabic presentation forms and Latin ligatures. Stored text, bookmarks
and highlighting keep their original UTF-16 source positions.
Audio is decoded in overlapping codec windows and scheduled on the existing
continuous PCM player. Rate changes use its single audio clock.

Kitten TTS 2 does not supply word durations. On iOS/macOS 26 and later, OpenRead
uses Apple's on-device DictationTranscriber timestamps, matched monotonically to
exact UTF-16 source ranges. It does not invent durations for unrecognized words.
The reading language needs its one-time Apple asset preparation in voice settings.
Asset installation alone does not guarantee a usable analyzer format. When timing
is unavailable, playback continues with a visible notice and no invented highlights.
An exact word/page resume then falls back to the current passage, rather than
silently dropping its untimed audio.
Actual language-asset availability and sustained iPhone performance still require
end-to-end validation; native simulator synthesis is not a device benchmark.

Safari hands Kitten TTS 2 playback to the containing OpenRead app. Return to the
webpage to follow its highlights and use extension controls. Only small commands
and source ranges cross the App Group bridge; the large model never loads inside
the Safari extension. Kitten Mini/Kokoro keep their existing Safari audio path.
The app-owned player currently supports 0.5–2×. Chrome's helper path is unchanged.

## Validation

Native tests cover all conditioning records, actual Arabic/Falconer/French audio,
repeated Arabic source words, diacritics, ASR gaps, grouped recognition intervals,
and session ownership/controls. Browser tests cover remote cancellation, source
offsets and rate limits. Tests skip synthesis when the optional local weights are
absent; they never fetch Kitten model weights automatically.

Voice downloads use an OS-owned background URLSession and saved HTTP resume data.
The full pack is queued before waiting for transfers; each file is installed only
after its SHA-256 check passes. Tests cover real HTTP byte-range resumption and
corrupt transfers. OS suspension/relaunch still needs a TestFlight check.

`dev/tests/kitten2-runtime-handoff.cpp` is an optional Metal hardware regression.
Link it against the built runtime and pass the pinned GGUF and voice SQLite paths.
It verifies cumulative tokens, continued generation with GPU access disabled, and
return to foreground GPU work. It never downloads weights.

Real-device Arabic alignment, sustained background performance and Safari playback
remain beta checks. Voice cloning is not part of this preset port yet.
