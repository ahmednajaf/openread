import base64
import pathlib
import sys
import tempfile
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / 'app/voice'))
import features

class FullBookTests(unittest.TestCase):
    def test_complete_book_contents_text_and_last_chapter_survive_saving(self):
        data = (pathlib.Path(__file__).resolve().parents[2] / 'app/mobile/shared/fixtures/full-book.epub').read_bytes()
        result = features.import_document({'name': 'Full book.epub', 'data': base64.b64encode(data).decode()}, lambda: None)
        self.assertGreater(len(result['text']), 2_000_000)
        self.assertEqual(len(result['chapters']), 24)
        self.assertEqual(result['chapters'][-1]['title'], 'Chapter 24')
        with tempfile.TemporaryDirectory() as folder:
            library = features.Library(pathlib.Path(folder) / 'library.db')
            saved = library.save(result)
            reopened = features.Library(pathlib.Path(folder) / 'library.db').get(saved['id'])
            self.assertEqual(reopened['text'], result['text'])
            self.assertEqual(reopened['chapters'], result['chapters'])

if __name__ == '__main__': unittest.main()
