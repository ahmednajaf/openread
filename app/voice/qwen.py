"""Optional pinned Qwen3-TTS/GGML engine. Audio and voice references stay local."""
import array
import base64
import ctypes as c
import io
import json
import math
from pathlib import Path
import re
import sys
import uuid
import wave

ROOT = Path(__file__).resolve().parents[2]
SPEAKERS = ('ryan', 'aiden', 'vivian', 'serena', 'dylan', 'eric', 'uncle_fu', 'ono_anna', 'sohee')
EXPRESSIVE = 'qwen-talker-1.7b-customvoice-Q4_K_M.gguf'
CLONE = 'qwen-talker-0.6b-base-Q4_K_M.gguf'

class VoiceError(ValueError):
    """Fixed public-facing errors; source text and paths are never included."""

class Params(c.Structure):
    _fields_ = [('max_audio_tokens', c.c_int32), ('temperature', c.c_float), ('top_p', c.c_float),
                ('top_k', c.c_int32), ('n_threads', c.c_int32), ('print_progress', c.c_int32), ('print_timing', c.c_int32),
                ('repetition_penalty', c.c_float), ('language_id', c.c_int32), ('instruction', c.c_char_p),
                ('speaker', c.c_char_p), ('vocoder_left_context_sec', c.c_float)]
class Result(c.Structure):
    _fields_ = [('audio', c.POINTER(c.c_float)), ('audio_len', c.c_int32), ('sample_rate', c.c_int32),
                ('success', c.c_int32), ('error_msg', c.c_char_p), ('t_total_ms', c.c_int64)]

def library_path():
    return ROOT / '.local/qwen-runtime' / ('libopenread_qwen.dylib' if sys.platform == 'darwin' else 'libopenread_qwen.so')
def ready(pack='expressive'):
    root = ROOT / '.local/qwen-models'
    name = CLONE if pack == 'clone' else EXPRESSIVE
    return library_path().is_file() and all((root / file).is_file() for file in [name, 'qwen-tokenizer-12hz-Q4_K_M.gguf'])

def estimated_words(text, duration):
    tokens = list(re.finditer(r'\S+', text)); total = sum(len(m.group()) for m in tokens) or 1
    elapsed = 0; result = []
    for token in tokens:
        start = duration * elapsed / total; elapsed += len(token.group())
        result.append({'offset': len(text[:token.start()].encode('utf-16-le')) // 2,
                       'length': len(token.group().encode('utf-16-le')) // 2,
                       'start': start, 'end': duration * elapsed / total, 'estimated': True})
    return result

def profiles():
    result = []
    for file in (ROOT / '.local/qwen-models/profiles').glob('*.json'):
        try:
            if not re.fullmatch(r'[a-f0-9]{32}', file.stem) or file.stat().st_size > 8000: continue
            item = json.loads(file.read_text()); key = item['id'].removeprefix('qwen:clone-')
            if re.fullmatch(r'[a-f0-9]{32}', key) and isinstance(item.get('name'), str) and 0 < len(item['name']) <= 80:
                result.append({'id': 'qwen:clone-' + key, 'name': item['name'], 'language': 'en-us', 'available': ready('clone'), 'pack': 'qwen-clone'})
        except (OSError, ValueError, KeyError, TypeError): continue
    return result


class QwenVoice:
    def __init__(self, root=None, library=None):
        self.root = Path(root or ROOT / '.local/qwen-models')
        self.library = c.CDLL(str(library or library_path()))
        self.library.qwen3_tts_init.restype = c.c_void_p
        for name, args in {
            'qwen3_tts_load_models_with_name': [c.c_void_p, c.c_char_p, c.c_char_p],
            'qwen3_tts_extract_icl_prompt': [c.c_void_p, c.c_char_p, c.c_char_p, c.c_char_p],
            'qwen3_tts_extract_speaker_embedding': [c.c_void_p, c.c_char_p, c.c_char_p],
            'qwen3_tts_free': [c.c_void_p], 'qwen3_tts_free_result': [Result],
        }.items(): getattr(self.library, name).argtypes = args
        for name, args in {'qwen3_tts_synthesize': [c.c_void_p, c.c_char_p, Params],
                           'qwen3_tts_synthesize_with_icl_prompt': [c.c_void_p, c.c_char_p, c.c_char_p, Params],
                           'qwen3_tts_synthesize_with_speaker_embedding': [c.c_void_p, c.c_char_p, c.c_char_p, Params]}.items():
            function = getattr(self.library, name); function.argtypes = args; function.restype = Result
        self.context = None; self.model = None

    def close(self):
        if self.context: self.library.qwen3_tts_free(self.context)
        self.context = self.model = None

    def load(self, model):
        if self.model == model: return
        self.close(); self.context = self.library.qwen3_tts_init()
        if not self.context or not self.library.qwen3_tts_load_models_with_name(self.context, str(self.root).encode(), model.encode()):
            self.close(); raise VoiceError('Qwen could not load. Install its optional voice pack and retry.')
        self.model = model

    def synthesize(self, text, voice, instruction=''):
        if not isinstance(text, str) or not text.strip() or len(text) > 1600: raise VoiceError('Choose a shorter speech passage.')
        # Keep synthesis bounded independently of the caller's passage size.
        # A long accepted request must never silently stop at the audio-token cap.
        if len(text) > 420:
            pieces = []; remaining = text
            while len(remaining) > 420:
                cut = remaining.rfind(' ', 0, 421)
                if cut < 140: cut = 420
                pieces.append(remaining[:cut]); remaining = remaining[cut:].lstrip()
            if remaining: pieces.append(remaining)
            pcm = bytearray()
            for piece in pieces:
                result = self.synthesize(piece, voice, instruction)
                with wave.open(io.BytesIO(base64.b64decode(result['audio'])), 'rb') as source: pcm.extend(source.readframes(source.getnframes()))
            output = io.BytesIO()
            with wave.open(output, 'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(pcm)
            duration = len(pcm) / 48000
            return {'audio': base64.b64encode(output.getvalue()).decode('ascii'), 'duration': duration, 'words': estimated_words(text, duration), 'voice': voice, 'timingSource': 'estimated-duration'}
        name = voice.removeprefix('qwen:'); profile = name.removeprefix('clone-') if name.startswith('clone-') else None
        if profile and not re.fullmatch(r'[a-f0-9]{32}', profile): raise VoiceError('Choose a saved voice.')
        if not profile and name not in SPEAKERS: raise VoiceError('Choose a Qwen voice.')
        if not isinstance(instruction, str) or len(instruction) > 500: raise VoiceError('Keep voice direction under 500 characters.')
        self.load(CLONE if profile else EXPRESSIVE)
        params = Params(720, .7, .9, 40, 4, 0, 0, 1.1, 2050, instruction.encode() if not profile else None, name.encode() if not profile else None, 1.)
        if profile:
            metadata = json.loads((self.root / 'profiles' / (profile + '.json')).read_text())
            quick = not metadata.get('transcript', '').strip()
            function = self.library.qwen3_tts_synthesize_with_speaker_embedding if quick else self.library.qwen3_tts_synthesize_with_icl_prompt
            result = function(self.context, text.encode(), str(self.root / 'profiles' / (profile + ('.speaker.json' if quick else '.icl'))).encode(), params)
        else: result = self.library.qwen3_tts_synthesize(self.context, text.encode(), params)
        try:
            if not result.success or result.sample_rate != 24000 or not 240 < result.audio_len <= 24000 * 90:
                raise VoiceError('Qwen did not finish this passage. Try again or choose another voice.')
            if any(not math.isfinite(result.audio[i]) for i in range(result.audio_len)): raise VoiceError('Qwen returned invalid audio. Try another passage.')
            pcm = array.array('h', (int(max(-1, min(1, result.audio[i])) * 32767) for i in range(result.audio_len)))
            if sys.byteorder != 'little': pcm.byteswap()
            output = io.BytesIO()
            with wave.open(output, 'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(pcm.tobytes())
            duration = result.audio_len / 24000
            return {'audio': base64.b64encode(output.getvalue()).decode('ascii'), 'duration': duration,
                    'words': estimated_words(text, duration), 'voice': voice, 'timingSource': 'estimated-duration'}
        finally: self.library.qwen3_tts_free_result(result)

    def clone(self, title, transcript, wav, permission):
        if permission is not True: raise VoiceError('Confirm this is your voice or you have permission to clone it.')
        if not isinstance(title, str) or not title.strip() or len(title) > 80 or not isinstance(transcript, str) or len(transcript) > 2000:
            raise VoiceError('Add a voice name. Any optional transcript must be under 2,000 characters.')
        try:
            with wave.open(io.BytesIO(wav)) as sample:
                if sample.getnchannels() != 1 or sample.getsampwidth() != 2 or sample.getframerate() != 24000 or not 3 <= sample.getnframes() / 24000 <= 30:
                    raise VoiceError('Use a 3–30 second mono WAV sample at 24 kHz.')
                frames = array.array('h', sample.readframes(sample.getnframes()))
                if not frames or max(abs(value) for value in frames) < 32: raise VoiceError('Choose a clear voice sample rather than silence.')
        except (wave.Error, EOFError): raise VoiceError('Choose a valid WAV voice sample.') from None
        self.load(CLONE); directory = self.root / 'profiles'; directory.mkdir(exist_ok=True)
        key = uuid.uuid4().hex; reference = directory / (key + '.wav'); prompt = directory / (key + ('.icl' if transcript.strip() else '.speaker.json'))
        reference.write_bytes(wav)
        try:
            prepared = self.library.qwen3_tts_extract_icl_prompt(self.context, str(reference).encode(), transcript.encode(), str(prompt).encode()) if transcript.strip() else self.library.qwen3_tts_extract_speaker_embedding(self.context, str(reference).encode(), str(prompt).encode())
            if not prepared:
                raise VoiceError('The voice sample could not be prepared. Try a clear sample without music.')
            (directory / (key + '.json')).write_text(json.dumps({'id': 'qwen:clone-' + key, 'name': title.strip(), 'transcript': transcript.strip(), 'permission': True}))
        except BaseException:
            prompt.unlink(missing_ok=True); raise
        finally: reference.unlink(missing_ok=True)
        return {'id': 'qwen:clone-' + key, 'name': title.strip()}
