"""Local Kitten Mini adapter; no network access or automatic model downloads.

Token alphabet and input preparation adapted from KittenML/KittenTTS 0.8's
kittentts/onnx_model.py, Apache-2.0. See docs/notices/KittenTTS-LICENSE.txt.
"""
import base64
from difflib import SequenceMatcher
import io
from pathlib import Path
import re
import wave

ROOT = Path(__file__).resolve().parents[2]
ALIASES = {'bella': 'expr-voice-2-f', 'jasper': 'expr-voice-2-m', 'luna': 'expr-voice-3-f', 'bruno': 'expr-voice-3-m',
           'rosie': 'expr-voice-4-f', 'hugo': 'expr-voice-4-m', 'kiki': 'expr-voice-5-f', 'leo': 'expr-voice-5-m'}
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
    import importlib.util
    return importlib.util.find_spec('faster_whisper') is not None and all((ROOT / '.local/kitten-mini' / name).exists() for name in ('kitten_tts_mini_v0_8.onnx', 'voices.npz', 'sources.json')) and (ROOT / '.local/whisper-base/model.bin').exists()


def align_transcript(text, recognized, duration):
    tokens = list(re.finditer(r'\S+', text))
    normalize = lambda value: ''.join(c.lower() for c in value if c.isalnum())
    source = [normalize(token.group()) for token in tokens]
    actual = [normalize(word.word) for word in recognized]
    matches = {}
    for block in SequenceMatcher(None, source, actual, autojunk=False).get_matching_blocks():
        for delta in range(block.size):
            matches[block.a + delta] = recognized[block.b + delta]
    # Spread each unrecognized run across the gap between real anchors. Giving
    # that entire gap to its first word leaves every subsequent word at zero.
    bounds = {}
    cursor = 0
    while cursor < len(tokens):
        if cursor in matches:
            bounds[cursor] = (float(matches[cursor].start), float(matches[cursor].end))
            cursor += 1
            continue
        end = cursor + 1
        while end < len(tokens) and end not in matches:
            end += 1
        start_time = bounds[cursor - 1][1] if cursor else 0.0
        end_time = max(start_time, float(matches[end].start) if end in matches else duration)
        weights = [max(1, len(source[i])) for i in range(cursor, end)]
        total = sum(weights)
        elapsed = 0
        for index, weight in zip(range(cursor, end), weights):
            bounds[index] = (start_time + (end_time - start_time) * elapsed / total,
                             start_time + (end_time - start_time) * (elapsed + weight) / total)
            elapsed += weight
        cursor = end
    words = []
    for index, token in enumerate(tokens):
        if not source[index]:
            continue
        start, end = bounds[index]
        start = max(words[-1]['start'] if words else 0.0, min(duration, start))
        words.append({'offset': len(text[:token.start()].encode('utf-16-le')) // 2, 'length': len(token.group().encode('utf-16-le')) // 2,
            'start': round(start, 4), 'end': round(max(start, min(duration, end)), 4), 'estimated': True})
    return words


def speech_alignment(text, recognized, duration):
    words = align_transcript(text, recognized, duration)
    # Whisper often drops isolated headings, initials and one-word replies.
    # Keep their valid audio; mark duration-based timing explicitly rather than
    # rejecting the entire reading. Longer clips still require recognized speech.
    if not words or not recognized and (len(words) > 5 or duration > 8):
        raise VoiceError('voice_alignment_failed')
    return words, 'whisper-word-alignment' if recognized else 'estimated-duration'


def trim_silence(samples):
    # Inspect only the bounded tail. Keep at least 100 ms of actual silence;
    # never cut into a soft but audible ending or remove a fixed audio length.
    silence = 0
    while silence < min(len(samples), 7200) and abs(samples[len(samples) - silence - 1]) <= .0001:
        silence += 1
    trim = max(0, silence - 2400)
    return samples[:len(samples) - trim] if trim else samples


class KittenVoice:
    def __init__(self):
        import numpy as np
        import onnxruntime as ort
        import phonemizer
        if not ready():
            raise VoiceError('voice_setup_required')
        options = ort.SessionOptions(); options.intra_op_num_threads = 4
        self.session = ort.InferenceSession(str(ROOT / '.local/kitten-mini/kitten_tts_mini_v0_8.onnx'), sess_options=options, providers=['CPUExecutionProvider'])
        self.voices = np.load(ROOT / '.local/kitten-mini/voices.npz', allow_pickle=False)
        self.phonemizer = phonemizer.backend.EspeakBackend(language='en-us', preserve_punctuation=True, with_stress=True)
        self.vocab = {char: index for index, char in enumerate(SYMBOLS)}
        self.np = np

    def synthesize(self, text, voice):
        import features
        np = self.np
        key = ALIASES[voice.split(':', 1)[1]]
        audio_parts = []
        for section in features.sections(text, 320):
            sounds = self.phonemizer.phonemize([section])[0]
            sounds = ' '.join(re.findall(r'\w+|[^\w\s]', sounds))
            tokens = [0] + [self.vocab[c] for c in sounds if c in self.vocab] + [10, 0]
            if len(tokens) > 510:
                raise VoiceError('voice_passage_complex')
            ref = min(len(section), self.voices[key].shape[0] - 1)
            result = self.session.run(None, {'input_ids': np.array([tokens], dtype=np.int64), 'style': self.voices[key][ref:ref + 1], 'speed': np.array([1.0], dtype=np.float32)})
            samples = np.asarray(result[0]).reshape(-1)
            audio_parts.append(trim_silence(samples))
        audio = np.concatenate(audio_parts)
        if not audio.size or not np.all(np.isfinite(audio)) or np.max(np.abs(audio)) < 1e-5:
            raise VoiceError('voice_empty_audio')
        rate = 24000; duration = len(audio) / rate
        # Whisper receives 16 kHz samples and aligns recognized words back to
        # exact source offsets. These boundaries are explicitly approximate.
        resampled = np.interp(np.arange(int(len(audio) * 16000 / rate)) * rate / 16000, np.arange(len(audio)), audio).astype(np.float32)
        recognized = features.whisper_word_timings(resampled, text)
        words, timing_source = speech_alignment(text, recognized, duration)
        output = io.BytesIO()
        with wave.open(output, 'wb') as wav:
            wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(rate)
            wav.writeframes((np.clip(audio, -1, 1) * 32767).astype('<i2').tobytes())
        return {'audio': base64.b64encode(output.getvalue()).decode('ascii'), 'words': words, 'duration': round(duration, 4), 'voice': voice, 'timingSource': timing_source}
