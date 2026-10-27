import base64
import importlib.util
import io
import sys
import json
import sqlite3
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import wave
import zipfile
from epub_fixture import chapter_book

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'app/voice'))
spec = importlib.util.spec_from_file_location('features', Path(__file__).resolve().parents[2] / 'app/voice/features.py')
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

    def test_epub3_contents_preserves_fragment_chapters_and_metadata(self):
        result = f.import_document(file_payload('book.epub', chapter_book()))
        self.assertEqual(result['title'], 'A Chaptered Book')
        self.assertEqual(result['author'], 'Fixture Author')
        self.assertEqual(result['source'], 'book.epub')
        self.assertEqual(result['text'].split('\n\n'), [
            'Opening heading', '🙂 The first chapter starts here.',
            'Second heading', 'The second chapter starts here.',
            'End heading', 'The final chapter ends here.',
        ])
        self.assertEqual(result['chapters'], [
            {'id': 'chapter-1', 'title': 'First & foremost', 'paragraph': 0},
            {'id': 'chapter-2', 'title': 'Second chapter', 'paragraph': 2},
            {'id': 'chapter-3', 'title': 'Final chapter', 'paragraph': 4},
        ])

    def test_epub2_ncx_with_doctype_and_relative_paths(self):
        data = archive({
            'META-INF/container.xml': '<container><rootfile full-path="OPS/book.opf"/></container>',
            'OPS/book.opf': '<package><manifest><item id="main" href="Text/book.xhtml"/><item id="toc" href="Nav/toc.ncx" media-type="application/x-dtbncx+xml"/></manifest><spine toc="toc"><itemref idref="main"/></spine></package>',
            'OPS/Nav/toc.ncx': '''<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
              <ncx><navMap><navPoint><navLabel><text>Opening</text></navLabel><content src="../Text/book.xhtml"/>
              <navPoint><navLabel><text>Next part</text></navLabel><content src="../Text/book.xhtml#next"/></navPoint>
              </navPoint></navMap></ncx>''',
            'OPS/Text/book.xhtml': '<h1>Opening heading</h1><p>First text.</p><a id="next"></a><p>Next text.</p>',
        })
        result = f.import_document(file_payload('book.epub', data))
        self.assertEqual([(c['title'], c['paragraph']) for c in result['chapters']], [('Opening', 0), ('Next part', 2)])

    def test_epub_contents_can_share_a_spine_document_with_chapters(self):
        data = archive({
            'META-INF/container.xml': '<container><rootfile full-path="book.opf"/></container>',
            'book.opf': '<package><manifest><item id="book" href="book.xhtml" properties="nav"/></manifest><spine><itemref idref="book"/></spine></package>',
            'book.xhtml': '<nav epub:type="toc"><a href="#one">First chapter</a><a href="#two">Second chapter</a></nav><h1 id="one">One</h1><p>First text.</p><h1 id="two">Two</h1><p>Second text.</p>',
        })
        result = f.import_document(file_payload('book.epub', data))
        self.assertEqual(result['text'], 'One\n\nFirst text.\n\nTwo\n\nSecond text.')
        self.assertEqual([(c['title'], c['paragraph']) for c in result['chapters']], [('First chapter', 0), ('Second chapter', 2)])

    def test_epub_without_contents_uses_headings_and_skips_empty_documents(self):
        data = archive({
            'META-INF/container.xml': '<container><rootfile full-path="book.opf"/></container>',
            'book.opf': '<package><manifest><item id="empty" href="empty.xhtml"/><item id="a" href="a.xhtml"/><item id="b" href="b.xhtml"/></manifest><spine><itemref idref="empty"/><itemref idref="a"/><itemref idref="b"/></spine></package>',
            'empty.xhtml': '<head><title>Not reading content</title></head>',
            'a.xhtml': '<h1>A <em>real</em> heading</h1><p>Words.</p>',
            'b.xhtml': '<p>No heading here.</p>',
        })
        result = f.import_document(file_payload('book.epub', data))
        self.assertEqual([(c['title'], c['paragraph']) for c in result['chapters']], [('A real heading', 0), ('Chapter 2', 2)])

    def test_epub_links_stay_inside_the_archive(self):
        for href in ['https://example.com/book.xhtml', '//example.com/book.xhtml', '../../../outside', '/outside', '../%2e%2e/outside']:
            with self.subTest(href=href):
                self.assertIsNone(f.epub_target('OPS/book.opf', href))
        self.assertEqual(f.epub_target('OPS/Nav/toc.ncx', '../Text/book%20one.xhtml#part%202'), ('OPS/Text/book one.xhtml', 'part 2'))

    def test_empty_oversized_unknown_and_entity_documents_are_rejected(self):
        for payload in [file_payload('empty.txt', b'  '), file_payload('app.exe', b'executable'), {'name': 'bad.txt', 'data': 'not base64'}, file_payload('large.txt', b'a' * (f.MAX_DOCUMENT + 1))]:
            with self.assertRaises(f.ToolError):
                f.import_document(payload)
        with self.assertRaises(f.ToolError):
            f.xml(b'<!DOCTYPE root [<!ENTITY x "secret">]><root>&x;</root>')


class LibraryTests(unittest.TestCase):
    def test_chapters_survive_progress_updates_reopen_and_backup_round_trip(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'db'
            library = f.Library(path)
            imported = f.import_document(file_payload('book.epub', chapter_book()))
            saved = library.save(imported)
            # An older client can update progress without deleting chapter metadata.
            library.save({**saved, 'position': 3, 'chapters': saved['chapters']})
            legacy_update = {**saved, 'position': 4}
            legacy_update.pop('chapters')
            library.save(legacy_update)
            reopened = f.Library(path).get(saved['id'])
            self.assertEqual(reopened['chapters'], imported['chapters'])
            self.assertEqual(reopened['position'], 4)
            restored = f.Library(Path(directory) / 'restored').save(json.loads(json.dumps(reopened)))
            self.assertEqual(restored['chapters'], imported['chapters'])
            # Editing the source invalidates the old chapter locations.
            changed = {**legacy_update, 'text': 'Changed text.'}
            self.assertEqual(library.save(changed)['chapters'], [])

    def test_old_library_schema_migrates_without_losing_readings(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'old.sqlite3'
            with sqlite3.connect(path) as db:
                db.execute('CREATE TABLE documents (id TEXT PRIMARY KEY, title TEXT, text TEXT, source TEXT, position INTEGER, bookmarks TEXT, updated TEXT)')
                db.execute('INSERT INTO documents VALUES(?,?,?,?,?,?,?)', ('old', 'Old title', 'Saved text.', '', 2, '[{"position":1,"label":"Kept"}]', '2026-01-01'))
            saved = f.Library(path).get('old')
            self.assertEqual(saved['text'], 'Saved text.')
            self.assertEqual(saved['position'], 2)
            self.assertEqual(saved['bookmarks'][0]['label'], 'Kept')
            self.assertEqual(saved['chapters'], [])
            self.assertEqual(f.Library(path).save(saved)['id'], 'old')

    def test_invalid_chapters_never_create_a_library_entry(self):
        invalid = [None, {}, [{'id': 'a', 'title': 'A', 'paragraph': True}],
                   [{'id': 'a', 'title': 'A', 'paragraph': -1}],
                   [{'id': 'a', 'title': 'A', 'paragraph': 1}],
                   [{'id': 'a', 'title': 'A', 'paragraph': 0}, {'id': 'a', 'title': 'B', 'paragraph': 1}],
                   [{'id': 'a', 'title': 'A', 'paragraph': 0}, {'id': 'b', 'title': 'B', 'paragraph': 0}],
                   [{'id': 'a', 'title': 'A', 'paragraph': 0}, {'id': 'b', 'title': 'B', 'paragraph': 2}]]
        with tempfile.TemporaryDirectory() as directory:
            library = f.Library(Path(directory) / 'db')
            for chapters in invalid:
                with self.subTest(chapters=chapters), self.assertRaises(f.ToolError):
                    library.save({'text': 'First.\n\nSecond.', 'chapters': chapters})
            self.assertEqual(library.list(), [])

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
    def test_model_returns_only_final_content_across_reasoning_formats(self):
        cases = [
            {'content': 'Final answer.', 'thinking': 'Private working notes.'},
            {'content': '<think>Working notes.</think>Final answer.'},
            {'content': 'Prefilled working notes.</think>Final answer.'},
            {'content': '{"title":"Final answer."}'},
        ]
        messages = [{'role': 'system', 'content': 'Source-only assistant.'}, {'role': 'user', 'content': 'Summarize.'}]
        for message in cases:
            with self.subTest(message=message), patch.object(f, 'ollama_request', return_value={'message': message}) as request:
                expected = '{"title":"Final answer."}' if message['content'].startswith('{') else 'Final answer.'
                self.assertEqual(f.chat_model(messages), expected)
                self.assertFalse(request.call_args.args[1]['think'])
        self.assertEqual(messages[0]['content'], 'Source-only assistant.')

    def test_model_rejects_incomplete_or_empty_final_answers(self):
        for content in ['<think>Incomplete notes', '<think>Notes</think>', 'Prefilled notes</think>']:
            with self.subTest(content=content), patch.object(f, 'ollama_request', return_value={'message': {'content': content}}):
                with self.assertRaises(f.ToolError):
                    f.chat_model([{'role': 'system', 'content': 'Assistant.'}])
        with patch.object(f, 'ollama_request', return_value={'done_reason': 'length', 'message': {'content': 'Unfinished working notes'}}):
            with self.assertRaises(f.ToolError):
                f.chat_model([{'role': 'system', 'content': 'Assistant.'}])

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
