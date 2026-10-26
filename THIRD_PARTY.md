# Third-party components

Model files, Python environments, and generated Safari builds are downloaded/generated locally and ignored by Git. They are not part of the extension's JavaScript source.

| Component | Purpose | Upstream / license |
| --- | --- | --- |
| Kokoro-82M v1.0 | Local neural speech weights and voice styles | [hexgrad/Kokoro-82M](https://huggingface.co/hexgrad/Kokoro-82M), Apache-2.0 |
| kokoro-onnx 0.6.1 | Python inference wrapper | [thewh1teagle/kokoro-onnx](https://github.com/thewh1teagle/kokoro-onnx), MIT |
| ONNX Runtime | Local model execution | [microsoft/onnxruntime](https://github.com/microsoft/onnxruntime), MIT |
| NumPy | Audio array processing | [numpy/numpy](https://github.com/numpy/numpy), BSD-3-Clause |
| phonemizer | Text to phonemes | [bootphon/phonemizer](https://github.com/bootphon/phonemizer), GPL-3.0 |
| espeakng-loader / eSpeak NG | Bundled phonemization engine | [thewh1teagle/espeakng-loader](https://github.com/thewh1teagle/espeakng-loader) / [espeak-ng/espeak-ng](https://github.com/espeak-ng/espeak-ng), includes GPL-3.0 components |
| pypdf | Local PDF text extraction | [py-pdf/pypdf](https://github.com/py-pdf/pypdf), BSD-3-Clause |
| PyObjC / macOS Vision | Python bridge to installed native OCR framework | [ronaldoussoren/pyobjc](https://github.com/ronaldoussoren/pyobjc), MIT bridge; Apple frameworks are supplied by macOS |
| Kitten TTS Mini 0.8 (optional) | Eight additional English voices | [KittenML/kitten-tts-mini-0.8](https://huggingface.co/KittenML/kitten-tts-mini-0.8), Apache-2.0; token alphabet/input preparation adapted from KittenTTS 0.8, [retained Apache license](docs/notices/KittenTTS-LICENSE.txt). This does not include differently licensed Kitten TTS 2. |
| Qwen3 4B (optional) | Local summaries, document chat, podcast scripts and notes | [Qwen/Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B), Apache-2.0 |
| Ollama (optional) | Local Qwen runner | [ollama/ollama](https://github.com/ollama/ollama), MIT; model notices separate |
| Whisper Base (optional) | Local speech recognition | [openai/whisper](https://github.com/openai/whisper), MIT; converted [Systran weights](https://huggingface.co/Systran/faster-whisper-base) |
| faster-whisper / CTranslate2 (optional) | Local Whisper inference | [SYSTRAN/faster-whisper](https://github.com/SYSTRAN/faster-whisper), MIT / [OpenNMT/CTranslate2](https://github.com/OpenNMT/CTranslate2), MIT |
| PyAV / FFmpeg (optional dependency) | Decode imported recordings | [PyAV](https://github.com/PyAV-Org/PyAV), BSD-3-Clause; bundled FFmpeg notices/configuration must be checked for redistribution |
The extension's UI and native-surface adapter are original OpenRead code under GPL-3.0-or-later. Safari supplies its own platform material; Apple frameworks and Safari are not relicensed by this project. The local reading app uses React and the MIT-licensed Glass Headline Hero by Kedhareswer Naidu ([upstream listing](https://mcp.21st.dev/%40kedhareswer/components/glass-headline-hero), [retained notice](docs/notices/GlassHeadlineHero-LICENSE.txt)). Runtime dependency notices are retained in [ReadingApp-LICENSES.txt](docs/notices/ReadingApp-LICENSES.txt).

The OpenRead logo was generated with the built-in image generation tool. The master and exact prompt are saved under `docs/assets/`; the generated icon sizes are under `extension/icons/`.

Python packages include their own notices. Before distributing a bundled helper or model, retain and satisfy each component's license/source obligations, including the phonemization stack, rather than treating the entire stack as MIT. This file is an inventory, not a replacement for upstream licenses. The generated Apple wrapper also includes Apple's generated-template notices.

The model assets come from the upstream Kokoro ONNX `model-files-v1.1` release. `app/voice/setup.py` records URLs and SHA-256 hashes in `.local/models/sources.json` and verifies these pinned hashes:

```text
beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a  kokoro-v1.0.onnx
bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d  voices-v1.0.bin
```

OpenRead is an independent project. Speechify's branding, UI assets, voices, and code are not included.

Optional model setup records the installed Ollama model digest in `.local/ai-source.json` and the Whisper repository revision plus downloaded-file SHA-256 checksums in `.local/whisper-base/openread-source.json`. Models are downloaded from their upstream hosts on the user's explicit setup action, not committed in Git. Python packages and Ollama retain their upstream licenses. A future prebundled binary must carry all applicable licenses and source obligations, including transitive FFmpeg components; the setup scripts are not a blanket redistribution permission.

`app/voice/setup_voices.py` pins Kitten Mini to revision `c02725660cea441db4c383af69f1f26f5cd00947` and verifies SHA-256 for the ONNX and voice-style files before recording `.local/kitten-mini/sources.json`. Pocket TTS and its reference voices are not bundled; their access/voice-specific terms need separate consideration.

The Odyssey excerpt in `dev/tests/fixtures/article/index.html`, `app/reader/src/data/odyssey.json`, `app/mobile/shared/odyssey.json`, and the website's sample text, recorded narration and demonstration was supplied by the project maintainer. The underlying translation retains its original rights and is excluded from the licence grant for OpenRead’s original software and assets. No translator or public-domain status is asserted.

The reading app and public website use React / React DOM / Scheduler (MIT), clsx (MIT), tailwind-merge (MIT) and Lucide React (ISC, with upstream icon attribution). The reading app also uses Tailwind CSS (MIT). TypeScript (Apache-2.0), esbuild (MIT) and the Tailwind CLI are build dependencies. Their upstream licences remain applicable. Built reading app JavaScript/CSS are committed for installation without Node; the corresponding sources live in `app/reader/src/` and `app/shared/components/`. The website retains the same notices at `/notices/ReadingApp-LICENSES.txt` and `/notices/GlassHeadlineHero-LICENSE.txt`. Its demo contains original OpenRead interface recordings, local Kitten narration and an original procedural music bed; it includes no commercial voice or third-party music recording.

## Native mobile previews

Native source is under `app/mobile/`. Both apps download Kitten Mini weights and English pronunciation data only after the user chooses setup. Exact revisions, URLs, checksums and licences are recorded in `app/mobile/shared/models.json`; weights and OCR models are not committed or embedded in the APK. The eSpeak NG dictionary/rule data is GPL-3.0-or-later, with corresponding upstream source at the pinned revision. OpenRead's native code remains GPL-3.0-or-later.

iOS uses KittenTTS-swift at revision `20cd4d8784c1bad348326955709892c8dfe7226b` (upstream declares Apache-2.0), ONNX Runtime 1.24.2 (MIT), SwiftSoup 2.7.6 (MIT), ZIPFoundation 0.9.19 (MIT), and Apple-supplied SwiftUI/UIKit, AVFoundation, PDFKit and Vision frameworks. The shared C++ pronunciation engine is copied from KittenTTS-web revision `c846fe92858f3447f4912226471f5a63983b3f94`; its Apache-2.0 licence and provenance remain beside the source. The web SDK and its analytics code are not included.

Android uses ONNX Runtime 1.24.3 (MIT), AndroidX/Compose/Media3 and Kotlin/coroutines (Apache-2.0), Jsoup 1.18.3 (MIT), PDFBox-Android 2.0.27.0 (Apache-2.0 and included notices), and Tesseract4Android 4.9.0 (Apache-2.0, with Tesseract, Leptonica, libpng and Independent JPEG Group components retaining their own notices). Optional English OCR data is from the pinned `tesseract-ocr/tessdata_fast` revision in the model manifest (Apache-2.0).

The apps bundle [mobile licence notices](app/mobile/shared/NOTICES.txt) in Settings. Generated projects, dependency lockfiles and the original pronunciation source are included for rebuilding; local SDKs, models, build outputs and signing material are ignored. Apple and Android platform SDKs are development dependencies supplied under their own terms, not redistributed as part of OpenRead's source licence.
