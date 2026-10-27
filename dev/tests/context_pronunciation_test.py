import importlib.util
import json
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'app/voice'))
from pronunciation import ContextPronunciation, WordPiece, apply_choices
FIXTURE = ROOT / 'app/mobile/shared/fixtures/pronunciation.json'

class ContextPronunciationTests(unittest.TestCase):
    def test_wordpiece_matches_the_reference_tokenizer_including_unicode(self):
        tokenizer = WordPiece((ROOT / 'app/mobile/shared/pronunciation/vocab.txt').read_text())
        for row in json.loads(FIXTURE.read_text())['tokenization']:
            with self.subTest(text=row['text']): self.assertEqual(tokenizer.encode(row['text']), row['ids'])

    @unittest.skipUnless(importlib.util.find_spec('onnxruntime'), 'Install ONNX Runtime to test actual context inference')
    def test_context_changes_meaning_without_rewriting_source(self):
        model = ContextPronunciation()
        for row in json.loads(FIXTURE.read_text())['decisions']:
            with self.subTest(text=row['text']):
                actual = '\n'.join(f'{i}\t{ipa}' for i, ipa in model.choices(row['text']).items())
                self.assertEqual(actual, row['replacements'])
        self.assertEqual(model.choices('A Nymph kept him in her vaulted cave.'), {})
        # Independent grammar confidence abstains rather than turning a present
        # tense sentence into the more frequent past-tense training class.
        self.assertEqual(model.choices('I read the book every morning.'), {})

    def test_alignment_preserves_punctuation_numbers_and_other_words(self):
        source = 'Yesterday, I read 12 pages.'
        baseline = 'jˈɛstɚdˌeɪ, aɪ ɹˈiːd twˈɛlv pˈeɪdʒɪz.'
        isolated = ['jˈɛstɚdˌeɪ,', 'aɪ', 'ɹˈiːd', 'twˈɛlv', 'pˈeɪdʒɪz.']
        self.assertEqual(apply_choices(source, baseline, isolated, {2:'ˈɹɛd'}), baseline.replace('ɹˈiːd','ˈɹɛd'))
        self.assertEqual(apply_choices(source, baseline, isolated, {}), baseline)

    def test_merged_or_unanchored_phone_groups_abstain(self):
        self.assertEqual(apply_choices('I read', 'aɪɹiːd', ['aɪ','ɹiːd'], {1:'ɹɛd'}), 'aɪɹiːd')
        self.assertEqual(apply_choices('read', 'xiːx', ['ɹiːd'], {0:'ɹɛd'}), 'xiːx')
        self.assertEqual(apply_choices('read', 'ɹiːd'*700, ['ɹiːd'*700], {0:'ɹɛd'}), 'ɹiːd'*700)

    def test_repeated_words_keep_their_own_source_owner(self):
        self.assertEqual(apply_choices('wind wind', 'wɪnd waɪnd', ['wɪnd','wɪnd'], {1:'ˈwaɪnd'}), 'wɪnd ˈwaɪnd')

if __name__ == '__main__': unittest.main()
