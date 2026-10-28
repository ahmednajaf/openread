#!/bin/zsh
# Shared Finder launcher. No Homebrew, Node, or global Python package changes.
set -e
project_dir="${0:A:h:h:h}"
cd "$project_dir"
mode="${1:-start}"
python_bin=""
for candidate in "$project_dir/.venv/bin/python" python3.13 python3.12 python3.11 /Library/Frameworks/Python.framework/Versions/3.13/bin/python3 /Library/Frameworks/Python.framework/Versions/3.12/bin/python3 /Library/Frameworks/Python.framework/Versions/3.11/bin/python3; do
  if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c 'import sys;sys.exit(not ((3,11) <= sys.version_info[:2] < (3,14)))' 2>/dev/null; then python_bin="$candidate"; break; fi
done
if [[ -z "$python_bin" ]]; then
  print "One thing to install first: Python 3.13 from https://www.python.org/downloads/"
  print "Choose the macOS installer. Open its Install Certificates.command once after installing."
  print "Then double-click Set Up OpenRead.command again. No coding or Terminal commands needed."
  open 'https://www.python.org/downloads/macos/'
  read -r "?Press Return to close."
  exit 1
fi
if [[ "$mode" == setup || ! -x .venv/bin/python || ! -f .local/models/kokoro-v1.0.onnx || ! -f .local/models/voices-v1.0.bin || ! -f .local/kitten-mini/sources.json || ! -f .local/setup-version ]]; then
  print "Setting up OpenRead. The voices download about 436 MB once, plus packages."
  "$python_bin" app/voice/setup.py
fi
case "$mode" in
  setup) print "Ready. Double-click Start OpenRead.command, then follow GETTING_STARTED.md." ;;
  ai) .venv/bin/python app/voice/setup_optional.py ai ;;
  dictation) .venv/bin/python app/voice/setup_optional.py dictation ;;
  voices) .venv/bin/python app/voice/setup_voices.py ;;
  start)
    if .venv/bin/python -c 'import urllib.request,json; r=urllib.request.Request("http://127.0.0.1:8765/health",headers={"X-OpenRead":"1"}); assert json.load(urllib.request.urlopen(r,timeout=2)).get("engine")=="Kokoro"' 2>/dev/null; then
      print "OpenRead is already running. Opening your library. Restart the existing helper after an update."
      open 'http://127.0.0.1:8765/'
    else
      print "Starting OpenRead. Leave this window open while listening. Control-C stops it."
      # Start an already-installed optional AI service; never pull models here.
      .venv/bin/python -c 'from app.voice.setup_optional import ensure_ollama;from pathlib import Path;ensure_ollama() if Path(".local/ai-source.json").exists() else None' 2>/dev/null || true
      ( .venv/bin/python -c 'import time,urllib.request; time.sleep(2)' ; open 'http://127.0.0.1:8765/' ) &
      exec .venv/bin/python app/voice/server.py
    fi ;;
esac
read -r "?Press Return to close."
