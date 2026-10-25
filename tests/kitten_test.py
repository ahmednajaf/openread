from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'voice'))
import kitten
import features


class AlignmentTests(unittest.TestCase):
    def test_unrecognized_run_does_not_freeze_first_word(self):
        words = kitten.align_transcript('One small missed phrase ends.', [
            SimpleNamespace(word='One', start=0, end=.4),
            SimpleNamespace(word='ends.', start=2, end=2.5)], 2.5)
        self.assertEqual(words[0]['end'], .4)
        self.assertEqual(words[-1]['start'], 2)
        self.assertTrue(all(w['end'] > w['start'] for w in words))
        self.assertTrue(all(a['end'] <= b['start'] for a, b in zip(words, words[1:])))

    def test_leading_and_trailing_gaps_keep_utf16_offsets(self):
        words = kitten.align_transcript('🌊 First two anchor last words', [
            SimpleNamespace(word='anchor', start=1, end=1.5)], 3)
        self.assertEqual(words[0]['offset'], 3)
        self.assertEqual(words[2]['start'], 1)
        self.assertTrue(all(w['end'] > w['start'] for w in words))
        self.assertEqual(words[-1]['end'], 3)

    def test_whisper_does_not_use_source_as_previous_transcript(self):
        model = SimpleNamespace(transcribe=lambda *a, **kw: ([], None))
        with patch.object(features, 'whisper_model', return_value=model):
            with patch.object(model, 'transcribe', return_value=([], None)) as call:
                features.whisper_word_timings([], 'A long source ending in repeated words.')
        self.assertNotIn('initial_prompt', call.call_args.kwargs)
        self.assertTrue(call.call_args.kwargs['word_timestamps'])


if __name__ == '__main__':
    unittest.main()
