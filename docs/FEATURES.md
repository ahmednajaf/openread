# Feature coverage — OpenRead 0.3.0

Compared with the **Speechify Reader Premium** list checked on **25 October 2026** at [Speechify’s pricing page](https://speechify.com/pricing/). Speechify Studio and its developer API are separate products; their voice cloning, dubbing and licensed celebrity voices are not included in this comparison. OpenRead is independent and does not use Speechify code or voices.

| Reader feature | OpenRead implementation | Limit / difference |
| --- | --- | --- |
| Natural voices | Kokoro runs locally; 41 voices, plus 8 Kitten Mini voices, featured first; Kiki is the default | English, Spanish, French, Hindi, Italian and Brazilian Portuguese. English is strongest; other languages are experimental. This does **not** match the advertised 1,000+ voices / 60+ languages. |
| Faster reading | Pitch-preserving playback from 0.5× to 5× | Browser audio behavior and intelligibility vary at high speeds. |
| Scan & Listen | Local macOS Vision OCR for images and scanned PDF pages | macOS only; not handwriting/layout reconstruction. PDFs: 200 pages, at most 20 scanned pages per import. |
| PDF/books/documents | PDF, DRM-free EPUB in spine order, DOCX, HTML, TXT, Markdown, CSV | 20 MB per file, 250,000 characters per reading. Text/tables may lose complex formatting. No DRM removal. |
| AI summaries | Local Qwen3 4B via Ollama; section summaries for long documents | Optional 2.5 GB model. Local quality/speed differ from larger hosted models. |
| AI chat | Questions and follow-ups grounded in retrieved document passages; source excerpts visible | Word-overlap retrieval can miss relevant evidence. Answers need checking; no browsing or external tools. |
| AI podcasts | Local model generates a two-host script; Kokoro makes two-voice WAV audio | Short overview; review the generated interpretation. No celebrity voices. |
| Voice assistant | Record a question → local Whisper → document chat → optional spoken answer | Browser workspace only; no always-on wake word, system actions or general web research. |
| Dictation | Microphone/audio-file transcription with local Whisper Base; copy text to other apps | Not system-wide live voice typing. Record up to 5 minutes; import up to 1 hour / 20 MB. |
| Meeting notes | Local transcript → AI notes, decisions, action items and open questions | No live meeting-bot integration or speaker diarization. |
| Cloud-drive integrations | Import from already-synced Google Drive, Dropbox, OneDrive or iCloud folders | No direct provider OAuth/API integration or cloud account browsing. |
| Saved library | Explicit saves, resume position, bookmarks, search, backup/restore | Stored on this computer; 200 documents, 200 bookmarks each. No hosted sync/mobile apps. |
| Offline audio | Export selected voice to WAV; podcast audio playable/downloadable | Up to 50,000 characters per reading export, 150 MB output safety limit. Natural-speed export, no MP3 transcoder. |
| In-page reading | Audio-clock word highlighting, inline link text, ordered/nested lists, optional scrolling, page/selection/paste | Restricted pages, embedded frames, closed shadow roots and Safari Reader's protected DOM are outside scope. |
| Safari and Chrome | One MV3 source folder, native toolbar controls; separate Chrome ZIP packager | macOS is the tested helper platform. Other desktop systems need manual Python setup; native OCR is Mac-only. No store listing yet. |

## Models and setup

Weights are **downloaded by explicit setup scripts**, not committed as multi-gigabyte repository files. The source includes the setup instructions, pinned speech hashes, model provenance records and runtime integration. Models run on the user's own hardware; “free” means no OpenRead subscription or hosted inference charge, not zero disk, electricity or hardware use.

- **Kokoro 82M:** approximately 354 MB weights/styles. Apache-2.0. Existing duration-capable ONNX export; 41 exposed voices from its style file. [Upstream voice/language notes](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md) describe quality differences. Japanese and Mandarin require more appropriate text processing and are intentionally not offered yet.
- **Kitten TTS Mini 0.8 (featured):** about 82 MB, eight English voices, Apache-2.0 weights and upstream inference source. Uses local Whisper for approximate word alignment; slower than Kokoro and not claimed to have model-duration timing. [Model details](https://huggingface.co/KittenML/kitten-tts-mini-0.8).
- **Qwen3 4B:** approximately 2.5 GB through Ollama. Apache-2.0. [Model details](https://ollama.com/library/qwen3:4b). No cloud fallback.
- **Whisper Base:** approximately 150 MB plus faster-whisper packages; included with featured voices for alignment and reused for dictation. MIT. Setup records the exact Hugging Face repository revision and downloaded checksums. [Runtime implementation](https://github.com/SYSTRAN/faster-whisper).
- **Vision OCR:** the installed macOS recognition framework; a small Python bridge is installed through PyPI. No separate hosted OCR account.

## Release status

This is a working development iteration, **not full Speechify parity**. The source is released under GPL-3.0-or-later; downloaded dependencies and models retain their upstream licences, documented in THIRD_PARTY.md. Optional signed/store distribution is separate from the free source-install route.

Automated checks cover real speech in WebKit/Chrome, extraction and highlight cleanup, toolbar reconnect behavior, library resume/bookmarks, HTML/EPUB/DOCX parsing, local-service access controls, job cancellation, WAV export and responsive layouts. Opt-in integration scripts exercise actual PDF/OCR, every exposed voice, Whisper and Qwen. Generated speech confirms model execution; it does not certify every voice's subjective quality or every website's extraction.

## Podcast prompt design

`voice/prompts.py` contains versioned, task-specific system prompts for summaries, chat, meeting notes, source briefs and podcast dialogue. Documents and prior conversation are supplied as JSON data. The podcast pipeline first extracts a factual brief with supporting quotes; code verifies each quote against the source/section notes. A second pass creates alternating curious-listener/explainer turns, a concrete hook and a source-grounded takeaway. Small excerpts get four turns and a 110-word budget; larger ones get eight turns and 230 words. A separate skeptical-editor pass checks the candidate against the source and removes unsupported inferences. The code checks speaker order, source IDs, length and unsupported performance tags, with one repair attempt. Fact references are metadata rather than spoken citations. The workspace exposes the source brief for inspection. This reduces unsupported output; it is not a guarantee of factual accuracy. Kiki and Jasper speak the dialogue locally.
