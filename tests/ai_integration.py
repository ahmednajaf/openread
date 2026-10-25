"""Opt-in checks against downloaded Qwen, Kokoro, and Whisper; no network AI."""
import base64
import io
from pathlib import Path
import sys
import wave
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'voice'))
import features as f
from server import KokoroVoice
source = 'The community library is open from 9 am to 5 pm. Ada hosts a free reading club every Wednesday at 2 pm. Members bring one book. The group decided to keep the club free. Alex will upload the meeting notes by Friday. There is no membership fee.'
progress = lambda value: print(value, flush=True)
assert f.capabilities()['ai'], 'Run Set Up AI.command first.'
summary = f.ai_task({'text': source, 'mode': 'summary'}, lambda: None, progress)
assert 'library' in summary['text'].lower() or 'reading' in summary['text'].lower(), summary
answer = f.ai_task({'text': source, 'mode': 'chat', 'question': 'When does the reading club meet?'}, lambda: None, progress)
assert 'wednesday' in answer['text'].lower(), answer
assert answer['sources'] and 'Passage' in answer['text'], answer
followup = f.ai_task({'text': source, 'mode': 'chat', 'question': 'Who hosts it?', 'history': [{'role': 'user', 'content': 'When does the reading club meet?'}, {'role': 'assistant', 'content': answer['text']}]}, lambda: None, progress)
assert 'ada' in followup['text'].lower(), followup
notes = f.ai_task({'text': source, 'mode': 'notes'}, lambda: None, progress)
assert 'alex' in notes['text'].lower() and 'friday' in notes['text'].lower(), notes
podcast = f.ai_task({'text': source, 'mode': 'podcast'}, lambda: None, progress)
assert 2 <= len(podcast['turns']) <= 16
voice = KokoroVoice()
audio = f.export_audio({'turns': podcast['turns']}, voice.synthesize, lambda: None, progress)
with wave.open(io.BytesIO(base64.b64decode(audio['audio']))) as wav:
    assert wav.getnframes() / wav.getframerate() > 5
print('Real local AI: summary, cited question, conversational follow-up, meeting notes, valid podcast script and two-voice WAV — passed.', flush=True)
