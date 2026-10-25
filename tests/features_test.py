import base64
import importlib.util
import io
import sys
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import wave
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'voice'))
spec = importlib.util.spec_from_file_location('features', Path(__file__).resolve().parent.parent / 'voice/features.py')
f = importlib.util.module_from_spec(spec)
spec.loader.exec_module(f)


def file_payload(name, data):
    return {'name': name, 'data': base64.b64encode(data).decode()}


def archive(files):
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as z:
        for name, value in files.items():
            z.writestr(name, value)
    return output.getvalue()


class ImportTests(unittest.TestCase):
    def test_html_preserves_link_words_and_lists_without_code_or_navigation(self):
        result = f.import_document(file_payload('article.html', b'<nav>Navigation</nav><h1>Reading</h1><p>A <a href="https://secret.example">linked word</a>.</p><ul><li>First</li><li>Second</li></ul><script>secret()</script>'))
        self.assertIn('linked word', result['text'])
        self.assertIn('• First', result['text'])
        self.assertNotIn('secret', result['text'])
        self.assertNotIn('Navigation', result['text'])

    def test_docx_paragraphs_and_table_cells_remain_in_order(self):
        data = archive({'word/document.xml': '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>First</w:t></w:r><w:r><w:t> linked</w:t></w:r></w:p><w:tbl><w:tr><w:tc><w:p><w:r><w:t>Table</w:t></w:r></w:p></w:tc></w:tr></w:tbl><w:p><w:r><w:t>Last</w:t></w:r></w:p></w:body></w:document>'})
        self.assertEqual(f.import_document(file_payload('document.docx', data))['text'], 'First linked\n\nTable\n\nLast')

    def test_epub_uses_spine_order_rather_than_archive_filename_order(self):
        data = archive({'META-INF/container.xml': '<container><rootfile full-path="OPS/book.opf"/></container>', 'OPS/book.opf': '<package xmlns="http://www.idpf.org/2007/opf"><manifest><item id="a" href="a.xhtml"/><item id="b" href="b.xhtml"/></manifest><spine><itemref idref="b"/><itemref idref="a"/></spine></package>', 'OPS/a.xhtml': '<p>Last chapter.</p>', 'OPS/b.xhtml': '<p>First chapter.</p>'})
        self.assertEqual(f.import_document(file_payload('book.epub', data))['text'], 'First chapter.\n\nLast chapter.')

    def test_empty_oversized_unknown_and_entity_documents_are_rejected(self):
        for payload in [file_payload('empty.txt', b'  '), file_payload('app.exe', b'executable'), {'name': 'bad.txt', 'data': 'not base64'}, file_payload('large.txt', b'a' * (f.MAX_DOCUMENT + 1))]:
            with self.assertRaises(f.ToolError):
                f.import_document(payload)
        with self.assertRaises(f.ToolError):
            f.xml(b'<!DOCTYPE root [<!ENTITY x "secret">]><root>&x;</root>')


class LibraryTests(unittest.TestCase):
    def test_saved_progress_bookmarks_delete_and_no_implicit_text_persistence(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'library.sqlite3'
            library = f.Library(path)
            self.assertFalse(path.exists())
            saved = library.save({'title': 'A chapter', 'text': 'Read this.', 'position': 2, 'bookmarks': [{'position': 1, 'label': 'A note'}]})
            self.assertEqual(library.get(saved['id'])['position'], 2)
            self.assertEqual(library.get(saved['id'])['bookmarks'][0]['label'], 'A note')
            self.assertNotIn('text', library.list()[0])
            library.delete(saved['id'])
            self.assertEqual(library.list(), [])
            with self.assertRaises(f.ToolError):
                library.get(saved['id'])

    def test_invalid_library_input_does_not_write(self):
        with tempfile.TemporaryDirectory() as directory:
            library = f.Library(Path(directory) / 'db')
            for update in [{'position': -1}, {'bookmarks': [{'position': 'wrong', 'label': 'x'}]}, {'title': []}]:
                with self.assertRaises(f.ToolError):
                    library.save({'text': 'hello', **update})
            self.assertEqual(library.list(), [])


class AITests(unittest.TestCase):
    def test_summary_processes_first_and_last_sections(self):
        calls = []
        def model(messages, json_output=False):
            calls.append(messages)
            return 'Short summary.'
        text = 'Beginning ' + ('ordinary text. ' * 1300) + ' Ending'
        with patch.object(f, 'chat_model', model):
            result = f.ai_task({'text': text, 'mode': 'summary'}, lambda: None, lambda _: None)
        self.assertEqual(result['sections'], 3)
        self.assertIn('Beginning', calls[0][1]['content'])
        self.assertIn('Ending', calls[2][1]['content'])
        self.assertIn('untrusted data', calls[0][0]['content'])

    def test_chat_retrieves_relevant_passages_and_exposes_sources(self):
        text = 'Ordinary introduction. ' * 110 + '\n\nUnique bicycle detail is here.\n\n' + 'Other ending. ' * 120
        with patch.object(f, 'chat_model', lambda messages, json_output=False: 'Bicycle [Passage 2].'):
            result = f.ai_task({'text': text, 'mode': 'chat', 'question': 'Where is the bicycle?'}, lambda: None, lambda _: None)
        self.assertTrue(any('bicycle' in source['text'] for source in result['sources']))
        self.assertIn('[Passage 2]', result['text'])

    def test_podcast_validates_quotes_and_script_before_audio(self):
        with patch.object(f, 'chat_model', lambda *args, **kwargs: '{"facts":[{"claim":"Invented","quote":"Not in source"}]}'):
            with self.assertRaises(f.ToolError):
                f.ai_task({'text': 'A short source.', 'mode': 'podcast'}, lambda: None, lambda _: None)
        brief = {'main_idea': 'A short source', 'facts': [{'claim': 'A short source.', 'quote': 'A short source.'}]}
        script = {'title': 'Overview', 'turns': [{'speaker': 'A' if i % 2 == 0 else 'B', 'text': 'A short source.', 'sources': ['F1']} for i in range(4)]}
        with patch.object(f, 'chat_model', side_effect=[json.dumps(brief), json.dumps(script), json.dumps(script)]):
            result = f.ai_task({'text': 'A short source.', 'mode': 'podcast'}, lambda: None, lambda _: None)
        self.assertEqual(result['turns'], script['turns'])
        self.assertEqual(result['sourceFacts'][0]['id'], 'F1')
        self.assertEqual(result['promptVersion'], f.prompts.VERSION)

    def test_podcast_repairs_alternation_and_rejects_unsupported_source_ids(self):
        brief = {'main_idea': 'A source', 'facts': [{'claim': 'A short source.', 'quote': 'A short source.'}]}
        invalid = {'title': 'Overview', 'turns': [{'speaker': 'A', 'text': 'A short source.', 'sources': ['F99']} for _ in range(4)]}
        with patch.object(f, 'chat_model', side_effect=[json.dumps(brief), json.dumps(invalid), json.dumps(invalid)]):
            with self.assertRaises(f.ToolError):
                f.ai_task({'text': 'A short source.', 'mode': 'podcast'}, lambda: None, lambda _: None)

    def test_export_combines_wav_with_two_distinct_voices(self):
        calls = []
        def voice(text, selected_voice):
            calls.append((text, selected_voice))
            output = io.BytesIO()
            with wave.open(output, 'wb') as wav:
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(24000); wav.writeframes(b'\0\0' * 2400)
            return {'audio': base64.b64encode(output.getvalue()).decode()}
        result = f.export_audio({'turns': [{'speaker': 'A', 'text': 'First.'}, {'speaker': 'B', 'text': 'Second.'}]}, voice, lambda: None, lambda _: None)
        self.assertEqual([v for _, v in calls], ['kitten:kiki', 'kitten:jasper'])
        with wave.open(io.BytesIO(base64.b64decode(result['audio']))) as wav:
            self.assertEqual(wav.getframerate(), 24000)
            self.assertEqual(wav.getnframes(), 14400)


class JobTests(unittest.TestCase):
    def test_cancelled_job_cannot_publish_a_completed_result(self):
        jobs = f.Jobs(); release = threading.Event()
        def task(cancel, progress):
            release.wait(2)
            return {'text': 'must not be published'}
        key = jobs.start(task)['id']; jobs.get(key, cancel=True); release.set()
        for _ in range(50):
            state = jobs.get(key)
            if state['status'] == 'cancelled':
                break
            time.sleep(.01)
        self.assertEqual(state['status'], 'cancelled')
        self.assertNotIn('result', state)
        jobs.pool.shutdown(wait=True)

    def test_unexpected_errors_do_not_echo_private_source(self):
        jobs = f.Jobs()
        def task(cancel, progress):
            raise RuntimeError('private document content')
        key = jobs.start(task)['id']
        for _ in range(50):
            state = jobs.get(key)
            if state['status'] == 'error':
                break
            time.sleep(.01)
        self.assertNotIn('private document', state['message'])
        jobs.pool.shutdown(wait=True)


if __name__ == '__main__':
    unittest.main()
