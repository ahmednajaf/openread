"""Local Kitten Mini adapter; no network access or automatic model downloads.

Token alphabet and input preparation adapted from KittenML/KittenTTS 0.8's
kittentts/onnx_model.py, Apache-2.0. See docs/notices/KittenTTS-LICENSE.txt.
"""
import base64
import json
from types import SimpleNamespace
from alignment import align_words
import io
from pathlib import Path
import re
import wave

ROOT = Path(__file__).resolve().parents[2]
ALIASES = {v['id'].split(':', 1)[1]: v['embedding']
           for v in json.loads((ROOT / 'extension/voices.json').read_text()) if v.get('embedding')}
SYMBOLS = '$' + ';:,.!?¡¿—…"«»"" ' + 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz' + "ɑɐɒæɓʙβɔɕçɗɖðʤəɘɚɛɜɝɞɟʄɡɠɢʛɦɧħɥʜɨɪʝɭɬɫɮʟɱɯɰŋɳɲɴøɵɸθœɶʘɹɺɾɻʀʁɽʂʃʈʧʉʊʋⱱʌɣɤʍχʎʏʑʐʒʔʡʕʢǀǁǂǃˈˌːˑʼʴʰʱʲʷˠˤ˞↓↑→↗↘'̩'ᵻ"


class VoiceError(ValueError):
    """Fixed, public-facing errors; never include the user's source text."""
    MESSAGES = {
        'voice_setup_required': 'Run setup/Set Up More Voices.command, then restart OpenRead.',
        'voice_passage_complex': 'This passage is too complex for this voice. Try a Kokoro voice.',
        'voice_alignment_failed': 'This voice could not align this passage. Try another voice.',
        'voice_empty_audio': 'This voice did not produce usable audio. Try another voice.',
    }

    def __init__(self, code):
        self.code = code
        super().__init__(self.MESSAGES[code])


def ready():
    return all((ROOT / '.local/kitten-mini' / name).exists()
               for name in ('kitten_tts_mini_v0_8.onnx', 'voices.npz', 'sources.json'))


def model_timings(sounds, vocabulary, frames, raw_samples, kept_samples, offset=0):
    """Use the model's token durations, preserving inserted separator positions."""
    prepared = ' '.join(re.findall(r'\w+|[^\w\s]', sounds))
    characters = [c for c in prepared if c in vocabulary]
    durations = [int(n) for n in frames]
    if len(durations) < len(characters) + 3 or any(n < 0 or n >= 100000 for n in durations) or not sum(durations):
        raise VoiceError('voice_alignment_failed')
    scale = raw_samples / sum(durations) / 24000
    edges = [0]
    for n in durations:
        edges.append(edges[-1] + n * scale)
    limit = kept_samples / 24000
    return [SimpleNamespace(phoneme=c, start=offset + min(limit, edges[i + 1]),
                            end=offset + min(limit, edges[i + 2]))
            for i, c in enumerate(characters)]


def trim_silence(samples):
    # Inspect only the bounded tail. Keep at least 100 ms of actual silence;
    # never cut into a soft but audible ending or remove a fixed audio length.
    silence = 0
    while silence < min(len(samples), 7200) and abs(samples[len(samples) - silence - 1]) <= .0001:
        silence += 1
    trim = max(0, silence - 2400)
    return samples[:len(samples) - trim] if trim else samples


def phoneme_chunks(sounds, vocabulary, limit=397):
    def size(text):
        prepared = ' '.join(re.findall(r'\w+|[^\w\s]', text))
        return sum(char in vocabulary for char in prepared)
    result = []; pending = ''
    for word in sounds.split():
        if size(word) > limit: raise VoiceError('voice_passage_complex')
        joined = (pending + ' ' + word).strip()
        if size(joined) > limit: result.append(pending); pending = word
        else: pending = joined
        if word[-1] in '.!?;:' and size(pending) >= 40: result.append(pending); pending = ''
    if pending: result.append(pending)
    return result


class KittenVoice:
    def __init__(self):
        import numpy as np
        import onnxruntime as ort
        import phonemizer
        import espeakng_loader
        from phonemizer.backend.espeak.wrapper import EspeakWrapper
        EspeakWrapper.set_data_path(espeakng_loader.get_data_path())
        EspeakWrapper.set_library(espeakng_loader.get_library_path())
        if not ready():
            raise VoiceError('voice_setup_required')
        options = ort.SessionOptions(); options.intra_op_num_threads = 4
        self.session = ort.InferenceSession(str(ROOT / '.local/kitten-mini/kitten_tts_mini_v0_8.onnx'), sess_options=options, providers=['CPUExecutionProvider'])
        self.voices = np.load(ROOT / '.local/kitten-mini/voices.npz', allow_pickle=False)
        self.phonemizer = phonemizer.backend.EspeakBackend(language='en-us', preserve_punctuation=True, with_stress=True)
        from pronunciation import EnglishFrontend
        self.english = EnglishFrontend(self.phonemizer)
        self.vocab = {char: index for index, char in enumerate(SYMBOLS)}
        self.np = np

    def synthesize(self, text, voice):
        np = self.np
        key = ALIASES[voice.split(':', 1)[1]]
        audio_parts = []
        timings = []
        elapsed = 0.0
        # Resolve pronunciation using the complete passage before any acoustic
        # token-window splitting, matching the native apps.
        full_sounds = self.english.phonemize(text)
        for chunk in phoneme_chunks(full_sounds, self.vocab):
            sounds = ' '.join(re.findall(r'\w+|[^\w\s]', chunk))
            tokens = [0] + [self.vocab[c] for c in sounds if c in self.vocab] + [10, 0]
            if len(tokens) > 510:
                raise VoiceError('voice_passage_complex')
            ref = min(max(1, len(text) * len(chunk) // max(1, len(full_sounds))), self.voices[key].shape[0] - 1)
            result = self.session.run(None, {'input_ids': np.array([tokens], dtype=np.int64), 'style': self.voices[key][ref:ref + 1], 'speed': np.array([1.0], dtype=np.float32)})
            samples = np.asarray(result[0]).reshape(-1)
            kept = trim_silence(samples)
            timings.extend(model_timings(chunk, self.vocab, np.asarray(result[1]).reshape(-1), len(samples), len(kept), elapsed))
            audio_parts.append(kept)
            elapsed += len(kept) / 24000
        audio = np.concatenate(audio_parts)
        if not audio.size or not np.all(np.isfinite(audio)) or np.max(np.abs(audio)) < 1e-5:
            raise VoiceError('voice_empty_audio')
        rate = 24000; duration = len(audio) / rate
        sounds = self.phonemizer.phonemize(re.findall(r'\S+', text), strip=True)
        words = align_words(text, sounds, timings, duration)
        if not words or not any(w['end'] > w['start'] for w in words):
            raise VoiceError('voice_alignment_failed')
        output = io.BytesIO()
        with wave.open(output, 'wb') as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(rate)
            wav.writeframes((np.clip(audio, -1, 1) * 32767).astype('<i2').tobytes())
        return {'audio': base64.b64encode(output.getvalue()).decode('ascii'), 'words': words, 'duration': round(duration, 4), 'voice': voice, 'timingSource': 'model-phonemes'}
