"""Isolated local test server: real voices, disposable library, no user history."""
from pathlib import Path
import sys
import tempfile
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'voice'))
from server import KokoroVoice, make_server
from features import Library
with tempfile.TemporaryDirectory(prefix='openread-test-') as directory:
    server = make_server(KokoroVoice(), port=8766, library=Library(Path(directory) / 'library.sqlite3'))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
