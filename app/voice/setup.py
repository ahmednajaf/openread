"""One-time local setup. Run with Python 3.11–3.13; no global packages are changed."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
import venv

ROOT = Path(__file__).resolve().parents[2]
MODELS = ROOT / ".local" / "models"
RELEASE = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.1/"
FILES = {
    "kokoro-v1.0.onnx": "beb0d1848dee9a49da392cc3df26958d46cfa35d321edf434f52949153f0df3a",
    "voices-v1.0.bin": "bca610b8308e8d99f32e6fe4197e7ec01679264efed0cac9140fe9c29f1fbf7d",
}


def main():
    if not (3, 11) <= sys.version_info[:2] < (3, 14):
        raise SystemExit("Use Python 3.11–3.13, for example: python3.11 app/voice/setup.py")
    environment = ROOT / ".venv"
    if not environment.exists():
        print("Creating a private Python environment…", flush=True)
        venv.create(environment, with_pip=True)
    python = environment / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    subprocess.run([str(python), "-m", "pip", "install", "-r", str(ROOT / "app/voice/requirements.txt")], check=True)
    MODELS.mkdir(parents=True, exist_ok=True)
    records = []
    for name in FILES:
        destination = MODELS / name
        if not destination.exists():
            print(f"Downloading {name} (one-time download)…", flush=True)
            temporary = destination.with_suffix(destination.suffix + ".part")
            request = urllib.request.Request(RELEASE + name, headers={"User-Agent": "OpenRead/0.1"})
            try:
                with urllib.request.urlopen(request, timeout=120) as response, temporary.open("wb") as output:
                    length = int(response.headers.get("Content-Length", 0))
                    downloaded = 0
                    last_report = 0
                    while data := response.read(1024 * 1024):
                        output.write(data)
                        downloaded += len(data)
                        if downloaded - last_report >= 25 * 1024 * 1024:
                            print(f"  {downloaded // (1024 * 1024)} MB" + (f" / {length // (1024 * 1024)} MB" if length else ""), flush=True)
                            last_report = downloaded
                    if length and downloaded != length:
                        raise RuntimeError("Incomplete download; run setup again.")
                temporary.replace(destination)
            finally:
                temporary.unlink(missing_ok=True)
        with destination.open("rb") as downloaded:
            digest = hashlib.file_digest(downloaded, "sha256").hexdigest()
        if digest != FILES[name]:
            raise SystemExit(f"Checksum mismatch for {name}. Remove .local/models/{name} and retry; don't use this file.")
        records.append({"name": name, "url": RELEASE + name, "sha256": digest})
    (MODELS / "sources.json").write_text(json.dumps(records, indent=2) + "\n")
    print('Setting up the featured Kitten voices…', flush=True)
    subprocess.run([str(python), str(ROOT / 'app/voice/setup_voices.py')], check=True)
    (ROOT / '.local/setup-version').write_text(json.loads((ROOT / 'package.json').read_text())['version'])
    print("\nReady. Start the voice with:\n  .venv/bin/python app/voice/server.py\n", flush=True)
    print("The downloaded model is Apache-2.0 licensed. See THIRD_PARTY.md.")


if __name__ == "__main__":
    main()
