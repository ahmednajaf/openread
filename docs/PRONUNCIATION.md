# Contextual pronunciation

Kitten and US-English Kokoro now use a small local sentence encoder before speech synthesis. It chooses between dictionary meanings using context and grammatical supervision. The source text, punctuation and highlight offsets stay intact. It is not a list of word replacements.

The bundled pack is about 11 MB. It contains an int8 BERT Mini encoder fine-tuned on Google's WikipediaHomographData and Universal Dependencies English EWT. Model files, pinned source revisions, licences and evaluation results are in `app/mobile/shared/pronunciation/`.

A confidence threshold is calibrated on development data; grammatical confidence is checked independently. On 1,615 held-out examples, the packaged model accepted 1,446 choices (89.5%) with 99.4% accuracy among those accepted. This measures labelled meaning selection, not overall audio quality. Uncertain cases retain eSpeak's pronunciation, so some ambiguity remains. Names and words outside the annotated lexicon use the existing frontend.

## Apple Intelligence

The native iPhone and Mac apps also offer on-device summaries, explanations and questions about the current passage. Open a reading and choose the sparkle button. This requires iOS/macOS 26 or later, a compatible device, Apple Intelligence enabled, and Apple's model ready. The app checks availability; unsupported devices can still read normally. Requests use a bounded passage, not an entire book, and no hosted AI service is contacted.

Apple's model does **not** make pronunciation decisions. Its word-meaning fallback passed simple examples but failed an independent difficult-case check (7 correct out of 11 accepted choices from 40 sampled uncertain examples). That approach was rejected. Speech uses the same calibrated portable model on Apple devices, Android and the desktop helper.

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

## Native playback

Kitten and Kokoro schedule PCM chunks from successive passages on one continuous
audio timeline. The queue keeps bounded audio ahead and preserves it when paused.
Changing speed updates time stretching and preparation lead without regenerating
speech. Original UTF-16 source ranges map to the model's token durations. The
desktop helper also uses these duration outputs; Whisper is needed only for the
optional dictation tool.
