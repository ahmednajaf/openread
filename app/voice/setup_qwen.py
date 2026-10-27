"""Build the vendored CPU runtime and download only the explicitly selected Qwen pack."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[2]

def build_runtime(root=ROOT):
    source = root / 'app/mobile/shared/qwen'
    output = root / '.local/qwen-runtime'; objects = output / 'objects'; objects.mkdir(parents=True, exist_ok=True)
    cxx = shutil.which('clang++') or shutil.which('c++'); cc = shutil.which('clang') or shutil.which('cc')
    if not cc or not cxx: raise RuntimeError('Install Apple’s Command Line Tools with Xcode, then run this setup again.')
    files = json.loads((source / 'build-sources.json').read_text())
    common = ['-O3', '-fPIC', '-pthread', '-DGGML_USE_CPU', '-DGGML_SCHED_MAX_COPIES=4', '-DGGML_VERSION="0.16.0"', '-DGGML_COMMIT="af97976c"']
    common += ['-I' + str(source / name) for name in ['include', 'vendor/src', 'vendor/ggml/include', 'vendor/ggml/src', 'vendor/ggml/src/ggml-cpu']]
    if sys.platform == 'darwin': common += ['-mmacosx-version-min=14.0']
    def compile(name):
        src = source / name; target = objects / (hashlib.sha256(name.encode()).hexdigest()[:20] + '.o')
        subprocess.run([cc if src.suffix == '.c' else cxx, '-std=c11' if src.suffix == '.c' else '-std=c++17', *common, '-c', str(src), '-o', str(target)], check=True, stdout=subprocess.DEVNULL)
        return str(target)
    print('Preparing the local Qwen engine. No Python AI packages are needed.', flush=True)
    with ThreadPoolExecutor(max_workers=4) as pool: compiled = list(pool.map(compile, files))
    destination = output / ('libopenread_qwen.dylib' if sys.platform == 'darwin' else 'libopenread_qwen.so')
    temporary = destination.with_suffix(destination.suffix + '.new')
    subprocess.run([cxx, '-dynamiclib' if sys.platform == 'darwin' else '-shared', '-pthread', *compiled, '-o', str(temporary)], check=True)
    temporary.replace(destination)
    return destination

def download(pack, root=ROOT, cancel=lambda: None, progress=lambda value: None):
    manifest = json.loads((root / 'app/mobile/shared/qwen-models.json').read_text())
    destination = root / '.local/qwen-models'; destination.mkdir(parents=True, exist_ok=True)
    assets = [asset for asset in manifest['assets'] if asset['pack'] in (pack, 'shared')]
    for asset in assets:
        target = destination / asset['name']
        def digest(path):
            with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()
        if target.exists() and target.stat().st_size == asset['bytes'] and digest(target) == asset['sha256']: continue
        temporary = target.with_suffix('.download')
        print('Downloading ' + asset['name'] + '…', flush=True)
        try:
            request = urllib.request.Request(asset['url'], headers={'User-Agent': 'OpenRead-Qwen-Setup/1'})
            copied = 0
            with urllib.request.urlopen(request, timeout=60) as response, temporary.open('wb') as output:
                while block := response.read(1024 * 1024):
                    cancel(); copied += len(block)
                    progress("Downloading Qwen · " + str(round(copied * 100 / asset['bytes'])) + "%")
                    if copied > asset['bytes']: raise ValueError('The download exceeds its expected size.')
                    output.write(block)
            if copied != asset['bytes'] or digest(temporary) != asset['sha256']: raise ValueError('The model failed its integrity check. Retry setup.')
            temporary.replace(target)
        finally: temporary.unlink(missing_ok=True)
    print('Qwen is ready. Restart OpenRead and choose a Qwen voice.', flush=True)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(); parser.add_argument('pack', choices=['expressive', 'clone', 'both'], default='expressive', nargs='?'); args = parser.parse_args()
    build_runtime()
    for pack in (['expressive', 'clone'] if args.pack == 'both' else [args.pack]): download(pack)
