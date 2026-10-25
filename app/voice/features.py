"""Optional local reading tools. Only an explicit Save writes document text."""
import base64
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from html.parser import HTMLParser
import io
import json
from pathlib import Path, PurePosixPath
import re
import sqlite3
import threading
import time
import urllib.error
import urllib.request
import uuid
import wave
import zipfile
try:
    from . import prompts
except ImportError:
    import prompts
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
MAX_DOCUMENT = 250_000
MAX_FILE = 20 * 1024 * 1024
OLLAMA = 'http://127.0.0.1:11434'
AI_MODEL = 'qwen3:4b'


class ToolError(ValueError):
    pass


def document_text(value):
    if not isinstance(value, str) or not value.strip() or len(value) > MAX_DOCUMENT:
        raise ToolError('Choose text containing 1–250,000 characters. Split larger books into chapters.')
    return value.strip()


def decode_file(payload):
    value = payload.get('data')
    if not isinstance(value, str) or len(value) > (MAX_FILE * 4 // 3 + 4):
        raise ToolError('Choose a file smaller than 20 MB.')
    try:
        data = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ToolError('The file could not be decoded.') from None
    if not data or len(data) > MAX_FILE:
        raise ToolError('Choose a file smaller than 20 MB.')
    name = payload.get('name', '')
    if not isinstance(name, str) or len(name) > 240:
        raise ToolError('Invalid filename.')
    return name, data


class HTMLText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):
        if tag in ('script', 'style', 'nav', 'footer', 'noscript', 'svg'):
            self.skip += 1
        if not self.skip and tag in ('p', 'div', 'h1', 'h2', 'h3', 'li', 'br', 'section'):
            self.parts.append('\n\n' if tag != 'li' else '\n• ')

    def handle_endtag(self, tag):
        if tag in ('script', 'style', 'nav', 'footer', 'noscript', 'svg') and self.skip:
            self.skip -= 1
        if not self.skip and tag in ('p', 'div', 'h1', 'h2', 'h3', 'li', 'section'):
            self.parts.append('\n\n')

    def handle_data(self, data):
        if not self.skip:
            self.parts.append(data)


def html_text(value):
    parser = HTMLText()
    parser.feed(value)
    return re.sub(r'\n[ \t]*\n(?:\s*\n)+', '\n\n', ''.join(parser.parts)).strip()


def xml(data):
    if b'<!DOCTYPE' in data.upper() or b'<!ENTITY' in data.upper():
        raise ToolError('This document contains unsupported XML declarations.')
    return ET.fromstring(data)


def checked_zip(data):
    archive = zipfile.ZipFile(io.BytesIO(data))
    if len(archive.infolist()) > 3000 or sum(i.file_size for i in archive.infolist()) > 50 * 1024 * 1024:
        archive.close()
        raise ToolError('This document expands beyond the 50 MB import limit.')
    if any(i.flag_bits & 1 for i in archive.infolist()):
        archive.close()
        raise ToolError('Password-protected documents are not supported.')
    return archive


def ocr_image(data):
    try:
        import Vision
        import Foundation
        import AppKit
    except ImportError:
        raise ToolError('Scan & Listen needs macOS. Run Set Up OpenRead.command to install its OCR bridge.') from None
    image_data = Foundation.NSData.dataWithBytes_length_(data, len(data))
    image = AppKit.NSBitmapImageRep.imageRepWithData_(image_data)
    if image is None or image.pixelsWide() * image.pixelsHigh() > 40_000_000:
        raise ToolError('Choose a valid image smaller than 40 megapixels.')
    request = Vision.VNRecognizeTextRequest.alloc().init()
    request.setRecognitionLevel_(Vision.VNRequestTextRecognitionLevelAccurate)
    request.setUsesLanguageCorrection_(True)
    handler = Vision.VNImageRequestHandler.alloc().initWithData_options_(image_data, {})
    success, _error = handler.performRequests_error_([request], None)
    if not success:
        raise ToolError('macOS could not recognize text in this image.')
    lines = []
    for observation in request.results() or []:
        candidates = observation.topCandidates_(1)
        if candidates:
            lines.append(str(candidates[0].string()))
    return '\n'.join(lines)


def pdf_text(data, cancelled):
    from pypdf import PdfReader
    reader = PdfReader(io.BytesIO(data))
    if reader.is_encrypted:
        raise ToolError('Open an unlocked copy of this PDF first.')
    if len(reader.pages) > 200:
        raise ToolError('Import up to 200 PDF pages at a time. Split this PDF into sections.')
    parts = []
    scan = None
    scan_count = 0
    for index, page in enumerate(reader.pages):
        cancelled()
        text = (page.extract_text() or '').strip()
        if not text:
            # OCR uses Apple's on-device Vision model. No hosted OCR service.
            scan_count += 1
            if scan_count > 20:
                raise ToolError('Scan up to 20 PDF pages at a time. Split this scanned PDF into sections.')
            try:
                import Quartz
                if scan is None:
                    provider = Quartz.CGDataProviderCreateWithCFData(data)
                    scan = Quartz.CGPDFDocumentCreateWithProvider(provider)
                native_page = Quartz.CGPDFDocumentGetPage(scan, index + 1)
                rect = Quartz.CGPDFPageGetBoxRect(native_page, Quartz.kCGPDFMediaBox)
                scale = min(2.0, 2200 / max(rect.size.width, rect.size.height))
                width, height = max(1, int(rect.size.width * scale)), max(1, int(rect.size.height * scale))
                context = Quartz.CGBitmapContextCreate(None, width, height, 8, width * 4,
                    Quartz.CGColorSpaceCreateDeviceRGB(), Quartz.kCGImageAlphaPremultipliedLast)
                Quartz.CGContextSetRGBFillColor(context, 1, 1, 1, 1)
                Quartz.CGContextFillRect(context, ((0, 0), (width, height)))
                Quartz.CGContextScaleCTM(context, scale, scale)
                Quartz.CGContextTranslateCTM(context, -rect.origin.x, -rect.origin.y)
                Quartz.CGContextDrawPDFPage(context, native_page)
                image = Quartz.CGBitmapContextCreateImage(context)
                output = __import__('Foundation').NSMutableData.data()
                destination = Quartz.CGImageDestinationCreateWithData(output, 'public.png', 1, None)
                Quartz.CGImageDestinationAddImage(destination, image, None)
                Quartz.CGImageDestinationFinalize(destination)
                text = ocr_image(bytes(output))
            except ImportError:
                raise ToolError('This is a scanned PDF. Scan & Listen currently needs macOS and the OCR setup.') from None
        if text:
            parts.append(text)
        if sum(len(p) for p in parts) > MAX_DOCUMENT:
            raise ToolError('This PDF contains over 250,000 characters. Import fewer pages.')
    return '\n\n'.join(parts)


def import_document(payload, cancelled=lambda: None):
    name, data = decode_file(payload)
    suffix = Path(name).suffix.lower()
    title = Path(name).stem or 'Imported document'
    if suffix == '.pdf':
        text = pdf_text(data, cancelled)
    elif suffix == '.docx':
        with checked_zip(data) as archive:
            root = xml(archive.read('word/document.xml'))
            namespace = {'w': 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
            text = '\n\n'.join(''.join(t.text or '' for t in p.findall('.//w:t', namespace)) for p in root.findall('.//w:p', namespace))
    elif suffix == '.epub':
        with checked_zip(data) as archive:
            container = xml(archive.read('META-INF/container.xml'))
            rootfile = next((e.attrib.get('full-path') for e in container.iter() if e.tag.endswith('rootfile')), None)
            if not rootfile:
                raise ToolError('This EPUB has no reading order.')
            package = xml(archive.read(rootfile))
            manifest = {e.attrib.get('id'): e.attrib.get('href') for e in package.iter() if e.tag.endswith('}item')}
            order = [e.attrib.get('idref') for e in package.iter() if e.tag.endswith('}itemref')]
            parts = []
            for key in order:
                cancelled()
                href = manifest.get(key)
                if href:
                    member = str(PurePosixPath(rootfile).parent / href.split('#')[0])
                    parts.append(html_text(archive.read(member).decode('utf-8-sig')))
            text = '\n\n'.join(parts)
    elif suffix in ('.html', '.htm'):
        text = html_text(data.decode('utf-8-sig'))
    elif suffix in ('.txt', '.md', '.csv'):
        text = data.decode('utf-8-sig')
    elif suffix in ('.png', '.jpg', '.jpeg', '.heic', '.tif', '.tiff', '.webp'):
        text = ocr_image(data)
    else:
        raise ToolError('Choose a PDF, EPUB, DOCX, text file, HTML file, or image.')
    return {'title': title, 'text': document_text(text), 'source': name}


class Library:
    def __init__(self, path=None):
        self.path = Path(path or ROOT / '.local/library.sqlite3')
        self.lock = threading.Lock()

    def connection(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(self.path)
        self.path.chmod(0o600)
        db.row_factory = sqlite3.Row
        db.execute('CREATE TABLE IF NOT EXISTS documents (id TEXT PRIMARY KEY, title TEXT, text TEXT, source TEXT, position INTEGER, bookmarks TEXT, updated TEXT)')
        return db

    def list(self):
        with self.lock, self.connection() as db:
            return [dict(row) for row in db.execute('SELECT id,title,source,position,updated FROM documents ORDER BY updated DESC')]

    def get(self, key):
        with self.lock, self.connection() as db:
            row = db.execute('SELECT * FROM documents WHERE id=?', (key,)).fetchone()
            if not row:
                raise ToolError('That saved document is no longer in your library.')
            result = dict(row)
            result['bookmarks'] = json.loads(result['bookmarks'])
            return result

    def save(self, payload):
        text = document_text(payload.get('text'))
        title = payload.get('title', 'Untitled')
        source = payload.get('source', '')
        key = payload.get('id') or str(uuid.uuid4())
        if not all(isinstance(v, str) for v in (title, source, key)) or len(title) > 240 or len(source) > 1000 or len(key) > 80:
            raise ToolError('Invalid document details.')
        position = payload.get('position', 0)
        bookmarks = payload.get('bookmarks', [])
        if type(position) is not int or not 0 <= position <= MAX_DOCUMENT or not isinstance(bookmarks, list) or len(bookmarks) > 200:
            raise ToolError('Invalid reading position or bookmarks.')
        for mark in bookmarks:
            if not isinstance(mark, dict) or type(mark.get('position')) is not int or not 0 <= mark['position'] <= MAX_DOCUMENT or not isinstance(mark.get('label'), str) or len(mark['label']) > 160:
                raise ToolError('Invalid bookmark.')
        with self.lock, self.connection() as db:
            if db.execute('SELECT count(*) FROM documents').fetchone()[0] >= 200 and not db.execute('SELECT 1 FROM documents WHERE id=?', (key,)).fetchone():
                raise ToolError('Your library holds 200 documents. Delete or export some before adding more.')
            db.execute('INSERT OR REPLACE INTO documents VALUES(?,?,?,?,?,?,?)', (key, title.strip() or 'Untitled', text, source, position, json.dumps(bookmarks), datetime.now(timezone.utc).isoformat()))
        return self.get(key)

    def delete(self, key):
        with self.lock, self.connection() as db:
            db.execute('DELETE FROM documents WHERE id=?', (key,))
        return {'deleted': True}


def ollama_request(path, payload=None, timeout=4):
    body = None if payload is None else json.dumps(payload).encode()
    request = urllib.request.Request(OLLAMA + path, data=body, headers={'Content-Type': 'application/json'})
    try:
        # Never use system proxies for private document requests to loopback.
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(request, timeout=timeout) as response:
            return json.loads(response.read(2 * 1024 * 1024))
    except (OSError, ValueError, urllib.error.URLError):
        raise ToolError('Local AI is unavailable. Run setup/Set Up AI.command, then start Ollama and try again.') from None


def capabilities():
    try:
        tags = ollama_request('/api/tags')
        ai = any(item.get('name') == AI_MODEL for item in tags.get('models', []))
    except ToolError:
        ai = False
    import importlib.util
    return {'ai': ai, 'aiModel': AI_MODEL, 'transcription': (ROOT / '.local/whisper-base/model.bin').exists() and importlib.util.find_spec('faster_whisper') is not None,
            'ocr': __import__('sys').platform == 'darwin' and importlib.util.find_spec('Vision') is not None,
            'pdf': importlib.util.find_spec('pypdf') is not None, 'extraVoices': __import__('kitten').ready()}


def chat_model(messages, json_output=False, schema=None):
    # Keep final answers separate even with older runner/templates that emit
    # reasoning delimiters in content instead of the separate thinking field.
    messages = [dict(message) for message in messages]
    for message in messages:
        if message['role'] == 'system':
            message['content'] += '\nReturn only the requested final answer. /no_think'
            break
    result = ollama_request('/api/chat', {'model': AI_MODEL, 'messages': messages, 'stream': False, 'think': False,
        'keep_alive': '5m', 'options': {'temperature': .25, 'num_ctx': 8192, 'num_predict': 2000 if json_output else 1200},
        **({'format': schema or 'json'} if json_output else {})}, timeout=300)
    if result.get('done_reason') == 'length':
        raise ToolError('The local model stopped before completing its answer. Try a shorter excerpt.')
    value = result.get('message', {}).get('content', '').strip()
    # Some templates prefill <think>, leaving only its closing tag in content.
    if '</think>' in value:
        value = value.rsplit('</think>', 1)[1].strip()
    if '<think>' in value:
        raise ToolError('The local model stopped before its final answer. Try again.')
    if not value:
        raise ToolError('The local model returned an empty answer. Try again.')
    return value


def sections(text, limit=7000):
    result = []
    while text:
        end = len(text) if len(text) <= limit else max(text.rfind('\n', 0, limit), text.rfind(' ', 0, limit))
        if end < limit // 2 and len(text) > limit:
            end = limit
        result.append(text[:end].strip())
        text = text[end:].strip()
    return result


def ai_task(payload, cancelled, progress):
    text = document_text(payload.get('text'))
    mode = payload.get('mode')
    if mode not in ('summary', 'chat', 'podcast', 'notes'):
        raise ToolError('Choose summary, chat, podcast, or meeting notes.')
    system = prompts.BASE
    if mode == 'chat':
        question = payload.get('question')
        if not isinstance(question, str) or not question.strip() or len(question) > 2000:
            raise ToolError('Ask a question under 2,000 characters.')
        history = payload.get('history', [])
        if not isinstance(history, list) or len(history) > 6 or any(not isinstance(m, dict) or m.get('role') not in ('user', 'assistant') or not isinstance(m.get('content'), str) or len(m['content']) > 12000 for m in history):
            raise ToolError('Invalid chat history. Start a new reading to reset the conversation.')
        blocks = sections(text, 1000)
        history = [{'role': m['role'], 'content': m['content'][:1200]} for m in history[-4:]]
        recent_questions = ' '.join(m['content'] for m in history if m['role'] == 'user')[-2000:]
        terms = set(re.findall(r'\w+', (recent_questions + ' ' + question).lower()))
        ranked = sorted(range(len(blocks)), key=lambda i: sum(blocks[i].lower().count(t) for t in terms if len(t) > 2), reverse=True)[:6]
        context = '\n\n'.join(f'[Passage {i + 1}] {blocks[i]}' for i in sorted(ranked))
        progress('Reading relevant passages…')
        answer = chat_model([{'role': 'system', 'content': system + '\n' + prompts.CHAT},
            {'role': 'user', 'content': json.dumps({'source_excerpts': context, 'conversation': history, 'question': question})}])
        return {'text': answer, 'sources': [{'passage': i + 1, 'text': blocks[i]} for i in sorted(ranked)]}
    blocks = sections(text, 8000)
    summaries = []
    for index, block in enumerate(blocks):
        cancelled()
        progress(f'Reading section {index + 1} of {len(blocks)}…')
        if len(blocks) == 1:
            summaries.append(block)
        else:
            summaries.append(chat_model([{'role': 'system', 'content': system + '\n' + prompts.SECTION}, {'role': 'user', 'content': json.dumps({'source': block})}]))
    cancelled()
    context = '\n\n'.join(summaries)
    # Reduce arbitrarily long documents without silently dropping later sections.
    while len(context) > 9000:
        reduced = []
        for block in sections(context, 8000):
            cancelled()
            progress('Combining section summaries…')
            reduced.append(chat_model([{'role': 'system', 'content': system + '\n' + prompts.REDUCE}, {'role': 'user', 'content': json.dumps({'notes': block})}]))
        context = '\n\n'.join(reduced)
    if mode == 'podcast':
        return podcast_task(context, cancelled, progress)
    progress('Writing your notes…' if mode == 'notes' else 'Writing your summary…')
    instruction = prompts.NOTES if mode == 'notes' else prompts.SUMMARY
    result = chat_model([{'role': 'system', 'content': system + '\n' + instruction}, {'role': 'user', 'content': json.dumps({'source_or_section_notes': context})}])
    return {'text': result, 'sections': len(blocks), 'promptVersion': prompts.VERSION}


def validate_podcast(script, ids, turns_count, budget, context=""):
    turns = script['turns']
    if not isinstance(turns, list) or len(turns) != turns_count:
        raise ValueError('Use exactly the requested number of turns.')
    count = 0
    for index, turn in enumerate(turns):
        if not isinstance(turn, dict) or turn.get('speaker') != ('A' if index % 2 == 0 else 'B'):
            raise ValueError('Alternate A and B, beginning with A.')
        text = turn.get('text')
        if not isinstance(text, str) or not text.strip() or len(text) > 700:
            raise ValueError('Keep every turn under 700 characters.')
        if re.search(r'https?://|\[(?:laugh|music|excited|pause)|<[^>]+>', text, re.I):
            raise ValueError('Use spoken text only, without URLs or performance markup.')
        references = turn.get('sources')
        if not isinstance(references, list) or not references or any(ref not in ids for ref in references):
            raise ValueError('Use only the supplied fact IDs as sources.')
        count += len(text.split())
    if count > budget * 1.15:
        raise ValueError(f'Keep the total at or below {budget} words.')
    transcript = ' '.join(turn['text'] for turn in turns).lower()
    if re.search(r"what['’]s the catch|the catch is|let['’]s delve|welcome to (?:our|the) podcast", transcript):
        raise ValueError('Remove canned hooks and invented tension. Open with a concrete source idea.')
    for marker in ['only if', 'must', 'required', 'guaranteed', 'forever', 'always']:
        if re.search(r'\b' + re.escape(marker) + r'\b', transcript) and not re.search(r'\b' + re.escape(marker) + r'\b', context.lower()):
            raise ValueError(f'Do not introduce the unsupported condition or certainty: {marker}. Use the source wording.')
    return turns, count


def podcast_task(context, cancelled, progress):
    progress('Building a source-grounded podcast brief…')
    raw = chat_model([{'role': 'system', 'content': prompts.BASE + '\n' + prompts.PODCAST_BRIEF},
        {'role': 'user', 'content': json.dumps({'source_or_section_notes': context})}], json_output=True, schema=prompts.BRIEF_SCHEMA)
    try:
        brief = json.loads(raw)
        facts = brief['facts']
        if not isinstance(facts, list) or not 1 <= len(facts) <= 6:
            raise ValueError()
        normalized_source = ' '.join(context.split())
        for index, fact in enumerate(facts):
            if not isinstance(fact, dict) or not isinstance(fact.get('claim'), str) or not isinstance(fact.get('quote'), str):
                raise ValueError()
            quote = ' '.join(fact['quote'].split())
            if not quote or len(quote) > 220 or quote not in normalized_source:
                raise ValueError()
            fact['id'] = f'F{index + 1}'
            fact['claim'] = quote  # Never strengthen the model's paraphrase beyond its exact evidence.
    except (ValueError, KeyError, TypeError):
        raise ToolError('The model could not build a verifiable source brief. Try a shorter excerpt.') from None
    cancelled()
    short = len(context.split()) < 100
    turns_count, budget = (4, 110) if short else (8, 230)
    ids = [fact['id'] for fact in facts]
    request = {'source_brief': brief, 'source_or_section_notes': context, 'requested_turns': turns_count,
        'maximum_total_words': budget, 'language': 'English', 'speakers': {'A': 'curious listener', 'B': 'warm explainer'}}
    for attempt in range(2):
        progress('Writing the conversation…' if attempt == 0 else 'Refining the script for length and grounding…')
        raw = chat_model([{'role': 'system', 'content': prompts.BASE + '\n' + prompts.PODCAST},
            {'role': 'user', 'content': json.dumps(request)}], json_output=True, schema=prompts.podcast_schema(ids))
        cancelled()
        try:
            script = json.loads(raw)
            turns = script['turns']
            turns, count = validate_podcast(script, ids, turns_count, budget, context)
            progress('Checking the conversation against the source…')
            reviewed = chat_model([{'role': 'system', 'content': prompts.BASE + '\n' + prompts.PODCAST_REVIEW},
                {'role': 'user', 'content': json.dumps({**request, 'candidate_dialogue': script})}], json_output=True, schema=prompts.podcast_schema(ids))
            cancelled()
            script = json.loads(reviewed)
            turns, count = validate_podcast(script, ids, turns_count, budget, context)
            return {'title': str(script.get('title', 'Your audio overview'))[:240], 'turns': turns,
                'text': '\n\n'.join(f"{t['speaker']}: {t['text']}" for t in turns), 'sourceFacts': facts,
                'promptVersion': prompts.VERSION, 'wordCount': count, 'sourceReview': True}
        except (ValueError, KeyError, TypeError) as error:
            if attempt:
                raise ToolError('The model could not produce a valid short conversation. Try a shorter excerpt.') from None
            request['revision_requirement'] = str(error)


WHISPER_LOCK = threading.Lock()
_whisper_model = None


def whisper_model():
    global _whisper_model
    path = ROOT / '.local/whisper-base'
    if not (path / 'model.bin').exists():
        raise ToolError('Dictation needs its local model. Run setup/Set Up Dictation.command once.')
    if _whisper_model is None:
        from faster_whisper import WhisperModel
        _whisper_model = WhisperModel(str(path), device='cpu', compute_type='int8', local_files_only=True, cpu_threads=4)
    return _whisper_model


def whisper_word_timings(audio, text):
    with WHISPER_LOCK:
        # Feeding the full passage as a previous-transcript prompt can make
        # Whisper resume at its end, collapsing all earlier word boundaries.
        # Recognize the audio independently, then align it to the source.
        segments, _info = whisper_model().transcribe(audio, language='en', beam_size=3, word_timestamps=True,
            condition_on_previous_text=False, vad_filter=False)
        return [word for segment in segments for word in (segment.words or [])]


def transcribe(payload, cancelled=lambda: None, progress=lambda _: None):
    _name, data = decode_file(payload)
    progress('Loading local dictation…')
    with WHISPER_LOCK:
        model = whisper_model()
        segments, info = model.transcribe(io.BytesIO(data), beam_size=3, vad_filter=True)
        if info.duration > 3600:
            raise ToolError('Transcribe up to one hour at a time. Split longer recordings.')
        text = []
        for segment in segments:
            cancelled()
            progress(f'Transcribing {int(segment.end)} of {int(info.duration)} seconds…')
            text.append(segment.text.strip())
            if sum(map(len, text)) > MAX_DOCUMENT:
                raise ToolError('This transcript exceeds 250,000 characters.')
    return {'text': document_text(' '.join(text)), 'language': info.language, 'duration': info.duration}


def export_audio(payload, synthesize, cancelled, progress):
    turns = payload.get('turns')
    if turns is None:
        text = document_text(payload.get('text'))
        if len(text) > 50_000:
            raise ToolError('Export up to 50,000 characters at a time. Split longer documents into chapters.')
        turns = [{'text': block, 'voice': payload.get('voice', 'af_heart')} for block in sections(text, 500)]
    else:
        if not isinstance(turns, list) or not 1 <= len(turns) <= 16:
            raise ToolError('Invalid podcast script.')
        expanded = []
        for turn in turns:
            if not isinstance(turn, dict) or turn.get('speaker') not in ('A', 'B'):
                raise ToolError('Invalid podcast speaker.')
            text = document_text(turn.get('text'))
            if len(text) > 700:
                raise ToolError('Keep each podcast turn under 700 characters.')
            expanded.extend({'text': block, 'voice': 'kitten:kiki' if turn['speaker'] == 'A' else 'kitten:jasper'} for block in sections(text, 500))
        turns = expanded
    output = io.BytesIO()
    rate = None
    with wave.open(output, 'wb') as target:
        target.setnchannels(1)
        target.setsampwidth(2)
        for index, turn in enumerate(turns):
            cancelled()
            progress(f'Generating audio {index + 1} of {len(turns)}…')
            result = synthesize(turn['text'], turn['voice'])
            with wave.open(io.BytesIO(base64.b64decode(result['audio'])), 'rb') as source:
                if source.getnchannels() != 1 or source.getsampwidth() != 2 or rate and source.getframerate() != rate:
                    raise ToolError('The voice returned an incompatible audio format.')
                if rate is None:
                    rate = source.getframerate()
                    target.setframerate(rate)
                target.writeframes(source.readframes(source.getnframes()))
                target.writeframes(b'\0\0' * int(rate * .2))
            if output.tell() > 150 * 1024 * 1024:
                raise ToolError('This audio is too large. Export a shorter section.')
    return {'audio': base64.b64encode(output.getvalue()).decode('ascii'), 'filename': 'openread.wav', 'mime': 'audio/wav'}


class Jobs:
    """Bounded local work queue with cancellation and expiring in-memory results."""
    def __init__(self):
        self.pool = ThreadPoolExecutor(max_workers=2)
        self.lock = threading.Lock()
        self.jobs = {}

    def start(self, operation):
        with self.lock:
            now = time.monotonic()
            self.jobs = {key: job for key, job in self.jobs.items() if job['status'] in ('running', 'queued') or now - job['time'] < 900}
            if sum(j['status'] in ('running', 'queued') for j in self.jobs.values()) >= 4 or len(self.jobs) >= 10:
                raise ToolError('The local work queue is full. Cancel a task or wait for one to finish.')
            key = str(uuid.uuid4())
            job = {'id': key, 'status': 'queued', 'message': 'Waiting…', 'time': now, 'cancel': threading.Event()}
            self.jobs[key] = job

        def cancelled():
            if job['cancel'].is_set():
                raise ToolError('Task cancelled.')

        def progress(message):
            with self.lock:
                job['message'] = message

        def run():
            with self.lock:
                job['status'] = 'running'
            try:
                cancelled()
                result = operation(cancelled, progress)
                cancelled()
                with self.lock:
                    job.update(status='done', result=result, message='Ready', time=time.monotonic())
            except Exception as error:
                with self.lock:
                    job.update(status='cancelled' if job['cancel'].is_set() else 'error',
                        message=str(error) if isinstance(error, ToolError) else 'This local task failed. Check the file format and setup, then try again.', time=time.monotonic())
        self.pool.submit(run)
        return {'id': key}

    def get(self, key, cancel=False, consume=False):
        with self.lock:
            job = self.jobs.get(key)
            if not job:
                raise ToolError('This task expired. Start it again.')
            if cancel:
                job['cancel'].set()
            result = {k: v for k, v in job.items() if k not in ('cancel', 'time')}
            if consume and job['status'] not in ('running', 'queued'):
                del self.jobs[key]
                result.pop('result', None)
            return result
