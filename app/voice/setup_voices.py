"""Optional Apache-2.0 Kitten Mini voice pack, with verified upstream assets."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = 'KittenML/kitten-tts-mini-0.8'
REVISION = 'c02725660cea441db4c383af69f1f26f5cd00947'
ASSETS = {
    'kitten_tts_mini_v0_8.onnx': '0f5bbae4fc4800c98dbc544a87ecfa79510de2fb8222db30d12e5bfe9177df91',
    'voices.npz': '40ad2638952b77b7b2f30127e2608e169fc69dd256b53bd8aaa3409a33193c42',
}


def main():
    destination = ROOT / '.local/kitten-mini'
    destination.mkdir(parents=True, exist_ok=True)
    records = []
    for name, expected in ASSETS.items():
        path = destination / name
        url = f'https://huggingface.co/{REPOSITORY}/resolve/{REVISION}/{name}'
        if not path.exists():
            print(f'Downloading {name}…', flush=True)
            temporary = path.with_suffix('.part')
            try:
                with urllib.request.urlopen(url, timeout=120) as response, temporary.open('wb') as output:
                    while block := response.read(1024 * 1024):
                        output.write(block)
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        with path.open('rb') as input_file:
            actual = hashlib.file_digest(input_file, 'sha256').hexdigest()
        if actual != expected:
            raise SystemExit(f'Checksum mismatch: remove .local/kitten-mini/{name} and run setup again.')
        records.append({'name': name, 'sha256': actual, 'url': url})
    (destination / 'sources.json').write_text(json.dumps({'repository': REPOSITORY, 'revision': REVISION, 'license': 'Apache-2.0', 'files': records}, indent=2) + '\n')
    # Kitten has no duration outputs. Local Whisper supplies approximate word
    # alignment against its actual audio, rather than a made-up progress clock.
    import importlib.util
    if not (ROOT / '.local/whisper-base/model.bin').exists() or importlib.util.find_spec('faster_whisper') is None:
        subprocess.run([sys.executable, str(ROOT / 'app/voice/setup_optional.py'), 'dictation'], check=True)
    print('Eight Kitten Mini voices are ready. Restart OpenRead and reload the extension. This pack uses local Whisper word alignment, which adds latency and is less precise than Kokoro timings.')


if __name__ == '__main__':
    main()
