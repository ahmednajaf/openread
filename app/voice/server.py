"""Loopback-only speech and reading tools. Documents persist only on explicit Save."""
import argparse
import base64
from difflib import SequenceMatcher
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
from pathlib import Path
import re
import threading
from urllib.parse import urlsplit
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import features
import kitten
import wave

ROOT = Path(__file__).resolve().parents[2]
PORT = 8765
MAX_BODY = 12000
MAX_TEXT = 1600
CATALOG = json.loads((ROOT / 'extension/voices.json').read_text())
VOICES = {v['id']: (v['name'], v['lang']) for v in CATALOG}


def allowed_origin(origin, allow_preview=False, port=PORT):
    if not origin:
        # Extension background fetches / local CLIs can omit Origin. The custom
        # header is still required; websites cannot send it without preflight.
        return True
    parsed = urlsplit(origin)
    if parsed.scheme in ("safari-web-extension", "moz-extension", "chrome-extension"):
        return bool(parsed.netloc) and parsed.path in ("", "/")
    return origin == f"http://127.0.0.1:{port}" or allow_preview and origin == "http://127.0.0.1:4173"


def validate_payload(payload):
    if not isinstance(payload, dict) or not isinstance(payload.get("text"), str):
        raise ValueError("Expected a text field.")
    text = payload["text"].strip()
    if not text or len(text) > MAX_TEXT:
        raise ValueError(f"Text must contain 1–{MAX_TEXT} characters.")
    if not isinstance(payload.get('voice', 'af_heart'), str) or payload.get('voice', 'af_heart') not in VOICES:
        raise ValueError('Unknown voice.')
    return text


def align_words(text, phonemes, timings, duration):
    """Align source words to model phonemes, including expansions like '2026'.

    Offsets are UTF-16 code units for DOM Range/JavaScript compatibility. A
    contextual pronunciation can differ from an isolated word; sequence
    alignment handles that without assuming one phoneme group per source word.
    """
    tokens = list(re.finditer(r'\S+', text))
    target = []; owners = []
    for index, sound in enumerate(phonemes):
        for character in sound:
            if not character.isspace():
                target.append(character); owners.append(index)
    actual = [timing for timing in timings if not timing.phoneme.isspace()]
    matches = [[] for _ in tokens]
    matcher = SequenceMatcher(None, target, [t.phoneme for t in actual], autojunk=False)
    for block in matcher.get_matching_blocks():
        for delta in range(block.size):
            matches[owners[block.a + delta]].append(actual[block.b + delta])
    words = []
    for index, token in enumerate(tokens):
        if not any(character.isalnum() for character in token.group()):
            continue
        sound = matches[index]
        if sound:
            start, end = sound[0].start, sound[-1].end
            estimated = False
        else:
            previous = words[-1]['end'] if words else 0.0
            following = next((m[0].start for m in matches[index + 1:] if m), duration)
            start, end = previous, max(previous, following)
            estimated = True
        start = max(words[-1]['start'] if words else 0.0, min(duration, start))
        words.append({
            'offset': len(text[:token.start()].encode('utf-16-le')) // 2,
            'length': len(token.group().encode('utf-16-le')) // 2,
            'start': round(start, 4), 'end': round(max(start, min(duration, end)), 4),
            'estimated': estimated,
        })
    return words


class KokoroVoice:
    def __init__(self):
        import numpy as np
        import onnxruntime as runtime
        from kokoro_onnx import Kokoro
        runtime.disable_telemetry_events()
        models = ROOT / ".local" / "models"
        self.model = Kokoro(str(models / "kokoro-v1.0.onnx"), str(models / "voices-v1.0.bin"))
        self.np = np
        self.kitten = None

    def synthesize(self, text, voice='af_heart'):
        if voice.startswith('kitten:'):
            from kitten import KittenVoice
            if self.kitten is None:
                self.kitten = KittenVoice()
            return self.kitten.synthesize(text, voice)
        import phonemizer
        language = VOICES[voice][1]
        options = {"voice": voice, "speed": 1.0, "lang": language}
        # Current exports support overlapping windows for continuous prosody.
        if getattr(self.model, "has_timings", False):
            options["continuous"] = True
        if not getattr(self.model, 'has_timings', False):
            raise RuntimeError('This model needs duration outputs for word highlighting.')
        audio, rate, timings = self.model.create_timed(text, **options)
        tokens = re.findall(r'\S+', text)
        # Phonemize in one batch to avoid initializing eSpeak once per word.
        sounds = phonemizer.phonemize(tokens, language, preserve_punctuation=True, with_stress=True)
        sounds = [''.join(c for c in sound if c in self.model.tokenizer.vocab) for sound in sounds]
        duration = len(audio) / rate
        words = align_words(text, sounds, timings, duration)
        pcm = (self.np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes()
        output = io.BytesIO()
        with wave.open(output, "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(rate)
            wav.writeframes(pcm)
        return {'audio': base64.b64encode(output.getvalue()).decode('ascii'),
                'words': words, 'duration': round(duration, 4), 'voice': voice, 'timingSource': 'model-phonemes'}


def make_server(voice, port=PORT, allow_preview=False, library=None):
    inference = threading.Lock()
    slots = threading.BoundedSemaphore(3)
    library = library or features.Library()
    jobs = features.Jobs()

    def synthesize(text, selected_voice):
        validate_payload({'text': text, 'voice': selected_voice})
        with inference:
            return voice.synthesize(text, selected_voice)

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            super().setup()
            self.connection.settimeout(100)

        def log_message(self, *_args):
            pass

        def send_json(self, status, data):
            body = json.dumps(data).encode()
            self.send_response(status)
            origin = self.headers.get("Origin")
            if origin and allowed_origin(origin, allow_preview, self.server.server_port):
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Vary", "Origin")
            self.send_header("Content-Type", "application/json")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def authorized(self, preflight=False):
            # Reject DNS rebinding and requests from ordinary websites.
            expected = f"127.0.0.1:{self.server.server_port}"
            if self.headers.get("Host") != expected or not allowed_origin(self.headers.get("Origin"), allow_preview, self.server.server_port):
                self.send_json(403, {"error": "Origin or host not allowed."})
                return False
            if not preflight and self.headers.get("X-OpenRead") != "1":
                self.send_json(403, {"error": "Missing extension header."})
                return False
            return True

        def do_OPTIONS(self):
            if not self.authorized(preflight=True):
                return
            self.send_response(204)
            origin = self.headers.get("Origin")
            if origin:
                self.send_header("Access-Control-Allow-Origin", origin)
                self.send_header("Vary", "Origin")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type, X-OpenRead")
            self.send_header("Access-Control-Max-Age", "600")
            self.end_headers()

        def do_GET(self):
            path = urlsplit(self.path).path
            static = {'/': ROOT / 'app/reader/dist/index.html', '/app.js': ROOT / 'app/reader/dist/app.js',
                      '/app.css': ROOT / 'app/reader/dist/app.css', '/icon.png': ROOT / 'extension/icons/128.png',
                      '/core.js': ROOT / 'extension/core.js', '/player.js': ROOT / 'extension/player.js'}
            if path in static:
                if not self.authorized(preflight=True):
                    return
                try:
                    body = static[path].read_bytes()
                except OSError:
                    self.send_json(404, {'error': 'Workspace files are missing. Download the complete repository.'})
                    return
                self.send_response(200)
                suffix = static[path].suffix
                self.send_header('Content-Type', {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.png': 'image/png'}[suffix])
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Cache-Control', 'no-store')
                self.send_header('X-Content-Type-Options', 'nosniff')
                self.send_header('Content-Security-Policy', "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; media-src 'self' blob: data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            if not self.authorized():
                return
            try:
                if path == '/health':
                    self.send_json(200, {'ready': True, 'engine': 'Kokoro', 'version': 3,
                        'wordTimings': True, 'voices': [{'id': key, 'name': value[0], 'language': value[1], 'available': not key.startswith('kitten:') or __import__('kitten').ready()} for key, value in VOICES.items()]})
                elif path == '/capabilities':
                    self.send_json(200, features.capabilities())
                elif path == '/library':
                    self.send_json(200, {'documents': library.list()})
                elif path.startswith('/library/'):
                    self.send_json(200, library.get(path.split('/')[-1]))
                elif path.startswith('/jobs/'):
                    self.send_json(200, jobs.get(path.split('/')[-1], consume=urlsplit(self.path).query == 'consume=1'))
                else:
                    self.send_json(404, {'error': 'Not found.'})
            except features.ToolError as error:
                self.send_json(400, {'error': str(error)})
            except Exception:
                self.send_json(500, {'error': 'This local request failed.'})

        def do_POST(self):
            if not self.authorized():
                return
            routes = ('/synthesize', '/library/save', '/library/delete', '/import', '/ai', '/transcribe', '/export', '/jobs/cancel')
            if self.path not in routes:
                self.send_json(404, {'error': 'Not found.'})
                return
            if self.headers.get_content_type() != 'application/json':
                self.send_json(415, {'error': 'Expected JSON.'})
                return
            try:
                length = int(self.headers.get('Content-Length', '0'))
                maximum = 28 * 1024 * 1024 if self.path in ('/import', '/transcribe') else 2 * 1024 * 1024
                if self.path == '/synthesize':
                    maximum = MAX_BODY
                if not 0 < length <= maximum:
                    raise features.ToolError('This request is too large. Files must be under 20 MB.')
                payload = json.loads(self.rfile.read(length))
                if not isinstance(payload, dict):
                    raise features.ToolError('Expected a JSON object.')
                if self.path == '/library/save':
                    self.send_json(200, library.save(payload))
                elif self.path == '/library/delete':
                    self.send_json(200, library.delete(str(payload.get('id', ''))))
                elif self.path == '/jobs/cancel':
                    self.send_json(200, jobs.get(str(payload.get('id', '')), cancel=True))
                elif self.path == '/import':
                    self.send_json(202, jobs.start(lambda cancel, progress: features.import_document(payload, cancel)))
                elif self.path == '/ai':
                    self.send_json(202, jobs.start(lambda cancel, progress: features.ai_task(payload, cancel, progress)))
                elif self.path == '/transcribe':
                    self.send_json(202, jobs.start(lambda cancel, progress: features.transcribe(payload, cancel, progress)))
                elif self.path == '/export':
                    self.send_json(202, jobs.start(lambda cancel, progress: features.export_audio(payload, synthesize, cancel, progress)))
                else:
                    text = validate_payload(payload)
                    if not slots.acquire(blocking=False):
                        self.send_json(429, {'error': 'Voice is busy. Try again shortly.'})
                        return
                    try:
                        self.send_json(200, synthesize(text, payload.get('voice', 'af_heart')))
                    finally:
                        slots.release()
            except kitten.VoiceError as error:
                self.send_json(422, {'error': str(error), 'code': error.code})
            except (features.ToolError, ValueError, UnicodeError) as error:
                self.send_json(400, {'error': str(error) if isinstance(error, features.ToolError) else 'Invalid request or text.'})
            except Exception:
                # Upstream errors can contain the user's document; never log them.
                self.send_json(500, {'error': 'This local task could not be completed.'})

    server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    server.daemon_threads = True
    return server


def main():
    parser = argparse.ArgumentParser(description="OpenRead local natural voice")
    parser.add_argument("--allow-preview", action="store_true", help="Also allow the local development preview on port 4173")
    args = parser.parse_args()
    print("Loading your on-device natural voices…", flush=True)
    try:
        voice = KokoroVoice()
        server = make_server(voice, allow_preview=args.allow_preview)
    except (ImportError, FileNotFoundError):
        raise SystemExit("Run Python 3.11–3.13 with app/voice/setup.py first, then use .venv/bin/python app/voice/server.py")
    print(f"OpenRead voice ready at http://127.0.0.1:{PORT}. Press Control-C to stop.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nVoice stopped.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
