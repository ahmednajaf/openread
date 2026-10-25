"""Explicit, optional model downloads. Runtime never downloads an AI model."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parent.parent


def request(path):
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open('http://127.0.0.1:11434' + path, timeout=3) as response:
        return json.load(response)


def ollama_binary():
    return shutil.which('ollama') or next((str(p) for p in [Path('/Applications/Ollama.app/Contents/Resources/ollama'), Path.home() / 'Applications/Ollama.app/Contents/Resources/ollama'] if p.exists()), None)


def ensure_ollama():
    binary = ollama_binary()
    if not binary:
        raise SystemExit('Install the free Ollama app from https://ollama.com/download first. Open it once, then run Set Up AI.command again. No account or paid API key is needed.')
    try:
        request('/api/tags')
    except (OSError, ValueError):
        environment = {**os.environ, 'OLLAMA_HOST': '127.0.0.1:11434', 'OLLAMA_NO_CLOUD': '1'}
        subprocess.Popen([binary, 'serve'], env=environment, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        for _ in range(30):
            time.sleep(.5)
            try:
                request('/api/tags')
                break
            except (OSError, ValueError):
                continue
        else:
            raise SystemExit('Ollama could not start. Open the Ollama app and try again.')
    return binary


def ai():
    binary = ensure_ollama()
    print('Downloading local AI (Qwen3 4B, about 2.5 GB). This is a one-time download; the model runs on your device.', flush=True)
    subprocess.run([binary, 'pull', 'qwen3:4b'], check=True, env={**os.environ, 'OLLAMA_HOST': '127.0.0.1:11434'})
    models = request('/api/tags')['models']
    record = next(item for item in models if item['name'] == 'qwen3:4b')
    (ROOT / '.local').mkdir(exist_ok=True)
    (ROOT / '.local/ai-source.json').write_text(json.dumps({'model': record['name'], 'digest': record['digest'], 'source': 'https://ollama.com/library/qwen3:4b', 'license': 'Apache-2.0'}, indent=2) + '\n')
    print('AI is ready. Start OpenRead, then open Library & tools for summaries, chat and audio overviews.')


def dictation():
    subprocess.run([sys.executable, '-m', 'pip', 'install', '-r', str(ROOT / 'voice/requirements-dictation.txt')], check=True)
    from huggingface_hub import HfApi, snapshot_download
    repository = 'Systran/faster-whisper-base'
    revision = HfApi().model_info(repository).sha
    destination = ROOT / '.local/whisper-base'
    print('Downloading local Whisper Base (about 150 MB). No recording is sent to a server.', flush=True)
    snapshot_download(repository, revision=revision, local_dir=str(destination), allow_patterns=['*.json', '*.txt', 'model.bin', 'README.md', 'LICENSE'])
    checksums = {p.name: hashlib.file_digest(p.open('rb'), 'sha256').hexdigest() for p in destination.iterdir() if p.is_file() and p.name != 'openread-source.json'}
    (destination / 'openread-source.json').write_text(json.dumps({'repository': repository, 'revision': revision, 'sha256': checksums, 'license': 'MIT'}, indent=2) + '\n')
    print('Dictation is ready. Open Library & tools → Dictation & notes. Microphone access is requested only when you choose Start recording.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('feature', choices=['ai', 'dictation'])
    args = parser.parse_args()
    try:
        ai() if args.feature == 'ai' else dictation()
    except KeyboardInterrupt:
        raise SystemExit('\nSetup cancelled. Run this file again to continue.')
