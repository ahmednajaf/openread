# Contextual pronunciation

Kitten and US-English Kokoro now use a small local sentence encoder before speech synthesis. It chooses between dictionary meanings using context and grammatical supervision. The source text, punctuation and highlight offsets stay intact. It is not a list of word replacements. Qwen keeps its own text frontend.

The bundled pack is about 11 MB. It contains an int8 BERT Mini encoder fine-tuned on Google's WikipediaHomographData and Universal Dependencies English EWT. Model files, pinned source revisions, licences and evaluation results are in `app/mobile/shared/pronunciation/`.

A confidence threshold is calibrated on development data; grammatical confidence is checked independently. On 1,615 held-out examples, the packaged model accepted 1,446 choices (89.5%) with 99.4% accuracy among those accepted. This measures labelled meaning selection, not overall audio quality. Uncertain cases retain eSpeak's pronunciation, so some ambiguity remains. Names and words outside the annotated lexicon use the existing frontend.

## Apple Intelligence

The native iPhone and Mac apps also offer on-device summaries, explanations and questions about the current passage. Open a reading and choose the sparkle button. This requires iOS/macOS 26 or later, a compatible device, Apple Intelligence enabled, and Apple's model ready. The app checks availability; unsupported devices can still read normally. Requests use a bounded passage, not an entire book, and no hosted AI service is contacted.

Apple's model does **not** make pronunciation decisions. Its word-meaning fallback passed simple examples but failed an independent difficult-case check (7 correct out of 11 accepted choices from 40 sampled uncertain examples). That approach was rejected. Speech uses the same calibrated portable model on Apple devices, Android and the desktop helper. Qwen retains its own text frontend.

## Reproduce the pack

Runtime users do not need PyTorch or training tools. For model development, use Python 3.12/3.13 in an isolated environment with the versions in `dev/pronunciation/requirements.txt`. Training uses only the pinned public corpora; no user readings or TestFlight data are included.

```sh
python -m venv .local/pronunciation-env
.local/pronunciation-env/bin/pip install -r dev/pronunciation/requirements.txt
export OPENREAD_PRONUNCIATION_WORK="$PWD/.local/pronunciation-training"
.local/pronunciation-env/bin/python dev/pronunciation/fetch.py
.local/pronunciation-env/bin/python dev/pronunciation/train_mini.py
.local/pronunciation-env/bin/python dev/pronunciation/train_joint.py
.local/pronunciation-env/bin/python dev/pronunciation/train_balanced.py
.local/pronunciation-env/bin/python dev/pronunciation/package_context.py
.local/pronunciation-env/bin/python -m onnxruntime.tools.convert_onnx_models_to_ort "$OPENREAD_PRONUNCIATION_WORK/balanced-context-int8.onnx" --optimization_style Runtime --output_dir "$OPENREAD_PRONUNCIATION_WORK/portable"
```

Copy the exported ORT file as `context.ort`, plus `lexicon.json`, `evaluation.json` and BERT's `vocab.txt` into the pack. Retain all notices and licences. The seed and schedule are fixed; different accelerators can produce slightly different floating-point results. `evaluation.json` records the shipped model's measurements. The model checksum is recorded in `SHA256SUMS`.

Run `python -m unittest discover -s dev/tests -p context_pronunciation_test.py` with ONNX Runtime installed. The same fixtures run in the iOS and Android native test suites. Native tests also check punctuation, source alignment and bounded input to the Apple reading tools.

The model is CC BY-SA 4.0 with upstream Apache-2.0 notices retained. The runtime adapter remains GPL-3.0-or-later. See the pack's `NOTICE.txt` for source attribution.

## Native Qwen playback

The Apple apps schedule Qwen PCM chunks from successive passages on one continuous audio timeline. Synthesis continues ahead of playback without resetting the engine at each passage. The queue keeps up to 20 seconds of listening time ahead, plus one in-flight passage, and waits between passages while paused. Changing speed updates the time-stretch unit and preparation lead without regenerating speech or resetting source timestamps. Playback builds a small lead that adapts within a bounded range, with a four-second deadline after audio first arrives. The buffer no longer waits for an estimate of the entire remaining passage. Pause retains queued audio and position. Qwen word timing remains approximate: repeated native phrase spans are grouped before estimating word times, rather than restarting every word in each 0.32-second chunk. Word ranges stay in original UTF-16 source coordinates; no Whisper model runs in the Apple Qwen playback path.

Apple device builds include the pinned GGML Metal backend alongside the CPU fallback. Simulators use CPU inference. The same downloaded GGUF models work with both backends. Native Apple streaming uses four codec frames (0.32 seconds) per chunk, enabling the upstream decoder’s persistent state instead of repeatedly decoding overlapping one-second windows. Generation speed still depends on the device and listening speed; buffering cannot make a slower-than-realtime producer sustain uninterrupted playback. Device diagnostics log timing without source text or voice samples.

On an iPhone Air, three consecutive Odyssey passages generated at 1.49× realtime with Sohee, 1.32× with Ryan and 0.68× with Aiden in one sequential run. Reversing the order gave Aiden 1.40× at nominal thermal state, Ryan 1.34× as the state rose to serious, then Sohee 0.65× at serious thermal state (Low Power Mode off). These are two short, stochastic runs, not controlled thermal certification; they show why voice speed cannot be judged from a first-chunk measurement and why live 2× playback cannot be promised. The separate probe used only public model files and fixed text, did not play audio or access the user's library, and was removed afterwards. Prepared audio bypasses inference during playback; see [high-speed preparation](VOICE_PACKS.md#smooth-listening-at-higher-speeds).

Regenerate the expanded Metal shader with `python3 dev/scripts/generate-qwen-metal.py`. CI verifies it against the pinned vendor sources. Xcode requires Apple’s Metal Toolchain component (`xcodebuild -downloadComponent MetalToolchain`) to precompile the portable shader library.
